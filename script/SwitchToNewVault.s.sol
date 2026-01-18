// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";

/**
 * @title SwitchToNewVault
 * @notice Switches ClearingHouse to point to new vault
 *
 * Run with:
 * forge script script/SwitchToNewVault.s.sol:SwitchToNewVault --rpc-url sepolia --broadcast -vvv
 */
contract SwitchToNewVault is Script {
    address constant CLEARING_HOUSE_PROXY = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;
    address constant NEW_VAULT = 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("Switching ClearingHouse to new vault...");
        console.log("ClearingHouse:", CLEARING_HOUSE_PROXY);
        console.log("New Vault:", NEW_VAULT);

        vm.startBroadcast(deployerPrivateKey);

        ClearingHouse(CLEARING_HOUSE_PROXY).setVault(NEW_VAULT);

        vm.stopBroadcast();

        console.log("Done! ClearingHouse now points to new vault");
        console.log("Frontend should show $0 collateral (clean slate)");
    }
}
