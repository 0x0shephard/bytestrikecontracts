// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CuOracle} from "../src/Oracle/CuOracle.sol";
import {CuOracleAdapter} from "../src/Oracle/CuOracleAdapter.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployH100Market
/// @notice Deploys an H100-PERP perpetual market on BattleChain testnet.
///
/// Uses the existing CuOracle, MarketRegistry, ClearingHouse, InsuranceFund,
/// FeeRouter, and vAMM implementation — only new contracts are the H100 token,
/// a CuOracleAdapter for H100, and a new vAMM proxy.
///
/// Run:
///   forge script script/DeployH100Market.s.sol \
///     --rpc-url battlechain_testnet \
///     --broadcast \
///     --legacy
///
/// After broadcast, reveal the oracle price with:
///   cast send 0x2E3f3D9aC763C3c7D8F5A9D6A94dD745D76D9e8f \
///     "updatePrices(bytes32,uint256,bytes32)" \
///     <H100_ASSET_ID> 3000000000000000000 <NONCE> \
///     --rpc-url $BATTLECHAIN_RPC_URL --private-key $PRIVATE_KEY --legacy
contract DeployH100Market is Script {
    // ── Existing deployed contracts ──────────────────────────────────────────
    CuOracle constant CU_ORACLE        = CuOracle(0x2E3f3D9aC763C3c7D8F5A9D6A94dD745D76D9e8f);
    MarketRegistry constant REGISTRY   = MarketRegistry(0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F);
    ClearingHouse constant CH          = ClearingHouse(payable(0x79299Dc44AFEC5e816d7EFD89f698Eca8Efb305c));
    // quoteToken must match what FeeRouter was deployed with
    address constant USDC              = 0x5033F54b2d97Bdbf21886bd311773E9b2B17bD98;
    // Dummy base asset — MarketRegistry only checks non-zero and != quoteToken
    address constant H100_DUMMY_BASE   = 0x0000000000000000000000000000000000000001;
    address constant INSURANCE_FUND    = 0x7bb834d07f8bB95E0DCad864943De2E4D5fB00E9;
    address constant FEE_ROUTER        = 0x63aE79E8D02Bb7F6f048Fa8B0543BAf44305a862;
    address constant VAMM_IMPL         = 0x6c9e72A4aFAc084d733B2D0d70d7ef3EB6E5450e;

    // ── H100-PERP market identifiers ─────────────────────────────────────────
    bytes32 constant H100_PERP     = keccak256("H100-PERP");
    bytes32 constant H100_ASSET_ID = keccak256("H100");

    // ── Market parameters ────────────────────────────────────────────────────
    uint256 constant INITIAL_PRICE        = 3e18;       // $3.00 per H100 hour
    uint256 constant INITIAL_BASE_RESERVE = 1_000e18;   // 1,000 H100 virtual reserve
    uint128 constant LIQUIDITY            = 1e24;
    uint16  constant FEE_BPS              = 10;          // 0.1% trade fee
    uint256 constant FR_MAX_BPS_PER_HOUR  = 100;         // 1% max funding/hr
    uint256 constant K_FUNDING_X18        = 1e18;
    uint256 constant IMR_BPS              = 1_000;       // 10% initial margin
    uint256 constant MMR_BPS              = 500;         // 5% maintenance margin
    uint256 constant LIQ_PENALTY_BPS      = 200;         // 2% liquidation penalty
    // aderyn-ignore-next-line(large-numeric-literal)
    uint256 constant LIQ_PENALTY_CAP      = 10_000e18;  // $10,000 cap

    // ── Oracle seeding nonce ─────────────────────────────────────────────────
    bytes32 constant SEED_NONCE = keccak256("h100-seed-v1");

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        bytes32 commitment = keccak256(abi.encodePacked(INITIAL_PRICE, SEED_NONCE));

        console.log("Deploying H100-PERP market");
        console.log("Deployer:      ", deployer);
        console.log("H100-PERP ID:  ", vm.toString(H100_PERP));
        console.log("H100_ASSET_ID: ", vm.toString(H100_ASSET_ID));
        console.log("Commitment:    ", vm.toString(commitment));
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Register H100 in existing CuOracle (onlyOwner)
        CU_ORACLE.registerAsset(H100_ASSET_ID);
        console.log("H100 asset registered in CuOracle");

        // 2. Commit index price ($3.00) — reveal must happen after minCommitRevealDelay (1s)
        CU_ORACLE.commitPrice(H100_ASSET_ID, commitment);
        console.log("H100 price committed (reveal separately after 1s)");

        // 3. CuOracleAdapter for H100 (maxAge=0 disables staleness check on testnet)
        CuOracleAdapter h100Adapter = new CuOracleAdapter(address(CU_ORACLE), H100_ASSET_ID, 0);
        console.log("H100 CuOracleAdapter: ", address(h100Adapter));

        // 4. New vAMM proxy — reuses the existing vAMM impl, fresh storage/state
        bytes memory vammInit = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(CH),
            address(h100Adapter),
            INITIAL_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY,
            FEE_BPS,
            FR_MAX_BPS_PER_HOUR,
            K_FUNDING_X18
        );
        ERC1967Proxy h100VammProxy = new ERC1967Proxy(VAMM_IMPL, vammInit);
        vAMM h100Vamm = vAMM(address(h100VammProxy));
        console.log("H100-PERP vAMM:      ", address(h100Vamm));

        // 5. Register H100-PERP in MarketRegistry
        REGISTRY.addMarket(IMarketRegistry.AddMarketConfig({
            marketId:      H100_PERP,
            vamm:          address(h100Vamm),
            oracle:        address(h100Adapter),
            baseAsset:     H100_DUMMY_BASE,
            quoteToken:    USDC,
            baseUnit:      1e18,
            feeBps:        FEE_BPS,
            feeRouter:     FEE_ROUTER,
            insuranceFund: INSURANCE_FUND
        }));
        console.log("H100-PERP market registered");

        // 6. Risk parameters: IMR=10%, MMR=5%
        CH.setRiskParams(
            H100_PERP,
            IMR_BPS,
            MMR_BPS,
            LIQ_PENALTY_BPS,
            LIQ_PENALTY_CAP,
            0,  // maxPositionSize: unlimited
            0   // minPositionSize: none
        );
        console.log("Risk params: IMR=10% MMR=5% penalty=2%");

        // 7. Wire vAMM to MarketRegistry (enables pauseSwaps)
        h100Vamm.setRegistry(address(REGISTRY));
        console.log("vAMM registry wired");

        vm.stopBroadcast();

        console.log("\n========================================");
        console.log("H100-PERP deployment complete");
        console.log("========================================");
        console.log("H100 baseAsset:  ", H100_DUMMY_BASE);
        console.log("H100 adapter:    ", address(h100Adapter));
        console.log("H100-PERP vAMM:  ", address(h100Vamm));
        console.log("========================================");
        console.log("NEXT: reveal oracle price with cast send:");
        console.log("  updatePrices(bytes32,uint256,bytes32)");
        console.log("  assetId:", vm.toString(H100_ASSET_ID));
        console.log("  price:  3000000000000000000");
        console.log("  nonce: ", vm.toString(SEED_NONCE));
        console.log("========================================\n");
    }
}
