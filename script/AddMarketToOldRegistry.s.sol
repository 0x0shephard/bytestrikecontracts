// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

/**
 * @title AddMarketToOldRegistry
 * @notice Adds ETH-PERP-V2 market to the old MarketRegistry that ClearingHouse uses
 */
contract AddMarketToOldRegistry is Script {
    address constant OLD_MARKET_REGISTRY = 0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD;
    address constant VAMM_V2 = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;
    address constant ORACLE = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;
    address constant FEE_ROUTER = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F;
    address constant INSURANCE_FUND = 0x3C1085dF918a38A95F84945E6705CC857b664074;
    address constant MOCK_USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;

    // ETH address for baseAsset (not using WETH, just ETH identifier)
    address constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  ADD ETH-PERP-V2 TO OLD REGISTRY");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Old MarketRegistry:", OLD_MARKET_REGISTRY);
        console.log("");

        // Market ID for ETH-PERP-V2
        bytes32 marketId = 0x923fe13dd90eff0f2f8b82db89ef27daef5f899aca7fba59ebb0b01a6343bfb5;

        vm.startBroadcast(deployerPrivateKey);

        // Create market config
        IMarketRegistry.AddMarketConfig memory config = IMarketRegistry.AddMarketConfig({
            marketId: marketId,
            vamm: VAMM_V2,
            oracle: ORACLE,
            baseAsset: ETH_ADDRESS,
            quoteToken: MOCK_USDC,
            baseUnit: 1e18,
            feeBps: 100, // 1% fee
            feeRouter: FEE_ROUTER,
            insuranceFund: INSURANCE_FUND
        });

        console.log("Adding market:");
        console.log("  Market ID:", vm.toString(marketId));
        console.log("  vAMM:", config.vamm);
        console.log("  Oracle:", config.oracle);
        console.log("  Fee:", config.feeBps, "bps");
        console.log("  Base Asset:", config.baseAsset);
        console.log("  Quote Token:", config.quoteToken);
        console.log("");

        IMarketRegistry(OLD_MARKET_REGISTRY).addMarket(config);

        console.log("Market added successfully!");

        vm.stopBroadcast();

        console.log("");
        console.log("=========================================");
        console.log("  MARKET ADDED");
        console.log("=========================================");
    }
}
