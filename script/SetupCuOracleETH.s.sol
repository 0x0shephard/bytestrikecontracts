// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface ICuOracle {
    function registerAsset(bytes32 assetId) external;
    function commitPrice(bytes32 assetId, bytes32 commit) external;
    function updatePrices(bytes32 assetId, uint256 price, uint256 nonce) external;
    function getPrice(string memory symbol) external view returns (uint256);
    function supportedAssets(bytes32 assetId) external view returns (bool);
    function grantRole(address role) external;
}

/**
 * @title SetupCuOracleETH
 * @notice Sets up ETH price in CuOracle
 */
contract SetupCuOracleETH is Script {
    address constant CU_ORACLE = 0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c;

    // ETH asset ID (keccak256("ETH"))
    bytes32 constant ETH_ASSET_ID = keccak256(abi.encodePacked("ETH"));

    // Price: $3.79
    uint256 constant ETH_PRICE = 3_790_000_000_000_000_000; // 3.79e18
    uint256 constant NONCE = 12345;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  SETUP ETH IN CUORACLE");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("CuOracle:", CU_ORACLE);
        console.log("ETH Asset ID:", vm.toString(ETH_ASSET_ID));
        console.log("ETH Price: $3.79");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Grant role to deployer if needed
        console.log("Step 1: Granting role to deployer...");
        try ICuOracle(CU_ORACLE).grantRole(deployer) {
            console.log("  Role granted!");
        } catch {
            console.log("  Already has role or failed");
        }

        // Step 2: Register ETH asset if not already
        console.log("");
        console.log("Step 2: Registering ETH asset...");
        bool isSupported = ICuOracle(CU_ORACLE).supportedAssets(ETH_ASSET_ID);
        if (!isSupported) {
            ICuOracle(CU_ORACLE).registerAsset(ETH_ASSET_ID);
            console.log("  ETH registered!");
        } else {
            console.log("  ETH already registered");
        }

        // Step 3: Commit price
        console.log("");
        console.log("Step 3: Committing price...");
        bytes32 commitHash = keccak256(abi.encodePacked(ETH_PRICE, NONCE));
        console.log("  Commit hash:", vm.toString(commitHash));
        ICuOracle(CU_ORACLE).commitPrice(ETH_ASSET_ID, commitHash);
        console.log("  Price committed!");

        vm.stopBroadcast();

        console.log("");
        console.log("=========================================");
        console.log("  COMMIT COMPLETE");
        console.log("=========================================");
        console.log("");
        console.log("IMPORTANT: Wait at least 1 second, then run:");
        console.log("  RevealCuOracleETH script to reveal the price");
    }
}
