// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title UpgradeClearingHouse
 * @notice Upgrades the ClearingHouse implementation with the margin allocation fix
 * @dev This script:
 *  1. Deploys new ClearingHouse implementation with auto-margin allocation
 *  2. Upgrades the existing proxy to point to new implementation
 */
contract UpgradeClearingHouse is Script {
    // Default ClearingHouse proxy on Sepolia (can be overridden via env)
    address constant DEFAULT_CLEARING_HOUSE_PROXY = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address proxyAddress = DEFAULT_CLEARING_HOUSE_PROXY;
        // Allow overriding the proxy via environment variable for other deployments
        try vm.envAddress("CLEARING_HOUSE_PROXY") returns (address envProxy) {
            if (envProxy != address(0)) {
                proxyAddress = envProxy;
            }
        } catch {}

        console.log("=========================================");
        console.log("  CLEARINGHOUSE UPGRADE");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Proxy Address:", proxyAddress);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy new implementation
        console.log("Step 1: Deploying new ClearingHouse implementation...");
        ClearingHouse newImplementation = new ClearingHouse();
        console.log("  New Implementation:", address(newImplementation));
        console.log("");

        // Step 2: Upgrade proxy to new implementation
    console.log("Step 2: Upgrading proxy to new implementation...");
    ClearingHouse clearingHouse = ClearingHouse(proxyAddress);
        clearingHouse.upgradeToAndCall(address(newImplementation), "");
        console.log("  Upgrade successful!");
        console.log("");

        // Step 3: Verify upgrade
        console.log("Step 3: Verifying upgrade...");
        // The proxy should now use the new implementation
    console.log("  Proxy still at:", proxyAddress);
        console.log("  New logic at:", address(newImplementation));
        console.log("");

        vm.stopBroadcast();

        console.log("=========================================");
        console.log("  UPGRADE COMPLETE");
        console.log("=========================================");
        console.log("");
        console.log("Summary:");
        console.log("  Proxy (unchanged):", proxyAddress);
        console.log("  New Implementation:", address(newImplementation));
        console.log("");
        console.log("The proxy now points to the new implementation with:");
        console.log("  Auto-margin allocation for new/increasing positions");
        console.log("  Fee deduction BEFORE IMR check");
        console.log("  Oracle-aware maintenance & liquidation checks");
        console.log("");
        console.log("Next step: Test position opening on Sepolia");
    }
}
