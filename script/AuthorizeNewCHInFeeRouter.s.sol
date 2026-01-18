// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";

interface IFeeRouter {
    function setClearinghouse(address ch) external;
    function clearinghouse() external view returns (address);
}

/**
 * @title AuthorizeNewCHInFeeRouter
 * @notice Authorize the new ClearingHouse in FeeRouter
 */
contract AuthorizeNewCHInFeeRouter is Script {
    address constant FEE_ROUTER = 0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F;
    address constant NEW_CH = 0x18F863b1b0A3Eca6B2235dc1957291E357f490B0;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== AUTHORIZE NEW CLEARINGHOUSE IN FEEROUTER ===");
        console.log("Deployer:", deployer);
        console.log("FeeRouter:", FEE_ROUTER);
        console.log("New ClearingHouse:", NEW_CH);
        console.log("");

        IFeeRouter feeRouter = IFeeRouter(FEE_ROUTER);

        address currentCH = feeRouter.clearinghouse();
        console.log("Current CH:", currentCH);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        console.log("Setting new ClearingHouse in FeeRouter...");
        feeRouter.setClearinghouse(NEW_CH);
        console.log("FeeRouter updated!");
        console.log("");

        vm.stopBroadcast();

        address newCH = feeRouter.clearinghouse();
        console.log("VERIFICATION:");
        console.log("  New CH:", newCH);
        console.log("  Expected:", NEW_CH);

        require(newCH == NEW_CH, "FeeRouter authorization failed");

        console.log("");
        console.log("=== SUCCESS ===");
    }
}
