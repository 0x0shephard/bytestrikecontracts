# ByteStrike

**Decentralized Perpetual Futures Trading Platform**

A production-ready perpetual and futures derivatives DEX built on Ethereum, featuring cross-margin collateral management, virtual AMM pricing, and comprehensive liquidation mechanisms.

---

## 🚀 Quick Start

### Prerequisites
- Node.js 18+
- Foundry (for smart contracts)
- MetaMask or compatible Web3 wallet

### Running the Frontend (Testnet)

```bash
cd bytestrike3
npm install
npm run dev
```

Visit `http://localhost:5173` and connect to **Sepolia Testnet**.

### Testing Smart Contracts

```bash
forge test -vvv
```

---

## 📊 Current Status

### ✅ Production-Ready Components

**Smart Contracts (100% Complete)**
- ✅ All 7 core contracts deployed on Sepolia
- ✅ ClearingHouse V3 with decimal fixes
- ✅ vAMM with TWAP and funding rates
- ✅ Multi-token collateral vault (USDC, WETH)
- ✅ Insurance fund backstop system
- ✅ Fee routing and distribution
- ✅ Comprehensive test suite (8 test files)

**Frontend (~90% Complete)**
- ✅ Full trading execution (buy/sell perpetuals)
- ✅ Real-time position management
- ✅ Collateral deposit/withdrawal
- ✅ Live price feeds (mark, TWAP, index, funding)
- ✅ Portfolio dashboard
- ✅ ApexCharts price visualization
- ✅ RainbowKit wallet integration
- ✅ Network validation (Sepolia enforcement)
- ✅ Faucet bot integration for test ETH

### ⚠️ Known Limitations (10%)

- ❌ Event indexing (24h volume/history uses mock data)
- ❌ Liquidation alert UI (hook exists, no display)
- ❌ Fee preview before trade execution
- ❌ Advanced orders (stop loss, take profit)

---

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│              ByteStrike Trading Platform                │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │MarketRegistry│  │CollateralVault│  │ InsuranceFund│  │
│  │  (Markets)   │  │ (Multi-Token)│  │  (Backstop)  │  │
│  └──────┬───────┘  └────────┬───────┘  └──────┬───────┘
│         │                   │                  │        │
│  ┌──────▼─────────────────────────────────────▼────┐  │
│  │         ClearingHouse (Trading Engine)          │  │
│  │  - Position tracking & margin management        │  │
│  │  - Trade execution (open/close)                 │  │
│  │  - Liquidations with insurance backstop         │  │
│  │  - Funding rate settlement                      │  │
│  └──────┬─────────────────────────────────────────┘  │
│         │                                             │
│  ┌──────▼─────────────────────────────────────┐     │
│  │  vAMM (Virtual Automated Market Maker)      │     │
│  │  - Constant product formula (x*y=k)        │     │
│  │  - TWAP calculation (15min window)         │     │
│  │  - Funding rate mechanism                  │     │
│  └──────┬─────────────────────────────────────┘     │
│         │                                             │
│  ┌──────▼──────────────┬─────────────────┐          │
│  │   Oracle Service    │  FeeRouter       │          │
│  │  - Chainlink Feeds  │  - Fee Splitting │          │
│  └─────────────────────┴─────────────────┘          │
│                                                          │
└─────────────────────────────────────────────────────────┘
                        ▲
                        │
                ┌───────┴────────┐
                │  Frontend dApp │
                │  (bytestrike3/)│
                │  - React 19    │
                │  - Wagmi v2    │
                └────────────────┘
