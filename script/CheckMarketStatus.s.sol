// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import "../src/ClearingHouse.sol";
import "../src/MarketRegistry.sol";
import "../src/Interfaces/IMarketRegistry.sol";
import "../src/vAMM.sol";
import "../src/Oracle/MultiAssetOracleAdapter.sol";

/**
 * @notice Quick diagnostic to check why HyperScalers and non-HyperScalers markets aren't working
 */
contract CheckMarketStatus is Script {
    address constant CLEARING_HOUSE = 0x18F863b1b0A3Eca6B2235dc1957291E357f490B0;
    address constant MARKET_REGISTRY = 0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD;

    // Market IDs from addresses.js
    bytes32 constant H100_PERP = 0x2bc0c3f3ef82289c7da8a9335c83ea4f2b5b8bd62b67c4f4e0dba00b304c2937;
    bytes32 constant HYPERSCALERS = 0xf4aa47cc83b0d01511ca8025a996421dda6fbab1764466da4b0de6408d3db2e2;
    bytes32 constant NON_HYPERSCALERS = 0x9d2d658888da74a10ac9263fc14dcac4a834dd53e8edf664b4cc3b2b4a23f214;

    function run() external view {
        console.log("=== Diagnosing Market Status ===\n");

        MarketRegistry registry = MarketRegistry(MARKET_REGISTRY);
        ClearingHouse ch = ClearingHouse(CLEARING_HOUSE);

        checkMarket(registry, ch, H100_PERP, "H100-PERP");
        console.log("");
        checkMarket(registry, ch, HYPERSCALERS, "HyperScalers");
        console.log("");
        checkMarket(registry, ch, NON_HYPERSCALERS, "non-HyperScalers");
    }

    function checkMarket(
        MarketRegistry registry,
        ClearingHouse ch,
        bytes32 marketId,
        string memory name
    ) internal view {
        console.log("Market:", name);
        console.log("Market ID:", vm.toString(marketId));

        // Check if market exists in registry
        try registry.getMarket(marketId) returns (
            IMarketRegistry.Market memory market
        ) {
            console.log("[Registry] Registered: YES");
            console.log("[Registry] vAMM:", market.vamm);
            console.log("[Registry] Oracle:", market.oracle);
            console.log("[Registry] Fee:", market.feeBps, "bps");

            // Check if market is active
            bool isActive = registry.isActive(marketId);
            bool isPaused = registry.isPaused(marketId);
            console.log("[Registry] Active:", isActive);
            console.log("[Registry] Paused:", isPaused);

            address vamm = market.vamm;
            address oracle = market.oracle;

            // Check vAMM
            if (vamm != address(0)) {
                try vAMM(vamm).getMarkPrice() returns (uint256 price) {
                    console.log("[vAMM] Mark Price:", price / 1e18, "USD");
                } catch {
                    console.log("[vAMM] ERROR: Cannot get mark price");
                }

                try vAMM(vamm).oracle() returns (address oracleAddr) {
                    console.log("[vAMM] Oracle address:", oracleAddr);

                    if (oracleAddr != address(0)) {
                        try MultiAssetOracleAdapter(oracleAddr).getPrice() returns (uint256 oraclePrice) {
                            console.log("[Oracle] Price:", oraclePrice / 1e18, "USD");
                        } catch {
                            console.log("[Oracle] ERROR: Cannot get price");
                        }
                    }
                } catch {
                    console.log("[vAMM] ERROR: Cannot get oracle");
                }
            }

            // Check risk parameters in ClearingHouse
            try ch.marketRiskParams(marketId) returns (
                uint256 imrBps,
                uint256 mmrBps,
                uint256 liquidationPenaltyBps,
                uint256 penaltyCap
            ) {
                console.log("[ClearingHouse] Risk Params Set: YES");
                console.log("[ClearingHouse] IMR:", imrBps, "bps");
                console.log("[ClearingHouse] MMR:", mmrBps, "bps");
            } catch {
                console.log("[ClearingHouse] Risk Params Set: NO (THIS WILL PREVENT TRADING!)");
            }
        } catch {
            console.log("[Registry] Registered: NO (MARKET DOES NOT EXIST!)");
        }
    }
}
