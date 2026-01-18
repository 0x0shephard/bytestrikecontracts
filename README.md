# ByteStrike Protocol - Audit Documentation

A perpetual futures DEX for trading GPU compute pricing. Traders can hedge or speculate on hourly rental rates for GPUs (H100, H200) across cloud providers.

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Contract Descriptions](#contract-descriptions)
3. [Core Mechanisms](#core-mechanisms)
4. [User Flows](#user-flows)
5. [Risk Parameters](#risk-parameters)
6. [Oracle System](#oracle-system)
7. [Fee Structure](#fee-structure)
8. [Security Considerations](#security-considerations)
9. [Key Invariants](#key-invariants)
10. [Known Limitations](#known-limitations)
11. [Build and Test](#build-and-test)

---

## Architecture Overview

```
                    +------------------+
                    |   ClearingHouse  |  <-- Main entry point for all trading
                    |    (Proxy)       |
                    +--------+---------+
                             |
         +-------------------+-------------------+
         |                   |                   |
+--------v--------+  +-------v-------+  +-------v-------+
| CollateralVault |  | MarketRegistry|  |     vAMM      |
|  (deposits)     |  |  (markets)    |  | (price/swap)  |
+-----------------+  +---------------+  +-------+-------+
                                                |
                     +----------------+---------+
                     |                |
              +------v------+  +------v------+
              |  FeeRouter  |  | InsuranceFund|
              | (fee split) |  | (bad debt)   |
              +-------------+  +-------------+
```

### Contract Deployment Pattern
- **ClearingHouse**: UUPS Upgradeable Proxy
- **vAMM**: UUPS Upgradeable Proxy (one per market)
- **All others**: Non-upgradeable

---

## Contract Descriptions

### ClearingHouse.sol
**Location**: `src/ClearingHouse.sol`

**Purpose**: Central orchestrator for all trading operations.

**Responsibilities**:
- Deposit/withdraw collateral routing
- Position opening/closing
- Margin management (add/remove)
- Liquidation execution
- Funding rate settlement
- Risk parameter enforcement

**Key State**:
```solidity
mapping(bytes32 marketId => mapping(address user => Position)) public positions;
mapping(bytes32 marketId => RiskParams) public marketRiskParams;
mapping(address user => bytes32[] marketIds) private _userActiveMarkets;
mapping(address user => mapping(bytes32 marketId => bool)) private _isMarketActive;
```

**Position Structure**:
```solidity
struct Position {
    int256 size;              // Positive = long, negative = short
    uint256 margin;           // Collateral backing this position
    uint256 entryPriceX18;    // Weighted average entry price (18 decimals)
    int256 lastFundingIndex;  // Funding index at last settlement
    int256 realizedPnL;       // Accumulated realized profit/loss
}
```

**Risk Parameters Structure**:
```solidity
struct RiskParams {
    uint256 imrBps;                  // Initial Margin Requirement in basis points
    uint256 mmrBps;                  // Maintenance Margin Requirement in basis points
    uint256 liquidationPenaltyBps;   // Penalty charged on liquidation
    uint256 penaltyCap;              // Maximum penalty amount
    uint256 maxPositionSize;         // Maximum position per user (0 = unlimited)
    uint256 minPositionSize;         // Minimum position size
}
```

**Access Control**:
- `admin`: Can set risk parameters, pause markets, whitelist liquidators
- `whitelistedLiquidator`: Can execute liquidations
- Anyone: Can deposit, trade, withdraw (with restrictions)

---

### CollateralVault.sol
**Location**: `src/CollateralVault.sol`

**Purpose**: Custody and accounting of user collateral.

**Responsibilities**:
- Hold deposited tokens
- Track per-user, per-token balances
- Apply haircuts to non-stablecoin collateral
- Provide collateral value in USD

**Key State**:
```solidity
mapping(address user => mapping(address token => uint256)) public userBalances;
mapping(address token => CollateralConfig) public collateralConfigs;
address public clearinghouse;  // Only authorized caller for withdrawFor
address public oracle;         // For collateral price lookup
```

**Collateral Configuration**:
```solidity
struct CollateralConfig {
    address token;
    uint256 baseUnit;        // Token decimals (1e6 for USDC, 1e18 for ETH)
    uint16 haircutBps;       // Discount for volatile collateral (0 for stables)
    uint16 liqIncentiveBps;  // Bonus to liquidator
    uint256 cap;             // Max total deposits
    uint256 accountCap;      // Max per-account deposits
    bool enabled;
    bool depositPaused;
    bool withdrawPaused;
    string oracleSymbol;     // For price lookup
}
```

**Fee-on-Transfer Support**: Uses balance-delta pattern for accurate accounting with deflationary tokens:
```solidity
function withdrawFor(...) external returns (uint256 received) {
    uint256 balanceBefore = IERC20(token).balanceOf(to);
    IERC20(token).safeTransfer(to, amount);
    received = IERC20(token).balanceOf(to) - balanceBefore;
}
```

---

### MarketRegistry.sol
**Location**: `src/MarketRegistry.sol`

**Purpose**: Registry of all perpetual markets and their configurations.

**Key State**:
```solidity
struct Market {
    bytes32 marketId;
    address vamm;
    address oracle;
    address baseAsset;
    address quoteToken;
    uint256 baseUnit;
    uint16 feeBps;
    address feeRouter;
    address insuranceFund;
    bool paused;
}
mapping(bytes32 => Market) public markets;
bytes32[] public marketIds;
```

**Access Control**: `MARKET_ADMIN_ROLE` required for adding/modifying markets.

---

### vAMM.sol
**Location**: `src/vAMM.sol`

**Purpose**: Virtual AMM providing price discovery and trade execution.

**AMM Model**: Constant product (x * y = k) similar to Uniswap V2.

**Key State**:
```solidity
uint256 public baseReserve;     // Virtual base tokens (GPU hours)
uint256 public quoteReserve;    // Virtual quote tokens (USD)
uint128 public liquidity;       // Scaling factor for k

// Funding rate
int256 public cumulativeFundingPerUnitX18;  // Accumulated funding rate
uint256 public lastFundingTime;              // Last funding calculation timestamp

// TWAP
uint256[64] public observations;  // Ring buffer for TWAP
uint8 public observationIndex;
uint32 public observationWindow;  // TWAP window in seconds

// Parameters
uint16 public feeBps;             // Swap fee
uint256 public frMaxBpsPerHour;   // Max funding rate per hour
uint256 public kFundingX18;       // Funding rate sensitivity
```

**Price Calculation**:
```solidity
markPrice = quoteReserve * 1e18 / baseReserve
```

**Swap Execution (Long/Buy Base)**:
```solidity
// For buying `baseOut` units of base:
quoteIn = (baseOut * quoteReserve) / (baseReserve - baseOut)
// Fee applied: actualQuoteIn = quoteIn * (10000 + feeBps) / 10000

// Reserve updates:
baseReserve -= baseOut
quoteReserve += quoteIn
```

**Swap Execution (Short/Sell Base)**:
```solidity
// For selling `baseIn` units of base:
quoteOut = (baseIn * quoteReserve) / (baseReserve + baseIn)
// Fee applied: actualQuoteOut = quoteOut * (10000 - feeBps) / 10000

// Reserve updates:
baseReserve += baseIn
quoteReserve -= quoteOut
```

**Funding Rate Mechanism**:
```solidity
// Calculated every time funding is settled
premiumFraction = (markPrice - oraclePrice) * 1e18 / oraclePrice
fundingRate = clamp(kFundingX18 * premiumFraction / 1e18, -frMaxBpsPerHour, +frMaxBpsPerHour)
cumulativeFundingPerUnitX18 += fundingRate * elapsedHours
```

---

### FeeRouter.sol
**Location**: `src/FeeRouter.sol`

**Purpose**: Routes trading fees between insurance fund and treasury.

**Key State**:
```solidity
address public quoteToken;
address public insuranceFund;
address public treasury;
address public clearingHouse;
uint16 public tradeToFundBps;    // % of trade fees to insurance (e.g., 5000 = 50%)
uint16 public liqToFundBps;      // % of liquidation penalties to insurance
```

**Fee Distribution Flow**:
1. ClearingHouse collects fee from trader
2. ClearingHouse transfers fee to FeeRouter
3. FeeRouter splits: `tradeToFundBps` to InsuranceFund, remainder to Treasury

**Fee-on-Transfer Support**:
```solidity
function onTradeFee(uint256 amount) external onlyCH {
    uint256 actualBalance = IERC20(quoteToken).balanceOf(address(this));
    uint256 actualAmount = actualBalance < amount ? actualBalance : amount;
    // Split actualAmount, not expected amount
}
```

---

### InsuranceFund.sol
**Location**: `src/InsuranceFund.sol`

**Purpose**: Backstop for bad debt during liquidations.

**Key State**:
```solidity
address public quoteToken;
mapping(address => bool) public isFeeRouter;
mapping(address => bool) public isAuthorized;
```

**Responsibilities**:
- Receive fees from FeeRouter
- Cover bad debt when liquidation results in negative equity
- Track total fund balance

**Graceful Degradation**: If insurance fund has insufficient balance for bad debt coverage, it pays what it can rather than reverting:
```solidity
function withdraw(uint256 amount) external onlyAuthorized returns (uint256 actual) {
    uint256 balance = IERC20(quoteToken).balanceOf(address(this));
    actual = amount > balance ? balance : amount;
    if (actual > 0) {
        IERC20(quoteToken).safeTransfer(msg.sender, actual);
    }
}
```

---

## Core Mechanisms

### Position Lifecycle

#### 1. Opening a Position
```
User calls: clearingHouse.openPosition(marketId, isLong, size, priceLimit)

Flow:
1. Settle any pending funding for user
2. Check user has no liquidatable positions in any market
3. Check size >= minPositionSize and (maxPositionSize == 0 || size <= maxPositionSize)
4. Get market config from MarketRegistry
5. Execute swap on vAMM:
   - Long: Buy base (size), pay quote
   - Short: Sell base (size), receive quote
6. Apply slippage check against priceLimit
7. Calculate fees: (size * executionPrice * feeBps / 10000)
8. Update position state:
   - size += deltaSize (positive for long, negative for short)
   - Update entry price (weighted average for same-direction increase)
   - Record funding index
9. Calculate required margin: (notionalValue * imrBps / 10000)
10. Verify: position.margin >= requiredMargin
11. Route fees to FeeRouter
12. Track user in _userActiveMarkets if new position
```

#### 2. Closing a Position
```
User calls: clearingHouse.closePosition(marketId, size, priceLimit)

Flow:
1. Settle pending funding
2. Verify size <= |position.size|
3. Execute reverse swap on vAMM:
   - Long closing: Sell base, receive quote
   - Short closing: Buy base, pay quote
4. Apply slippage check
5. Calculate realized PnL:
   - Long: (exitPrice - entryPrice) * closedSize / 1e18
   - Short: (entryPrice - exitPrice) * closedSize / 1e18
6. Apply fees
7. Update position:
   - size -= closedSize (or += for shorts)
   - margin adjusted by PnL and fees
   - realizedPnL accumulated
8. If fully closed:
   - Return remaining margin to collateral
   - Remove from _userActiveMarkets
9. If partially closed:
   - Verify remaining position meets margin requirements
```

### Margin System

**Margin Types**:
- **Initial Margin Requirement (IMR)**: Required to open/increase position
- **Maintenance Margin Requirement (MMR)**: Required to keep position open

**Calculations**:
```solidity
notionalValue = |position.size| * markPrice / 1e18

requiredInitialMargin = notionalValue * imrBps / 10000
requiredMaintenanceMargin = notionalValue * mmrBps / 10000

// Equity = margin + unrealizedPnL
unrealizedPnL = (markPrice - entryPrice) * size / 1e18  // for longs
unrealizedPnL = (entryPrice - markPrice) * |size| / 1e18  // for shorts

marginRatio = (margin + unrealizedPnL) * 10000 / notionalValue
```

**Add/Remove Margin**:
```solidity
// Add margin from collateral to position
clearingHouse.addMargin(marketId, amount)
// Transfers from vault balance to position.margin

// Remove margin from position to collateral
clearingHouse.removeMargin(marketId, amount)
// Checked: remaining margin >= IMR * notional
// Transfers from position.margin back to vault balance
```

### Liquidation Flow

```
Liquidator calls: clearingHouse.liquidate(user, marketId)

Flow:
1. Settle user's pending funding (updates unrealizedPnL)
2. Check isLiquidatable(user, marketId):
   - marginRatio < mmrBps
3. Close user's entire position at market price via vAMM
4. Calculate liquidation penalty:
   penalty = min(notional * liquidationPenaltyBps / 10000, penaltyCap)
5. Calculate equity:
   equity = position.margin + realizedPnL (from closing)

6. If equity >= penalty (healthy liquidation):
   - liquidatorReward = penalty / 2
   - insurancePortion = penalty - liquidatorReward
   - Transfer liquidatorReward to liquidator
   - Transfer insurancePortion to InsuranceFund via FeeRouter
   - Return (equity - penalty) to user's vault balance

7. If equity < penalty but equity > 0 (partial bad debt):
   - liquidatorReward = equity / 2
   - insurancePortion = equity - liquidatorReward
   - Transfer rewards
   - User receives nothing

8. If equity <= 0 (full bad debt):
   - badDebt = |equity|
   - InsuranceFund covers badDebt (graceful degradation)
   - Liquidator receives nothing from user

9. Clear position (size = 0, margin = 0)
10. Remove from _userActiveMarkets
```

### Funding Rate

**Purpose**: Keep perpetual price aligned with oracle (spot) price.

**Calculation** (on each funding settlement):
```solidity
elapsedTime = block.timestamp - lastFundingTime
elapsedHours = elapsedTime / 3600

markPrice = vamm.getMarkPrice()
oraclePrice = oracle.getPrice()

premiumFraction = (markPrice - oraclePrice) * 1e18 / oraclePrice
fundingRatePerHour = clamp(kFundingX18 * premiumFraction / 1e18, -frMaxBpsPerHour, +frMaxBpsPerHour)

cumulativeFundingPerUnitX18 += fundingRatePerHour * elapsedHours
lastFundingTime = block.timestamp
```

**Settlement for User**:
```solidity
fundingDelta = cumulativeFundingPerUnitX18 - position.lastFundingIndex
fundingPayment = position.size * fundingDelta / 1e18

// Positive fundingPayment = user pays (longs when funding positive)
// Negative fundingPayment = user receives
position.margin -= fundingPayment  // Can go negative, triggering liquidatability
position.lastFundingIndex = cumulativeFundingPerUnitX18
```

---

## User Flows

### Complete Trading Flow
```solidity
// 1. Approve collateral
IERC20(usdc).approve(address(vault), amount);

// 2. Deposit collateral (goes to vault balance)
clearingHouse.deposit(usdc, amount);

// 3. Add margin to specific market
clearingHouse.addMargin(marketId, marginAmount);

// 4. Open position (long 10 units, max price $5)
clearingHouse.openPosition(marketId, true, 10e18, 5e18);

// ... time passes, funding accrues ...

// 5. Close position (min price $4)
clearingHouse.closePosition(marketId, 10e18, 4e18);

// 6. Remove margin back to vault balance
clearingHouse.removeMargin(marketId, profitAmount);

// 7. Withdraw from vault
clearingHouse.withdraw(usdc, totalAmount);
```

### Liquidation Flow
```solidity
// Liquidator (must be whitelisted) monitors positions
bool canLiquidate = clearingHouse.isLiquidatable(user, marketId);

if (canLiquidate) {
    // Execute liquidation
    clearingHouse.liquidate(user, marketId);
    // Receives liquidation reward (half of penalty, capped by user's equity)
}
```

---

## Risk Parameters

| Parameter | Description | Typical Value | Max Leverage |
|-----------|-------------|---------------|--------------|
| `imrBps` | Initial Margin Requirement | 1000 (10%) | 10x |
| `mmrBps` | Maintenance Margin Requirement | 500 (5%) | Liquidation at 5% |
| `liquidationPenaltyBps` | Penalty on liquidation | 250 (2.5%) | - |
| `penaltyCap` | Maximum penalty in USD | 1000e18 ($1000) | - |
| `maxPositionSize` | Maximum position per user | 0 (unlimited) | - |
| `minPositionSize` | Minimum position size | 1e18 (1 unit) | Prevents dust |

---

## Fee Structure

### Trading Fees
- Charged on every position open/close
- Calculated: `notionalValue * feeBps / 10000`
- Typical: 10 bps (0.1%)
- Precision: Uses `mulDivRoundingUp` for low-decimal tokens

### Fee Distribution
```
Trade Fee (100%)
    |
    +-- Insurance Fund (tradeToFundBps, e.g., 50%)
    |
    +-- Treasury (remainder, e.g., 50%)
```

### Liquidation Fees
```
Liquidation Penalty
    |
    +-- Liquidator (50%)
    |
    +-- Remaining (50%)
         |
         +-- Insurance Fund (liqToFundBps portion)
         |
         +-- Treasury (remainder)
```

---

## Oracle System

### CuOracle.sol
**Purpose**: Commit-reveal oracle for GPU prices (prevents front-running).

**Flow**:
1. Admin commits: `commitPrice(assetId, keccak256(price, nonce))`
2. Wait minimum delay
3. Admin reveals: `updatePrices(assetId, price, nonce)`

**State**:
```solidity
mapping(bytes32 assetId => uint256 price) public prices;
mapping(bytes32 assetId => uint256 timestamp) public lastUpdated;
mapping(bytes32 assetId => bytes32 commitment) public commitments;
```

### CuOracleAdapter.sol
**Purpose**: Wraps CuOracle to IOracle interface for vAMM compatibility.

```solidity
function getPrice() external view returns (uint256) {
    (uint256 price, uint256 timestamp) = cuOracle.getPrice(assetId);
    require(block.timestamp - timestamp <= maxAge, "stale");
    return price;
}
```

### MultiAssetOracle.sol
**Purpose**: Single oracle supporting multiple GPU types.

```solidity
mapping(bytes32 assetId => uint256 price) public prices;
mapping(bytes32 assetId => uint256 timestamp) public lastUpdated;
mapping(bytes32 assetId => bool) public isAssetRegistered;
```

### MultiAssetOracleAdapter.sol
**Purpose**: Wraps MultiAssetOracle per-asset for vAMM.

---

## Security Considerations

### Access Control Matrix

| Contract | Role | Capabilities |
|----------|------|--------------|
| ClearingHouse | admin | setRiskParams, pause, setWhitelistedLiquidator |
| ClearingHouse | whitelistedLiquidator | liquidate |
| MarketRegistry | MARKET_ADMIN_ROLE | addMarket, updateMarket, pauseMarket |
| CollateralVault | owner | registerCollateral, setOracle, setClearinghouse |
| CollateralVault | clearinghouse | withdrawFor |
| InsuranceFund | authorized | withdraw (for bad debt) |
| InsuranceFund | feeRouter | deposit |
| CuOracle | priceCommitter | commitPrice, updatePrices |

### Reentrancy Protection
- ClearingHouse uses `ReentrancyGuard` on all external entry points
- Check-effects-interactions pattern followed in token transfers

### Critical Checks

**Position Opening**:
```solidity
// Before opening any new position:
for (uint256 i = 0; i < _userActiveMarkets[msg.sender].length; i++) {
    require(!this.isLiquidatable(msg.sender, activeMarkets[i]), "CH: has liquidatable position");
}
```

**Withdrawal**:
```solidity
// After withdrawal:
for (uint256 i = 0; i < _userActiveMarkets[msg.sender].length; i++) {
    require(!this.isLiquidatable(msg.sender, activeMarkets[i]), "CH: would be liquidatable");
}
```

**Liquidation Check**:
```solidity
function isLiquidatable(address user, bytes32 marketId) public returns (bool) {
    _settleFundingInternal(marketId, user);  // Settle first!
    uint256 marginRatio = getMarginRatio(user, marketId);
    RiskParams memory rp = marketRiskParams[marketId];
    return marginRatio < rp.mmrBps;
}
```

### Fee-on-Transfer Token Support
- Balance-delta pattern in CollateralVault.withdrawFor()
- Balance-delta pattern in FeeRouter.onTradeFee()
- Actual received amounts tracked and returned

---

## Key Invariants

### Position Invariants
1. `position.size != 0` implies `position.margin > 0` (before liquidation)
2. After any non-liquidation operation: `marginRatio >= mmrBps`
3. Entry price is always > 0 when size != 0
4. `|newSize| >= minPositionSize` when opening (unless closing to zero)

### Collateral Invariants
1. `sum(userBalances[*][token]) <= IERC20(token).balanceOf(vault)`
2. User cannot have negative vault balance
3. `userBalances[user][token] <= collateralConfig.accountCap`

### vAMM Invariants
1. `baseReserve > 0 && quoteReserve > 0` always
2. Mark price = quoteReserve / baseReserve (scaled)
3. Net position across all traders = net reserve change

### Funding Invariants
1. Sum of all funding payments = 0 (zero-sum game between longs and shorts)
2. `cumulativeFundingPerUnitX18` monotonically changes based on premium sign

---

## Known Limitations

### Centralization Risks
1. **Oracle Updates**: GPU prices pushed by admin/bot, not decentralized
2. **Liquidator Whitelist**: Only approved addresses can liquidate
3. **Admin Controls**: Can pause markets, change risk parameters instantly

### Economic Limitations
1. **Single Collateral Type per Position**: Cannot use multiple collateral types
2. **No Partial Liquidations**: Entire position closed on liquidation
3. **Insurance Fund Depletion**: If fund emptied, bad debt may accumulate

### Technical Limitations
1. **Token Restrictions**: Assumes standard ERC20 (supports fee-on-transfer, but not rebasing)
2. **Oracle Staleness**: 24-hour max age may be too long for volatile markets
3. **Funding Rate Caps**: May not converge fast enough during extreme deviations
4. **No Cross-Margin**: Each market has isolated margin

### Potential Attack Vectors to Audit
1. **Oracle Manipulation**: Sustained mark price manipulation to trigger liquidations
2. **Funding Rate Gaming**: Opening position just before favorable funding settlement
3. **Dust Position Attacks**: Mitigated by minPositionSize
4. **Flash Loan Attacks**: No direct vulnerability, but review collateral deposit/withdraw atomicity
5. **Precision Loss**: Review mulDiv operations, especially fee conversions between decimals

---

## Build and Test

```bash
# Install dependencies
forge install

# Build
forge build

# Run all tests
forge test

# Run tests with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/ClearingHouseTest.t.sol

# Run specific test
forge test --match-test testLiquidation -vvv

# Gas report
forge test --gas-report

# Coverage
forge coverage
```

---

## Deployed Contracts (Sepolia Testnet)

| Contract | Address |
|----------|---------|
| ClearingHouse (Proxy) | `0x18F863b1b0A3Eca6B2235dc1957291E357f490B0` |
| MarketRegistry | `0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD` |
| CollateralVault | `0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0` |
| InsuranceFund | `0x3C1085dF918a38A95F84945E6705CC857b664074` |
| FeeRouter | `0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F` |
| MultiAssetOracle | `0xB44d652354d12Ac56b83112c6ece1fa2ccEfc683` |
| Mock USDC | `0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7` |
| Mock WETH | `0xc696f32d4F8219CbA41bcD5C949b2551df13A7d6` |

---

## Audit Checklist

### Critical Priority
- [ ] Liquidation flow: bad debt handling, edge cases
- [ ] Margin calculations: IMR/MMR enforcement
- [ ] Position size validation: min/max enforcement
- [ ] Funding rate: overflow, manipulation resistance
- [ ] Fee calculations: precision loss with low-decimal tokens
- [ ] Oracle integration: staleness, manipulation resistance
- [ ] Reentrancy: all external entry points protected

### High Priority
- [ ] Access control: all privileged functions
- [ ] Withdrawal restrictions: post-withdrawal liquidatability check
- [ ] Position opening restrictions: existing liquidatable positions
- [ ] Collateral valuation: haircut application
- [ ] vAMM swap math: constant product enforcement

### Medium Priority
- [ ] Event emission: correctness and completeness
- [ ] View function accuracy: getPosition, getMarginRatio, etc.
- [ ] Gas optimization opportunities
- [ ] Upgrade safety: storage layout for UUPS proxies
- [ ] Edge cases: zero amounts, max values, empty positions

### Low Priority
- [ ] Code style and documentation
- [ ] Test coverage gaps
- [ ] Unused code removal
