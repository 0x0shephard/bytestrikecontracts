// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/ClearingHouse.sol";
import "../src/MarketRegistry.sol";
import "../src/CollateralVault.sol";
import "../src/Interfaces/IMarketRegistry.sol";

/**
 * @title TestMarketAccess
 * @notice Test script to diagnose why HyperScalers and non-HyperScalers markets aren't accessible
 */
contract TestMarketAccess is Script {
    // Contracts
    address constant CLEARING_HOUSE = 0x18F863b1b0A3Eca6B2235dc1957291E357f490B0;
    address constant MARKET_REGISTRY = 0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD;
    address constant COLLATERAL_VAULT = 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2;
    address constant MOCK_USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;

    // Market IDs
    bytes32 constant H100_PERP = 0x2bc0c3f3ef82289c7da8a9335c83ea4f2b5b8bd62b67c4f4e0dba00b304c2937;
    bytes32 constant HYPERSCALERS_PERP = 0xf4aa47cc83b0d01511ca8025a996421dda6fbab1764466da4b0de6408d3db2e2;
    bytes32 constant NON_HYPERSCALERS_PERP = 0x9d2d658888da74a10ac9263fc14dcac4a834dd53e8edf664b4cc3b2b4a23f214;

    function run() external view {
        console.log("=== Testing Market Access ===\n");

        ClearingHouse clearingHouse = ClearingHouse(CLEARING_HOUSE);
        MarketRegistry marketRegistry = MarketRegistry(MARKET_REGISTRY);

        // Test 1: Check if markets are registered
        console.log("Test 1: Checking Market Registration");
        console.log("--------------------------------------");

        checkMarketRegistration(marketRegistry, H100_PERP, "H100-PERP");
        checkMarketRegistration(marketRegistry, HYPERSCALERS_PERP, "H100-HyperScalers-PERP");
        checkMarketRegistration(marketRegistry, NON_HYPERSCALERS_PERP, "H100-non-HyperScalers-PERP");

        console.log("");

        // Test 2: Check risk parameters
        console.log("Test 2: Checking Risk Parameters");
        console.log("----------------------------------");

        checkRiskParams(clearingHouse, H100_PERP, "H100-PERP");
        checkRiskParams(clearingHouse, HYPERSCALERS_PERP, "H100-HyperScalers-PERP");
        checkRiskParams(clearingHouse, NON_HYPERSCALERS_PERP, "H100-non-HyperScalers-PERP");

        console.log("");

        // Test 3: Check if markets are paused
        console.log("Test 3: Checking Market Pause Status");
        console.log("-------------------------------------");

        checkMarketPaused(clearingHouse, H100_PERP, "H100-PERP");
        checkMarketPaused(clearingHouse, HYPERSCALERS_PERP, "H100-HyperScalers-PERP");
        checkMarketPaused(clearingHouse, NON_HYPERSCALERS_PERP, "H100-non-HyperScalers-PERP");

        console.log("\n=== Test Complete ===");
    }

    function checkMarketRegistration(MarketRegistry registry, bytes32 marketId, string memory name) internal view {
        try registry.getMarket(marketId) returns (IMarketRegistry.Market memory market) {
            console.log(string.concat(name, ":"));
            console.log("  Registered: YES");
            console.log("  vAMM:", market.vamm);
            console.log("  Oracle:", market.oracle);
            console.log("  Fee (bps):", market.feeBps);
        } catch {
            console.log(string.concat(name, ":"));
            console.log("  Registered: NO");
        }
    }

    function checkRiskParams(ClearingHouse clearingHouse, bytes32 marketId, string memory name) internal view {
        try clearingHouse.marketRiskParams(marketId) returns (
            uint256 imrBps,
            uint256 mmrBps,
            uint256 liquidationPenaltyBps,
            uint256 penaltyCap,
            uint256 maxPositionSize,
            uint256 minPositionSize
        ) {
            console.log(string.concat(name, ":"));
            console.log("  Risk Params Set: YES");
            console.log("  IMR (bps):", imrBps);
            console.log("  MMR (bps):", mmrBps);
            console.log("  Liq Penalty (bps):", liquidationPenaltyBps);
            console.log("  Penalty Cap:", penaltyCap / 1e18, "USD");
            console.log("  Max Position Size:", maxPositionSize);
            console.log("  Min Position Size:", minPositionSize);
        } catch {
            console.log(string.concat(name, ":"));
            console.log("  Risk Params Set: NO");
        }
    }

    function checkMarketPaused(ClearingHouse clearingHouse, bytes32 marketId, string memory name) internal view {
        MarketRegistry registry = MarketRegistry(MARKET_REGISTRY);
        try registry.isPaused(marketId) returns (bool paused) {
            console.log(string.concat(name, ":"));
            console.log("  Paused:", paused ? "YES" : "NO");
        } catch {
            console.log(string.concat(name, ":"));
            console.log("  Cannot check pause status");
        }
    }
}
