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
 * @title DeployH200Market
 * @notice Deploys a new H200-PERP perpetual market using the existing MultiAssetOracle infrastructure
 *
 * This script:
 * 1. Registers H200 asset in the existing MultiAssetOracle
 * 2. Deploys a MultiAssetOracleAdapter for H200
 * 3. Deploys a new vAMM proxy for H200-PERP market
 * 4. Registers the market in MarketRegistry
 * 5. Sets risk parameters in ClearingHouse
 *
 * Run with:
 * forge script script/DeployH200Market.s.sol:DeployH200Market --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
 */
contract DeployH200Market is Script {
    // ============ Existing Infrastructure (Sepolia) ============
    address constant CLEARING_HOUSE = 0x18F863b1b0A3Eca6B2235dc1957291E357f490B0;
    address constant MARKET_REGISTRY = 0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD;
    address constant INSURANCE_FUND = 0x3C1085dF918a38A95F84945E6705CC857b664074;
    address constant FEE_ROUTER = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F;
    address constant MOCK_USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;
    address constant MOCK_WETH = 0xc696f32d4F8219CbA41bcD5C949b2551df13A7d6;
    address constant VAMM_IMPLEMENTATION = 0xd64175cE957F089bA7fb3EBdA5B17f268DE01190;

    // Existing MultiAssetOracle (already deployed)
    address constant MULTI_ASSET_ORACLE = 0xB44d652354d12Ac56b83112c6ece1fa2ccEfc683;

    // ============ H200 Asset Configuration ============
    bytes32 constant H200_ASSET_ID = keccak256("H200_HOURLY");

    // Initial price for H200 GPU (in 1e18 format)
    // H200 hourly rental rate: $3.53/hour
    uint256 constant H200_INITIAL_PRICE = 3_530_000_000_000_000_000; // $3.53

    // ============ Market Configuration ============
    string constant H200_MARKET_NAME = "H200-PERP";

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

        console.log("=== Deploying H200 Market ===");
        console.log("Deployer:", deployer);
        console.log("Using existing MultiAssetOracle at:", MULTI_ASSET_ORACLE);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        MultiAssetOracle multiAssetOracle = MultiAssetOracle(MULTI_ASSET_ORACLE);

        // ============================================================
        // STEP 1: Register H200 asset if not already registered
        // ============================================================
        console.log("Step 1: Registering H200 asset...");

        if (!multiAssetOracle.isAssetRegistered(H200_ASSET_ID)) {
            multiAssetOracle.registerAsset(H200_ASSET_ID, H200_INITIAL_PRICE);
            console.log("Registered H200 asset at $3.53/hour");
        } else {
            console.log("H200 asset already registered");
            console.log("Current price:", multiAssetOracle.prices(H200_ASSET_ID) / 1e18, "USD");
        }
        console.log("");

        // ============================================================
        // STEP 2: Deploy H200 Oracle Adapter
        // ============================================================
        console.log("Step 2: Deploying H200 Oracle Adapter...");

        MultiAssetOracleAdapter h200Adapter = new MultiAssetOracleAdapter(
            address(multiAssetOracle),
            H200_ASSET_ID,
            ORACLE_MAX_AGE
        );
        console.log("H200 Oracle Adapter deployed at:", address(h200Adapter));
        console.log("Adapter price:", h200Adapter.getPrice() / 1e18, "USD");
        console.log("");

        // ============================================================
        // STEP 3: Deploy H200 vAMM Proxy
        // ============================================================
        console.log("Step 3: Deploying H200 vAMM proxy...");

        bytes memory h200InitData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            CLEARING_HOUSE,
            address(h200Adapter),
            H200_INITIAL_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY,
            FEE_BPS,
            FR_MAX_BPS_PER_HOUR,
            K_FUNDING,
            OBSERVATION_WINDOW
        );
        ERC1967Proxy h200VammProxy = new ERC1967Proxy(VAMM_IMPLEMENTATION, h200InitData);
        address h200Vamm = address(h200VammProxy);
        console.log("H200 vAMM Proxy deployed at:", h200Vamm);
        console.log("vAMM Mark Price:", vAMM(h200Vamm).getMarkPrice() / 1e18, "USD");
        console.log("");

        // ============================================================
        // STEP 4: Register H200 market in MarketRegistry
        // ============================================================
        console.log("Step 4: Registering H200 market...");

        bytes32 h200MarketId = keccak256(abi.encodePacked(H200_MARKET_NAME));
        console.log("H200 Market ID:", vm.toString(h200MarketId));

        MarketRegistry(MARKET_REGISTRY).addMarket(IMarketRegistry.AddMarketConfig({
            marketId: h200MarketId,
            vamm: h200Vamm,
            oracle: address(h200Adapter),
            baseAsset: MOCK_WETH,
            quoteToken: MOCK_USDC,
            baseUnit: 1e18,
            feeBps: TRADING_FEE_BPS,
            feeRouter: FEE_ROUTER,
            insuranceFund: INSURANCE_FUND
        }));
        console.log("H200 market registered successfully");
        console.log("");

        // ============================================================
        // STEP 5: Set risk parameters in ClearingHouse
        // ============================================================
        console.log("Step 5: Setting risk parameters...");

        ClearingHouse(CLEARING_HOUSE).setRiskParams(
            h200MarketId,
            IMR_BPS,
            MMR_BPS,
            LIQUIDATION_PENALTY_BPS,
            PENALTY_CAP
        );
        console.log("H200 risk parameters set:");
        console.log("  - IMR: 10%");
        console.log("  - MMR: 5%");
        console.log("  - Liquidation Penalty: 2.5%");
        console.log("  - Penalty Cap: $1000");
        console.log("");

        vm.stopBroadcast();

        // ============================================================
        // Print Deployment Summary
        // ============================================================
        console.log("");
        console.log("========================================");
        console.log("=== H200 DEPLOYMENT COMPLETE ===");
        console.log("========================================");
        console.log("");
        console.log("Contract Addresses:");
        console.log("-------------------");
        console.log("MultiAssetOracle:", MULTI_ASSET_ORACLE);
        console.log("H200 Oracle Adapter:", address(h200Adapter));
        console.log("H200 vAMM Proxy:", h200Vamm);
        console.log("");
        console.log("Configuration:");
        console.log("--------------");
        console.log("Market Name: H200-PERP");
        console.log("Market ID:", vm.toString(h200MarketId));
        console.log("Asset ID:", vm.toString(H200_ASSET_ID));
        console.log("Initial Price: $3.53/hour");
        console.log("");
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Add to overhaul/src/contracts/addresses.js:");
        console.log("   h200OracleAdapter: '", address(h200Adapter), "'");
        console.log("   vammProxyH200: '", h200Vamm, "'");
        console.log("");
        console.log("2. Update overhaul/src/contracts/addresses.js MARKET_IDS section:");
        console.log("   'H200-PERP': '", vm.toString(h200MarketId), "'");
        console.log("");
        console.log("3. Update overhaul/src/contracts/addresses.js ASSET_IDS section:");
        console.log("   'H200_HOURLY': '", vm.toString(H200_ASSET_ID), "'");
        console.log("");
        console.log("4. Update overhaul/src/contracts/addresses.js MARKETS section with H200-PERP configuration");
        console.log("");
        console.log("5. Use scripts/update_oracle_price.py to update H200 prices as needed:");
        console.log("   python scripts/update_oracle_price.py");
        console.log("");
    }
}
