// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BCScript } from "battlechain-lib/BCScript.sol";
import { Contact } from "battlechain-lib/types/AgreementTypes.sol";
import { console } from "forge-std/console.sol";

interface IAttackRegistryInfo {
    struct AgreementInfo {
        address moderator;
        uint256 adoptedAt;
        uint256 promotionRequestedTimestamp;
        uint8   state;
        uint8   field4;
        uint8   field5;
        uint8   field6;
        uint8   field7;
    }
    function getAgreementInfo(address agreementAddress) external view returns (AgreementInfo memory);
    function cancelPromotion(address agreementAddress) external;
}

/// @title CancelPromotion
/// @notice Cancels a pending promotion request and returns the agreement to UNDER_ATTACK.
///         Only callable during the 3-day promotion window.
///
/// Run:
///   forge script script/CancelPromotion.s.sol \
///     --rpc-url battlechain_testnet \
///     --broadcast \
///     --legacy
contract CancelPromotion is BCScript {
    address constant AGREEMENT = 0xbedE5784286D79de78F2b617953b2c492931bE94;

    uint8 constant STATE_PROMOTION_REQUESTED = 2;

    error NoPendingPromotion();
    error PromotionAlreadyFinalized();

    function _protocolName() internal pure override returns (string memory) { return "ByteStrike"; }
    function _contacts() internal pure override returns (Contact[] memory) {
        Contact[] memory c = new Contact[](0);
        return c;
    }
    function _recoveryAddress() internal view override returns (address) { return msg.sender; }

    function run() external {
        IAttackRegistryInfo registry = IAttackRegistryInfo(_bcAttackRegistry());
        IAttackRegistryInfo.AgreementInfo memory info = registry.getAgreementInfo(AGREEMENT);

        if (info.state != STATE_PROMOTION_REQUESTED) revert NoPendingPromotion();
        if (block.timestamp >= info.promotionRequestedTimestamp + 3 days) revert PromotionAlreadyFinalized();

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        registry.cancelPromotion(AGREEMENT);
        vm.stopBroadcast();

        console.log("\n=== ByteStrike Promotion Cancelled ===");
        console.log("Agreement returned to UNDER_ATTACK state.");
    }
}
