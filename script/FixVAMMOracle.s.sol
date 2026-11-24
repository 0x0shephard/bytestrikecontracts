// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IVAMM {
    function oracle() external view returns (address);
}

interface IMarketRegistryOracle {
    function setOracle(bytes32 marketId, address newOracle) external;
}

/**
 * @title FixVAMMOracle
 * @notice Sets the ETH-PERP-V2 market oracle (risk and vAMM funding) back to Chainlink Oracle which has ETH at $3.79
 */
contract FixVAMMOracle is Script {
    address constant VAMM = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;
    address constant CHAINLINK_ORACLE = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;
    address constant MARKET_REGISTRY = 0x937F40013B088832919992E0Bd0D0F48520dC964;
    bytes32 constant MARKET_ID = keccak256("ETH-PERP-V2");

    function run() external {
        address deployer = msg.sender;

        console.log("=========================================");
        console.log("  FIX VAMM ORACLE");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("vAMM:", VAMM);
        console.log("Target Oracle:", CHAINLINK_ORACLE);
        console.log("  (Chainlink Oracle with ETH at $3.79)");
        console.log("");

        // Check current
        address currentOracle = IVAMM(VAMM).oracle();
        console.log("Current Oracle:", currentOracle);
        console.log("");

        vm.startBroadcast();

        console.log("Setting oracle...");
        IMarketRegistryOracle(MARKET_REGISTRY).setOracle(MARKET_ID, CHAINLINK_ORACLE);
        console.log("Oracle updated!");

        vm.stopBroadcast();

        // Verify
        address newOracle = IVAMM(VAMM).oracle();
        console.log("");
        console.log("Verification:");
        console.log("  New Oracle:", newOracle);
        console.log("  Expected:", CHAINLINK_ORACLE);
        console.log("  Match:", newOracle == CHAINLINK_ORACLE);

        console.log("");
        console.log("=========================================");
        console.log("  COMPLETE");
        console.log("=========================================");
    }
}
