# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

ByteStrike is a perpetual futures DEX for trading GPU compute pricing (H100, H200 hourly rental rates). It uses a virtual AMM (vAMM) model with margin-based perpetual futures. Built on Foundry with Solidity 0.8.28.

## Commands

```bash
# Build
forge build

# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run a single test file
forge test --match-path test/ClearingHouseTest.t.sol -vvv

# Run a single test function
forge test --match-test testLiquidation -vvv

# Gas report
forge test --gas-report

# Coverage
forge coverage
```

## Architecture

### Contract Roles

| Contract | Purpose |
|----------|---------|
| `ClearingHouse.sol` | Main orchestrator — deposits, positions, liquidations, funding settlement. UUPS upgradeable. |
| `CollateralVault.sol` | Custody/accounting for user collateral; supports multiple tokens and fee-on-transfer. |
| `vAMM.sol` | Virtual AMM (constant product, x*y=k) for price discovery and trade execution. UUPS upgradeable. |
| `MarketRegistry.sol` | Registry of all perpetual markets and their configurations. |
| `FeeRouter.sol` | Splits trading/liquidation fees between InsuranceFund and Treasury. |
| `InsuranceFund.sol` | Backstop for bad debt; gracefully pays what it can if underfunded. |
| `Oracle/CuOracle.sol` | Commit-reveal oracle for GPU prices (prevents front-running). |

### Key Design Decisions

- **Fixed-point math**: WAD precision (1e18). All prices and rates are `X18` suffixed when scaled.
- **Separate funding accumulators**: Longs and shorts have separate `cumulativeLongPay/ReceivePerUnit` and `cumulativeShortPay/ReceivePerUnit` indices in vAMM.
- **Fee-on-transfer support**: Vault and FeeRouter use balance-delta pattern (`balanceAfter - balanceBefore`) for accurate token accounting.
- **UUPS proxies**: ClearingHouse and vAMM are upgradeable; other contracts are not.
- **`ReentrancyGuardTransient`**: Uses EIP-1153 transient storage (ERC-6780) for reentrancy protection in ClearingHouse.
- **Self-external calls**: ClearingHouse calls `this.isLiquidatable()` via external call to work around internal visibility patterns.

### Position Flow

Open: settle funding → check liquidatability → swap on vAMM → apply IMR check → route fees
Close: settle funding → reverse swap → calculate realized PnL → return margin to vault
Liquidate: settle funding → check MMR breach → close at market → split penalty (liquidator 50% / insurance) → handle bad debt

### Risk Parameters (bps)

- `imrBps`: Initial Margin Requirement (typically 500 = 5%, 20x leverage)
- `mmrBps`: Maintenance Margin Requirement (typically 250 = 2.5%)
- `liquidationPenaltyBps`: Penalty charged on liquidation (typically 200 = 2%)
- `penaltyCap`: Absolute cap on liquidation penalty

### Test Setup

Tests inherit from `test/BaseTest.sol` which deploys the full protocol stack. Key accounts: `admin`, `treasury`, `alice`, `bob`, `liquidator`. Key constants: `IMR_BPS=500`, `MMR_BPS=250`, `TRADE_FEE_BPS=10`.

`test/findingsTest.t.sol` contains audit finding reproductions — do not delete these tests.
