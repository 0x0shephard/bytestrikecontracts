// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";

/// @notice Finding 8: a failing fee or penalty push (e.g. a USDC withdrawal pause) leaves the amount
/// booked to the fee router's vault balance instead of reverting closes and liquidations.
contract AuditFixesPart2FeeRoutingTest is BaseTest {
    function _trackedInsurance() internal view returns (uint256) {
        return insuranceFund.totalReceived() - insuranceFund.totalPaid();
    }

    function _pauseWithdrawals(bool paused) internal {
        vm.prank(admin);
        vault.setPause(address(usdc), false, paused);
    }

    function test_Finding8_withdrawalPauseDoesNotBlockCloseOrLiquidation() public {
        fundAndDeposit(alice, 10_000e18);
        fundAndDeposit(bob, 100_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, true, 1e18, 0);

        _pauseWithdrawals(true);

        // A fee-paying close goes through; the fee stays booked to the router in the vault.
        uint256 routerTokensBefore = usdc.balanceOf(address(feeRouter));
        vm.prank(bob);
        clearingHouse.closePosition(ETH_PERP, 1e18, 0);
        uint256 bookedFee = clearingHouse.pendingTradeFees(address(feeRouter), address(usdc));
        assertGt(bookedFee, 0, "fee not booked");
        assertEq(vault.balanceOf(address(feeRouter), address(usdc)), bookedFee, "fee not on router's vault balance");
        assertEq(usdc.balanceOf(address(feeRouter)), routerTokensBefore, "fee pushed during pause");

        // A liquidation that routes a penalty share goes through as well.
        setOraclePrice(1_900e18);
        assertTrue(isLiquidatable(alice), "alice not liquidatable");
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);
        uint256 bookedPenalty = clearingHouse.pendingLiqPenalties(address(feeRouter), address(usdc));
        assertGt(bookedPenalty, 0, "penalty share not booked");

        // The sweep fails while the pause lasts and keeps the amounts booked.
        vm.expectRevert(bytes("CV: withdrawals paused"));
        clearingHouse.sweepFees(address(feeRouter), address(usdc));

        // Once withdrawals resume, anyone delivers them to the router, which splits them.
        _pauseWithdrawals(false);
        uint256 trackedBefore = _trackedInsurance();
        vm.prank(makeAddr("anyone"));
        clearingHouse.sweepFees(address(feeRouter), address(usdc));
        assertEq(clearingHouse.pendingTradeFees(address(feeRouter), address(usdc)), 0, "fees still booked");
        assertEq(clearingHouse.pendingLiqPenalties(address(feeRouter), address(usdc)), 0, "penalty still booked");
        assertEq(vault.balanceOf(address(feeRouter), address(usdc)), 0, "router vault balance left");
        uint256 total = bookedFee + bookedPenalty;
        assertEq(usdc.balanceOf(address(feeRouter)) - routerTokensBefore + (_trackedInsurance() - trackedBefore), total, "split lost tokens");
        assertGt(_trackedInsurance(), trackedBefore, "fund share not delivered");
    }

    function test_Finding8_pushStillInlineWhenItSucceeds() public {
        fundAndDeposit(bob, 100_000e18);
        uint256 trackedBefore = _trackedInsurance();
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, true, 1e18, 0);
        assertEq(clearingHouse.pendingTradeFees(address(feeRouter), address(usdc)), 0, "fee booked");
        assertEq(vault.balanceOf(address(feeRouter), address(usdc)), 0, "fee left in the vault");
        assertGt(_trackedInsurance(), trackedBefore, "fund share not routed inline");
    }

    function test_Finding8_pushFeeIsSelfOnly() public {
        vm.expectRevert(bytes4(keccak256("NotSelf()")));
        clearingHouse.pushFee(address(feeRouter), address(usdc), 1, false);
    }
}
