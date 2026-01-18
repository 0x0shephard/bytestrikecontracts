// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

/// @title PositionTest
/// @notice Tests for opening and closing positions
contract PositionTest is BaseTest {

    function setUp() public override {
        super.setUp();
    }

    // ============ Opening Long Positions ============

    function test_OpenLongPosition() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1); // 1 ETH

        fundAndDeposit(alice, depositAmount);

        uint256 balanceBefore = getCollateralBalance(alice);

        openLongPosition(alice, size, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);

        // Assert position is opened
        assertEq(pos.size, int256(uint256(size)), "Position size incorrect");
        assertTrue(pos.entryPriceX18 > 0, "Entry price not set");
        assertTrue(pos.margin > 0, "Margin not set");

        // Collateral balance should decrease as margin is reserved for the position
        // The helper only adds minimum required margin, so some collateral should remain
        assertTrue(getCollateralBalance(alice) < balanceBefore, "Collateral should decrease when margin is reserved");
    }

    function test_OpenLongPosition_AutoMarginWithoutManualAdd() public {
        uint256 depositAmount = 1000 * USDC_UNIT;
        uint128 size = ethQty(1);

        // Deposit collateral without pre-adding margin; rely on auto allocation inside openPosition
        fundAndDeposit(alice, depositAmount);

        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, size, 0);
        vm.stopPrank();

        IClearingHouse.PositionView memory pos = getPosition(alice);
        assertEq(pos.size, int256(uint256(size)), "Position size incorrect");
        assertTrue(pos.margin > 0, "Margin should be auto allocated");
    }

    function test_OpenLongPosition_WithPriceLimit() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
        uint128 size = ethQty(1);
        uint256 priceLimit = 2050 * PRICE_PRECISION; // Allow up to $2050

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, priceLimit);

        IClearingHouse.PositionView memory pos = getPosition(alice);

        // Entry price should be within limit
        assertLe(pos.entryPriceX18, priceLimit, "Entry price exceeds limit");
    }

    function test_RevertWhen_OpenLongPosition_PriceLimitTooLow() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);
        uint256 priceLimit = 1900 * PRICE_PRECISION; // Too low - mark price is ~$2000

        fundAndDeposit(alice, depositAmount);

        // Manually open with price limit to test the revert
        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, 500 * USDC_UNIT); // Sufficient margin

        vm.expectRevert("slippage"); // vAMM error message
        clearingHouse.openPosition(ETH_PERP, true, size, priceLimit);
        vm.stopPrank();
    }

    function test_OpenLongPosition_IncreasesExistingPosition() public {
        uint256 depositAmount = 20000 * USDC_UNIT;
    uint128 size1 = ethQty(1);
    uint128 size2 = ethQty(2);

        fundAndDeposit(alice, depositAmount);

        // Open first position
        openLongPosition(alice, size1, 0);
        uint256 entryPrice1 = getPosition(alice).entryPriceX18;

        // Open second position
        openLongPosition(alice, size2, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);

        // Total size should be sum
        assertEq(pos.size, int256(uint256(size1 + size2)), "Total size incorrect");

        // Entry price should be weighted average (roughly between the two prices)
        assertTrue(pos.entryPriceX18 > entryPrice1, "Entry price should increase");
    }

    function test_RevertWhen_OpenLongPosition_InsufficientMargin() public {
        uint256 depositAmount = USDC_UNIT / 100; // Insufficient for 1 ETH position even before fees
        uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);

    // Manually add insufficient margin and try to open position
        vm.startPrank(alice);
    clearingHouse.addMargin(ETH_PERP, depositAmount); // Add entire (insufficient) deposit

        vm.expectRevert("Insufficient collateral");
        clearingHouse.openPosition(ETH_PERP, true, size, 0);
        vm.stopPrank();
    }

    // ============ Opening Short Positions ============

    function test_OpenShortPosition() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openShortPosition(alice, size, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);

        // Position size should be negative for short
        assertEq(pos.size, -int256(uint256(size)), "Short position should be negative");
        assertTrue(pos.entryPriceX18 > 0, "Entry price not set");
    }

    function test_OpenShortPosition_WithPriceLimit() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);
        uint256 priceLimit = 1950 * PRICE_PRECISION; // Minimum acceptable price

        fundAndDeposit(alice, depositAmount);
        openShortPosition(alice, size, priceLimit);

        IClearingHouse.PositionView memory pos = getPosition(alice);

        // Entry price should be at least the limit
        assertGe(pos.entryPriceX18, priceLimit, "Entry price below limit");
    }

    // ============ Closing Positions ============

    function test_ClosePosition_CompleteLong() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        // Close entire position
        closePosition(alice, size, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);

        // Position should be fully closed
        assertEq(pos.size, 0, "Position not fully closed");
        assertEq(pos.entryPriceX18, 0, "Entry price not cleared");
    }

    function test_ClosePosition_PartialLong() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 totalSize = ethQty(2);
    uint128 closeSize = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, totalSize, 0);

        // Close partial position
        closePosition(alice, closeSize, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);

        // Remaining position
        assertEq(pos.size, int256(uint256(totalSize - closeSize)), "Remaining size incorrect");
    }

    function test_ClosePosition_WithProfit() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
        uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        fundAndDeposit(bob, depositAmount);

        // Alice opens long at ~$2,002
        openLongPosition(alice, size, 0);

        // Bob opens long, pushing vAMM price further up
        openLongPosition(bob, ethQty(2), 0);

        // Now Alice closes at the higher price
        closePosition(alice, size, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);

        // Should have profit since Bob pushed the price up after Alice entered
        assertTrue(pos.realizedPnL > 0, "Should have realized profit");
    }

    function test_ClosePosition_WithLoss() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
        uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        // Price goes down
        setOraclePrice(1800 * PRICE_PRECISION);

        // Close position
        closePosition(alice, size, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);

        // Should have loss
        assertTrue(pos.realizedPnL < 0, "Should have realized loss");
    }

    function test_RevertWhen_ClosePosition_SizeExceedsPosition() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
        uint128 openSize = ethQty(1);
        uint128 closeSize = ethQty(2); // More than opened

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, openSize, 0);

        vm.expectRevert();
        closePosition(alice, closeSize, 0);
    }

    function test_RevertWhen_ClosePosition_NoPosition() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
        uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);

        // Try to close without opening
        vm.expectRevert();
        closePosition(alice, size, 0);
    }

    // ============ Multiple Users ============

    function test_MultipleUsers_IndependentPositions() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
        uint128 size = ethQty(1);

        // Alice opens long
        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        // Bob opens short
        fundAndDeposit(bob, depositAmount);
        openShortPosition(bob, size, 0);

        IClearingHouse.PositionView memory alicePos = getPosition(alice);
        IClearingHouse.PositionView memory bobPos = getPosition(bob);

        // Positions should be independent and opposite
        assertEq(alicePos.size, -bobPos.size, "Positions should be opposite");
        assertTrue(alicePos.margin > 0, "Alice should have margin");
        assertTrue(bobPos.margin > 0, "Bob should have margin");
    }

    // ============ Margin Management ============

    function test_AddMargin() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
        uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        uint256 marginBefore = getMargin(alice);
        uint256 additionalMargin = 1000 * USDC_UNIT;

        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, additionalMargin);

        uint256 marginAfter = getMargin(alice);

        assertEq(marginAfter, marginBefore + additionalMargin, "Margin not added correctly");
    }

    function test_RemoveMargin() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
        uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        uint256 marginBefore = getMargin(alice);
        uint256 removeAmount = 100 * USDC_UNIT;

        // Ensure we're not violating MMR
        uint256 notional = getNotional(alice);
        uint256 requiredMargin = calculateMaintenanceMargin(notional);

        if (marginBefore > requiredMargin + removeAmount) {
            vm.prank(alice);
            clearingHouse.removeMargin(ETH_PERP, removeAmount);

            uint256 marginAfter = getMargin(alice);
            assertEq(marginAfter, marginBefore - removeAmount, "Margin not removed correctly");
        }
    }

    function test_RevertWhen_RemoveMargin_BelowMMR() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
        uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        uint256 marginBefore = getMargin(alice);

        // Try to remove too much
        vm.expectRevert();
        vm.prank(alice);
        clearingHouse.removeMargin(ETH_PERP, marginBefore);
    }

    // ============ Price Impact Tests ============

    function test_LargePosition_PriceImpact() public {
        uint256 depositAmount = 100000 * USDC_UNIT;
        uint128 largeSize = ethQty(50); // Large position (reduced to fit within available margin)

        fundAndDeposit(alice, depositAmount);

        uint256 markPriceBefore = getMarkPrice();

        openLongPosition(alice, largeSize, 0);

        uint256 markPriceAfter = getMarkPrice();

        // Large buy should increase mark price
        assertTrue(markPriceAfter > markPriceBefore, "Mark price should increase");

        // Entry price should be higher than initial mark due to price impact
        IClearingHouse.PositionView memory pos = getPosition(alice);
        assertTrue(pos.entryPriceX18 > markPriceBefore, "Entry price should reflect slippage");
    }

    // ============ Edge Cases ============

    function test_VerySmallPosition() public {
        uint256 depositAmount = 1000 * USDC_UNIT;
        uint128 tinySize = ethQty(1) / 100; // 0.01 ETH

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, tinySize, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);
        assertEq(pos.size, int256(uint256(tinySize)), "Tiny position should work");
    }

    function test_PositionFlip_LongToShort() public {
        uint256 depositAmount = 20000 * USDC_UNIT;
        uint128 initialLong = ethQty(1);
        uint128 closeAndFlip = ethQty(2); // Close 1 ETH, go short 1 ETH

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, initialLong, 0);

        // This should close the long and open a short
        openShortPosition(alice, closeAndFlip, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);

        // Should now have a short position
        assertEq(pos.size, -int256(uint256(initialLong)), "Should have flipped to short");
    }
}
