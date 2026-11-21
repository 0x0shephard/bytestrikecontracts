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

/// @notice Acceptance phase for Ownable2Step contracts after MultisigKeyCutover.
/// @dev Must be executed by the pending owner. For a Safe, submit these calls from the Safe UI/transaction builder.
///
/// Required env:
/// - MAIN_ADMIN_MULTISIG
/// - MARKET_IDS: comma-separated bytes32 ids of every market; vAMMs are resolved through MarketRegistry
///
/// Optional env:
/// - ORACLE_ADMIN_MULTISIG defaults to MAIN_ADMIN_MULTISIG
/// - MARKET_REGISTRY, FEE_ROUTER, INSURANCE_FUND, CU_ORACLE, COLLATERAL_ORACLE (default to Sepolia)
/// - ACCEPT_MAIN (default true): accept FeeRouter, InsuranceFund and every vAMM as MAIN_ADMIN_MULTISIG
/// - ACCEPT_ORACLES (default true): accept CuOracle and the collateral Oracle as ORACLE_ADMIN_MULTISIG
///   When the two multisigs differ, run once per signer with the other flag set to false.
///
/// Every accepted contract is checked to be owned by its expected owner before the run ends.
contract AcceptMultisigOwnership is Script {
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
            _acceptIfPending(vm.envOr("FEE_ROUTER", DEFAULT_FEE_ROUTER), mainAdmin, "FeeRouter");
            _acceptIfPending(vm.envOr("INSURANCE_FUND", DEFAULT_INSURANCE_FUND), mainAdmin, "InsuranceFund");
            _acceptVamms(vm.envOr("MARKET_REGISTRY", DEFAULT_REGISTRY), mainAdmin);
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
