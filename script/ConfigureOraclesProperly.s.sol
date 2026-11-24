// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CuOracleAdapter} from "../src/Oracle/CuOracleAdapter.sol";

interface IMarketRegistryOracle {
    function setOracle(bytes32 marketId, address newOracle) external;
}

/**
 * @title ConfigureOraclesProperly
 * @notice Sets up oracles correctly:
 *   - CuOracle: ETH index price (for funding rate)
 *   - Chainlink Oracle: USDC and other token prices
 *   - ETH-PERP-V2 market (risk and vAMM funding): uses a CuOracleAdapter for the CuOracle ETH price
 * @dev The CuOracle itself has no getPrice(), so the market is pointed at an adapter, through
 *      MarketRegistry.setOracle (the only way to move the vAMM's oracle). The ETH price must already be
 *      revealed in the CuOracle: setOracle reverts while the adapter cannot report a price.
 */
contract ConfigureOraclesProperly is Script {
    address constant VAMM = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;
    address constant CU_ORACLE = 0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c;
    address constant CHAINLINK_ORACLE = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;
    address constant MARKET_REGISTRY = 0x937F40013B088832919992E0Bd0D0F48520dC964;
    bytes32 constant MARKET_ID = keccak256("ETH-PERP-V2");
    bytes32 constant ETH_ASSET_ID = keccak256("ETH");

    function run() external {
        address deployer = msg.sender;

        console.log("=========================================");
        console.log("  CONFIGURE ORACLES PROPERLY");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("");
        console.log("Plan:");
        console.log("  1. Update vAMM to use CuOracle for ETH index price");
        console.log("  2. Set ETH index price in CuOracle ($3.79)");
        console.log("  3. Chainlink Oracle keeps USDC price");
        console.log("");

        vm.startBroadcast();

        // Step 1: Point the market (registry and vAMM) at a CuOracle adapter
        console.log("Step 1: Updating market oracle to a CuOracle adapter...");
        CuOracleAdapter adapter = new CuOracleAdapter(CU_ORACLE, ETH_ASSET_ID, 12 hours);
        IMarketRegistryOracle(MARKET_REGISTRY).setOracle(MARKET_ID, address(adapter));
        console.log("  market oracle updated to:", address(adapter));
        console.log("");

        // Step 2: Set ETH price in CuOracle
        // Note: CuOracle uses commit-reveal, so we need to:
        // - Commit the price hash first
        // - Wait 5 minutes
        // - Reveal the price

        console.log("Step 2: Setting ETH index price in CuOracle...");
        console.log("  Note: CuOracle uses commit-reveal mechanism");
        console.log("  You'll need to:");
        console.log("    1. Commit price hash");
        console.log("    2. Wait 5 minutes");
        console.log("    3. Reveal price");
        console.log("");
        console.log("  For now, check if CuOracle has a direct set function...");

        vm.stopBroadcast();

        // Verify
        (bool success2, bytes memory data) = VAMM.staticcall(
            abi.encodeWithSignature("oracle()")
        );
        if (success2) {
            address newOracle = abi.decode(data, (address));
            console.log("Verification:");
            console.log("  vAMM oracle now:", newOracle);
            console.log("  Expected:", address(adapter));
            console.log("  Match:", newOracle == address(adapter) ? "YES" : "NO");
        }

        console.log("");
        console.log("=========================================");
        console.log("  CONFIGURATION COMPLETE");
        console.log("=========================================");
        console.log("");
        console.log("Next Steps:");
        console.log("  1. Update ETH index price in CuOracle ($3.79)");
        console.log("  2. Keep USDC price in Chainlink Oracle ($1.00)");
        console.log("  3. Test funding rate calculation");
    }
}
