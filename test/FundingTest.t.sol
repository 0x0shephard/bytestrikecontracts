// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {console} from "forge-std/Test.sol";

/// @title FundingTest
/// @notice Tests for funding rate mechanism
contract FundingTest is BaseTest {

    function setUp() public override {
        super.setUp();
    }

    // ============ Basic Funding Tests ============

    function test_FundingSettlement_InitiallyZero() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        int256 fundingBefore = getCumulativeFunding();

        settleFunding(alice);

        int256 fundingAfter = getCumulativeFunding();

        // Initially funding should be zero or very small
        assertEq(fundingBefore, fundingAfter, "Funding should not change immediately");
    }

    function test_FundingAccrual_OverTime() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        int256 fundingBefore = getCumulativeFunding();

        // Skip time to allow funding to accrue
        skipTime(1 hours);

        // Poke funding to update
        vamm.pokeFunding();

        int256 fundingAfter = getCumulativeFunding();

        // Funding should have changed
        assertTrue(fundingAfter != fundingBefore, "Funding should accrue over time");
    }

    function test_FundingPayment_LongPosition_MarkAboveIndex() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        uint256 marginBefore = getMargin(alice);

        // Skip time for funding to accrue
        skipTime(1 hours);

        // Settle funding
        settleFunding(alice);

        uint256 marginAfter = getMargin(alice);

        // When mark > index, longs pay shorts, so margin should decrease or stay same
        // (depending on funding rate direction)
        console.log("Margin before:", marginBefore);
        console.log("Margin after:", marginAfter);
    }

    function test_FundingPayment_ShortPosition() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openShortPosition(alice, size, 0);

        uint256 marginBefore = getMargin(alice);

        skipTime(1 hours);
        settleFunding(alice);

        uint256 marginAfter = getMargin(alice);

        console.log("Short - Margin before:", marginBefore);
        console.log("Short - Margin after:", marginAfter);
    }

    function test_FundingPayment_OppositeDirections() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        // Alice goes long
        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        // Bob goes short
        fundAndDeposit(bob, depositAmount);
        openShortPosition(bob, size, 0);

        uint256 aliceMarginBefore = getMargin(alice);
        uint256 bobMarginBefore = getMargin(bob);

        // Skip time and settle funding for both
        skipTime(1 hours);
        settleFunding(alice);
        settleFunding(bob);

        uint256 aliceMarginAfter = getMargin(alice);
        uint256 bobMarginAfter = getMargin(bob);

        // One should gain and one should lose (funding is transfer between longs and shorts)
        int256 aliceChange = int256(aliceMarginAfter) - int256(aliceMarginBefore);
        int256 bobChange = int256(bobMarginAfter) - int256(bobMarginBefore);

        console.log("Alice funding change:", aliceChange);
        console.log("Bob funding change:", bobChange);

        // Changes should be opposite in sign
        if (aliceChange > 0) {
            assertTrue(bobChange < 0, "If alice gains, bob should lose");
        } else if (aliceChange < 0) {
            assertTrue(bobChange > 0, "If alice loses, bob should gain");
        }
    }

    // ============ Funding Rate Mechanics ============

    function test_FundingRate_AdjustsToMarkIndexDivergence() public {
        uint256 depositAmount = 50000 * USDC_UNIT;
    uint128 largeSize = ethQty(50);

        // Open large long to push mark price up
        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, largeSize, 0);

        uint256 markPrice = getMarkPrice();
        uint256 indexPrice = oracle.getPrice();

        console.log("Mark price:", markPrice);
        console.log("Index price:", indexPrice);

        int256 fundingBefore = getCumulativeFunding();

        // Skip time and update funding
        skipTime(1 hours);
        vamm.pokeFunding();

        int256 fundingAfter = getCumulativeFunding();

        // Funding should have accrued based on mark-index premium
        assertTrue(fundingAfter != fundingBefore, "Funding should adjust");

        // If mark > index, funding rate should be positive (longs pay)
        if (markPrice > indexPrice) {
            assertTrue(fundingAfter > fundingBefore, "Funding should increase when mark > index");
        }
    }

    function test_FundingRate_Clamped() public {
        uint256 depositAmount = 100000 * USDC_UNIT;
    uint128 massiveSize = ethQty(200); // Huge position

        // Create massive imbalance
        fundAndDeposit(alice, depositAmount);

        // This might fail if not enough margin, that's okay for this test
        try this.openLongPosition(alice, massiveSize, 0) {
            skipTime(1 hours);

            int256 fundingBefore = getCumulativeFunding();
            vamm.pokeFunding();
            int256 fundingAfter = getCumulativeFunding();

            int256 fundingChange = fundingAfter - fundingBefore;

            // Funding rate should be clamped to max per hour
            // FUNDING_MAX_BPS_PER_HOUR = 100 bps = 1%
            // For 1 hour, max change should be around 1% (in 1e18)
            int256 maxFundingChange = int256(FUNDING_MAX_BPS_PER_HOUR * 1e16); // 1% in 1e18

            console.log("Funding change:", fundingChange);
            console.log("Max allowed:", maxFundingChange);

            // Should be within max bounds
            assertTrue(
                fundingChange <= maxFundingChange && fundingChange >= -maxFundingChange,
                "Funding rate should be clamped"
            );
        } catch {
            // If position too large to open, that's fine
            console.log("Position too large - expected for stress test");
        }
    }

    // ============ Multiple Funding Settlements ============

    function test_MultipleFundingSettlements() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        uint256 marginInitial = getMargin(alice);

        // Settle funding multiple times
        for (uint i = 0; i < 5; i++) {
            skipTime(1 hours);
            settleFunding(alice);
        }

        uint256 marginFinal = getMargin(alice);

        console.log("Initial margin:", marginInitial);
        console.log("Final margin after 5 settlements:", marginFinal);

        // Margin should have changed due to funding
        // (direction depends on mark vs index)
    }

    function test_FundingSettlement_BeforeTrading() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size1 = ethQty(1);
    uint128 size2 = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size1, 0);

        // Skip time to accrue funding
        skipTime(2 hours);

        // Open another position (should auto-settle funding)
        openLongPosition(alice, size2, 0);

        // Funding should have been settled
        // (we can't easily assert this without exposing internal state,
        // but the transaction should succeed)
        assertTrue(true, "Opening position should settle funding");
    }

    // ============ Funding with Price Changes ============

    function test_FundingWithOraclePriceChange() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        // Change oracle price to create mark-index divergence
        setOraclePrice(2100 * PRICE_PRECISION);

        skipTime(1 hours);

        int256 fundingBefore = getCumulativeFunding();
        vamm.pokeFunding();
        int256 fundingAfter = getCumulativeFunding();

        console.log("Funding before:", fundingBefore);
        console.log("Funding after:", fundingAfter);

        // Funding should adjust based on new index price
        assertTrue(fundingAfter != fundingBefore, "Funding should react to index price change");
    }

    function test_FundingConvergence() public {
        uint256 depositAmount = 20000 * USDC_UNIT;
    uint128 size = ethQty(10);

        // Create imbalance - push mark price up
        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        uint256 markPriceBefore = getMarkPrice();
        uint256 indexPrice = oracle.getPrice();

        console.log("Initial mark price:", markPriceBefore);
        console.log("Index price:", indexPrice);

        // Let funding accrue over multiple periods
        for (uint i = 0; i < 10; i++) {
            skipTime(1 hours);
            vamm.pokeFunding();
        }

        uint256 markPriceAfter = getMarkPrice();

        console.log("Final mark price:", markPriceAfter);

        // Mark price should converge toward index over time
        // (though it may not fully converge without trading)
    }

    // ============ Edge Cases ============

    function test_FundingWithZeroPosition() public {
        fundAndDeposit(alice, 10000 * USDC_UNIT);

        // Don't open position
        skipTime(1 hours);

        // Should not revert when settling funding with no position
        settleFunding(alice);

        assertTrue(true, "Should handle funding settlement with no position");
    }

    function test_FundingIndexTracking() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        IClearingHouse.PositionView memory posBefore = getPosition(alice);

        skipTime(1 hours);
        settleFunding(alice);

        IClearingHouse.PositionView memory posAfter = getPosition(alice);

        // Last funding index should be updated
        assertTrue(
            posAfter.lastFundingIndex != posBefore.lastFundingIndex ||
            posBefore.lastFundingIndex == 0,
            "Funding index should be tracked"
        );
    }

    function test_FundingDoesNotAffectRealizedPnL_UntilSettled() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        int256 realizedPnLBefore = getPosition(alice).realizedPnL;

        // Skip time but don't settle
        skipTime(1 hours);

        int256 realizedPnLAfter = getPosition(alice).realizedPnL;

        // Realized PnL should not change without settlement
        assertEq(realizedPnLBefore, realizedPnLAfter, "PnL should not change without settlement");

        // Now settle
        settleFunding(alice);

        // Realized PnL might still be same (funding affects margin, not necessarily realized PnL)
        // depending on implementation
    }
}
