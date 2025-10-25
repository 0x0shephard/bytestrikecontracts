# vAMM (Virtual Automated Market Maker) - Comprehensive Analysis

## Table of Contents
1. [Overview](#overview)
2. [Core Concepts](#core-concepts)
3. [Architecture](#architecture)
4. [Swap Mechanisms](#swap-mechanisms)
5. [TWAP System](#twap-system)
6. [Funding Rate Mechanism](#funding-rate-mechanism)
7. [Identified Bugs and Issues](#identified-bugs-and-issues)
8. [Security Concerns](#security-concerns)
9. [Gas Optimization Opportunities](#gas-optimization-opportunities)

---

## Overview

The vAMM is a **Virtual Automated Market Maker** implementing a Uniswap V2-style constant product formula (`x * y = k`) without actual token reserves. It's designed for perpetual futures trading where:

- **Virtual reserves** (not real tokens) determine pricing
- Only the **Clearinghouse** can execute swaps
- Uses **TWAP** (Time-Weighted Average Price) for funding rate calculations
- Implements **funding rates** to anchor mark price to oracle index price
- Supports **UUPS upgradeability** pattern

---

## Core Concepts

### 1. Virtual Reserves

```solidity
uint256 private reserveBase;   // X (virtual base asset)
uint256 private reserveQuote;  // Y (virtual quote asset, e.g., USD)
```

**Key Points:**
- All values are **1e18-scaled**
- Reserves are **virtual** - no actual tokens are held
- Mark price = `reserveQuote / reserveBase`
- Constant product formula: After each swap, `(X - feeBase) * (Y - feeQuote) ≈ k`

### 2. Mark Price vs Index Price

- **Mark Price**: Current price derived from virtual reserves (`Y/X`)
- **Index Price**: External oracle price (e.g., from Chainlink)
- **TWAP**: Time-weighted average of mark price over a window
- **Funding Rate**: Mechanism to converge mark price to index price

### 3. Fee System

```solidity
uint16 public feeBps; // Fee in basis points (e.g., 10 = 0.1%)
```

- **Fee-on-input** model (Uniswap V2 style)
- Fees accumulate in `_feeGrowthGlobalX128` (Q128 fixed-point)
- Fee accounting uses virtual `_liquidity` as denominator

### 4. Access Control

- **Owner**: Can update parameters, pause swaps, change roles
- **Clearinghouse**: Only address allowed to execute swaps
- **Anyone**: Can call `pokeFunding()` to update funding rates

---

## Architecture

### State Variables

| Variable | Type | Purpose |
|----------|------|---------|
| `reserveBase` | uint256 | Virtual base reserve (X) |
| `reserveQuote` | uint256 | Virtual quote reserve (Y) |
| `feeBps` | uint16 | Trade fee in basis points |
| `frMaxBpsPerHour` | uint256 | Max funding rate per hour (clamp) |
| `kFundingX18` | uint256 | Funding sensitivity factor |
| `observationWindow` | uint32 | Default TWAP window (seconds) |
| `_liquidity` | uint128 | Virtual liquidity for fee accounting |
| `_feeGrowthGlobalX128` | uint256 | Cumulative fee per unit liquidity |
| `_cumulativeFundingPerUnitX18` | int256 | Cumulative funding index |
| `lastFundingTimestamp` | uint64 | Last funding update time |
| `swapsPaused` | bool | Trading pause flag |

### TWAP Ring Buffer

```solidity
struct Observation {
    uint32 timestamp;
    uint256 priceCumulativeX128; // Cumulative sum(priceX128 * dt)
}
Observation[64] private _obs; // Ring buffer (cardinality = 64)
uint16 private _obsIndex;     // Current index
```

---

## Swap Mechanisms

### 1. `swapBaseForQuote()` - Buy Base (Long)

**Purpose**: Trader receives base asset, pays quote

**Formula** (Uniswap V2 inverse):
```
inWithFeeScaled = baseAmount * Y * 10000 / (X - baseAmount)
grossQuoteIn = ceil(inWithFeeScaled / (10000 - feeBps))
```

**Flow**:
1. Calculate quote needed for desired base output
2. Check slippage: `avgPrice <= priceLimitX18`
3. Update reserves: `Y += grossQuoteIn`, `X -= baseAmount`
4. Accumulate fees
5. Return `(+base, -quote, avgPrice)`

**Example**:
- Base reserve (X) = 1,000,000e18
- Quote reserve (Y) = 50,000,000e18
- Buy 1,000e18 base → Pay ~50,050e18 quote (with 0.1% fee)

---

### 2. `swapQuoteForBase()` - Sell Quote for Base

**Purpose**: Trader pays quote to receive base

**Formula** (Uniswap V2 standard):
```
inWithFeeScaled = quoteAmount * (10000 - feeBps)
baseOut = X * inWithFeeScaled / (Y * 10000 + inWithFeeScaled)
```

**Flow**:
1. Calculate base output from quote input
2. Check slippage: `avgPrice <= priceLimitX18`
3. Update reserves: `Y += quoteAmount`, `X -= baseOut`
4. Accumulate fees
5. Return `(+base, -quote, avgPrice)`

---

### 3. `swapSellBaseForQuote()` - Sell Base (Short)

**Purpose**: Trader provides base, receives quote

**Formula**:
```
quoteOut = Y * baseAmount * (10000 - feeBps) / (X * 10000 + baseAmount * (10000 - feeBps))
```

**Flow**:
1. Calculate quote received for base input
2. Check slippage: `avgPrice >= priceLimitX18` (note: minimum price check)
3. Update reserves: `X += baseAmount`, `Y -= quoteOut`
4. Fee converted from base to quote using avgPrice
5. Return `(-base, +quote, avgPrice)`

---

## TWAP System

### Observation Mechanism

The vAMM uses a **ring buffer** of 64 observations to track price over time.

**Key Functions:**

#### `_accumulatePrice()`
Updates the current observation with elapsed time:
```solidity
pxX128 = (priceX18 << 128) / 1e18  // Convert to Q128
dt = now - lastTimestamp
obs[index].priceCumulativeX128 += pxX128 * dt
```

#### `_writeObservation()`
Advances ring buffer after each swap:
```solidity
_accumulatePrice()           // Update current
next = (index + 1) % 64     // Wrap around
_obs[next] = _obs[index]    // Copy to next slot
_obsIndex = next
```

#### `getTwap(uint32 window)`
Calculates TWAP over lookback period:
```solidity
cumNow = current cumulative price
cumPast = cumulative price at (now - window)
twapX128 = (cumNow - cumPast) / window
return (twapX128 * 1e18) >> 128  // Convert back to 1e18
```

**Ring Buffer Search:**
- Scans backward up to 64 observations
- Finds closest observation ≤ targetTimestamp
- Falls back to spot price if insufficient history

---

## Funding Rate Mechanism

### Purpose
Perpetual futures have no expiry, so **funding rates** anchor the mark price to the index (spot) price.

### Calculation (`pokeFunding()`)

```solidity
premium = twapMarkPrice - indexPrice
fundingRate = premium * kFundingX18 * timeElapsed / (24h * 1e18)

// Clamp to max rate
maxRateAbs = frMaxBpsPerHour * timeElapsed * 1e18 / (3600 * 10000)
fundingRate = clamp(fundingRate, -maxRateAbs, +maxRateAbs)

_cumulativeFundingPerUnitX18 += fundingRate
```

**Parameters:**
- `kFundingX18`: Sensitivity multiplier (higher = faster convergence)
- `frMaxBpsPerHour`: Maximum funding rate change per hour (in bps)
- `observationWindow`: TWAP lookback period

**Effect:**
- If mark > index → Longs pay shorts (incentivizes selling)
- If mark < index → Shorts pay longs (incentivizes buying)

---

## Identified Bugs and Issues

### 🔴 CRITICAL

#### 1. **Integer Overflow in TWAP Accumulation**
**Location**: `vAMM.sol:447`, `vAMM.sol:469`

```solidity
_obs[_obsIndex].priceCumulativeX128 += pxX128 * dt;  // Line 447
cum = last.priceCumulativeX128 + pxX128 * dt;        // Line 469
```

**Issue**: `pxX128 * dt` can overflow `uint256` over long periods
- `pxX128` is already left-shifted by 128 bits
- Multiplying by `dt` (seconds) can exceed `type(uint256).max`
- Example: After ~2^96 seconds (~2.5 billion years) at max price

**Likelihood**: Low (requires extreme time/price)
**Impact**: TWAP calculation breaks, funding becomes unreliable

**Fix**: Use checked arithmetic or cap `dt` to reasonable bounds

---

#### 2. **Fee Rounding Inconsistency**
**Location**: `vAMM.sol:157`, `vAMM.sol:194`, `vAMM.sol:234`

```solidity
// swapBaseForQuote (line 157)
uint256 fee = grossQuoteIn - Calculations.mulDiv(grossQuoteIn, 10_000 - feeBps, 10_000);

// swapQuoteForBase (line 194)
uint256 fee = Calculations.mulDiv(grossIn, feeBps, 10_000);

// swapSellBaseForQuote (line 234)
uint256 feeInBase = Calculations.mulDiv(grossBaseIn, feeBps, 10_000);
```

**Issue**: Different fee calculation methods across swaps
- `swapBaseForQuote`: Subtractive (can round down)
- Other swaps: Direct multiplication

**Impact**: Fee accounting inconsistency, potential fee loss over many swaps

**Fix**: Standardize fee calculation method

---

### 🟡 HIGH

#### 3. **TWAP Ring Buffer Edge Case**
**Location**: `vAMM.sol:299-311`

```solidity
while (scanned < OBS_CARDINALITY) {
    Observation memory o = _obs[idx];
    if (o.timestamp == 0) {
        break;  // ❌ Doesn't set 'found'
    }
    obsPast = o;
    if (o.timestamp <= targetTs) {
        found = true;
        break;
    }
    idx = (idx == 0) ? (OBS_CARDINALITY - 1) : (idx - 1);
    scanned++;
}
```

**Issue**: If `o.timestamp == 0` is encountered, loop breaks without setting `found = true`
- Leads to `obsPast.timestamp == 0` check at line 313
- Falls back to spot price even if valid observations exist

**Impact**: TWAP may incorrectly return spot price during sparse observation periods

**Fix**: Set `found = true` before break, or handle empty observations differently

---

#### 4. **Missing Reserve Update Validation**
**Location**: `vAMM.sol:154`, `vAMM.sol:192`, `vAMM.sol:231`

```solidity
reserveQuote = Y - quoteOut;  // Line 231 (no underflow check)
```

**Issue**: No explicit check that `Y >= quoteOut` (relies on Solidity 0.8 revert)
- While Solidity 0.8+ has automatic overflow checks, adding explicit `require` improves clarity
- Large trades could drain reserves below safe thresholds

**Impact**: Potential for reserve manipulation or unexpected reverts

**Recommendation**: Add explicit checks for reserve health thresholds

---

#### 5. **Fee Growth Overflow**
**Location**: `vAMM.sol:159`, `vAMM.sol:196`, `vAMM.sol:237`

```solidity
_feeGrowthGlobalX128 += (fee << 128) / _liquidity;
```

**Issue**: `fee << 128` can overflow if fee is large (> 2^128)
- Unlikely in practice but mathematically possible with extreme trades
- No overflow protection in Q128 conversion

**Impact**: Fee accounting corrupted on extreme trades

**Fix**: Add overflow check or cap fee before left shift

---

### 🟠 MEDIUM

#### 6. **Timestamp Downcast Truncation**
**Location**: `vAMM.sol:119`, `vAMM.sol:438`, `vAMM.sol:463`

```solidity
_obs[0] = Observation({timestamp: uint32(block.timestamp), ...});
uint32 tsNow = uint32(block.timestamp);
```

**Issue**: `block.timestamp` (uint256) downcast to `uint32`
- Overflows in year 2106 (2^32 seconds from Unix epoch)
- System stops functioning correctly after overflow

**Impact**: Contract unusable after 2106

**Recommendation**: Use `uint64` or add future-proofing check

---

#### 7. **Slippage Check Inconsistency**
**Location**: `vAMM.sol:150`, `vAMM.sol:189`, `vAMM.sol:227`

```solidity
// swapBaseForQuote & swapQuoteForBase
require(priceLimitX18 == 0 || avgPriceX18 <= priceLimitX18, "slippage");

// swapSellBaseForQuote
require(priceLimitX18 == 0 || avgPriceX18 >= priceLimitX18, "slippage");
```

**Issue**: Different comparison directions for different swap types
- Buying: `avgPrice <= limit` (max price protection)
- Selling: `avgPrice >= limit` (min price protection)

**Potential Confusion**: Callers must remember which direction applies
- Correct by design, but could benefit from clearer naming

**Recommendation**: Use separate parameter names (`maxPrice`/`minPrice`) for clarity

---

#### 8. **Oracle Price Staleness Not Checked**
**Location**: `vAMM.sol:378`

```solidity
uint256 indexPriceX18 = IOracle(oracle).getPrice();
```

**Issue**: No validation of oracle price freshness or validity
- Assumes oracle always returns valid, recent data
- No fallback if oracle fails or returns stale price

**Impact**: Funding rate calculated from stale/invalid oracle price

**Fix**: Add oracle staleness checks or try-catch pattern

---

#### 9. **Zero Price Edge Cases**
**Location**: Multiple swap functions

**Issue**: No explicit zero-price protection in swap calculations
- If reserves are manipulated to cause `Y/X → 0`, swaps break
- Division by zero prevented by Solidity, but reverts are obscure

**Impact**: Poor UX if edge case is hit

**Recommendation**: Add `require(avgPriceX18 > 0)` checks

---

### 🟢 LOW / INFORMATIONAL

#### 10. **Gas: Redundant Storage Reads**
**Location**: `vAMM.sol:377-378`

```solidity
uint256 twapX18 = getTwap(observationWindow);  // Reads observationWindow
uint256 indexPriceX18 = IOracle(oracle).getPrice();  // Reads oracle
```

**Optimization**: Cache `observationWindow` and `oracle` in memory

---

#### 11. **Reentrancy Risk (Low)**
**Location**: All swap functions

**Issue**: External oracle call in `pokeFunding()` could enable reentrancy
- Current design: Swaps are `onlyCH`, limiting attack surface
- No reentrancy guards present

**Impact**: Low (requires malicious clearinghouse or oracle)

**Recommendation**: Add `nonReentrant` modifier from OpenZeppelin

---

#### 12. **Initialization Gap**
**Location**: `vAMM.sol:480`

```solidity
uint256[50] private __gap;
```

**Issue**: Gap size (50) may be insufficient for future upgrades
- Current state variables: ~15 slots used
- Upgrades adding >50 slots would cause storage collision

**Recommendation**: Document upgrade constraints or increase gap

---

#### 13. **Funding Timestamp Edge Case**
**Location**: `vAMM.sol:372-374`

```solidity
if (nowTs <= lastTs) {
    return; // Funding already up to date
}
```

**Issue**: Silent return if `nowTs == lastTs`
- No event emitted
- Keepers can't distinguish "no update needed" from failure

**Recommendation**: Emit event or return status code

---

#### 14. **Division Before Multiplication**
**Location**: `vAMM.sol:222`

```solidity
uint256 quoteOut = numerator / denominator;
```

**Issue**: Division truncates before final result
- Standard Solidity precision loss
- Acceptable for AMM pricing but could accumulate

**Impact**: Minimal (inherent to fixed-point math)

---

#### 15. **Missing Event Parameters**
**Location**: `vAMM.sol:65`

```solidity
event Swap(address indexed sender, int256 baseDelta, int256 quoteDelta, uint256 avgPriceX18);
```

**Issue**: No `indexed` position identifier or trade direction enum
- Off-chain indexing requires parsing delta signs

**Recommendation**: Add `indexed bytes32 positionId` or direction enum

---

## Security Concerns

### Access Control
✅ **Properly implemented**:
- Owner can't steal funds (no reserves)
- Clearinghouse is single point of trust
- No external token approvals

### Upgrade Safety
⚠️ **Risks**:
- UUPS pattern: Owner can upgrade to malicious implementation
- No timelock on upgrades
- Storage layout changes could corrupt state

**Mitigation**: Add multi-sig ownership + timelock

### Oracle Dependency
⚠️ **Risks**:
- Single oracle address (no fallback)
- No circuit breaker if oracle malfunctions
- Funding rate directly depends on oracle

**Mitigation**: Add oracle staleness checks, multi-oracle aggregation

### Economic Attacks
- **Reserve Manipulation**: No direct attack vector (no token deposits)
- **Funding Rate Manipulation**: Requires manipulating TWAP over `observationWindow`
- **Front-Running**: Clearinghouse controls all swaps (depends on CH design)

---

## Gas Optimization Opportunities

### 1. Pack State Variables
```solidity
// Current (3 slots)
uint16 public feeBps;
uint256 public frMaxBpsPerHour;
uint256 public kFundingX18;

// Optimized (2 slots if values fit)
uint16 public feeBps;
uint64 public frMaxBpsPerHour;  // If max value allows
uint64 public kFundingX18;      // If max value allows
uint32 public observationWindow;
```

### 2. Cache Storage Reads
```solidity
// Before
function pokeFunding() external {
    uint256 twapX18 = getTwap(observationWindow);  // SLOAD
    uint256 indexPriceX18 = IOracle(oracle).getPrice();  // SLOAD

// After
function pokeFunding() external {
    uint32 window = observationWindow;  // Single SLOAD
    address oracleAddr = oracle;         // Single SLOAD
    uint256 twapX18 = getTwap(window);
    uint256 indexPriceX18 = IOracle(oracleAddr).getPrice();
```

### 3. Use `unchecked` for Safe Operations
```solidity
// Line 456 (index increment, always < 64)
unchecked {
    uint16 next = (_obsIndex + 1) % OBS_CARDINALITY;
}
```

### 4. Batch Observation Writes
Current design writes observation after every swap. Consider batching if high-frequency trading is expected.

---

## Summary

### Contract Quality: **B+**

**Strengths:**
✅ Clean implementation of constant product AMM
✅ Comprehensive TWAP system
✅ Flexible funding rate mechanism
✅ Upgradeable architecture

**Weaknesses:**
❌ Integer overflow risks in long-running scenarios
❌ No oracle staleness protection
❌ Timestamp downcast limits lifespan to 2106
❌ Fee calculation inconsistencies

### Critical Action Items:
1. Fix TWAP overflow potential (add caps or use unchecked safely)
2. Standardize fee calculation across swap functions
3. Add oracle price validation/staleness checks
4. Use uint64 for timestamps (not uint32)
5. Add explicit reserve health checks
6. Consider reentrancy guards despite low risk

### Recommended Security Measures:
- Multi-signature ownership
- Timelock for upgrades
- Circuit breaker for extreme market conditions
- Oracle price bounds validation
- Comprehensive integration tests for edge cases

---

## Conclusion

The vAMM is a well-architected virtual AMM suitable for perpetual futures. The identified bugs are mostly edge cases unlikely to occur in normal operation, but should be addressed before mainnet deployment. The funding rate mechanism is elegant, and the TWAP system is robust for most use cases.

**Overall Risk Level**: Medium (due to oracle dependency and timestamp truncation)

**Recommended Next Steps**:
1. Address critical bugs (overflow, timestamp)
2. Add comprehensive testing for edge cases
3. Implement oracle validation layer
4. Conduct professional security audit
5. Test with mainnet-forked simulations
