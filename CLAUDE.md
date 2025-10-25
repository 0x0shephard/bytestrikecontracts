# ByteStrike - Perpetual & Futures Derivatives Trading Platform

## Project Overview

ByteStrike is a decentralized perpetual and futures derivatives trading platform built on Ethereum using Solidity 0.8.30. The protocol enables leveraged trading of perpetual futures and expiring futures contracts through a virtual AMM (Automated Market Maker) architecture with cross-margin collateral management.

### Technology Stack
- **Solidity**: 0.8.30
- **Framework**: Foundry
- **Upgradability**: UUPS (Universal Upgradeable Proxy Pattern)
- **Oracles**: Chainlink price feeds with L2 sequencer support
- **Libraries**: OpenZeppelin contracts (AccessControl, SafeERC20, UUPS)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│              ByteStrike Trading Platform                │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ MarketRegistry│  │ CollateralVault│  │  Insurance   │
│  │  (Governance)│  │  (Multi-Token) │  │   Fund       │
│  └──────┬───────┘  └────────┬───────┘  └──────┬───────┘
│         │                   │                  │        │
│  ┌──────▼─────────────────────────────────────▼────┐  │
│  │            ClearingHouse (Empty Stub)           │  │
│  │  - Orchestrates trading, liquidation, margin   │  │
│  └──────┬─────────────────────────────────────────┘  │
│         │                                             │
│  ┌──────▼─────────────────────────────────────┐     │
│  │  vAMM (Virtual Automated Market Maker)      │     │
│  │  - Perpetual/Futures Pricing Engine        │     │
│  │  - Constant Product Formula (x*y=k)        │     │
│  │  - TWAP & Funding Rate Mechanism           │     │
│  └──────┬─────────────────────────────────────┘     │
│         │                                             │
│  ┌──────▼──────────────┬─────────────────┐          │
│  │   Oracle Service    │  FeeRouter       │          │
│  │  - Chainlink Feeds  │  - Fee Splitting │          │
│  │  - Price Validation │  - Insurance/Tx  │          │
│  └─────────────────────┴─────────────────┘          │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## Core Components

### 1. vAMM (Virtual Automated Market Maker)
**Location**: `src/vAMM.sol`

The pricing engine for the platform. Implements a Uniswap V2-style constant product formula using virtual reserves (no actual token reserves).

**Key Features**:
- Virtual reserves: `reserveBase` (X) and `reserveQuote` (Y)
- Mark price = Y/X in 1e18 precision
- Constant product maintained: (X - feeBase) * (Y - feeQuote) ≈ k
- TWAP system: 64-slot ring buffer for Time-Weighted Average Price
- Funding rate mechanism: Anchors mark price to oracle index price
- UUPS upgradeable pattern

**Three Swap Types**:
1. `swapBaseForQuote()` - Buy base (go long) by paying quote
2. `swapQuoteForBase()` - Sell quote (go short) to receive base
3. `swapSellBaseForQuote()` - Sell base (close position) to receive quote

**TWAP & Funding**:
- Ring buffer stores cumulative price data every block/swap
- `getTwap(window)` computes average price over lookback period
- `pokeFunding()` updates cumulative funding rate based on premium between TWAP and oracle price
- Funding rate is clamped to prevent extreme swings

### 2. MarketRegistry
**Location**: `src/MarketRegistry.sol`

Central registry for all markets (perpetuals and futures). Manages market configurations and governance.

**Market Structure** (9 storage slots, optimized with bit-packing):
- Market type: Perpetual (no expiry) or Future (expires)
- Model type: VAMM or Pool
- Flags (1 byte packed): Paused, Settled, OrderbookEnabled, FundingEnabled
- vAMM address, oracle, fee router, insurance fund
- Base asset & quote token, base unit
- Optional liquidity pool, expiry timestamp, settlement TWAP window
- Final settlement price (for futures)

