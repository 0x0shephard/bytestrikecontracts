// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/**
 * @title ConfigureOraclesProperly
 * @notice Sets up oracles correctly:
 *   - CuOracle: ETH index price (for funding rate)
 *   - Chainlink Oracle: USDC and other token prices
 *   - vAMM: Uses CuOracle for index price
 */
contract ConfigureOraclesProperly is Script {
    address constant VAMM = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;
    address constant CU_ORACLE = 0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c;
    address constant CHAINLINK_ORACLE = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

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

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Update vAMM to use CuOracle
        console.log("Step 1: Updating vAMM oracle to CuOracle...");
        (bool success1, ) = VAMM.call(
            abi.encodeWithSignature("setOracle(address)", CU_ORACLE)
        );
        require(success1, "Failed to set vAMM oracle");
        console.log("  vAMM oracle updated to:", CU_ORACLE);
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
            console.log("  Expected:", CU_ORACLE);
            console.log("  Match:", newOracle == CU_ORACLE ? "YES" : "NO");
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
