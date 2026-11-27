// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

/// @notice Finding 26: every open position pays a continuing holding fee on its notional, so a
///         delta-neutral pair parked on the gross OI cap pays for the capacity it blocks.
contract AuditFixesPart2HoldingFeeTest is BaseTest {
    uint256 internal constant RATE_BPS = 1_000; // 10% of notional per year

    function setUp() public override {
        super.setUp();
        fundAndDeposit(alice, 20_000e18);
        fundAndDeposit(bob, 20_000e18);
        // A delta-neutral pair: Alice long, Bob short, same size.
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 5e18, 0);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 5e18, 0);
    }

    function _setRate(uint256 bps) internal {
        vm.prank(admin);
        clearingHouse.setHoldingFeeRate(ETH_PERP, bps);
    }

    /// @dev Advances time by `duration` with a keeper settling the market every hour (an account with no
    ///      position, so no position is charged on the way): funding and the holding fee accrue at most
    ///      one hour per settlement, so a market left unsettled longer is not charged for the gap.
    function _keepSettling(uint256 duration) internal {
        address keeper = makeAddr("keeper");
        uint256 t = vm.getBlockTimestamp();
        uint256 end = t + duration;
        while (t < end) {
            t += 1 hours;
            vm.warp(t);
            clearingHouse.settleFunding(ETH_PERP, keeper);
        }
    }

    /// @dev Index growth over `hoursCount` hourly settlements at `bps` a year.
    function _hourly(uint256 bps, uint256 hoursCount) internal pure returns (uint256) {
        return hoursCount * (bps * 1e14 * 1 hours / 365 days);
    }

    function _routerFees() internal view returns (uint256) {
        return clearingHouse.pendingTradeFees(address(feeRouter), address(usdc));
    }

    function _ceil(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + 1e18 - 1) / 1e18;
    }

    /// @dev Fee `account` owes when the market index reaches `cumulative`.
    function _expectedFee(address account, uint256 cumulative) internal view returns (uint256) {
        IClearingHouse.PositionView memory p = clearingHouse.getPosition(account, ETH_PERP);
        uint256 absSize = uint256(p.size > 0 ? p.size : -p.size);
        return _ceil(_ceil(absSize, oracle.getPrice()), cumulative - p.lastHoldingFeeIndexX18);
    }

    function test_Finding26_DeltaNeutralPairPaysHoldingFee() public {
        _setRate(RATE_BPS);
        uint256 routerBefore = _routerFees();
        _keepSettling(30 days);

        uint256 cumulative = _hourly(RATE_BPS, 30 * 24);
        uint256 feeAlice = _expectedFee(alice, cumulative);
        uint256 feeBob = _expectedFee(bob, cumulative);
        // 10% a year of a ~10,000 notional for 30 days: about 82 each.
        assertApproxEqRel(feeAlice, 82e18, 0.02e18);

        clearingHouse.settleFunding(ETH_PERP, alice);
        clearingHouse.settleFunding(ETH_PERP, bob);
        (, uint256 cumAfter,) = clearingHouse.holdingFees(ETH_PERP);
        assertEq(cumAfter, cumulative);
        assertEq(_routerFees() - routerBefore, feeAlice + feeBob);
        assertEq(clearingHouse.getPosition(alice, ETH_PERP).lastHoldingFeeIndexX18, cumulative);

        // The booked fees reach the router, which splits them.
        uint256 routerTokensBefore = usdc.balanceOf(address(feeRouter));
        clearingHouse.sweepFees(address(feeRouter), address(usdc));
        assertEq(_routerFees(), 0);
        assertGt(usdc.balanceOf(address(feeRouter)), routerTokensBefore);
    }

    function test_Finding26_NoFeeWithoutRate() public {
        vm.warp(block.timestamp + 30 days);
        uint256 routerBefore = _routerFees();
        clearingHouse.settleFunding(ETH_PERP, alice);
        assertEq(_routerFees(), routerBefore);
    }

    /// @notice A rate change applies from the moment it is set; the old rate covers the time before.
    function test_Finding26_RateChangeAccruesOldRate() public {
        _setRate(RATE_BPS);
        _keepSettling(10 days);
        _setRate(2 * RATE_BPS);
        _keepSettling(10 days);
        clearingHouse.settleFunding(ETH_PERP, alice);
        (, uint256 cumulative,) = clearingHouse.holdingFees(ETH_PERP);
        assertEq(cumulative, _hourly(RATE_BPS, 240) + _hourly(2 * RATE_BPS, 240));
    }

    /// @notice A position opened later pays only from its open.
    function test_Finding26_NewPositionPaysFromOpen() public {
        _setRate(RATE_BPS);
        vm.warp(block.timestamp + 30 days);
        address carol = makeAddr("carol");
        fundAndDeposit(carol, 20_000e18);
        vm.prank(carol);
        clearingHouse.openPosition(ETH_PERP, true, 1e18, 0);
        (, uint256 cumulative,) = clearingHouse.holdingFees(ETH_PERP);
        assertGt(cumulative, 0);
        assertEq(clearingHouse.getPosition(carol, ETH_PERP).lastHoldingFeeIndexX18, cumulative);
    }

    /// @notice The pending fee counts in the health check before it is settled.
    function test_Finding26_PendingFeeCountsTowardsLiquidation() public {
        _setRate(10_000);
        assertFalse(clearingHouse.isLiquidatable(alice, ETH_PERP));
        uint256 ratioBefore = clearingHouse.getMarginRatio(alice, ETH_PERP);
        vm.warp(block.timestamp + 30 days);
        assertLt(clearingHouse.getMarginRatio(alice, ETH_PERP), ratioBefore);
    }

    /// @notice Time in which funding is skipped (index oracle down) is not charged.
    function test_Finding26_OutageTimeNotCharged() public {
        _setRate(RATE_BPS);
        oracle.setPrice(0);
        clearingHouse.settleFunding(ETH_PERP, alice);
        vm.warp(block.timestamp + 30 days);
        clearingHouse.settleFunding(ETH_PERP, alice);
        oracle.setPrice(INITIAL_ETH_PRICE);
        uint256 routerBefore = _routerFees();
        clearingHouse.settleFunding(ETH_PERP, alice);
        assertEq(_routerFees(), routerBefore);
    }

    /// @notice A fee beyond the position's margin plus free collateral is carried as funding debt,
    ///         which makes the position liquidatable.
    function test_Finding26_UnpaidFeeCarriedAsDebt() public {
        // Alice keeps only her reserved margin, so a month of the fee exceeds what she can pay.
        uint256 free = vault.balanceOf(alice, address(usdc)) - clearingHouse._totalReservedMargin(alice);
        vm.prank(alice);
        clearingHouse.withdraw(address(usdc), free);
        _setRate(10_000);
        _keepSettling(30 days);
        clearingHouse.settleFunding(ETH_PERP, alice);
        assertGt(clearingHouse.getPosition(alice, ETH_PERP).fundingDebt, 0);
        assertEq(vault.balanceOf(alice, address(usdc)), 0);
        assertTrue(clearingHouse.isLiquidatable(alice, ETH_PERP));
    }

    function test_Finding26_RateBounded() public {
        vm.prank(admin);
        vm.expectRevert(ClearingHouse.InvalidHoldingFeeRate.selector);
        clearingHouse.setHoldingFeeRate(ETH_PERP, 10_001);
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.NotAdmin.selector);
        clearingHouse.setHoldingFeeRate(ETH_PERP, 100);
    }
}
