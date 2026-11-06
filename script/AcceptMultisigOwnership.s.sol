// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IOwnable2StepAccept {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
}

/// @notice Acceptance phase for Ownable2Step contracts after MultisigKeyCutover.
/// @dev Must be executed by the pending owner. For a Safe, submit these calls from the Safe UI/transaction builder.
contract AcceptMultisigOwnership is Script {
    address internal constant DEFAULT_FEE_ROUTER = 0xBCEA366b30eb1dcAC6968AECcc215E8797553a5e;
    address internal constant DEFAULT_INSURANCE_FUND = 0x132Ba3d3073FDa7440fb0594210C47eC19087eaD;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(pk);
        address expectedOwner = vm.envAddress("MAIN_ADMIN_MULTISIG");

        console.log("Accepting Ownable2Step ownership");
        console.log("signer:", signer);
        console.log("expected owner:", expectedOwner);

        vm.startBroadcast(pk);

        _acceptIfPending(vm.envOr("FEE_ROUTER", DEFAULT_FEE_ROUTER), expectedOwner, "FeeRouter");
        _acceptIfPending(vm.envOr("INSURANCE_FUND", DEFAULT_INSURANCE_FUND), expectedOwner, "InsuranceFund");
        _acceptVamms(expectedOwner);
        _acceptOracles();

        vm.stopBroadcast();
    }

    /// @dev Opt-in because older deployed oracles have no pendingOwner or acceptOwnership.
    ///      Set ACCEPT_CU_ORACLE and ACCEPT_COLLATERAL_ORACLE only for Ownable2Step deployments.
    ///      The signer must be ORACLE_ADMIN_MULTISIG, which may differ from MAIN_ADMIN_MULTISIG.
    function _acceptOracles() internal {
        address cuOracle = vm.envOr("ACCEPT_CU_ORACLE", address(0));
        address collateralOracle = vm.envOr("ACCEPT_COLLATERAL_ORACLE", address(0));
        if (cuOracle == address(0) && collateralOracle == address(0)) return;

        address oracleAdmin = vm.envAddress("ORACLE_ADMIN_MULTISIG");
        if (cuOracle != address(0)) _acceptIfPending(cuOracle, oracleAdmin, "CuOracle");
        if (collateralOracle != address(0)) _acceptIfPending(collateralOracle, oracleAdmin, "Collateral Oracle");
    }

    function _acceptVamms(address expectedOwner) internal {
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
            _acceptIfPending(vamms[i], expectedOwner, "vAMM");
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
