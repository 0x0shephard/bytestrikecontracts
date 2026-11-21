// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

interface IVerifyAccessControl {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IVerifyMarketRegistry is IVerifyAccessControl {
    function MARKET_ADMIN_ROLE() external view returns (bytes32);
    function PARAM_ADMIN_ROLE() external view returns (bytes32);
    function PAUSE_GUARDIAN_ROLE() external view returns (bytes32);
}

interface IVerifyCollateralVault is IVerifyAccessControl {
    function VAULT_ADMIN_ROLE() external view returns (bytes32);
}

interface IVerifyOwnable {
    function owner() external view returns (address);
}

interface IVerifyFeeRouter is IVerifyOwnable {
    function treasuryAdmin() external view returns (address);
}

interface IVerifyCuOracle {
    function owner() external view returns (address);
    function allowedRoles(address account) external view returns (bool);
    function minTimeInterval() external view returns (uint256);
    function minCommitRevealDelay() external view returns (uint256);
    function maxCommitAge() external view returns (uint256);
}

interface IVerifyClearingHouse is IVerifyOwnable {
    function whitelistedLiquidators(address liquidator) external view returns (bool);
}

/// @notice Prints the post-cutover key/role state for evidence and reverts unless the cutover is complete.
/// @dev Required env: MAIN_ADMIN_MULTISIG, ORACLE_ADMIN_MULTISIG, MARKET_IDS (comma-separated bytes32 ids of
///      every market; vAMMs are resolved through MarketRegistry). Asserts ClearingHouse, FeeRouter,
///      InsuranceFund and every vAMM are owned by MAIN_ADMIN_MULTISIG, CuOracle and the collateral Oracle by
///      ORACLE_ADMIN_MULTISIG, and that MAIN_ADMIN_MULTISIG (not OLD_ADMIN) holds the MarketRegistry and
///      CollateralVault admin roles.
contract VerifyProtocolKeyState is Script {
    address internal constant DEFAULT_CLEARING_HOUSE = 0xDf4DDD4019097B335dD507f916984A1A53E40a0d;
    address internal constant DEFAULT_VAULT = 0x44345dFCD97973329A88aaE8c1432ea90525Ed13;
    address internal constant DEFAULT_REGISTRY = 0x236b75D39203506ee3180Ef2E1c7460a188C43c6;
    address internal constant DEFAULT_FEE_ROUTER = 0xBCEA366b30eb1dcAC6968AECcc215E8797553a5e;
    address internal constant DEFAULT_INSURANCE_FUND = 0x132Ba3d3073FDa7440fb0594210C47eC19087eaD;
    address internal constant DEFAULT_CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    address internal constant DEFAULT_COLLATERAL_ORACLE = 0x27F4970bd037c09440823755657c5fcF107532ae;

    function run() external view {
        address oldAdmin = vm.envOr("OLD_ADMIN", address(0xCc624fFA5df1F3F4b30aa8abd30186a86254F406));
        address mainAdmin = vm.envAddress("MAIN_ADMIN_MULTISIG");
        address oracleAdmin = vm.envAddress("ORACLE_ADMIN_MULTISIG");
        address oraclePublisher = vm.envOr("ORACLE_PUBLISHER", address(0));
        address treasury = vm.envOr("TREASURY_MULTISIG", address(0));
        address pauseGuardian = vm.envOr("PAUSE_GUARDIAN_MULTISIG", address(0));
        address riskParamAdmin = vm.envOr("RISK_PARAM_MULTISIG", mainAdmin);
        address liquidator = vm.envOr("NEW_LIQUIDATOR", address(0));

        address clearingHouse = vm.envOr("CLEARING_HOUSE", DEFAULT_CLEARING_HOUSE);
        address vault = vm.envOr("COLLATERAL_VAULT", DEFAULT_VAULT);
        address registry = vm.envOr("MARKET_REGISTRY", DEFAULT_REGISTRY);
        address feeRouter = vm.envOr("FEE_ROUTER", DEFAULT_FEE_ROUTER);
        address insuranceFund = vm.envOr("INSURANCE_FUND", DEFAULT_INSURANCE_FUND);
        address cuOracle = vm.envOr("CU_ORACLE", DEFAULT_CU_ORACLE);
        address collateralOracle = vm.envOr("COLLATERAL_ORACLE", DEFAULT_COLLATERAL_ORACLE);

        console.log("Protocol key state evidence");
        console.log("old admin:", oldAdmin);
        console.log("main admin multisig:", mainAdmin);
        console.log("risk param multisig:", riskParamAdmin);
        console.log("pause guardian multisig:", pauseGuardian);
        console.log("oracle admin multisig:", oracleAdmin);
        console.log("oracle publisher:", oraclePublisher);
        console.log("treasury multisig:", treasury);
        console.log("");

        _printOwners(clearingHouse, feeRouter, insuranceFund, cuOracle, collateralOracle);
        _printRegistry(registry, oldAdmin, mainAdmin, riskParamAdmin, pauseGuardian);
        _printVault(vault, oldAdmin, mainAdmin);
        _printCuOracle(cuOracle, oraclePublisher, oldAdmin);
        _printLiquidator(clearingHouse, liquidator);
        _printVammOwners(registry, mainAdmin, oldAdmin);

        _requireOwnership(clearingHouse, feeRouter, insuranceFund, cuOracle, collateralOracle, mainAdmin, oracleAdmin);
        _requireRoles(registry, vault, oldAdmin, mainAdmin);
        console.log("Cutover end state verified.");
    }

    function _requireOwnership(
        address clearingHouse,
        address feeRouter,
        address insuranceFund,
        address cuOracle,
        address collateralOracle,
        address mainAdmin,
        address oracleAdmin
    ) internal view {
        require(IVerifyOwnable(clearingHouse).owner() == mainAdmin, "ClearingHouse owner != main admin");
        require(IVerifyOwnable(feeRouter).owner() == mainAdmin, "FeeRouter owner != main admin");
        require(IVerifyOwnable(insuranceFund).owner() == mainAdmin, "InsuranceFund owner != main admin");
        require(IVerifyCuOracle(cuOracle).owner() == oracleAdmin, "CuOracle owner != oracle admin");
        require(IVerifyOwnable(collateralOracle).owner() == oracleAdmin, "Collateral Oracle owner != oracle admin");
    }

    function _requireRoles(address registry, address vault, address oldAdmin, address mainAdmin) internal view {
        IVerifyMarketRegistry r = IVerifyMarketRegistry(registry);
        require(r.hasRole(r.DEFAULT_ADMIN_ROLE(), mainAdmin), "MarketRegistry: main admin missing");
        IVerifyCollateralVault v = IVerifyCollateralVault(vault);
        require(v.hasRole(v.DEFAULT_ADMIN_ROLE(), mainAdmin), "CollateralVault: main admin missing");
        if (oldAdmin != mainAdmin) {
            require(!r.hasRole(r.DEFAULT_ADMIN_ROLE(), oldAdmin), "MarketRegistry: old admin remains");
            require(!r.hasRole(r.MARKET_ADMIN_ROLE(), oldAdmin), "MarketRegistry: old market admin remains");
            require(!r.hasRole(r.PARAM_ADMIN_ROLE(), oldAdmin), "MarketRegistry: old param admin remains");
            require(!r.hasRole(r.PAUSE_GUARDIAN_ROLE(), oldAdmin), "MarketRegistry: old pause guardian remains");
            require(!v.hasRole(v.DEFAULT_ADMIN_ROLE(), oldAdmin), "CollateralVault: old admin remains");
            require(!v.hasRole(v.VAULT_ADMIN_ROLE(), oldAdmin), "CollateralVault: old vault admin remains");
        }
    }

    function _printOwners(
        address clearingHouse,
        address feeRouter,
        address insuranceFund,
        address cuOracle,
        address collateralOracle
    ) internal view {
        console.log("Owners");
        console.log("ClearingHouse:", IVerifyOwnable(clearingHouse).owner());
        console.log("FeeRouter:", IVerifyOwnable(feeRouter).owner());
        console.log("InsuranceFund:", IVerifyOwnable(insuranceFund).owner());
        console.log("CuOracle:", IVerifyCuOracle(cuOracle).owner());
        try IVerifyOwnable(collateralOracle).owner() returns (address owner) {
            console.log("Collateral Oracle:", owner);
        } catch {
            console.log("Collateral Oracle: owner read failed");
        }
        console.log("FeeRouter treasuryAdmin:", IVerifyFeeRouter(feeRouter).treasuryAdmin());
        console.log("");
    }

    function _printRegistry(
        address registry,
        address oldAdmin,
        address mainAdmin,
        address riskParamAdmin,
        address pauseGuardian
    ) internal view {
        IVerifyMarketRegistry r = IVerifyMarketRegistry(registry);
        console.log("MarketRegistry roles");
        _printRole("old DEFAULT_ADMIN", r.hasRole(r.DEFAULT_ADMIN_ROLE(), oldAdmin));
        _printRole("main DEFAULT_ADMIN", r.hasRole(r.DEFAULT_ADMIN_ROLE(), mainAdmin));
        _printRole("main MARKET_ADMIN", r.hasRole(r.MARKET_ADMIN_ROLE(), mainAdmin));
        _printRole("risk PARAM_ADMIN", r.hasRole(r.PARAM_ADMIN_ROLE(), riskParamAdmin));
        _printRole("guardian PAUSE_GUARDIAN", r.hasRole(r.PAUSE_GUARDIAN_ROLE(), pauseGuardian));
        console.log("");
    }

    function _printVault(address vault, address oldAdmin, address mainAdmin) internal view {
        IVerifyCollateralVault v = IVerifyCollateralVault(vault);
        console.log("CollateralVault roles");
        _printRole("old DEFAULT_ADMIN", v.hasRole(v.DEFAULT_ADMIN_ROLE(), oldAdmin));
        _printRole("main DEFAULT_ADMIN", v.hasRole(v.DEFAULT_ADMIN_ROLE(), mainAdmin));
        _printRole("main VAULT_ADMIN", v.hasRole(v.VAULT_ADMIN_ROLE(), mainAdmin));
        console.log("");
    }

    function _printCuOracle(address cuOracle, address oraclePublisher, address oldAdmin) internal view {
        IVerifyCuOracle oracle = IVerifyCuOracle(cuOracle);
        console.log("CuOracle publisher/timing");
        _printRole("new publisher allowed", oracle.allowedRoles(oraclePublisher));
        _printRole("old admin publisher allowed", oracle.allowedRoles(oldAdmin));
        console.log("minTimeInterval:", oracle.minTimeInterval());
        console.log("minCommitRevealDelay:", oracle.minCommitRevealDelay());
        console.log("maxCommitAge:", oracle.maxCommitAge());
        console.log("");
    }

    function _printLiquidator(address clearingHouse, address liquidator) internal view {
        if (liquidator == address(0)) return;
        console.log("Liquidator");
        _printRole("new liquidator whitelisted", IVerifyClearingHouse(clearingHouse).whitelistedLiquidators(liquidator));
        console.log("");
    }

    function _printVammOwners(address registry, address mainAdmin, address oldAdmin) internal view {
        bytes32[] memory marketIds = vm.envBytes32("MARKET_IDS", ",");
        require(marketIds.length != 0, "MARKET_IDS empty");

        console.log("vAMM owner summary");
        uint256 mainCount;
        uint256 oldCount;
        for (uint256 i = 0; i < marketIds.length; i++) {
            address vamm = IMarketRegistry(registry).getMarket(marketIds[i]).vamm;
            require(vamm != address(0), "MARKET_IDS: unknown market");
            address owner = IVerifyOwnable(vamm).owner();
            if (owner == mainAdmin) mainCount++;
            if (owner == oldAdmin) oldCount++;
        }
        console.log("vAMMs owned by main multisig:", mainCount);
        console.log("vAMMs still owned by old admin:", oldCount);
        require(mainCount == marketIds.length, "vAMM not owned by main admin");
    }

    function _printRole(string memory label, bool value) internal pure {
        console.log(label, value);
    }
}
