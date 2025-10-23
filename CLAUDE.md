# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Foundry-based Solidity project implementing oracle systems for price feeds. The project includes two distinct oracle implementations:

1. **Oracle (Chainlink-based)**: A production-ready oracle that integrates with Chainlink price feeds, includes L2 sequencer uptime checks, and supports per-token staleness periods
2. **CuOracle (Commit-Reveal)**: A custom oracle implementation using a commit-reveal scheme to prevent front-running attacks

## Development Commands

### Build
```bash
forge build
```

### Testing
```bash
# Run all tests with verbose output
forge test -vvv

# Run specific test file
forge test --match-path test/YourTest.t.sol -vvv

# Run specific test function
forge test --match-test testFunctionName -vvv
```

### Formatting
```bash
# Check formatting
forge fmt --check

# Format all Solidity files
forge fmt
```

### Gas Analysis
```bash
# Create gas snapshots
forge snapshot

# Show contract sizes
forge build --sizes
```

### Local Development
```bash
# Start local Ethereum node
anvil

# Deploy contracts (example from README)
forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

## Architecture

### Oracle System Design

The project implements a dual-oracle architecture:

#### 1. Chainlink Oracle (`src/Oracle/Oracle.sol`)
- **Purpose**: Provides reliable price feeds using Chainlink's decentralized oracle network
- **Key Features**:
  - Normalizes prices to 18 decimals regardless of feed decimals
  - L2 sequencer uptime validation to prevent stale prices on Layer 2 networks
  - Global and per-token staleness period configuration
  - Support for underlying price calculations (normalized by base unit)
- **Price Access Methods**:
  - `getPrice(string tokenSymbol)`: Returns price normalized to 1e18
  - `getUnderlyingPrice(string tokenSymbol)`: Returns price normalized for token's base unit
- **Owner Controls**: Set price feeds, base units, sequencer uptime feed, staleness periods

#### 2. Commit-Reveal Oracle (`src/Oracle/CuOracle.sol`)
- **Purpose**: Custom oracle with front-running protection via commit-reveal pattern
- **Key Features**:
  - Two-phase price update: commit hash first, reveal price + nonce later
  - Configurable minimum time interval between updates
  - Role-based access control for price commits (owner-only reveals)
  - Asset registration system with per-asset price tracking
- **Workflow**:
  1. Allowed role calls `commitPrice(assetId, hash)` where hash = keccak256(price, nonce)
  2. Wait for minimum time interval
  3. Owner calls `updatePrices(assetId, price, nonce)` to reveal and set price
- **Data Structure**: Returns `PriceData` struct with `price` (1e18 scaled) and `lastUpdatedAt` timestamp

#### 3. CuOracle Adapter (`src/Oracle/CuOracleAdapter.sol`)
- **Purpose**: Wraps CuOracle to conform to the standard `IOracle` interface
- **Key Features**:
  - Immutable configuration (oracle address, assetId, maxAge)
  - Optional staleness check via `maxAge` parameter (0 disables)
  - Simple `getPrice()` interface for integration
- **Use Case**: Allows CuOracle to be used anywhere an `IOracle` interface is expected

### Interface Standards

- **IOracle** (`src/Interfaces/IOracle.sol`): Minimal interface with single `getPrice()` method returning uint256
- **AggregatorV3Interface** (`src/Oracle/Interfaces/AggregatorV3Interface.sol`): Chainlink's standard interface for price feed aggregators

### Key Architectural Patterns

1. **Price Normalization**: Both oracles normalize prices to 1e18 scale for consistency
2. **Staleness Protection**: Both implement time-based staleness checks (Oracle via configurable periods, CuOracle via commit-reveal timing + adapter maxAge)
3. **Adapter Pattern**: CuOracleAdapter demonstrates how to wrap complex oracles behind simple interfaces
4. **Access Control**: CuOracle uses role-based access (commit vs reveal permissions), Oracle uses simple owner control

## Configuration

- **Solidity Version**: 0.8.30 (strictly enforced)
- **Foundry Profile**: Default profile uses `src/`, `out/`, and `lib/` directories
- **CI Profile**: Set via `FOUNDRY_PROFILE=ci` in GitHub Actions

## CI/CD

The project uses GitHub Actions (`.github/workflows/test.yml`) with three checks:
1. **forge fmt --check**: Ensures code formatting compliance
2. **forge build --sizes**: Compiles contracts and shows sizes
3. **forge test -vvv**: Runs full test suite with maximum verbosity
