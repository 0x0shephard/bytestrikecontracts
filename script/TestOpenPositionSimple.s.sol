// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestOpenPositionSimple is Script {
    address constant CLEARING_HOUSE = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;
    address constant COLLATERAL_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;
    address constant MOCK_USDC = 0x71075745A2A63dff3BD4819e9639D0E412c14AA9;

    bytes32 constant MARKET_ID = 0x923fe13d72f8a442cb473c31c3f8b89b76ea47edc7f5071ccdae6717ad84fe6e;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(deployerPrivateKey);

        console.log("=== SIMPLE POSITION OPEN TEST ===");
        console.log("Trader:", trader);
        console.log("");

        ClearingHouse ch = ClearingHouse(CLEARING_HOUSE);
        ICollateralVault vault = ICollateralVault(COLLATERAL_VAULT);
        IERC20 usdc = IERC20(MOCK_USDC);

        uint256 usdcBalance = usdc.balanceOf(trader);
        console.log("USDC Balance:", usdcBalance);

        vm.startBroadcast(deployerPrivateKey);

        // Deposit large amount to avoid any shortfall
        uint256 depositAmount = 100000000000000; // 100M USDC
        if (usdcBalance >= depositAmount) {
            usdc.approve(COLLATERAL_VAULT, depositAmount);
            ch.deposit(MOCK_USDC, depositAmount);
            console.log("Deposited:", depositAmount);
        }

        uint256 collateralValue = vault.getAccountCollateralValueX18(trader);
        console.log("Collateral Value (X18):", collateralValue);
        console.log("");

        // Open tiny position
        uint128 size = 0.0001 ether; // 0.0001 ETH
        console.log("Opening position - Size: 0.0001 ETH");

        try ch.openPosition(MARKET_ID, true, size, 0) {
            console.log("SUCCESS!");

            IClearingHouse.PositionView memory pos = ch.getPosition(trader, MARKET_ID);
            console.log("Position Size:", uint256(pos.size));
            console.log("Position Margin:", pos.margin);
            console.log("Entry Price:", pos.entryPriceX18);

        } catch Error(string memory reason) {
            console.log("FAILED:", reason);
        } catch (bytes memory data) {
            console.log("FAILED: Low-level");
            console.logBytes(data);
        }

        vm.stopBroadcast();
    }
}
