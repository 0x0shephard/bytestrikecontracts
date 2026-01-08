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
 * @title DeployB200Market
 * @notice Deploys a new B200-PERP perpetual market using the existing MultiAssetOracle infrastructure
 *
 * This script:
 * 1. Registers B200 asset in the existing MultiAssetOracle
 * 2. Deploys a MultiAssetOracleAdapter for B200
 * 3. Deploys a new vAMM proxy for B200-PERP market
 * 4. Registers the market in MarketRegistry
 * 5. Sets risk parameters in ClearingHouse
 *
 * Run with:
 * forge script script/DeployB200Market.s.sol:DeployB200Market --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
 */
contract DeployB200Market is Script {
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

    // ============ B200 Asset Configuration ============
    bytes32 constant B200_ASSET_ID = keccak256("B200_HOURLY");

    // Initial price for B200 GPU (in 1e18 format)
    // Note: Update this based on current B200 hourly rental rates
    // B200 hourly rental rate: $7.15/hour
    uint256 constant B200_INITIAL_PRICE = 7_150_000_000_000_000_000; // $7.15

    // ============ Market Configuration ============
    string constant B200_MARKET_NAME = "B200-PERP";

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

        console.log("=== Deploying B200 Market ===");
        console.log("Deployer:", deployer);
        console.log("Using existing MultiAssetOracle at:", MULTI_ASSET_ORACLE);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        MultiAssetOracle multiAssetOracle = MultiAssetOracle(MULTI_ASSET_ORACLE);

        // ============================================================
        // STEP 1: Register B200 asset if not already registered
        // ============================================================
        console.log("Step 1: Registering B200 asset...");

        if (!multiAssetOracle.isAssetRegistered(B200_ASSET_ID)) {
            multiAssetOracle.registerAsset(B200_ASSET_ID, B200_INITIAL_PRICE);
            console.log("Registered B200 asset at $7.15/hour");
        } else {
            console.log("B200 asset already registered");
            console.log("Current price:", multiAssetOracle.prices(B200_ASSET_ID) / 1e18, "USD");
        }
        console.log("");

        // ============================================================
        // STEP 2: Deploy B200 Oracle Adapter
        // ============================================================
        console.log("Step 2: Deploying B200 Oracle Adapter...");

        MultiAssetOracleAdapter b200Adapter = new MultiAssetOracleAdapter(
            address(multiAssetOracle),
            B200_ASSET_ID,
            ORACLE_MAX_AGE
        );
        console.log("B200 Oracle Adapter deployed at:", address(b200Adapter));
        console.log("Adapter price:", b200Adapter.getPrice() / 1e18, "USD");
        console.log("");

        // ============================================================
        // STEP 3: Deploy B200 vAMM Proxy
        // ============================================================
        console.log("Step 3: Deploying B200 vAMM proxy...");

        bytes memory b200InitData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            CLEARING_HOUSE,
            address(b200Adapter),
            B200_INITIAL_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY,
            FEE_BPS,
            FR_MAX_BPS_PER_HOUR,
            K_FUNDING,
            OBSERVATION_WINDOW
        );
        ERC1967Proxy b200VammProxy = new ERC1967Proxy(VAMM_IMPLEMENTATION, b200InitData);
        address b200Vamm = address(b200VammProxy);
        console.log("B200 vAMM Proxy deployed at:", b200Vamm);
        console.log("vAMM Mark Price:", vAMM(b200Vamm).getMarkPrice() / 1e18, "USD");
        console.log("");

        // ============================================================
        // STEP 4: Register B200 market in MarketRegistry
        // ============================================================
        console.log("Step 4: Registering B200 market...");

        bytes32 b200MarketId = keccak256(abi.encodePacked(B200_MARKET_NAME));
        console.log("B200 Market ID:", vm.toString(b200MarketId));

        MarketRegistry(MARKET_REGISTRY).addMarket(IMarketRegistry.AddMarketConfig({
            marketId: b200MarketId,
            vamm: b200Vamm,
            oracle: address(b200Adapter),
            baseAsset: MOCK_WETH,
            quoteToken: MOCK_USDC,
            baseUnit: 1e18,
            feeBps: TRADING_FEE_BPS,
            feeRouter: FEE_ROUTER,
            insuranceFund: INSURANCE_FUND
        }));
        console.log("B200 market registered successfully");
        console.log("");

        // ============================================================
        // STEP 5: Set risk parameters in ClearingHouse
        // ============================================================
        console.log("Step 5: Setting risk parameters...");

        ClearingHouse(CLEARING_HOUSE).setRiskParams(
            b200MarketId,
            IMR_BPS,
            MMR_BPS,
            LIQUIDATION_PENALTY_BPS,
            PENALTY_CAP
        );
        console.log("B200 risk parameters set:");
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
        console.log("=== B200 DEPLOYMENT COMPLETE ===");
        console.log("========================================");
        console.log("");
        console.log("Contract Addresses:");
        console.log("-------------------");
        console.log("MultiAssetOracle:", MULTI_ASSET_ORACLE);
        console.log("B200 Oracle Adapter:", address(b200Adapter));
        console.log("B200 vAMM Proxy:", b200Vamm);
        console.log("");
        console.log("Configuration:");
        console.log("--------------");
        console.log("Market Name: B200-PERP");
        console.log("Market ID:", vm.toString(b200MarketId));
        console.log("Asset ID:", vm.toString(B200_ASSET_ID));
        console.log("Initial Price: $7.15/hour");
        console.log("");
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Add to overhaul/src/contracts/addresses.js:");
        console.log("   b200OracleAdapter: '", address(b200Adapter), "'");
        console.log("   vammProxyB200: '", b200Vamm, "'");
        console.log("");
        console.log("2. Update overhaul/src/marketData.jsx to include B200-PERP market");
        console.log("");
        console.log("3. Update oracle price updater script to include B200_HOURLY asset");
        console.log("");
        console.log("4. Use update_oracle_price.py to set accurate B200 prices:");
        console.log("   python scripts/update_oracle_price.py");
        console.log("");
    }
}
