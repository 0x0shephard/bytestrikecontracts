// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";

/// @notice Regression for finding 26 (mitigation review): the holding fee runs on the vAMM's funding clock
/// (vAMM.liveFundingSeconds), so it is charged for exactly the time funding accrues: not for a pause, a
/// skipped oracle outage or a gap past the one hour cap, and still for the live time a pause flush accrued.
contract AuditFixesPart2Review26bTest is BaseTest {
    uint256 internal constant RATE_BPS = 1_000;
    uint128 internal constant SIZE = 5e18;

    function setUp() public override {
        super.setUp();
        fundAndDeposit(alice, 20_000e18);
        fundAndDeposit(bob, 20_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, SIZE, 0);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, SIZE, 0);
        vm.prank(admin);
        clearingHouse.setHoldingFeeRate(ETH_PERP, RATE_BPS);
        clearingHouse.settleFunding(ETH_PERP, alice);
    }

    function _feeCum() internal view returns (uint256 cum) {
        (, cum,) = clearingHouse.holdingFees(ETH_PERP);
    }

    function _perSeconds(uint256 secs) internal pure returns (uint256) {
        return RATE_BPS * 1e14 * secs / 365 days;
    }

    function _pause(bool paused) internal {
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, paused);
    }

    function test_PauseWithoutSettlementNotCharged() public {
        uint256 cumBefore = _feeCum();
        _pause(true);
        uint256 tResume = vm.getBlockTimestamp() + 30 days;
        vm.warp(tResume);
        _pause(false);

        uint256 routerBefore = clearingHouse.pendingTradeFees(address(feeRouter), address(usdc));
        clearingHouse.settleFunding(ETH_PERP, alice);
        assertEq(clearingHouse.pendingTradeFees(address(feeRouter), address(usdc)), routerBefore, "paused time charged");
        assertEq(_feeCum(), cumBefore, "paused time accrued");
    }

    function test_LiveTimeBeforePauseKeptBySettlementInsidePause() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 cumBefore = _feeCum();
        // 20 live minutes, then the market is paused: the pause flush accrues them
        vm.warp(t0 + 20 minutes);
        _pause(true);
        // a settlement inside the pause neither drops them nor charges the paused time
        vm.warp(t0 + 10 days);
        clearingHouse.settleFunding(ETH_PERP, alice);
        assertEq(_feeCum(), cumBefore + _perSeconds(20 minutes), "live time before the pause dropped");
        vm.warp(t0 + 20 days);
        _pause(false);
        clearingHouse.settleFunding(ETH_PERP, alice);
        assertEq(_feeCum(), cumBefore + _perSeconds(20 minutes), "paused time charged");
    }

    function test_RateChangeDuringPauseChargesNothing() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 cumBefore = _feeCum();
        _pause(true);
        vm.warp(t0 + 30 days);
        vm.prank(admin);
        clearingHouse.setHoldingFeeRate(ETH_PERP, RATE_BPS / 2);
        assertEq(_feeCum(), cumBefore, "old rate charged for the pause");
    }

    function test_UnobservedOutageChargedAtMostTheFundingCap() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 cumBefore = _feeCum();
        // the index feed is down for five hours and no settlement observes it
        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("getPrice()"), "stale");
        vm.warp(t0 + 5 hours);
        vm.clearMockedCalls();
        clearingHouse.settleFunding(ETH_PERP, alice);
        // funding accrues at most one hour on recovery, and so does the holding fee
        assertEq(_feeCum(), cumBefore + _perSeconds(1 hours), "outage charged past the funding cap");
    }

    function test_LiveTimeChargedInFull() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 cumBefore = _feeCum();
        vm.warp(t0 + 30 minutes);
        clearingHouse.settleFunding(ETH_PERP, alice);
        vm.warp(t0 + 60 minutes);
        clearingHouse.settleFunding(ETH_PERP, alice);
        assertEq(_feeCum(), cumBefore + _perSeconds(30 minutes) + _perSeconds(30 minutes), "live time not charged");
    }
}
