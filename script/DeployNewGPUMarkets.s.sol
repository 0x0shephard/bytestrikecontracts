// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import "../src/vAMM.sol";
import "../src/ClearingHouse.sol";
import "../src/MarketRegistry.sol";
import "../src/Oracle/MultiAssetOracle.sol";
import "../src/Oracle/MultiAssetOracleAdapter.sol";
import "../src/Interfaces/IMarketRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployNewGPUMarkets
 * @notice Deploys two new GPU perpetual markets (HyperScalers and non-HyperScalers) and migrates
 *         the existing H100-PERP to use the new MultiAssetOracle infrastructure.
 *
 * This script:
 * 1. Deploys MultiAssetOracle with 3 assets (H100, HyperScalers, non-HyperScalers)
 * 2. Deploys 3 MultiAssetOracleAdapters (one per market)
 * 3. Migrates existing H100-PERP vAMM to new oracle adapter
 * 4. Deploys 2 new vAMM proxies for the new markets
 * 5. Registers 2 new markets in MarketRegistry
 * 6. Sets risk parameters in ClearingHouse
 *
 * Run with:
 * forge script script/DeployNewGPUMarkets.s.sol:DeployNewGPUMarkets --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
 */
contract DeployNewGPUMarkets is Script {
    // ============ Existing Infrastructure (Sepolia) ============
    address constant CLEARING_HOUSE = 0x18F863b1b0A3Eca6B2235dc1957291E357f490B0;
    address constant MARKET_REGISTRY = 0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD;
    address constant COLLATERAL_VAULT = 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2;
    address constant INSURANCE_FUND = 0x3C1085dF918a38A95F84945E6705CC857b664074;
    address constant FEE_ROUTER = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F;
    address constant MOCK_USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;
    address constant MOCK_WETH = 0xc696f32d4F8219CbA41bcD5C949b2551df13A7d6;

    // Existing vAMM implementation (reuse for new markets)
    address constant VAMM_IMPLEMENTATION = 0xd64175cE957F089bA7fb3EBdA5B17f268DE01190;

    // Existing H100-PERP vAMM (to migrate oracle)
    address constant EXISTING_H100_VAMM = 0xF7210ccC245323258CC15e0Ca094eBbe2DC2CD85;

    // ============ Asset IDs ============
    bytes32 constant H100_ASSET_ID = keccak256("H100_HOURLY");
    bytes32 constant H100_HYPERSCALERS_ASSET_ID = keccak256("H100_HYPERSCALERS_HOURLY");
    bytes32 constant H100_NON_HYPERSCALERS_ASSET_ID = keccak256("H100_NON_HYPERSCALERS_HOURLY");

    // ============ Initial Prices (1e18 format) ============
    uint256 constant H100_PRICE = 3_790_000_000_000_000_000; // $3.79
    uint256 constant H100_HYPERSCALERS_PRICE = 4_202_163_309_021_113_000; // $4.202163309021113
    uint256 constant H100_NON_HYPERSCALERS_PRICE = 2_946_243_092_754_190_000; // $2.94624309275419

    // ============ Market Names ============
    string constant HYPERSCALERS_MARKET_NAME = "H100-HyperScalers-PERP";
    string constant NON_HYPERSCALERS_MARKET_NAME = "H100-non-HyperScalers-PERP";

    // ============ vAMM Parameters ============
    uint256 constant INITIAL_BASE_RESERVE = 100_000e18; // 100k base units
    uint128 constant LIQUIDITY = 1_000_000e18; // 1M liquidity
    uint16 constant FEE_BPS = 10; // 0.1% fee
    uint256 constant FR_MAX_BPS_PER_HOUR = 100; // 1% max funding per hour
    uint256 constant K_FUNDING = 1e18; // 1.0 funding coefficient
    uint32 constant OBSERVATION_WINDOW = 900; // 15 minutes TWAP

    // ============ Risk Parameters ============
    uint256 constant IMR_BPS = 1000; // 10% Initial Margin Requirement
    uint256 constant MMR_BPS = 500; // 5% Maintenance Margin Requirement
    uint256 constant LIQUIDATION_PENALTY_BPS = 250; // 2.5% Liquidation Penalty
    uint256 constant PENALTY_CAP = 1000e18; // $1000 max penalty

    // ============ Oracle Settings ============
    uint256 constant ORACLE_MAX_AGE = 86400; // 24 hours (bot updates every 12h)

    // Trading fee
    uint16 constant TRADING_FEE_BPS = 10; // 0.1% trading fee

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying New GPU Markets ===");
        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============================================================
        // STEP 1: Deploy MultiAssetOracle
        // ============================================================
        console.log("Step 1: Deploying MultiAssetOracle...");
        MultiAssetOracle multiAssetOracle = new MultiAssetOracle();
        console.log("MultiAssetOracle deployed at:", address(multiAssetOracle));
        console.log("");

        // ============================================================
        // STEP 2: Register all 3 assets with initial prices
        // ============================================================
        console.log("Step 2: Registering assets...");

        multiAssetOracle.registerAsset(H100_ASSET_ID, H100_PRICE);
        console.log("Registered H100 asset at $3.79");

        multiAssetOracle.registerAsset(H100_HYPERSCALERS_ASSET_ID, H100_HYPERSCALERS_PRICE);
        console.log("Registered H100-HyperScalers asset at $4.20");

        multiAssetOracle.registerAsset(H100_NON_HYPERSCALERS_ASSET_ID, H100_NON_HYPERSCALERS_PRICE);
        console.log("Registered H100-non-HyperScalers asset at $2.95");
        console.log("");

        // ============================================================
        // STEP 3: Deploy 3 MultiAssetOracleAdapters
        // ============================================================
        console.log("Step 3: Deploying Oracle Adapters...");

        MultiAssetOracleAdapter h100Adapter = new MultiAssetOracleAdapter(
            address(multiAssetOracle),
            H100_ASSET_ID,
            ORACLE_MAX_AGE
        );
        console.log("H100 Oracle Adapter deployed at:", address(h100Adapter));

        MultiAssetOracleAdapter hyperscalersAdapter = new MultiAssetOracleAdapter(
            address(multiAssetOracle),
            H100_HYPERSCALERS_ASSET_ID,
            ORACLE_MAX_AGE
        );
        console.log("HyperScalers Oracle Adapter deployed at:", address(hyperscalersAdapter));

        MultiAssetOracleAdapter nonHyperscalersAdapter = new MultiAssetOracleAdapter(
            address(multiAssetOracle),
            H100_NON_HYPERSCALERS_ASSET_ID,
            ORACLE_MAX_AGE
        );
        console.log("non-HyperScalers Oracle Adapter deployed at:", address(nonHyperscalersAdapter));
        console.log("");

        // ============================================================
        // STEP 4: Migrate existing H100-PERP vAMM to new oracle
        // ============================================================
        console.log("Step 4: Migrating existing H100-PERP vAMM to new oracle...");
        vAMM(EXISTING_H100_VAMM).setOracle(address(h100Adapter));
        console.log("H100-PERP vAMM now uses new oracle adapter");
        console.log("");

        // ============================================================
        // STEP 5: Deploy 2 new vAMM Proxies
        // ============================================================
        console.log("Step 5: Deploying new vAMM proxies...");

        // HyperScalers vAMM
        bytes memory hyperscalersInitData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            CLEARING_HOUSE,
            address(hyperscalersAdapter),
            H100_HYPERSCALERS_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY,
            FEE_BPS,
            FR_MAX_BPS_PER_HOUR,
            K_FUNDING,
            OBSERVATION_WINDOW
        );
        ERC1967Proxy hyperscalersVammProxy = new ERC1967Proxy(VAMM_IMPLEMENTATION, hyperscalersInitData);
        address hyperscalersVamm = address(hyperscalersVammProxy);
        console.log("HyperScalers vAMM Proxy deployed at:", hyperscalersVamm);

        // non-HyperScalers vAMM
        bytes memory nonHyperscalersInitData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            CLEARING_HOUSE,
            address(nonHyperscalersAdapter),
            H100_NON_HYPERSCALERS_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY,
            FEE_BPS,
            FR_MAX_BPS_PER_HOUR,
            K_FUNDING,
            OBSERVATION_WINDOW
        );
        ERC1967Proxy nonHyperscalersVammProxy = new ERC1967Proxy(VAMM_IMPLEMENTATION, nonHyperscalersInitData);
        address nonHyperscalersVamm = address(nonHyperscalersVammProxy);
        console.log("non-HyperScalers vAMM Proxy deployed at:", nonHyperscalersVamm);
        console.log("");

        // ============================================================
        // STEP 6: Register new markets in MarketRegistry
        // ============================================================
        console.log("Step 6: Registering new markets...");

        bytes32 hyperscalersMarketId = keccak256(abi.encodePacked(HYPERSCALERS_MARKET_NAME));
        bytes32 nonHyperscalersMarketId = keccak256(abi.encodePacked(NON_HYPERSCALERS_MARKET_NAME));

        console.log("HyperScalers Market ID:", vm.toString(hyperscalersMarketId));
        console.log("non-HyperScalers Market ID:", vm.toString(nonHyperscalersMarketId));

        // Register HyperScalers market
        MarketRegistry(MARKET_REGISTRY).addMarket(IMarketRegistry.AddMarketConfig({
            marketId: hyperscalersMarketId,
            vamm: hyperscalersVamm,
            oracle: address(hyperscalersAdapter),
            baseAsset: MOCK_WETH,
            quoteToken: MOCK_USDC,
            baseUnit: 1e18,
            feeBps: TRADING_FEE_BPS,
            feeRouter: FEE_ROUTER,
            insuranceFund: INSURANCE_FUND
        }));
        console.log("HyperScalers market registered");

        // Register non-HyperScalers market
        MarketRegistry(MARKET_REGISTRY).addMarket(IMarketRegistry.AddMarketConfig({
            marketId: nonHyperscalersMarketId,
            vamm: nonHyperscalersVamm,
            oracle: address(nonHyperscalersAdapter),
            baseAsset: MOCK_WETH,
            quoteToken: MOCK_USDC,
            baseUnit: 1e18,
            feeBps: TRADING_FEE_BPS,
            feeRouter: FEE_ROUTER,
            insuranceFund: INSURANCE_FUND
        }));
        console.log("non-HyperScalers market registered");
        console.log("");

        // ============================================================
        // STEP 7: Set risk parameters in ClearingHouse
        // ============================================================
        console.log("Step 7: Setting risk parameters...");

        ClearingHouse(CLEARING_HOUSE).setRiskParams(
            hyperscalersMarketId,
            IMR_BPS,
            MMR_BPS,
            LIQUIDATION_PENALTY_BPS,
            PENALTY_CAP
        );
        console.log("HyperScalers risk parameters set");

        ClearingHouse(CLEARING_HOUSE).setRiskParams(
            nonHyperscalersMarketId,
            IMR_BPS,
            MMR_BPS,
            LIQUIDATION_PENALTY_BPS,
            PENALTY_CAP
        );
        console.log("non-HyperScalers risk parameters set");
        console.log("");

        // ============================================================
        // STEP 8: Verify deployment
        // ============================================================
        console.log("Step 8: Verifying deployment...");

        // Check oracle prices
        console.log("H100 Adapter Price:", h100Adapter.getPrice() / 1e18, "USD");
        console.log("HyperScalers Adapter Price:", hyperscalersAdapter.getPrice() / 1e18, "USD");
        console.log("non-HyperScalers Adapter Price:", nonHyperscalersAdapter.getPrice() / 1e18, "USD");

        // Check vAMM mark prices
        console.log("HyperScalers vAMM Mark Price:", vAMM(hyperscalersVamm).getMarkPrice() / 1e18, "USD");
        console.log("non-HyperScalers vAMM Mark Price:", vAMM(nonHyperscalersVamm).getMarkPrice() / 1e18, "USD");

        // Check existing H100 vAMM oracle was updated
        console.log("Existing H100 vAMM oracle:", vAMM(EXISTING_H100_VAMM).oracle());

        vm.stopBroadcast();

        // ============================================================
        // Print Summary for Frontend Integration
        // ============================================================
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Add to overhaul/src/contracts/addresses.js:");
        console.log("");
        console.log("// New Oracle Infrastructure");
        console.log("multiAssetOracle:", address(multiAssetOracle));
        console.log("h100OracleAdapter:", address(h100Adapter));
        console.log("hyperscalersOracleAdapter:", address(hyperscalersAdapter));
        console.log("nonHyperscalersOracleAdapter:", address(nonHyperscalersAdapter));
        console.log("");
        console.log("// New vAMMs");
        console.log("vammProxyHyperscalers:", hyperscalersVamm);
        console.log("vammProxyNonHyperscalers:", nonHyperscalersVamm);
        console.log("");
        console.log("// Market IDs");
        console.log("'H100-HyperScalers-PERP':", vm.toString(hyperscalersMarketId));
        console.log("'H100-non-HyperScalers-PERP':", vm.toString(nonHyperscalersMarketId));
        console.log("");
        console.log("// Asset IDs for bot");
        console.log("H100_ASSET_ID:", vm.toString(H100_ASSET_ID));
        console.log("H100_HYPERSCALERS_ASSET_ID:", vm.toString(H100_HYPERSCALERS_ASSET_ID));
        console.log("H100_NON_HYPERSCALERS_ASSET_ID:", vm.toString(H100_NON_HYPERSCALERS_ASSET_ID));
    }
}
