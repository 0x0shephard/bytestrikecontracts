// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IMarketRegistry {
    struct AddMarketConfig {
        bytes32 marketId;
        address vamm;
        address oracle;
        address feeRouter;
        address insuranceFund;
        address baseAsset;
        address quoteToken;
        uint256 baseUnit;
        uint16 feeBps;
    }
    
    function addMarket(AddMarketConfig calldata config) external;
    function getMarket(bytes32 marketId) external view returns (
        address vamm,
        uint16 feeBps,
        bool paused,
        address oracle,
        address feeRouter,
        address insuranceFund,
        address baseAsset,
        address quoteToken,
        uint256 baseUnit
    );
    function pauseMarket(bytes32 marketId, bool paused) external;
}

/// @title AddNewMarketWithNewVAMM
/// @notice Add ETH-PERP-V2 market with new vAMM at $3.75
contract AddNewMarketWithNewVAMM is Script {
    
    function run() external {
        address marketRegistryAddress = 0x937F40013B088832919992E0Bd0D0F48520dC964;
        address newVAMMAddress = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;
        address oracleAddress = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;
        
        // Get config from old market
        address feeRouter = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F;
        address insuranceFund = 0x3C1085dF918a38A95F84945E6705CC857b664074;
        address baseAsset = 0xc696f32d4F8219CbA41bcD5C949b2551df13A7d6; // WETH
        address quoteToken = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7; // USDC
        
        // New market ID
        bytes32 newMarketId = keccak256("ETH-PERP-V2");
        
        console.log("=================================");
        console.log("Adding New Market with New vAMM");
        console.log("=================================");
        console.log("Market ID: ETH-PERP-V2");
        console.log("New vAMM:", newVAMMAddress);
        console.log("Oracle:", oracleAddress);
        console.log("Initial Mark Price: $3.75");
        console.log("");
        
        vm.startBroadcast();
        
        IMarketRegistry registry = IMarketRegistry(marketRegistryAddress);
        
        // Add new market
        IMarketRegistry.AddMarketConfig memory config = IMarketRegistry.AddMarketConfig({
            marketId: newMarketId,
            vamm: newVAMMAddress,
            oracle: oracleAddress,
            feeRouter: feeRouter,
            insuranceFund: insuranceFund,
            baseAsset: baseAsset,
            quoteToken: quoteToken,
            baseUnit: 1e18,
            feeBps: 10 // 0.1% fee
        });
        
        registry.addMarket(config);
        
        console.log("New market added successfully!");
        
        // Optionally pause old market
        bytes32 oldMarketId = keccak256("ETH-PERP");
        console.log("");
        console.log("Pausing old ETH-PERP market...");
        registry.pauseMarket(oldMarketId, true);
        console.log("Old market paused.");
        
        // Verify new market
        (address vamm, , bool paused, , , , , , ) = registry.getMarket(newMarketId);
        console.log("");
        console.log("Verification:");
        console.log("New Market vAMM:", vamm);
        console.log("Is Paused:", paused);
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=================================");
        console.log("Setup Complete!");
        console.log("=================================");
        console.log("");
        console.log("IMPORTANT:");
        console.log("Update frontend to use:");
        console.log("  Market ID: ETH-PERP-V2");
        console.log("  vAMM:", newVAMMAddress);
    }
}
