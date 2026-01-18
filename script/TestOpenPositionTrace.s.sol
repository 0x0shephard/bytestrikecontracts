// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/ClearingHouse.sol";

contract TestOpenPositionTrace is Script {
    address constant CLEARING_HOUSE = 0x18F863b1b0A3Eca6B2235dc1957291E357f490B0;
    bytes32 constant HYPERSCALERS = 0xf4aa47cc83b0d01511ca8025a996421dda6fbab1764466da4b0de6408d3db2e2;
    address constant USER = 0xCc624fFA5df1F3F4b30aa8abd30186a86254F406;

    function run() external {
        console.log("=== Testing Position Opening with Trace ===\n");

        vm.startPrank(USER);

        ClearingHouse ch = ClearingHouse(CLEARING_HOUSE);

        console.log("Attempting to open position...");
        console.log("Market ID:", vm.toString(HYPERSCALERS));
        console.log("User:", USER);
        console.log("Size: 0.1 GPU-hours");
        console.log("");

        try ch.openPosition(
            HYPERSCALERS,
            true,  // isLong
            100000000000000000, // 0.1 GPU-hours
            0  // no price limit
        ) {
            console.log("SUCCESS! Position opened!");
        } catch Error(string memory reason) {
            console.log("FAILED with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("FAILED with low-level error");
            console.logBytes(lowLevelData);
        }

        vm.stopPrank();
    }
}
