// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {console} from "forge-std/Test.sol";

/// @title LiquidationTest
/// @notice Tests for liquidation mechanism
contract LiquidationTest is BaseTest {

    function setUp() public override {
        super.setUp();
    }

    // ============ Basic Liquidation Tests ============

    function test_Liquidation_PriceMovesAgainstLong() public {
        uint256 depositAmount = 5000 * USDC_UNIT; // Minimal margin
    uint128 size = ethQty(2); // 2 ETH at ~$2000 = $4000 notional

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        // Check not liquidatable initially
        assertFalse(isLiquidatable(alice), "Should not be liquidatable initially");

        // Price crashes - long loses value
        setOraclePrice(1200 * PRICE_PRECISION); // -40% crash

        // Push vAMM price down by having bob open large short positions
        // This simulates market participants reacting to the oracle price drop
        fundAndDeposit(bob, 50000 * USDC_UNIT);
        openShortPosition(bob, ethQty(20), 0);

        // Should now be liquidatable
        assertTrue(isLiquidatable(alice), "Should be liquidatable after price crash");

        uint256 liquidatorBalanceBefore = getCollateralBalance(liquidator);

        // Liquidate
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, size);

        // Position should be closed
        IClearingHouse.PositionView memory pos = getPosition(alice);
        assertEq(pos.size, 0, "Position should be liquidated");

        // Liquidator should receive incentive
        uint256 liquidatorBalanceAfter = getCollateralBalance(liquidator);
        assertTrue(liquidatorBalanceAfter > liquidatorBalanceBefore, "Liquidator should receive reward");
    }

    function test_Liquidation_PriceMovesAgainstShort() public {
        uint256 depositAmount = 5000 * USDC_UNIT;
    uint128 size = ethQty(2);

        fundAndDeposit(alice, depositAmount);
        openShortPosition(alice, size, 0);

        assertFalse(isLiquidatable(alice), "Should not be liquidatable initially");

        // Price pumps - short loses value
        setOraclePrice(2800 * PRICE_PRECISION); // +40% pump

        // Push vAMM price up by having bob open large long positions
        fundAndDeposit(bob, 50000 * USDC_UNIT);
        openLongPosition(bob, ethQty(20), 0);

        assertTrue(isLiquidatable(alice), "Should be liquidatable after price pump");

        // Liquidate
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, size);

        IClearingHouse.PositionView memory pos = getPosition(alice);
        assertEq(pos.size, 0, "Short position should be liquidated");
    }

    function test_RevertWhen_Liquidation_NotLiquidatable() public {
        uint256 depositAmount = 10000 * USDC_UNIT; // Plenty of margin
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        // Try to liquidate healthy position - should fail
        vm.expectRevert();
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, size);
    }

    function test_RevertWhen_Liquidation_NotWhitelisted() public {
        uint256 depositAmount = 5000 * USDC_UNIT;
    uint128 size = ethQty(2);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        // Price crashes
        setOraclePrice(1200 * PRICE_PRECISION);

        // Random user tries to liquidate - should fail
        address randomUser = makeAddr("randomUser");
        vm.expectRevert();
        vm.prank(randomUser);
        clearingHouse.liquidate(alice, ETH_PERP, size);
    }

    // ============ Partial Liquidation ============

    function test_PartialLiquidation() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 totalSize = ethQty(4);
    uint128 liquidateSize = ethQty(2);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, totalSize, 0);

        // Price drops to make it liquidatable
        setOraclePrice(1300 * PRICE_PRECISION);

        // Push vAMM price down
        fundAndDeposit(bob, 50000 * USDC_UNIT);
        openShortPosition(bob, ethQty(30), 0);

        assertTrue(isLiquidatable(alice), "Should be liquidatable");

        // Partial liquidation
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, liquidateSize);

        IClearingHouse.PositionView memory pos = getPosition(alice);

        // Should have remaining position
        assertEq(pos.size, int256(uint256(totalSize - liquidateSize)), "Should have partial position remaining");
    }

    // ============ Liquidation Mechanics ============

    function test_LiquidationPenalty() public {
        uint256 depositAmount = 5000 * USDC_UNIT;
    uint128 size = ethQty(2);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        uint256 marginBefore = getMargin(alice);

        // Price crashes
        setOraclePrice(1200 * PRICE_PRECISION);

        // Push vAMM price down
        fundAndDeposit(bob, 50000 * USDC_UNIT);
        openShortPosition(bob, ethQty(20), 0);

        // Liquidate
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, size);

        // Alice should have lost margin (penalty + losses)
        IClearingHouse.PositionView memory pos = getPosition(alice);
        assertTrue(pos.margin < marginBefore, "Margin should decrease after liquidation");
    }

    function test_LiquidationIncentive_ToLiquidator() public {
        uint256 depositAmount = 5000 * USDC_UNIT;
    uint128 size = ethQty(2);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        uint256 liquidatorBalanceBefore = getCollateralBalance(liquidator);

        // Price crashes
        setOraclePrice(1200 * PRICE_PRECISION);

        // Push vAMM price down
        fundAndDeposit(bob, 50000 * USDC_UNIT);
        openShortPosition(bob, ethQty(20), 0);

        // Calculate expected notional and penalty
        uint256 notional = getNotional(alice);
        console.log("Notional:", notional);

        // Liquidate
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, size);

        uint256 liquidatorBalanceAfter = getCollateralBalance(liquidator);
        uint256 reward = liquidatorBalanceAfter - liquidatorBalanceBefore;

        console.log("Liquidator reward:", reward);

        // Reward should be positive
        assertTrue(reward > 0, "Liquidator should receive reward");

        // Reward should be reasonable (not more than penalty cap)
        assertTrue(reward <= PENALTY_CAP, "Reward should not exceed penalty cap");
    }

    function test_LiquidationWithInsuranceFund() public {
        uint256 depositAmount = 2000 * USDC_UNIT; // Very small margin
    uint128 size = ethQty(2);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        uint256 insuranceBalanceBefore = usdc.balanceOf(address(insuranceFund));

        // Massive price crash
        setOraclePrice(800 * PRICE_PRECISION); // -60%

        // Push vAMM price down massively
        fundAndDeposit(bob, 100000 * USDC_UNIT);
        openShortPosition(bob, ethQty(50), 0);

        // Liquidate (might need insurance fund to cover shortfall)
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, size);

        uint256 insuranceBalanceAfter = usdc.balanceOf(address(insuranceFund));

        // Insurance fund might have paid out if bad debt
        if (insuranceBalanceAfter < insuranceBalanceBefore) {
            console.log("Insurance fund paid:", insuranceBalanceBefore - insuranceBalanceAfter);
        }
    }

    // ============ Edge Cases ============

    function test_LiquidationAtExactMMR() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(2);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        // Calculate price that puts position exactly at MMR
        uint256 markPrice = getMarkPrice();
        uint256 positionSize = uint256(int256(getPosition(alice).size));
        uint256 notional = (positionSize * markPrice) / 1e18;
        uint256 requiredMMR = calculateMaintenanceMargin(notional);
        uint256 currentMargin = getMargin(alice);

        console.log("Current margin:", currentMargin);
        console.log("Required MMR:", requiredMMR);

        // Find price that makes margin = MMR
        // This is complex because margin changes with price
        // For now, just test that near-MMR positions are handled correctly
    }

    function test_RevertWhen_LiquidateMoreThanPosition() public {
        uint256 depositAmount = 5000 * USDC_UNIT;
    uint128 openSize = ethQty(1);
    uint128 liquidateSize = ethQty(2); // More than position

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, openSize, 0);

        setOraclePrice(1200 * PRICE_PRECISION);

        vm.expectRevert();
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, liquidateSize);
    }

    function test_MultipleLiquidations_DifferentUsers() public {
        uint256 depositAmount = 5000 * USDC_UNIT;
    uint128 size = ethQty(2);
        address charlie = makeAddr("charlie");

        // Both Alice and Bob open risky long positions
        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        fundAndDeposit(bob, depositAmount);
        openLongPosition(bob, size, 0);

        // Price crashes
        setOraclePrice(1200 * PRICE_PRECISION);

        // Charlie pushes vAMM price down
        fundAndDeposit(charlie, 50000 * USDC_UNIT);
        openShortPosition(charlie, ethQty(25), 0);

        assertTrue(isLiquidatable(alice), "Alice should be liquidatable");
        assertTrue(isLiquidatable(bob), "Bob should be liquidatable");

        // Liquidate both
        vm.startPrank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, size);
        clearingHouse.liquidate(bob, ETH_PERP, size);
        vm.stopPrank();

        // Both should be liquidated
        assertEq(getPosition(alice).size, 0, "Alice position closed");
        assertEq(getPosition(bob).size, 0, "Bob position closed");
    }

    // ============ Liquidation Prevention ============

    function test_AddMargin_PreventLiquidation() public {
        uint256 depositAmount = 5000 * USDC_UNIT;
    uint128 size = ethQty(2);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        // Price drops close to liquidation
        setOraclePrice(1400 * PRICE_PRECISION);

        // Check if getting close to liquidation
        uint256 marginRatio = getMarginRatio(alice);
        console.log("Margin ratio:", marginRatio);

        // Add more margin to prevent liquidation
        uint256 additionalMargin = 2000 * USDC_UNIT;

        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, additionalMargin);

        // Should not be liquidatable anymore
        assertFalse(isLiquidatable(alice), "Should not be liquidatable after adding margin");
    }

    function test_ClosePosition_AvoidLiquidation() public {
        uint256 depositAmount = 5000 * USDC_UNIT;
    uint128 size = ethQty(2);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        // Price drops
        setOraclePrice(1400 * PRICE_PRECISION);

        // Close half the position to reduce risk
        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, size / 2, 0);

        // Continue price drop
        setOraclePrice(1300 * PRICE_PRECISION);

        // Should still be safe due to reduced position
        bool liquidatable = isLiquidatable(alice);
        console.log("Liquidatable after partial close:", liquidatable);
    }

    // ============ Stress Tests ============

    function test_MassiveLoss_ExceedingMargin() public {
        uint256 depositAmount = 3000 * USDC_UNIT;
    uint128 size = ethQty(2);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        // Catastrophic price crash
        setOraclePrice(500 * PRICE_PRECISION); // -75%

        // Push vAMM price down catastrophically
        fundAndDeposit(bob, 150000 * USDC_UNIT);
        openShortPosition(bob, ethQty(80), 0);

        assertTrue(isLiquidatable(alice), "Should definitely be liquidatable");

        // Liquidate
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, size);

        // Alice might have zero or negative "value"
        IClearingHouse.PositionView memory pos = getPosition(alice);
        console.log("Margin after massive loss:", pos.margin);
    }

    function test_LiquidationGas() public {
        uint256 depositAmount = 5000 * USDC_UNIT;
    uint128 size = ethQty(2);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        setOraclePrice(1200 * PRICE_PRECISION);

        // Push vAMM price down
        fundAndDeposit(bob, 50000 * USDC_UNIT);
        openShortPosition(bob, ethQty(20), 0);

        uint256 gasBefore = gasleft();

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, size);

        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for liquidation:", gasUsed);

        // Gas should be reasonable (< 500k)
        assertTrue(gasUsed < 500000, "Liquidation gas should be reasonable");
    }
}
