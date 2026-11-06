// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "./MockERC20.sol";
import {Oracle} from "../src/Oracle/Oracle.sol";
import {CuOracle} from "../src/Oracle/CuOracle.sol";
import {CuOracleAdapter} from "../src/Oracle/CuOracleAdapter.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {ClearingHouseLogic} from "../src/ClearingHouseLogic.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";

/// @title DeploySepoliaH100
/// @notice End-to-end Sepolia deployment for the ByteStrike H100-PERP market.
///         Phases 1-4 of the deployment plan: tokens, oracles, core protocol, wiring,
///         market registration, risk params, and oracle commit. Phase 5 (reveal +
///         seed trades + unpause) runs in a separate script after a 1-block delay.
///
/// @dev Required env vars:
///        PRIVATE_KEY        - deployer EOA, must have >= 0.5 Sepolia ETH
///        SEED_LONG_ADDR     - address that will open the seed long
///        SEED_SHORT_ADDR    - address that will open the seed short
///        TREASURY_ADDR      - FeeRouter treasury admin
///        H100_NONCE         - 32-byte unpredictable nonce for the oracle commit
///                             (e.g. `cast keccak $(openssl rand -hex 32)`)
///
/// @dev Audit-driven invariants enforced here:
///        L-05 markets default to paused; risk params set before unpause (Phase 5)
///        L-17 mark price non-zero (1000 H100-hr * $4.22 = $42_200 reserveQuote)
///        L-18 frMaxBpsPerHour = 100, kFundingX18 = 1e18 (both non-zero)
///        I-12 nonce sourced from env var, never hard-coded
///        M-12 seed long+short opened in Phase 5 before unpause
contract DeploySepoliaH100 is Script {

    // ========= Sepolia Chainlink feeds (from DeployConfig.sol) =========
    address constant USDC_USD_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;

    // ========= H100-PERP market parameters (user spec) =========
    bytes32 constant H100_PERP        = keccak256("H100-PERP");
    bytes32 constant H100_ASSET_ID    = keccak256("H100");
    address constant H100_DUMMY_BASE  = 0x0000000000000000000000000000000000000001;

    uint256 constant INITIAL_PRICE_X18    = 4_220_000_000_000_000_000;     // $4.22
    uint256 constant INITIAL_BASE_RESERVE = 10_000e18;                      // 10k H100-hr virtual
    uint128 constant LIQUIDITY            = 1e24;
    uint16  constant FEE_BPS              = 10;                             // 0.1%
    uint256 constant FR_MAX_BPS_PER_HOUR  = 100;                            // L-18: non-zero
    uint256 constant K_FUNDING_X18        = 1e18;                           // L-18: non-zero
    uint256 constant IMR_BPS              = 1_000;                          // 10% (user spec)
    uint256 constant MMR_BPS              = 500;                            // 5% (user spec)
    uint256 constant LIQ_PENALTY_BPS      = 200;                            // 2%
    uint256 constant LIQ_PENALTY_CAP      = 10_000e18;                      // $10k

    // ========= FeeRouter splits =========
    uint16 constant TRADE_TO_FUND_BPS = 5_000;                              // 50%
    uint16 constant LIQ_TO_FUND_BPS   = 3_000;                              // 30%

    // ========= Token amounts =========
    uint256 constant USDC_DECIMALS         = 6;
    uint256 constant USDC_UNIT             = 1e6;
    uint256 constant DEPLOYER_USDC_MINT    = 1_000_000 * USDC_UNIT;
    uint256 constant SEED_USDC_MINT        = 100_000  * USDC_UNIT;
    uint256 constant INSURANCE_FUND_SEED   = 100_000  * USDC_UNIT;

    // ========= Oracle parameters =========
    uint256 constant CU_ORACLE_MIN_INTERVAL = 1;        // 1s testnet — production should raise
    uint256 constant CU_ORACLE_MAX_AGE      = 12 hours;
    uint256 constant ORACLE_STALE_PERIOD    = 86_400;   // 24h on testnet (slow Sepolia feeds)

    // ========= Collateral params (USDC) =========
    uint16  constant USDC_HAIRCUT_BPS       = 100;             // 1%
    uint16  constant USDC_LIQ_INCENTIVE_BPS = 500;             // 5%
    uint256 constant USDC_GLOBAL_CAP        = 10_000_000 * USDC_UNIT;
    uint256 constant USDC_ACCOUNT_CAP       = 1_000_000  * USDC_UNIT;

    // ========= Deployment artifacts =========
    struct Deployment {
        address deployer;
        address treasury;
        address seedLong;
        address seedShort;
        MockERC20 usdc;
        MockERC20 h100;
        Oracle oracle;
        CuOracle cuOracle;
        CuOracleAdapter h100Adapter;
        MarketRegistry registry;
        CollateralVault vault;
        ClearingHouseLogic chLogic;
        ClearingHouse chImpl;
        ClearingHouse ch;
        InsuranceFund insuranceFund;
        FeeRouter feeRouter;
        vAMM vammImpl;
        vAMM vamm;
    }

    Deployment internal d;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        d.deployer  = vm.addr(deployerPk);
        d.treasury  = vm.envAddress("TREASURY_ADDR");
        d.seedLong  = vm.envAddress("SEED_LONG_ADDR");
        d.seedShort = vm.envAddress("SEED_SHORT_ADDR");
        bytes32 nonce = vm.envBytes32("H100_NONCE");

        require(d.deployer != address(0),  "deployer=0");
        require(d.treasury != address(0),  "TREASURY_ADDR=0");
        require(d.seedLong != address(0),  "SEED_LONG_ADDR=0");
        require(d.seedShort != address(0), "SEED_SHORT_ADDR=0");
        require(d.seedLong != d.seedShort, "seed wallets must differ");
        require(nonce != bytes32(0),       "H100_NONCE=0");

        _logHeader();

        vm.startBroadcast(deployerPk);

        _phase1_tokens();
        _phase2_oracles();
        _phase3_core();
        _phase4_wireAndConfigure(nonce);

        vm.stopBroadcast();

        _writeArtifacts();
        _logFooter(nonce);
    }

    // ============================================================================
    // Phase 1: mock tokens
    // ============================================================================
    function _phase1_tokens() internal {
        d.usdc = new MockERC20("USD Coin", "USDC", uint8(USDC_DECIMALS));
        d.h100 = new MockERC20("H100 Compute Hour", "H100", 18);

        d.usdc.mint(d.deployer,  DEPLOYER_USDC_MINT);
        d.usdc.mint(d.seedLong,  SEED_USDC_MINT);
        d.usdc.mint(d.seedShort, SEED_USDC_MINT);

        console.log("Phase 1 - tokens deployed");
        console.log("  USDC:", address(d.usdc));
        console.log("  H100:", address(d.h100));
    }

    // ============================================================================
    // Phase 2: oracle infrastructure
    // ============================================================================
    function _phase2_oracles() internal {
        // Chainlink-backed Oracle for collateral valuation. Sepolia is L1, no
        // sequencer feed needed (defaults to address(0); the check is skipped).
        d.oracle = new Oracle();
        d.oracle.setPriceFeed("USDC", USDC_USD_FEED);
        d.oracle.setBaseUnit("USDC", USDC_UNIT);
        d.oracle.setPriceStalePeriod(ORACLE_STALE_PERIOD);

        // Commit-reveal oracle for the H100 index price.
        d.cuOracle = new CuOracle(d.deployer, CU_ORACLE_MIN_INTERVAL);
        d.cuOracle.registerAsset(H100_ASSET_ID);

        // Adapter implements IOracle for vAMM consumption. L-01 fix: maxAge is
        // measured against commit time, not reveal time.
        d.h100Adapter = new CuOracleAdapter(address(d.cuOracle), H100_ASSET_ID, CU_ORACLE_MAX_AGE);

        console.log("Phase 2 - oracles deployed");
        console.log("  Oracle (Chainlink):  ", address(d.oracle));
        console.log("  CuOracle:            ", address(d.cuOracle));
        console.log("  CuOracleAdapter H100:", address(d.h100Adapter));
    }

    // ============================================================================
    // Phase 3: core protocol
    // ============================================================================
    function _phase3_core() internal {
        // Registry first (no dependencies). Deployer auto-gets DEFAULT_ADMIN_ROLE
        // which is sufficient for addMarket/pauseMarket via onlyAllowed.
        d.registry = new MarketRegistry();

        // Vault (no constructor deps; setOracle now, setClearinghouse later in wiring).
        d.vault = new CollateralVault();
        d.vault.setOracle(address(d.oracle));

        // ClearingHouse logic + impl + UUPS proxy. Slots 0-10 of logic mirror impl.
        d.chLogic = new ClearingHouseLogic();
        d.chImpl  = new ClearingHouse(address(d.chLogic));
        bytes memory chInit = abi.encodeCall(
            ClearingHouse.initialize,
            (address(d.vault), address(d.registry), d.deployer)
        );
        d.ch = ClearingHouse(address(new ERC1967Proxy(address(d.chImpl), chInit)));

        // InsuranceFund - passing CH at construction auto-authorizes it via
        // _authorized[clearinghouse_] = true (audit-fix wired in constructor).
        d.insuranceFund = new InsuranceFund(address(d.usdc), address(d.ch));

        // FeeRouter - post-audit constructor REQUIRES non-zero CH (FR: CH=0).
        d.feeRouter = new FeeRouter(
            address(d.usdc),
            address(d.insuranceFund),
            d.treasury,
            address(d.ch),
            TRADE_TO_FUND_BPS,
            LIQ_TO_FUND_BPS
        );

        // vAMM impl + UUPS proxy. The vAMM init reads the oracle via try/catch:
        // since CuOracle has no revealed price yet, the catch fires and seeds
        // _cachedIndexPriceX18 with INITIAL_PRICE_X18 ($4.22). Safe.
        d.vammImpl = new vAMM();
        bytes memory vammInit = abi.encodeCall(
            vAMM.initialize,
            (
                address(d.ch),
                address(d.h100Adapter),
                INITIAL_PRICE_X18,
                INITIAL_BASE_RESERVE,
                LIQUIDITY,
                FEE_BPS,
                FR_MAX_BPS_PER_HOUR,
                K_FUNDING_X18
            )
        );
        d.vamm = vAMM(address(new ERC1967Proxy(address(d.vammImpl), vammInit)));

        console.log("Phase 3 - core protocol deployed");
        console.log("  MarketRegistry:    ", address(d.registry));
        console.log("  CollateralVault:   ", address(d.vault));
        console.log("  ClearingHouseLogic:", address(d.chLogic));
        console.log("  ClearingHouse impl:", address(d.chImpl));
        console.log("  ClearingHouse:     ", address(d.ch));
        console.log("  InsuranceFund:     ", address(d.insuranceFund));
        console.log("  FeeRouter:         ", address(d.feeRouter));
        console.log("  vAMM impl:         ", address(d.vammImpl));
        console.log("  vAMM (H100-PERP):  ", address(d.vamm));
    }

    // ============================================================================
    // Phase 4: wire dependencies, register collateral & market, set risk params,
    //          commit oracle price, fund insurance fund.
    // ============================================================================
    function _phase4_wireAndConfigure(bytes32 nonce) internal {
        // 4.1 wire mutual references
        d.vault.setClearinghouse(address(d.ch));            // one-shot
        d.vamm.setRegistry(address(d.registry));            // enables pauseSwaps
        d.insuranceFund.setFeeRouter(address(d.feeRouter), true);
        // setAuthorized(ch, true) already happened in IF constructor

        // 4.2 register USDC as collateral (1% haircut, 5% liq incentive)
        d.vault.registerCollateral(ICollateralVault.CollateralConfig({
            token:           address(d.usdc),
            baseUnit:        USDC_UNIT,
            haircutBps:      USDC_HAIRCUT_BPS,
            liqIncentiveBps: USDC_LIQ_INCENTIVE_BPS,
            cap:             USDC_GLOBAL_CAP,
            accountCap:      USDC_ACCOUNT_CAP,
            enabled:         true,
            depositPaused:   false,
            withdrawPaused:  false,
            oracleSymbol:    "USDC"
        }));

        // 4.3 add H100-PERP to MarketRegistry (audit L-05: defaults to paused)
        d.registry.addMarket(IMarketRegistry.AddMarketConfig({
            marketId:      H100_PERP,
            vamm:          address(d.vamm),
            oracle:        address(d.h100Adapter),
            baseAsset:     H100_DUMMY_BASE,
            quoteToken:    address(d.usdc),
            baseUnit:      1e18,
            feeBps:        FEE_BPS,
            feeRouter:     address(d.feeRouter),
            insuranceFund: address(d.insuranceFund)
        }));

        // 4.4 set risk params (audit L-05 fix: openPosition requires mmrBps > 0)
        d.ch.setRiskParams(
            H100_PERP,
            IMR_BPS,         // 1000 = 10%
            MMR_BPS,         // 500  =  5%
            LIQ_PENALTY_BPS, // 200  =  2%
            LIQ_PENALTY_CAP, // $10k
            0,               // maxPositionSize: unlimited (testnet)
            0                // minPositionSize: 0 (allow tiny test positions)
        );

        // 4.5 commit H100 index price = $4.22 with caller-supplied random nonce
        bytes32 commitment = keccak256(abi.encodePacked(INITIAL_PRICE_X18, nonce));
        d.cuOracle.commitPrice(H100_ASSET_ID, commitment);

        // 4.6 seed the insurance fund via donate() so _totalReceived is tracked
        d.usdc.approve(address(d.insuranceFund), INSURANCE_FUND_SEED);
        d.insuranceFund.donate(INSURANCE_FUND_SEED);

        console.log("Phase 4 - configuration complete");
        console.log("  Collateral registered, market added (paused), risk params set");
        console.log("  Oracle commit posted, insurance fund seeded with 100k USDC");
    }

    // ============================================================================
    // Output: write addresses to deployments/sepolia.json for Phase 5 + tooling
    // ============================================================================
    function _writeArtifacts() internal {
        string memory key = "sepolia";
        vm.serializeAddress(key, "deployer",        d.deployer);
        vm.serializeAddress(key, "treasury",        d.treasury);
        vm.serializeAddress(key, "seedLong",        d.seedLong);
        vm.serializeAddress(key, "seedShort",       d.seedShort);
        vm.serializeAddress(key, "usdc",            address(d.usdc));
        vm.serializeAddress(key, "h100",            address(d.h100));
        vm.serializeAddress(key, "oracle",          address(d.oracle));
        vm.serializeAddress(key, "cuOracle",        address(d.cuOracle));
        vm.serializeAddress(key, "h100Adapter",     address(d.h100Adapter));
        vm.serializeAddress(key, "registry",        address(d.registry));
        vm.serializeAddress(key, "vault",           address(d.vault));
        vm.serializeAddress(key, "chLogic",         address(d.chLogic));
        vm.serializeAddress(key, "chImpl",          address(d.chImpl));
        vm.serializeAddress(key, "clearingHouse",   address(d.ch));
        vm.serializeAddress(key, "insuranceFund",   address(d.insuranceFund));
        vm.serializeAddress(key, "feeRouter",       address(d.feeRouter));
        vm.serializeAddress(key, "vammImpl",        address(d.vammImpl));
        string memory final_ = vm.serializeAddress(key, "vamm", address(d.vamm));

        vm.writeJson(final_, "./deployments/sepolia.json");
        console.log("Wrote deployments/sepolia.json");
    }

    function _logHeader() internal view {
        console.log("============================================");
        console.log(" ByteStrike Sepolia H100-PERP Deployment");
        console.log("============================================");
        console.log("Deployer:    ", d.deployer);
        console.log("Treasury:    ", d.treasury);
        console.log("Seed long:   ", d.seedLong);
        console.log("Seed short:  ", d.seedShort);
        console.log("Initial mark/index: $4.22 (4220000000000000000)");
        console.log("IMR / MMR:    10% / 5%");
        console.log("");
    }

    function _logFooter(bytes32 nonce) internal view {
        console.log("");
        console.log("============================================");
        console.log(" Phase 1-4 complete. Market is PAUSED.");
        console.log("============================================");
        console.log("Next steps:");
        console.log(" 1. Wait for at least 1 block (CuOracle minCommitRevealDelay).");
        console.log(" 2. Run script/SeedAndUnpauseH100.s.sol with the SAME H100_NONCE:");
        console.log("    forge script script/SeedAndUnpauseH100.s.sol \\");
        console.log("      --rpc-url sepolia --broadcast --legacy");
        console.log("");
        console.log(" Nonce in use (do NOT reuse for future commits):");
        console.logBytes32(nonce);
        console.log("============================================");
    }
}
