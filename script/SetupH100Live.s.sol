// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockOracle} from "../test/mocks/MockOracle.sol";
import {CuOracleAdapter} from "../src/Oracle/CuOracleAdapter.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {vAMM} from "../src/vAMM.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title SetupH100Live
/// @notice Sets up a fully tradeable H100-PERP-LIVE market and opens a test position.
///
/// Fixes the "dead USDC" problem from the original deployment by:
///   1. Using the working MockERC20 at USDC_LIVE as the quoteToken
///   2. Deploying a fresh MockOracle for vault collateral pricing
///   3. Deploying new InsuranceFund + FeeRouter referencing USDC_LIVE
///   4. Deploying a new vAMM proxy (reusing existing impl)
///   5. Registering the new H100-PERP-LIVE market
///   6. Depositing collateral and opening a long position
///
/// Run:
///   forge script script/SetupH100Live.s.sol \
///     --rpc-url battlechain_testnet \
///     --broadcast \
///     --legacy
contract SetupH100Live is Script {

    // ── Existing deployed contracts ───────────────────────────────────────────
    address constant USDC_LIVE      = 0x445Fa8890562Ec6220A60b3911C692DffaD49AcB;
    address constant VAULT          = 0x5eb81A19Bc42CA3Fb034C5250EbFC00E4D0F3a7e;
    address constant CH             = 0x79299Dc44AFEC5e816d7EFD89f698Eca8Efb305c;
    address constant REGISTRY       = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F;
    address constant VAMM_IMPL      = 0x6c9e72A4aFAc084d733B2D0d70d7ef3EB6E5450e;
    address constant H100_ADAPTER   = 0x4719869E2EceaADa61536906eeE68d483C6acABc;
    address constant H100_DUMMY_BASE = 0x0000000000000000000000000000000000000001;

    // ── H100-PERP-LIVE market ────────────────────────────────────────────────
    bytes32 constant H100_PERP_LIVE = keccak256("H100-PERP-LIVE");

    // ── Market parameters ───────────────────────────────────────────────────
    uint256 constant INITIAL_PRICE        = 3e18;
    uint256 constant INITIAL_BASE_RESERVE = 1_000e18;
    uint128 constant LIQUIDITY            = 1e24;
    uint16  constant FEE_BPS              = 10;
    uint256 constant FR_MAX_BPS_PER_HOUR  = 100;
    uint256 constant K_FUNDING_X18        = 1e18;
    uint16  constant TRADE_TO_FUND_BPS    = 5_000;
    uint16  constant LIQ_TO_FUND_BPS      = 3_000;
    uint256 constant IMR_BPS              = 1_000;
    uint256 constant MMR_BPS              = 500;
    uint256 constant LIQ_PENALTY_BPS      = 200;
    // aderyn-ignore-next-line(large-numeric-literal)
    uint256 constant LIQ_PENALTY_CAP      = 10_000e18;

    // ── Position parameters ─────────────────────────────────────────────────
    uint256 constant DEPOSIT_AMOUNT  = 10_000e6;  // 10,000 USDC (6 decimals)
    uint128 constant POSITION_SIZE   = 1e18;       // 1 H100 GPU hour

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== SetupH100Live ===");
        console.log("Deployer:", deployer);
        console.log("H100-PERP-LIVE ID:", vm.toString(H100_PERP_LIVE));

        vm.startBroadcast(deployerPrivateKey);

        // ── 1. Mint USDC to deployer ─────────────────────────────────────────
        MockERC20(USDC_LIVE).mint(deployer, DEPOSIT_AMOUNT * 2);  // 20k buffer
        console.log("Minted 20,000 USDC to deployer");

        // ── 2. Deploy fresh MockOracle for vault (USDC = $1.00) ──────────────
        MockOracle vaultOracle = new MockOracle(1e18, 18);
        vaultOracle.setSymbolPrice("USDC", 1e18);
        console.log("VaultOracle deployed:", address(vaultOracle));

        // ── 3. Fix vault oracle ──────────────────────────────────────────────
        CollateralVault(VAULT).setOracle(address(vaultOracle));
        console.log("Vault oracle updated");

        // ── 4. Register USDC_LIVE in vault ───────────────────────────────────
        CollateralVault(VAULT).registerCollateral(ICollateralVault.CollateralConfig({
            token:            USDC_LIVE,
            baseUnit:         1e6,
            haircutBps:       100,
            liqIncentiveBps:  500,
            cap:              10_000_000e6,
            accountCap:       1_000_000e6,
            enabled:          true,
            depositPaused:    false,
            withdrawPaused:   false,
            oracleSymbol:     "USDC"
        }));
        console.log("USDC_LIVE registered in vault");

        // ── 5. Deploy InsuranceFund ──────────────────────────────────────────
        InsuranceFund insuranceFund = new InsuranceFund(USDC_LIVE, CH);
        console.log("InsuranceFund deployed:", address(insuranceFund));

        // ── 6. Deploy FeeRouter ──────────────────────────────────────────────
        FeeRouter feeRouter = new FeeRouter(
            USDC_LIVE,
            address(insuranceFund),
            deployer,
            CH,
            TRADE_TO_FUND_BPS,
            LIQ_TO_FUND_BPS
        );
        insuranceFund.setFeeRouter(address(feeRouter), true);
        console.log("FeeRouter deployed:", address(feeRouter));

        // ── 7. Deploy new vAMM proxy for H100-PERP-LIVE ──────────────────────
        bytes memory vammInit = abi.encodeWithSelector(
            vAMM.initialize.selector,
            CH,
            H100_ADAPTER,
            INITIAL_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY,
            FEE_BPS,
            FR_MAX_BPS_PER_HOUR,
            K_FUNDING_X18
        );
        ERC1967Proxy vammProxy = new ERC1967Proxy(VAMM_IMPL, vammInit);
        vAMM h100Vamm = vAMM(address(vammProxy));
        console.log("H100-PERP-LIVE vAMM deployed:", address(h100Vamm));

        // ── 8. Register H100-PERP-LIVE market ────────────────────────────────
        MarketRegistry(REGISTRY).addMarket(IMarketRegistry.AddMarketConfig({
            marketId:      H100_PERP_LIVE,
            vamm:          address(h100Vamm),
            oracle:        H100_ADAPTER,
            baseAsset:     H100_DUMMY_BASE,
            quoteToken:    USDC_LIVE,
            baseUnit:      1e18,
            feeBps:        FEE_BPS,
            feeRouter:     address(feeRouter),
            insuranceFund: address(insuranceFund)
        }));
        console.log("H100-PERP-LIVE market registered");

        // ── 9. Set risk parameters ───────────────────────────────────────────
        ClearingHouse(payable(CH)).setRiskParams(
            H100_PERP_LIVE,
            IMR_BPS,
            MMR_BPS,
            LIQ_PENALTY_BPS,
            LIQ_PENALTY_CAP,
            0,
            0
        );
        console.log("Risk params set: IMR=10% MMR=5%");

        // ── 10. Wire vAMM to registry ────────────────────────────────────────
        h100Vamm.setRegistry(REGISTRY);
        console.log("vAMM registry wired");

        // ── 11. Approve vault and deposit collateral ─────────────────────────
        IERC20(USDC_LIVE).approve(VAULT, DEPOSIT_AMOUNT);
        ClearingHouse(payable(CH)).deposit(USDC_LIVE, DEPOSIT_AMOUNT);
        console.log("Deposited 10,000 USDC into vault");

        // ── 12. Open long position: 1 H100 GPU hour ──────────────────────────
        ClearingHouse(payable(CH)).openPosition(H100_PERP_LIVE, true, POSITION_SIZE, 0);
        console.log("Opened LONG 1 H100 GPU hour on H100-PERP-LIVE");

        vm.stopBroadcast();

        console.log("\n========================================");
        console.log("H100-PERP-LIVE setup complete!");
        console.log("========================================");
        console.log("VaultOracle:      ", address(vaultOracle));
        console.log("InsuranceFund:    ", address(insuranceFund));
        console.log("FeeRouter:        ", address(feeRouter));
        console.log("H100-PERP-LIVE vAMM:", address(h100Vamm));
        console.log("Market ID:        ", vm.toString(H100_PERP_LIVE));
        console.log("Position:         LONG 1e18 H100 @ ~$3.00");
        console.log("========================================");
    }
}
