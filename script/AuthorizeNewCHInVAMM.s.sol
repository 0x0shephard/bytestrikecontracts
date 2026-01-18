// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";

interface IVAMM {
    function clearinghouse() external view returns (address);
    function setClearinghouse(address newCH) external;
    function owner() external view returns (address);
}

/**
 * @title AuthorizeNewCHInVAMM
 * @notice Authorize the new ClearingHouse in vAMM proxy
 *
 * The vAMM has an `onlyCH` modifier that checks msg.sender == clearinghouse.
 * We need to update the vAMM to use the new ClearingHouse address.
 */
contract AuthorizeNewCHInVAMM is Script {
    address constant VAMM_PROXY = 0xF7210ccC245323258CC15e0Ca094eBbe2DC2CD85;
    address constant NEW_CH = 0x18F863b1b0A3Eca6B2235dc1957291E357f490B0;
    address constant OLD_CH = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== AUTHORIZE NEW CLEARINGHOUSE IN VAMM ===");
        console.log("Deployer:", deployer);
        console.log("vAMM Proxy:", VAMM_PROXY);
        console.log("New ClearingHouse:", NEW_CH);
        console.log("");

        IVAMM vamm = IVAMM(VAMM_PROXY);

        // Check current state
        address currentOwner = vamm.owner();
        address currentCH = vamm.clearinghouse();

        console.log("CURRENT STATE:");
        console.log("  vAMM Owner:", currentOwner);
        console.log("  Current CH:", currentCH);
        console.log("");

        require(currentOwner == deployer, "Deployer is not vAMM owner");

        vm.startBroadcast(deployerPrivateKey);

        console.log("Setting new ClearingHouse in vAMM...");
        vamm.setClearinghouse(NEW_CH);
        console.log("vAMM updated!");
        console.log("");

        vm.stopBroadcast();

        // Verify
        address newCH = vamm.clearinghouse();
        console.log("VERIFICATION:");
        console.log("  New CH in vAMM:", newCH);
        console.log("  Expected:", NEW_CH);
        console.log("");

        require(newCH == NEW_CH, "vAMM authorization failed");

        console.log("=== SUCCESS ===");
        console.log("vAMM now authorized for new ClearingHouse");
        console.log("Users can now open positions!");
    }
}
