// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";

/**
 * @title SetupForFinalTest
 * @notice Deposit USDC to old vault and fund InsuranceFund
 */
contract SetupForFinalTest is Script {
    address constant OLD_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;
    address constant INSURANCE_FUND = 0x3C1085dF918a38A95F84945E6705CC857b664074;
    address constant MOCK_USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  SETUP FOR FINAL TEST");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("");

        // Check balances
        uint256 deployerBalance = IERC20(MOCK_USDC).balanceOf(deployer);
        console.log("Deployer USDC balance:", deployerBalance);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deposit 100,000 USDC to old vault
        uint256 depositAmount = 100_000 * 1e6;
        console.log("Step 1: Depositing", depositAmount, "USDC to old vault");
        IERC20(MOCK_USDC).approve(OLD_VAULT, depositAmount);
        ICollateralVault(OLD_VAULT).deposit(MOCK_USDC, depositAmount, deployer);
        console.log("Deposited successfully!");
        console.log("");

        // 2. Transfer 50,000 USDC to InsuranceFund
        uint256 fundAmount = 50_000 * 1e6;
        console.log("Step 2: Funding InsuranceFund with", fundAmount, "USDC");
        IERC20(MOCK_USDC).transfer(INSURANCE_FUND, fundAmount);
        console.log("Funded successfully!");

        vm.stopBroadcast();

        console.log("");
        console.log("Final Balances:");
        console.log("  Old Vault (trader):", ICollateralVault(OLD_VAULT).balanceOf(deployer, MOCK_USDC));
        console.log("  InsuranceFund:", IERC20(MOCK_USDC).balanceOf(INSURANCE_FUND));
        console.log("");
        console.log("=========================================");
        console.log("  SETUP COMPLETE");
        console.log("=========================================");
    }
}
