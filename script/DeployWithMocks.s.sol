// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockOracle} from "../test/mocks/MockOracle.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {vAMM} from "../src/vAMM.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title Deploy Protocol with Mock Oracle
/// @notice Simplified deployment script using MockOracle instead of Chainlink
/// @dev This is useful for testing and local development
contract DeployWithMocks is Script {
    // Deployed contract instances
    MockERC20 public quoteToken;
    MockERC20 public baseToken;
    MockOracle public oracle;
    CollateralVault public vault;
    MarketRegistry public marketRegistry;
    ClearingHouse public clearingHouse;
    vAMM public vamm;
    FeeRouter public feeRouter;
    InsuranceFund public insuranceFund;

    // Configuration
    address public treasury;
    address public admin;
    uint256 public initialOraclePriceX18;
    uint256 public initialBaseReserve;
    uint128 public liquidityIndex;
    uint16 public tradeFeeBps;
    uint256 public fundingMaxBpsPerHour;
    uint256 public fundingKx18;
    uint32 public observationWindow;
    uint16 public insuranceFundTradeFeeShareBps;
    uint16 public insuranceFundLiqShareBps;
    uint256 public imrBps;
    uint256 public mmrBps;
    uint16 public liquidationPenaltyBps;
    uint256 public penaltyCap;
    bytes32 public constant ETH_PERP_MARKET_ID = keccak256("ETH-PERP");

    function run() external {
        admin = vm.envOr("ADMIN_ADDRESS", tx.origin);
        treasury = vm.envOr("TREASURY_ADDRESS", tx.origin);
        initialOraclePriceX18 = vm.envOr("INITIAL_ORACLE_PRICE_X18", uint256(2000 * 1e18)); // $2000
        initialBaseReserve = vm.envOr("INITIAL_BASE_RESERVE", uint256(1000 * 1e18)); // 1000 ETH
        liquidityIndex = uint128(vm.envOr("INITIAL_LIQUIDITY_INDEX", uint256(1e24)));
        tradeFeeBps = uint16(vm.envOr("TRADE_FEE_BPS", uint256(10))); // 0.1%
        fundingMaxBpsPerHour = vm.envOr("FUNDING_MAX_BPS_PER_HOUR", uint256(100)); // 1% max per hour
        fundingKx18 = vm.envOr("FUNDING_K_X18", uint256(1e18));
        observationWindow = uint32(vm.envOr("OBSERVATION_WINDOW", uint256(3600))); // 1 hour
        insuranceFundTradeFeeShareBps = uint16(vm.envOr("FEE_ROUTER_TRADE_FEE_TO_INSURANCE_BPS", uint256(5000))); // 50%
        insuranceFundLiqShareBps = uint16(vm.envOr("FEE_ROUTER_LIQ_PENALTY_TO_INSURANCE_BPS", uint256(5000))); // 50%
        imrBps = vm.envOr("IMR_BPS", uint256(500)); // 5%
        mmrBps = vm.envOr("MMR_BPS", uint256(250)); // 2.5%
        liquidationPenaltyBps = uint16(vm.envOr("LIQUIDATION_PENALTY_BPS", uint256(200))); // 2%
        penaltyCap = vm.envOr("PENALTY_CAP", uint256(10000 * 1e6)); // 10k USDC

        require(admin != address(0), "ADMIN=0");
        require(treasury != address(0), "TREASURY=0");

        vm.startBroadcast();

        console.log("=== ByteStrike Deployment with Mocks ===");
        console.log("Admin:", admin);
        console.log("Treasury:", treasury);
        console.log("Initial ETH price:", initialOraclePriceX18 / 1e18, "USD");
        console.log("Initial base reserve:", initialBaseReserve / 1e18, "ETH");
        console.log("");

        // 1. Deploy Mock Dependencies
        console.log("1. Deploying Mock Tokens and Oracle...");
        quoteToken = new MockERC20("Mock USDC", "mUSDC", 6);
        baseToken = new MockERC20("Mock WETH", "mWETH", 18);
        oracle = new MockOracle(initialOraclePriceX18, 18);
        oracle.setSymbol("ETH");

        console.log("Quote Token (mUSDC) deployed at:", address(quoteToken));
        console.log("Base Token (mWETH) deployed at:", address(baseToken));
        console.log("MockOracle deployed at:", address(oracle));
        console.log("");

        // Mint some tokens for testing
        quoteToken.mint(admin, 1_000_000 * 1e6); // 1M USDC
        baseToken.mint(admin, 1000 * 1e18); // 1000 ETH
        console.log("Minted test tokens to admin");
        console.log("");

        // 2. Deploy Core Infrastructure
        console.log("2. Deploying Core Infrastructure...");
        vault = new CollateralVault();
        vault.setOracle(address(oracle));
        marketRegistry = new MarketRegistry();

        ClearingHouse clearingHouseImplementation = new ClearingHouse();
        bytes memory clearingHouseInitData = abi.encodeCall(
            ClearingHouse.initialize,
            (address(vault), address(marketRegistry), admin)
        );
        ERC1967Proxy clearingHouseProxy = new ERC1967Proxy(
            address(clearingHouseImplementation),
            clearingHouseInitData
        );
        clearingHouse = ClearingHouse(address(clearingHouseProxy));

        console.log("CollateralVault deployed at:", address(vault));
        console.log("MarketRegistry deployed at:", address(marketRegistry));
        console.log("ClearingHouse implementation at:", address(clearingHouseImplementation));
        console.log("ClearingHouse proxy at:", address(clearingHouse));
        console.log("");

        // 3. Deploy Market-Specific Components
        console.log("3. Deploying Market Components...");
        vAMM vammImplementation = new vAMM();
        bytes memory vammInitData = abi.encodeCall(
            vAMM.initialize,
            (
                address(clearingHouse),
                address(oracle),
                initialOraclePriceX18,
                initialBaseReserve,
                liquidityIndex,
                tradeFeeBps,
                fundingMaxBpsPerHour,
                fundingKx18,
                observationWindow
            )
        );
        ERC1967Proxy vammProxy = new ERC1967Proxy(address(vammImplementation), vammInitData);
        vamm = vAMM(address(vammProxy));

        insuranceFund = new InsuranceFund(address(quoteToken), address(clearingHouse));

        feeRouter = new FeeRouter(
            address(quoteToken),
            address(insuranceFund),
            treasury,
            address(clearingHouse),
            insuranceFundTradeFeeShareBps,
            insuranceFundLiqShareBps
        );

        console.log("vAMM implementation at:", address(vammImplementation));
        console.log("vAMM proxy at:", address(vamm));
        console.log("InsuranceFund at:", address(insuranceFund));
        console.log("FeeRouter at:", address(feeRouter));
        console.log("");

        // 4. Configure and Wire Contracts
        console.log("4. Configuring Permissions...");

        // Register quote token as collateral
        vault.registerCollateral(
            ICollateralVault.CollateralConfig({
                token: address(quoteToken),
                baseUnit: 1e6,
                haircutBps: 0,
                liqIncentiveBps: liquidationPenaltyBps,
                cap: type(uint256).max,
                accountCap: type(uint256).max,
                enabled: true,
                depositPaused: false,
                withdrawPaused: false,
                oracleSymbol: "USDC"
            })
        );
        console.log("Registered USDC as collateral");

        insuranceFund.setFeeRouter(address(feeRouter), true);
        insuranceFund.setAuthorized(address(clearingHouse), true);
        console.log("Configured InsuranceFund");

        vault.setClearinghouse(address(clearingHouse));
        console.log("Wired Vault to ClearingHouse");

        marketRegistry.grantRole(marketRegistry.MARKET_ADMIN_ROLE(), admin);
        console.log("Granted MARKET_ADMIN_ROLE to admin");
        console.log("");

        // 5. Register ETH-PERP Market
        console.log("5. Registering ETH-PERP market...");
        IMarketRegistry.AddMarketConfig memory marketConfig = IMarketRegistry.AddMarketConfig({
            marketId: ETH_PERP_MARKET_ID,
            vamm: address(vamm),
            oracle: address(oracle),
            baseAsset: address(baseToken),
            quoteToken: address(quoteToken),
            baseUnit: 1e18,
            feeBps: tradeFeeBps,
            feeRouter: address(feeRouter),
            insuranceFund: address(insuranceFund)
        });
        marketRegistry.addMarket(marketConfig);
        console.log("ETH-PERP market registered");
        console.log("");

        // 6. Set Risk Parameters
        console.log("6. Setting risk parameters...");
        clearingHouse.setRiskParams(
            ETH_PERP_MARKET_ID,
            imrBps,
            mmrBps,
            uint256(liquidationPenaltyBps),
            penaltyCap,
            0, // maxPositionSize (unlimited)
            0  // minPositionSize (no minimum)
        );
        console.log("Risk parameters set");
        console.log("");

        vm.stopBroadcast();

        // Print summary
        console.log("=== Deployment Complete ===");
        console.log("");
        console.log("Core Contracts:");
        console.log("  Oracle:", address(oracle));
        console.log("  MarketRegistry:", address(marketRegistry));
        console.log("  CollateralVault:", address(vault));
        console.log("  ClearingHouse:", address(clearingHouse));
        console.log("  InsuranceFund:", address(insuranceFund));
        console.log("  FeeRouter:", address(feeRouter));
        console.log("");
        console.log("Market:");
        console.log("  ETH-PERP vAMM:", address(vamm));
        console.log("  Market ID:", vm.toString(ETH_PERP_MARKET_ID));
        console.log("  Initial Price:", initialOraclePriceX18 / 1e18, "USD");
        console.log("");
        console.log("Tokens:");
        console.log("  Quote (mUSDC):", address(quoteToken));
        console.log("  Base (mWETH):", address(baseToken));
        console.log("");
        console.log("To update oracle price:");
        console.log("  cast send", address(oracle), '"setPrice(uint256)" <newPrice>');
        console.log("");
        console.log("Example: Set ETH to $2500:");
        console.log("  cast send", address(oracle), '"setPrice(uint256)" 2500000000000000000000');
    }
}
