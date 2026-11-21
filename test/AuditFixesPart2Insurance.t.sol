// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";

/// @notice Regression tests for InsuranceFund usage audit fixes (Cyfrin bytestrike part 2).
contract AuditFixesPart2InsuranceTest is BaseTest {
    function _trackedInsurance() internal view returns (uint256) {
        return insuranceFund.totalReceived() - insuranceFund.totalPaid();
    }

    /// @dev Pays the fund's tracked balance down to `remaining`.
    function _drainInsuranceTo(uint256 remaining) internal {
        uint256 tracked = _trackedInsurance();
        vm.prank(address(clearingHouse));
        insuranceFund.payout(treasury, tracked - remaining);
    }

    /// @dev Alice's long loses more than her whole deposit, so the liquidator incentive
    /// cannot be collected from her and falls to the insurance fund.
    function _openUnderwaterLong() internal {
        fundAndDeposit(alice, 1_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 9e18, 0);
        // Bob's large short pushes the vAMM mark down so alice's close realizes a loss
        // larger than her deposit.
        fundAndDeposit(bob, 100_000 * USDC_UNIT);
        setOraclePrice(1_800e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 60e18, 0);
        setOraclePrice(getMarkPrice());
        assertTrue(isLiquidatable(alice), "alice should be liquidatable");
    }

    /// @notice Finding 19: a direct transfer to the fund must not void the insurance payout
    /// for a liquidator-incentive shortfall larger than the tracked reserve.
    function test_Finding19_directTransferDoesNotVoidLiquidationPayout() public {
        _openUnderwaterLong();

        uint256 tracked = 10 * USDC_UNIT;
        _drainInsuranceTo(tracked);
        usdc.mint(address(insuranceFund), 1); // untracked dust via plain transfer
        uint256 keeperBefore = getCollateralBalance(liquidator) + usdc.balanceOf(liquidator);
        uint256 badDebtBefore = clearingHouse.totalBadDebt();

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 9e18, 0);

        uint256 keeperAfter = getCollateralBalance(liquidator) + usdc.balanceOf(liquidator);
        assertEq(_trackedInsurance(), 0, "fund paid its whole tracked balance");
        assertEq(keeperAfter - keeperBefore, tracked, "keeper received the tracked reserve");
        assertGt(clearingHouse.totalBadDebt(), badDebtBefore, "remaining shortfall recorded as bad debt");
    }

    /// @notice Finding 19: owner can book quote tokens sent by plain transfer into the tracked balance.
    function test_Finding19_syncBooksUntrackedBalance() public {
        uint256 trackedBefore = _trackedInsurance();
        usdc.mint(address(insuranceFund), 500 * USDC_UNIT);
        assertEq(_trackedInsurance(), trackedBefore, "plain transfer is untracked");

        vm.prank(admin);
        uint256 booked = insuranceFund.sync();

        assertEq(booked, 500 * USDC_UNIT, "booked surplus");
        assertEq(_trackedInsurance(), trackedBefore + 500 * USDC_UNIT, "tracked balance includes surplus");
        assertEq(_trackedInsurance(), insuranceFund.balance(), "tracked equals token balance");

        // Payout of the full balance now succeeds.
        uint256 fullBalance = insuranceFund.balance();
        vm.prank(address(clearingHouse));
        insuranceFund.payout(treasury, fullBalance);
    }

    function test_Finding19_syncOnlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        insuranceFund.sync();
    }
}
