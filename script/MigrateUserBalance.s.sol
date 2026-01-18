// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MigrateUserBalance
 * @notice Migrates user's balance from old vault to new vault
 *   1. Withdraws from old vault via ClearingHouse
 *   2. Approves new vault
 *   3. Deposits into new vault via ClearingHouse
 *
 * Run with:
 * forge script script/MigrateUserBalance.s.sol:MigrateUserBalance --rpc-url sepolia --broadcast -vvvv
 */
contract MigrateUserBalance is Script {
    // Deployed contracts
    address constant CLEARING_HOUSE_PROXY = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;
    address constant OLD_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;
    address constant NEW_VAULT = 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2; // UPDATE THIS
    address constant CORRECT_MUSDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;

    function run() external {
        uint256 userPrivateKey = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(userPrivateKey);

        console.log("=========================================");
        console.log("  USER BALANCE MIGRATION");
        console.log("=========================================");
        console.log("");
        console.log("User:", user);
        console.log("Old Vault:", OLD_VAULT);
        console.log("New Vault:", NEW_VAULT);
        console.log("Token (mUSDC):", CORRECT_MUSDC);
        console.log("");

        ClearingHouse clearingHouse = ClearingHouse(CLEARING_HOUSE_PROXY);
        CollateralVault oldVault = CollateralVault(OLD_VAULT);
        CollateralVault newVault = CollateralVault(NEW_VAULT);

        // Check balances before
        uint256 balanceInOldVault = oldVault.balanceOf(user, CORRECT_MUSDC);
        uint256 balanceInNewVault = newVault.balanceOf(user, CORRECT_MUSDC);
        uint256 walletBalance = IERC20(CORRECT_MUSDC).balanceOf(user);

        console.log("BEFORE MIGRATION:");
        console.log("  Balance in old vault:", balanceInOldVault);
        console.log("  Balance in new vault:", balanceInNewVault);
        console.log("  Balance in wallet:", walletBalance);
        console.log("");

        if (balanceInOldVault == 0) {
            console.log("No balance to migrate!");
            return;
        }

        vm.startBroadcast(userPrivateKey);

        // STEP 1: Withdraw from old vault
        console.log("STEP 1: Withdrawing from old vault...");
        clearingHouse.withdraw(CORRECT_MUSDC, balanceInOldVault);
        console.log("  Withdrawn:", balanceInOldVault);
        console.log("");

        // STEP 2: Approve new vault
        console.log("STEP 2: Approving new vault...");
        IERC20(CORRECT_MUSDC).approve(CLEARING_HOUSE_PROXY, balanceInOldVault);
        console.log("  Approved:", balanceInOldVault);
        console.log("");

        // STEP 3: Deposit into new vault
        console.log("STEP 3: Depositing into new vault...");
        clearingHouse.deposit(CORRECT_MUSDC, balanceInOldVault);
        console.log("  Deposited:", balanceInOldVault);
        console.log("");

        vm.stopBroadcast();

        // Verify migration
        uint256 finalBalanceOld = oldVault.balanceOf(user, CORRECT_MUSDC);
        uint256 finalBalanceNew = newVault.balanceOf(user, CORRECT_MUSDC);

        console.log("AFTER MIGRATION:");
        console.log("  Balance in old vault:", finalBalanceOld);
        console.log("  Balance in new vault:", finalBalanceNew);
        console.log("");

        require(finalBalanceOld == 0, "Old vault not empty");
        require(finalBalanceNew == balanceInOldVault, "New vault balance incorrect");

        console.log("=========================================");
        console.log("  MIGRATION SUCCESSFUL!");
        console.log("=========================================");
        console.log("");
        console.log("Migrated:", balanceInOldVault, "USDC");
        console.log("New vault collateral value:");
        uint256 collateralValue = newVault.getAccountCollateralValueX18(user);
        console.log("  ", collateralValue, "(1e18 format)");
        console.log("");
    }
}
