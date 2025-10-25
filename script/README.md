# ByteStrike Deployment Scripts

This directory contains deployment scripts for the ByteStrike perpetual vAMM protocol.

## Overview

ByteStrike has been refactored to focus on:
- **Perpetual markets only** (no futures with expiry)
- **vAMM model only** (no liquidity pools)
- **Simplified architecture** with cleaner contracts

## Available Scripts

### 1. Deploy.s.sol
Main deployment script using actual oracle infrastructure (CuOracle).

**Features:**
- Uses CuOracle with commit-reveal price updates
- Suitable for production/mainnet deployment
- Requires GPU compute unit pricing oracle setup

**Usage:**
```bash
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
```

### 2. DeployWithMocks.s.sol
Simplified deployment using MockOracle for testing.

**Features:**
- Uses simple MockOracle (no Chainlink/CuOracle complexity)
- Perfect for local testing and development
- Easy price manipulation for testing scenarios
- Mints test tokens automatically

**Usage:**
```bash
# Local testing (Anvil)
anvil
forge script script/DeployWithMocks.s.sol --rpc-url http://localhost:8545 --broadcast

# Testnet deployment
forge script script/DeployWithMocks.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
```

## Configuration

### Environment Variables

Create a `.env` file:
```bash
# Required
ADMIN_ADDRESS=0x...
TREASURY_ADDRESS=0x...

# Optional (defaults provided)
INITIAL_ORACLE_PRICE_X18=2000000000000000000000  # $2000 in 1e18
INITIAL_BASE_RESERVE=1000000000000000000000      # 1000 ETH
INITIAL_LIQUIDITY_INDEX=1000000000000000000000000 # 1e24
TRADE_FEE_BPS=10                                  # 0.1%
FUNDING_MAX_BPS_PER_HOUR=100                      # 1% max
FUNDING_K_X18=1000000000000000000                 # 1e18
OBSERVATION_WINDOW=3600                           # 1 hour
FEE_ROUTER_TRADE_FEE_TO_INSURANCE_BPS=5000       # 50%
FEE_ROUTER_LIQ_PENALTY_TO_INSURANCE_BPS=5000     # 50%
IMR_BPS=500                                       # 5%
MMR_BPS=250                                       # 2.5%
LIQUIDATION_PENALTY_BPS=200                       # 2%
PENALTY_CAP=10000000000                           # 10k USDC (6 decimals)
```

## Deployment Architecture

### Contracts Deployed

1. **CollateralVault** - Holds user collateral (multi-token support)
2. **MarketRegistry** - Registry for perpetual markets
3. **ClearingHouse** - Main trading engine (UUPS upgradeable)
4. **vAMM** - Virtual AMM for each market (UUPS upgradeable)
5. **InsuranceFund** - Protocol insurance reserves
6. **FeeRouter** - Routes fees between treasury and insurance fund
7. **Oracle** - Price oracle (MockOracle or CuOracle)

### Deployment Flow

```
1. Deploy Oracle
2. Deploy CollateralVault + set oracle
3. Deploy MarketRegistry
4. Deploy ClearingHouse (upgradeable)
5. Deploy vAMM (upgradeable)
6. Deploy InsuranceFund
7. Deploy FeeRouter
8. Wire contracts together
9. Register collateral tokens
10. Register market in MarketRegistry
11. Set risk parameters in ClearingHouse
```

## Post-Deployment Testing

### Using MockOracle (from DeployWithMocks)

After deployment, you can test the system:

```bash
# 1. Update oracle price
cast send $ORACLE_ADDRESS "setPrice(uint256)" 2500000000000000000000 --rpc-url $RPC_URL

# 2. Approve and deposit collateral
cast send $QUOTE_TOKEN "approve(address,uint256)" $CLEARING_HOUSE 1000000000 --rpc-url $RPC_URL
cast send $CLEARING_HOUSE "deposit(address,uint256)" $QUOTE_TOKEN 1000000000 --rpc-url $RPC_URL

# 3. Open a position (go long 1 ETH)
cast send $CLEARING_HOUSE "openPosition(bytes32,bool,uint128,uint256)" \
  $MARKET_ID \
  true \
  1000000000000000000 \
  0 \
  --rpc-url $RPC_URL

# 4. Check position
cast call $CLEARING_HOUSE "getPosition(address,bytes32)" $YOUR_ADDRESS $MARKET_ID --rpc-url $RPC_URL

# 5. Update price and check unrealized PnL
cast send $ORACLE_ADDRESS "setPrice(uint256)" 2100000000000000000000 --rpc-url $RPC_URL
```

## Key Differences from Original

The deployment scripts have been updated to reflect the refactored architecture:

### Removed
- ❌ `IMarketRegistry.MarketType` enum (Perpetual/Future)
- ❌ `IMarketRegistry.ModelType` enum (VAMM/Pool)
- ❌ Futures-specific parameters (expiry, settlement)
- ❌ Pool-specific parameters (liquidityPool)
- ❌ MarketLib (no longer needed with simplified flags)
- ❌ `clearingHouse.registerMarket()` (now done via MarketRegistry)

### Simplified
- ✅ Market struct only has `bool paused` instead of complex flags
- ✅ Direct `marketRegistry.addMarket()` with simple config
- ✅ Only 9 parameters for market config (down from 13+)
- ✅ ClearingHouse focused on perpetuals only

## Risk Parameters

Default risk parameters (adjust for your use case):

| Parameter | Default | Description |
|-----------|---------|-------------|
| IMR | 5% (500 bps) | Initial margin requirement |
| MMR | 2.5% (250 bps) | Maintenance margin requirement |
| Liquidation Penalty | 2% (200 bps) | Penalty on liquidation |
| Penalty Cap | 10k USDC | Max liquidation penalty |
| Trade Fee | 0.1% (10 bps) | Fee on each trade |
| Fee to Insurance | 50% | % of fees to insurance fund |

## Troubleshooting

### Common Issues

1. **"Not Allowed" errors**
   - Ensure ClearingHouse is set in CollateralVault via `setClearinghouse()`
   - Ensure admin has `MARKET_ADMIN_ROLE` in MarketRegistry

2. **"Market does not exist"**
   - Verify market was registered via `marketRegistry.addMarket()`
   - Check correct marketId is being used

3. **Oracle price issues**
   - MockOracle: Use `setPrice()` to update
   - CuOracle: Follow commit-reveal pattern

4. **Funding rate not updating**
   - Call `settleFunding()` or `pokeFunding()` on vAMM
   - Ensure sufficient time has passed (uses block.timestamp)

## Security Notes

⚠️ **Before Mainnet:**
- [ ] Complete security audit
- [ ] Verify all access controls
- [ ] Test liquidation mechanisms thoroughly
- [ ] Ensure oracle price feeds are reliable
- [ ] Test upgrade mechanisms for UUPS contracts
- [ ] Verify all role assignments
- [ ] Test emergency pause functionality
- [ ] Fund insurance fund adequately

## Network Deployments

Add deployment addresses here after deploying:

### Sepolia Testnet
```
Oracle: 0x...
MarketRegistry: 0x...
CollateralVault: 0x...
ClearingHouse: 0x...
InsuranceFund: 0x...
FeeRouter: 0x...
ETH-PERP vAMM: 0x...
```

### Arbitrum Sepolia
```
Coming soon...
```

### Mainnet
```
Not yet deployed
```

## Support

For issues or questions:
- Check CLAUDE.md for architecture details
- Review vAMM_Analysis.md for technical specifics
- Open an issue on GitHub
