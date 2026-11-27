// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";

/// @notice Regression for finding 24 (mitigation review): depositMargin's bound measures equity with
/// min(unrealized PnL at the index, 0), net of funding debt, as removeMargin does, so a position in
/// profit but liquidatable for funding debt can still be cured past the deposit pause.
contract AuditFixesPart2Review24Test is BaseTest {
    uint128 internal constant ALICE_SIZE = 5e18;
    uint128 internal constant BOB_SIZE = 100e18;

    function setUp() public override {
        super.setUp();

        // Alice opens a long with her whole deposit
        fundAndDeposit(alice, 1_300e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, ALICE_SIZE, 0);

        // A larger long lifts the mark and the index follows it, so alice is well in profit at the index
        fundAndDeposit(bob, 100_000e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, true, BOB_SIZE, 0);
        setOraclePrice(vamm.getMarkPrice());

        // A holding fee of 100% a year drains margin and free collateral like a funding debit
        vm.prank(admin);
        clearingHouse.setHoldingFeeRate(ETH_PERP, 10_000);

        // Alice keeps wallet USDC to top up with
        fundUser(alice, 10_000e18);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Advances time with a keeper settling the market every hour (funding and the holding fee
    ///      accrue at most one hour per settlement).
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

    function _pauseDeposits() internal {
        ICollateralVault.CollateralConfig memory cfg = vault.getConfig(address(usdc));
        cfg.depositPaused = true;
        vm.prank(admin);
        vault.setCollateralParams(address(usdc), cfg);
    }

    function test_DepositMarginCuresDebtLiquidatablePositionInProfit() public {
        // 42 days later (a keeper settling the market hourly) the fee exceeds alice's whole balance and
        // the rest is carried as funding debt
        _keepSettling(42 days);
        clearingHouse.settleFunding(ETH_PERP, alice);
        uint256 debt = clearingHouse.getPosition(alice, ETH_PERP).fundingDebt;
        assertGt(debt, 0, "no funding debt");
        assertEq(vault.balanceOf(alice, address(usdc)), 0, "balance left");

        // Alice is far above maintenance at the index, but liquidatable for the debt she cannot pay
        assertGt(clearingHouse.getMarginRatio(alice, ETH_PERP), MMR_BPS * 1e14, "below maintenance");
        assertTrue(clearingHouse.isLiquidatable(alice, ETH_PERP), "not liquidatable");

        // Deposits are paused; the top-up path still takes the debt and cures the position
        _pauseDeposits();
        uint256 topUp = debt + 1e18;
        vm.prank(alice);
        vm.expectRevert("CV: deposits paused");
        clearingHouse.deposit(address(usdc), topUp);
        vm.prank(alice);
        clearingHouse.depositMargin(ETH_PERP, topUp);
        clearingHouse.settleFunding(ETH_PERP, alice);
        assertEq(clearingHouse.getPosition(alice, ETH_PERP).fundingDebt, 0, "debt not paid");
        assertFalse(clearingHouse.isLiquidatable(alice, ETH_PERP), "top-up did not cure");

        // The liquidation she would have paid the penalty for no longer goes through
        vm.prank(liquidator);
        vm.expectRevert();
        clearingHouse.liquidate(alice, ETH_PERP, ALICE_SIZE, 0);
    }

    function test_DepositMarginStillBoundedByInitialMargin() public {
        _keepSettling(42 days);
        clearingHouse.settleFunding(ETH_PERP, alice);
        uint256 debt = clearingHouse.getPosition(alice, ETH_PERP).fundingDebt;
        _pauseDeposits();

        // Profit does not count, but a top-up past debt plus the initial margin is still refused
        uint256 imr = uint256(ALICE_SIZE) * vamm.getMarkPrice() / 1e18 * IMR_BPS / 10_000;
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.ExceedsMarginTopUp.selector);
        clearingHouse.depositMargin(ETH_PERP, debt + imr + 10e18);
    }
}
