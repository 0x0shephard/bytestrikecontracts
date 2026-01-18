// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {vAMM} from "../src/vAMM.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployNewVAMM
/// @notice Deploy a new vAMM with $3.75 initial price
contract DeployNewVAMM is Script {
    
    function run() external {
        // Configuration
        address clearingHouse = 0x445Fa8890562Ec6220A60b3911C692DffaD49AcB;
        address oracle = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;
        
        // Price Configuration
        uint256 initialPriceX18 = 3.75e18; // $3.75
        uint256 initialBaseReserve = 1_000_000 * 1e18; // 1 million base tokens
        
        // Calculate quote reserve to match price
        // quoteReserve = baseReserve * price
        uint256 initialQuoteReserve = (initialBaseReserve * initialPriceX18) / 1e18;
        // = 1,000,000 * 3.75 = 3,750,000
        
        uint128 liquidity = 1_000_000; // Liquidity index
        uint16 feeBps = 10; // 0.1% fee
        uint256 frMaxBpsPerHour = 100; // 1% max funding per hour
        uint256 kFundingX18 = 1e18; // 1.0 funding coefficient
        uint32 observationWindow = 3600; // 1 hour TWAP window
        
        console.log("=================================");
        console.log("Deploying New vAMM");
        console.log("=================================");
        console.log("Initial Price: $3.75");
        console.log("Base Reserve:", initialBaseReserve / 1e18, "tokens");
        console.log("Quote Reserve:", initialQuoteReserve / 1e18, "tokens");
        console.log("");
        
        vm.startBroadcast();
        
        // 1. Deploy implementation
        vAMM vammImpl = new vAMM();
        console.log("vAMM Implementation:", address(vammImpl));
        
        // 2. Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            clearingHouse,
            oracle,
            initialPriceX18,
            initialBaseReserve,
            liquidity,
            feeBps,
            frMaxBpsPerHour,
            kFundingX18,
            observationWindow
        );
        
        // 3. Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(vammImpl),
            initData
        );
        
        console.log("vAMM Proxy:", address(proxy));
        
        // 4. Verify the price
        vAMM vammProxy = vAMM(address(proxy));
        uint256 markPrice = vammProxy.getMarkPrice();
        console.log("");
        console.log("Verification:");
        console.log("Mark Price (wei):", markPrice);
        console.log("Mark Price (USD): $", markPrice / 1e18);
        
        (uint256 base, uint256 quote) = vammProxy.getReserves();
        console.log("Base Reserve:", base / 1e18);
        console.log("Quote Reserve:", quote / 1e18);
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=================================");
        console.log("Deployment Complete!");
        console.log("=================================");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Update ClearingHouse to use new vAMM");
        console.log("2. Update MarketRegistry");
        console.log("3. Update frontend addresses.js with:");
        console.log("   vammProxy:", address(proxy));
    }
}
