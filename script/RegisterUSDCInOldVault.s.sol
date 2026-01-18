// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";

/**
 * @title RegisterUSDCInOldVault
 * @notice Registers USDC in the old CollateralVault that ClearingHouse uses
 */
contract RegisterUSDCInOldVault is Script {
    address constant OLD_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;
    address constant MOCK_USDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  REGISTER USDC IN OLD VAULT");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Old CollateralVault:", OLD_VAULT);
        console.log("Mock USDC:", MOCK_USDC);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        ICollateralVault.CollateralConfig memory config = ICollateralVault.CollateralConfig({
            token: MOCK_USDC,
            baseUnit: 1e6,
            haircutBps: 0,                  // 0% haircut for stablecoin
            liqIncentiveBps: 500,           // 5% liquidation incentive
            cap: 0,                         // No total cap
            accountCap: 0,                  // No per-account cap
            enabled: true,
            depositPaused: false,
            withdrawPaused: false,
            oracleSymbol: "USDC"
        });

        console.log("Registering USDC collateral:");
        console.log("  Base Unit:", config.baseUnit);
        console.log("  Haircut:", config.haircutBps, "bps");
        console.log("  Oracle Symbol:", config.oracleSymbol);
        console.log("");

        ICollateralVault(OLD_VAULT).registerCollateral(config);
        console.log("USDC collateral registered!");

        vm.stopBroadcast();

        console.log("");
        console.log("=========================================");
        console.log("  REGISTRATION COMPLETE");
        console.log("=========================================");
    }
}
