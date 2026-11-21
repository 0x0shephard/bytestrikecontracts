// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IInsuranceFund} from "../src/Interfaces/IInsuranceFund.sol";

/**
 * @title FundInsuranceFund
 * @notice Donate USDC to InsuranceFund
 * @dev Uses InsuranceFund.donate so the amount is booked in the fund's tracked balance and can be
 *      paid out. A plain ERC20 transfer would sit in the fund unspendable until the owner calls sync().
 */
contract FundInsuranceFund is Script {
    address constant INSURANCE_FUND = 0x3C1085dF918a38A95F84945E6705CC857b664074;
    address constant MOCK_USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;

    function run() external {
        address deployer = msg.sender;

        console.log("=========================================");
        console.log("  FUND INSURANCE FUND");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("");

        uint256 deployerBalance = IERC20(MOCK_USDC).balanceOf(deployer);
        console.log("Deployer USDC balance:", deployerBalance);
        console.log("");

        vm.startBroadcast();

        // Donate 10,000 USDC to InsuranceFund
        uint256 fundAmount = 10_000 * 1e6;
        console.log("Donating", fundAmount, "USDC to InsuranceFund");
        IERC20(MOCK_USDC).approve(INSURANCE_FUND, fundAmount);
        IInsuranceFund(INSURANCE_FUND).donate(fundAmount);
        console.log("Donated successfully!");

        vm.stopBroadcast();

        uint256 ifBalance = IERC20(MOCK_USDC).balanceOf(INSURANCE_FUND);
        console.log("");
        console.log("InsuranceFund balance:", ifBalance);
        console.log(
            "InsuranceFund tracked balance:",
            IInsuranceFund(INSURANCE_FUND).totalReceived() - IInsuranceFund(INSURANCE_FUND).totalPaid()
        );
        console.log("");
        console.log("=========================================");
        console.log("  FUNDING COMPLETE");
        console.log("=========================================");
    }
}
