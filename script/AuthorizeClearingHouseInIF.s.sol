// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IInsuranceFund} from "../src/Interfaces/IInsuranceFund.sol";

/**
 * @title AuthorizeClearingHouseInIF
 * @notice Authorizes ClearingHouse to request payouts from InsuranceFund
 */
contract AuthorizeClearingHouseInIF is Script {
    address constant INSURANCE_FUND = 0x3C1085dF918a38A95F84945E6705CC857b664074;
    address constant CLEARING_HOUSE = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  AUTHORIZE CLEARINGHOUSE IN IF");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("InsuranceFund:", INSURANCE_FUND);
        console.log("ClearingHouse:", CLEARING_HOUSE);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        IInsuranceFund(INSURANCE_FUND).setAuthorized(CLEARING_HOUSE, true);
        console.log("ClearingHouse authorized!");

        vm.stopBroadcast();

        console.log("");
        console.log("=========================================");
        console.log("  AUTHORIZATION COMPLETE");
        console.log("=========================================");
    }
}
