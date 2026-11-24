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

    function getPrice(string memory) external pure override returns (uint256) {
        return ETH_PRICE;
    }
}

interface IVAMM {
    function oracle() external view returns (address);
}

interface IMarketRegistryOracle {
    function setOracle(bytes32 marketId, address newOracle) external;
}

contract DeploySimpleETHOracle is Script {
    address constant VAMM = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;
    address constant MARKET_REGISTRY = 0x937F40013B088832919992E0Bd0D0F48520dC964;
    bytes32 constant MARKET_ID = keccak256("ETH-PERP-V2");

    function run() external {
        address deployer = msg.sender;

        console.log("=========================================");
        console.log("  DEPLOY SIMPLE ETH ORACLE");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("ETH Price: $3.79");
        console.log("");

        vm.startBroadcast();

        // Deploy oracle
        console.log("Step 1: Deploying SimpleETHOracle...");
        SimpleETHOracle oracle = new SimpleETHOracle();
        console.log("  Oracle deployed:", address(oracle));

        // Test it
        uint256 price = oracle.getPrice();
        console.log("  Oracle price:", price);

        // Move the market's oracle (risk and vAMM funding)
        console.log("");
        console.log("Step 2: Setting market oracle...");
        IMarketRegistryOracle(MARKET_REGISTRY).setOracle(MARKET_ID, address(oracle));
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
