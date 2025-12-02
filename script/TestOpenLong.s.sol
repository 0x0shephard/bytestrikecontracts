// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {IVAMM} from "../src/Interfaces/IVAMM.sol";
import {IOracle} from "../src/Interfaces/IOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestOpenLong
 * @notice Test script to open a long position and debug failures
 */
contract TestOpenLong is Script {
    // Sepolia addresses - UPDATED CLEARING HOUSE
    address constant CLEARING_HOUSE = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;
    address constant COLLATERAL_VAULT = 0x46615074Bb2bAA2b33553d50A25D0e4f2ec4542e;
    address constant MARKET_REGISTRY = 0x6d96DFC1a209B500Eb928C83455F415cb96AFF3C;
    address constant VAMM = 0xb46928829C728e3CE1B20eA4157a23553eeA5701;
    address constant MOCK_USDC = 0x71075745A2A63dff3BD4819e9639D0E412c14AA9;

    // Market ID for ETH-PERP
    bytes32 constant MARKET_ID = 0x352291f10e3a0d4a9f7beb3b623eac0b06f735c95170f956bc68b2f8b504a35d;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  TEST OPEN LONG POSITION");
        console.log("=========================================");
        console.log("");
        console.log("Trader:", trader);
        console.log("ClearingHouse:", CLEARING_HOUSE);
        console.log("");

        ClearingHouse ch = ClearingHouse(CLEARING_HOUSE);
        ICollateralVault vault = ICollateralVault(COLLATERAL_VAULT);
        IMarketRegistry registry = IMarketRegistry(MARKET_REGISTRY);

        // PRE-FLIGHT CHECKS
        console.log("=== PRE-FLIGHT CHECKS ===");
        console.log("");

        // 1. Check market
        console.log("1. Market Status:");
        bool isActive = registry.isActive(MARKET_ID);
        console.log("   Is Active:", isActive);
        require(isActive, "Market not active");

        IMarketRegistry.Market memory market = registry.getMarket(MARKET_ID);
        console.log("   vAMM:", market.vamm);
        console.log("   Oracle:", market.oracle);
        console.log("   Paused:", market.paused);
        console.log("");

        // 2. Check collateral BEFORE trade
        console.log("2. Trader Collateral (BEFORE):");
        uint256 usdcBalance = vault.balanceOf(trader, MOCK_USDC);
        console.log("   USDC Balance:", usdcBalance);

        uint256 collateralValue = vault.getAccountCollateralValueX18(trader);
        console.log("   Total Collateral Value (X18):", collateralValue);

        uint256 reservedMargin = ch._totalReservedMargin(trader);
        console.log("   Reserved Margin:", reservedMargin);
        console.log("   Available:", collateralValue - reservedMargin);
        console.log("");

        // 3. Check oracle price
        console.log("3. Oracle Price:");
        if (market.oracle != address(0)) {
            uint256 oraclePrice = IOracle(market.oracle).getPrice();
            console.log("   Oracle Price (X18):", oraclePrice);
        }
        console.log("");

        // 4. Check vAMM
        console.log("4. vAMM Status:");
        IVAMM vamm = IVAMM(market.vamm);
        uint256 markPrice = vamm.getMarkPrice();
        console.log("   Mark Price (X18):", markPrice);
        console.log("");

        // 5. Check risk params
        console.log("5. Risk Parameters:");
        (uint256 imrBps, uint256 mmrBps, uint256 liqPenaltyBps, uint256 penaltyCap) =
            ch.marketRiskParams(MARKET_ID);
        console.log("   IMR BPS:", imrBps);
        console.log("   MMR BPS:", mmrBps);

        require(imrBps > 0, "IMR not set");
        require(mmrBps > 0, "MMR not set");
        console.log("");

        // 6. Calculate requirements for test trade
        uint128 testSize = 0.01 ether; // 0.01 ETH (small test)
        console.log("6. Trade Requirements (0.01 ETH long):");
        console.log("   Position Size:", testSize);

        uint256 notional = (uint256(testSize) * markPrice) / 1e18;
        console.log("   Notional Value:", notional);

        uint256 marginRequired = (notional * imrBps) / 10_000;
        console.log("   Margin Required (IMR):", marginRequired);

        uint256 fee = (notional * market.feeBps) / 10_000;
        console.log("   Trading Fee:", fee);

        uint256 totalNeeded = marginRequired + fee;
        console.log("   Total Needed:", totalNeeded);
        console.log("   Have Available:", collateralValue - reservedMargin);

        require(collateralValue - reservedMargin >= totalNeeded, "Insufficient collateral");
        console.log("");

        // 7. Check vault oracle config
        console.log("7. Vault Oracle Config:");
        address vaultOracle = vault.getOracle();
        console.log("   Vault Oracle:", vaultOracle);

        ICollateralVault.CollateralConfig memory usdcConfig = vault.getConfig(MOCK_USDC);
        console.log("   USDC Enabled:", usdcConfig.enabled);
        console.log("   USDC Oracle Symbol:", usdcConfig.oracleSymbol);
        console.log("");

        // ATTEMPT TO OPEN POSITION
        console.log("=== ATTEMPTING TO OPEN POSITION ===");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        try ch.openPosition(
            MARKET_ID,
            true, // isLong
            testSize,
            0 // no price limit for testing
        ) {
            console.log("SUCCESS: Position opened!");
            console.log("");

            // Check position
            IClearingHouse.PositionView memory position = ch.getPosition(trader, MARKET_ID);
            console.log("Position Details:");
            console.log("   Size:", uint256(position.size));
            console.log("   Margin:", position.margin);
            console.log("   Entry Price (X18):", position.entryPriceX18);
            console.log("   Realized PnL:", uint256(position.realizedPnL));
            console.log("");

        } catch Error(string memory reason) {
            console.log("FAILED: Transaction reverted");
            console.log("Revert Reason:", reason);
            console.log("");

            // Additional debugging
            console.log("=== DEBUGGING FAILURE ===");

            // Try to identify specific failure point
            if (keccak256(bytes(reason)) == keccak256(bytes("Insufficient collateral"))) {
                console.log("Issue: Insufficient collateral");
                console.log("This means _ensureAvailableCollateral failed");
                console.log("Check: collateralValue >= _totalReservedMargin + amount");

            } else if (keccak256(bytes(reason)) == keccak256(bytes("IMR breach after trade"))) {
                console.log("Issue: IMR breach after trade");
                console.log("This means position.margin < requiredMargin after fees");

            } else if (keccak256(bytes(reason)) == keccak256(bytes("Market not active"))) {
                console.log("Issue: Market not active or paused");

            } else {
                console.log("Unknown error - investigating...");
            }

        } catch (bytes memory lowLevelData) {
            console.log("FAILED: Low-level revert");
            console.logBytes(lowLevelData);
        }

        vm.stopBroadcast();

        // POST-FLIGHT STATUS
        console.log("=== POST-FLIGHT STATUS ===");
        console.log("");

        uint256 finalUsdcBalance = vault.balanceOf(trader, MOCK_USDC);
        uint256 finalCollateralValue = vault.getAccountCollateralValueX18(trader);
        uint256 finalReservedMargin = ch._totalReservedMargin(trader);

        console.log("Final Balances:");
        console.log("   USDC Balance:", finalUsdcBalance);
        console.log("   Collateral Value:", finalCollateralValue);
        console.log("   Reserved Margin:", finalReservedMargin);
        console.log("");

        IClearingHouse.PositionView memory finalPosition = ch.getPosition(trader, MARKET_ID);
        console.log("Final Position:");
        console.log("   Size:", uint256(finalPosition.size));
        console.log("   Margin:", finalPosition.margin);
    }
}
