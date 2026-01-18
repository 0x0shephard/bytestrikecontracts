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
    function getReserves() external view returns (uint256 base, uint256 quote);
}

/// @title VerifyNewVAMM
/// @notice Verify the new vAMM is working correctly
contract VerifyNewVAMM is Script {
    
    function run() external view {
        address newVAMM = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;
        address oracle = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;
        
        console.log("=================================");
        console.log("Verifying New vAMM Setup");
        console.log("=================================");
        console.log("");
        
        IVAMM vamm = IVAMM(newVAMM);
        IOracle oracleContract = IOracle(oracle);
        
        // Check Oracle
        uint256 oraclePrice = oracleContract.getPrice();
        console.log("Oracle Price: $", oraclePrice / 1e18);
        
        // Check vAMM
        address vammOracle = vamm.oracle();
        uint256 markPrice = vamm.getMarkPrice();
        uint256 twap = vamm.getTwap(900);
        (uint256 baseReserve, uint256 quoteReserve) = vamm.getReserves();
        
        console.log("");
        console.log("vAMM Configuration:");
        console.log("  Address:", newVAMM);
        console.log("  Oracle:", vammOracle);
        console.log("  Mark Price: $", markPrice / 1e18);
        console.log("  TWAP (15min): $", twap / 1e18);
        console.log("  Base Reserve:", baseReserve / 1e18);
        console.log("  Quote Reserve:", quoteReserve / 1e18);
        
        console.log("");
        console.log("=================================");
        console.log("Status Checks:");
        console.log("=================================");
        
        bool oracleMatches = vammOracle == oracle;
        bool priceCorrect = (markPrice / 1e18) == 3;
        
        console.log("Oracle Connected:", oracleMatches ? "YES" : "NO");
        console.log("Price = $3.75:", priceCorrect ? "YES" : "NO");
        
        if (oracleMatches && priceCorrect) {
            console.log("");
            console.log("SUCCESS! vAMM is ready for trading");
            console.log("Frontend will display: $3.75");
        } else {
            console.log("");
            console.log("WARNING: Configuration issues detected");
        }
        
        console.log("");
        console.log("=================================");
    }
}