```

---

## 📡 Deployed Contracts (Sepolia Testnet)

### Core Contracts

| Contract | Address | Status |
|----------|---------|--------|
| **ClearingHouse** (V3) | `0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6` | ✅ Active |
| **vAMM** (Active) | `0x3f9b634b9f09e7F8e84348122c86d3C2324841b5` | ✅ Active ($3.75-$3.79) |
| **MarketRegistry** | `0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD` | ✅ Active |
| **CollateralVault** | `0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0` | ✅ Active |
| **InsuranceFund** | `0x3C1085dF918a38A95F84945E6705CC857b664074` | ✅ Active |
| **FeeRouter** | `0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F` | ✅ Active |
| **Oracle** (Chainlink) | `0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad` | ✅ Active ($3.79) |

### Test Tokens

| Token | Address | Decimals |
|-------|---------|----------|
| **Mock USDC** | `0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7` | 6 |
| **Mock WETH** | `0xc696f32d4F8219CbA41bcD5C949b2551df13A7d6` | 18 |

### Active Markets

| Market | Market ID | vAMM | Oracle Price | Status |
|--------|-----------|------|--------------|--------|
| **ETH-PERP-V2** | `0x923fe...3bfb5` | `0x3f9b63...841b5` | $3.79 | ✅ Default |
| ETH-PERP (Old) | `0x352291...a35d` | `0xF8908F...2739` | $2000 | Deprecated |

---

## 🎯 Core Features

### Smart Contract Layer

**1. ClearingHouse** (`src/ClearingHouse.sol` - 742 lines)
- Central trading orchestration contract
- Position management with cross-margin support
- IMR (Initial Margin Requirement) and MMR (Maintenance Margin Requirement)
- Whitelisted liquidator system with insurance fund backstop
- Funding rate settlement integration
- UUPS upgradeable pattern

**2. vAMM** (`src/vAMM.sol` - 480 lines)
- Virtual constant product AMM (no real liquidity)
- Three swap types: long entry, short entry, position close
- 64-slot TWAP ring buffer (15-minute default)
- Funding rate calculation (mark price vs. index price premium)
- Fee-on-input model (0.1% - 1%)

**3. MarketRegistry** (`src/MarketRegistry.sol` - 148 lines)
- Centralized market configuration storage
- vAMM, oracle, fee router, insurance fund linking
- Emergency pause functionality
- Role-based access control

**4. CollateralVault** (`src/CollateralVault.sol` - 280 lines)
- Multi-token collateral support
- Haircut-based risk valuation
- Per-token caps (protocol-wide and per-account)
- Fee-on-transfer token compatibility

**5. InsuranceFund** (`src/InsuranceFund.sol` - 141 lines)
- Protocol backstop for bad debt
- Receives portion of trading fees and liquidation penalties
- Pays out to cover negative equity liquidations

**6. FeeRouter** (`src/FeeRouter.sol` - 133 lines)
- Splits fees between insurance fund and treasury
- Configurable basis point splits for trade fees vs. liquidation penalties

**7. Oracle** (`src/Oracle/Oracle.sol` - 199 lines)
- Chainlink price feed integration
- Staleness checks and decimal normalization
- L2 sequencer uptime validation

### Frontend Application

**Technology Stack**
- **React 19** + **Vite 7** (latest build tools)
- **Wagmi v2.16.9** + **Viem v2.37.5** (Ethereum interactions)
- **RainbowKit v2.2.8** (wallet connection)
- **TanStack Query v5** (data fetching)
- **Tailwind CSS v4** (styling)
- **ApexCharts** (price visualization)
- **Supabase** (authentication/backend)

**User Flow**
1. Connect wallet (MetaMask, Coinbase, WalletConnect)
2. Validate Sepolia network
3. Claim test ETH from faucet bot
4. Mint testnet USDC (10,000 mUSDC)
5. Approve and deposit collateral
6. View real-time prices (mark, TWAP, index, funding)
7. Open long/short positions with slippage protection
8. Monitor positions with live PnL
9. Close positions (partial or full)
10. Withdraw collateral

**Pages**
- `/` - Landing page
- `/trade` - Main trading dashboard (3-column layout)
- `/portfolio` - Portfolio overview with account stats
- `/guide` - Interactive user guide

---

## 🧪 Testing

### Smart Contract Tests

```bash
# Run all tests
forge test -vvv

# Run specific test file
forge test --match-contract PositionTest -vvv

# Run with gas reporting
forge test --gas-report
```

**Test Coverage** (8 test files)
- `PositionTest.t.sol` - Position management
- `LiquidationTest.t.sol` - Liquidation scenarios
- `CollateralVaultTest.t.sol` - Multi-token collateral
- `FeeRouterTest.t.sol` - Fee distribution
- `InsuranceFundTest.t.sol` - Insurance mechanics
- `MarketRegistryTest.t.sol` - Market configuration
- `FundingTest.t.sol` - Funding rate calculations
- `VAMMEdgeCaseTest.t.sol` - Edge cases

### Frontend Testing

Currently manual testing. Recommended additions:
- Vitest for unit tests
- Playwright/Cypress for E2E tests

---

## 🛠️ Development

### Project Structure

```
byte-strike/
├── src/                       # Smart contracts (Solidity 0.8.30)
│   ├── ClearingHouse.sol
│   ├── vAMM.sol
│   ├── MarketRegistry.sol
│   ├── CollateralVault.sol
│   ├── InsuranceFund.sol
│   ├── FeeRouter.sol
│   ├── Oracle/
│   ├── Interfaces/
│   └── Libraries/
│
├── test/                      # Foundry tests
├── script/                    # Deployment scripts
│
├── bytestrike3/               # Frontend dApp
│   ├── src/
│   │   ├── contracts/         # ABIs & addresses
│   │   ├── hooks/             # Custom React hooks
│   │   ├── components/        # UI components
│   │   ├── pages/             # Route pages
│   │   └── App.jsx
│   └── package.json
│
├── liquidation-bot/           # TypeScript liquidation monitor
│   └── src/
│
└── foundry.toml               # Foundry configuration
```

### Environment Setup

**Smart Contracts (.env)**
```bash
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY
PRIVATE_KEY=0x...
ETHERSCAN_API_KEY=YOUR_KEY
```

**Frontend (bytestrike3/.env.local)**
```bash
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_ANON_KEY
```

### Deployment

```bash
# Deploy all contracts
forge script script/DeployBytestrike.s.sol --rpc-url sepolia --broadcast --verify