**Role-Based Access**:
- `MARKET_ADMIN_ROLE`: Add/unpause markets
- `PARAM_ADMIN_ROLE`: Update fees and routing
- `PAUSE_GUARDIAN_ROLE`: Emergency pause (no unpause power)
- `SETTLER_ROLE`: Post-expiry settlement only

### 3. CollateralVault
**Location**: `src/CollateralVault.sol`

Manages cross-margin collateral across multiple ERC20 tokens.

**Key Features**:
- Multi-collateral support with custom risk parameters per token
- CollateralConfig includes: haircut %, liquidation incentive %, caps, oracle symbol
- User accounting: `mapping(user => mapping(token => balance))`
- Valuation helpers with haircut adjustments
- Only clearinghouse can execute withdrawals, seizures, fee sweeps
- Fee-on-transfer token support via balance delta detection

**Functions**:
- `getTokenValueX18()` - Single token USD value with haircut
- `getAccountCollateralValueX18()` - Sum of all collateral USD values

### 4. Oracle
**Location**: `src/Oracle/Oracle.sol`

Chainlink-based price feed aggregation with staleness and sequencer checks.

**Features**:
- Per-symbol configuration with custom stale periods
- Decimal normalization to 1e18
- Round validation (answeredInRound >= roundID)
- Timestamp freshness checks
- L2 sequencer uptime verification (for Arbitrum/Optimism)

### 5. FeeRouter
**Location**: `src/FeeRouter.sol`

Routes trading fees and liquidation penalties between treasury and insurance fund.

**Configuration**:
- One router per quote token (e.g., USDC router, WETH router)
- `tradeToFundBps`: % of trade fees → insurance fund
- `liqToFundBps`: % of liquidation penalties → insurance fund
- Remainder goes to treasury

**Hooks**:
- `onTradeFee(amount)` - Called by clearinghouse after trades
- `onLiquidationPenalty(amount)` - Called during liquidations

### 6. InsuranceFund
**Location**: `src/InsuranceFund.sol`

Protocol reserve that holds quote tokens to cover bad debt and fund incentives.

**Dual Role**:
- Receives fees from fee routers
- Pays out to cover bad debt, liquidation incentives

**Accounting**:
- `_totalReceived`: Cumulative fees + donations
- `_totalPaid`: Cumulative payouts
- Real balance via ERC20 `balanceOf()`

### 7. ClearingHouse
**Location**: `src/ClearingHouse.sol`
**Status**: ⚠️ **EMPTY STUB - NEEDS IMPLEMENTATION**

This is the main orchestration layer that should coordinate:
- Position management & margin tracking
- Trade execution flow (deposit collateral → execute swap → update position)
- Liquidation mechanics
- Funding payment settlement
- Integration with vAMM, CollateralVault, InsuranceFund

## Component Relationships

```
ClearingHouse
├── calls vAMM.swapBaseForQuote()
├── calls vAMM.swapQuoteForBase()
├── calls vAMM.swapSellBaseForQuote()
├── calls vAMM.pokeFunding()
├── calls CollateralVault.deposit()
├── calls CollateralVault.withdrawFor()
├── calls CollateralVault.seize()
├── calls FeeRouter.onTradeFee()
├── calls FeeRouter.onLiquidationPenalty()
└── calls InsuranceFund.payout()

MarketRegistry
├── stores market configs
├── queried by ClearingHouse for active markets
└── provides market parameters (fee, oracle, vAMM, etc.)

vAMM
├── calls IOracle.getPrice() for funding calculations
├── emits Swap events
├── maintains TWAP observations
└── upgradeable via proxy pattern

FeeRouter
├── calls InsuranceFund.onFeeReceived()
└── transfers quote tokens out

CollateralVault
├── calls Oracle.getPrice(symbol) for valuations
├── maintains user balances per token
└── called by ClearingHouse for outflows
```

## Interfaces

