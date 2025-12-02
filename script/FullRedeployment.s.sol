// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Core Contracts
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {vAMM} from "../src/vAMM.sol";

// Oracles
import {CuOracle} from "../src/Oracle/CuOracle.sol";
import {CuOracleAdapter} from "../src/Oracle/CuOracleAdapter.sol";
import {Oracle} from "../src/Oracle/Oracle.sol";

// Mock Tokens for Sepolia
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 10_000_000 * 1e6); // 10M USDC
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWETH is ERC20 {
    constructor() ERC20("Mock WETH", "mWETH") {
        _mint(msg.sender, 100_000 * 1e18); // 100K WETH
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title FullRedeployment
 * @notice Complete protocol redeployment with proper oracles:
 *   - CuOracle + Adapter for GPU hourly rental prices (you push prices)
 *   - Chainlink Oracle for USDC stablecoin ($1.00)
 *   - Fixed ClearingHouse with IMR bug resolved
 *   - New GPU market configuration
 */
contract FullRedeployment is Script {
    // Constants
    uint256 constant INITIAL_GPU_PRICE = 3.75 * 1e18; // $3.75/hour
    uint256 constant USDC_PRICE = 1e18; // $1.00

    // Risk Parameters (Production values)
    uint256 constant IMR_BPS = 1000;              // 10% initial margin requirement
    uint256 constant MMR_BPS = 250;               // 2.5% maintenance margin requirement
    uint256 constant LIQUIDATION_PENALTY_BPS = 200; // 2% liquidation penalty
    uint256 constant PENALTY_CAP = 10_000 * 1e18; // 10,000 USDC max penalty

    // Market Parameters
    uint16 constant MARKET_FEE_BPS = 10;          // 0.1% trading fee
    uint256 constant VAMM_INITIAL_PRICE = 3.75 * 1e18;    // $3.75/hour initial mark price
    uint256 constant VAMM_BASE_RESERVE = 100_000 * 1e18;   // 100k GPU hours
    uint128 constant VAMM_LIQUIDITY = 100_000 * 1e18;      // Initial liquidity
    uint16 constant VAMM_FEE_BPS = 10;                     // 0.1% vAMM swap fee
    uint256 constant VAMM_FUNDING_MAX_BPS = 100;           // 1% max funding rate per hour
    uint256 constant VAMM_K_FUNDING = 1e18;                // 1.0 funding scaling factor
    uint32 constant VAMM_OBSERVATION_WINDOW = 15 minutes;  // 15 min TWAP window

    // CuOracle settings
    uint256 constant MIN_TIME_INTERVAL = 5 minutes; // Min time between price commits
    bytes32 constant GPU_ASSET_ID = keccak256("H100_GPU_HOURLY");

    // Deployment addresses (to be populated)
    struct Deployment {
        // Tokens
        address mockUSDC;
        address mockWETH;

        // Oracles
        address cuOracle;
        address cuOracleAdapter;
        address chainlinkOracle; // Actually simple oracle for USDC

        // Core
        address collateralVault;
        address marketRegistry;
        address insuranceFund;
        address feeRouter;
        address clearingHouseImpl;
        address clearingHouseProxy;
        address vammImpl;
        address vammProxy;

        // Market ID
        bytes32 gpuMarketId;
    }

    Deployment public deployment;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("===========================================");
        console.log("  BYTESTRIKE FULL PROTOCOL REDEPLOYMENT");
        console.log("===========================================");
        console.log("Deployer:", deployer);
        console.log("Network: Sepolia (Chain ID: 11155111)");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // STEP 1: Deploy Mock Tokens
        console.log("STEP 1: Deploying Mock Tokens...");
        deployment.mockUSDC = address(new MockUSDC());
        deployment.mockWETH = address(new MockWETH());
        console.log("  Mock USDC:", deployment.mockUSDC);
        console.log("  Mock WETH:", deployment.mockWETH);
        console.log("");

        // STEP 2: Deploy Oracles
        console.log("STEP 2: Deploying Oracles...");

        // 2a. Deploy CuOracle for GPU prices (commit-reveal pattern)
        deployment.cuOracle = address(new CuOracle(deployer, MIN_TIME_INTERVAL));
        console.log("  CuOracle (GPU prices):", deployment.cuOracle);

        // Register GPU asset in CuOracle
        CuOracle(deployment.cuOracle).registerAsset(GPU_ASSET_ID);
        console.log("  Registered GPU asset ID:");
        console.logBytes32(GPU_ASSET_ID);

        // Grant deployer commit role
        CuOracle(deployment.cuOracle).grantRole(deployer);
        console.log("  Granted commit role to deployer");

        // Set initial GPU price via commit-reveal
        bytes32 nonce = keccak256(abi.encodePacked(block.timestamp, "initial"));
        bytes32 commit = keccak256(abi.encodePacked(INITIAL_GPU_PRICE, nonce));
        CuOracle(deployment.cuOracle).commitPrice(GPU_ASSET_ID, commit);
        console.log("  Committed initial GPU price");

        // Wait 2 seconds (simulate block time)
        vm.warp(block.timestamp + 2);

        // Reveal price
        CuOracle(deployment.cuOracle).updatePrices(GPU_ASSET_ID, INITIAL_GPU_PRICE, nonce);
        console.log("  Revealed GPU price: $3.75/hour");

        // 2b. Deploy CuOracleAdapter (wrapper for IOracle interface)
        deployment.cuOracleAdapter = address(new CuOracleAdapter(
            deployment.cuOracle,
            GPU_ASSET_ID,
            1 hours // Max age: 1 hour
        ));
        console.log("  CuOracleAdapter:", deployment.cuOracleAdapter);

        // 2c. Deploy Oracle for USDC
        deployment.chainlinkOracle = address(new Oracle());
        console.log("  Oracle (USDC):", deployment.chainlinkOracle);
        console.log("");

        // STEP 3: Deploy Core Contracts
        console.log("STEP 3: Deploying Core Contracts...");

        // 3a. Deploy MarketRegistry
        deployment.marketRegistry = address(new MarketRegistry());
        console.log("  MarketRegistry:", deployment.marketRegistry);

        // 3b. Deploy CollateralVault
        deployment.collateralVault = address(new CollateralVault());
        console.log("  CollateralVault:", deployment.collateralVault);

        // Set oracle for CollateralVault
        CollateralVault(deployment.collateralVault).setOracle(deployment.chainlinkOracle);
        console.log("  Oracle set for CollateralVault");

        // 3c. Deploy InsuranceFund
        deployment.insuranceFund = address(new InsuranceFund(
            deployment.mockUSDC,
            deployer
        ));
        console.log("  InsuranceFund:", deployment.insuranceFund);
        console.log("");

        // STEP 4: Deploy ClearingHouse (with IMR bug fix)
        console.log("STEP 4: Deploying ClearingHouse (with IMR fix)...");
        deployment.clearingHouseImpl = address(new ClearingHouse());
        console.log("  Implementation:", deployment.clearingHouseImpl);

        // Initialize proxy (correct parameter order: vault, marketRegistry, admin)
        bytes memory chInitData = abi.encodeWithSelector(
            ClearingHouse.initialize.selector,
            deployment.collateralVault,
            deployment.marketRegistry,
            deployer  // admin address
        );
        deployment.clearingHouseProxy = address(new ERC1967Proxy(
            deployment.clearingHouseImpl,
            chInitData
        ));
        console.log("  Proxy:", deployment.clearingHouseProxy);
        console.log("");

        // 3d. Deploy FeeRouter (after ClearingHouse)
        console.log("STEP 4b: Deploying FeeRouter...");
        deployment.feeRouter = address(new FeeRouter(
            deployment.mockUSDC,
            deployment.insuranceFund,
            deployer,
            deployment.clearingHouseProxy,  // Now we have the actual clearinghouse address
            5000,  // 50% of trade fees to insurance
            5000   // 50% of liquidation penalties to insurance
        ));
        console.log("  FeeRouter:", deployment.feeRouter);
        console.log("");

        // STEP 5: Configure CollateralVault
        console.log("STEP 5: Configuring CollateralVault...");
        CollateralVault vault = CollateralVault(deployment.collateralVault);

        // Register USDC as collateral
        vault.registerCollateral(ICollateralVault.CollateralConfig({
            token: deployment.mockUSDC,
            baseUnit: 1e6,              // 6 decimals
            haircutBps: 0,              // no haircut
            liqIncentiveBps: 200,       // 2% liquidation incentive
            cap: 0,                     // no cap
            accountCap: 0,              // no account cap
            enabled: true,              // enabled
            depositPaused: false,       // deposits enabled
            withdrawPaused: false,      // withdrawals enabled
            oracleSymbol: "USDC"        // oracle symbol
        }));
        console.log("  Registered USDC collateral");

        // Authorize ClearingHouse
        vault.setClearinghouse(deployment.clearingHouseProxy);
        console.log("  Authorized ClearingHouse");
        console.log("");

        // STEP 6: Deploy vAMM for GPU Market
        console.log("STEP 6: Deploying vAMM for GPU Market...");
        deployment.vammImpl = address(new vAMM());
        console.log("  vAMM Implementation:", deployment.vammImpl);

        // Initialize vAMM proxy with correct 9 parameters
        bytes memory vammInitData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            deployment.clearingHouseProxy,  // _clearinghouse
            deployment.cuOracleAdapter,     // _oracle (GPU price feed)
            VAMM_INITIAL_PRICE,             // initialPriceX18 ($3.75)
            VAMM_BASE_RESERVE,              // initialBaseReserve (100k GPU hours)
            VAMM_LIQUIDITY,                 // liquidity_ (100k)
            VAMM_FEE_BPS,                   // feeBps_ (10 = 0.1%)
            VAMM_FUNDING_MAX_BPS,           // frMaxBpsPerHour_ (100 = 1% max)
            VAMM_K_FUNDING,                 // kFundingX18_ (1e18 = 1.0)
            VAMM_OBSERVATION_WINDOW         // observationWindow_ (15 minutes)
        );
        deployment.vammProxy = address(new ERC1967Proxy(
            deployment.vammImpl,
            vammInitData
        ));
        console.log("  vAMM Proxy:", deployment.vammProxy);
        console.log("  Initial Mark Price: $", VAMM_INITIAL_PRICE / 1e18);
        console.log("");

        // STEP 7: Register GPU Market
        console.log("STEP 7: Registering GPU Market...");
        deployment.gpuMarketId = keccak256("H100-GPU-PERP");

        MarketRegistry(deployment.marketRegistry).addMarket(IMarketRegistry.AddMarketConfig({
            marketId: deployment.gpuMarketId,
            vamm: deployment.vammProxy,
            oracle: deployment.cuOracleAdapter,
            baseAsset: deployment.mockWETH,  // Placeholder
            quoteToken: deployment.mockUSDC,
            baseUnit: 1e18,
            feeBps: MARKET_FEE_BPS,
            feeRouter: deployment.feeRouter,
            insuranceFund: deployment.insuranceFund
        }));
        console.log("  GPU Market ID:");
        console.logBytes32(deployment.gpuMarketId);
        console.log("  Market Name: H100-GPU-PERP");
        console.log("  Trading Fee: 0.1%");
        console.log("");

        // STEP 8: Set Risk Parameters
        console.log("STEP 8: Setting Risk Parameters...");
        ClearingHouse(deployment.clearingHouseProxy).setRiskParams(
            deployment.gpuMarketId,
            IMR_BPS,
            MMR_BPS,
            LIQUIDATION_PENALTY_BPS,
            PENALTY_CAP
        );
        console.log("  IMR: 10% (10x max leverage)");
        console.log("  MMR: 2.5% (liquidation threshold)");
        console.log("  Liquidation Penalty: 2%");
        console.log("  Penalty Cap: 10,000 USDC");
        console.log("");

        // STEP 9: Configure InsuranceFund
        console.log("STEP 9: Configuring InsuranceFund...");
        InsuranceFund(deployment.insuranceFund).setFeeRouter(deployment.feeRouter, true);
        InsuranceFund(deployment.insuranceFund).setAuthorized(deployment.clearingHouseProxy, true);
        console.log("  Authorized FeeRouter and ClearingHouse");
        console.log("");

        vm.stopBroadcast();

        // STEP 10: Print Deployment Summary
        console.log("===========================================");
        console.log("  DEPLOYMENT COMPLETE!");
        console.log("===========================================");
        console.log("");
        console.log("TOKENS:");
        console.log("  Mock USDC:", deployment.mockUSDC);
        console.log("  Mock WETH:", deployment.mockWETH);
        console.log("");
        console.log("ORACLES:");
        console.log("  CuOracle (GPU):", deployment.cuOracle);
        console.log("  CuOracleAdapter:", deployment.cuOracleAdapter);
        console.log("  Chainlink Oracle (USDC):", deployment.chainlinkOracle);
        console.log("");
        console.log("CORE CONTRACTS:");
        console.log("  ClearingHouse:", deployment.clearingHouseProxy);
        console.log("  CollateralVault:", deployment.collateralVault);
        console.log("  MarketRegistry:", deployment.marketRegistry);
        console.log("  InsuranceFund:", deployment.insuranceFund);
        console.log("  FeeRouter:", deployment.feeRouter);
        console.log("  vAMM (GPU Market):", deployment.vammProxy);
        console.log("");
        console.log("MARKET:");
        console.log("  GPU Market ID:", vm.toString(deployment.gpuMarketId));
        console.log("  Initial GPU Price: $3.75/hour");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Update frontend contract addresses");
        console.log("2. Mint test USDC tokens");
        console.log("3. Test trading flow");
        console.log("4. Update GPU prices via CuOracle commit-reveal");
        console.log("");
        console.log("To update GPU price:");
        console.log("  1. Call commitPrice(GPU_ASSET_ID, keccak256(price, nonce))");
        console.log("  2. Wait minimum delay");
        console.log("  3. Call updatePrices(GPU_ASSET_ID, price, nonce)");
        console.log("");
    }
}
