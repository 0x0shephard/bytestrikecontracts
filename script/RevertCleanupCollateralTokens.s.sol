// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";

/**
 * @title RevertCleanupCollateralTokens
 * @notice Re-enable the two tokens that were disabled by CleanupCollateralTokens.s.sol
 *
 * This script reverts the changes made by CleanupCollateralTokens.s.sol by:
 * - Re-enabling 0x37D5154731eE25C83E06E1abC312075AB4B4D8fF
 * - Re-enabling 0x71075745A2A63dff3BD4819e9639D0E412c14AA9
 *
 * Run with:
 * forge script script/RevertCleanupCollateralTokens.s.sol:RevertCleanupCollateralTokens --rpc-url sepolia --broadcast -vvvv
 */
contract RevertCleanupCollateralTokens is Script {
    // Deployed contract
    address constant COLLATERAL_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;

    // Tokens to re-enable
    address constant OLD_TOKEN_0 = 0x37D5154731eE25C83E06E1abC312075AB4B4D8fF;
    address constant OLD_MUSDC = 0x71075745A2A63dff3BD4819e9639D0E412c14AA9;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  REVERT CLEANUP - RE-ENABLE TOKENS");
        console.log("=========================================");
        console.log("");
        console.log("Admin:", deployer);
        console.log("Vault:", COLLATERAL_VAULT);
        console.log("");

        CollateralVault vault = CollateralVault(COLLATERAL_VAULT);

        // Check current state
        console.log("STEP 1: Checking current state...");
        console.log("");

        for (uint256 i = 0; i < 10; i++) {
            try vault.registeredTokens(i) returns (address token) {
                ICollateralVault.CollateralConfig memory config = vault.getConfig(token);
                console.log("  Index", i, ":", token);
                console.log("    Enabled:", config.enabled);
                console.log("");
            } catch {
                console.log("  (No more tokens after index", i, ")");
                break;
            }
        }

        vm.startBroadcast(deployerPrivateKey);

        console.log("STEP 2: Re-enabling previously disabled tokens...");
        console.log("");

        // Re-enable old token 0
        _enableToken(vault, OLD_TOKEN_0, "Old Token 0");

        // Re-enable old mUSDC
        _enableToken(vault, OLD_MUSDC, "Old mUSDC");

        vm.stopBroadcast();

        console.log("");
        console.log("STEP 3: Verifying revert...");
        console.log("");

        // Verify state after revert
        uint256 enabledCount = 0;
        for (uint256 i = 0; i < 10; i++) {
            try vault.registeredTokens(i) returns (address token) {
                ICollateralVault.CollateralConfig memory config = vault.getConfig(token);
                if (config.enabled) {
                    enabledCount++;
                    console.log("  Enabled Token:", token);
                    console.log("    Oracle Symbol:", config.oracleSymbol);
                }
            } catch {
                break;
            }
        }

        console.log("");
        console.log("Total enabled tokens:", enabledCount);
        console.log("");
        console.log("=========================================");
        console.log("  REVERT COMPLETE");
        console.log("=========================================");
    }

    function _enableToken(CollateralVault vault, address token, string memory name) internal {
        console.log("Re-enabling:", name, "at", token);

        // Get current config
        ICollateralVault.CollateralConfig memory config = vault.getConfig(token);

        if (config.enabled) {
            console.log("  Already enabled, skipping");
            console.log("");
            return;
        }

        // Set enabled = true, keep other params
        config.enabled = true;

        vault.setCollateralParams(token, config);

        console.log("  Re-enabled successfully");
        console.log("");
    }
}