# Upgrade ClearingHouse
forge script script/UpgradeClearingHouseV3.s.sol --rpc-url sepolia --broadcast

# Add new market
forge script script/AddNewMarket.s.sol --rpc-url sepolia --broadcast
```

---

## 📈 Usage Examples

### Opening a Long Position (Foundry Script)

```solidity
// TestOpenLong.s.sol
vm.startBroadcast();

// 1. Approve USDC
IERC20(mockUSDC).approve(address(collateralVault), 1000e6);

// 2. Deposit collateral
collateralVault.deposit(mockUSDC, 1000e6);

// 3. Open position (1 ETH long, no price limit)
clearingHouse.openPosition(
    marketId,
    true,      // isLong
    1e18,      // size (1 ETH)
    0          // priceLimit (market order)
);

vm.stopBroadcast();
```

### Interacting via Frontend (React Hooks)

```javascript
import { useOpenPosition, usePosition } from './hooks/useClearingHouse';

function TradingPanel() {
  const { openPosition, isLoading } = useOpenPosition(marketId);
  const { position } = usePosition(marketId, address);

  const handleTrade = () => {
    openPosition(
      true,           // isLong
      parseEther("1"), // 1 ETH
      0               // market order
    );
  };

  return (
    <div>
      <button onClick={handleTrade} disabled={isLoading}>
        Open Long Position
      </button>
      <div>Current PnL: {position?.realizedPnL}</div>
    </div>
  );
}
```

---

## 🔒 Security

### Implemented Safeguards
✅ Role-based access control (OpenZeppelin AccessControl)
✅ UUPS upgradeability for critical contracts
✅ SafeERC20 for all token transfers
✅ Fee-on-transfer token support
✅ Extensive input validation
✅ IMR/MMR separation for margin safety
✅ Insurance fund backstop
✅ Whitelisted liquidators

### Known Risks
⚠️ No formal security audit
⚠️ Integer overflow risks (TWAP, fee growth in vAMM)
⚠️ Oracle manipulation possible with sustained attacks
⚠️ uint32 timestamp limitation (fails year 2106)
⚠️ No reentrancy guards (relies on checks-effects-interactions)

### Recommended Before Mainnet
1. Comprehensive security audit (Trail of Bits, OpenZeppelin, etc.)
2. Bug bounty program
3. Multi-sig for admin functions
4. Fix vAMM overflow issues
5. Formal verification of core invariants

---

## 📚 Additional Documentation

- [DEVELOPMENT.md](./DEVELOPMENT.md) - Detailed technical documentation
- [vAMM_Analysis.md](./vAMM_Analysis.md) - In-depth vAMM mechanics analysis

---

## 🤝 Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Submit a pull request

---

## 📄 License

MIT License - see LICENSE file for details

---

## 🔗 Links

- **Testnet Explorer**: [Sepolia Etherscan](https://sepolia.etherscan.io)
- **Frontend Demo**: [Coming Soon]
- **Documentation**: This README + DEVELOPMENT.md
- **Support**: [GitHub Issues](https://github.com/YOUR_REPO/issues)

---

## ⚡ Quick Commands Reference

```bash
# Smart Contracts
forge build                    # Compile contracts
forge test -vvv               # Run tests
forge coverage                # Coverage report

# Frontend
cd bytestrike3
npm install                   # Install dependencies
npm run dev                   # Start dev server
npm run build                 # Production build

# Deployment
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast

# Verification
forge verify-contract <address> <contract> --chain sepolia
```

---

**Status**: ✅ Testnet Production-Ready
**Last Updated**: November 26, 2025
**Network**: Sepolia Testnet (Chain ID: 11155111)
**Solidity Version**: 0.8.30
**Frontend Framework**: React 19 + Wagmi v2
