// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IOracle} from "../src/Interfaces/IOracle.sol";

/**
 * @title SimpleETHOracle
 * @notice Simple oracle that returns fixed ETH price of $3.79
 */
contract SimpleETHOracle is IOracle {
    uint256 public constant ETH_PRICE = 3_790_000_000_000_000_000; // $3.79

    function getPrice() external pure override returns (uint256) {
        return ETH_PRICE;
    }
}

interface IVAMM {
    function setOracle(address oracle) external;
    function oracle() external view returns (address);
}

contract DeploySimpleETHOracle is Script {
    address constant VAMM = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  DEPLOY SIMPLE ETH ORACLE");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("ETH Price: $3.79");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy oracle
        console.log("Step 1: Deploying SimpleETHOracle...");
        SimpleETHOracle oracle = new SimpleETHOracle();
        console.log("  Oracle deployed:", address(oracle));

        // Test it
        uint256 price = oracle.getPrice();
        console.log("  Oracle price:", price);

        // Set vAMM oracle
        console.log("");
        console.log("Step 2: Setting vAMM oracle...");
        IVAMM(VAMM).setOracle(address(oracle));
        console.log("  Oracle set!");

        vm.stopBroadcast();

        // Verification
        address vammOracle = IVAMM(VAMM).oracle();

        console.log("");
        console.log("=========================================");
        console.log("  VERIFICATION");
        console.log("=========================================");
        console.log("  Oracle Address:", address(oracle));
        console.log("  vAMM Oracle:", vammOracle);
        console.log("  Match:", vammOracle == address(oracle));
        console.log("  Price:", price, "($3.79)");
        console.log("");
        console.log("=========================================");
        console.log("  COMPLETE");
        console.log("=========================================");
    }
}
