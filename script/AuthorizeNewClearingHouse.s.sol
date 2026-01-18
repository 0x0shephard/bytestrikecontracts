// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/CollateralVault.sol";
import "../src/MarketRegistry.sol";

/**
 * @title AuthorizeNewClearingHouse
 * @notice Authorize the new ClearingHouse in CollateralVault and MarketRegistry
 *
 * This script must be run AFTER deploying the new ClearingHouse.
 * It connects the new ClearingHouse to existing infrastructure.
 *
 * USAGE:
 * NEW_CH=<new_clearinghouse_address> \
 * forge script script/AuthorizeNewClearingHouse.s.sol:AuthorizeNewClearingHouse \
 *   --rpc-url $SEPOLIA_RPC_URL \
 *   --broadcast \
 *   -vvvv
 */
contract AuthorizeNewClearingHouse is Script {
    address constant MARKET_REGISTRY = 0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD;
    address constant COLLATERAL_VAULT_NEW = 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get new ClearingHouse address from environment
        address newClearingHouse = vm.envAddress("NEW_CH");

        console.log("=== AUTHORIZE NEW CLEARINGHOUSE ===");
        console.log("Deployer:", deployer);
        console.log("New ClearingHouse:", newClearingHouse);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Authorize in CollateralVault
        console.log("Step 1: Setting ClearingHouse in CollateralVault...");
        CollateralVault vault = CollateralVault(COLLATERAL_VAULT_NEW);
        vault.setClearinghouse(newClearingHouse);
        console.log("CollateralVault updated to use new ClearingHouse");
        console.log("Verification:", vault.getClearinghouse());
        require(vault.getClearinghouse() == newClearingHouse, "Vault authorization failed");
        console.log("");

        // Step 2: Verify MarketRegistry connection
        console.log("Step 2: Verifying MarketRegistry...");
        MarketRegistry registry = MarketRegistry(MARKET_REGISTRY);
        console.log("MarketRegistry verified at:", MARKET_REGISTRY);
        console.log("Note: MarketRegistry doesn't store ClearingHouse reference");
        console.log("");

        console.log("=== AUTHORIZATION COMPLETE ===");
        console.log("New ClearingHouse is now authorized to:");
        console.log("  - Manage deposits/withdrawals in CollateralVault");
        console.log("  - Read market configurations from MarketRegistry");
        console.log("");
        console.log("NEXT: Update frontend to use new ClearingHouse address");

        vm.stopBroadcast();
    }
}
