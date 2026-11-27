// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {IFeeRouter} from "../src/Interfaces/IFeeRouter.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

/// @notice Regression for finding 4 (second mitigation review): the running penalty total resets only
/// when a top-up (addMargin or depositMargin) leaves the position no longer liquidatable, and a
/// liquidation call that leaves size open collects only the keeper's half of its penalty, keeping the
/// protocol's half owed until the episode ends.
contract AuditFixesPart2Review4bTest is BaseTest {
    address internal restorer;

    uint256 internal constant CAP = 1_000e18;
    uint128 internal constant ALICE_SIZE = 50e18;
    uint256 internal constant INDEX = 1_920e18;

    function setUp() public override {
        super.setUp();
        restorer = makeAddr("restorer");
        vm.prank(admin);
        clearingHouse.setRiskParams(
            ETH_PERP, IMR_BPS, MMR_BPS, LIQUIDATION_PENALTY_BPS, CAP, MAX_POSITION_SIZE, MIN_POSITION_SIZE
        );
        fundAndDeposit(restorer, 300_000e18);
        fundAndDeposit(bob, 200_000e18);
    }

    function _openAndGap(uint256 deposit, uint256 index) internal {
        fundAndDeposit(alice, deposit);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, ALICE_SIZE, 0);
        setOraclePrice(index);
        (uint256 x, uint256 y) = getReserves();
        uint256 xTarget = _sqrtBase((x * y / index) * 1e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, uint128(xTarget - x), 0);
        assertTrue(isLiquidatable(alice), "not liquidatable");
    }

    /// @dev One liquidation call for the whole position; returns this call's protocol share.
    function _liquidateOnce() internal returns (uint256 routeAmount) {
        vm.recordLogs();
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, ALICE_SIZE, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(clearingHouse) && logs[i].topics[0] == IClearingHouse.LiquidationExecuted.selector) {
                (,,,, routeAmount,) = abi.decode(logs[i].data, (uint128, uint256, uint256, uint256, uint256, uint256));
            }
        }
    }

    /// @dev Trades the mark back to the index with the market fee at 0, as an arbitrageur would.
    function _restoreMark() internal {
        (uint256 x, uint256 y) = getReserves();
        uint256 xTarget = _sqrtBase((x * y / oracle.getPrice()) * 1e18);
        IMarketRegistry.Market memory m = marketRegistry.getMarket(ETH_PERP);
        _setMarketFee(ETH_PERP, m, 0);
        vm.prank(restorer);
        clearingHouse.openPosition(ETH_PERP, xTarget < x, uint128(xTarget < x ? x - xTarget : xTarget - x), 0);
        _setMarketFee(ETH_PERP, m, m.feeBps);
    }

    /// @dev Sum of liquidation penalties the fee router received in `logs`.
    function _routed(Vm.Log[] memory logs) internal view returns (uint256 total) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(feeRouter) && logs[i].topics[0] == IFeeRouter.LiquidationPenaltyRouted.selector) {
                (uint256 amount,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                total += amount;
            }
        }
    }

    function test_AddMarginLeavingLiquidatableKeepsRunningTotal() public {
        _openAndGap(16_000e18, INDEX);
        _liquidateOnce();
        assertNotEq(getPosition(alice).size, 0, "closed in one call");
        assertTrue(isLiquidatable(alice), "healthy after one call");
        uint256 charged = getPosition(alice).liquidationPenaltyCharged;
        assertGt(charged, 0);

        // a top-up that leaves the position liquidatable does not start a new episode
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 10e18);
        assertTrue(isLiquidatable(alice), "cured");
        assertEq(getPosition(alice).liquidationPenaltyCharged, charged, "running total reset");
    }

    function test_DepositMarginCureResetsRunningTotal() public {
        _openAndGap(16_000e18, INDEX);
        _liquidateOnce();
        assertTrue(isLiquidatable(alice), "healthy after one call");
        assertGt(getPosition(alice).liquidationPenaltyCharged, 0);

        fundUser(alice, 10_000e18);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        // the smallest top-up (in 50 USDC steps) that cures the position
        bool cured;
        for (uint256 amount = 50e18; amount <= 5_000e18 && !cured; amount += 50e18) {
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            try clearingHouse.depositMargin(ETH_PERP, amount) {
                if (!isLiquidatable(alice)) {
                    cured = true;
                    break;
                }
            } catch {}
            vm.revertToState(snap);
        }
        assertTrue(cured, "no top-up cured the position");
        assertEq(getPosition(alice).liquidationPenaltyCharged, 0, "running total not reset on cure");
        assertEq(getPosition(alice).liquidationPenaltyOwed, 0, "owed share not collected on cure");
    }

    function test_ProtocolShareOwedUntilEpisodeEnds() public {
        _openAndGap(16_000e18, INDEX);
        vm.recordLogs();
        uint256 firstShare = _liquidateOnce();
        assertNotEq(getPosition(alice).size, 0, "closed in one call");
        assertGt(firstShare, 0);
        // only the keeper's half was collected; the protocol's half is owed
        assertEq(_routed(vm.getRecordedLogs()), 0, "protocol share collected while size stays open");
        assertEq(getPosition(alice).liquidationPenaltyOwed, firstShare, "share not owed");

        // the chain ends: the owed shares are collected in full (alice has spare collateral)
        _restoreMark();
        vm.recordLogs();
        liquidateFully(alice, ETH_PERP, restorer);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(getPosition(alice).size, 0, "not closed");
        assertEq(getPosition(alice).liquidationPenaltyOwed, 0, "owed share left");
        uint256 shares = firstShare;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(clearingHouse) && logs[i].topics[0] == IClearingHouse.LiquidationExecuted.selector) {
                (,,,, uint256 share,) = abi.decode(logs[i].data, (uint128, uint256, uint256, uint256, uint256, uint256));
                shares += share;
            }
        }
        assertEq(_routed(logs), shares, "owed shares not collected at the end");
    }

    function test_UnderwaterChainCollectsNoProtocolShareTheFundCovers() public {
        // alice holds little more than the initial margin, and the index gaps 6% below her entry
        _openAndGap(11_200e18, 1_700e18);
        uint256 fundBefore = insuranceFund.totalPaid();

        vm.recordLogs();
        uint256 calls = liquidateFully(alice, ETH_PERP, restorer);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(calls, 1, "one call");
        assertEq(getPosition(alice).size, 0, "not closed");

        // the insurance fund paid for the chain, so none of alice's collateral went to the protocol's share
        assertGt(insuranceFund.totalPaid(), fundBefore, "insurance fund paid nothing");
        assertEq(_routed(logs), 0, "protocol share collected while the fund pays");
        assertEq(getPosition(alice).liquidationPenaltyOwed, 0, "owed share left");
    }
}
