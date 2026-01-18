// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/Oracle/MultiAssetOracle.sol";

/**
 * @title UpdateH200ProviderPrices
 * @notice Updates prices for all H200 provider-specific markets
 *
 * Update the price constants below with current market rates before running.
 *
 * Run with:
 * forge script script/UpdateH200ProviderPrices.s.sol:UpdateH200ProviderPrices --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
 */
contract UpdateH200ProviderPrices is Script {
    address constant MULTI_ASSET_ORACLE = 0xB44d652354d12Ac56b83112c6ece1fa2ccEfc683;

    // Asset IDs (keccak256 of asset names)
    bytes32 constant ORACLE_H200_ASSET_ID = keccak256("ORACLE_H200_HOURLY");
    bytes32 constant AWS_H200_ASSET_ID = keccak256("AWS_H200_HOURLY");
    bytes32 constant COREWEAVE_H200_ASSET_ID = keccak256("COREWEAVE_H200_HOURLY");
    bytes32 constant GCP_H200_ASSET_ID = keccak256("GCP_H200_HOURLY");

    // ============================================================
    // UPDATE THESE PRICES BEFORE RUNNING
    // ============================================================
    uint256 constant ORACLE_H200_PRICE = 6_470_000_000_000_000_000; // $6.47/hour
    uint256 constant AWS_H200_PRICE = 4_040_000_000_000_000_000; // $4.04/hour
    uint256 constant COREWEAVE_H200_PRICE = 14_530_000_000_000_000_000; // $14.53/hour
    uint256 constant GCP_H200_PRICE = 6_600_000_000_000_000_000; // $6.60/hour

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Updating H200 Provider Prices ===");
        console.log("Caller:", deployer);
        console.log("MultiAssetOracle:", MULTI_ASSET_ORACLE);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        MultiAssetOracle oracle = MultiAssetOracle(MULTI_ASSET_ORACLE);

        // Update Oracle H200
        console.log("Updating Oracle H200 price to:", ORACLE_H200_PRICE / 1e18, "USD/hour");
        oracle.updatePrice(ORACLE_H200_ASSET_ID, ORACLE_H200_PRICE);

        // Update AWS H200
        console.log("Updating AWS H200 price to:", AWS_H200_PRICE / 1e18, "USD/hour");
        oracle.updatePrice(AWS_H200_ASSET_ID, AWS_H200_PRICE);

        // Update CoreWeave H200
        console.log("Updating CoreWeave H200 price to:", COREWEAVE_H200_PRICE / 1e18, "USD/hour");
        oracle.updatePrice(COREWEAVE_H200_ASSET_ID, COREWEAVE_H200_PRICE);

        // Update GCP H200
        console.log("Updating GCP H200 price to:", GCP_H200_PRICE / 1e18, "USD/hour");
        oracle.updatePrice(GCP_H200_ASSET_ID, GCP_H200_PRICE);

        vm.stopBroadcast();

        console.log("");
        console.log("=== All Prices Updated Successfully ===");
        console.log("");

        // Verify updates
        console.log("Verification:");
        console.log("  Oracle H200:", oracle.prices(ORACLE_H200_ASSET_ID) / 1e18, "USD/hour");
        console.log("  AWS H200:", oracle.prices(AWS_H200_ASSET_ID) / 1e18, "USD/hour");
        console.log("  CoreWeave H200:", oracle.prices(COREWEAVE_H200_ASSET_ID) / 1e18, "USD/hour");
        console.log("  GCP H200:", oracle.prices(GCP_H200_ASSET_ID) / 1e18, "USD/hour");
        console.log("");
        console.log("Last updated:", block.timestamp);
    }

    // Helper function to calculate price in 1e18 format
    // Example: priceInWAD(6.47) = 6_470_000_000_000_000_000
    function priceInWAD(uint256 dollars, uint256 cents) public pure returns (uint256) {
        return (dollars * 1e18) + (cents * 1e16);
    }
}
