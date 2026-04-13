// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CuOracle} from "../src/Oracle/CuOracle.sol";

/// @title SeedCuOracle
/// @notice Commits and reveals an initial price for the CU-PERP market oracle.
///
/// Run:
///   forge script script/SeedCuOracle.s.sol \
///     --rpc-url battlechain_testnet \
///     --broadcast \
///     --legacy
///
/// The script performs both steps in one run. A 2-second sleep between commit
/// and reveal satisfies the 1-second minCommitRevealDelay on testnet.
contract SeedCuOracle is Script {
    CuOracle constant ORACLE = CuOracle(0x2E3f3D9aC763C3c7D8F5A9D6A94dD745D76D9e8f);

    bytes32 constant CU_ASSET_ID =
        0x2cb39337dc2f90e1578ad7f3ba41430cb4ae796ca5b7d7d2aaced43f80bf42e4;

    /// Initial price: $3.00 per compute unit (1e18 format)
    uint256 constant INITIAL_PRICE = 3e18;

    /// Deterministic nonce — change for each new commit cycle
    bytes32 constant NONCE = keccak256("bytestrike-seed-v1");

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        bytes32 commitment = keccak256(abi.encodePacked(INITIAL_PRICE, NONCE));

        console.log("CuOracle:  ", address(ORACLE));
        console.log("Asset ID:   ");
        console.logBytes32(CU_ASSET_ID);
        console.log("Price:     ", INITIAL_PRICE, "(3.00 USD in 1e18)");
        console.log("Nonce:      ");
        console.logBytes32(NONCE);
        console.log("Commitment: ");
        console.logBytes32(commitment);
        console.log("");

        // ── Step 1: Commit ──────────────────────────────────────────────────
        console.log("Step 1: Committing price hash...");
        vm.startBroadcast(deployerPrivateKey);
        ORACLE.commitPrice(CU_ASSET_ID, commitment);
        vm.stopBroadcast();
        console.log("Commit tx sent.");

        // ── Wait for minCommitRevealDelay (1s on testnet) ───────────────────
        console.log("Waiting 3 seconds before reveal...");
        vm.sleep(3000); // 3 000 ms

        // ── Step 2: Reveal ──────────────────────────────────────────────────
        console.log("Step 2: Revealing price...");
        vm.startBroadcast(deployerPrivateKey);
        ORACLE.updatePrices(CU_ASSET_ID, INITIAL_PRICE, NONCE);
        vm.stopBroadcast();

        console.log("");
        console.log("========================================");
        console.log("  CuOracle seeded successfully");
        console.log("  Price: $3.00 per compute unit");
        console.log("========================================");
    }
}
