// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {FeeRouter} from "../src/FeeRouter.sol";

/**
 * @title UpdateFeeRouterCH
 * @notice Updates FeeRouter to point to correct ClearingHouse
 */
contract UpdateFeeRouterCH is Script {
    address constant FEE_ROUTER = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F;
    address constant CLEARING_HOUSE = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  UPDATE FEE ROUTER CLEARINGHOUSE");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("FeeRouter:", FEE_ROUTER);
        console.log("New ClearingHouse:", CLEARING_HOUSE);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        FeeRouter(FEE_ROUTER).setClearinghouse(CLEARING_HOUSE);
        console.log("ClearingHouse updated!");

        vm.stopBroadcast();

        console.log("");
        console.log("=========================================");
        console.log("  UPDATE COMPLETE");
        console.log("=========================================");
    }
}
