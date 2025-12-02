# ByteStrike Development Guide

**Technical Documentation for Developers**

This document provides in-depth technical information for developers working on ByteStrike.

---

## Table of Contents

1. [Smart Contract Architecture](#smart-contract-architecture)
2. [Frontend Architecture](#frontend-architecture)
3. [Contract Integration](#contract-integration)
4. [Deployment Process](#deployment-process)
5. [Testing Guide](#testing-guide)
6. [Known Issues & Limitations](#known-issues--limitations)
7. [Upgrade Procedures](#upgrade-procedures)
8. [API Reference](#api-reference)

---

## Smart Contract Architecture

### 1. ClearingHouse (src/ClearingHouse.sol)

**Purpose**: Central trading orchestration and position management

**Key Data Structures**:
```solidity
struct PositionView {
    int256 size;              // Positive = long, negative = short
    uint256 margin;           // Collateral margin in 1e18
    uint256 entryPriceX18;    // Average entry price in 1e18
    int256 lastFundingIndex;  // Last settled funding index
    int256 realizedPnL;       // Realized profit/loss in 1e18
}

struct MarketRiskParams {
    uint256 imrBps;               // Initial margin requirement (basis points)
    uint256 mmrBps;               // Maintenance margin requirement
    uint256 liquidationPenaltyBps; // Liquidation penalty
    uint256 penaltyCap;           // Maximum penalty cap
}
```

**Critical Functions**:

1. **openPosition(bytes32 marketId, bool isLong, uint256 size, uint256 priceLimitX18)**
   - Opens or increases a position
   - Validates IMR (Initial Margin Requirement)
   - Executes swap via vAMM
   - Routes fees to FeeRouter
   - Emits `PositionOpened` event

2. **closePosition(bytes32 marketId, uint256 size, uint256 priceLimitX18)**
   - Closes or reduces a position
   - Realizes PnL
   - Returns excess margin
   - Emits `PositionClosed` event

3. **liquidatePosition(bytes32 marketId, address account)**
   - Only whitelisted liquidators can call
   - Checks if position is below MMR
   - Closes entire position via vAMM
   - Distributes liquidation penalty (50% liquidator, 50% protocol)
   - Insurance fund covers bad debt
   - Emits `PositionLiquidated` event

4. **settleFunding(bytes32 marketId, address account)**
   - Called internally before each trade
   - Pokes vAMM to update funding rate
   - Calculates funding payment: `(newIndex - lastIndex) * positionSize`
   - Adjusts margin accordingly

**Access Control Roles**:
- `DEFAULT_ADMIN_ROLE`: Full contract control
- `LIQUIDATOR_ROLE`: Can execute liquidations

**Gas Optimization Notes**:
- Uses `unchecked` blocks where overflow is impossible
- Stores packed structs to minimize storage slots
- Batch operations where possible

---

### 2. vAMM (src/vAMM.sol)

**Purpose**: Virtual automated market maker for price discovery

**Pricing Formula**: Constant Product (Uniswap V2 style)
```
x * y = k
markPrice = y / x
```

**Virtual Reserves**:
- `reserveBase` (X): Virtual base asset amount
- `reserveQuote` (Y): Virtual quote asset amount
- No real liquidity deposited

**Swap Functions**:

1. **swapBaseForQuote(uint256 baseAmountIn, uint256 minQuoteOut)**
   - Used to enter long positions
   - Input: Base amount to buy
   - Output: Quote cost (including fee)
   - Formula: `quoteOut = (y * baseIn * (10000-fee)) / (x*10000 + baseIn*(10000-fee))`

2. **swapQuoteForBase(uint256 quoteAmountIn, uint256 minBaseOut)**
   - Alternative long entry
   - Input: Quote amount to spend
   - Output: Base received

3. **swapSellBaseForQuote(uint256 baseAmountIn, uint256 minQuoteOut)**
   - Used to enter shorts or close longs
   - Sells base for quote

**TWAP System**:
- 64-slot ring buffer (Observation struct)
- Stores cumulative price in Q128 format
- Updated on every swap via `_accumulatePrice()` and `_writeObservation()`
- `getTwap(uint32 window)` returns average over lookback period
- Default window: 900 seconds (15 minutes)

```solidity
struct Observation {
    uint32 timestamp;
    uint256 cumulativePriceX128;  // Q128 fixed-point
}
```

**Funding Rate Mechanism**:
- `pokeFunding()` updates cumulative funding index
- Premium = TWAP - Oracle Index Price
- Funding Rate = `premium * kFundingX18 * timeElapsed / (24h * 1e18)`
- Clamped by `frMaxBpsPerHour` (default: 100 bps/hour = 1%)
- Positive funding: Longs pay shorts
- Negative funding: Shorts pay longs

**Known Bugs** (see vAMM_Analysis.md):
1. TWAP overflow risk (cumulative price can overflow uint256)
2. uint32 timestamp limitation (fails year 2106)
3. Fee growth overflow with extreme volume
4. No explicit reentrancy guards

---

### 3. MarketRegistry (src/MarketRegistry.sol)

**Purpose**: Central market configuration and state management

**Market Structure**:
```solidity
struct Market {
    address vamm;           // vAMM contract
    uint16 feeBps;          // Trade fee (0-300 bps, max 3%)
    bool paused;            // Emergency pause flag
    address oracle;         // Price oracle
    address feeRouter;      // Fee distribution
    address insuranceFund;  // Insurance fund
    address baseAsset;      // Base asset address
    address quoteToken;     // Quote token address
    uint256 baseUnit;       // Decimal normalization (1e18 for ETH)
}
```

**Market ID Generation**:
```solidity
marketId = keccak256(abi.encodePacked(
    vamm,
    oracle,
    baseAsset,
    quoteToken
));
```

**Access Control**:
- `MARKET_ADMIN_ROLE`: Add markets, unpause
- `PARAM_ADMIN_ROLE`: Update fees, routing
- `PAUSE_GUARDIAN_ROLE`: Emergency pause (cannot unpause)

---

### 4. CollateralVault (src/CollateralVault.sol)

**Purpose**: Multi-token collateral custody and valuation

**Collateral Configuration**:
```solidity
struct CollateralConfig {
    address token;
    uint256 baseUnit;       // 1e6 for USDC, 1e18 for WETH
    uint16 haircutBps;      // Risk discount (e.g., 500 = 5%)
    uint16 liqIncentiveBps; // Liquidation bonus
    uint256 cap;            // Protocol-wide cap
    uint256 accountCap;     // Per-account cap
    bool enabled;
    bool depositPaused;
    bool withdrawPaused;
    string oracleSymbol;    // "ETH", "USDC", etc.
}
```

**Valuation Formula**:
```solidity
usdValue = (oraclePrice * amount / baseUnit) * (10000 - haircutBps) / 10000
```

**Balance Delta Detection**:
- Measures actual token balance change
- Supports fee-on-transfer tokens
- Prevents double-counting

**Authorization**:
- Only ClearingHouse can call `withdrawFor()`, `seize()`, `sweepFees()`
- Users directly call `deposit()` and `withdraw()`

---

### 5. InsuranceFund (src/InsuranceFund.sol)

**Purpose**: Protocol backstop for bad debt

**Key Functions**:
- `onFeeReceived(uint256 amount)`: Called by FeeRouter after fee transfer
- `payout(address to, uint256 amount)`: Transfers funds to cover liquidations
- `donate(uint256 amount)`: External donations

**Tracking**:
- `_totalReceived`: Cumulative fees received
- `_totalPaid`: Cumulative payouts
- Balance: `quoteToken.balanceOf(address(this))`

**Authorization**:
- `_routers`: Approved fee routers
- `_authorized`: Contracts that can request payouts (ClearingHouse)

---

### 6. FeeRouter (src/FeeRouter.sol)

**Purpose**: Fee distribution between insurance fund and treasury

**Configuration**:
```solidity
address public quoteToken;
uint16 public tradeToFundBps;  // % of trade fees → insurance
uint16 public liqToFundBps;    // % of liquidation penalties → insurance
```

**Fee Flow**:
```
ClearingHouse
  ↓ seizes fees from CollateralVault
  ↓ transfers to FeeRouter
  ↓ calls onTradeFee() or onLiquidationPenalty()
FeeRouter
  ↓ splits based on bps
  ↓ transfers insurance share
  ↓ calls InsuranceFund.onFeeReceived()
  ↓ treasury share remains in router
```

---

### 7. Oracle (src/Oracle/Oracle.sol)

**Purpose**: Chainlink price feed integration

**Features**:
- Multi-feed support (maps symbol → aggregator)
- Decimal normalization (all prices in 1e18)
- Staleness checks (configurable per token)
- L2 sequencer uptime validation
- Round validation (`answeredInRound >= roundID`)

**Functions**:
- `getPrice(string symbol)`: Returns 1e18-normalized price
- `getUnderlyingPrice(string symbol)`: Price adjusted for base unit
- `setPriceFeed(string symbol, address feed)`: Configure Chainlink feed

---

## Frontend Architecture

### Technology Stack

**Core Framework**:
- React 19.1.0 (latest with concurrent features)
- Vite 7.0.4 (fast ES module build tool)

**Web3 Integration**:
- Wagmi v2.16.9 (React hooks for Ethereum)
- Viem v2.37.5 (TypeScript Ethereum library)
- RainbowKit v2.2.8 (wallet connection UI)
- Ethers v6.15.0 (contract interactions)

**State Management**:
- TanStack Query v5.87.1 (server state)
- React Context (UI state)
- Local Storage (user preferences)

**UI/UX**:
- Tailwind CSS v4.1.13 (utility-first styling)
- Radix UI (headless components)
- Framer Motion 12.23.6 (animations)
- ApexCharts 5.3.3 (price charts)
- React Hot Toast 2.6.0 (notifications)

**Backend**:
- Supabase 2.52.0 (authentication, database)

### Project Structure

```
bytestrike3/src/
├── main.jsx                 # React entry point
├── App.jsx                  # Main app with routing
│
├── contracts/
│   ├── addresses.js         # Deployed contract addresses
│   └── abis/                # Contract ABIs (8 files)
│       ├── ClearingHouse.json
│       ├── vAMM.json
│       ├── CollateralVault.json
│       └── ...
│
├── hooks/                   # Custom React hooks
│   ├── useVAMM.js          # vAMM interactions (234 lines)
│   ├── useClearingHouse.js # Trading operations (378 lines)
│   └── useOracle.js        # Price feeds (63 lines)
│
├── components/              # Reusable UI components
│   ├── TradingPanel.jsx    # Main trading interface
│   ├── PositionPanel.jsx   # Position display
│   ├── CollateralManager.jsx # Collateral management
│   ├── WalletStatus.jsx    # Wallet info
│   ├── NetworkGuard.jsx    # Network validation
│   ├── MintUSDC.jsx        # USDC minting
│   └── ui/                 # Radix UI components
│
├── pages/                   # Route pages
│   ├── landingpage.jsx
│   ├── tradingdash.jsx     # Main trading dashboard
│   ├── portfolio.jsx       # Portfolio overview
│   └── guidepage.jsx
│
├── marketData.jsx           # Market data hooks
├── marketcontext.jsx        # Market selection context
├── creatclient.jsx          # Supabase client
└── wallet.jsx               # Wallet utilities
```

### Custom Hooks Reference

**useVAMM.js** (234 lines):
- `useMarkPrice(vammAddress, refetchInterval)` - Current mark price from vAMM
- `useVAMMReserves(vammAddress)` - Virtual base/quote reserves
- `useTWAP(vammAddress, window)` - Time-weighted average price
- `useFundingRate(vammAddress)` - Cumulative funding rate
- `useSwapBaseForQuote(vammAddress)` - Direct vAMM swap (rarely used)
- `usePokeFunding(vammAddress)` - Update funding rate

**useClearingHouse.js** (378 lines):
- `usePosition(marketId, userAddress)` - Get single position
- `useAllPositions()` - Get all user positions across markets
- `useAccountValue(userAddress)` - Total account value in USD
- `useOpenPosition(marketId)` - Open/increase position
- `useClosePosition(marketId)` - Close/reduce position
- `useDeposit()` - Deposit collateral
- `useWithdraw()` - Withdraw collateral
- `useMarketRiskParams(marketId)` - Get IMR/MMR/penalty
- `useLiquidationStatus(marketId, userAddress)` - Check liquidation risk

**useOracle.js** (63 lines):
- `useOraclePrice(oracleAddress, refetchInterval)` - Index price

### Data Flow

```
User Action (Button Click)
   ↓
React Component Handler
   ↓
Custom Hook (e.g., useOpenPosition)
   ↓
Wagmi useWriteContract
   ↓
Viem (Contract Encoding)
   ↓
RainbowKit (Wallet Signing)
   ↓
Ethereum JSON-RPC
   ↓
Sepolia Blockchain
   ↓
Smart Contract Execution
   ↓
Transaction Receipt
   ↓
Wagmi waitForTransactionReceipt
   ↓
TanStack Query Refetch
   ↓
UI Update (Toast, Position Refresh)
```

### Key Components Explained

**TradingPanel.jsx** (570 lines):
- Main trading interface
- Market selection dropdown
- Buy/Sell toggle
- Size and price limit inputs
- Slippage validation
- Real-time market data display (mark, TWAP, index, funding)
- Integrated collateral manager
- Transaction execution and status

**PositionPanel.jsx** (266 lines):
- Displays all open positions
- Real-time PnL calculation: `(currentPrice - entryPrice) * size`
- Close position UI with partial close support
- Position size, margin, entry price display
- Color-coded long/short indicators

**CollateralManager.jsx** (499 lines):
- Deposit/withdraw collateral UI
- Token selection (mUSDC, mWETH)
- ERC20 approval flow
- Balance and allowance display
- Integrated faucet bot (test ETH)

**NetworkGuard.jsx** (94 lines):
- Enforces Sepolia network (Chain ID: 11155111)
- Shows modal if wrong network
- Provides network switch button
- Blocks trading until correct network

---

## Contract Integration

### Configuration Files

**addresses.js**:
```javascript
export const SEPOLIA_CONTRACTS = {
  clearingHouse: '0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6',
  marketRegistry: '0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD',
  collateralVault: '0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0',
  vammProxy: '0x3f9b634b9f09e7F8e84348122c86d3C2324841b5',
  oracle: '0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad',
  mockUSDC: '0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7',
  mockWETH: '0xc696f32d4F8219CbA41bcD5C949b2551df13A7d6',
};

export const MARKET_IDS = {
  'ETH-PERP-V2': '0x923fe13dd90eff0f2f8b82db89ef27daef5f899aca7fba59ebb0b01a6343bfb5',
};

export const DEFAULT_MARKET_ID = MARKET_IDS['ETH-PERP-V2'];
```

### ABIs

All contract ABIs stored in `bytestrike3/src/contracts/abis/`:
- ClearingHouse.json (181KB)
- vAMM.json (108KB)
- CollateralVault.json (127KB)
- MarketRegistry.json (64KB)
- Oracle.json (36KB)
- FeeRouter.json (40KB)
- InsuranceFund.json (42KB)
- UpdatableETHOracle.json (2.2KB)

### Wagmi Configuration

**App.jsx**:
```javascript
import { WagmiProvider, createConfig, http } from 'wagmi';
import { sepolia } from 'wagmi/chains';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { RainbowKitProvider, getDefaultConfig } from '@rainbow-me/rainbowkit';

const config = getDefaultConfig({
  appName: 'ByteStrike',
  projectId: 'YOUR_PROJECT_ID',
  chains: [sepolia],
  transports: {
    [sepolia.id]: http('https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY'),
  },
});

const queryClient = new QueryClient();

function App() {
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider>
          {/* App routes */}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
```

---

## Deployment Process

### Prerequisites

1. Foundry installed
2. `.env` file configured:
```bash
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY
PRIVATE_KEY=0x...
ETHERSCAN_API_KEY=YOUR_KEY
```

### Full Deployment (Fresh Start)

```bash
# 1. Deploy all contracts
forge script script/DeployBytestrike.s.sol \
  --rpc-url sepolia \
  --broadcast \
  --verify \
  -vvvv

# 2. Post-deployment setup (risk params, markets, etc.)
forge script script/PostDeploymentSetup.s.sol \
  --rpc-url sepolia \
  --broadcast

# 3. Fund insurance fund
forge script script/FundInsuranceFund.s.sol \
  --rpc-url sepolia \
  --broadcast

# 4. Set risk parameters
forge script script/SetRiskParams.s.sol \
  --rpc-url sepolia \
  --broadcast
```

### Upgrading ClearingHouse

```bash
# Deploy new implementation
forge script script/UpgradeClearingHouseV3.s.sol \
  --rpc-url sepolia \
  --broadcast \
  --verify

# Proxy will automatically point to new implementation
```

### Adding a New Market

```bash
# Edit script/AddNewMarket.s.sol with new market params
# Then run:
forge script script/AddNewMarket.s.sol \
  --rpc-url sepolia \
  --broadcast
```

### Contract Verification

```bash
# Individual contract
forge verify-contract \
  0xYOUR_CONTRACT_ADDRESS \
  src/ClearingHouse.sol:ClearingHouse \
  --chain sepolia \
  --constructor-args $(cast abi-encode "constructor()")

# Batch verification
./script/VerifyContracts.sh
```

---

## Testing Guide

### Running Tests

```bash
# All tests
forge test -vvv

# Specific test file
forge test --match-contract PositionTest -vvv

# Specific test function
forge test --match-test testOpenLongPosition -vvvv

# With gas reporting
forge test --gas-report

# With coverage
forge coverage

# Fork testing (against Sepolia)
forge test --fork-url $SEPOLIA_RPC_URL -vvv
```

### Test File Overview

1. **BaseTest.sol** (14KB)
   - Common setup and fixtures
   - Mock contract initialization
   - Helper functions

2. **PositionTest.t.sol**
   - Opening positions (long/short)
   - Closing positions
   - Adding/removing margin
   - Entry price calculation
   - PnL realization

3. **LiquidationTest.t.sol**
   - Liquidation conditions (below MMR)
   - Liquidation penalty distribution
   - Insurance fund backstop
   - Bad debt handling

4. **CollateralVaultTest.t.sol**
   - Multi-token deposits
   - Withdrawals
   - Haircut valuation
   - Fee-on-transfer tokens
   - Cap enforcement

5. **FeeRouterTest.t.sol**
   - Fee splitting
   - Insurance fund allocation
   - Treasury allocation

6. **InsuranceFundTest.t.sol**
   - Fee reception
   - Payouts
   - Donations

7. **MarketRegistryTest.t.sol**
   - Market registration
   - Parameter updates
   - Pause/unpause

8. **VAMMEdgeCaseTest.t.sol**
   - Price manipulation attempts
   - Extreme swaps
   - Overflow scenarios

### Writing New Tests

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./BaseTest.sol";

contract MyNewTest is BaseTest {
    function setUp() public override {
        super.setUp(); // Call parent setup
        // Additional setup
    }

    function testMyFeature() public {
        // Arrange
        vm.startPrank(alice);
        // ...

        // Act
        clearingHouse.openPosition(marketId, true, 1e18, 0);

        // Assert
        (int256 size, uint256 margin,,,) = clearingHouse.getPosition(marketId, alice);
        assertEq(size, 1e18);

        vm.stopPrank();
    }
}
```

---

## Known Issues & Limitations

### Smart Contract Issues

1. **vAMM TWAP Overflow** (HIGH)
   - Cumulative price can overflow uint256 after sustained high prices
   - Mitigation: Monitor and redeploy vAMM if approaching limits
   - Fix: Use larger integer type or periodic reset

2. **uint32 Timestamp** (MEDIUM)
   - Fails in year 2106
   - Mitigation: Upgrade before 2106
   - Fix: Use uint64 for timestamps

3. **Fee Growth Overflow** (MEDIUM)
   - Cumulative fee growth can overflow with extreme volume
   - Mitigation: Monitor fee accumulation
   - Fix: Implement fee growth checkpointing

4. **No Reentrancy Guards** (LOW)
   - Relies on checks-effects-interactions pattern
   - Risk: Low (all external calls at end of functions)
   - Recommendation: Add ReentrancyGuard for defense in depth

5. **Oracle Manipulation** (MEDIUM)
   - Chainlink oracle can be manipulated with sustained attacks
   - Mitigation: TWAP acts as secondary price source
   - Recommendation: Use multiple oracle sources

### Frontend Limitations

1. **Event Indexing Missing**
   - 24h volume uses mock data
   - Order/trade history not populated from blockchain
   - Solution: Deploy TheGraph subgraph or build custom indexer

2. **Liquidation Alerts Not Displayed**
   - `useLiquidationStatus()` hook exists but not shown in UI
   - Solution: Add warning badges to PositionPanel

3. **Fee Preview Missing**
   - Fees charged but not shown before execution
   - Solution: Calculate and display estimated fees in TradingPanel

4. **React 19 Compatibility**
   - Uses workaround for `use-sync-external-store`
   - May cause console warnings
   - Monitor React 19 ecosystem maturity

---

## Upgrade Procedures

### UUPS Upgrade Pattern

ClearingHouse, vAMM, and other critical contracts use UUPS (Universal Upgradeable Proxy Standard).

**Upgrade Steps**:

1. **Deploy New Implementation**:
```bash
forge create src/ClearingHouse.sol:ClearingHouse \
  --rpc-url sepolia \
  --private-key $PRIVATE_KEY \
  --verify
```

2. **Encode Upgrade Call**:
```bash
cast calldata "upgradeToAndCall(address,bytes)" \
  NEW_IMPLEMENTATION_ADDRESS \
  0x  # Empty data if no initialization
```

3. **Execute Upgrade via Proxy**:
```bash
cast send PROXY_ADDRESS \
  "upgradeToAndCall(address,bytes)" \
  NEW_IMPLEMENTATION_ADDRESS \
  0x \
  --rpc-url sepolia \
  --private-key $PRIVATE_KEY
```

4. **Verify Upgrade**:
```bash
cast call PROXY_ADDRESS "implementation()(address)" \
  --rpc-url sepolia
```

### Rollback Procedure

If upgrade fails or has critical bugs:

```bash
# Upgrade back to previous implementation
cast send PROXY_ADDRESS \
  "upgradeToAndCall(address,bytes)" \
  PREVIOUS_IMPLEMENTATION_ADDRESS \
  0x \
  --rpc-url sepolia \
  --private-key $PRIVATE_KEY
```

---

## API Reference

### ClearingHouse External Functions

```solidity
// Position Management
function openPosition(bytes32 marketId, bool isLong, uint256 size, uint256 priceLimitX18) external
function closePosition(bytes32 marketId, uint256 size, uint256 priceLimitX18) external
function addMargin(bytes32 marketId, uint256 amount) external
function removeMargin(bytes32 marketId, uint256 amount) external

// Liquidation
function liquidatePosition(bytes32 marketId, address account) external

// View Functions
function getPosition(bytes32 marketId, address account) external view returns (PositionView memory)
function getAccountValue(address account) external view returns (uint256)
function getMarginRatio(bytes32 marketId, address account) external view returns (uint256)
```

### vAMM External Functions

```solidity
// Swaps
function swapBaseForQuote(uint256 baseAmountIn, uint256 minQuoteOut) external returns (uint256 quoteOut)
function swapQuoteForBase(uint256 quoteAmountIn, uint256 minBaseOut) external returns (uint256 baseOut)
function swapSellBaseForQuote(uint256 baseAmountIn, uint256 minQuoteOut) external returns (uint256 quoteOut)

// Price/Funding
function getMarkPrice() external view returns (uint256)
function getTwap(uint32 window) external view returns (uint256)
function pokeFunding() external
function getCumulativeFundingPerUnit() external view returns (int256)

// Reserves
function getReserves() external view returns (uint256 base, uint256 quote)
```

### CollateralVault External Functions

```solidity
// User Functions
function deposit(address token, uint256 amount) external
function withdraw(address token, uint256 amount) external
function getBalance(address account, address token) external view returns (uint256)
function getTotalValue(address account) external view returns (uint256)

// ClearingHouse Only
function withdrawFor(address account, address token, address to, uint256 amount) external
function seize(address account, address token, uint256 amount) external
```

---

## Performance Optimization

### Smart Contract Gas Optimization

1. **Use `unchecked` blocks** where overflow is impossible
2. **Pack structs** to minimize storage slots
3. **Cache storage variables** in memory
4. **Batch operations** when possible
5. **Use events** instead of storage for historical data

### Frontend Performance

1. **Memoization**:
```javascript
const memoizedValue = useMemo(() => expensiveCalculation(), [deps]);
```

2. **Debounce User Input**:
```javascript
const debouncedSize = useDebounce(size, 500);
```

3. **Lazy Loading**:
```javascript
const PositionPanel = lazy(() => import('./components/PositionPanel'));
```

4. **Optimistic Updates**:
```javascript
const { openPosition } = useOpenPosition(marketId);
// Update UI immediately, revert if tx fails
```

---

## Troubleshooting

### Common Issues

**Issue**: "Insufficient margin"
- **Cause**: Position size exceeds available collateral given IMR
- **Solution**: Deposit more collateral or reduce position size

**Issue**: "Price limit exceeded"
- **Cause**: Slippage protection triggered
- **Solution**: Increase price limit tolerance or reduce size

**Issue**: "Market paused"
- **Cause**: Emergency pause activated
- **Solution**: Wait for unpause or contact admin

**Issue**: "Wrong network"
- **Cause**: Connected to wrong chain
- **Solution**: Switch to Sepolia in wallet

**Issue**: "Transaction reverted"
- **Cause**: Various (check error message)
- **Solution**: Check allowance, balance, market status

---

## Additional Resources

- **Foundry Book**: https://book.getfoundry.sh/
- **Wagmi Docs**: https://wagmi.sh/
- **Viem Docs**: https://viem.sh/
- **OpenZeppelin Contracts**: https://docs.openzeppelin.com/contracts/
- **Uniswap V2 Math**: https://docs.uniswap.org/protocol/V2/concepts/protocol-overview/how-uniswap-works

---

**Last Updated**: November 26, 2025
**Maintained By**: ByteStrike Development Team
