// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FundInsuranceFund
 * @notice Transfer USDC to InsuranceFund
 */
contract FundInsuranceFund is Script {
    address constant INSURANCE_FUND = 0x3C1085dF918a38A95F84945E6705CC857b664074;
    address constant MOCK_USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  FUND INSURANCE FUND");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("");

        uint256 deployerBalance = IERC20(MOCK_USDC).balanceOf(deployer);
        console.log("Deployer USDC balance:", deployerBalance);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Transfer 10,000 USDC to InsuranceFund
        uint256 fundAmount = 10_000 * 1e6;
        console.log("Transferring", fundAmount, "USDC to InsuranceFund");
        IERC20(MOCK_USDC).transfer(INSURANCE_FUND, fundAmount);
        console.log("Transferred successfully!");

        vm.stopBroadcast();

        uint256 ifBalance = IERC20(MOCK_USDC).balanceOf(INSURANCE_FUND);
        console.log("");
        console.log("InsuranceFund balance:", ifBalance);
        console.log("");
        console.log("=========================================");
        console.log("  FUNDING COMPLETE");
        console.log("=========================================");
    }
}
