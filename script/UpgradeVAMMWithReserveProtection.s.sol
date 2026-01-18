// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {vAMM} from "../src/vAMM.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title Upgrade vAMM with Reserve Protection
/// @notice Upgrades the vAMM implementation to add minimum reserve protection
contract UpgradeVAMMWithReserveProtection is Script {

    // Existing proxy address
    address constant VAMM_PROXY = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;

    // Minimum reserves to prevent depletion (10% of current target)
    uint256 constant MIN_RESERVE_BASE = 10_000_000e18;  // 10M GPU-HRS minimum
    uint256 constant MIN_RESERVE_QUOTE = 37_900_000e18; // 37.9M USDC minimum (at $3.79 price)

    // New reserves to reset to (10x larger than before)
    uint256 constant NEW_PRICE_X18 = 3_79e16; // $3.79
    uint256 constant NEW_BASE_RESERVE = 1_000_000_000e18; // 1 billion GPU-HRS

    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPrivateKey == 0) {
            deployerPrivateKey = 0x7857dfba6a2faf4f52f5e7b28a28d5a66be4bdf588437d03d5fd5d8522cf8348;
        }

        console.log("=================================");
        console.log("Upgrading vAMM with Reserve Protection");
        console.log("=================================");
        console.log("Proxy Address:", VAMM_PROXY);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy new implementation
        console.log("Deploying new vAMM implementation...");
        vAMM newImpl = new vAMM();
        console.log("New Implementation:", address(newImpl));

        // Upgrade the proxy
        console.log("");
        console.log("Upgrading proxy to new implementation...");
        vAMM proxy = vAMM(VAMM_PROXY);
        proxy.upgradeToAndCall(address(newImpl), "");
        console.log("Proxy upgraded successfully!");

        // Set minimum reserves
        console.log("");
        console.log("Setting minimum reserves...");
        console.log("  Min Base Reserve:", MIN_RESERVE_BASE / 1e18, "GPU-HRS");
        console.log("  Min Quote Reserve:", MIN_RESERVE_QUOTE / 1e18, "USDC");
        proxy.setMinReserves(MIN_RESERVE_BASE, MIN_RESERVE_QUOTE);
        console.log("Minimum reserves set!");

        // Reset reserves to rescue from depleted state
        console.log("");
        console.log("Resetting reserves to rescue vAMM...");
        console.log("  New Price: $3.79");
        console.log("  New Base Reserve:", NEW_BASE_RESERVE / 1e18, "GPU-HRS");
        uint256 newQuoteReserve = (NEW_BASE_RESERVE * NEW_PRICE_X18) / 1e18;
        console.log("  New Quote Reserve:", newQuoteReserve / 1e18, "USDC");

        proxy.resetReserves(NEW_PRICE_X18, NEW_BASE_RESERVE);
        console.log("Reserves reset successfully!");

        // Verify the upgrade
        console.log("");
        console.log("Verifying upgrade...");
        (uint256 baseReserve, uint256 quoteReserve) = proxy.getReserves();
        console.log("  Current Base Reserve:", baseReserve / 1e18);
        console.log("  Current Quote Reserve:", quoteReserve / 1e18);

        uint256 markPrice = proxy.getMarkPrice();
        console.log("  Current Mark Price: $", markPrice / 1e16, ".", (markPrice % 1e16) / 1e14);

        vm.stopBroadcast();

        console.log("");
        console.log("=================================");
        console.log("Upgrade Complete!");
        console.log("=================================");
        console.log("vAMM is now protected against reserve depletion");
        console.log("Positions can now be closed properly");
    }
}
