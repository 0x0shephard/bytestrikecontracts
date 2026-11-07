// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeClearingHouseRiskControls
 * @notice Deploys a ClearingHouse implementation with the trader allowlist and the
 *         per-market open-interest caps, and upgrades the proxy if the broadcaster owns it.
 * @dev Reuses the deployed ClearingHouseLogic: its executable code is unchanged by these features.
 *      Both features start switched off: the allowlist is not enforced and every market has no OI cap.
 *      If the proxy owner is a multisig, the script only deploys the implementation and prints the
 *      upgrade calldata for the multisig to execute.
 *
 *      Env: PRIVATE_KEY (required), CLEARING_HOUSE_PROXY and CLEARING_HOUSE_LOGIC (default to Sepolia).
 */
contract UpgradeClearingHouseRiskControls is Script {
    address constant SEPOLIA_PROXY = 0xDf4DDD4019097B335dD507f916984A1A53E40a0d;
    address constant SEPOLIA_LOGIC = 0x8a7FD495fECBc46e427A309d0f3cC5FC9355860d;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(pk);
        address proxyAddr = vm.envOr("CLEARING_HOUSE_PROXY", SEPOLIA_PROXY);
        address logic = vm.envOr("CLEARING_HOUSE_LOGIC", SEPOLIA_LOGIC);
        require(logic.code.length > 0, "Logic not deployed");

        ClearingHouse proxy = ClearingHouse(proxyAddr);
        address owner = proxy.owner();

        console.log("Proxy:", proxyAddr);
        console.log("Logic (reused):", logic);
        console.log("Proxy owner:", owner);
        console.log("Broadcaster:", broadcaster);

        vm.startBroadcast(pk);
        ClearingHouse newImpl = new ClearingHouse(logic);
        bool canUpgrade = broadcaster == owner;
        if (canUpgrade) proxy.upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        console.log("New implementation:", address(newImpl));
        if (canUpgrade) {
            console.log("Proxy upgraded.");
            console.log("allowlistEnforced:", proxy.allowlistEnforced());
        } else {
            console.log("Broadcaster is not the owner. Submit this call from the owner multisig:");
            console.log("  to:", proxyAddr);
            console.logBytes(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newImpl), "")));
        }
        console.log("Next: set caps per market with setOpenInterestCaps(marketId, maxGrossOI, maxNetOI).");
    }
}
