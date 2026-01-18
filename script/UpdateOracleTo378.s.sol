// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";


interface IUpdatableOracle {
    function updatePrice(uint256 newPrice) external;
    function getPrice() external view returns (uint256);
}

/// @title Update Oracle Price to $3.78
contract UpdateOracleTo378 is Script {

    // Index oracle address for H100 GPU rental price
    address constant ORACLE = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;

    function run() external {
        // Get private key from environment or use the one passed via --private-key
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPrivateKey == 0) {
            // If not in env, the --private-key flag will be used by forge
            deployerPrivateKey = 0x7857dfba6a2faf4f52f5e7b28a28d5a66be4bdf588437d03d5fd5d8522cf8348;
        }

        // New price: $3.78 in 1e18 format
        uint256 newPrice = 3_78e16; // 3.78 * 1e18 = 3780000000000000000

        console.log("=================================");
        console.log("Updating Oracle Price on Sepolia");
        console.log("=================================");
        console.log("Oracle Address:", ORACLE);
        console.log("New Price: $3.78 (H100 GPU rental rate)");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        IUpdatableOracle oracle = IUpdatableOracle(ORACLE);

        // Check current price
        uint256 currentPrice = oracle.getPrice();
        console.log("Current Price (wei):", currentPrice);
        console.log("Current Price (USD): $", currentPrice / 1e16, ".", (currentPrice % 1e16) / 1e14);

        // Update price
        oracle.updatePrice(newPrice);
        console.log("");
        console.log("Price updated successfully!");

        // Verify new price
        uint256 updatedPrice = oracle.getPrice();
        console.log("New Price (wei):", updatedPrice);
        console.log("New Price (USD): $3.78");

        vm.stopBroadcast();

        console.log("");
        console.log("=================================");
        console.log("Update Complete!");
        console.log("=================================");
    }
}
