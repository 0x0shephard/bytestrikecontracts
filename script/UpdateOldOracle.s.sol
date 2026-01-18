// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IOracle {
    function setPrice(uint256 newPrice) external;
    function getPrice() external view returns (uint256);
}

/// @title UpdateOldOracle
/// @notice Update the old Oracle that vAMM is currently using
contract UpdateOldOracle is Script {
    
    function run() external {
        address oldOracleAddress = 0x31b9fbe750F6aDC8f46C8D8C7fdE32C98DEE2D29;
        uint256 newPrice = 3.75e18; // $3.75
        
        console.log("=================================");
        console.log("Updating Old Oracle Price");
        console.log("=================================");
        console.log("Oracle Address:", oldOracleAddress);
        console.log("New Price: $3.75");
        console.log("");
        
        vm.startBroadcast();
        
        IOracle oracle = IOracle(oldOracleAddress);
        
        // Check current price
        uint256 currentPrice = oracle.getPrice();
        console.log("Current Price (USD): $", currentPrice / 1e18);
        
        // Update price
        oracle.setPrice(newPrice);
        console.log("");
        console.log("Price updated successfully!");
        
        // Verify
        uint256 updatedPrice = oracle.getPrice();
        console.log("New Price (USD): $", updatedPrice / 1e18);
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=================================");
        console.log("Update Complete!");
        console.log("=================================");
    }
}
