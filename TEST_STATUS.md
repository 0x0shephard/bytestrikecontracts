# ByteStrike Test Status

## Summary
**Total Tests:** 49
**Passing:** 33 (67%)
**Failing:** 16 (33%)

Last updated: After fixing decimal precision and oracle issues

## Test Results by Suite

### PositionTest.t.sol (15/20 passing)

#### ✅ Passing Tests
- test_AddMargin
- test_ClosePosition_CompleteLong
- test_ClosePosition_PartialLong
- test_ClosePosition_WithLoss
- test_MultipleUsers_IndependentPositions
- test_OpenLongPosition_IncreasesExistingPosition
- test_OpenLongPosition_WithPriceLimit
- test_OpenShortPosition
- test_OpenShortPosition_WithPriceLimit
- test_PositionFlip_LongToShort
- test_RemoveMargin
- test_RevertWhen_ClosePosition_NoPosition
- test_RevertWhen_ClosePosition_SizeExceedsPosition
- test_RevertWhen_RemoveMargin_BelowMMR
- test_VerySmallPosition

#### ❌ Failing Tests
1. **test_OpenLongPosition** - "Collateral should not change"
   - Issue: Test expects vault collateral to remain unchanged, but margin is now reserved
   - Fix needed: Update assertion to account for margin reservation

2. **test_ClosePosition_WithProfit** - "Should have realized profit"
   - Issue: Realized PnL calculation may need review
   - Fix needed: Investigate PnL realization logic

3. **test_LargePosition_PriceImpact** - "IMR breach after trade"
   - Issue: Trying to open 100 ETH position (~200k notional) with only 100k collateral
   - Fix needed: Increase test deposit amount

4. **test_RevertWhen_OpenLongPosition_InsufficientMargin** - "next call did not revert"
   - Issue: Helper auto-adds all available margin, so insufficient margin tests don't work
   - Fix needed: Create separate helper for testing failures

5. **test_RevertWhen_OpenLongPosition_PriceLimitTooLow** - "next call did not revert"
   - Issue: Similar to above, helper changes test behavior
   - Fix needed: Call openPosition directly in these tests

### FundingTest.t.sol (12/14 passing)

#### ✅ Passing Tests (12)
- test_FundingAccrual_OverTime
- test_FundingDoesNotAffectRealizedPnL_UntilSettled
- test_FundingIndexTracking
- test_FundingPayment_LongPosition_MarkAboveIndex
- test_FundingPayment_OppositeDirections
- test_FundingPayment_ShortPosition
- test_FundingRate_Clamped
- test_FundingSettlement_BeforeTrading
- test_FundingSettlement_InitiallyZero
- test_FundingWithOraclePriceChange
- test_FundingWithZeroPosition
- test_MultipleFundingSettlements

#### ❌ Failing Tests (2)
1. **test_FundingConvergence** - "IMR breach after trade"
   - Issue: Large position (10 ETH) with insufficient collateral (20k)
   - Fix needed: Increase deposit amount

2. **test_FundingRate_AdjustsToMarkIndexDivergence** - "IMR breach after trade"
   - Issue: Large position (50 ETH) with insufficient collateral (50k)
   - Fix needed: Increase deposit amount

### LiquidationTest.t.sol (6/15 passing)

#### ✅ Passing Tests (6)
- test_AddMargin_PreventLiquidation
- test_ClosePosition_AvoidLiquidation
- test_LiquidationAtExactMMR
- test_RevertWhen_LiquidateMoreThanPosition
- test_RevertWhen_Liquidation_NotLiquidatable
- test_RevertWhen_Liquidation_NotWhitelisted

#### ❌ Failing Tests (9)
Most liquidation tests fail because positions are too healthy (not under-collateralized enough to liquidate):

1. **test_Liquidation_PriceMovesAgainstLong** - "Not liquidatable after price crash"
2. **test_Liquidation_PriceMovesAgainstShort** - "Not liquidatable after price pump"
3. **test_LiquidationPenalty** - "Not liquidatable"
4. **test_LiquidationIncentive_ToLiquidator** - "Not liquidatable"
5. **test_LiquidationGas** - "Not liquidatable"
6. **test_PartialLiquidation** - "Not liquidatable"
7. **test_MultipleLiquidations_DifferentUsers** - "Not liquidatable"
8. **test_LiquidationWithInsuranceFund** - "IMR breach" (insufficient initial margin)
9. **test_MassiveLoss_ExceedingMargin** - "IMR breach" (insufficient initial margin)

## Root Causes

### 1. Margin Pre-Allocation Requirement
The ClearingHouse requires margin to be explicitly added to positions via `addMargin()` before trading. This is different from typical perpetual DEXs where collateral is automatically used.

**Impact:**
- Helper functions (openLongPosition, openShortPosition) must add margin before trading
- Tests designed for auto-margin usage don't match current behavior

### 2. Trade Cost Deduction from Position Margin
In `_applyTrade()`, the trade cost (quoteDelta) is deducted from `position.margin` rather than vault balance.

**For longs:**
- quoteDelta is negative (paying for base)
- This decreases position.margin
- User must have pre-funded enough margin to cover trade cost + IMR

**For shorts:**
- quoteDelta is positive (receiving quote)
- This increases position.margin

### 3. Decimal Precision
Fixed issues:
- ✅ Changed test USDC from 6 decimals to 18 decimals to match vAMM
- ✅ Updated PENALTY_CAP to use 18 decimals
- ✅ Updated baseUnit in collateral config to 1e18
- ✅ Added `getPrice(string symbol)` overload to MockOracle

## Recommendations

### Short-term Fixes (Test Adjustments)
1. **Large position tests**: Increase deposit amounts to cover notional + IMR
2. **Liquidation tests**: Decrease deposit amounts to create riskier positions
3. **Collateral change test**: Update assertion to expect margin reservation
4. **Revert tests**: Call ClearingHouse functions directly instead of using helpers

### Medium-term Improvements (Helper Functions)
1. Create separate helpers:
   - `openPositionSafe()` - Adds full collateral as margin
   - `openPositionRisky()` - Adds minimal margin for liquidation tests
   - `openPositionDirect()` - No auto-margin, for testing edge cases

2. Add parameter to existing helpers:
   ```solidity
   function openLongPosition(user, size, priceLimit, marginRatio)
   ```

### Long-term Considerations (Protocol Design)
The current margin model may not match user expectations. Consider:

1. **Auto-margin allocation**: Automatically use vault collateral for trades
2. **Cross-margin by default**: Share collateral across all positions
3. **Separate trade costs**: Deduct costs from vault, not position margin

## Next Steps

1. ✅ Fix decimal precision issues
2. ✅ Fix MockOracle to support symbol parameter
3. ✅ Update test helpers to add margin before trading
4. 🔄 Adjust individual failing tests (in progress)
5. ⏳ Consider protocol-level margin model improvements

## Files Modified
- `test/BaseTest.sol` - Updated USDC decimals, collateral config, helpers
- `test/mocks/MockOracle.sol` - Added getPrice(string) overload
- All test files now inherit fixed setup from BaseTest

## Notes
- Funding tests are performing well (86% pass rate)
- Position tests are solid (75% pass rate)
- Liquidation tests need the most work (40% pass rate) due to margin model differences
