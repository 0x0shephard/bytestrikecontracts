// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IMarketRegistry {
    function updateMarket(
        bytes32 marketId,
        address vamm,
        uint256 imr,
        uint256 mmr,
        uint256 maxLeverage
    ) external;
    
    function getMarket(bytes32 marketId) external view returns (
        address vamm,
        uint256 imr,
        uint256 mmr,
        uint256 maxLeverage,
        bool isActive
    );
}

/// @title UpdateMarketRegistry
/// @notice Update MarketRegistry to use new vAMM
contract UpdateMarketRegistry is Script {
    
    function run() external {
        address marketRegistryAddress = 0x937F40013B088832919992E0Bd0D0F48520dC964;
        address newVAMMAddress = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;
        
        // ETH-PERP market ID
        bytes32 ethPerpMarketId = keccak256("ETH-PERP");
        
        console.log("=================================");
        console.log("Updating MarketRegistry");
        console.log("=================================");
        console.log("Market Registry:", marketRegistryAddress);
        console.log("New vAMM:", newVAMMAddress);
        console.log("Market ID: ETH-PERP");
        console.log("");
        
        vm.startBroadcast();
        
        IMarketRegistry registry = IMarketRegistry(marketRegistryAddress);
        
        // Get current market config
        (address oldVamm, uint256 imr, uint256 mmr, uint256 maxLeverage, bool isActive) = 
            registry.getMarket(ethPerpMarketId);
        
        console.log("Current Configuration:");
        console.log("Old vAMM:", oldVamm);
        console.log("IMR:", imr);
        console.log("MMR:", mmr);
        console.log("Max Leverage:", maxLeverage);
        console.log("Is Active:", isActive);
        console.log("");
        
        // Update market with new vAMM (keep same risk params)
        registry.updateMarket(
            ethPerpMarketId,
            newVAMMAddress,
            imr,
            mmr,
            maxLeverage
        );
        
        console.log("Market updated successfully!");
        
        // Verify
        (address updatedVamm, , , , ) = registry.getMarket(ethPerpMarketId);
        console.log("");
        console.log("Verification:");
        console.log("Updated vAMM:", updatedVamm);
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=================================");
        console.log("Update Complete!");
        console.log("=================================");
    }
}
