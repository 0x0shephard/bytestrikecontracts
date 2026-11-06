// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CuOracle} from "../src/Oracle/CuOracle.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";

/// @title SeedMoreMarkets
/// @notice Phase B for the batch market deployment: reveals every CuOracle price,
///         opens a paired seed long + short on every market (audit M-12), and
///         unpauses each market.
///
/// @dev Sequence (minimises race window):
///        1. Deployer reveals ALL prices first (markets stay paused — oracle live
///           but no one can trade because pauseMarket gate is enforced).
///        2. seed_long does one big USDC.approve + ClearingHouse.deposit.
///        3. seed_short same.
///        4. For each market: deployer.unpause -> seed_long opens long -> seed_short opens short.
///
/// @dev Required env: PRIVATE_KEY, SEED_LONG_PK, SEED_SHORT_PK, NONCE_BASE
contract SeedMoreMarkets is Script {

    address constant CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    address constant REGISTRY  = 0x236b75D39203506ee3180Ef2E1c7460a188C43c6;
    address constant CH        = 0xDf4DDD4019097B335dD507f916984A1A53E40a0d;
    address constant USDC      = 0x947Cc17D8CbC0Fc1E64de138eE4947d3AF9C26EE;
    address constant VAULT     = 0x44345dFCD97973329A88aaE8c1432ea90525Ed13;

    uint128 constant SEED_SIZE       = 100e18;          // 100 base units per side per market
    uint256 constant SEED_MARGIN_X18 = 300e18;          // $300 margin per market per side
    uint256 constant DEPOSIT_USDC    = 7_000 * 1e6;     // 7,000 USDC per seed wallet (~$5,700 of margin needed for 19 markets, $1,300 buffer)

    // Slippage envelopes vs expected execution price.
    uint256 constant LONG_MAX_BPS  = 11_000;            // up to 110% of notional → maxQuoteIn
    uint256 constant SHORT_MIN_BPS = 8_500;             // down to 85%  of notional → minQuoteOut
    uint256 constant BPS           = 10_000;

    struct SeedSpec {
        string  name;
        string  assetSymbol;
        uint256 priceX18;
    }

    function run() external {
        uint256 deployerPk  = vm.envUint("PRIVATE_KEY");
        uint256 seedLongPk  = vm.envUint("SEED_LONG_PK");
        uint256 seedShortPk = vm.envUint("SEED_SHORT_PK");
        bytes32 nonceBase   = vm.envBytes32("NONCE_BASE");

        SeedSpec[] memory s = _buildSpecs();

        console.log("============================================");
        console.log(" Batch seed: ", s.length, "markets");
        console.log("============================================");

        // ── Phase A: deployer reveals every oracle price ──────────────────────
        vm.startBroadcast(deployerPk);
        for (uint256 i = 0; i < s.length; i++) {
            bytes32 assetId = keccak256(bytes(s[i].assetSymbol));
            bytes32 nonce   = keccak256(abi.encode(nonceBase, assetId));
            CuOracle(CU_ORACLE).updatePrices(assetId, s[i].priceX18, nonce);
        }
        vm.stopBroadcast();
        console.log("Phase A complete: all oracle prices revealed");

        // ── Phase B: seed_long deposits USDC ──────────────────────────────────
        vm.startBroadcast(seedLongPk);
        IERC20(USDC).approve(VAULT, DEPOSIT_USDC);
        ClearingHouse(payable(CH)).deposit(USDC, DEPOSIT_USDC);
        vm.stopBroadcast();
        console.log("Phase B complete: seed_long deposited 7000 USDC");

        // ── Phase C: seed_short deposits USDC ─────────────────────────────────
        vm.startBroadcast(seedShortPk);
        IERC20(USDC).approve(VAULT, DEPOSIT_USDC);
        ClearingHouse(payable(CH)).deposit(USDC, DEPOSIT_USDC);
        vm.stopBroadcast();
        console.log("Phase C complete: seed_short deposited 7000 USDC");

        // ── Phase D: per-market unpause + seed long + seed short ──────────────
        for (uint256 i = 0; i < s.length; i++) {
            _seedOne(s[i], deployerPk, seedLongPk, seedShortPk);
        }

        console.log("============================================");
        console.log(" Batch seed complete. All markets active.");
        console.log("============================================");
    }

    function _seedOne(
        SeedSpec memory spec,
        uint256 deployerPk,
        uint256 seedLongPk,
        uint256 seedShortPk
    ) internal {
        bytes32 marketId = keccak256(bytes(spec.name));

        // Estimated notional (size * price / 1e18) and slippage envelopes.
        uint256 notional   = (uint256(SEED_SIZE) * spec.priceX18) / 1e18;
        uint256 maxQuoteIn  = (notional * LONG_MAX_BPS)  / BPS;
        uint256 minQuoteOut = (notional * SHORT_MIN_BPS) / BPS;

        // 1. Deployer unpauses the market (race window opens).
        vm.startBroadcast(deployerPk);
        MarketRegistry(REGISTRY).pauseMarket(marketId, false);
        vm.stopBroadcast();

        // 2. Seed long allocates margin and opens long.
        vm.startBroadcast(seedLongPk);
        ClearingHouse(payable(CH)).addMargin(marketId, SEED_MARGIN_X18);
        ClearingHouse(payable(CH)).openPosition(marketId, true, SEED_SIZE, maxQuoteIn);
        vm.stopBroadcast();

        // 3. Seed short allocates margin and opens short.
        vm.startBroadcast(seedShortPk);
        ClearingHouse(payable(CH)).addMargin(marketId, SEED_MARGIN_X18);
        ClearingHouse(payable(CH)).openPosition(marketId, false, SEED_SIZE, minQuoteOut);
        vm.stopBroadcast();

        console.log(spec.name);
    }

    /// @dev Must mirror DeployMoreMarkets._buildSpecs (name, assetSymbol, priceX18).
    function _buildSpecs() internal pure returns (SeedSpec[] memory s) {
        s = new SeedSpec[](19);
        s[0]  = SeedSpec("A100-PERP",                  "A100",                  176e16);
        s[1]  = SeedSpec("AWS-H100-PERP",              "AWS-H100",              385e16);
        s[2]  = SeedSpec("AWS-H200-PERP",              "AWS-H200",              404e16);
        s[3]  = SeedSpec("AZURE-H100-PERP",            "AZURE-H100",            212e16);
        s[4]  = SeedSpec("B200-PERP",                  "B200",                  715e16);
        s[5]  = SeedSpec("COREWEAVE-H200-PERP",        "COREWEAVE-H200",        1453e16);
        s[6]  = SeedSpec("GCP-H100-PERP",              "GCP-H100",              388e16);
        s[7]  = SeedSpec("GCP-H200-PERP",              "GCP-H200",              660e16);
        s[8]  = SeedSpec("H200-PERP",                  "H200",                  353e16);
        s[9]  = SeedSpec("H100-HyperScalers-PERP",     "H100-HyperScalers",     420e16);
        s[10] = SeedSpec("H100-non-HyperScalers-PERP", "H100-non-HyperScalers", 295e16);
        s[11] = SeedSpec("ORACLE-H200-PERP",           "ORACLE-H200",           647e16);
        s[12] = SeedSpec("T4-PERP",                    "T4",                     45e16);
        s[13] = SeedSpec("H100-GPU-PERP",              "H100-GPU",              375e16);
        s[14] = SeedSpec("ORACLE-H200-PERPETUAL",      "ORACLE_H200_HOUR",      292e16);
        s[15] = SeedSpec("AWS-H200-PERPETUAL",         "AWS_H200_HOUR",         265e16);
        s[16] = SeedSpec("COREWEAVE-H200-PERPETUAL",   "COREWEAVE_H200_HOUR",   257e16);
        s[17] = SeedSpec("GCP-H200-PERPETUAL",         "GCP_H200_HOUR",         455e16);
        s[18] = SeedSpec("AZURE-H200-PERPETUAL",       "AZURE_H200_HOUR",       505e16);
    }
}
