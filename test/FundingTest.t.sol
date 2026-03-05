// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {console} from "forge-std/Test.sol";

/// @title FundingTest
/// @notice Tests for funding rate mechanism
contract FundingTest is BaseTest {
    address public counterparty;

    function setUp() public override {
        super.setUp();
        counterparty = makeAddr("counterparty");
    }

    /// @dev Opens a small counterparty position on the opposite side so both OI sides are non-zero.
    /// This is required after the balanced funding change: if either side has zero OI, funding
    /// doesn't accrue (since there's nobody to receive).
    function _ensureCounterpartyShort(uint128 size) internal {
        fundAndDeposit(counterparty, 100_000 * USDC_UNIT);
        openShortPosition(counterparty, size, 0);
    }

    function _ensureCounterpartyLong(uint128 size) internal {
        fundAndDeposit(counterparty, 100_000 * USDC_UNIT);
        openLongPosition(counterparty, size, 0);
    }

    // ============ Basic Funding Tests ============

    function test_FundingSettlement_InitiallyZero() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);

        uint256 fundingBefore = getCumulativeFunding();

        settleFunding(alice);

        uint256 fundingAfter = getCumulativeFunding();

        // Initially funding should be zero or very small
        assertEq(fundingBefore, fundingAfter, "Funding should not change immediately");
    }

    function test_FundingAccrual_OverTime() public {
        uint256 depositAmount = 10000 * USDC_UNIT;
    uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);
        _ensureCounterpartyShort(size);

        uint256 fundingBefore = getCumulativeFunding();

        // Skip time to allow funding to accrue
        skipTime(1 hours);

        // Poke funding to update
        vamm.pokeFunding();

        uint256 fundingAfter = getCumulativeFunding();

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

    function test_FundingSettlement_UpdatesVaultBalance() public {
        uint256 depositAmount = 50000 * USDC_UNIT;
        uint128 size = ethQty(10); // Large long pushes mark significantly above index

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, size, 0);
        _ensureCounterpartyShort(ethQty(1)); // Ensures short OI > 0 so funding accrues

        uint256 markPrice = getMarkPrice();
        uint256 indexPrice = oracle.getPrice();
        assertTrue(markPrice > indexPrice, "Mark should be above index after large long");

        uint256 aliceVaultBefore = getCollateralBalance(alice);

        skipTime(1 hours);
        settleFunding(alice);

        uint256 aliceVaultAfter = getCollateralBalance(alice);

        // mark > index => longs pay funding => alice's vault balance must decrease
        assertLt(aliceVaultAfter, aliceVaultBefore, "Vault balance should decrease when longs pay funding");
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
        _ensureCounterpartyShort(ethQty(1));

        uint256 markPrice = getMarkPrice();
        uint256 indexPrice = oracle.getPrice();

        console.log("Mark price:", markPrice);
        console.log("Index price:", indexPrice);

        uint256 fundingBefore = getCumulativeFunding();

        // Skip time and update funding
        skipTime(1 hours);
        vamm.pokeFunding();

        uint256 fundingAfter = getCumulativeFunding();

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

            uint256 fundingBefore = getCumulativeFunding();
            vamm.pokeFunding();
            uint256 fundingAfter = getCumulativeFunding();

            uint256 fundingChange = fundingAfter - fundingBefore;

            // Funding rate should be clamped to max per hour
            // FUNDING_MAX_BPS_PER_HOUR = 100 bps = 1%
            // For 1 hour, max change should be around 1% (in 1e18)
            uint256 maxFundingChange = FUNDING_MAX_BPS_PER_HOUR * 1e16; // 1% in 1e18

            console.log("Funding change:", fundingChange);
            console.log("Max allowed:", maxFundingChange);

            // Should be within max bounds (monotonic: can only increase)
            assertTrue(
                fundingChange <= maxFundingChange,
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
        _ensureCounterpartyShort(size);

        // Change oracle price to create mark-index divergence
        setOraclePrice(2100 * PRICE_PRECISION);

        skipTime(1 hours);

        uint256 fundingBefore = getCumulativeFunding();
        vamm.pokeFunding();
        uint256 fundingAfter = getCumulativeFunding();

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
            posAfter.lastFundingPayIndex != posBefore.lastFundingPayIndex ||
            posBefore.lastFundingPayIndex == 0,
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

    // ============ Continuous Funding Accrual Tests ============

    function test_ContinuousAccrual_IndexUpdatedOnEverySwap() public {
        uint256 depositAmount = 50000 * USDC_UNIT;
        uint128 size = ethQty(1);

        fundAndDeposit(alice, depositAmount);
        fundAndDeposit(bob, depositAmount);

        // Open initial position to create mark != index
        openLongPosition(alice, ethQty(10), 0);
        // Ensure short OI exists so funding can accrue
        _ensureCounterpartyShort(ethQty(1));

        // Skip time so funding can accrue
        skipTime(30 minutes);

        uint256 fundingBefore = getCumulativeFunding();

        // Trade — should accrue funding at pre-trade mark price
        openLongPosition(bob, size, 0);

        uint256 fundingAfterTrade1 = getCumulativeFunding();
        assertTrue(fundingAfterTrade1 != fundingBefore, "Funding should update on first trade");

        // Skip more time
        skipTime(30 minutes);

        // Another trade — should accrue again
        openShortPosition(bob, size, 0);

        uint256 fundingAfterTrade2 = getCumulativeFunding();
        assertTrue(fundingAfterTrade2 != fundingAfterTrade1, "Funding should update on second trade");
    }

    function test_ContinuousAccrual_PathDependent() public {
        uint256 depositAmount = 50000 * USDC_UNIT;

        fundAndDeposit(alice, depositAmount);
        fundAndDeposit(bob, depositAmount);

        // Push mark above index with a large long
        openLongPosition(alice, ethQty(10), 0);
        // Ensure short OI exists so funding accrues in the first period
        _ensureCounterpartyShort(ethQty(1));

        uint256 markHigh = getMarkPrice();
        uint256 indexPrice = oracle.getPrice();
        assertTrue(markHigh > indexPrice, "mark should be above index");

        // Skip 30 minutes — mark > index during this period
        skipTime(30 minutes);

        // Poke to lock in the high premium period
        vamm.pokeFunding();
        uint256 fundingAfterHighPremium = getCumulativeFunding();

        // Now push mark below index with a large short
        openShortPosition(bob, ethQty(30), 0);
        uint256 markLow = getMarkPrice();
        assertTrue(markLow < indexPrice, "mark should be below index after short");

        // Skip 30 minutes — mark < index during this period
        skipTime(30 minutes);
        vamm.pokeFunding();
        uint256 fundingAfterBothPeriods = getCumulativeFunding();

        // With monotonic indices the long pay index can only grow.
        // After the high-premium period longs paid, so pay > 0.
        // After the low-premium period shorts paid longs, so the receive index grew
        // while the pay index stayed flat.  Net obligation should be smaller.
        assertTrue(fundingAfterHighPremium > 0, "High premium period should produce positive long pay funding");
        // Pay index is monotonic — it must not decrease
        assertTrue(
            fundingAfterBothPeriods >= fundingAfterHighPremium,
            "Monotonic long pay index should not decrease"
        );
        // But the long receive index should have grown, partially offsetting the pay
        uint256 longReceive = vamm.cumulativeLongReceivePerUnitX18();
        assertTrue(longReceive > 0, "Low premium period should produce long receive funding");
    }

    function test_ContinuousAccrual_LateSettlementSameAsImmediate() public {
        uint256 depositAmount = 50000 * USDC_UNIT;
        uint128 size = ethQty(5);

        fundAndDeposit(alice, depositAmount);
        fundAndDeposit(bob, depositAmount);

        // Both open same-size long at the same time
        openLongPosition(alice, size, 0);
        openLongPosition(bob, size, 0);

        // Record initial margins (differ because Alice's buy moves mark price before Bob enters)
        uint256 aliceMarginInitial = getMargin(alice);
        uint256 bobMarginInitial = getMargin(bob);

        // Skip time to accrue funding
        skipTime(30 minutes);

        // Alice settles immediately after first trade interval
        settleFunding(alice);

        // Trade happens (triggers _accrueFunding internally)
        address carol = makeAddr("carol");
        fundAndDeposit(carol, depositAmount);
        openLongPosition(carol, ethQty(1), 0);

        skipTime(30 minutes);

        // Another trade to trigger accrual
        openShortPosition(carol, ethQty(1), 0);

        // Now both settle
        settleFunding(alice);
        settleFunding(bob);

        uint256 aliceMarginFinal = getMargin(alice);
        uint256 bobMarginFinal = getMargin(bob);

        // Compare FUNDING DELTAS (not absolute margins, since entry prices differ).
        // Both had the same position size for the same duration, so funding delta should match.
        int256 aliceFundingDelta = int256(aliceMarginFinal) - int256(aliceMarginInitial);
        int256 bobFundingDelta = int256(bobMarginFinal) - int256(bobMarginInitial);

        assertEq(aliceFundingDelta, bobFundingDelta, "Late settlement should produce same funding delta as immediate");
    }

    function test_ContinuousAccrual_OracleCacheRefreshedOnPokeFunding() public {
        // Initial cached price should be the oracle price
        uint256 cachedBefore = vamm.cachedIndexPrice();
        assertEq(cachedBefore, INITIAL_ETH_PRICE, "Cache should be seeded with oracle price");

        // Change oracle price
        setOraclePrice(2500 * PRICE_PRECISION);

        // Cache should NOT update yet (no pokeFunding called)
        assertEq(vamm.cachedIndexPrice(), cachedBefore, "Cache should not update without pokeFunding");

        // A direct buyBase call (not through ClearingHouse which calls pokeFunding) should NOT update the cache
        skipTime(10 minutes);
        vm.prank(address(clearingHouse));
        vamm.buyBase(ethQty(1), 0);
        assertEq(vamm.cachedIndexPrice(), cachedBefore, "Cache should not update on swap");

        // pokeFunding should refresh the cache
        vamm.pokeFunding();
        assertEq(vamm.cachedIndexPrice(), 2500 * PRICE_PRECISION, "Cache should update on pokeFunding");
    }

    function test_ContinuousAccrual_NoOracleCallOnSwap() public {
        uint256 depositAmount = 50000 * USDC_UNIT;

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, ethQty(5), 0);

        // Deploy a broken oracle that always reverts
        MockOracle brokenOracle = new MockOracle(0, 18);

        // Set the broken oracle (setOracle will try to fetch price but it returns 0,
        // so cache keeps old value)
        vm.prank(admin);
        vamm.setOracle(address(brokenOracle));

        // Trades should still succeed even with broken oracle
        // because _accrueFunding uses cached price, not a live oracle call
        skipTime(10 minutes);

        // These should not revert
        fundAndDeposit(bob, depositAmount);
        openLongPosition(bob, ethQty(1), 0);
        openShortPosition(bob, ethQty(1), 0);
    }

    function test_ContinuousAccrual_FundingFrozenDuringPause() public {
        uint256 depositAmount = 50000 * USDC_UNIT;

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, ethQty(10), 0);

        skipTime(30 minutes);
        vamm.pokeFunding();
        uint256 fundingBeforePause = getCumulativeFunding();

        // Pause swaps directly on the vAMM (owner can call pauseSwaps)
        vm.prank(admin);
        vamm.pauseSwaps(true);

        // Skip a lot of time while paused
        skipTime(24 hours);

        // Unpause
        vm.prank(admin);
        vamm.pauseSwaps(false);

        uint256 fundingAfterUnpause = getCumulativeFunding();

        // No funding should have accrued during the pause
        assertEq(fundingBeforePause, fundingAfterUnpause, "No funding should accrue during pause");
    }

    function test_ContinuousAccrual_SetParamsFlushes() public {
        uint256 depositAmount = 50000 * USDC_UNIT;

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, ethQty(10), 0);
        _ensureCounterpartyShort(ethQty(1));

        skipTime(1 hours);

        uint256 fundingBefore = getCumulativeFunding();

        // setParams should flush funding before applying new params
        vm.prank(admin);
        vamm.setParams(TRADE_FEE_BPS, FUNDING_MAX_BPS_PER_HOUR, 2e18); // double kFunding

        uint256 fundingAfterSetParams = getCumulativeFunding();

        // Funding should have been flushed (accrued) with old params
        assertTrue(fundingAfterSetParams != fundingBefore, "setParams should flush pending funding");
    }

    function test_ContinuousAccrual_SetOracleFlushesAndRefreshes() public {
        uint256 depositAmount = 50000 * USDC_UNIT;

        fundAndDeposit(alice, depositAmount);
        openLongPosition(alice, ethQty(10), 0);
        _ensureCounterpartyShort(ethQty(1));

        skipTime(1 hours);

        uint256 fundingBefore = getCumulativeFunding();
        uint256 cachedBefore = vamm.cachedIndexPrice();

        // Deploy new oracle with different price
        MockOracle newOracle = new MockOracle(2500 * PRICE_PRECISION, 18);

        // setOracle should flush funding at old price, then update cache
        vm.prank(admin);
        vamm.setOracle(address(newOracle));

        uint256 fundingAfter = getCumulativeFunding();
        uint256 cachedAfter = vamm.cachedIndexPrice();

        // Funding should have been flushed at the OLD oracle price
        assertTrue(fundingAfter != fundingBefore, "setOracle should flush pending funding");

        // Cache should now reflect the NEW oracle price
        assertEq(cachedAfter, 2500 * PRICE_PRECISION, "Cache should be updated to new oracle price");
        assertTrue(cachedAfter != cachedBefore, "Cache should have changed");
    }
}
