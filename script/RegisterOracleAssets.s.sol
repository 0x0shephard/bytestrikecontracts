// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/Oracle/MultiAssetOracle.sol";

/**
 * @title RegisterOracleAssets
 * @notice Registers assets in the deployed MultiAssetOracle
 */
contract RegisterOracleAssets is Script {
    address constant MULTI_ASSET_ORACLE = 0xB44d652354d12Ac56b83112c6ece1fa2ccEfc683;

    bytes32 constant H100_ASSET_ID = keccak256("H100_HOURLY");
    bytes32 constant H100_HYPERSCALERS_ASSET_ID = keccak256("H100_HYPERSCALERS_HOURLY");
    bytes32 constant H100_NON_HYPERSCALERS_ASSET_ID = keccak256("H100_NON_HYPERSCALERS_HOURLY");

    uint256 constant H100_PRICE = 3_790_000_000_000_000_000;
    uint256 constant H100_HYPERSCALERS_PRICE = 4_202_163_309_021_113_000;
    uint256 constant H100_NON_HYPERSCALERS_PRICE = 2_946_243_092_754_190_000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Registering Oracle Assets ===");
        console.log("MultiAssetOracle:", MULTI_ASSET_ORACLE);

        vm.startBroadcast(deployerPrivateKey);

        MultiAssetOracle oracle = MultiAssetOracle(MULTI_ASSET_ORACLE);

        if (!oracle.isAssetRegistered(H100_ASSET_ID)) {
            oracle.registerAsset(H100_ASSET_ID, H100_PRICE);
            console.log("Registered H100 asset at $3.79");
        } else {
            console.log("H100 asset already registered");
        }

        if (!oracle.isAssetRegistered(H100_HYPERSCALERS_ASSET_ID)) {
            oracle.registerAsset(H100_HYPERSCALERS_ASSET_ID, H100_HYPERSCALERS_PRICE);
            console.log("Registered H100-HyperScalers asset at $4.20");
        } else {
            console.log("H100-HyperScalers asset already registered");
        }

        if (!oracle.isAssetRegistered(H100_NON_HYPERSCALERS_ASSET_ID)) {
            oracle.registerAsset(H100_NON_HYPERSCALERS_ASSET_ID, H100_NON_HYPERSCALERS_PRICE);
            console.log("Registered H100-non-HyperScalers asset at $2.95");
        } else {
            console.log("H100-non-HyperScalers asset already registered");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== REGISTRATION COMPLETE ===");
    }
}
