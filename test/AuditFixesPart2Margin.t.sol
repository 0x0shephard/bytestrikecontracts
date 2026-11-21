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

    // ---------------------------------------------------------------------
    // Finding 15 (+ draft 48): removeMargin enforces the initial margin
    // ---------------------------------------------------------------------

    /// @dev Initial margin of alice's whole position at max(mark, index) and her unrealized loss
    /// at the less favourable of mark and index (0 when in profit).
    function _imrAndLoss(address user) internal view returns (uint256 imrReq, uint256 loss) {
        IClearingHouse.PositionView memory pos = getPosition(user);
        uint256 mark = getMarkPrice();
        uint256 index = oracle.getPrice();
        uint256 absSize = uint256(pos.size > 0 ? pos.size : -pos.size);
        uint256 imrPx = mark > index ? mark : index;
        imrReq = ((absSize * imrPx) / 1e18) * IMR_BPS / 10_000;
        uint256 px = pos.size > 0 ? (mark < index ? mark : index) : (mark > index ? mark : index);
        if (pos.size > 0 && px < pos.entryPriceX18) loss = ((pos.entryPriceX18 - px) * absSize) / 1e18 + 1;
        if (pos.size < 0 && px > pos.entryPriceX18) loss = ((px - pos.entryPriceX18) * absSize) / 1e18 + 1;
    }

    /// @dev Finding 15: removing margin below the initial margin used to pass as long as the
    /// position stayed above maintenance, which let traders bypass the leverage cap.
    function test_RemoveMarginBelowInitialMarginReverts() public {
        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);

        // the position holds exactly its initial margin; removing a tenth of it keeps it far
        // above maintenance but below the initial margin
        uint256 margin = getMargin(alice);
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("IMRBreach()")));
        clearingHouse.removeMargin(ETH_PERP, margin / 10);
    }

    /// @dev Margin above the initial margin can still be removed, down to the IMR (net of unrealized loss).
    function test_RemoveMarginDownToInitialMargin() public {
        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        clearingHouse.addMargin(ETH_PERP, 2_000 ether);
        vm.stopPrank();

        (uint256 imrReq, uint256 loss) = _imrAndLoss(alice);
        uint256 margin = getMargin(alice);
        uint256 maxRemovable = margin - imrReq - loss;

        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("IMRBreach()")));
        clearingHouse.removeMargin(ETH_PERP, maxRemovable + 2);

        vm.prank(alice);
        clearingHouse.removeMargin(ETH_PERP, maxRemovable - 1);
        assertEq(getMargin(alice), margin - maxRemovable + 1);
    }

    /// @dev Unrealized profit does not count towards the initial margin left behind.
    function test_RemoveMarginIgnoresUnrealizedProfitForIMR() public {
        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        fundAndDeposit(bob, 50_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);

        // price rises: the long is in profit at both mark and index
        setOraclePrice(2_200 ether);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, true, 40 ether, 0);
        IClearingHouse.PositionView memory pos = getPosition(alice);
        assertGt(getMarkPrice(), pos.entryPriceX18);

        (uint256 imrReq,) = _imrAndLoss(alice);
        uint256 margin = getMargin(alice);
        assertLt(margin, imrReq);
        uint256 px = getMarkPrice() < 2_200 ether ? getMarkPrice() : 2_200 ether;
        uint256 profit = (px - pos.entryPriceX18) * 10; // 10 ETH position
        // counting the profit would leave plenty above IMR
        assertGt(margin + profit - 1 ether, imrReq);

        // removing any margin would leave it further below IMR, even though profit covers it
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("IMRBreach()")));
        clearingHouse.removeMargin(ETH_PERP, 1 ether);
    }

    /// @dev Draft finding 48: with under-backed quote collateral, the post-removal margin is valued
    /// against the post-removal reserved sum, so a removal that leaves the position fully backed
    /// and above IMR is accepted in one call.
    function test_RemoveMarginValuesAgainstPostRemovalReserved() public {
        fundAndDeposit(alice, 3_000 * USDC_UNIT);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        // reserve almost the whole balance
        uint256 free = getCollateralBalance(alice) - clearingHouse._totalReservedMargin(alice);
        clearingHouse.addMargin(ETH_PERP, free - 1 ether);
        vm.stopPrank();

        // quote token depegs: the vault balance is now worth less than the reserved margin
        vm.prank(admin);
        oracle.setSymbolPrice("USDC", 0.9e18);
        uint256 vaultValue = (getCollateralBalance(alice) * 9) / 10;
        uint256 reserved = clearingHouse._totalReservedMargin(alice);
        assertLt(vaultValue, reserved);

        (uint256 imrReq, uint256 loss) = _imrAndLoss(alice);
        uint256 margin = getMargin(alice);
        uint256 remaining = imrReq + loss + 10 ether;
        uint256 amount = margin - remaining;
        // after removal the remaining margin is fully backed
        assertGe(vaultValue, reserved - amount);
        // valuing it against the pre-removal reserved sum would put it below IMR
        assertLt((remaining * vaultValue) / reserved, imrReq + loss);

        vm.prank(alice);
        clearingHouse.removeMargin(ETH_PERP, amount);
        assertEq(getMargin(alice), remaining);
        assertFalse(isLiquidatable(alice));
    }
}
