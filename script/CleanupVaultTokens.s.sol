// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface ICollateralVault {
    struct CollateralConfig {
        address token;
        uint256 baseUnit;
        uint16 haircutBps;
        uint16 liqIncentiveBps;
        uint256 cap;
        uint256 accountCap;
        bool enabled;
        bool depositPaused;
        bool withdrawPaused;
        string oracleSymbol;
    }

    function setCollateralParams(address token, CollateralConfig calldata cfg) external;
    function getConfig(address token) external view returns (CollateralConfig memory);
    function balanceOf(address user, address token) external view returns (uint256);
}

contract CleanupVaultTokens is Script {
    address constant VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;
    address constant TOKEN_1 = 0x37D5154731eE25C83E06E1abC312075AB4B4D8fF; // Old token
    address constant TOKEN_2 = 0x71075745A2A63dff3BD4819e9639D0E412c14AA9; // Old token
    address constant USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;    // Keep enabled

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address user = deployer;

        console.log("=========================================");
        console.log("  CLEANUP VAULT TOKENS");
        console.log("=========================================");
        console.log("");
        console.log("Vault:", VAULT);
        console.log("User:", user);
        console.log("");

        // Check balances
        uint256 bal1 = ICollateralVault(VAULT).balanceOf(user, TOKEN_1);
        uint256 bal2 = ICollateralVault(VAULT).balanceOf(user, TOKEN_2);
        uint256 bal3 = ICollateralVault(VAULT).balanceOf(user, USDC);

        console.log("Current Balances:");
        console.log("  Token 1:", TOKEN_1);
        console.log("    Balance:", bal1);
        console.log("  Token 2:", TOKEN_2);
        console.log("    Balance:", bal2);
        console.log("  USDC:", USDC);
        console.log("    Balance:", bal3, "(KEEP THIS)");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Disable old tokens
        console.log("Disabling old tokens...");

        // Get and modify Token 1 config
        ICollateralVault.CollateralConfig memory cfg1 = ICollateralVault(VAULT).getConfig(TOKEN_1);
        cfg1.enabled = false;
        ICollateralVault(VAULT).setCollateralParams(TOKEN_1, cfg1);
        console.log("  Token 1 disabled");

        // Get and modify Token 2 config
        ICollateralVault.CollateralConfig memory cfg2 = ICollateralVault(VAULT).getConfig(TOKEN_2);
        cfg2.enabled = false;
        ICollateralVault(VAULT).setCollateralParams(TOKEN_2, cfg2);
        console.log("  Token 2 disabled");

        vm.stopBroadcast();

        console.log("");
        console.log("=========================================");
        console.log("  COMPLETE");
        console.log("=========================================");
        console.log("");
        console.log("NOTE: Old token balances still exist but won't");
        console.log("      count toward account value anymore.");
    }
}
