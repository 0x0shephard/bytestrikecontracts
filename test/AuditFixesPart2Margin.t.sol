// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

/// @notice Regression tests for margin-check audit fixes (Cyfrin bytestrike part 2).
contract AuditFixesPart2MarginTest is BaseTest {
    // ---------------------------------------------------------------------
    // Findings 13 + 14: partial closes of healthy losing positions
    // ---------------------------------------------------------------------

    /// @dev Finding 13: closing half of a losing but healthy long used to charge the closed slice's
    /// loss to the remaining margin and revert with ImmediatelyLiquidatable.
    function test_PartialCloseOfHealthyLosingLongSucceeds() public {
        uint128 size = 10 ether;
        uint128 closeAmt = 5 ether;
        uint256 indexAfter = 1800 ether;

        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        fundAndDeposit(bob, 50_000 * USDC_UNIT);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, size, 0);
        clearingHouse.addMargin(ETH_PERP, 1980 ether);
        vm.stopPrank();

        setOraclePrice(indexAfter);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 64 ether, 0);

        IClearingHouse.PositionView memory before = getPosition(alice);
        assertLt(indexAfter, before.entryPriceX18);
        assertFalse(isLiquidatable(alice));
        uint256 reservedBefore = clearingHouse._totalReservedMargin(alice);

        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, closeAmt, 0);

        IClearingHouse.PositionView memory afterPos = getPosition(alice);
        assertEq(afterPos.size, int256(uint256(size - closeAmt)));
        // The slice's loss is covered by its own margin share, so the remainder keeps its
        // proportional margin.
        uint256 propMargin = before.margin - (before.margin * closeAmt) / size;
        assertEq(afterPos.margin, propMargin);
        assertEq(clearingHouse._totalReservedMargin(alice), reservedBefore - (before.margin - propMargin));
        assertFalse(isLiquidatable(alice));
    }

    /// @dev Finding 14: closing 1% or 50% of a healthy short after an adverse move used to revert
    /// with IMRBreach because IMR was re-applied to the remaining size at the new price.
    function test_PartialCloseOfShortAfterAdverseMoveSucceeds() public {
        uint128 size = 10 ether;
        uint256 indexAfter = 2015 ether;

        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        fundAndDeposit(bob, 50_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, false, size, 0);

        setOraclePrice(indexAfter);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, true, 13 ether, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);
        assertGt(indexAfter, pos.entryPriceX18);
        assertFalse(isLiquidatable(alice));

        uint128 onePercent = size / 100;
        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, onePercent, 0);
        assertEq(getPosition(alice).size, -int256(uint256(size - onePercent)));

        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, size / 2, 0);
        assertEq(getPosition(alice).size, -int256(uint256(size - onePercent - size / 2)));
        assertFalse(isLiquidatable(alice));
    }

    /// @dev Reductions still enforce maintenance: a reduction that leaves the remainder below MMR reverts.
    function test_PartialCloseStillEnforcesMaintenance() public {
        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        fundAndDeposit(bob, 50_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, false, 10 ether, 0);

        // index rises against the short and bob pushes the vAMM mark well above it
        setOraclePrice(2010 ether);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, true, 40 ether, 0);
        assertFalse(isLiquidatable(alice));

        // closing a large slice at a vAMM price well above the index realizes a loss beyond
        // the slice margin, leaving the remainder below maintenance
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("ImmediatelyLiquidatable()")));
        clearingHouse.closePosition(ETH_PERP, 9 ether, 0);
    }
}
