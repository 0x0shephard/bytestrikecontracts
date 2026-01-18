// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";

/**
 * @title RevertToOldVault
 * @notice Reverts ClearingHouse to point back to old vault
 *
 * Run with:
 * forge script script/RevertToOldVault.s.sol:RevertToOldVault --rpc-url sepolia --broadcast -vvv
 */
contract RevertToOldVault is Script {
    address constant CLEARING_HOUSE_PROXY = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;
    address constant OLD_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("Reverting ClearingHouse to old vault...");
        console.log("ClearingHouse:", CLEARING_HOUSE_PROXY);
        console.log("Old Vault:", OLD_VAULT);

        vm.startBroadcast(deployerPrivateKey);

        ClearingHouse(CLEARING_HOUSE_PROXY).setVault(OLD_VAULT);

        vm.stopBroadcast();

        console.log("Done! ClearingHouse now points to old vault");
    }
}
