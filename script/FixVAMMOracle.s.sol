// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IVAMM {
    function setOracle(address oracle) external;
    function oracle() external view returns (address);
}

/**
 * @title FixVAMMOracle
 * @notice Sets vAMM oracle back to Chainlink Oracle which has ETH at $3.79
 */
contract FixVAMMOracle is Script {
    address constant VAMM = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;
    address constant CHAINLINK_ORACLE = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

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

        vm.startBroadcast(deployerPrivateKey);

        console.log("Setting oracle...");
        IVAMM(VAMM).setOracle(CHAINLINK_ORACLE);
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
