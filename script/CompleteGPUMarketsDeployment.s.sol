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
 * @title CompleteGPUMarketsDeployment
 * @notice Completes the GPU markets deployment using the existing MultiAssetOracle
 *
 * This script continues from where the previous deployment left off:
 * - MultiAssetOracle already deployed at: 0xCe23E7298CF6300963bb722819Ba54C700f8D2d1
 * - Needs to: register assets, deploy adapters, deploy vAMMs, register markets, set risk params
 */
contract CompleteGPUMarketsDeployment is Script {
    // ============ Existing Infrastructure ============
    address constant CLEARING_HOUSE = 0x18F863b1b0A3Eca6B2235dc1957291E357f490B0;
    address constant MARKET_REGISTRY = 0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD;
    address constant INSURANCE_FUND = 0x3C1085dF918a38A95F84945E6705CC857b664074;
    address constant FEE_ROUTER = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F;
    address constant MOCK_USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;
    address constant MOCK_WETH = 0xc696f32d4F8219CbA41bcD5C949b2551df13A7d6;
    address constant VAMM_IMPLEMENTATION = 0xd64175cE957F089bA7fb3EBdA5B17f268DE01190;
    address constant EXISTING_H100_VAMM = 0xF7210ccC245323258CC15e0Ca094eBbe2DC2CD85;

    // EXISTING MultiAssetOracle (already deployed)
    address constant MULTI_ASSET_ORACLE = 0xCe23E7298CF6300963bb722819Ba54C700f8D2d1;

    // ============ Asset IDs ============
    bytes32 constant H100_ASSET_ID = keccak256("H100_HOURLY");
    bytes32 constant H100_HYPERSCALERS_ASSET_ID = keccak256("H100_HYPERSCALERS_HOURLY");
    bytes32 constant H100_NON_HYPERSCALERS_ASSET_ID = keccak256("H100_NON_HYPERSCALERS_HOURLY");

    // ============ Initial Prices (1e18 format) ============
    uint256 constant H100_PRICE = 3_790_000_000_000_000_000;
    uint256 constant H100_HYPERSCALERS_PRICE = 4_202_163_309_021_113_000;
    uint256 constant H100_NON_HYPERSCALERS_PRICE = 2_946_243_092_754_190_000;

    // ============ Market Names ============
    string constant HYPERSCALERS_MARKET_NAME = "H100-HyperScalers-PERP";
    string constant NON_HYPERSCALERS_MARKET_NAME = "H100-non-HyperScalers-PERP";

    // ============ vAMM Parameters ============
    uint256 constant INITIAL_BASE_RESERVE = 100_000e18;
    uint128 constant LIQUIDITY = 1_000_000e18;
    uint16 constant FEE_BPS = 10;
    uint256 constant FR_MAX_BPS_PER_HOUR = 100;
    uint256 constant K_FUNDING = 1e18;
    uint32 constant OBSERVATION_WINDOW = 900;

    // ============ Risk Parameters ============
    uint256 constant IMR_BPS = 1000;
    uint256 constant MMR_BPS = 500;
    uint256 constant LIQUIDATION_PENALTY_BPS = 250;
    uint256 constant PENALTY_CAP = 1000e18;
    uint256 constant ORACLE_MAX_AGE = 86400;
    uint16 constant TRADING_FEE_BPS = 10;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Completing GPU Markets Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Using existing MultiAssetOracle at:", MULTI_ASSET_ORACLE);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        MultiAssetOracle multiAssetOracle = MultiAssetOracle(MULTI_ASSET_ORACLE);

        // ============================================================
        // STEP 1: Register assets if not already registered
        // ============================================================
        console.log("Step 1: Registering assets...");

        if (!multiAssetOracle.isAssetRegistered(H100_ASSET_ID)) {
            multiAssetOracle.registerAsset(H100_ASSET_ID, H100_PRICE);
            console.log("Registered H100 asset");
        } else {
            console.log("H100 asset already registered");
        }

        if (!multiAssetOracle.isAssetRegistered(H100_HYPERSCALERS_ASSET_ID)) {
            multiAssetOracle.registerAsset(H100_HYPERSCALERS_ASSET_ID, H100_HYPERSCALERS_PRICE);
            console.log("Registered H100-HyperScalers asset");
        } else {
            console.log("H100-HyperScalers asset already registered");
        }

        if (!multiAssetOracle.isAssetRegistered(H100_NON_HYPERSCALERS_ASSET_ID)) {
            multiAssetOracle.registerAsset(H100_NON_HYPERSCALERS_ASSET_ID, H100_NON_HYPERSCALERS_PRICE);
            console.log("Registered H100-non-HyperScalers asset");
        } else {
            console.log("H100-non-HyperScalers asset already registered");
        }
        console.log("");

        // ============================================================
        // STEP 2: Deploy Oracle Adapters
        // ============================================================
        console.log("Step 2: Deploying Oracle Adapters...");

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
        // STEP 3: Migrate existing H100-PERP vAMM to new oracle
        // ============================================================
        console.log("Step 3: Migrating existing H100-PERP vAMM...");
        vAMM(EXISTING_H100_VAMM).setOracle(address(h100Adapter));
        console.log("H100-PERP vAMM migrated to new oracle");
        console.log("");

        // ============================================================
        // STEP 4: Deploy new vAMM Proxies
        // ============================================================
        console.log("Step 4: Deploying new vAMM proxies...");

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
        console.log("HyperScalers vAMM deployed at:", hyperscalersVamm);

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
        console.log("non-HyperScalers vAMM deployed at:", nonHyperscalersVamm);
        console.log("");

        // ============================================================
        // STEP 5: Register markets
        // ============================================================
        console.log("Step 5: Registering markets...");

        bytes32 hyperscalersMarketId = keccak256(abi.encodePacked(HYPERSCALERS_MARKET_NAME));
        bytes32 nonHyperscalersMarketId = keccak256(abi.encodePacked(NON_HYPERSCALERS_MARKET_NAME));

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
        // STEP 6: Set risk parameters
        // ============================================================
        console.log("Step 6: Setting risk parameters...");

        ClearingHouse(CLEARING_HOUSE).setRiskParams(
            hyperscalersMarketId,
            IMR_BPS,
            MMR_BPS,
            LIQUIDATION_PENALTY_BPS,
            PENALTY_CAP
        );
        console.log("HyperScalers risk params set");

        ClearingHouse(CLEARING_HOUSE).setRiskParams(
            nonHyperscalersMarketId,
            IMR_BPS,
            MMR_BPS,
            LIQUIDATION_PENALTY_BPS,
            PENALTY_CAP
        );
        console.log("non-HyperScalers risk params set");

        vm.stopBroadcast();

        // ============================================================
        // Print Summary
        // ============================================================
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("MultiAssetOracle:", MULTI_ASSET_ORACLE);
        console.log("h100OracleAdapter:", address(h100Adapter));
        console.log("hyperscalersOracleAdapter:", address(hyperscalersAdapter));
        console.log("nonHyperscalersOracleAdapter:", address(nonHyperscalersAdapter));
        console.log("vammProxyHyperscalers:", hyperscalersVamm);
        console.log("vammProxyNonHyperscalers:", nonHyperscalersVamm);
        console.log("");
        console.log("Market IDs:");
        console.log("H100-HyperScalers-PERP:", vm.toString(hyperscalersMarketId));
        console.log("H100-non-HyperScalers-PERP:", vm.toString(nonHyperscalersMarketId));
    }
}
