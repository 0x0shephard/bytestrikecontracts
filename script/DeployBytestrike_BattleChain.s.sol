// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BCScript } from "battlechain-lib/BCScript.sol";
import { Contact, AgreementDetails } from "battlechain-lib/types/AgreementTypes.sol";
import { IAttackRegistry } from "battlechain-lib/interfaces/IAttackRegistry.sol";
import { console } from "forge-std/console.sol";

import { MockERC20 } from "./MockERC20.sol";
import { MockOracle } from "../test/mocks/MockOracle.sol";
import { CuOracle } from "../src/Oracle/CuOracle.sol";
import { CuOracleAdapter } from "../src/Oracle/CuOracleAdapter.sol";
import { MarketRegistry } from "../src/MarketRegistry.sol";
import { CollateralVault } from "../src/CollateralVault.sol";
import { ClearingHouse } from "../src/ClearingHouse.sol";
import { ClearingHouseLogic } from "../src/ClearingHouseLogic.sol";
import { InsuranceFund } from "../src/InsuranceFund.sol";
import { FeeRouter } from "../src/FeeRouter.sol";
import { vAMM } from "../src/vAMM.sol";
import { ICollateralVault } from "../src/Interfaces/ICollateralVault.sol";
import { IMarketRegistry } from "../src/Interfaces/IMarketRegistry.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployBytestrike_BattleChain
/// @notice Full ByteStrike protocol deployment for BattleChain testnet (chain 627).
///
/// Prerequisites:
///   - Set BATTLECHAIN_RPC_URL and PRIVATE_KEY in your environment.
///
/// Run:
///   forge script script/DeployBytestrike_BattleChain.s.sol \
///     --rpc-url battlechain_testnet \
///     --broadcast \
///     --skip-simulation \
///     --legacy
///
/// Oracles:
///   - CollateralVault uses MockOracle with USDC price = 1e18 ($1.00).
///   - vAMM uses CuOracle (commit/reveal) + CuOracleAdapter. The deployer must
///     call commitPrice + updatePrices on CuOracle after deployment before trading.
///
/// @dev Uses `new Contract()` so the broadcaster EOA retains admin/ownership for
///      post-deployment wiring. BCScript is used for Safe Harbor + attack mode only.
contract DeployBytestrike_BattleChain is BCScript {
    // -------------------------------------------------------------------------
    // BCScript hooks
    // -------------------------------------------------------------------------

    function _protocolName() internal pure override returns (string memory) {
        return "ByteStrike";
    }

    function _contacts() internal pure override returns (Contact[] memory) {
        Contact[] memory contacts = new Contact[](1);
        contacts[0] = Contact({ name: "ByteStrike Security", contact: "security@bytestrike.io" });
        return contacts;
    }

    function _recoveryAddress() internal view override returns (address) {
        return msg.sender;
    }

    // -------------------------------------------------------------------------
    // Deployment parameters
    // -------------------------------------------------------------------------

    /// CU/USDC initial mark price: $3.00 per compute unit (1e18 format)
    uint256 constant INITIAL_CU_PRICE = 3e18;
    /// Virtual base reserve: 1,000 CU
    uint256 constant INITIAL_BASE_RESERVE = 1_000e18;
    /// vAMM liquidity denominator
    uint128 constant LIQUIDITY = 1e24;
    /// Trade fee: 0.1%
    uint16 constant FEE_BPS = 10;
    /// Max funding rate per hour: 1%
    uint256 constant FR_MAX_BPS_PER_HOUR = 100;
    /// Funding scaling factor: 1.0
    uint256 constant K_FUNDING_X18 = 1e18;
    /// 50% of trade fees go to insurance fund
    uint16 constant TRADE_TO_FUND_BPS = 5_000;
    /// 30% of liquidation penalties go to insurance fund
    uint16 constant LIQ_TO_FUND_BPS = 3_000;
    /// Initial margin requirement: 5%
    uint256 constant IMR_BPS = 500;
    /// Maintenance margin requirement: 2.5%
    uint256 constant MMR_BPS = 250;
    /// Liquidation penalty: 2%
    uint256 constant LIQ_PENALTY_BPS = 200;
    /// Liquidation penalty cap: $10,000
    // aderyn-ignore-next-line(large-numeric-literal)
    uint256 constant LIQ_PENALTY_CAP = 10_000e18;

    /// CU-PERP market identifier
    bytes32 constant CU_PERP = keccak256("CU-PERP");
    /// CuOracle asset identifier for GPU compute units
    bytes32 constant CU_ASSET_ID = keccak256("CU");

    // -------------------------------------------------------------------------
    // run()
    // -------------------------------------------------------------------------

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // ===== 1. Mock tokens =====
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        console.log("USDC deployed at:", address(usdc));

        // Base asset token for CU-PERP — MarketRegistry requires baseAsset != address(0).
        MockERC20 cuToken = new MockERC20("Compute Unit", "CU", 18);
        console.log("CU token deployed at:", address(cuToken));

        // ===== 2. MockOracle (CollateralVault token pricing) =====
        // USDC = $1.00 in 1e18 format. CollateralVault calls getPrice("USDC").
        MockOracle vaultOracle = new MockOracle(1e18, 18);
        vaultOracle.setSymbolPrice("USDC", 1e18);
        console.log("VaultOracle (MockOracle) deployed at:", address(vaultOracle));

        // ===== 3. CuOracle (commit/reveal, GPU compute unit index price) =====
        // minTimeInterval = 1 second for testnet flexibility.
        CuOracle cuOracle = new CuOracle(deployer, 1);
        cuOracle.registerAsset(CU_ASSET_ID);
        console.log("CuOracle deployed at:", address(cuOracle));

        // ===== 4. CuOracleAdapter (IOracle wrapper for vAMM) =====
        // maxAge = 0 disables staleness check on testnet.
        CuOracleAdapter cuAdapter = new CuOracleAdapter(address(cuOracle), CU_ASSET_ID, 0);
        console.log("CuOracleAdapter deployed at:", address(cuAdapter));

        // ===== 5. MarketRegistry =====
        MarketRegistry marketRegistry = new MarketRegistry();
        console.log("MarketRegistry deployed at:", address(marketRegistry));

        // ===== 6. CollateralVault =====
        CollateralVault vault = new CollateralVault();
        vault.setOracle(address(vaultOracle));
        console.log("CollateralVault deployed at:", address(vault));

        // ===== 7. ClearingHouse (UUPS proxy) =====
        // Deploy logic contract first — ClearingHouse constructor requires its address.
        ClearingHouseLogic chLogic = new ClearingHouseLogic();
        console.log("ClearingHouseLogic deployed at:", address(chLogic));

        ClearingHouse chImpl = new ClearingHouse(address(chLogic));
        bytes memory chInit = abi.encodeWithSelector(
            ClearingHouse.initialize.selector,
            address(vault),
            address(marketRegistry),
            deployer      // explicit admin — independent of msg.sender in initializer
        );
        ERC1967Proxy chProxy = new ERC1967Proxy(address(chImpl), chInit);
        ClearingHouse clearingHouse = ClearingHouse(address(chProxy));
        console.log("ClearingHouse impl deployed at:", address(chImpl));
        console.log("ClearingHouse proxy deployed at:", address(clearingHouse));

        // ===== 8. InsuranceFund =====
        InsuranceFund insuranceFund = new InsuranceFund(address(usdc), address(clearingHouse));
        console.log("InsuranceFund deployed at:", address(insuranceFund));

        // ===== 9. FeeRouter =====
        FeeRouter feeRouter = new FeeRouter(
            address(usdc),
            address(insuranceFund),
            deployer,
            address(clearingHouse),
            TRADE_TO_FUND_BPS,
            LIQ_TO_FUND_BPS
        );
        insuranceFund.setFeeRouter(address(feeRouter), true);
        console.log("FeeRouter deployed at:", address(feeRouter));

        // ===== 10. vAMM (UUPS proxy) =====
        // Oracle = CuOracleAdapter (wraps CuOracle commit/reveal).
        // The oracle is only consulted at trade/liquidation time, not during init.
        vAMM vammImpl = new vAMM();
        bytes memory vammInit = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(clearingHouse),
            address(cuAdapter),
            INITIAL_CU_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY,
            FEE_BPS,
            FR_MAX_BPS_PER_HOUR,
            K_FUNDING_X18
        );
        ERC1967Proxy vammProxy = new ERC1967Proxy(address(vammImpl), vammInit);
        vAMM vamm = vAMM(address(vammProxy));
        console.log("vAMM impl deployed at:", address(vammImpl));
        console.log("vAMM proxy deployed at:", address(vamm));

        // ===== 11. Wire CollateralVault =====
        vault.setClearinghouse(address(clearingHouse));
        vault.registerCollateral(ICollateralVault.CollateralConfig({
            token: address(usdc),
            baseUnit: 1e6,
            haircutBps: 100,         // 1% haircut on USDC
            liqIncentiveBps: 500,    // 5% liquidation incentive
            cap: 10_000_000e6,       // 10M USDC total cap
            accountCap: 1_000_000e6, // 1M USDC per account
            enabled: true,
            depositPaused: false,
            withdrawPaused: false,
            oracleSymbol: "USDC"
        }));
        console.log("CollateralVault wired and USDC registered");

        // ===== 12. Register CU-PERP market =====
        marketRegistry.addMarket(IMarketRegistry.AddMarketConfig({
            marketId: CU_PERP,
            vamm: address(vamm),
            oracle: address(cuAdapter),
            baseAsset: address(cuToken),
            quoteToken: address(usdc),
            baseUnit: 1e18,
            feeBps: FEE_BPS,
            feeRouter: address(feeRouter),
            insuranceFund: address(insuranceFund)
        }));
        console.log("CU-PERP market registered");

        // ===== 13. Set risk parameters =====
        clearingHouse.setRiskParams(
            CU_PERP,
            IMR_BPS,
            MMR_BPS,
            LIQ_PENALTY_BPS,
            LIQ_PENALTY_CAP,
            0,  // maxPositionSize: unlimited
            0   // minPositionSize: none
        );
        console.log("Risk params set");

        // ===== 14. Grant MarketRegistry sub-roles to deployer =====
        // PARAM_ADMIN_ROLE is required by setMarketParams (onlyRole — DEFAULT_ADMIN alone is not enough).
        // PAUSE_GUARDIAN_ROLE and MARKET_ADMIN_ROLE are covered by DEFAULT_ADMIN but granted
        // explicitly so the deployer holds the canonical roles rather than relying on the admin bypass.
        marketRegistry.grantRole(marketRegistry.PARAM_ADMIN_ROLE(), deployer);
        marketRegistry.grantRole(marketRegistry.PAUSE_GUARDIAN_ROLE(), deployer);
        marketRegistry.grantRole(marketRegistry.MARKET_ADMIN_ROLE(), deployer);
        console.log("MarketRegistry roles granted to deployer");

        // ===== 15. Wire vAMM registry =====
        // registry is address(0) after initialize; MarketRegistry cannot call pauseSwaps without this.
        vamm.setRegistry(address(marketRegistry));
        console.log("vAMM registry set to MarketRegistry");

        // ===== 16. Whitelist deployer as liquidator =====
        clearingHouse.setWhitelistedLiquidator(deployer, true);
        console.log("Deployer whitelisted as liquidator");

        // ===== 17. Safe Harbor agreement =====
        // Scope: core protocol contracts only. Mock tokens and oracles are test
        // scaffolding and are excluded — BattleChain AttackRegistry validates
        // scoped addresses against its deployment registry.
        address[] memory contracts = new address[](7);
        contracts[0] = address(cuOracle);
        contracts[1] = address(cuAdapter);
        contracts[2] = address(marketRegistry);
        contracts[3] = address(vault);
        contracts[4] = address(clearingHouse);
        contracts[5] = address(insuranceFund);
        contracts[6] = address(feeRouter);

        AgreementDetails memory details = defaultAgreementDetails(
            _protocolName(),
            _contacts(),
            contracts,
            _recoveryAddress()
        );

        address agreement = createAndAdoptAgreement(details, deployer, keccak256("bytestrike-v1"));
        console.log("Safe Harbor agreement adopted:", agreement);

        vm.stopBroadcast();

        // ===== 18. Request attack mode (BattleChain only) =====
        // Runs outside broadcast — not a transaction sent by this script.
        // AttackRegistry validates that each scoped contract was deployed through
        // BattleChainDeployer. If contracts were deployed via new Contract() this
        // call may revert — the agreement is still adopted and attack mode can be
        // requested separately via the BattleChain UI or a dedicated script.
        if (_isBattleChain()) {
            try IAttackRegistry(_bcAttackRegistry()).requestUnderAttack(agreement) {
                console.log("Attack mode requested");
            } catch {
                console.log("Attack mode request skipped (contracts not registered with BattleChainDeployer)");
                console.log("Request manually via BattleChain UI with agreement:", agreement);
            }
        }

        // ===== Summary =====
        console.log("\n========================================");
        console.log("ByteStrike BattleChain Deployment Complete");
        console.log("========================================");
        console.log("USDC (mock):         ", address(usdc));
        console.log("CU token (mock):     ", address(cuToken));
        console.log("VaultOracle (mock):  ", address(vaultOracle));
        console.log("CuOracle:            ", address(cuOracle));
        console.log("CuOracleAdapter:     ", address(cuAdapter));
        console.log("MarketRegistry:      ", address(marketRegistry));
        console.log("CollateralVault:     ", address(vault));
        console.log("ClearingHouse impl:  ", address(chImpl));
        console.log("ClearingHouse:       ", address(clearingHouse));
        console.log("InsuranceFund:       ", address(insuranceFund));
        console.log("FeeRouter:           ", address(feeRouter));
        console.log("vAMM impl:           ", address(vammImpl));
        console.log("vAMM:                ", address(vamm));
        console.log("Safe Harbor:         ", agreement);
        console.log("CU_ASSET_ID:         ", vm.toString(CU_ASSET_ID));
        console.log("CU-PERP market ID:   ", vm.toString(CU_PERP));
        console.log("========================================");
        console.log("NOTE: Before trading, call commitPrice + updatePrices");
        console.log("      on CuOracle for asset ID:", vm.toString(CU_ASSET_ID));
        console.log("========================================\n");

        _saveDeployment(
            address(usdc), address(cuToken), address(vaultOracle),
            address(cuOracle), address(cuAdapter),
            address(marketRegistry), address(vault),
            address(chImpl), address(clearingHouse),
            address(insuranceFund), address(feeRouter),
            address(vammImpl), address(vamm), agreement
        );
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _saveDeployment(
        address usdc,
        address cuToken,
        address vaultOracle,
        address cuOracle,
        address cuAdapter,
        address marketRegistry,
        address vault,
        address chImpl,
        address clearingHouse,
        address insuranceFund,
        address feeRouter,
        address vammImpl,
        address vamm,
        address agreement
    ) internal {
        string memory json = "deployment";
        vm.serializeAddress(json, "usdc", usdc);
        vm.serializeAddress(json, "cuToken", cuToken);
        vm.serializeAddress(json, "vaultOracle", vaultOracle);
        vm.serializeAddress(json, "cuOracle", cuOracle);
        vm.serializeAddress(json, "cuOracleAdapter", cuAdapter);
        vm.serializeAddress(json, "marketRegistry", marketRegistry);
        vm.serializeAddress(json, "collateralVault", vault);
        vm.serializeAddress(json, "clearingHouseImpl", chImpl);
        vm.serializeAddress(json, "clearingHouse", clearingHouse);
        vm.serializeAddress(json, "insuranceFund", insuranceFund);
        vm.serializeAddress(json, "feeRouter", feeRouter);
        vm.serializeAddress(json, "vammImpl", vammImpl);
        vm.serializeAddress(json, "vamm", vamm);
        string memory finalJson = vm.serializeAddress(json, "safeHarborAgreement", agreement);
        vm.writeJson(finalJson, "./deployments/battlechain-testnet-deployment.json");
        console.log("Addresses saved to: deployments/battlechain-testnet-deployment.json");
    }
}
