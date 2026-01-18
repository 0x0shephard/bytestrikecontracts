// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {UpdatableETHOracle} from "../src/Oracle/UpdatableETHOracle.sol";

interface IVAMM {
    function setOracle(address oracle) external;
    function oracle() external view returns (address);
}

contract DeployUpdatableETHOracle is Script {
    address constant VAMM = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5;
    uint256 constant INITIAL_PRICE = 3_790_000_000_000_000_000; // $3.79

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  DEPLOY UPDATABLE ETH ORACLE");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Initial ETH Price: $3.79");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy oracle
        console.log("Step 1: Deploying UpdatableETHOracle...");
        UpdatableETHOracle oracle = new UpdatableETHOracle(INITIAL_PRICE);
        console.log("  Oracle deployed:", address(oracle));

        // Test it
        uint256 price = oracle.getPrice();
        console.log("  Oracle price:", price);
        console.log("  Owner:", oracle.owner());

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
        console.log("  Owner:", oracle.owner());
        console.log("");
        console.log("=========================================");
        console.log("  COMPLETE");
        console.log("=========================================");
        console.log("");
        console.log("To update price:");
        console.log("  cast send", address(oracle));
        console.log("    'updatePrice(uint256)' <NEW_PRICE_IN_WEI>");
        console.log("    --private-key $PRIVATE_KEY");
        console.log("    --rpc-url $SEPOLIA_RPC_URL");
        console.log("");
        console.log("Example (set to $4.00):");
        console.log("  cast send", address(oracle));
        console.log("    'updatePrice(uint256)' 4000000000000000000");
        console.log("    --private-key $PRIVATE_KEY");
        console.log("    --rpc-url $SEPOLIA_RPC_URL");
    }
}
