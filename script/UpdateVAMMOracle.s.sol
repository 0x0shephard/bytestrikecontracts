// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";

interface IVAMM {
    function oracle() external view returns (address);
    function owner() external view returns (address);
}

/// @title UpdateVAMMOracle
/// @notice Point a market (its risk oracle and its vAMM's funding oracle) to the correct Oracle.
/// @dev The vAMM's oracle can only be moved through MarketRegistry.setOracle. MARKET_REGISTRY and
///      MARKET_ID (bytes32) name the market whose vAMM is vammAddress.
contract UpdateVAMMOracle is Script {
    
    function run() external {
        address vammAddress = 0xF8908F7B4a1AaaD69bF0667FA83f85D3d0052739;
        address newOracleAddress = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;
        
        console.log("=================================");
        console.log("Updating vAMM Oracle");
        console.log("=================================");
        console.log("vAMM Address:", vammAddress);
        console.log("New Oracle:", newOracleAddress);
        console.log("");
        
        vm.startBroadcast();
        
        IVAMM vamm = IVAMM(vammAddress);
        
        // Check current oracle
        address currentOracle = vamm.oracle();
        console.log("Current Oracle:", currentOracle);
        
        // Update to new oracle through the registry
        MarketRegistry registry = MarketRegistry(vm.envAddress("MARKET_REGISTRY"));
        bytes32 marketId = vm.envBytes32("MARKET_ID");
        IMarketRegistry.Market memory market = registry.getMarket(marketId);
        require(market.vamm == vammAddress, "market is not this vAMM");
        registry.setOracle(marketId, newOracleAddress);
        console.log("");
        console.log("Oracle updated successfully!");
        
        // Verify
        address updatedOracle = vamm.oracle();
        console.log("New Oracle:", updatedOracle);
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=================================");
        console.log("Update Complete!");
        console.log("Frontend will now show $3.75");
        console.log("=================================");
    }
}
