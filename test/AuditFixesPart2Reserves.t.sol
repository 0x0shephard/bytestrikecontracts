// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";

/// @notice Regression tests for vAMM reserve resets (Cyfrin bytestrike part 2, finding 2).
contract AuditFixesPart2ReservesTest is BaseTest {
    uint128 internal constant SIZE = 20 ether;

    function _pastCooldown() internal {
        vm.warp(vm.getBlockTimestamp() + vamm.RESET_COOLDOWN());
    }

    /// @notice Finding 2: with a net long open, a deeper reset at the same price would let the long
    /// exit with profit no account paid, so it must revert.
    function test_Finding2_depthResetWithNetOpenInterestReverts() public {
        fundAndDeposit(alice, 50_000 * USDC_UNIT);
        openLongPosition(alice, SIZE, 0);
        _pastCooldown();

        uint256 mark = getMarkPrice();
        vm.prank(admin);
        vm.expectRevert("Net OI open");
        vamm.resetReserves(mark, 10 * INITIAL_BASE_RESERVE);
    }

    /// @notice Finding 2 (auditor comment): a price-only reset at the current depth moves the net
    /// side's exit value the same way, so it is blocked too.
    function test_Finding2_priceOnlyResetWithNetOpenInterestReverts() public {
        fundAndDeposit(alice, 50_000 * USDC_UNIT);
        openShortPosition(alice, SIZE, 0);
        _pastCooldown();

        (uint256 base,) = getReserves();
        uint256 mark = getMarkPrice();
        vm.prank(admin);
        vm.expectRevert("Net OI open");
        vamm.resetReserves(mark * 105 / 100, base);
    }

    /// @notice Finding 2: with balanced open interest a reset moves no value to a net side and
    /// remains available.
    function test_Finding2_resetAllowedWithBalancedOpenInterest() public {
        fundAndDeposit(alice, 50_000 * USDC_UNIT);
        fundAndDeposit(bob, 50_000 * USDC_UNIT);
        openLongPosition(alice, SIZE, 0);
        openShortPosition(bob, SIZE, 0);
        assertEq(vamm.totalLongOI(), vamm.totalShortOI(), "balanced book");
        _pastCooldown();

        uint256 mark = getMarkPrice();
        vm.prank(admin);
        vamm.resetReserves(mark, 2 * INITIAL_BASE_RESERVE);
        (uint256 base,) = getReserves();
        assertEq(base, 2 * INITIAL_BASE_RESERVE, "depth reset");
    }
}
