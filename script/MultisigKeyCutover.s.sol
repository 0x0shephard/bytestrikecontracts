// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

interface IAccessControlled {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @dev AccessControlDefaultAdminRules (MarketRegistry / CollateralVault deployed from the current
///      sources). Legacy deployments use plain AccessControl and do not implement it.
interface IDefaultAdminRules {
    function defaultAdmin() external view returns (address);
    function pendingDefaultAdmin() external view returns (address newAdmin, uint48 schedule);
    function beginDefaultAdminTransfer(address newAdmin) external;
}

interface IMarketRegistryRoles is IAccessControlled {
    function MARKET_ADMIN_ROLE() external view returns (bytes32);
    function PARAM_ADMIN_ROLE() external view returns (bytes32);
    function PAUSE_GUARDIAN_ROLE() external view returns (bytes32);
}

interface ICollateralVaultRoles is IAccessControlled {
    function VAULT_ADMIN_ROLE() external view returns (bytes32);
}

interface IOwnableDirect {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IOwnable2StepView {
    function pendingOwner() external view returns (address);
}

interface IFeeRouterAdmin is IOwnableDirect {
    function treasuryAdmin() external view returns (address);
    function setTreasuryAdmin(address newTreasuryAdmin) external;
}

interface ICuOracleAdmin {
    function owner() external view returns (address);
    function allowedRoles(address account) external view returns (bool);
    function grantRole(address account) external;
    function revokeRole(address account) external;
    function transferOwnership(address newOwner) external;
}

interface IClearingHouseAdmin is IOwnableDirect {
    function whitelistedLiquidators(address liquidator) external view returns (bool);
    function setWhitelistedLiquidator(address liquidator, bool allowed) external;
}

/// @notice Moves ByteStrike Sepolia admin authority away from a single deployer EOA.
/// @dev Run with the current privileged wallet. Nothing is handed over in one step: every Ownable2Step
///      contract (ClearingHouse included) is left pending to its new owner, and the MarketRegistry and
///      CollateralVault roles are granted to the multisigs while the old admin keeps its own. The
///      multisig then runs AcceptMultisigOwnership, which accepts the pending ownerships (and, on a
///      registry/vault deployed with AccessControlDefaultAdminRules, the pending default admin
///      transfer once its delay has passed) and revokes the old admin's registry/vault roles itself,
///      which it can only do if it really holds DEFAULT_ADMIN_ROLE (audit finding 29).
///
/// Sign with the current privileged wallet via `--account <keystore-name> --sender <address>`
/// (or `--ledger`); no private key is read from the environment.
///
/// Required env:
/// - MAIN_ADMIN_MULTISIG
/// - ORACLE_ADMIN_MULTISIG
/// - ORACLE_PUBLISHER
/// - TREASURY_MULTISIG
/// - PAUSE_GUARDIAN_MULTISIG
/// - MARKET_IDS: comma-separated bytes32 ids of EVERY market (from MarketRegistry MarketAdded logs).
///   vAMMs are resolved through MarketRegistry.getMarket; a missing id is not detected, so the list
///   must be complete.
///
/// Optional env:
/// - RISK_PARAM_MULTISIG defaults to MAIN_ADMIN_MULTISIG
/// - OLD_ADMIN defaults to broadcaster
/// - OLD_ORACLE_PUBLISHER defaults to OLD_ADMIN
/// - OLD_LIQUIDATOR, NEW_LIQUIDATOR
/// - TRANSFER_COLLATERAL_ORACLE defaults to true (Oracle.sol is Ownable2Step); set false only for a legacy
///   deployment whose collateral Oracle cannot transfer ownership
///
/// The run ends with end-state checks and reverts unless every handed-over contract is owned by, or
/// pending to, its new owner and the multisigs hold (or, for a default admin with transfer rules, are
/// pending to receive) the registry/vault admin roles. VerifyProtocolKeyState checks the final state
/// after AcceptMultisigOwnership.
contract MultisigKeyCutover is Script {
    address internal constant DEFAULT_CLEARING_HOUSE = 0xDf4DDD4019097B335dD507f916984A1A53E40a0d;
    address internal constant DEFAULT_VAULT = 0x44345dFCD97973329A88aaE8c1432ea90525Ed13;
    address internal constant DEFAULT_REGISTRY = 0x236b75D39203506ee3180Ef2E1c7460a188C43c6;
    address internal constant DEFAULT_FEE_ROUTER = 0xBCEA366b30eb1dcAC6968AECcc215E8797553a5e;
    address internal constant DEFAULT_INSURANCE_FUND = 0x132Ba3d3073FDa7440fb0594210C47eC19087eaD;
    address internal constant DEFAULT_CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    address internal constant DEFAULT_COLLATERAL_ORACLE = 0x27F4970bd037c09440823755657c5fcF107532ae;

    function run() external {
        address broadcaster = msg.sender;

        address oldAdmin = vm.envOr("OLD_ADMIN", broadcaster);
        address oldOraclePublisher = vm.envOr("OLD_ORACLE_PUBLISHER", oldAdmin);
        address oldLiquidator = vm.envOr("OLD_LIQUIDATOR", address(0));
        address newLiquidator = vm.envOr("NEW_LIQUIDATOR", address(0));

        address mainAdmin = vm.envAddress("MAIN_ADMIN_MULTISIG");
        address oracleAdmin = vm.envAddress("ORACLE_ADMIN_MULTISIG");
        address oraclePublisher = vm.envAddress("ORACLE_PUBLISHER");
        address treasury = vm.envAddress("TREASURY_MULTISIG");
        address pauseGuardian = vm.envAddress("PAUSE_GUARDIAN_MULTISIG");
        address riskParamAdmin = vm.envOr("RISK_PARAM_MULTISIG", mainAdmin);

        address clearingHouse = vm.envOr("CLEARING_HOUSE", DEFAULT_CLEARING_HOUSE);
        address vault = vm.envOr("COLLATERAL_VAULT", DEFAULT_VAULT);
        address registry = vm.envOr("MARKET_REGISTRY", DEFAULT_REGISTRY);
        address feeRouter = vm.envOr("FEE_ROUTER", DEFAULT_FEE_ROUTER);
        address insuranceFund = vm.envOr("INSURANCE_FUND", DEFAULT_INSURANCE_FUND);
        address cuOracle = vm.envOr("CU_ORACLE", DEFAULT_CU_ORACLE);
        address collateralOracle = vm.envOr("COLLATERAL_ORACLE", DEFAULT_COLLATERAL_ORACLE);
        bool transferCollateralOracle = vm.envOr("TRANSFER_COLLATERAL_ORACLE", true);

        _requireNonZero(mainAdmin, "MAIN_ADMIN_MULTISIG");
        _requireNonZero(oracleAdmin, "ORACLE_ADMIN_MULTISIG");
        _requireNonZero(oraclePublisher, "ORACLE_PUBLISHER");
        _requireNonZero(treasury, "TREASURY_MULTISIG");
        _requireNonZero(pauseGuardian, "PAUSE_GUARDIAN_MULTISIG");
        _requireNonZero(riskParamAdmin, "RISK_PARAM_MULTISIG");

        console.log("Multisig key cutover");
        console.log("broadcaster:", broadcaster);
        console.log("old admin:", oldAdmin);
        console.log("main admin multisig:", mainAdmin);
        console.log("risk param multisig:", riskParamAdmin);
        console.log("pause guardian multisig:", pauseGuardian);
        console.log("oracle admin multisig:", oracleAdmin);
        console.log("oracle publisher:", oraclePublisher);
        console.log("treasury multisig:", treasury);

        vm.startBroadcast();

        _cutoverMarketRegistry(registry, mainAdmin, riskParamAdmin, pauseGuardian);
        _cutoverCollateralVault(vault, mainAdmin);
        _cutoverClearingHouse(clearingHouse, mainAdmin, oldLiquidator, newLiquidator);
        _cutoverFeeRouter(feeRouter, mainAdmin, treasury);
        _cutoverInsuranceFund(insuranceFund, mainAdmin);
        _cutoverCuOracle(cuOracle, oracleAdmin, oraclePublisher, oldOraclePublisher);
        _cutoverVamms(registry, mainAdmin);

        if (transferCollateralOracle) {
            _transferDirectOwner("Collateral Oracle", collateralOracle, oracleAdmin);
        } else {
            console.log("WARNING: Collateral Oracle transfer skipped (TRANSFER_COLLATERAL_ORACLE=false).");
        }

        vm.stopBroadcast();

        // End-state checks: fail the run if anything is still controlled by the old admin.
        _requireRolesHandedOff(registry, vault, mainAdmin);
        _requireHandedOff(clearingHouse, mainAdmin, "ClearingHouse not handed off");
        _requireHandedOff(feeRouter, mainAdmin, "FeeRouter not handed off");
        _requireHandedOff(insuranceFund, mainAdmin, "InsuranceFund not handed off");
        _requireHandedOff(cuOracle, oracleAdmin, "CuOracle not handed off");
        if (transferCollateralOracle) {
            _requireHandedOff(collateralOracle, oracleAdmin, "Collateral Oracle not handed off");
        }

        console.log("Cutover submission complete. The old admin keeps its registry/vault roles for now.");
        console.log("Next: main multisig runs AcceptMultisigOwnership (OLD_ADMIN set) to accept ClearingHouse,");
        console.log("vAMMs, FeeRouter, InsuranceFund and the registry/vault default admin, then revoke the old admin.");
        console.log("CuOracle and Collateral Oracle (Ownable2Step) must be accepted by the oracle admin multisig.");
    }

    function _cutoverMarketRegistry(
        address registry,
        address mainAdmin,
        address riskParamAdmin,
        address pauseGuardian
    ) internal {
        IMarketRegistryRoles r = IMarketRegistryRoles(registry);
        bytes32 defaultAdmin = r.DEFAULT_ADMIN_ROLE();
        bytes32 marketAdmin = r.MARKET_ADMIN_ROLE();
        bytes32 paramAdmin = r.PARAM_ADMIN_ROLE();
        bytes32 pauseRole = r.PAUSE_GUARDIAN_ROLE();

        _handOverDefaultAdmin(r, defaultAdmin, mainAdmin, "MarketRegistry DEFAULT_ADMIN_ROLE");
        _grantRoleIfMissing(r, marketAdmin, mainAdmin, "MarketRegistry MARKET_ADMIN_ROLE");
        _grantRoleIfMissing(r, paramAdmin, riskParamAdmin, "MarketRegistry PARAM_ADMIN_ROLE");
        _grantRoleIfMissing(r, pauseRole, pauseGuardian, "MarketRegistry PAUSE_GUARDIAN_ROLE");

        // The old admin's roles are revoked by mainAdmin in AcceptMultisigOwnership, which proves the
        // multisig controls DEFAULT_ADMIN_ROLE before the old admin loses it.
    }

    function _cutoverCollateralVault(address vault, address mainAdmin) internal {
        ICollateralVaultRoles v = ICollateralVaultRoles(vault);
        bytes32 defaultAdmin = v.DEFAULT_ADMIN_ROLE();
        bytes32 vaultAdmin = v.VAULT_ADMIN_ROLE();

        _handOverDefaultAdmin(v, defaultAdmin, mainAdmin, "CollateralVault DEFAULT_ADMIN_ROLE");
        _grantRoleIfMissing(v, vaultAdmin, mainAdmin, "CollateralVault VAULT_ADMIN_ROLE");

        // Revoked by mainAdmin in AcceptMultisigOwnership, as above.
    }

    /// @dev With AccessControlDefaultAdminRules the default admin moves only through a delayed two-step
    ///      transfer, which is started here; a legacy AccessControl deployment grants the role (the
    ///      old admin keeps its own until the multisig revokes it).
    function _handOverDefaultAdmin(IAccessControlled target, bytes32 role, address mainAdmin, string memory label)
        internal
    {
        try IDefaultAdminRules(address(target)).defaultAdmin() returns (address current) {
            if (current == mainAdmin) return;
            (address pending,) = IDefaultAdminRules(address(target)).pendingDefaultAdmin();
            if (pending != mainAdmin) {
                IDefaultAdminRules(address(target)).beginDefaultAdminTransfer(mainAdmin);
                console.log("default admin transfer started", label, mainAdmin);
            }
        } catch {
            _grantRoleIfMissing(target, role, mainAdmin, label);
        }
    }

    function _cutoverClearingHouse(
        address clearingHouse,
        address mainAdmin,
        address oldLiquidator,
        address newLiquidator
    ) internal {
        if (newLiquidator != address(0)) {
            IClearingHouseAdmin(clearingHouse).setWhitelistedLiquidator(newLiquidator, true);
            console.log("ClearingHouse new liquidator whitelisted:", newLiquidator);
        }
        if (oldLiquidator != address(0)) {
            IClearingHouseAdmin(clearingHouse).setWhitelistedLiquidator(oldLiquidator, false);
            console.log("ClearingHouse old liquidator removed:", oldLiquidator);
        }
        _transferDirectOwner("ClearingHouse", clearingHouse, mainAdmin);
    }

    function _cutoverFeeRouter(address feeRouter, address mainAdmin, address treasury) internal {
        IFeeRouterAdmin router = IFeeRouterAdmin(feeRouter);
        if (router.treasuryAdmin() != treasury) {
            router.setTreasuryAdmin(treasury);
            console.log("FeeRouter treasuryAdmin set:", treasury);
        }
        _transferDirectOwner("FeeRouter pending owner", feeRouter, mainAdmin);
    }

    function _cutoverInsuranceFund(address insuranceFund, address mainAdmin) internal {
        _transferDirectOwner("InsuranceFund pending owner", insuranceFund, mainAdmin);
    }

    function _cutoverCuOracle(
        address cuOracle,
        address oracleAdmin,
        address oraclePublisher,
        address oldOraclePublisher
    ) internal {
        ICuOracleAdmin oracle = ICuOracleAdmin(cuOracle);
        if (!oracle.allowedRoles(oraclePublisher)) {
            oracle.grantRole(oraclePublisher);
            console.log("CuOracle publisher granted:", oraclePublisher);
        }
        if (oldOraclePublisher != address(0) && oldOraclePublisher != oraclePublisher && oracle.allowedRoles(oldOraclePublisher)) {
            oracle.revokeRole(oldOraclePublisher);
            console.log("CuOracle old publisher revoked:", oldOraclePublisher);
        }
        if (oracle.owner() != oracleAdmin) {
            oracle.transferOwnership(oracleAdmin);
            console.log("CuOracle owner transfer started:", oracleAdmin);
        }
    }

    /// @dev vAMMs are resolved from MarketRegistry using MARKET_IDS, never from a literal address list.
    function _cutoverVamms(address registry, address mainAdmin) internal {
        address[] memory vamms = marketVamms(registry);
        for (uint256 i = 0; i < vamms.length; i++) {
            _transferDirectOwner("vAMM pending owner", vamms[i], mainAdmin);
            _requireHandedOff(vamms[i], mainAdmin, "vAMM not handed off");
        }
    }

    /// @notice Resolves the vAMM of every market id in MARKET_IDS through MarketRegistry.
    function marketVamms(address registry) public view returns (address[] memory vamms) {
        bytes32[] memory marketIds = vm.envBytes32("MARKET_IDS", ",");
        require(marketIds.length != 0, "MARKET_IDS empty");
        vamms = new address[](marketIds.length);
        for (uint256 i = 0; i < marketIds.length; i++) {
            address vamm = IMarketRegistry(registry).getMarket(marketIds[i]).vamm;
            require(vamm != address(0), "MARKET_IDS: unknown market");
            vamms[i] = vamm;
        }
    }

    function _requireHandedOff(address target, address newOwner, string memory err) internal view {
        if (IOwnableDirect(target).owner() == newOwner) return;
        address pending;
        try IOwnable2StepView(target).pendingOwner() returns (address p) {
            pending = p;
        } catch {}
        require(pending == newOwner, err);
    }

    function _requireRolesHandedOff(address registry, address vault, address mainAdmin) internal view {
        IMarketRegistryRoles r = IMarketRegistryRoles(registry);
        require(_holdsOrPendingDefaultAdmin(r, mainAdmin), "MarketRegistry admin not handed off");
        require(r.hasRole(r.MARKET_ADMIN_ROLE(), mainAdmin), "MarketRegistry market admin not handed off");
        ICollateralVaultRoles v = ICollateralVaultRoles(vault);
        require(_holdsOrPendingDefaultAdmin(v, mainAdmin), "CollateralVault admin not handed off");
        require(v.hasRole(v.VAULT_ADMIN_ROLE(), mainAdmin), "CollateralVault vault admin not handed off");
    }

    function _holdsOrPendingDefaultAdmin(IAccessControlled target, address account) internal view returns (bool) {
        if (target.hasRole(target.DEFAULT_ADMIN_ROLE(), account)) return true;
        try IDefaultAdminRules(address(target)).pendingDefaultAdmin() returns (address pending, uint48) {
            return pending == account;
        } catch {
            return false;
        }
    }

    function _grantRoleIfMissing(IAccessControlled target, bytes32 role, address account, string memory label) internal {
        if (!target.hasRole(role, account)) {
            target.grantRole(role, account);
            console.log("granted", label, account);
        }
    }

    function _transferDirectOwner(string memory label, address target, address newOwner) internal {
        IOwnableDirect ownable = IOwnableDirect(target);
        if (ownable.owner() != newOwner) {
            ownable.transferOwnership(newOwner);
            console.log(label, target, newOwner);
        }
    }

    function _requireNonZero(address value, string memory name) internal pure {
        require(value != address(0), name);
    }
}