| Interface | Location | Purpose |
|-----------|----------|---------|
| `IVAMM.sol` | `src/Interfaces/` | vAMM swap, pricing, and funding hooks |
| `IMarketRegistry.sol` | `src/Interfaces/` | Market registration and querying |
| `ICollateralVault.sol` | `src/Interfaces/` | Collateral management interface |
| `IOracle.sol` | `src/Interfaces/` | Price feed interface |
| `IFeeRouter.sol` | `src/Interfaces/` | Fee notification hooks |
| `IInsuranceFund.sol` | `src/Interfaces/` | Fund intake and payout hooks |
| `IClearingHouse.sol` | `src/Interfaces/` | Empty (not yet defined) |

## Libraries

**MarketLib.sol** (`src/Libraries/`)
- Bit-packing utility for Market.flags
- Helper functions: `isPaused()`, `isSettled()`, `isOrderbookEnabled()`, etc.
- Used by external contracts to read market state efficiently

## Key Patterns & Conventions

### Precision
- All prices and values use **1e18 precision** (18 decimal places)
- Oracle prices normalized to 1e18 regardless of feed decimals
- Base units used for token-specific decimal normalization

### Access Control
- OpenZeppelin's `AccessControl` for role-based permissions
- Multiple admin roles for separation of duties
- Emergency pause capabilities without unpause power

### Upgradability
- vAMM uses UUPS proxy pattern
- Owner-controlled upgrades
- Other contracts are non-upgradeable

### Error Handling
- Custom errors for gas efficiency
- Specific error types for different failure modes
- Oracle validation with clear error messages

## Known Issues & TODOs

### Critical Issues (from vAMM_Analysis.md)
1. **Integer overflow in TWAP accumulation** - `cumulativePrice += uint256(markPriceX18) * elapsedTime` can overflow
2. **TWAP edge cases** - Ring buffer edge cases with zero observations
3. **Missing validation** - No checks for zero reserves or invalid parameters
4. **Fee growth overflow** - `cumulativeFeeGrowthX18` can overflow
5. **Timestamp truncation** - `uint32(block.timestamp)` will fail in 2106

### Development TODOs
- [ ] Implement ClearingHouse contract
- [ ] Fix vAMM critical bugs before mainnet
- [ ] Build comprehensive test suite
- [ ] Add deployment scripts
- [ ] Conduct security audit
- [ ] Add event emissions where missing
- [ ] Implement liquidation mechanics
- [ ] Add position tracking and margin calculations

## Development Status

**Completed Components**:
- ✅ vAMM (production-ready with identified bugs to fix)
- ✅ MarketRegistry
- ✅ CollateralVault
- ✅ Oracle (Chainlink integration)
- ✅ FeeRouter
- ✅ InsuranceFund
- ✅ Libraries (MarketLib)

**Incomplete Components**:
- ❌ ClearingHouse (empty - needs full implementation)
- ❌ Test suite (test/ and script/ directories empty)
- ⚠️ vAMM bugs need fixing before mainnet

## How ByteStrike Works

1. **Perpetual Futures Trading**: Users can:
   - Go long (buy base, pay quote via `swapBaseForQuote`)
   - Go short (sell base, receive quote via `swapSellBaseForQuote`)
   - Close positions (reverse swaps)

2. **Virtual AMM Pricing**:
   - Prices derived from virtual reserves (x*y=k)
   - Mark price adjusts automatically with position size
   - Slippage protection via price limits

3. **Funding Rate Mechanism**:
   - TWAP-based mark price compared to oracle index price
   - Periodic funding payments incentivize price convergence
   - Long positions pay shorts when mark > index, vice versa

4. **Multi-Collateral Cross-Margin**:
   - Deposit any registered ERC20 as collateral
   - Haircut-adjusted valuations for risk management
   - Liquidation with haircut incentives

