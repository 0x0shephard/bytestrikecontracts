// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";

/**
 * @title EnableUSDCCollateral
 * @notice Enable USDC as collateral in the CollateralVault
 */
contract EnableUSDCCollateral is Script {
    address constant COLLATERAL_VAULT = 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0;
    address constant MOCK_USDC = 0x71075745A2A63dff3BD4819e9639D0E412c14AA9;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  ENABLE USDC COLLATERAL");
        console.log("=========================================");
        console.log("");
        console.log("Admin:", deployer);
        console.log("Vault:", COLLATERAL_VAULT);
        console.log("USDC:", MOCK_USDC);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        CollateralVault vault = CollateralVault(COLLATERAL_VAULT);

        // USDC configuration
        // token: USDC address
        // baseUnit: 1e6 (USDC has 6 decimals)
        // haircutBps: 0 (no haircut for stablecoin)
        // liqIncentiveBps: 500 (5% liquidation incentive)
        // cap: 0 (no protocol-wide cap)
        // accountCap: 0 (no per-account cap)
        // enabled: true
        // oracleSymbol: "USDC"

        console.log("Registering USDC collateral configuration...");
        console.log("  Base Unit: 1000000 (6 decimals)");
        console.log("  Haircut: 0 bps (0%)");
        console.log("  Liq Incentive: 500 bps (5%)");
        console.log("  Oracle Symbol: USDC");
        console.log("");

        ICollateralVault.CollateralConfig memory config = ICollateralVault.CollateralConfig({
            token: MOCK_USDC,
            baseUnit: 1e6,
            haircutBps: 0,
            liqIncentiveBps: 500,
            cap: 0,
            accountCap: 0,
            enabled: true,
            depositPaused: false,
            withdrawPaused: false,
            oracleSymbol: "USDC"
        });

        vault.registerCollateral(config);

        console.log("SUCCESS: USDC enabled as collateral!");

        vm.stopBroadcast();

        // Verify
        console.log("");
        console.log("Verification:");

        ICollateralVault.CollateralConfig memory verifyConfig = vault.getConfig(MOCK_USDC);
        console.log("  Token:", verifyConfig.token);
        console.log("  Base Unit:", verifyConfig.baseUnit);
        console.log("  Haircut BPS:", verifyConfig.haircutBps);
        console.log("  Liq Incentive BPS:", verifyConfig.liqIncentiveBps);
        console.log("  Enabled:", verifyConfig.enabled);
        console.log("  Oracle Symbol:", verifyConfig.oracleSymbol);
        console.log("");

        console.log("=========================================");
        console.log("  SETUP COMPLETE!");
        console.log("=========================================");
    }
}
