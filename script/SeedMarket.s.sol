// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

/// @title SeedMarket
/// @notice Seeds a newly registered market with a minimal paired long+short position.
///
/// @dev Bootstrapping rationale:
///      The vAMM funding mechanism only accrues when both totalLongOI > 0 and totalShortOI > 0.
///      Without seed positions, the very first trader on either side operates with zero funding
///      incentive, because any funding that would be owed to them has no counterparty to pay it.
///      This also creates a "first trader" vector: a sophisticated actor could open a large
///      one-sided position before any counterparty exists and earn funding with no risk of the
///      system rebalancing against them.
///
///      Two separate wallets are required because ClearingHouse tracks position size as a single
///      signed integer per (address, marketId) — the same address cannot hold both a long and a
///      short in the same market simultaneously.
///
/// @dev Required environment variables:
///      PRIVATE_KEY      — Admin wallet (funds both seed wallets via vault.deposit onBehalfOf)
///      SEED_LONG_PK     — Seed long wallet private key
///      SEED_SHORT_PK    — Seed short wallet private key
///
/// @dev Required configuration (update constants below before running):
///      CLEARING_HOUSE   — ClearingHouse proxy address
///      COLLATERAL_VAULT — CollateralVault proxy address
///      USDC             — Quote token (USDC) address
///      MARKET_ID        — keccak256 market identifier
///
/// Usage:
///      forge script script/SeedMarket.s.sol --rpc-url $RPC_URL --broadcast
contract SeedMarket is Script {

    // =========== Configure before running ===========

    address constant CLEARING_HOUSE   = address(0); // TODO: set proxy address
    address constant COLLATERAL_VAULT = address(0); // TODO: set proxy address
    address constant USDC             = address(0); // TODO: set USDC address
    bytes32 constant MARKET_ID        = keccak256("ETH-PERP"); // TODO: set target market

    // Seed position parameters.
    // 0.001 ETH — small enough to have negligible price impact on the vAMM, large enough
    // that both long and short OI are non-zero from the first block after deployment.
    uint128 constant SEED_SIZE = 0.001 ether; // 1e15 base units

    // 50 USDC per side — well above the initial margin requirement for a 0.001 ETH position
    // at ~$3000 with a 10x leverage cap (notional ≈ $3, IMR ≈ $0.30).
    uint256 constant SEED_COLLATERAL = 50e6; // 50 USDC (6 decimals)

    // ================================================

    function run() external {
        uint256 adminPk     = vm.envUint("PRIVATE_KEY");
        uint256 seedLongPk  = vm.envUint("SEED_LONG_PK");
        uint256 seedShortPk = vm.envUint("SEED_SHORT_PK");

        address admin     = vm.addr(adminPk);
        address seedLong  = vm.addr(seedLongPk);
        address seedShort = vm.addr(seedShortPk);

        require(CLEARING_HOUSE   != address(0), "SeedMarket: CLEARING_HOUSE not set");
        require(COLLATERAL_VAULT != address(0), "SeedMarket: COLLATERAL_VAULT not set");
        require(USDC             != address(0), "SeedMarket: USDC not set");
        require(seedLong != seedShort,          "SeedMarket: seed wallets must differ");

        console.log("=========================================");
        console.log("  SEED MARKET");
        console.log("=========================================");
        console.log("Admin:      ", admin);
        console.log("Seed long:  ", seedLong);
        console.log("Seed short: ", seedShort);
        console.log("Seed size:  ", SEED_SIZE, "base units (0.001 ETH)");
        console.log("Collateral: ", SEED_COLLATERAL, "per side (50 USDC)");
        console.log("");

        // ── Step 1: Admin deposits collateral on behalf of both seed wallets ──────────
        console.log("Step 1: Admin funds seed wallets via vault...");
        vm.startBroadcast(adminPk);

        uint256 totalNeeded = SEED_COLLATERAL * 2;
        IERC20(USDC).approve(COLLATERAL_VAULT, totalNeeded);

        ICollateralVault(COLLATERAL_VAULT).deposit(USDC, SEED_COLLATERAL, seedLong);
        ICollateralVault(COLLATERAL_VAULT).deposit(USDC, SEED_COLLATERAL, seedShort);

        vm.stopBroadcast();

        console.log("  Deposited", SEED_COLLATERAL, "USDC for seed long wallet");
        console.log("  Deposited", SEED_COLLATERAL, "USDC for seed short wallet");
        console.log("");

        // ── Step 2: Seed long wallet opens long ──────────────────────────────────────
        console.log("Step 2: Seed long wallet opens long position...");
        vm.startBroadcast(seedLongPk);

        IClearingHouse(CLEARING_HOUSE).openPosition(MARKET_ID, true, SEED_SIZE, 0);

        vm.stopBroadcast();

        IClearingHouse.PositionView memory longPos =
            IClearingHouse(CLEARING_HOUSE).getPosition(seedLong, MARKET_ID);
        console.log("  Long position size:  ", longPos.size);
        console.log("  Long entry price:    ", longPos.entryPriceX18);
        console.log("  Long margin:         ", longPos.margin);
        console.log("");

        // ── Step 3: Seed short wallet opens short ────────────────────────────────────
        console.log("Step 3: Seed short wallet opens short position...");
        vm.startBroadcast(seedShortPk);

        IClearingHouse(CLEARING_HOUSE).openPosition(MARKET_ID, false, SEED_SIZE, 0);

        vm.stopBroadcast();

        IClearingHouse.PositionView memory shortPos =
            IClearingHouse(CLEARING_HOUSE).getPosition(seedShort, MARKET_ID);
        console.log("  Short position size: ", shortPos.size);
        console.log("  Short entry price:   ", shortPos.entryPriceX18);
        console.log("  Short margin:        ", shortPos.margin);
        console.log("");

        // ── Verification ─────────────────────────────────────────────────────────────
        console.log("=========================================");
        console.log("  VERIFICATION");
        console.log("=========================================");
        console.log("Long  OI seeded: both-sided OI now non-zero");
        console.log("  longPos.size  > 0:", longPos.size > 0);
        console.log("  shortPos.size < 0:", shortPos.size < 0);
        console.log("");
        console.log("Funding will accrue from the next pokeFunding() call.");
        console.log("Market is ready for trading.");
        console.log("=========================================");
    }
}
