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
    function promote(address agreementAddress) external;
    function cancelPromotion(address agreementAddress) external;
}

/// @title PromoteToProduction
/// @notice Requests promotion of the ByteStrike agreement to production mode.
///         Starts the mandatory 3-day countdown. Contracts remain attackable
///         during this window and promotion can be cancelled if issues are found.
///
/// Agreement:     0xbedE5784286D79de78F2b617953b2c492931bE94
/// AttackRegistry: 0xdD029a6374095EEb4c47a2364Ce1D0f47f007350
///
/// Run:
///   forge script script/PromoteToProduction.s.sol \
///     --rpc-url battlechain_testnet \
///     --broadcast \
///     --legacy
///
/// To cancel during the 3-day window (if a bug is found):
///   forge script script/CancelPromotion.s.sol \
///     --rpc-url battlechain_testnet \
///     --broadcast \
///     --legacy
contract PromoteToProduction is BCScript {
    address constant AGREEMENT = 0xbedE5784286D79de78F2b617953b2c492931bE94;

    // State enum from AttackRegistry
    uint8 constant STATE_UNDER_ATTACK        = 1;
    uint8 constant STATE_PROMOTION_REQUESTED = 2;
    uint8 constant STATE_PRODUCTION          = 3;

    error WrongState(uint8 current, uint8 required);
    error AlreadyInProduction();
    error AlreadyPromotionRequested(uint256 promotionTime);

    function _protocolName() internal pure override returns (string memory) { return "ByteStrike"; }
    function _contacts() internal pure override returns (Contact[] memory) {
        Contact[] memory c = new Contact[](0);
        return c;
    }
    function _recoveryAddress() internal view override returns (address) { return msg.sender; }

    function run() external {
        IAttackRegistryInfo registry = IAttackRegistryInfo(_bcAttackRegistry());
        IAttackRegistryInfo.AgreementInfo memory info = registry.getAgreementInfo(AGREEMENT);

        if (info.state == STATE_PRODUCTION) revert AlreadyInProduction();
        if (info.state == STATE_PROMOTION_REQUESTED) {
            revert AlreadyPromotionRequested(info.promotionRequestedTimestamp + 3 days);
        }
        if (info.state != STATE_UNDER_ATTACK) revert WrongState(info.state, STATE_UNDER_ATTACK);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        registry.promote(AGREEMENT);
        vm.stopBroadcast();

        uint256 promotionTime = block.timestamp + 3 days;
        console.log("\n=== ByteStrike Promotion Requested ===");
        console.log("Agreement:         ", AGREEMENT);
        console.log("AttackRegistry:    ", _bcAttackRegistry());
        console.log("Promotion unlocks: ", promotionTime);
        console.log("(contracts still attackable for 3 days - cancel if issues found)");
    }
}
