// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

/// @notice Add ETH-PERP-V2 market with new vAMM ($3.75 price)
/// @dev MarketRegistry doesn't support updating vAMM address, so we create a new market ID
contract UpdateMarketToNewVAMM is Script {
    
    // Deployed contracts on Sepolia
    address constant MARKET_REGISTRY = 0x937F40013B088832919992E0Bd0D0F48520dC964;
    address constant NEW_VAMM = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5; // New vAMM with $3.75
    address constant NEW_ORACLE = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad; // Oracle with $3.75
    
    // Existing contract addresses from old market
    address constant FEE_ROUTER = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F;
    address constant INSURANCE_FUND = 0x3C1085dF918a38A95F84945E6705CC857b664074;
    address constant WETH = 0xc696f32d4F8219CbA41bcD5C949b2551df13A7d6;
    address constant USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;
    
    // Market IDs
    bytes32 constant OLD_MARKET_ID = keccak256("ETH-PERP");
    bytes32 constant NEW_MARKET_ID = keccak256("ETH-PERP-V2"); // New market ID
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        MarketRegistry registry = MarketRegistry(MARKET_REGISTRY);
        
        console.log("=== Adding New Market: ETH-PERP-V2 ===");
        console.log("Old Market ID:", vm.toString(OLD_MARKET_ID));
        console.log("New Market ID:", vm.toString(NEW_MARKET_ID));
        console.log("New vAMM:", NEW_VAMM);
        console.log("New Oracle:", NEW_ORACLE);
        
        // Check if new market already exists
        IMarketRegistry.Market memory existingMarket = registry.getMarket(NEW_MARKET_ID);
        if (existingMarket.vamm != address(0)) {
            console.log("\n NOTICE: ETH-PERP-V2 already exists!");
            console.log("Existing vAMM:", existingMarket.vamm);
            vm.stopBroadcast();
            return;
        }
        
        // Prepare market config
        IMarketRegistry.AddMarketConfig memory config = IMarketRegistry.AddMarketConfig({
            marketId: NEW_MARKET_ID,
            vamm: NEW_VAMM,
            oracle: NEW_ORACLE,
            feeBps: 10, // 0.10% fee (same as old market)
            feeRouter: FEE_ROUTER,
            insuranceFund: INSURANCE_FUND,
            baseAsset: WETH,
            quoteToken: USDC,
            baseUnit: 1e18 // 1 ETH
        });
        
        // Add the new market
        registry.addMarket(config);
        
        console.log("\n=== Market Added Successfully! ===");
        
        vm.stopBroadcast();
        
        // Verify the new market
        console.log("\n=== Verifying New Market ===");
        IMarketRegistry.Market memory market = registry.getMarket(NEW_MARKET_ID);
        
        console.log("vAMM:", market.vamm);
        console.log("Oracle:", market.oracle);
        console.log("Fee BPS:", market.feeBps);
        console.log("Paused:", market.paused);
        console.log("Fee Router:", market.feeRouter);
        console.log("Insurance Fund:", market.insuranceFund);
        console.log("Base Asset:", market.baseAsset);
        console.log("Quote Token:", market.quoteToken);
        console.log("Base Unit:", market.baseUnit);
        
        if (market.vamm == NEW_VAMM && market.oracle == NEW_ORACLE) {
            console.log("\n SUCCESS! ETH-PERP-V2 market created with $3.75 vAMM!");
            console.log("\n NEXT STEPS:");
            console.log("1. Update frontend to use NEW_MARKET_ID:", vm.toString(NEW_MARKET_ID));
            console.log("2. Or pause the old ETH-PERP market");
            console.log("3. Users can now trade on ETH-PERP-V2 with $3.75 mark price");
        }
    }
}
