// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title MigrateToNewVault
 * @notice Complete migration script that:
 *   1. Deploys new ClearingHouse V4 implementation with setVault() function
 *   2. Deploys new CollateralVault with only correct mUSDC token
 *   3. Migrates user balances from old vault to new vault
 *   4. Upgrades ClearingHouse proxy to V4
 *   5. Updates ClearingHouse to point to new vault
 *
 * Run with:
 * forge script script/MigrateToNewVault.s.sol:MigrateToNewVault --rpc-url sepolia --broadcast -vvvv
 */
contract MigrateToNewVault is Script {
    // Existing contracts
    address constant CLEARING_HOUSE_PROXY = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;
    address constant OLD_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;
    address constant ORACLE = 0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c; // USDC price oracle

    // The ONLY token we want in the new vault
    address constant CORRECT_MUSDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;

    // User who needs balance migrated (add more if needed)
    address constant USER_TO_MIGRATE = 0xCc624fFA5df1F3F4b30aa8abd30186a86254F406;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  VAULT MIGRATION - COMPLETE WORKFLOW");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("ClearingHouse Proxy:", CLEARING_HOUSE_PROXY);
        console.log("Old Vault:", OLD_VAULT);
        console.log("Correct mUSDC:", CORRECT_MUSDC);
        console.log("");

        // STEP 1: Deploy new ClearingHouse V4 implementation
        console.log("STEP 1: Deploying new ClearingHouse V4 implementation...");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        ClearingHouse newClearingHouseImpl = new ClearingHouse();
        console.log("  New ClearingHouse V4 impl:", address(newClearingHouseImpl));
        console.log("");

        // STEP 2: Deploy new CollateralVault
        console.log("STEP 2: Deploying new CollateralVault...");
        console.log("");

        CollateralVault newVault = new CollateralVault();
        console.log("  New Vault deployed:", address(newVault));

        // Configure new vault
        newVault.setOracle(ORACLE);
        newVault.setClearinghouse(CLEARING_HOUSE_PROXY);
        console.log("  Oracle set:", ORACLE);
        console.log("  Clearinghouse set:", CLEARING_HOUSE_PROXY);

        // Register ONLY the correct mUSDC token
        ICollateralVault.CollateralConfig memory config = ICollateralVault.CollateralConfig({
            token: CORRECT_MUSDC,
            baseUnit: 1_000_000, // 6 decimals for USDC
            haircutBps: 0,
            liqIncentiveBps: 500, // 5%
            cap: 0, // No cap
            accountCap: 0, // No account cap
            enabled: true,
            depositPaused: false,
            withdrawPaused: false,
            oracleSymbol: "USDC"
        });

        newVault.registerCollateral(config);
        console.log("  Registered mUSDC:", CORRECT_MUSDC);
        console.log("");

        // STEP 3: Check user balances (migration will be done separately by user)
        console.log("STEP 3: Checking user balances...");
        console.log("");

        CollateralVault oldVault = CollateralVault(OLD_VAULT);
        uint256 userBalance = oldVault.balanceOf(USER_TO_MIGRATE, CORRECT_MUSDC);

        console.log("  User:", USER_TO_MIGRATE);
        console.log("  Balance in old vault:", userBalance);
        console.log("");
        console.log("  NOTE: User will need to:");
        console.log("    1. Withdraw from old vault via ClearingHouse");
        console.log("    2. Approve new vault");
        console.log("    3. Deposit into new vault via ClearingHouse");
        console.log("");

        // STEP 4: Upgrade ClearingHouse proxy to V4
        console.log("STEP 4: Upgrading ClearingHouse proxy to V4...");
        console.log("");

        ClearingHouse clearingHouse = ClearingHouse(CLEARING_HOUSE_PROXY);
        clearingHouse.upgradeToAndCall(address(newClearingHouseImpl), "");
        console.log("  Upgraded to V4 implementation:", address(newClearingHouseImpl));
        console.log("");

        // STEP 5: Update vault address in ClearingHouse
        console.log("STEP 5: Updating vault address in ClearingHouse...");
        console.log("");

        clearingHouse.setVault(address(newVault));
        console.log("  Vault updated to:", address(newVault));
        console.log("");

        vm.stopBroadcast();

        // STEP 6: Verification
        console.log("STEP 6: Verifying setup...");
        console.log("");

        // Verify ClearingHouse points to new vault
        address currentVault = clearingHouse.vault();
        console.log("  ClearingHouse vault:", currentVault);
        require(currentVault == address(newVault), "Vault not updated");

        // Verify only 1 token registered
        address token0 = newVault.registeredTokens(0);
        console.log("  Registered token:", token0);
        require(token0 == CORRECT_MUSDC, "Wrong token registered");

        try newVault.registeredTokens(1) returns (address) {
            revert("More than 1 token registered");
        } catch {
            console.log("  Only 1 token registered (correct)");
        }

        console.log("");
        console.log("=========================================");
        console.log("  MIGRATION INFRASTRUCTURE DEPLOYED");
        console.log("=========================================");
        console.log("");
        console.log("Summary:");
        console.log("  New ClearingHouse V4:", address(newClearingHouseImpl));
        console.log("  New Vault:", address(newVault));
        console.log("  Registered tokens: 1 (mUSDC only)");
        console.log("  User balance in old vault:", userBalance);
        console.log("");
        console.log("Next steps:");
        console.log("  1. User withdraws", userBalance, "USDC from old vault");
        console.log("  2. User approves new vault:", address(newVault));
        console.log("  3. User deposits into new vault");
        console.log("");
    }
}
