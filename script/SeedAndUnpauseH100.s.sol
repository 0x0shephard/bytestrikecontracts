// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CuOracle} from "../src/Oracle/CuOracle.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {SeedLimits} from "./SeedLimits.sol";

/// @title SeedAndUnpauseH100
/// @notice Phase 5 of the Sepolia H100-PERP rollout: reveal the CuOracle price,
///         open paired seed long/short to satisfy audit M-12, then unpause the
///         market for public trading.
///
/// @dev MUST be run AT LEAST ONE BLOCK after DeploySepoliaH100 because
///      CuOracle::updatePrices requires `block.timestamp >= commitTime + 1s`.
///
/// @dev The market is listed unpaused, so it is open from the price reveal. The seed trades run with
///      the trader allowlist enforced and only the seed wallets listed (nobody else trades yet), and
///      with slippage limits a few bps from the expected fill (SeedLimits). Enforcement is switched
///      back off at the end if it was off before.
///
/// @dev Sign as the deployer (oracle owner, ClearingHouse owner; unpauses market) via `--account <keystore-name>`.
/// @dev Required env vars:
///        SEED_LONG_PK    - seed long wallet (already funded with USDC by Phase 1)
///        SEED_SHORT_PK   - seed short wallet (already funded with USDC by Phase 1)
///        H100_NONCE      - same 32-byte nonce used in Phase 4 commit
contract SeedAndUnpauseH100 is Script {

    bytes32 constant H100_PERP     = keccak256("H100-PERP");
    bytes32 constant H100_ASSET_ID = keccak256("H100");

    uint256 constant INITIAL_PRICE_X18 = 4_220_000_000_000_000_000; // $4.22 — must match Phase 4

    // Seed sizing: 100 H100-hr per side at $4.22 ≈ $422 notional, 0.6% slippage on 10k base reserve.
    uint128 constant SEED_SIZE         = 100e18;
    uint256 constant SEED_DEPOSIT_USDC = 1_000e6;       // $1,000 (USDC has 6 decimals)
    uint256 constant SEED_MARGIN_X18   = 200e18;        // $200 — well above 10% IMR of $42

    // amountLimit semantics (per ClearingHouse.openPosition docs):
    //   long  -> max quote tokens to SPEND   in WAD (1e18 units)
    //   short -> min quote tokens to RECEIVE in WAD
    // Both come from SeedLimits: SEED_SLIPPAGE_BPS from the fill expected at the reserves right
    // before each seed trade.

    function run() external {
        uint256 seedLongPk  = vm.envUint("SEED_LONG_PK");
        uint256 seedShortPk = vm.envUint("SEED_SHORT_PK");
        bytes32 nonce       = vm.envBytes32("H100_NONCE");

        // Read deployment artifacts written by DeploySepoliaH100.
        string memory j = vm.readFile("./deployments/sepolia.json");
        address cuOracle      = vm.parseJsonAddress(j, ".cuOracle");
        address registryAddr  = vm.parseJsonAddress(j, ".registry");
        address chAddr        = vm.parseJsonAddress(j, ".clearingHouse");
        address vault         = vm.parseJsonAddress(j, ".vault");
        address usdc          = vm.parseJsonAddress(j, ".usdc");

        address deployer  = msg.sender;
        address seedLong  = vm.addr(seedLongPk);
        address seedShort = vm.addr(seedShortPk);

        require(seedLong != seedShort, "seed wallets must differ");

        console.log("============================================");
        console.log(" Phase 5: reveal + seed + unpause");
        console.log("============================================");
        console.log("Deployer:   ", deployer);
        console.log("Seed long:  ", seedLong);
        console.log("Seed short: ", seedShort);
        console.log("");

        address vamm = SeedLimits.vammOf(registryAddr, H100_PERP);
        ClearingHouse ch = ClearingHouse(payable(chAddr));
        bool allowlistWasEnforced = ch.allowlistEnforced();

        // ── Step 0: only the seed wallets may deposit or open until both seeds land ──
        vm.startBroadcast();
        address[] memory seeds = new address[](2);
        seeds[0] = seedLong;
        seeds[1] = seedShort;
        ch.setAllowedTraders(seeds, true);
        if (!allowlistWasEnforced) ch.setAllowlistEnforced(true);
        vm.stopBroadcast();
        console.log("Step 0: trader allowlist enforced with the seed wallets listed");

        // ── Step 1: deployer reveals oracle price ─────────────────────────────
        vm.startBroadcast();
        CuOracle(cuOracle).updatePrices(H100_ASSET_ID, INITIAL_PRICE_X18, nonce);
        vm.stopBroadcast();
        console.log("Step 1: oracle price revealed at $4.22");

        // ── Step 2: seed long opens long ──────────────────────────────────────
        vm.startBroadcast(seedLongPk);
        IERC20(usdc).approve(vault, SEED_DEPOSIT_USDC);
        ClearingHouse(payable(chAddr)).deposit(usdc, SEED_DEPOSIT_USDC);
        ClearingHouse(payable(chAddr)).openPosition(H100_PERP, true, SEED_SIZE, SeedLimits.longMaxQuoteIn(vamm, SEED_SIZE));
        ClearingHouse(payable(chAddr)).addMargin(H100_PERP, SEED_MARGIN_X18);
        vm.stopBroadcast();

        IClearingHouse.PositionView memory longPos =
            ClearingHouse(payable(chAddr)).getPosition(seedLong, H100_PERP);
        console.log("Step 2: seed long opened");
        console.log("  size: ");
        console.logInt(longPos.size);
        console.log("  entry price: ", longPos.entryPriceX18);

        // ── Step 3: seed short opens short ────────────────────────────────────
        vm.startBroadcast(seedShortPk);
        IERC20(usdc).approve(vault, SEED_DEPOSIT_USDC);
        ClearingHouse(payable(chAddr)).deposit(usdc, SEED_DEPOSIT_USDC);
        ClearingHouse(payable(chAddr)).openPosition(H100_PERP, false, SEED_SIZE, SeedLimits.shortMinQuoteOut(vamm, SEED_SIZE));
        ClearingHouse(payable(chAddr)).addMargin(H100_PERP, SEED_MARGIN_X18);
        vm.stopBroadcast();

        IClearingHouse.PositionView memory shortPos =
            ClearingHouse(payable(chAddr)).getPosition(seedShort, H100_PERP);
        console.log("Step 3: seed short opened");
        console.log("  size: ");
        console.logInt(shortPos.size);
        console.log("  entry price: ", shortPos.entryPriceX18);

        // ── Step 4: deployer opens the market to everyone ─────────────────────
        vm.startBroadcast();
        if (MarketRegistry(registryAddr).isPaused(H100_PERP)) {
            MarketRegistry(registryAddr).pauseMarket(H100_PERP, false);
        }
        if (!allowlistWasEnforced) ch.setAllowlistEnforced(false);
        vm.stopBroadcast();
        console.log("Step 4: H100-PERP open for public trading");

        console.log("");
        console.log("============================================");
        console.log(" Deployment complete. Public trading open.");
        console.log("============================================");
        console.log("Both sides of OI are non-zero (audit M-12).");
        console.log("Funding will accrue from the next ClearingHouse funding settlement.");
        console.log("============================================");
    }
}
