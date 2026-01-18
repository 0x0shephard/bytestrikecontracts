// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CuOracleAdapter} from "../src/Oracle/CuOracleAdapter.sol";

interface ICuOracle {
    function updatePrices(bytes32 assetId, uint256 price, uint256 nonce) external;
    function commitPrice(bytes32 assetId, bytes32 commitHash) external;
    function latestPrices(bytes32 assetId) external view returns (uint256 price, uint256 lastUpdatedAt);
    function registerAsset(bytes32 assetId) external;
    function supportedAssets(bytes32 assetId) external view returns (bool);
}

interface IVAMM {
    function setOracle(address oracle) external;
    function oracle() external view returns (address);
}

contract FixIndexPrice is Script {
    address constant CU_ORACLE = 0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c;
    address constant VAMM = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;

    bytes32 constant ETH_ASSET_ID = keccak256("ETH");
    uint256 constant ETH_PRICE = 3_790_000_000_000_000_000; // $3.79
    uint256 constant NONCE = 99999;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  FIX INDEX PRICE");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("ETH Price: $3.79");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Register ETH asset if needed
        console.log("Step 1: Registering ETH asset...");
        try ICuOracle(CU_ORACLE).registerAsset(ETH_ASSET_ID) {
            console.log("  ETH registered!");
        } catch Error(string memory reason) {
            console.log("  Already registered or failed:", reason);
        }

        // Step 2: Commit price to CuOracle
        console.log("");
        console.log("Step 2: Committing ETH price to CuOracle...");
        bytes32 commitHash = keccak256(abi.encodePacked(ETH_PRICE, NONCE));
        try ICuOracle(CU_ORACLE).commitPrice(ETH_ASSET_ID, commitHash) {
            console.log("  Committed!");
        } catch Error(string memory reason) {
            console.log("  Commit failed:", reason);
        }

        vm.stopBroadcast();

        // Wait for commit-reveal delay
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 30);

        vm.startBroadcast(deployerPrivateKey);

        // Step 2: Reveal price
        console.log("");
        console.log("Step 2: Revealing ETH price...");
        try ICuOracle(CU_ORACLE).updatePrices(ETH_ASSET_ID, ETH_PRICE, NONCE) {
            console.log("  Price revealed!");
        } catch Error(string memory reason) {
            console.log("  Reveal failed:", reason);
        }

        // Step 3: Deploy CuOracleAdapter for ETH
        console.log("");
        console.log("Step 3: Deploying CuOracleAdapter for ETH...");
        CuOracleAdapter adapter = new CuOracleAdapter(
            CU_ORACLE,
            ETH_ASSET_ID,
            3600 // 1 hour max age
        );
        console.log("  Adapter deployed:", address(adapter));

        // Step 4: Test adapter
        try adapter.getPrice() returns (uint256 price) {
            console.log("  Adapter price:", price);
        } catch Error(string memory reason) {
            console.log("  Adapter test failed:", reason);
        }

        // Step 5: Set vAMM oracle to adapter
        console.log("");
        console.log("Step 4: Setting vAMM oracle to adapter...");
        IVAMM(VAMM).setOracle(address(adapter));
        console.log("  Oracle updated!");

        vm.stopBroadcast();

        // Verification
        address vammOracle = IVAMM(VAMM).oracle();
        (uint256 cuPrice,) = ICuOracle(CU_ORACLE).latestPrices(ETH_ASSET_ID);

        console.log("");
        console.log("=========================================");
        console.log("  VERIFICATION");
        console.log("=========================================");
        console.log("  CuOracle ETH Price:", cuPrice);
        console.log("  Adapter Address:", address(adapter));
        console.log("  vAMM Oracle:", vammOracle);
        console.log("  Match:", vammOracle == address(adapter));
        console.log("");
        console.log("=========================================");
        console.log("  COMPLETE");
        console.log("=========================================");
    }
}
