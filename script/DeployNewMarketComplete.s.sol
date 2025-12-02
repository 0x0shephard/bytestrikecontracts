// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import "../src/vAMM.sol";
import "../src/ClearingHouse.sol";
import "../src/MarketRegistry.sol";
import "../src/Oracle/Oracle.sol";
import "../src/Interfaces/IMarketRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @notice Deploys a complete new market with:
 * - New vAMM
 * - Market registration
 * - Risk parameters: IMR=10%, MMR=5%, Liq Penalty=2.5%
 *
 * Run with:
 * forge script script/DeployNewMarketComplete.s.sol:DeployNewMarketComplete --rpc-url sepolia --broadcast --verify -vvvv
 */
contract DeployNewMarketComplete is Script {
    // Deployed contract addresses (Sepolia)
    address constant CLEARING_HOUSE = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;
    address constant MARKET_REGISTRY = 0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD;
    address constant COLLATERAL_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;
    address constant INSURANCE_FUND = 0x3C1085dF918a38A95F84945E6705CC857b664074;
    address constant FEE_ROUTER = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F;
    address constant MOCK_USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;
    address constant MOCK_WETH = 0x36EC0f183Bd4014097934dcD7e23d9A5F0a69b40; // Base asset placeholder
    address constant ORACLE_H100 = 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad;

    // Market configuration
    string constant MARKET_NAME = "H100-PERP";

    // vAMM parameters
    uint256 constant INITIAL_PRICE = 3.79e18; // $3.79/hour
    uint256 constant INITIAL_BASE_RESERVE = 100000e18; // 100k base units
    uint128 constant LIQUIDITY = 1000000e18; // 1M liquidity
    uint16 constant FEE_BPS = 10; // 0.1% fee
    uint256 constant FR_MAX_BPS_PER_HOUR = 100; // 1% max funding per hour
    uint256 constant K_FUNDING = 1e18; // 1.0 funding coefficient
    uint32 constant OBSERVATION_WINDOW = 900; // 15 minutes TWAP

    // Risk parameters
    uint256 constant IMR_BPS = 1000; // 10% Initial Margin Requirement
    uint256 constant MMR_BPS = 500; // 5% Maintenance Margin Requirement
    uint256 constant LIQUIDATION_PENALTY_BPS = 250; // 2.5% Liquidation Penalty
    uint256 constant PENALTY_CAP = 1000e18; // $1000 max penalty

    // Trading fee
    uint16 constant TRADING_FEE_BPS = 10; // 0.1% trading fee

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying New Market ===");
        console.log("Deployer:", deployer);
        console.log("Market Name:", MARKET_NAME);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy new vAMM
        console.log("Step 1: Deploying new vAMM...");
        address vammImplementation = address(new vAMM());
        console.log("vAMM Implementation deployed at:", vammImplementation);

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            CLEARING_HOUSE,
            ORACLE_H100,
            INITIAL_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY,
            FEE_BPS,
            FR_MAX_BPS_PER_HOUR,
            K_FUNDING,
            OBSERVATION_WINDOW
        );

        ERC1967Proxy vammProxy = new ERC1967Proxy(vammImplementation, initData);
        address vammAddress = address(vammProxy);
        console.log("vAMM Proxy deployed at:", vammAddress);
        console.log("");

        // Step 2: Register market in MarketRegistry
        console.log("Step 2: Registering market in MarketRegistry...");
        bytes32 marketId = keccak256(abi.encodePacked(MARKET_NAME));
        console.log("Market ID:", vm.toString(marketId));

        IMarketRegistry.AddMarketConfig memory config = IMarketRegistry.AddMarketConfig({
            marketId: marketId,
            vamm: vammAddress,
            oracle: ORACLE_H100,
            baseAsset: MOCK_WETH, // Using WETH as base asset placeholder
            quoteToken: MOCK_USDC,
            baseUnit: 1e18, // Standard unit
            feeBps: TRADING_FEE_BPS,
            feeRouter: FEE_ROUTER,
            insuranceFund: INSURANCE_FUND
        });

        MarketRegistry(MARKET_REGISTRY).addMarket(config);
        console.log("Market registered successfully");
        console.log("");

        // Step 3: Set risk parameters in ClearingHouse
        console.log("Step 3: Setting risk parameters...");
        console.log("IMR:", IMR_BPS, "bps (10%)");
        console.log("MMR:", MMR_BPS, "bps (5%)");
        console.log("Liquidation Penalty:", LIQUIDATION_PENALTY_BPS, "bps (2.5%)");
        console.log("Penalty Cap:", PENALTY_CAP / 1e18, "USD");

        ClearingHouse(CLEARING_HOUSE).setRiskParams(
            marketId,
            IMR_BPS,
            MMR_BPS,
            LIQUIDATION_PENALTY_BPS,
            PENALTY_CAP
        );
        console.log("Risk parameters set successfully");
        console.log("");

        // Step 4: Verify deployment
        console.log("Step 4: Verifying deployment...");

        // Check vAMM
        vAMM vammContract = vAMM(vammAddress);
        uint256 markPrice = vammContract.getMarkPrice();
        console.log("vAMM Mark Price:", markPrice / 1e18, "USD");

        // Check market registry
        IMarketRegistry.Market memory registeredMarket = MarketRegistry(MARKET_REGISTRY).getMarket(marketId);
        console.log("Registered vAMM:", registeredMarket.vamm);
        console.log("Market Paused:", registeredMarket.paused);
        console.log("Market Active:", !registeredMarket.paused);

        // Check risk params
        (uint256 imr, uint256 mmr, uint256 liqPenalty, uint256 cap) = ClearingHouse(CLEARING_HOUSE).marketRiskParams(marketId);
        console.log("ClearingHouse IMR:", imr, "bps");
        console.log("ClearingHouse MMR:", mmr, "bps");
        console.log("");

        vm.stopBroadcast();

        // Print summary for frontend integration
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Frontend Integration:");
        console.log("Add to bytestrike3/src/contracts/addresses.js:");
        console.log("");
        console.log("export const SEPOLIA_CONTRACTS = {");
        console.log("  ...,");
        console.log("  vammProxy:", vammAddress, ",");
        console.log("};");
        console.log("");
        console.log("export const MARKET_IDS = {");
        console.log("  'H100-PERP':", vm.toString(marketId), ",");
        console.log("};");
        console.log("");
        console.log("Market Configuration:");
        console.log("- Market ID:", vm.toString(marketId));
        console.log("- vAMM Address:", vammAddress);
        console.log("- Oracle:", ORACLE_H100);
        console.log("- Initial Price: $3.79/hour");
        console.log("- IMR: 10%");
        console.log("- MMR: 5%");
        console.log("- Liquidation Penalty: 2.5%");
        console.log("- Trading Fee: 0.1%");
    }
}
