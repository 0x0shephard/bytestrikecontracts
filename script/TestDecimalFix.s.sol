// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestDecimalFix
 * @notice Tests that the upgraded ClearingHouse correctly converts fees from 1e18 to quote decimals
 */
contract TestDecimalFix is Script {
    address constant CLEARING_HOUSE = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;
    address constant COLLATERAL_VAULT = 0x7109D4E5368476a2FeCaACCfDbd9E77284C5987C;
    address constant MOCK_USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;
    address constant INSURANCE_FUND = 0x3C1085dF918a38A95F84945E6705CC857b664074;
    address constant FEE_ROUTER = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F;
    bytes32 constant ETH_PERP_V2 = 0x923fe13dd90eff0f2f8b82db89ef27daef5f899aca7fba59ebb0b01a6343bfb5;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  TESTING DECIMAL CONVERSION FIX");
        console.log("=========================================");
        console.log("");
        console.log("Trader:", trader);
        console.log("ClearingHouse:", CLEARING_HOUSE);
        console.log("Market:", vm.toString(ETH_PERP_V2));
        console.log("");

        // Check balances before
        uint256 traderUSDCBefore = IERC20(MOCK_USDC).balanceOf(trader);
        uint256 insuranceUSDCBefore = IERC20(MOCK_USDC).balanceOf(INSURANCE_FUND);
        uint256 feeRouterUSDCBefore = IERC20(MOCK_USDC).balanceOf(FEE_ROUTER);
        uint256 traderCollateralBefore = ICollateralVault(COLLATERAL_VAULT).balanceOf(trader, MOCK_USDC);

        console.log("BEFORE TRADE:");
        console.log("  Trader USDC balance:", traderUSDCBefore);
        console.log("  Trader collateral:", traderCollateralBefore);
        console.log("  InsuranceFund USDC:", insuranceUSDCBefore);
        console.log("  FeeRouter USDC:", feeRouterUSDCBefore);
        console.log("");

        // Check current position
        IClearingHouse.PositionView memory posBefore = ClearingHouse(CLEARING_HOUSE).getPosition(trader, ETH_PERP_V2);
        console.log("POSITION BEFORE:");
        console.log("  Size:", posBefore.size);
        console.log("  Margin:", posBefore.margin);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Open a small position: 0.0001 ETH
        // At $3.75, notional = 0.0001 * 3.75 = $0.000375
        // With 1% fee: 0.000375 * 0.01 = $0.00000375
        // In 1e6 decimals: 3.75 USDC units (should be ~4 after rounding)
        uint128 size = 0.0001 ether;
        uint256 priceLimit = 4 ether; // Max $4 slippage

        console.log("Opening position:");
        console.log("  Size:", size, "wei (0.0001 ETH)");
        console.log("  Price limit:", priceLimit);
        console.log("");

        try ClearingHouse(CLEARING_HOUSE).openPosition(ETH_PERP_V2, true, size, priceLimit) {
            console.log("SUCCESS: Position opened");
        } catch Error(string memory reason) {
            console.log("FAILED:", reason);
            vm.stopBroadcast();
            return;
        } catch (bytes memory lowLevelData) {
            console.log("FAILED: Low-level error");
            console.logBytes(lowLevelData);
            vm.stopBroadcast();
            return;
        }

        vm.stopBroadcast();

        // Check balances after
        uint256 traderUSDCAfter = IERC20(MOCK_USDC).balanceOf(trader);
        uint256 insuranceUSDCAfter = IERC20(MOCK_USDC).balanceOf(INSURANCE_FUND);
        uint256 feeRouterUSDCAfter = IERC20(MOCK_USDC).balanceOf(FEE_ROUTER);
        uint256 traderCollateralAfter = ICollateralVault(COLLATERAL_VAULT).balanceOf(trader, MOCK_USDC);

        console.log("");
        console.log("AFTER TRADE:");
        console.log("  Trader USDC balance:", traderUSDCAfter);
        console.log("  Trader collateral:", traderCollateralAfter);
        console.log("  InsuranceFund USDC:", insuranceUSDCAfter);
        console.log("  FeeRouter USDC:", feeRouterUSDCAfter);
        console.log("");

        // Calculate changes
        int256 traderUSDCChange = int256(traderUSDCAfter) - int256(traderUSDCBefore);
        int256 traderCollateralChange = int256(traderCollateralAfter) - int256(traderCollateralBefore);
        int256 insuranceChange = int256(insuranceUSDCAfter) - int256(insuranceUSDCBefore);
        int256 feeRouterChange = int256(feeRouterUSDCAfter) - int256(feeRouterUSDCBefore);

        console.log("CHANGES:");
        console.log("  Trader USDC:", traderUSDCChange >= 0 ? "+" : "", vm.toString(traderUSDCChange));
        console.log("  Trader collateral:", traderCollateralChange >= 0 ? "+" : "", vm.toString(traderCollateralChange));
        console.log("  InsuranceFund:", insuranceChange >= 0 ? "+" : "", vm.toString(insuranceChange));
        console.log("  FeeRouter:", feeRouterChange >= 0 ? "+" : "", vm.toString(feeRouterChange));
        console.log("");

        // Check position after
        IClearingHouse.PositionView memory posAfter = ClearingHouse(CLEARING_HOUSE).getPosition(trader, ETH_PERP_V2);
        console.log("POSITION AFTER:");
        console.log("  Size:", posAfter.size);
        console.log("  Margin:", posAfter.margin);
        console.log("  Entry Price (X18):", posAfter.entryPriceX18);
        console.log("");

        console.log("=========================================");
        console.log("  TEST COMPLETE");
        console.log("=========================================");
        console.log("");
        console.log("Analysis:");
        console.log("  Expected fee: ~4 USDC units (0.00000375 USD in 1e6)");
        console.log("  Actual FeeRouter change:", vm.toString(feeRouterChange));

        if (feeRouterChange > 0 && feeRouterChange < 1000) {
            console.log("  PASS: Fee amount reasonable");
        } else if (feeRouterChange == 0) {
            console.log("  WARNING: No fee collected");
        } else {
            console.log("  WARNING: Fee seems too large (possible decimal issue)");
        }
    }
}
