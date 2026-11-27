// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

interface IOwnable2StepAccept {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
}

interface IAcceptAccessControl {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function revokeRole(bytes32 role, address account) external;
}

/// @dev AccessControlDefaultAdminRules; legacy AccessControl deployments do not implement it.
interface IAcceptDefaultAdminRules {
    function defaultAdmin() external view returns (address);
    function pendingDefaultAdmin() external view returns (address newAdmin, uint48 schedule);
    function acceptDefaultAdminTransfer() external;
}

interface IAcceptRegistryRoles is IAcceptAccessControl {
    function MARKET_ADMIN_ROLE() external view returns (bytes32);
    function PARAM_ADMIN_ROLE() external view returns (bytes32);
    function PAUSE_GUARDIAN_ROLE() external view returns (bytes32);
}

interface IAcceptVaultRoles is IAcceptAccessControl {
    function VAULT_ADMIN_ROLE() external view returns (bytes32);
}

/// @notice Acceptance phase after MultisigKeyCutover: the multisigs accept what was handed to them and the
///         main multisig revokes the old admin's MarketRegistry / CollateralVault roles itself.
/// @dev Must be executed by the pending owner. For a Safe, submit these calls from the Safe UI/transaction builder.
///      Revoking the old admin is the acceptance step for the AccessControl contracts: only a holder of
///      DEFAULT_ADMIN_ROLE can do it, so the old admin keeps its roles until the multisig proves control.
///      On a registry/vault deployed with AccessControlDefaultAdminRules, the pending default admin
///      transfer is accepted first; run after its delay (INITIAL_DEFAULT_ADMIN_DELAY) has passed.
///
/// Required env:
/// - MAIN_ADMIN_MULTISIG
/// - MARKET_IDS: comma-separated bytes32 ids of every market; vAMMs are resolved through MarketRegistry
///
/// Optional env:
/// - ORACLE_ADMIN_MULTISIG defaults to MAIN_ADMIN_MULTISIG
/// - OLD_ADMIN: the admin MultisigKeyCutover handed over from; its registry/vault roles are revoked
///   (required with ACCEPT_MAIN unless it equals MAIN_ADMIN_MULTISIG)
/// - CLEARING_HOUSE, MARKET_REGISTRY, COLLATERAL_VAULT, FEE_ROUTER, INSURANCE_FUND, CU_ORACLE,
///   COLLATERAL_ORACLE (default to Sepolia)
/// - ACCEPT_MAIN (default true): accept ClearingHouse, FeeRouter, InsuranceFund, every vAMM and the
///   registry/vault default admin as MAIN_ADMIN_MULTISIG, then revoke OLD_ADMIN's registry/vault roles
/// - ACCEPT_ORACLES (default true): accept CuOracle and the collateral Oracle as ORACLE_ADMIN_MULTISIG
///   When the two multisigs differ, run once per signer with the other flag set to false.
///
/// Every accepted contract is checked to be owned by its expected owner before the run ends.
contract AcceptMultisigOwnership is Script {
    address internal constant DEFAULT_CLEARING_HOUSE = 0xDf4DDD4019097B335dD507f916984A1A53E40a0d;
    address internal constant DEFAULT_VAULT = 0x44345dFCD97973329A88aaE8c1432ea90525Ed13;
    address internal constant DEFAULT_REGISTRY = 0x236b75D39203506ee3180Ef2E1c7460a188C43c6;
    address internal constant DEFAULT_FEE_ROUTER = 0xBCEA366b30eb1dcAC6968AECcc215E8797553a5e;
    address internal constant DEFAULT_INSURANCE_FUND = 0x132Ba3d3073FDa7440fb0594210C47eC19087eaD;
    address internal constant DEFAULT_CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    address internal constant DEFAULT_COLLATERAL_ORACLE = 0x27F4970bd037c09440823755657c5fcF107532ae;

    function run() external {
        address signer = msg.sender;
        address mainAdmin = vm.envAddress("MAIN_ADMIN_MULTISIG");
        address oracleAdmin = vm.envOr("ORACLE_ADMIN_MULTISIG", mainAdmin);
        bool acceptMain = vm.envOr("ACCEPT_MAIN", true);
        bool acceptOracles = vm.envOr("ACCEPT_ORACLES", true);

        console.log("Accepting Ownable2Step ownership");
        console.log("signer:", signer);
        console.log("main admin:", mainAdmin);
        console.log("oracle admin:", oracleAdmin);

        vm.startBroadcast();

        if (acceptMain) {
            address registry = vm.envOr("MARKET_REGISTRY", DEFAULT_REGISTRY);
            address vault = vm.envOr("COLLATERAL_VAULT", DEFAULT_VAULT);
            _acceptIfPending(vm.envOr("CLEARING_HOUSE", DEFAULT_CLEARING_HOUSE), mainAdmin, "ClearingHouse");
            _acceptIfPending(vm.envOr("FEE_ROUTER", DEFAULT_FEE_ROUTER), mainAdmin, "FeeRouter");
            _acceptIfPending(vm.envOr("INSURANCE_FUND", DEFAULT_INSURANCE_FUND), mainAdmin, "InsuranceFund");
            _acceptVamms(registry, mainAdmin);
            _acceptDefaultAdmin(registry, mainAdmin, "MarketRegistry");
            _acceptDefaultAdmin(vault, mainAdmin, "CollateralVault");
            address oldAdmin = vm.envOr("OLD_ADMIN", address(0));
            require(oldAdmin != address(0), "OLD_ADMIN not set");
            if (oldAdmin != mainAdmin) _revokeOldAdmin(registry, vault, oldAdmin);
        }
        if (acceptOracles) {
            _acceptIfPending(vm.envOr("CU_ORACLE", DEFAULT_CU_ORACLE), oracleAdmin, "CuOracle");
            _acceptIfPending(vm.envOr("COLLATERAL_ORACLE", DEFAULT_COLLATERAL_ORACLE), oracleAdmin, "Collateral Oracle");
        }

        vm.stopBroadcast();
    }

    function _acceptVamms(address registry, address expectedOwner) internal {
        bytes32[] memory marketIds = vm.envBytes32("MARKET_IDS", ",");
        require(marketIds.length != 0, "MARKET_IDS empty");
        for (uint256 i = 0; i < marketIds.length; i++) {
            address vamm = IMarketRegistry(registry).getMarket(marketIds[i]).vamm;
            require(vamm != address(0), "MARKET_IDS: unknown market");
            _acceptIfPending(vamm, expectedOwner, "vAMM");
        }
    }

    /// @dev Accepts a pending default admin transfer (AccessControlDefaultAdminRules); on a legacy
    ///      AccessControl deployment the role was granted by the cutover and is only checked.
    function _acceptDefaultAdmin(address target, address expectedAdmin, string memory label) internal {
        IAcceptAccessControl ac = IAcceptAccessControl(target);
        bytes32 role = ac.DEFAULT_ADMIN_ROLE();
        if (ac.hasRole(role, expectedAdmin)) {
            console.log(label, "default admin already held", target);
            return;
        }
        (address pending,) = IAcceptDefaultAdminRules(target).pendingDefaultAdmin();
        require(pending == expectedAdmin, "pending default admin mismatch");
        IAcceptDefaultAdminRules(target).acceptDefaultAdminTransfer();
        require(ac.hasRole(role, expectedAdmin), "default admin accept failed");
        console.log(label, "default admin accepted", target);
    }

    /// @dev Revokes the old admin's registry and vault roles. Sent by the main multisig, so it only
    ///      succeeds once the multisig holds DEFAULT_ADMIN_ROLE. With AccessControlDefaultAdminRules the
    ///      old admin already lost DEFAULT_ADMIN_ROLE on acceptance.
    function _revokeOldAdmin(address registry, address vault, address oldAdmin) internal {
        IAcceptRegistryRoles r = IAcceptRegistryRoles(registry);
        _revokeIfHeld(r, r.PAUSE_GUARDIAN_ROLE(), oldAdmin, "MarketRegistry PAUSE_GUARDIAN_ROLE");
        _revokeIfHeld(r, r.PARAM_ADMIN_ROLE(), oldAdmin, "MarketRegistry PARAM_ADMIN_ROLE");
        _revokeIfHeld(r, r.MARKET_ADMIN_ROLE(), oldAdmin, "MarketRegistry MARKET_ADMIN_ROLE");
        _revokeIfHeld(r, r.DEFAULT_ADMIN_ROLE(), oldAdmin, "MarketRegistry DEFAULT_ADMIN_ROLE");
        IAcceptVaultRoles v = IAcceptVaultRoles(vault);
        _revokeIfHeld(v, v.VAULT_ADMIN_ROLE(), oldAdmin, "CollateralVault VAULT_ADMIN_ROLE");
        _revokeIfHeld(v, v.DEFAULT_ADMIN_ROLE(), oldAdmin, "CollateralVault DEFAULT_ADMIN_ROLE");
    }

    function _revokeIfHeld(IAcceptAccessControl target, bytes32 role, address account, string memory label) internal {
        if (target.hasRole(role, account)) {
            target.revokeRole(role, account);
            console.log("revoked old admin", label, account);
        }
    }

    function _acceptIfPending(address target, address expectedOwner, string memory label) internal {
        IOwnable2StepAccept ownable = IOwnable2StepAccept(target);
        if (ownable.owner() == expectedOwner) {
            console.log(label, "already owned", target);
            return;
        }
        require(ownable.pendingOwner() == expectedOwner, "pending owner mismatch");
        ownable.acceptOwnership();
        require(ownable.owner() == expectedOwner, "accept failed");
        console.log(label, "accepted", target);
    }
}