5. **Market Governance**:
   - Multiple market types (perpetuals, futures with expiry)
   - Pause/settle controls
   - Fee routing to insurance fund and treasury

6. **Risk Management**:
   - Insurance fund accumulates fees for bad debt coverage
   - Per-collateral and per-account caps
   - Liquidation mechanics (to be implemented in ClearingHouse)

## Getting Started

### Prerequisites
- Foundry installed
- Solidity 0.8.30
- OpenZeppelin contracts

### Build
```bash
forge build
```

### Test
```bash
forge test
```

### Deploy
```bash
# Deployment scripts to be added
```

## File Structure

```
byte-strike/
├── src/
│   ├── vAMM.sol                    # Virtual AMM implementation
│   ├── MarketRegistry.sol          # Market configuration registry
│   ├── CollateralVault.sol         # Multi-token collateral manager
│   ├── ClearingHouse.sol           # Empty stub - needs implementation
│   ├── FeeRouter.sol               # Fee distribution
│   ├── InsuranceFund.sol           # Protocol insurance fund
│   ├── Oracle/
│   │   └── Oracle.sol              # Chainlink price feed integration
│   ├── Interfaces/
│   │   ├── IVAMM.sol
│   │   ├── IMarketRegistry.sol
│   │   ├── ICollateralVault.sol
│   │   ├── IOracle.sol
│   │   ├── IFeeRouter.sol
│   │   └── IInsuranceFund.sol
│   └── Libraries/
│       └── MarketLib.sol           # Market flags bit-packing
├── test/                           # Empty - tests to be added
├── script/                         # Empty - deployment scripts to be added
├── vAMM_Analysis.md                # Comprehensive vAMM security analysis
├── foundry.toml                    # Foundry configuration
└── CLAUDE.md                       # This file

```

## Documentation

- **vAMM_Analysis.md**: Comprehensive 17.8 KB analysis covering:
  - Core concepts and mechanics
  - Swap formulas and calculations
  - TWAP system architecture
  - Funding rate mechanism
  - 15 identified bugs/issues (1 critical, 4 high, 4 medium, 6 low)
  - Security concerns and recommendations
  - Overall assessment: B+ quality

## Important Notes for Development

1. **Always check market registry** before executing trades to ensure market is active and not paused
2. **TWAP requires time** - Need sufficient observations for accurate TWAP calculations
3. **Funding must be poked regularly** - Call `pokeFunding()` to keep funding rates updated
4. **Collateral valuations use haircuts** - Never use raw collateral value without haircut adjustment
5. **Fee-on-transfer tokens supported** - CollateralVault uses balance delta detection
6. **Oracle staleness matters** - Always validate oracle prices are fresh before trading
7. **L2 sequencer checks** - Oracle validates sequencer uptime on L2s

## Security Considerations

- **Integer overflow risks** - Especially in TWAP and fee accumulation (vAMM)
- **Timestamp dependencies** - uint32 timestamp limitation in vAMM
- **Oracle manipulation** - TWAP helps but still vulnerable to sustained attacks
- **Liquidation cascades** - Need proper liquidation incentive sizing
- **Access control** - Critical functions must validate caller roles
- **Reentrancy** - Use checks-effects-interactions pattern

## Next Steps

1. Implement ClearingHouse with full position management
2. Fix identified vAMM bugs (see vAMM_Analysis.md)
3. Build comprehensive test suite covering:
   - Unit tests for each contract
   - Integration tests for trading flows
   - Fuzz tests for edge cases
   - Liquidation scenarios
4. Add deployment scripts
5. Conduct formal security audit
6. Add natspec documentation to all functions
7. Implement events for all state changes

## Contact & Resources

- Git History:
  - `8f10609` - first commit
  - `2517684` - vault
  - `19ff37a` - second

---

**Last Updated**: 2025-10-25
**Status**: Active Development - Pre-Audit
**Security**: Not audited - DO NOT USE IN PRODUCTION
