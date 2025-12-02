// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import "../src/ClearingHouse.sol";
import "../src/CollateralVault.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestOpenPosition
 * @notice Debug script to test opening a position on ClearingHouse
 */
contract TestOpenPosition is Script {
    // Deployed contract addresses (Sepolia - NEW DEPLOYMENT)
    address constant CLEARING_HOUSE = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;
    address constant COLLATERAL_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;
    address constant MOCK_USDC = 0x37D5154731eE25C83E06E1abC312075AB4B4D8fF;
    address constant VAMM_PROXY = 0x684d4C1133188845EaF9d533bef6E602C1a8b6d2;

    // Market ID for H100-GPU-PERP
    bytes32 constant H100_GPU_MARKET_ID = 0xa583a10b2c0991c6f416501cbea19895d7becde9398eff1b7f60ef1120547d53;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Testing Position Opening ===");
        console.log("Wallet:", deployer);
        console.log("ClearingHouse:", CLEARING_HOUSE);
        console.log("CollateralVault:", COLLATERAL_VAULT);
        console.log("Market ID:");
        console.logBytes32(H100_GPU_MARKET_ID);
        console.log("");

        // Step 1: Check USDC balance
        IERC20 usdc = IERC20(MOCK_USDC);
        uint256 usdcBalance = usdc.balanceOf(deployer);
        console.log("Step 1: USDC Balance");
        console.log("  Balance:", usdcBalance);
        console.log("  Balance (human):", usdcBalance / 1e6, "USDC");
        console.log("");

        if (usdcBalance == 0) {
            console.log("ERROR: No USDC balance. Mint some USDC first!");
            return;
        }

        // Step 2: Check USDC allowance for CollateralVault
        uint256 allowance = usdc.allowance(deployer, COLLATERAL_VAULT);
        console.log("Step 2: USDC Allowance");
        console.log("  Allowance:", allowance);
        console.log("  Allowance (human):", allowance / 1e6, "USDC");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 3: Approve if needed
        if (allowance < 10 * 1e6) {
            console.log("Step 3: Approving USDC...");
            usdc.approve(COLLATERAL_VAULT, type(uint256).max);
            console.log("  Approved: unlimited");
            console.log("");
        }

        // Step 4: Check collateral balance in vault
        ClearingHouse clearingHouse = ClearingHouse(CLEARING_HOUSE);
        int256 accountValueSigned = clearingHouse.getAccountValue(deployer);
        uint256 accountValue = accountValueSigned > 0 ? uint256(accountValueSigned) : 0;
        console.log("Step 4: Account Value in ClearingHouse");
        console.log("  Account Value:", accountValue);
        console.log("  Account Value (human):", accountValue / 1e18, "USD");
        console.log("");

        // Step 5: Deposit collateral if needed
        if (accountValue < 10 * 1e18) {
            console.log("Step 5: Depositing 10 USDC as collateral...");
            uint256 depositAmount = 10 * 1e6; // 10 USDC (6 decimals)
            clearingHouse.deposit(MOCK_USDC, depositAmount);

            accountValueSigned = clearingHouse.getAccountValue(deployer);
            accountValue = accountValueSigned > 0 ? uint256(accountValueSigned) : 0;
            console.log("  New Account Value:", accountValue / 1e18, "USD");
            console.log("");
        }

        // Step 6: Get current mark price
        console.log("Step 6: Getting Mark Price...");
        (bool success, bytes memory data) = VAMM_PROXY.staticcall(
            abi.encodeWithSignature("getMarkPrice()")
        );
        uint256 markPrice = 0;
        if (success) {
            markPrice = abi.decode(data, (uint256));
            console.log("  Mark Price:", markPrice);
            console.log("  Mark Price (human):", markPrice / 1e18, "USD");
        } else {
            console.log("  Failed to get mark price");
        }
        console.log("");

        // Step 7: Check risk parameters
        console.log("Step 7: Risk Parameters");
        (uint256 imr, uint256 mmr, uint256 penalty, uint256 cap) = clearingHouse.marketRiskParams(H100_GPU_MARKET_ID);
        console.log("  IMR (bps):", imr);
        console.log("  MMR (bps):", mmr);
        console.log("  Liquidation Penalty (bps):", penalty);
        console.log("");

        // Step 8: Calculate position parameters
        console.log("Step 8: Position Calculation");
        uint256 targetNotional = 80 * 1e18; // $80 notional
        uint256 size = 0;
        if (markPrice > 0) {
            size = (targetNotional * 1e18) / markPrice;
            console.log("  Target Notional: $80");
            console.log("  Size:", size);
            console.log("  Size (human):", size / 1e18, "ETH");

            uint256 requiredMargin = (targetNotional * imr) / 10_000;
            uint256 tradingFee = (targetNotional * 10) / 10_000; // 10 bps = 0.1%
            console.log("  Required Margin (IMR):", requiredMargin / 1e18, "USD");
            console.log("  Trading Fee:", tradingFee / 1e18, "USD");
            console.log("  Total Needed:", (requiredMargin + tradingFee) / 1e18, "USD");
        }
        console.log("");

        // Step 9: Try to open position
        if (size > 0 && accountValue >= 1 * 1e18) {
            console.log("Step 9: Opening Position...");
            console.log("  Market ID:");
            console.logBytes32(H100_GPU_MARKET_ID);
            console.log("  Is Long: true");
            console.log("  Size:", size / 1e18, "GPU hours");
            console.log("  Price Limit: 0 (market order)");
            console.log("");

            try clearingHouse.openPosition(
                H100_GPU_MARKET_ID,
                true,  // isLong
                uint128(size),
                0  // priceLimitX18 = 0 (no limit, market order)
            ) {
                console.log("SUCCESS: Position opened!");
                console.log("");

                // Check new position
                console.log("Step 10: Checking Position...");
                IClearingHouse.PositionView memory pos = clearingHouse.getPosition(deployer, H100_GPU_MARKET_ID);
                uint256 posSize = pos.size > 0 ? uint256(pos.size) : uint256(-pos.size);
                console.log("  Position Size:", posSize / 1e18, "GPU hours");
                console.log("  Margin:", pos.margin / 1e18, "USD");
                console.log("  Entry Price:", pos.entryPriceX18 / 1e18, "USD");
                int256 realizedPnL = pos.realizedPnL;
                if (realizedPnL >= 0) {
                    console.log("  Realized PnL:", uint256(realizedPnL) / 1e18, "USD (profit)");
                } else {
                    console.log("  Realized PnL:", uint256(-realizedPnL) / 1e18, "USD (loss)");
                }
            } catch Error(string memory reason) {
                console.log("FAILED: Position opening failed!");
                console.log("Error:", reason);
            } catch (bytes memory lowLevelData) {
                console.log("FAILED: Position opening failed with low-level error!");
                console.log("Error data length:", lowLevelData.length);
            }
        } else {
            console.log("Step 9: Skipping position opening");
            console.log("  Reason: Insufficient account value or size is 0");
        }

        vm.stopBroadcast();
    }
}
