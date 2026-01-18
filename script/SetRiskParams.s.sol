// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import "../src/ClearingHouse.sol";

/**
 * @title SetRiskParams
 * @notice Script to set risk parameters for markets in the ClearingHouse
 * @dev Run with: forge script script/SetRiskParams.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
 */
contract SetRiskParams is Script {
    // Deployed contract addresses (Sepolia)
    address constant CLEARING_HOUSE = 0x445Fa8890562Ec6220A60b3911C692DffaD49AcB;

    // Market IDs
    bytes32 constant ETH_PERP_V2_MARKET_ID = 0x385badc5603eb47056a6bdcd6ac81a50df49d7a4e8a7451405e580bd12087a28;
    bytes32 constant ETH_PERP_MARKET_ID = 0x352291f10e3a0d4a9f7beb3b623eac0b06f735c95170f956bc68b2f8b504a35d;

    // Risk Parameters - TESTNET ONLY: Minimal values to bypass margin checks
    // WARNING: DO NOT USE ON MAINNET - Allows infinite leverage
    uint256 constant IMR_BPS = 1;                 // 0.01% initial margin requirement (essentially 0)
    uint256 constant MMR_BPS = 1;                 // 0.01% maintenance margin requirement (minimum allowed)
    uint256 constant LIQUIDATION_PENALTY_BPS = 1; // 0.01% liquidation penalty
    uint256 constant PENALTY_CAP = 10_000 * 1e18; // 10,000 USDC max penalty
    uint256 constant MAX_POSITION_SIZE = 0;       // 0 = unlimited
    uint256 constant MIN_POSITION_SIZE = 0;       // 0 = no minimum

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        ClearingHouse clearingHouse = ClearingHouse(CLEARING_HOUSE);

        console.log("Setting risk parameters for markets...");
        console.log("ClearingHouse:", address(clearingHouse));

        // Set risk params for ETH-PERP-V2 (active market)
        console.log("=== Setting Risk Params for ETH-PERP-V2 ===");
        console.log("Market ID:");
        console.logBytes32(ETH_PERP_V2_MARKET_ID);
        console.log("IMR (bps):", IMR_BPS);
        console.log("MMR (bps):", MMR_BPS);
        console.log("Liquidation Penalty (bps):", LIQUIDATION_PENALTY_BPS);
        console.log("Penalty Cap:", PENALTY_CAP / 1e18);

        clearingHouse.setRiskParams(
            ETH_PERP_V2_MARKET_ID,
            IMR_BPS,
            MMR_BPS,
            LIQUIDATION_PENALTY_BPS,
            PENALTY_CAP,
            MAX_POSITION_SIZE,
            MIN_POSITION_SIZE
        );

        console.log("Risk params set for ETH-PERP-V2!");

        // Set risk params for ETH-PERP (deprecated market - same params)
        console.log("=== Setting Risk Params for ETH-PERP (Deprecated) ===");
        console.log("Market ID:");
        console.logBytes32(ETH_PERP_MARKET_ID);

        clearingHouse.setRiskParams(
            ETH_PERP_MARKET_ID,
            IMR_BPS,
            MMR_BPS,
            LIQUIDATION_PENALTY_BPS,
            PENALTY_CAP,
            MAX_POSITION_SIZE,
            MIN_POSITION_SIZE
        );

        console.log("Risk params set for ETH-PERP!");

        // Verify the settings
        console.log("=== Verifying Risk Params ===");

        (uint256 imr1, uint256 mmr1, uint256 penalty1, uint256 cap1, uint256 max1, uint256 min1) = clearingHouse.marketRiskParams(ETH_PERP_V2_MARKET_ID);
        console.log("ETH-PERP-V2:");
        console.log("  IMR (bps):", imr1);
        console.log("  MMR (bps):", mmr1);
        console.log("  Penalty (bps):", penalty1);
        console.log("  Cap:", cap1 / 1e18);
        console.log("  Max Size:", max1);
        console.log("  Min Size:", min1);

        (uint256 imr2, uint256 mmr2, uint256 penalty2, uint256 cap2, uint256 max2, uint256 min2) = clearingHouse.marketRiskParams(ETH_PERP_MARKET_ID);
        console.log("ETH-PERP:");
        console.log("  IMR (bps):", imr2);
        console.log("  MMR (bps):", mmr2);
        console.log("  Penalty (bps):", penalty2);
        console.log("  Cap:", cap2 / 1e18);
        console.log("  Max Size:", max2);
        console.log("  Min Size:", min2);

        vm.stopBroadcast();

        console.log("=== Risk Parameters Set Successfully! ===");
        console.log("TESTNET ONLY - Minimal margin requirements enabled");
        console.log("Frontend will now display:");
        console.log("  IMR: 0.01% (essentially no margin requirement)");
        console.log("  MMR: 0.01% (essentially no liquidations)");
        console.log("  Liquidation Penalty: 0.01%");
        console.log("");
        console.log("WARNING: These settings allow infinite leverage!");
        console.log("Remember to restore proper values before mainnet deployment.");
    }
}
