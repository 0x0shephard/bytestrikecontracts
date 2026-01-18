// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";

/**
 * @title UpgradeClearingHouseV2
 * @notice Upgrades ClearingHouse with decimal conversion fix for fees
 * @dev Fixes fee/penalty conversion from 1e18 to quote token decimals
 */
contract UpgradeClearingHouseV2 is Script {
    address constant CLEARING_HOUSE_PROXY = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  CLEARINGHOUSE UPGRADE V2");
        console.log("  Fix: Decimal conversion for fees");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Proxy:", CLEARING_HOUSE_PROXY);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy new implementation
        console.log("Deploying new ClearingHouse implementation...");
        ClearingHouse newImpl = new ClearingHouse();
        console.log("New Implementation:", address(newImpl));
        console.log("");

        // Upgrade
        console.log("Upgrading proxy...");
        ClearingHouse proxy = ClearingHouse(CLEARING_HOUSE_PROXY);
        proxy.upgradeToAndCall(address(newImpl), "");
        console.log("Upgrade complete!");
        console.log("");

        vm.stopBroadcast();

        console.log("=========================================");
        console.log("  UPGRADE SUCCESSFUL");
        console.log("=========================================");
        console.log("");
        console.log("Changes:");
        console.log("  - Fees now converted from 1e18 to quote decimals");
        console.log("  - USDC fees: 1e18 -> 1e6 (divide by 1e12)");
        console.log("  - Insurance fund payouts use correct decimals");
        console.log("");
        console.log("Proxy:", CLEARING_HOUSE_PROXY);
        console.log("New Implementation:", address(newImpl));
    }
}
