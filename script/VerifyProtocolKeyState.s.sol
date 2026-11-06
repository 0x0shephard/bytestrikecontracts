// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

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

/// @notice Prints the post-cutover key/role state for evidence.
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
        address mainAdmin = vm.envOr("MAIN_ADMIN_MULTISIG", address(0));
        address oracleAdmin = vm.envOr("ORACLE_ADMIN_MULTISIG", address(0));
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
        _printVammOwners(mainAdmin, oldAdmin);
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

    function _printVammOwners(address mainAdmin, address oldAdmin) internal view {
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

        console.log("vAMM owner summary");
        uint256 mainCount;
        uint256 oldCount;
        for (uint256 i = 0; i < vamms.length; i++) {
            address owner = IVerifyOwnable(vamms[i]).owner();
            if (owner == mainAdmin) mainCount++;
            if (owner == oldAdmin) oldCount++;
        }
        console.log("vAMMs owned by main multisig:", mainCount);
        console.log("vAMMs still owned by old admin:", oldCount);
    }

    function _printRole(string memory label, bool value) internal pure {
        console.log(label, value);
    }
}
