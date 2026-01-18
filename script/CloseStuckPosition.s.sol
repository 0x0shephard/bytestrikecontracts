// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IClearingHouse {
    function closePosition(
        bytes32 marketId,
        uint128 size,
        uint256 priceLimitX18
    ) external;

    function getPosition(bytes32 marketId, address trader) external view returns (
        int256 size,
        uint256 margin,
        uint256 entryPriceX18,
        int256 lastFundingIndex,
        int256 realizedPnL
    );
}

/// @title Close Stuck Position
/// @notice Close the large short position that was stuck due to vAMM depletion
contract CloseStuckPosition is Script {

    address constant CLEARING_HOUSE = 0x445Fa8890562Ec6220A60b3911C692DffaD49AcB;
    bytes32 constant MARKET_ID = 0x923fe13dd90eff0f2f8b82db89ef27daef5f899aca7fba59ebb0b01a6343bfb5; // H100-PERP

    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPrivateKey == 0) {
            deployerPrivateKey = 0x7857dfba6a2faf4f52f5e7b28a28d5a66be4bdf588437d03d5fd5d8522cf8348;
        }

        address trader = vm.addr(deployerPrivateKey);

        console.log("=================================");
        console.log("Closing Stuck Short Position");
        console.log("=================================");
        console.log("Trader:", trader);
        console.log("Market ID:", vm.toString(MARKET_ID));
        console.log("");

        IClearingHouse ch = IClearingHouse(CLEARING_HOUSE);

        // Get current position
        (int256 size, uint256 margin, uint256 entryPrice, , int256 realizedPnL) = ch.getPosition(MARKET_ID, trader);

        console.log("Current Position:");
        console.log("  Size:", size < 0 ? "SHORT" : "LONG", uint256(size < 0 ? -size : size) / 1e18);
        console.log("  Margin:", margin / 1e18);
        console.log("  Entry Price: $", entryPrice / 1e16, ".", (entryPrice % 1e16) / 1e14);
        console.log("  Realized PnL:", realizedPnL / 1e18);

        if (size == 0) {
            console.log("");
            console.log("No position to close!");
            return;
        }

        uint256 absSize = uint256(size < 0 ? -size : size);

        console.log("");
        console.log("Closing position...");
        console.log("  Closing size:", absSize / 1e18, "GPU-HRS");
        console.log("  Price limit: Market (0 = no limit)");

        vm.startBroadcast(deployerPrivateKey);

        // Close the full position at market price (0 = no limit)
        ch.closePosition(
            MARKET_ID,
            uint128(absSize / 1e18), // Convert back to whole units
            0 // Market price (no limit)
        );

        console.log("");
        console.log("Position closed successfully!");

        // Verify position is closed
        (int256 newSize, uint256 newMargin, , , int256 newRealizedPnL) = ch.getPosition(MARKET_ID, trader);

        console.log("");
        console.log("New Position:");
        console.log("  Size:", uint256(newSize < 0 ? -newSize : newSize) / 1e18);
        console.log("  Margin:", newMargin / 1e18);
        console.log("  Realized PnL:", newRealizedPnL / 1e18);

        vm.stopBroadcast();

        console.log("");
        console.log("=================================");
        console.log("Close Complete!");
        console.log("=================================");
    }
}
