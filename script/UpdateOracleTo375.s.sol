// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IMockOracle {
    function setPrice(uint256 newPrice) external;
    function getPrice() external view returns (uint256);
}

/// @title Update Oracle Price to $3.75
contract UpdateOracleTo375 is Script {
    
    // Your deployed Oracle address from VerifyContracts.sh
    address constant ORACLE = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;
    
    function run() external {
        // Get private key from environment or use the one passed via --private-key
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPrivateKey == 0) {
            // If not in env, the --private-key flag will be used by forge
            deployerPrivateKey = 0x7857dfba6a2faf4f52f5e7b28a28d5a66be4bdf588437d03d5fd5d8522cf8348;
        }
        
        // New price: $3.75 in 1e18 format
        uint256 newPrice = 3_75e16; // 3.75 * 1e18 = 3750000000000000000
        
        console.log("=================================");
        console.log("Updating Oracle Price on Sepolia");
        console.log("=================================");
        console.log("Oracle Address:", ORACLE);
        console.log("New Price: $3.75");
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        IMockOracle oracle = IMockOracle(ORACLE);
        
        // Check current price
        uint256 currentPrice = oracle.getPrice();
        console.log("Current Price (wei):", currentPrice);
        console.log("Current Price (USD):", currentPrice / 1e18);
        
        // Update price
        oracle.setPrice(newPrice);
        console.log("");
        console.log("Price updated successfully!");
        
        // Verify new price
        uint256 updatedPrice = oracle.getPrice();
        console.log("New Price (wei):", updatedPrice);
        console.log("New Price (USD): $3.75");
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=================================");
        console.log("Update Complete!");
        console.log("=================================");
    }
}
