// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";

/**
 * @title SetRiskParamsETHPerpV2
 * @notice Sets risk parameters for ETH-PERP-V2 market
 */
contract SetRiskParamsETHPerpV2 is Script {
    address constant CLEARING_HOUSE = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;
    bytes32 constant ETH_PERP_V2 = 0x923fe13dd90eff0f2f8b82db89ef27daef5f899aca7fba59ebb0b01a6343bfb5;

    // Risk Parameters
    uint256 constant IMR_BPS = 1000;  // 10% Initial Margin Requirement
    uint256 constant MMR_BPS = 500;   // 5% Maintenance Margin Requirement
    uint256 constant LIQ_PENALTY_BPS = 250; // 2.5% Liquidation Penalty
    uint256 constant PENALTY_CAP = 1000 * 1e18; // $1000 cap in 1e18
    uint256 constant MAX_POSITION_SIZE = 0; // 0 = unlimited
    uint256 constant MIN_POSITION_SIZE = 0; // 0 = no minimum

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  SET RISK PARAMS FOR ETH-PERP-V2");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("ClearingHouse:", CLEARING_HOUSE);
        console.log("Market ID:", vm.toString(ETH_PERP_V2));
        console.log("");
        console.log("Parameters:");
        console.log("  IMR:", IMR_BPS, "bps (10%)");
        console.log("  MMR:", MMR_BPS, "bps (5%)");
        console.log("  Liquidation Penalty:", LIQ_PENALTY_BPS, "bps (2.5%)");
        console.log("  Penalty Cap: $1000");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        ClearingHouse(CLEARING_HOUSE).setRiskParams(
            ETH_PERP_V2,
            IMR_BPS,
            MMR_BPS,
            LIQ_PENALTY_BPS,
            PENALTY_CAP,
            MAX_POSITION_SIZE,
            MIN_POSITION_SIZE
        );

        console.log("Risk parameters set!");

        vm.stopBroadcast();

        console.log("");
        console.log("=========================================");
        console.log("  COMPLETE");
        console.log("=========================================");
    }
}
