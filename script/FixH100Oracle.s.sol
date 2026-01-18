// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/Oracle/MultiAssetOracleAdapter.sol";
import "../src/vAMM.sol";

/**
 * @title FixH100Oracle
 * @notice Deploys the missing H100 oracle adapter and updates the H100 vAMM to use it
 *
 * Run with:
 * forge script script/FixH100Oracle.s.sol:FixH100Oracle --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
 */
contract FixH100Oracle is Script {
    // Existing infrastructure
    address constant MULTI_ASSET_ORACLE = 0xB44d652354d12Ac56b83112c6ece1fa2ccEfc683;
    address constant H100_VAMM = 0xF7210ccC245323258CC15e0Ca094eBbe2DC2CD85;

    // Asset ID
    bytes32 constant H100_ASSET_ID = 0x82af7da7090d6235dbc9f8cfccfb82eee2e9cb33d50be18eabf66c158261796a; // keccak256("H100_HOURLY")

    // Oracle settings
    uint256 constant ORACLE_MAX_AGE = 86400; // 24 hours

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Fixing H100 Oracle ===");
        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy H100 Oracle Adapter
        console.log("Step 1: Deploying H100 Oracle Adapter...");
        MultiAssetOracleAdapter h100Adapter = new MultiAssetOracleAdapter(
            MULTI_ASSET_ORACLE,
            H100_ASSET_ID,
            ORACLE_MAX_AGE
        );
        console.log("H100 Oracle Adapter deployed at:", address(h100Adapter));
        console.log("");

        // Update H100 vAMM to use new oracle
        console.log("Step 2: Updating H100 vAMM oracle...");
        vAMM(H100_VAMM).setOracle(address(h100Adapter));
        console.log("H100 vAMM oracle updated to:", address(h100Adapter));
        console.log("");

        // Verify oracle works
        console.log("Step 3: Verifying oracle...");
        uint256 price = h100Adapter.getPrice();
        console.log("H100 Oracle Price:", price / 1e18, ".", (price % 1e18) / 1e15);
        console.log("");

        vm.stopBroadcast();

        console.log("=== H100 Oracle Fix Complete ===");
        console.log("Update addresses.js with:");
        console.log("  h100OracleAdapter: '", address(h100Adapter), "',");
    }
}
