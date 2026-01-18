// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface ICuOracle {
    function updatePrices(bytes32 assetId, uint256 price, uint256 nonce) external;
    function getPrice(string memory symbol) external view returns (uint256);
}

/**
 * @title RevealCuOracleETH
 * @notice Reveals ETH price in CuOracle
 */
contract RevealCuOracleETH is Script {
    address constant CU_ORACLE = 0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c;

    // ETH asset ID (keccak256("ETH"))
    bytes32 constant ETH_ASSET_ID = keccak256(abi.encodePacked("ETH"));

    // Must match commit values
    uint256 constant ETH_PRICE = 3_790_000_000_000_000_000; // 3.79e18
    uint256 constant NONCE = 12345;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  REVEAL ETH PRICE IN CUORACLE");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("CuOracle:", CU_ORACLE);
        console.log("ETH Asset ID:", vm.toString(ETH_ASSET_ID));
        console.log("ETH Price: $3.79");
        console.log("Nonce:", NONCE);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        console.log("Revealing price...");
        ICuOracle(CU_ORACLE).updatePrices(ETH_ASSET_ID, ETH_PRICE, NONCE);
        console.log("Price revealed!");

        vm.stopBroadcast();

        // Verify
        console.log("");
        console.log("Verification:");
        try ICuOracle(CU_ORACLE).getPrice("ETH") returns (uint256 price) {
            console.log("  ETH price:", price);
            console.log("  Price matches:", price == ETH_PRICE);
        } catch {
            console.log("  Could not read ETH price");
        }

        console.log("");
        console.log("=========================================");
        console.log("  REVEAL COMPLETE");
        console.log("=========================================");
    }
}
