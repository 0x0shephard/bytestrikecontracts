// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IVAMM} from "../src/Interfaces/IVAMM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestOpenPositionFinal
 * @notice Deposit USDC and test opening a long position on ETH-PERP-V2
 */
contract TestOpenPositionFinal is Script {
    address constant CLEARING_HOUSE = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;
    address constant COLLATERAL_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;
    address constant VAMM_V2 = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5; // New vAMM with $3.75 oracle
    address constant MOCK_USDC = 0x71075745A2A63dff3BD4819e9639D0E412c14AA9;

    // Market ID for ETH-PERP-V2 (now active!)
    bytes32 constant MARKET_ID = 0x923fe13d72f8a442cb473c31c3f8b89b76ea47edc7f5071ccdae6717ad84fe6e;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  TEST OPEN LONG POSITION");
        console.log("=========================================");
        console.log("");
        console.log("Trader:", trader);
        console.log("Market ID:", vm.toString(MARKET_ID));
        console.log("");

        ClearingHouse ch = ClearingHouse(CLEARING_HOUSE);
        ICollateralVault vault = ICollateralVault(COLLATERAL_VAULT);
        IERC20 usdc = IERC20(MOCK_USDC);

        // Check USDC balance
        uint256 usdcBalance = usdc.balanceOf(trader);
        console.log("USDC Wallet Balance:", usdcBalance / 1e6, "USDC");

        vm.startBroadcast(deployerPrivateKey);

        // STEP 1: Deposit USDC
        console.log("");
        console.log("STEP 1: Depositing USDC...");
        uint256 depositAmount = 5000e6; // 5,000 USDC

        require(usdcBalance >= depositAmount, "Insufficient USDC balance");

        usdc.approve(COLLATERAL_VAULT, depositAmount);
        console.log("  Approved", depositAmount / 1e6, "USDC");

        ch.deposit(MOCK_USDC, depositAmount);
        console.log("  Deposited", depositAmount / 1e6, "USDC");

        // Check collateral
        uint256 vaultBalance = vault.balanceOf(trader, MOCK_USDC);
        uint256 collateralValue = vault.getAccountCollateralValueX18(trader);
        console.log("  Vault Balance:", vaultBalance / 1e6, "USDC");
        console.log("  Collateral Value:", collateralValue / 1e18, "USD");
        console.log("");

        // STEP 2: Open position
        console.log("STEP 2: Opening long position...");
        uint128 positionSize = 0.001 ether; // 0.001 ETH (very small test)
        console.log("  Size: 0.001 ETH");

        // Get mark price for logging
        IVAMM vamm = IVAMM(VAMM_V2);
        uint256 markPrice = vamm.getMarkPrice();
        console.log("  Mark Price:", markPrice / 1e18, "USD");

        uint256 notional = (uint256(positionSize) * markPrice) / 1e18;
        console.log("  Notional:", notional / 1e18, "USD");
        console.log("");

        try ch.openPosition(
            MARKET_ID,
            true, // isLong
            positionSize,
            0 // no price limit
        ) {
            console.log("SUCCESS: Position opened!");
            console.log("");

            // Check position
            IClearingHouse.PositionView memory position = ch.getPosition(trader, MARKET_ID);
            console.log("Position Details:");
            console.log("  Size:", uint256(position.size) / 1e18, "ETH");
            console.log("  Margin:", position.margin / 1e18, "USD");
            console.log("  Entry Price:", position.entryPriceX18 / 1e18, "USD");
            console.log("");

            // Check remaining collateral
            uint256 finalCollateral = vault.getAccountCollateralValueX18(trader);
            uint256 reservedMargin = ch._totalReservedMargin(trader);
            console.log("Final Status:");
            console.log("  Total Collateral:", finalCollateral / 1e18, "USD");
            console.log("  Reserved Margin:", reservedMargin / 1e18, "USD");
            console.log("  Available:", (finalCollateral - reservedMargin) / 1e18, "USD");

        } catch Error(string memory reason) {
            console.log("FAILED: Transaction reverted");
            console.log("Reason:", reason);

        } catch (bytes memory lowLevelData) {
            console.log("FAILED: Low-level revert");
            console.logBytes(lowLevelData);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=========================================");
        console.log("  TEST COMPLETE");
        console.log("=========================================");
    }
}
