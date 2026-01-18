// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IOracle {
    function getPrice() external view returns (uint256);
}

interface IVAMM {
    function getMarkPrice() external view returns (uint256);
    function oracle() external view returns (address);
    function getTwap(uint32 window) external view returns (uint256);
}

/// @title CheckMarketPrices
/// @notice Verify Oracle and vAMM prices match
contract CheckMarketPrices is Script {
    
    function run() external view {
        address oracleAddress = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;
        address vammAddress = 0xF8908F7B4a1AaaD69bF0667FA83f85D3d0052739;
        
        console.log("=================================");
        console.log("Price Check on Sepolia");
        console.log("=================================");
        console.log("");
        
        // Check Oracle
        IOracle oracle = IOracle(oracleAddress);
        uint256 oraclePrice = oracle.getPrice();
        console.log("Oracle Address:", oracleAddress);
        console.log("Oracle Price (wei):", oraclePrice);
        console.log("Oracle Price (USD): $", oraclePrice / 1e18);
        console.log("");
        
        // Check vAMM
        IVAMM vamm = IVAMM(vammAddress);
        address vammOracle = vamm.oracle();
        uint256 markPrice = vamm.getMarkPrice();
        uint256 twap = vamm.getTwap(900); // 15 min TWAP
        
        console.log("vAMM Address:", vammAddress);
        console.log("vAMM's Oracle:", vammOracle);
        console.log("Mark Price (wei):", markPrice);
        console.log("Mark Price (USD): $", markPrice / 1e18);
        console.log("TWAP Price (USD): $", twap / 1e18);
        console.log("");
        
        // Check if they match
        if (vammOracle != oracleAddress) {
            console.log("WARNING: vAMM is using a different Oracle!");
            console.log("Expected:", oracleAddress);
            console.log("Actual:", vammOracle);
        } else {
            console.log("Oracle connection: CORRECT");
        }
        
        console.log("");
        console.log("=================================");
        console.log("Frontend should show: $", markPrice / 1e18);
        console.log("=================================");
    }
}
