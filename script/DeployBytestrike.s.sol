// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {DeployConfig} from "./DeployConfig.sol";
import {Oracle} from "../src/Oracle/Oracle.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {vAMM} from "../src/vAMM.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployBytestrike
/// @notice Main deployment script for ByteStrike protocol on Sepolia
/// @dev Deploys all core contracts in correct dependency order
contract DeployBytestrike is Script, DeployConfig {

    // Deployed contract addresses
    Oracle public oracle;
    MarketRegistry public marketRegistry;
    CollateralVault public collateralVault;
    InsuranceFund public insuranceFund;
    FeeRouter public feeRouter;
    vAMM public vammImplementation;
    ERC1967Proxy public vammProxy;
    vAMM public vammProxied;

    function run() external {
        // Get configuration
        Config memory config = getSepoliaConfig();
        TestTokens memory tokens = getSepoliaTestTokens();
        TradingParams memory tradingParams = getDefaultTradingParams();
        VAMMParams memory vammParams = getDefaultVAMMParams();

        // Set admin addresses to deployer if not set
        if (config.treasuryAdmin == address(0)) config.treasuryAdmin = msg.sender;
        if (config.pauseGuardian == address(0)) config.pauseGuardian = msg.sender;
        if (config.marketAdmin == address(0)) config.marketAdmin = msg.sender;
        if (config.paramAdmin == address(0)) config.paramAdmin = msg.sender;

        console.log("Starting ByteStrike deployment on Sepolia...");
        console.log("Deployer:", msg.sender);

        vm.startBroadcast();

        // ===== 1. Deploy Oracle =====
        console.log("\n=== Deploying Oracle ===");
        oracle = new Oracle();
        console.log("Oracle deployed at:", address(oracle));

        // Configure Oracle with Sepolia price feeds
        oracle.setPriceFeed("ETH", config.priceFeeds.ethUsd);
        oracle.setPriceFeed("USDC", config.priceFeeds.usdcUsd);
        oracle.setPriceFeed("BTC", config.priceFeeds.btcUsd);
        console.log("Price feeds configured");

        // Set base units for tokens
        oracle.setBaseUnit("ETH", 1e18);
        oracle.setBaseUnit("USDC", 1e6);
        oracle.setBaseUnit("BTC", 1e8);
        console.log("Base units configured");

        // Set staleness period (1 hour)
        oracle.setPriceStalePeriod(3600);
        console.log("Stale period set to 1 hour");

        // ===== 2. Deploy MarketRegistry =====
        console.log("\n=== Deploying MarketRegistry ===");
        marketRegistry = new MarketRegistry();
        console.log("MarketRegistry deployed at:", address(marketRegistry));

        // Grant roles
        marketRegistry.grantRole(marketRegistry.MARKET_ADMIN_ROLE(), config.marketAdmin);
        marketRegistry.grantRole(marketRegistry.PARAM_ADMIN_ROLE(), config.paramAdmin);
        marketRegistry.grantRole(marketRegistry.PAUSE_GUARDIAN_ROLE(), config.pauseGuardian);
        console.log("Roles granted");

        // ===== 3. Deploy CollateralVault =====
        console.log("\n=== Deploying CollateralVault ===");
        collateralVault = new CollateralVault();
        console.log("CollateralVault deployed at:", address(collateralVault));

        // Set oracle
        collateralVault.setOracle(address(oracle));
        console.log("Oracle set in CollateralVault");

        // Grant vault admin role
        collateralVault.grantRole(collateralVault.VAULT_ADMIN_ROLE(), msg.sender);
        console.log("Vault admin role granted");

        // Note: Clearinghouse will be set after it's deployed (placeholder for now)
        console.log("Note: Clearinghouse must be set later via setClearinghouse()");

        // ===== 4. Deploy InsuranceFund (for USDC quote token) =====
        console.log("\n=== Deploying InsuranceFund ===");
        // Note: Using address(1) as placeholder for quote token
        // You should replace this with actual USDC token address
        address quoteToken = tokens.usdc != address(0) ? tokens.usdc : address(1);
        console.log("Using quote token:", quoteToken);

        insuranceFund = new InsuranceFund(
            quoteToken,
            address(0) // Clearinghouse will be set later
        );
        console.log("InsuranceFund deployed at:", address(insuranceFund));

        // ===== 5. Deploy FeeRouter =====
        console.log("\n=== Deploying FeeRouter ===");
        feeRouter = new FeeRouter(
            quoteToken,
            address(insuranceFund),
            config.treasuryAdmin,
            address(0), // Clearinghouse placeholder
            tradingParams.tradeToFundBps,
            tradingParams.liqToFundBps
        );
        console.log("FeeRouter deployed at:", address(feeRouter));

        // Configure InsuranceFund to accept fees from router
        insuranceFund.setFeeRouter(address(feeRouter), true);
        console.log("FeeRouter authorized in InsuranceFund");

        // ===== 6. Deploy vAMM (UUPS Proxy) =====
        console.log("\n=== Deploying vAMM ===");

        // Deploy implementation
        vammImplementation = new vAMM();
        console.log("vAMM implementation deployed at:", address(vammImplementation));

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(0), // Clearinghouse placeholder
            address(oracle),
            vammParams.initialPriceX18,
            vammParams.initialBaseReserve,
            vammParams.liquidity,
            tradingParams.feeBps,
            tradingParams.frMaxBpsPerHour,
            tradingParams.kFundingX18,
            tradingParams.observationWindow
        );

        // Deploy proxy
        vammProxy = new ERC1967Proxy(
            address(vammImplementation),
            initData
        );
        console.log("vAMM proxy deployed at:", address(vammProxy));

        // Get proxied instance
        vammProxied = vAMM(address(vammProxy));
        console.log("vAMM initialized with:");
        console.log("  - Initial price: 3000 ETH/USD");
        console.log("  - Base reserve: 1000 ETH");
        console.log("  - Fee: 0.1%");

        vm.stopBroadcast();

        // ===== Post-deployment summary =====
        console.log("\n========================================");
        console.log("ByteStrike Deployment Complete!");
        console.log("========================================");
        console.log("Core Contracts:");
        console.log("  Oracle:           ", address(oracle));
        console.log("  MarketRegistry:   ", address(marketRegistry));
        console.log("  CollateralVault:  ", address(collateralVault));
        console.log("  InsuranceFund:    ", address(insuranceFund));
        console.log("  FeeRouter:        ", address(feeRouter));
        console.log("  vAMM (proxy):     ", address(vammProxy));
        console.log("  vAMM (impl):      ", address(vammImplementation));
        console.log("\nAdmin Addresses:");
        console.log("  Treasury Admin:   ", config.treasuryAdmin);
        console.log("  Market Admin:     ", config.marketAdmin);
        console.log("  Param Admin:      ", config.paramAdmin);
        console.log("  Pause Guardian:   ", config.pauseGuardian);
        console.log("\n IMPORTANT POST-DEPLOYMENT STEPS:");
        console.log("1. Deploy or obtain test token addresses (USDC, WETH, WBTC)");
        console.log("2. Deploy ClearingHouse contract (currently not implemented)");
        console.log("3. Set clearinghouse in CollateralVault, InsuranceFund, FeeRouter, and vAMM");
        console.log("4. Register collateral tokens in CollateralVault");
        console.log("5. Add markets to MarketRegistry");
        console.log("6. Transfer admin roles if needed");
        console.log("========================================\n");

        // Save deployment addresses to file
        _saveDeploymentAddresses();
    }

    function _saveDeploymentAddresses() internal {
        string memory json = "deployment";

        vm.serializeAddress(json, "oracle", address(oracle));
        vm.serializeAddress(json, "marketRegistry", address(marketRegistry));
        vm.serializeAddress(json, "collateralVault", address(collateralVault));
        vm.serializeAddress(json, "insuranceFund", address(insuranceFund));
        vm.serializeAddress(json, "feeRouter", address(feeRouter));
        vm.serializeAddress(json, "vammProxy", address(vammProxy));
        string memory finalJson = vm.serializeAddress(json, "vammImplementation", address(vammImplementation));

        vm.writeJson(finalJson, "./deployments/sepolia-deployment.json");
        console.log("\nDeployment addresses saved to: deployments/sepolia-deployment.json");
    }
}
