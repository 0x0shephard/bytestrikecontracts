// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {Oracle} from "../src/Oracle/Oracle.sol";

/**
 * @title FixUSDCCollateralAndOracle
 * @notice Register correct mUSDC address in CollateralVault and configure oracle price feed
 *
 * Issue: mUSDC (0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7) deposits succeed but
 * getAccountCollateralValueX18() reverts because:
 * 1. CollateralVault may not have mUSDC registered
 * 2. Oracle doesn't have price feed configured for "USDC" symbol
 *
 * Solution:
 * 1. Register mUSDC in CollateralVault with oracleSymbol="USDC"
 * 2. Set USDC price feed in Oracle (use CuOracle at 0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c or create mock feed)
 *
 * Run with:
 * forge script script/FixUSDCCollateralAndOracle.s.sol:FixUSDCCollateralAndOracle --rpc-url sepolia --broadcast -vvvv
 */
contract FixUSDCCollateralAndOracle is Script {
    // Deployed contract addresses
    address constant COLLATERAL_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;
    address constant MOCK_USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7; // Correct mUSDC address
    address constant ORACLE = 0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c; // CuOracle used by CollateralVault

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  FIX USDC COLLATERAL & ORACLE");
        console.log("=========================================");
        console.log("");
        console.log("Admin:", deployer);
        console.log("Vault:", COLLATERAL_VAULT);
        console.log("mUSDC:", MOCK_USDC);
        console.log("Oracle:", ORACLE);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        CollateralVault vault = CollateralVault(COLLATERAL_VAULT);
        Oracle oracle = Oracle(ORACLE);

        // Step 1: Register mUSDC in CollateralVault
        console.log("Step 1: Registering mUSDC collateral in vault...");
        console.log("  Base Unit: 1000000 (6 decimals)");
        console.log("  Haircut: 0 bps (no haircut for stablecoin)");
        console.log("  Liq Incentive: 500 bps (5%)");
        console.log("  Oracle Symbol: USDC");
        console.log("");

        ICollateralVault.CollateralConfig memory config = ICollateralVault.CollateralConfig({
            token: MOCK_USDC,
            baseUnit: 1e6,          // USDC has 6 decimals
            haircutBps: 0,          // No haircut for stablecoin
            liqIncentiveBps: 500,   // 5% liquidation incentive
            cap: 0,                 // No protocol-wide cap
            accountCap: 0,          // No per-account cap
            enabled: true,
            depositPaused: false,
            withdrawPaused: false,
            oracleSymbol: "USDC"    // Oracle will look up price using this symbol
        });

        vault.registerCollateral(config);
        console.log("SUCCESS: mUSDC registered in vault!");
        console.log("");

        // Step 2: Configure Oracle price feed for USDC
        console.log("Step 2: Configuring oracle price feed for USDC...");

        // Deploy a simple mock price feed that returns $1.00 (1e8 with 8 decimals like Chainlink)
        // For now, we'll use CuOracle which should already have the price feed
        // If CuOracle doesn't work, we'll need to deploy a MockPriceFeed

        // Check if oracle owner matches deployer
        address oracleOwner = oracle.owner();
        console.log("Oracle owner:", oracleOwner);
        console.log("Deployer:", deployer);

        if (oracleOwner == deployer) {
            // Deploy a simple mock Chainlink price feed for USDC = $1.00
            MockUSDCPriceFeed mockFeed = new MockUSDCPriceFeed();
            console.log("MockUSDCPriceFeed deployed at:", address(mockFeed));

            // Set price feed in oracle
            oracle.setPriceFeed("USDC", address(mockFeed));
            console.log("Oracle price feed set for USDC");

            // Set base unit for USDC (1e6 for 6 decimals)
            oracle.setBaseUnit("USDC", 1e6);
            console.log("Oracle base unit set for USDC: 1e6");
            console.log("");

            // Test oracle price
            uint256 usdcPrice = oracle.getPrice("USDC");
            console.log("USDC price from oracle:", usdcPrice / 1e18, "USD (1e18 format)");
        } else {
            console.log("WARNING: Cannot configure oracle - deployer is not owner");
            console.log("  You need to configure the oracle with the owner account:", oracleOwner);
        }
        console.log("");

        vm.stopBroadcast();

        // Verification
        console.log("=========================================");
        console.log("  VERIFICATION");
        console.log("=========================================");
        console.log("");

        ICollateralVault.CollateralConfig memory verifyConfig = vault.getConfig(MOCK_USDC);
        console.log("Vault Configuration:");
        console.log("  Token:", verifyConfig.token);
        console.log("  Base Unit:", verifyConfig.baseUnit);
        console.log("  Haircut BPS:", verifyConfig.haircutBps);
        console.log("  Liq Incentive BPS:", verifyConfig.liqIncentiveBps);
        console.log("  Enabled:", verifyConfig.enabled);
        console.log("  Oracle Symbol:", verifyConfig.oracleSymbol);
        console.log("");

        // Test getAccountCollateralValueX18 for user
        address testUser = 0xCc624fFA5df1F3F4b30aa8abd30186a86254F406;
        console.log("Testing getAccountCollateralValueX18 for:", testUser);
        try vault.getAccountCollateralValueX18(testUser) returns (uint256 value) {
            console.log("  SUCCESS! Collateral value:", value / 1e18, "USD");
        } catch {
            console.log("  FAILED: Still reverting");
        }

        console.log("");
        console.log("=========================================");
        console.log("  FIX COMPLETE!");
        console.log("=========================================");
    }
}

/**
 * @title MockUSDCPriceFeed
 * @notice Mock Chainlink price feed that returns $1.00 for USDC
 */
contract MockUSDCPriceFeed {
    uint8 public constant decimals = 8;
    string public description = "USDC / USD";
    uint256 public version = 1;

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            1,                      // roundId
            1e8,                    // $1.00 with 8 decimals
            block.timestamp,        // startedAt
            block.timestamp,        // updatedAt
            1                       // answeredInRound
        );
    }
}
