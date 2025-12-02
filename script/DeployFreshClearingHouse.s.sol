// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import "../src/ClearingHouse.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployFreshClearingHouse
 * @notice Deploy a completely new ClearingHouse proxy + implementation with clean state
 *
 * OPTION C: FRESH START (RECOMMENDED FOR CLEAN SLATE)
 *
 * WHY THIS APPROACH:
 * - No stale storage (no stuck _totalReservedMargin)
 * - No ghost positions
 * - Clean state from day 1 with new vault
 * - Users start fresh (must deposit collateral again)
 * - Old ClearingHouse remains for historical reference
 *
 * TRADE-OFFS:
 * ✅ Pro: Clean state, no legacy issues
 * ✅ Pro: No need for emergency admin functions
 * ✅ Pro: Better for testnet environments
 * ❌ Con: Users must redeposit collateral
 * ❌ Con: Historical positions not accessible from new contract
 * ❌ Con: Need to update all frontend references
 *
 * USAGE:
 * forge script script/DeployFreshClearingHouse.s.sol:DeployFreshClearingHouse \
 *   --rpc-url $SEPOLIA_RPC_URL \
 *   --broadcast \
 *   --verify \
 *   -vvvv
 */
contract DeployFreshClearingHouse is Script {
    // Existing contracts (will remain unchanged)
    address constant MARKET_REGISTRY = 0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD;
    address constant COLLATERAL_VAULT_NEW = 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2; // Clean vault
    address constant INSURANCE_FUND = 0x3C1085dF918a38A95F84945E6705CC857b664074;
    address constant FEE_ROUTER = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F;

    // Market IDs
    bytes32 constant H100_PERP_MARKET = 0x2bc0c3f3ef82289c7da8a9335c83ea4f2b5b8bd62b67c4f4e0dba00b304c2937;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== DEPLOY FRESH CLEARINGHOUSE (OPTION C) ===");
        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy new ClearingHouse implementation
        console.log("Step 1: Deploying ClearingHouse implementation...");
        ClearingHouse clearingHouseImpl = new ClearingHouse();
        console.log("Implementation deployed at:", address(clearingHouseImpl));
        console.log("");

        // Step 2: Deploy proxy pointing to new implementation
        console.log("Step 2: Deploying ERC1967 Proxy...");
        bytes memory initData = abi.encodeWithSelector(
            ClearingHouse.initialize.selector,
            COLLATERAL_VAULT_NEW,  // Use the new clean vault
            MARKET_REGISTRY,       // Existing market registry
            deployer               // Admin
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(clearingHouseImpl), initData);
        console.log("Proxy deployed at:", address(proxy));
        console.log("");

        // Get reference to ClearingHouse through proxy
        ClearingHouse ch = ClearingHouse(address(proxy));

        // Step 3: Configure H100-PERP market risk params
        console.log("Step 3: Setting H100-PERP risk parameters...");
        ch.setRiskParams(
            H100_PERP_MARKET,
            1000,  // 10% IMR (Initial Margin Requirement)
            500,   // 5% MMR (Maintenance Margin Requirement)
            250,   // 2.5% Liquidation Penalty
            1000 * 1e18  // $1000 penalty cap
        );
        console.log("Risk params set for H100-PERP");
        console.log("");

        // Step 4: Verify deployment
        console.log("Step 4: Verifying deployment...");
        require(ch.vault() == COLLATERAL_VAULT_NEW, "Vault mismatch");
        require(ch.marketRegistry() == MARKET_REGISTRY, "Registry mismatch");
        require(ch.hasRole(ch.DEFAULT_ADMIN_ROLE(), deployer), "Admin not set");
        console.log("Verification passed!");
        console.log("");

        // Step 5: Check that new contract has clean state
        console.log("Step 5: Verifying clean state...");
        address testUser = 0xCc624fFA5df1F3F4b30aa8abd30186a86254F406;
        uint256 reservedMargin = ch._totalReservedMargin(testUser);
        int256 accountValue = ch.getAccountValue(testUser);

        console.log("Test User:", testUser);
        console.log("Reserved Margin:", reservedMargin, "(should be 0)");
        console.log("Account Value:", uint256(accountValue >= 0 ? accountValue : -accountValue), "(should be 0)");

        require(reservedMargin == 0, "Reserved margin should be 0 in fresh contract");
        require(accountValue == 0, "Account value should be 0 in fresh contract");
        console.log("Clean state confirmed!");
        console.log("");

        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("New ClearingHouse Proxy:", address(proxy));
        console.log("New ClearingHouse Implementation:", address(clearingHouseImpl));
        console.log("Connected to Vault:", COLLATERAL_VAULT_NEW);
        console.log("Connected to MarketRegistry:", MARKET_REGISTRY);
        console.log("");
        console.log("=== NEXT STEPS ===");
        console.log("1. Update MarketRegistry to authorize new ClearingHouse:");
        console.log("   - Call setClearinghouse() on MarketRegistry");
        console.log("");
        console.log("2. Update CollateralVault to authorize new ClearingHouse:");
        console.log("   - Call setClearinghouse() on CollateralVault");
        console.log("");
        console.log("3. Update frontend addresses.js:");
        console.log("   clearingHouse: '", address(proxy), "'");
        console.log("   clearingHouseImpl: '", address(clearingHouseImpl), "'");
        console.log("");
        console.log("4. Regenerate and update ABI:");
        console.log("   cp out/ClearingHouse.sol/ClearingHouse.json \\");
        console.log("      bytestrike3/src/contracts/abis/ClearingHouse.json");
        console.log("");
        console.log("5. Users must deposit collateral to start trading");
        console.log("");
        console.log("=== OLD CLEARINGHOUSE ===");
        console.log("Old ClearingHouse Proxy: 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6");
        console.log("Status: Deprecated (historical reference only)");
        console.log("Note: Users cannot interact with old contract after frontend update");

        vm.stopBroadcast();
    }
}
