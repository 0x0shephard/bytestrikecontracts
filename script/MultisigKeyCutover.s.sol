// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IAccessControlled {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
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
/// @dev Run with the current privileged wallet. Ownable2Step recipients must accept ownership separately.
///
/// Required env:
/// - PRIVATE_KEY
/// - MAIN_ADMIN_MULTISIG
/// - ORACLE_ADMIN_MULTISIG
/// - ORACLE_PUBLISHER
/// - TREASURY_MULTISIG
/// - PAUSE_GUARDIAN_MULTISIG
///
/// Optional env:
/// - RISK_PARAM_MULTISIG defaults to MAIN_ADMIN_MULTISIG
/// - OLD_ADMIN defaults to broadcaster
/// - OLD_ORACLE_PUBLISHER defaults to OLD_ADMIN
/// - OLD_LIQUIDATOR, NEW_LIQUIDATOR
/// - TRANSFER_COLLATERAL_ORACLE defaults to false because older deployed Oracle.sol had no transferOwnership
contract MultisigKeyCutover is Script {
    address internal constant DEFAULT_CLEARING_HOUSE = 0xDf4DDD4019097B335dD507f916984A1A53E40a0d;
    address internal constant DEFAULT_VAULT = 0x44345dFCD97973329A88aaE8c1432ea90525Ed13;
    address internal constant DEFAULT_REGISTRY = 0x236b75D39203506ee3180Ef2E1c7460a188C43c6;
    address internal constant DEFAULT_FEE_ROUTER = 0xBCEA366b30eb1dcAC6968AECcc215E8797553a5e;
    address internal constant DEFAULT_INSURANCE_FUND = 0x132Ba3d3073FDa7440fb0594210C47eC19087eaD;
    address internal constant DEFAULT_CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    address internal constant DEFAULT_COLLATERAL_ORACLE = 0x27F4970bd037c09440823755657c5fcF107532ae;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(pk);

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
        bool transferCollateralOracle = vm.envOr("TRANSFER_COLLATERAL_ORACLE", false);

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

        vm.startBroadcast(pk);

        _cutoverMarketRegistry(registry, oldAdmin, mainAdmin, riskParamAdmin, pauseGuardian);
        _cutoverCollateralVault(vault, oldAdmin, mainAdmin);
        _cutoverClearingHouse(clearingHouse, mainAdmin, oldLiquidator, newLiquidator);
        _cutoverFeeRouter(feeRouter, mainAdmin, treasury);
        _cutoverInsuranceFund(insuranceFund, mainAdmin);
        _cutoverCuOracle(cuOracle, oracleAdmin, oraclePublisher, oldOraclePublisher);
        _cutoverVamms(mainAdmin);

        if (transferCollateralOracle) {
            _transferDirectOwner("Collateral Oracle", collateralOracle, oracleAdmin);
        } else {
            console.log("Collateral Oracle transfer skipped. Older deployed Oracle.sol has no transferOwnership.");
        }

        vm.stopBroadcast();

        console.log("Cutover submission complete.");
        console.log("Next: multisig must accept ownership for vAMMs, FeeRouter and InsuranceFund.");
        console.log("Oracles on Ownable2Step code must also be accepted by the oracle admin multisig.");
    }

    function _cutoverMarketRegistry(
        address registry,
        address oldAdmin,
        address mainAdmin,
        address riskParamAdmin,
        address pauseGuardian
    ) internal {
        IMarketRegistryRoles r = IMarketRegistryRoles(registry);
        bytes32 defaultAdmin = r.DEFAULT_ADMIN_ROLE();
        bytes32 marketAdmin = r.MARKET_ADMIN_ROLE();
        bytes32 paramAdmin = r.PARAM_ADMIN_ROLE();
        bytes32 pauseRole = r.PAUSE_GUARDIAN_ROLE();

        _grantRoleIfMissing(r, defaultAdmin, mainAdmin, "MarketRegistry DEFAULT_ADMIN_ROLE");
        _grantRoleIfMissing(r, marketAdmin, mainAdmin, "MarketRegistry MARKET_ADMIN_ROLE");
        _grantRoleIfMissing(r, paramAdmin, riskParamAdmin, "MarketRegistry PARAM_ADMIN_ROLE");
        _grantRoleIfMissing(r, pauseRole, pauseGuardian, "MarketRegistry PAUSE_GUARDIAN_ROLE");

        _revokeRoleIfPresent(r, pauseRole, oldAdmin, "MarketRegistry old PAUSE_GUARDIAN_ROLE");
        _revokeRoleIfPresent(r, paramAdmin, oldAdmin, "MarketRegistry old PARAM_ADMIN_ROLE");
        _revokeRoleIfPresent(r, marketAdmin, oldAdmin, "MarketRegistry old MARKET_ADMIN_ROLE");
        _revokeRoleIfPresent(r, defaultAdmin, oldAdmin, "MarketRegistry old DEFAULT_ADMIN_ROLE");
    }

    function _cutoverCollateralVault(address vault, address oldAdmin, address mainAdmin) internal {
        ICollateralVaultRoles v = ICollateralVaultRoles(vault);
        bytes32 defaultAdmin = v.DEFAULT_ADMIN_ROLE();
        bytes32 vaultAdmin = v.VAULT_ADMIN_ROLE();

        _grantRoleIfMissing(v, defaultAdmin, mainAdmin, "CollateralVault DEFAULT_ADMIN_ROLE");
        _grantRoleIfMissing(v, vaultAdmin, mainAdmin, "CollateralVault VAULT_ADMIN_ROLE");

        _revokeRoleIfPresent(v, vaultAdmin, oldAdmin, "CollateralVault old VAULT_ADMIN_ROLE");
        _revokeRoleIfPresent(v, defaultAdmin, oldAdmin, "CollateralVault old DEFAULT_ADMIN_ROLE");
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

    function _cutoverVamms(address mainAdmin) internal {
        address[19] memory vamms = [
            0x9916716B80b353FdDEe6E5c480422d6BF73e3642,
            0x1a2150a6C3d4005b6515486CD5580D80D0a91df0,
            0x3EC9bCC775dD69aA8b5D358c782f80a785B12d0e,
            0x3F63a0f4B1E4DB3eff51d5a6495f6f5E9A5E4741,
            0x69852D155Ddb624E9511382242cBfF1DC985bFef,
            0x8a0b25E83F714E7d14AC8C7251673711ad0BE7e7,
            0x6c35F2C88c99EcD7794cB4BcC1465C7129113a22,
            0xa245588f6867F78866F38e947983Bdca6D12E937,
            0xA52c4170Da956Da2d270B4F52309657664e10819,
            0xd2F9b28ce16d0ed8Ff2cCCf638F0484b2f6508d4,
            0x18c6103BDC17A8c7F1aE315Ccbdc9349205f248E,
            0xc4C187F1a499Bf1f565F9816bD0427F676B772c2,
            0x079A30C8Aa3D34FcF17B9e288bd05C04Df203e23,
            0x15df002e93168Cf574Bdad50D05AC2bAAaC6Cd6a,
            0x2395987E973CdFc4e145b1220D3ee34FC7c8E084,
            0x8a68985e036E7fD635eC8E8AFd8a86A61187D723,
            0x0D8132954F4BefAE87a240AFE6584320bED12322,
            0x564d5076B7229Fffa7Ca369C7752b2EC4376aBF6,
            0xDF3D211986E47946e079E85F24A2f22fd5C4C280
        ];

        for (uint256 i = 0; i < vamms.length; i++) {
            _transferDirectOwner("vAMM pending owner", vamms[i], mainAdmin);
        }
    }

    function _grantRoleIfMissing(IAccessControlled target, bytes32 role, address account, string memory label) internal {
        if (!target.hasRole(role, account)) {
            target.grantRole(role, account);
            console.log("granted", label, account);
        }
    }

    function _revokeRoleIfPresent(IAccessControlled target, bytes32 role, address account, string memory label) internal {
        if (account != address(0) && target.hasRole(role, account)) {
            target.revokeRole(role, account);
            console.log("revoked", label, account);
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
