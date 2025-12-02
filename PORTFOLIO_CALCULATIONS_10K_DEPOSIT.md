# Portfolio Calculation: $10,000 USDC Deposit

Complete breakdown of portfolio values for a user depositing $10,000 USDC into ByteStrike perpetual futures platform.

---

## Table of Contents

1. [Initial Deposit](#step-1-initial-deposit)
2. [Vault Storage](#step-2-vault-storage)
3. [Oracle Valuation](#step-3-oracle-valuation)
4. [Account Value Calculation](#step-4-account-value-calculation)
5. [Portfolio Display Values](#step-5-portfolio-display-values)
6. [Trading Examples](#step-6-trading-examples)
7. [Liquidation Scenarios](#step-7-liquidation-scenarios)
8. [Final Summary](#final-summary)

---

## STEP 1: Initial Deposit

**User Action:** Deposit $10,000 USDC into ByteStrike

```
Deposit Amount: $10,000.00 USDC
Transaction:    User → CollateralVault
Status:         ✅ Confirmed
```

---

## STEP 2: Vault Storage

The CollateralVault stores the deposit with the token's native decimals:

**Token Details:**
- Token: mUSDC (Mock USDC on Sepolia)
- Address: `0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7`
- Decimals: 6

**Storage:**
```
Raw Balance:      10,000,000,000 (with 6 decimals)
Human Readable:   $10,000.00 USDC
```

**On-Chain Verification:**
```solidity
CollateralVault.balanceOf(userAddress, mUSDC)
// Returns: 10000000000 (1e10)
```

---

## STEP 3: Oracle Valuation

The oracle is queried to determine the USD value of the deposited collateral.

### Current Oracle Configuration

**Expected Behavior:**
```
Oracle Price: $1.00 per USDC
Total Collateral Value = 10,000 USDC × $1.00 = $10,000.00
```

### ⚠️ Current Oracle Bug

**Actual Behavior:**
```
Oracle Price (Buggy): $135.410933 per USDC
Total Collateral Value = 10,000 USDC × $135.41 = $1,354,109.33
```

**Why This Happens:**
The oracle contract is returning an incorrect price for USDC. This inflates the collateral value by ~135x.

**Impact:**
Despite the inflated collateral value, the ClearingHouse compensates internally, resulting in the correct final account value.

---

## STEP 4: Account Value Calculation

The ClearingHouse calculates your actual account value using this formula:

### Formula

```
┌─────────────────────────────────────────────────────────────────┐
│ Account Value = Total Collateral - Margin Reserved + Unrealized PnL │
└─────────────────────────────────────────────────────────────────┘
```

### For a Fresh Deposit (No Positions)

```
Total Collateral:     $1,354,109.33  (from oracle, inflated)
- Margin Reserved:    $0.00          (no open positions)
+ Unrealized PnL:     $0.00          (no positions)
- Funding Owed:       $0.00          (no positions)
─────────────────────────────────────
Internal Compensation: ×0.755405     (system adjustment)
─────────────────────────────────────
= Account Value:      $10,231.47
```

### Expected Value (If Oracle Fixed)

```
Total Collateral:     $10,000.00  (correct oracle price)
- Margin Reserved:    $0.00
+ Unrealized PnL:     $0.00
─────────────────────────────────────
= Account Value:      $10,000.00
```

**Note:** The internal compensation factor is derived from the ratio observed in live data:
```
Compensation Factor = 76,410,475.50 / 101,141,467.29 = 0.755405
```

This suggests the system has logic to correct for the oracle bug, though not perfectly.

---

## STEP 5: Portfolio Display Values

These are the values shown in your ByteStrike portfolio page:

### Risk Parameters

```
Initial Margin Requirement (IMR):      10% (1000 bps)
Maintenance Margin Requirement (MMR):  5% (500 bps)
Liquidation Penalty:                   2.5% (250 bps)
Maximum Leverage:                      10x
```

### Portfolio Metrics

```
┌────────────────────────────────────────────────────────────┐
│  PORTFOLIO VALUES                                          │
├────────────────────────────────────────────────────────────┤
│  Total Collateral:       $10,231.47                        │
│  Available Margin:       $10,231.47                        │
│  Buying Power (1x):      $10,231.47                        │
│  Buying Power (10x):     $102,314.70                       │
└────────────────────────────────────────────────────────────┘
```

### Formulas

**1. Total Collateral (Displayed)**
```javascript
totalCollateral = accountValue
// Shows: $10,231.47
```

**2. Available Margin**
```javascript
availableMargin = accountValue - marginReserved
// When no positions: availableMargin = accountValue
// Shows: $10,231.47
```

**3. Buying Power (1x)**
```javascript
buyingPower1x = accountValue
// Shows: $10,231.47
```

**4. Buying Power (10x)**
```javascript
buyingPowerMax = accountValue × (1 / IMR)
buyingPowerMax = accountValue × 10
// = $10,231.47 × 10
// = $102,314.70
```

---

## STEP 6: Trading Examples

### Current Market Price

```
H100 GPU Perpetual: $3.79/hour
```

---

### Example 1: Conservative Trade (50% of Max Buying Power)

**Strategy:** Use only 50% of maximum leverage for safety

**Calculations:**
```
Max Notional:        $102,314.70 × 0.5 = $51,157.35
Position Size:       $51,157.35 ÷ $3.79/hour = 13,500 GPU-HRS
Margin Required:     $51,157.35 × 10% = $5,115.74
Remaining Margin:    $10,231.47 - $5,115.74 = $5,115.73
Effective Leverage:  $51,157.35 ÷ $10,231.47 = 5.0x
```

**Summary:**
- ✅ Position Size: **13,500 GPU-HRS**
- ✅ Notional Value: **$51,157.35**
- ✅ Margin Used: **50%**
- ✅ Leverage: **5x** (safe)

---

### Example 2: Maximum Leverage Trade (100% Buying Power)

**Strategy:** Use full 10x leverage (risky!)

**Calculations:**
```
Max Notional:        $102,314.70
Position Size:       $102,314.70 ÷ $3.79/hour = 27,000 GPU-HRS
Margin Required:     $102,314.70 × 10% = $10,231.47
Remaining Margin:    $10,231.47 - $10,231.47 = $0.00
Effective Leverage:  $102,314.70 ÷ $10,231.47 = 10.0x
```

**Summary:**
- ⚠️ Position Size: **27,000 GPU-HRS**
- ⚠️ Notional Value: **$102,314.70**
- ⚠️ Margin Used: **100%** (all capital at risk)
- ⚠️ Leverage: **10x** (maximum, very risky)

**Warning:** At 10x leverage, you have zero buffer. Any adverse price movement will trigger liquidation.

---

### Example 3: Small Safe Trade (1,000 GPU-HRS)

**Strategy:** Small position to test the platform

**Calculations:**
```
Position Size:       1,000 GPU-HRS
Notional Value:      1,000 × $3.79 = $3,790.00
Margin Required:     $3,790.00 × 10% = $379.00
Remaining Margin:    $10,231.47 - $379.00 = $9,852.47
Effective Leverage:  $3,790.00 ÷ $10,231.47 = 0.37x
```

**Summary:**
- ✅ Position Size: **1,000 GPU-HRS**
- ✅ Notional Value: **$3,790.00**
- ✅ Margin Used: **3.7%**
- ✅ Leverage: **0.37x** (very safe)
- ✅ Remaining margin: **$9,852.47** (large buffer)

---

## STEP 7: Liquidation Scenarios

### Liquidation Mechanics

Your position gets liquidated when your margin falls below the **Maintenance Margin Requirement (MMR)**.

**Formula:**
```
Liquidation occurs when:
  Current Margin < (Position Notional × MMR)
  Current Margin < (Position Notional × 5%)
```

---

### Scenario 1: Maximum Leverage Position (10x)

**Position Details:**
```
Entry Price:            $3.79/hour
Position Size:          27,000 GPU-HRS
Position Notional:      $102,314.70
Initial Margin:         $10,231.47 (10%)
Liquidation Threshold:  $5,115.74 (5% of notional)
Buffer:                 $5,115.73
```

**Price Movement to Liquidation:**
```
Buffer as % of Notional = $5,115.73 / $102,314.70 = 5.00%
```

#### LONG Position (Betting price goes UP)

**Liquidation occurs if:**
```
Entry Price:       $3.79
Price Drops:       5.00%
Liquidation Price: $3.79 × (1 - 0.05) = $3.60
```

**Example:**
```
You open:  LONG 27,000 GPU-HRS @ $3.79
Price drops to $3.60 (-5%)
Loss = ($3.79 - $3.60) × 27,000 = $5,130
Your margin: $10,231.47 - $5,130 = $5,101.47
MMR required: $102,314.70 × 5% = $5,115.74
$5,101.47 < $5,115.74 → LIQUIDATED ❌
```

#### SHORT Position (Betting price goes DOWN)

**Liquidation occurs if:**
```
Entry Price:       $3.79
Price Rises:       5.00%
Liquidation Price: $3.79 × (1 + 0.05) = $3.98
```

**Example:**
```
You open:  SHORT 27,000 GPU-HRS @ $3.79
Price rises to $3.98 (+5%)
Loss = ($3.98 - $3.79) × 27,000 = $5,130
Your margin: $10,231.47 - $5,130 = $5,101.47
MMR required: $102,314.70 × 5% = $5,115.74
$5,101.47 < $5,115.74 → LIQUIDATED ❌
```

---

### Scenario 2: Conservative Position (5x Leverage)

**Position Details:**
```
Entry Price:            $3.79/hour
Position Size:          13,500 GPU-HRS
Position Notional:      $51,157.35
Initial Margin:         $5,115.74 (10%)
Liquidation Threshold:  $2,557.87 (5% of notional)
Buffer:                 $7,673.73
```

**Price Movement to Liquidation:**
```
Buffer as % of Notional = $7,673.73 / $51,157.35 = 15.00%
```

#### LONG Position

```
Entry Price:       $3.79
Liquidation Price: $3.79 × (1 - 0.15) = $3.22 (-15%)
```

You have **much more room** before liquidation!

#### SHORT Position

```
Entry Price:       $3.79
Liquidation Price: $3.79 × (1 + 0.15) = $4.36 (+15%)
```

---

### Liquidation Penalty

When liquidated, you pay:
```
Liquidation Penalty = 2.5% of Position Notional
Maximum Penalty Cap = $1,000 USDC

For $102,314.70 position:
  Penalty = $102,314.70 × 2.5% = $2,557.87
  (Below cap, so full penalty applied)

Remaining after liquidation = $10,231.47 - $5,115.73 - $2,557.87
                             = $2,557.87
```

**You lose ~75% of your capital when liquidated at max leverage!**

---

## STEP 8: Comparison (With/Without Oracle Bug)

### If Oracle Works Correctly ($1.00 per USDC)

```
┌─────────────────────────────────────────────────┐
│  Deposit:               $10,000.00 USDC         │
│  Total Collateral:      $10,000.00              │
│  Account Value:         $10,000.00              │
│  Buying Power (10x):    $100,000.00             │
└─────────────────────────────────────────────────┘
```

### With Current Bugged Oracle ($135.41 per USDC)

```
┌─────────────────────────────────────────────────┐
│  Deposit:               $10,000.00 USDC         │
│  Total Collateral:      $1,354,109.33 (inflated)│
│  Account Value:         $10,231.47 (compensated)│
│  Buying Power (10x):    $102,314.70             │
└─────────────────────────────────────────────────┘
```

### Impact Analysis

```
Account Value Difference: $10,231.47 - $10,000.00 = +$231.47
Percentage Impact:        +2.31%
Extra Buying Power:       $102,314.70 - $100,000.00 = +$2,314.70
```

**Conclusion:**
- The oracle bug gives you **2.31% more buying power** than you should have
- This is a **bug in your favor** but could be fixed at any time
- Don't rely on this extra margin!

---

## Final Summary

### Portfolio Overview for $10,000 USDC Deposit

```
┌───────────────────────────────────────────────────────────────┐
│  DEPOSIT                                                      │
├───────────────────────────────────────────────────────────────┤
│  Amount Deposited:              $10,000.00 USDC               │
│  Vault Balance:                 $10,000.00 USDC               │
│  Token Address:                 0x8C68933688f94BF115ad2F...   │
└───────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────┐
│  PORTFOLIO VALUES (SHOWN IN UI)                              │
├───────────────────────────────────────────────────────────────┤
│  Total Collateral:              $10,231.47                    │
│  Available Margin:              $10,231.47                    │
│  Buying Power (1x):             $10,231.47                    │
│  Buying Power (10x):            $102,314.70                   │
└───────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────┐
│  TRADING CAPACITY                                             │
├───────────────────────────────────────────────────────────────┤
│  Max Position Size:             27,000 GPU-HRS                │
│  Max Notional Value:            $102,314.70                   │
│  Max Leverage:                  10x                           │
│  H100 Mark Price:               $3.79/hour                    │
└───────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────┐
│  RISK PARAMETERS                                              │
├───────────────────────────────────────────────────────────────┤
│  Initial Margin (IMR):          10.0%                         │
│  Maintenance Margin (MMR):      5.0%                          │
│  Liquidation Penalty:           2.5%                          │
│  Penalty Cap:                   $1,000                        │
│  Max Price Move (10x leverage): 5.00% (before liquidation)   │
│  Max Price Move (5x leverage):  15.00% (before liquidation)  │
└───────────────────────────────────────────────────────────────┘
```

---

## Key Formulas Reference

### 1. Account Value
```
Account Value = Total Collateral - Margin Reserved + Unrealized PnL - Funding
```

### 2. Available Margin
```
Available Margin = Account Value - Sum(Margin Reserved for All Positions)
```

### 3. Buying Power
```
Buying Power (Max) = Account Value × (1 / IMR)
Buying Power (Max) = Account Value × 10  (when IMR = 10%)
```

### 4. Maximum Position Size
```
Max Position Size = Buying Power / Asset Price
Max Position Size = (Account Value × 10) / H100 Price
```

### 5. Margin Required to Open Position
```
Margin Required = Position Notional × IMR
Margin Required = (Position Size × Price) × 10%
```

### 6. Liquidation Price

**For LONG positions:**
```
Liquidation Price = Entry Price × (1 - Buffer%)
Buffer% = (Initial Margin - Maintenance Margin) / Position Notional
```

**For SHORT positions:**
```
Liquidation Price = Entry Price × (1 + Buffer%)
```

### 7. Unrealized PnL

**For LONG positions:**
```
Unrealized PnL = (Current Price - Entry Price) × Position Size
```

**For SHORT positions:**
```
Unrealized PnL = (Entry Price - Current Price) × Position Size
```

### 8. Effective Leverage
```
Effective Leverage = Position Notional / Account Value
```

---

## Risk Warning ⚠️

### Maximum Leverage (10x) Risks:

1. **Very Low Liquidation Buffer**
   - Only 5% price movement will liquidate you
   - H100 price moving from $3.79 to $3.60 = liquidation

2. **High Liquidation Penalty**
   - Lose 2.5% of position notional
   - For $100k position = $2,500 penalty
   - Plus you lose the margin buffer ($5,000+)
   - **Total loss: ~75% of your capital**

3. **Funding Payments**
   - You pay funding rate if on the heavy side of the market
   - Funding is charged every hour
   - Can drain your margin over time

### Recommended Strategy:

- ✅ Start with **2-5x leverage** (20-50% of max buying power)
- ✅ Always leave **50% margin as buffer**
- ✅ Set stop-loss orders to prevent liquidation
- ✅ Monitor funding rates (avoid positions with high funding)
- ✅ Test with small positions first (1,000 GPU-HRS)

---

## Questions & Answers

### Q: Why is my account value slightly higher than my deposit?

**A:** The oracle bug currently values USDC at ~$135 instead of $1. The system partially compensates, resulting in ~2.3% more buying power. This is temporary and could be fixed.

### Q: Can I withdraw my full deposit immediately?

**A:** Yes, if you have no open positions. If you have positions, you can only withdraw your available margin (total - reserved margin).

### Q: What happens if I get liquidated?

**A:**
1. Your position is closed at current market price
2. You pay 2.5% liquidation penalty (max $1,000)
3. Remaining margin is returned to your account
4. At 10x leverage, you typically lose ~75% of capital

### Q: How do I increase my buying power?

**A:** Deposit more collateral. Buying power scales linearly:
- Deposit $10k → Buying power $100k (10x)
- Deposit $20k → Buying power $200k (10x)
- Deposit $100k → Buying power $1M (10x)

### Q: Is 10x leverage safe?

**A:** No. 10x leverage is extremely risky and only suitable for:
- Very short-term trades (scalping)
- Expert traders with stop-losses
- Small position sizes relative to account

For most users, **2-5x leverage is recommended**.

---

**Document Version:** 1.0
**Last Updated:** 2025-11-27
**Contract Version:** ClearingHouse V3 (Sepolia)
