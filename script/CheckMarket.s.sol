// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IMarketRegistry {
    function isMarketRegistered(bytes32 marketId) external view returns (bool);
    function getVAMM(bytes32 marketId) external view returns (address);
}

interface IVAMM {
    function getMarkPrice() external view returns (uint256);
    function getReserves() external view returns (uint256 base, uint256 quote);
}

interface IOracle {
    function getPrice() external view returns (uint256);
}

/// @title Check Market Status
contract CheckMarket is Script {
    
    // Deployed addresses from VerifyContracts.sh
    address constant MARKET_REGISTRY = 0x6d96DFC1a209B500Eb928C83455F415cb96AFF3C;
    address constant VAMM_PROXY = 0xb46928829C728e3CE1B20eA4157a23553eeA5701;
    address constant ORACLE = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;
    
    bytes32 constant ETH_PERP = keccak256("ETH-PERP");
    
    function run() external view {
        console.log("=================================");
        console.log("ByteStrike Market Status Check");
        console.log("=================================");
        console.log("");
        
        // Check Oracle Price
        IOracle oracle = IOracle(ORACLE);
        uint256 indexPrice = oracle.getPrice();
        console.log("Oracle Index Price:");
        console.log("  Wei:", indexPrice);
        console.log("  USD: $", indexPrice / 1e18);
        console.log("");
        
        // Check if market is registered
        IMarketRegistry registry = IMarketRegistry(MARKET_REGISTRY);
        bool isRegistered = registry.isMarketRegistered(ETH_PERP);
        console.log("ETH-PERP Market Registered:", isRegistered);
        
        if (isRegistered) {
            address vammAddress = registry.getVAMM(ETH_PERP);
            console.log("vAMM Address:", vammAddress);
            console.log("");
            
            // Get vAMM status
            IVAMM vamm = IVAMM(vammAddress);
            uint256 markPrice = vamm.getMarkPrice();
            (uint256 baseReserve, uint256 quoteReserve) = vamm.getReserves();
            
            console.log("vAMM Status:");
            console.log("  Mark Price (wei):", markPrice);
            console.log("  Mark Price (USD): $", markPrice / 1e18);
            console.log("  Base Reserve:", baseReserve / 1e18, "tokens");
            console.log("  Quote Reserve:", quoteReserve / 1e18, "tokens");
            console.log("");
            
            console.log("=================================");
            console.log("Market is READY for trading!");
            console.log("=================================");
        } else {
            console.log("");
            console.log("WARNING: Market NOT registered!");
            console.log("You need to register the market first.");
        }
    }
}
