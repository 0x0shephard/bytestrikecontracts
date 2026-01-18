// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";

/**
 * @title CleanupCollateralTokens
 * @notice Disable duplicate/old mUSDC registrations, keep only the correct one
 *
 * Problem: CollateralVault has 4 registered tokens:
 * - 0x37D5154731eE25C83E06E1abC312075AB4B4D8fF (unknown/old)
 * - 0x71075745A2A63dff3BD4819e9639D0E412c14AA9 (old mUSDC)
 * - 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7 (correct mUSDC) ✅
 * - 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7 (duplicate)
 *
 * Solution: Disable all except the correct mUSDC at 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7
 *
 * Run with:
 * forge script script/CleanupCollateralTokens.s.sol:CleanupCollateralTokens --rpc-url sepolia --broadcast -vvvv
 */
contract CleanupCollateralTokens is Script {
    // Deployed contract
    address constant COLLATERAL_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;

    // The ONLY token we want to keep enabled
    address constant CORRECT_MUSDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;

    // Tokens to disable (found via registeredTokens array)
    address constant OLD_TOKEN_0 = 0x37D5154731eE25C83E06E1abC312075AB4B4D8fF;
    address constant OLD_MUSDC = 0x71075745A2A63dff3BD4819e9639D0E412c14AA9;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  CLEANUP COLLATERAL VAULT TOKENS");
        console.log("=========================================");
        console.log("");
        console.log("Admin:", deployer);
        console.log("Vault:", COLLATERAL_VAULT);
        console.log("");

        CollateralVault vault = CollateralVault(COLLATERAL_VAULT);

        // Check current state
        console.log("STEP 1: Checking current registered tokens...");
        console.log("");

        for (uint256 i = 0; i < 10; i++) {
            try vault.registeredTokens(i) returns (address token) {
                ICollateralVault.CollateralConfig memory config = vault.getConfig(token);
                console.log("  Index", i, ":", token);
                console.log("    Enabled:", config.enabled);
                console.log("    Oracle Symbol:", config.oracleSymbol);
                console.log("    Base Unit:", config.baseUnit);
                console.log("");
            } catch {
                console.log("  (No more tokens after index", i, ")");
                break;
            }
        }

        vm.startBroadcast(deployerPrivateKey);

        console.log("STEP 2: Disabling old/duplicate tokens...");
        console.log("");

        // Disable old token 0
        _disableToken(vault, OLD_TOKEN_0, "Old Token 0");

        // Disable old mUSDC
        _disableToken(vault, OLD_MUSDC, "Old mUSDC");

        // Ensure correct mUSDC is enabled (in case it was disabled)
        _ensureCorrectTokenEnabled(vault);

        vm.stopBroadcast();

        console.log("");
        console.log("STEP 3: Verifying cleanup...");
        console.log("");

        // Verify state after cleanup
        uint256 enabledCount = 0;
        for (uint256 i = 0; i < 10; i++) {
            try vault.registeredTokens(i) returns (address token) {
                ICollateralVault.CollateralConfig memory config = vault.getConfig(token);
                if (config.enabled) {
                    enabledCount++;
                    console.log("  Enabled Token:", token);
                    console.log("    Oracle Symbol:", config.oracleSymbol);
                    console.log("    Base Unit:", config.baseUnit);
                }
            } catch {
                break;
            }
        }

        console.log("");
        console.log("Total enabled tokens:", enabledCount);

        if (enabledCount == 1) {
            console.log("");
            console.log("SUCCESS: Only 1 token enabled (correct mUSDC)!");
        } else {
            console.log("");
            console.log("WARNING: Expected 1 enabled token, found", enabledCount);
        }

        console.log("");
        console.log("=========================================");
        console.log("  CLEANUP COMPLETE");
        console.log("=========================================");
    }

    function _disableToken(CollateralVault vault, address token, string memory name) internal {
        console.log("Disabling:", name, "at", token);

        // Get current config
        ICollateralVault.CollateralConfig memory config = vault.getConfig(token);

        if (!config.enabled) {
            console.log("  Already disabled, skipping");
            console.log("");
            return;
        }

        // Set enabled = false, keep other params
        config.enabled = false;

        vault.setCollateralParams(token, config);

        console.log("  Disabled successfully");
        console.log("");
    }

    function _ensureCorrectTokenEnabled(CollateralVault vault) internal {
        console.log("Ensuring correct mUSDC is enabled:", CORRECT_MUSDC);

        ICollateralVault.CollateralConfig memory config = vault.getConfig(CORRECT_MUSDC);

        if (config.enabled) {
            console.log("  Already enabled");
            console.log("");
            return;
        }

        // Enable it
        config.enabled = true;

        vault.setCollateralParams(CORRECT_MUSDC, config);

        console.log("  Enabled successfully");
        console.log("");
    }
}
