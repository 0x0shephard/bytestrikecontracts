// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {DeployConfig} from "./DeployConfig.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

/// @title PostDeploymentSetup
/// @notice Configures ByteStrike protocol after initial deployment
/// @dev Run this after deploying all contracts and obtaining token addresses
contract PostDeploymentSetup is Script, DeployConfig {

    // Replace these with your deployed contract addresses
    address constant ORACLE = address(0); // Replace with deployed Oracle
    address constant MARKET_REGISTRY = address(0); // Replace with deployed MarketRegistry
    address constant COLLATERAL_VAULT = address(0); // Replace with deployed CollateralVault
    address constant INSURANCE_FUND = address(0); // Replace with deployed InsuranceFund
    address constant FEE_ROUTER = address(0); // Replace with deployed FeeRouter
    address constant VAMM_PROXY = address(0); // Replace with deployed vAMM proxy

    // Replace these with your token addresses
    address constant USDC = address(0); // Replace with USDC address
    address constant WETH = address(0); // Replace with WETH address
    address constant WBTC = address(0); // Replace with WBTC address

    // Placeholder for ClearingHouse (deploy this first)
    address constant CLEARING_HOUSE = address(0); // Replace with deployed ClearingHouse

    function run() external {
        require(ORACLE != address(0), "Set ORACLE address");
        require(COLLATERAL_VAULT != address(0), "Set COLLATERAL_VAULT address");
        require(MARKET_REGISTRY != address(0), "Set MARKET_REGISTRY address");
        require(USDC != address(0), "Set USDC address");
        require(WETH != address(0), "Set WETH address");
        require(WBTC != address(0), "Set WBTC address");

        console.log("Starting post-deployment setup...");
        console.log("Caller:", msg.sender);

        vm.startBroadcast();

        CollateralVault vault = CollateralVault(COLLATERAL_VAULT);
        MarketRegistry registry = MarketRegistry(MARKET_REGISTRY);

        // ===== 1. Register Collateral Tokens =====
        console.log("\n=== Registering Collateral Tokens ===");

        // Register USDC
        CollateralParams memory usdcParams = getUSDCCollateralParams();
        vault.registerCollateral(ICollateralVault.CollateralConfig({
            token: USDC,
            baseUnit: usdcParams.baseUnit,
            haircutBps: usdcParams.haircutBps,
            liqIncentiveBps: usdcParams.liqIncentiveBps,
            cap: usdcParams.cap,
            accountCap: usdcParams.accountCap,
            enabled: usdcParams.enabled,
            depositPaused: usdcParams.depositPaused,
            withdrawPaused: usdcParams.withdrawPaused,
            oracleSymbol: usdcParams.oracleSymbol
        }));
        console.log("USDC collateral registered");

        // Register WETH
        CollateralParams memory wethParams = getWETHCollateralParams();
        vault.registerCollateral(ICollateralVault.CollateralConfig({
            token: WETH,
            baseUnit: wethParams.baseUnit,
            haircutBps: wethParams.haircutBps,
            liqIncentiveBps: wethParams.liqIncentiveBps,
            cap: wethParams.cap,
            accountCap: wethParams.accountCap,
            enabled: wethParams.enabled,
            depositPaused: wethParams.depositPaused,
            withdrawPaused: wethParams.withdrawPaused,
            oracleSymbol: wethParams.oracleSymbol
        }));
        console.log("WETH collateral registered");

        // Register WBTC
        CollateralParams memory wbtcParams = getWBTCCollateralParams();
        vault.registerCollateral(ICollateralVault.CollateralConfig({
            token: WBTC,
            baseUnit: wbtcParams.baseUnit,
            haircutBps: wbtcParams.haircutBps,
            liqIncentiveBps: wbtcParams.liqIncentiveBps,
            cap: wbtcParams.cap,
            accountCap: wbtcParams.accountCap,
            enabled: wbtcParams.enabled,
            depositPaused: wbtcParams.depositPaused,
            withdrawPaused: wbtcParams.withdrawPaused,
            oracleSymbol: wbtcParams.oracleSymbol
        }));
        console.log("WBTC collateral registered");

        // ===== 2. Add Market (if ClearingHouse is deployed) =====
        if (CLEARING_HOUSE != address(0) && VAMM_PROXY != address(0)) {
            console.log("\n=== Adding ETH-PERP Market ===");

            TradingParams memory tradingParams = getDefaultTradingParams();

            // Create ETH perpetual market
            bytes32 marketId = keccak256("ETH-PERP");
            registry.addMarket(IMarketRegistry.AddMarketConfig({
                marketId: marketId,
                vamm: VAMM_PROXY,
                feeBps: tradingParams.feeBps,
                oracle: ORACLE,
                feeRouter: FEE_ROUTER,
                insuranceFund: INSURANCE_FUND,
                baseAsset: WETH,
                quoteToken: USDC,
                baseUnit: 1e18
            }));
            console.log("ETH-PERP market added");
        } else {
            console.log("\n  Skipping market creation - ClearingHouse or vAMM not set");
        }

        // ===== 3. Set ClearingHouse (if deployed) =====
        if (CLEARING_HOUSE != address(0)) {
            console.log("\n=== Setting ClearingHouse ===");
            vault.setClearinghouse(CLEARING_HOUSE);
            console.log("ClearingHouse set in CollateralVault");
        } else {
            console.log("\n  Skipping ClearingHouse setup - not deployed yet");
        }

        vm.stopBroadcast();

        console.log("\n========================================");
        console.log("Post-Deployment Setup Complete!");
        console.log("========================================");
        console.log("Configured:");
        console.log("Collateral tokens registered (USDC, WETH, WBTC)");
        if (CLEARING_HOUSE != address(0)) {
            console.log("ClearingHouse configured");
            if (VAMM_PROXY != address(0)) {
                console.log("ETH-PERP market added");
            }
        } else {
            console.log("ClearingHouse not configured (deploy it first)");
        }
        console.log("\n  Remember to:");
        console.log("1. Deploy ClearingHouse contract");
        console.log("2. Update ClearingHouse address in all contracts");
        console.log("3. Test trading functionality");
        console.log("4. Transfer ownership/admin roles if needed");
        console.log("========================================\n");
    }
}
