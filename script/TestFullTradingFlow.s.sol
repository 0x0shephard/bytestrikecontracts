// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/ClearingHouse.sol";
import "../src/Interfaces/IClearingHouse.sol";
import "../src/Interfaces/ICollateralVault.sol";

interface IERC20Mintable {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
}

/**
 * @title TestFullTradingFlow
 * @notice Test the complete trading flow: approve → deposit → open position
 */
contract TestFullTradingFlow is Script {
    address constant MUSDC = 0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7;
    address constant NEW_CH = 0x18F863b1b0A3Eca6B2235dc1957291E357f490B0;
    address constant VAULT = 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2;
    bytes32 constant H100_MARKET = 0x2bc0c3f3ef82289c7da8a9335c83ea4f2b5b8bd62b67c4f4e0dba00b304c2937;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== FULL TRADING FLOW TEST ===");
        console.log("User:", deployer);
        console.log("");

        // Check initial state
        IERC20Mintable musdc = IERC20Mintable(MUSDC);
        ClearingHouse ch = ClearingHouse(NEW_CH);
        ICollateralVault vault = ICollateralVault(VAULT);

        console.log("INITIAL STATE:");
        uint256 balance = musdc.balanceOf(deployer);
        console.log("  mUSDC balance:", balance / 1e6, "mUSDC (6 decimals)");

        uint256 allowance = musdc.allowance(deployer, NEW_CH);
        console.log("  Allowance:", allowance / 1e6, "mUSDC");

        uint256 vaultBal = vault.balanceOf(deployer, MUSDC);
        console.log("  Vault balance:", vaultBal / 1e6, "mUSDC");

        int256 accountValue = ch.getAccountValue(deployer);
        console.log("  Account value:", uint256(accountValue >= 0 ? accountValue : -accountValue) / 1e18, "USD (1e18)");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Mint if needed
        if (balance < 1000e6) {
            console.log("Step 1: Minting 10,000 mUSDC...");
            musdc.mint(deployer, 10000e6);
            console.log("  Minted 10,000 mUSDC");
            balance = musdc.balanceOf(deployer);
            console.log("  New balance:", balance / 1e6, "mUSDC");
            console.log("");
        } else {
            console.log("Step 1: Sufficient mUSDC balance");
            console.log("");
        }

        // Step 2: Approve
        console.log("Step 2: Approving 10,000 mUSDC to ClearingHouse...");
        musdc.approve(NEW_CH, 10000e6);
        uint256 newAllowance = musdc.allowance(deployer, NEW_CH);
        console.log("  Approved! New allowance:", newAllowance / 1e6, "mUSDC");
        console.log("");

        // Step 3: Deposit
        console.log("Step 3: Depositing 1,000 mUSDC to vault...");
        ch.deposit(MUSDC, 1000e6);
        uint256 newVaultBal = vault.balanceOf(deployer, MUSDC);
        console.log("  Deposited! Vault balance:", newVaultBal / 1e6, "mUSDC");

        int256 newAccountValue = ch.getAccountValue(deployer);
        console.log("  Account value:", uint256(newAccountValue >= 0 ? newAccountValue : -newAccountValue) / 1e18, "USD");
        console.log("");

        // Step 4: Open position
        console.log("Step 4: Opening long position (0.1 GPU-HRS)...");
        console.log("  Size: 0.1 GPU-HRS");
        console.log("  Direction: Long");
        console.log("  Market: H100-PERP");

        uint128 size = uint128(0.1e18); // 0.1 GPU hours
        uint128 priceLimit = 0; // No limit

        ch.openPosition(H100_MARKET, true, size, priceLimit);
        console.log("  Position opened!");
        console.log("");

        // Step 5: Check final state
        console.log("Step 5: Checking final state...");
        IClearingHouse.PositionView memory position = ch.getPosition(deployer, H100_MARKET);

        console.log("  Position size:", uint256(position.size >= 0 ? position.size : -position.size) / 1e18, "GPU-HRS");
        console.log("  Position margin:", position.margin / 1e18, "USD (1e18)");
        console.log("  Entry price:", position.entryPriceX18 / 1e18, "USD/GPU-HR");

        uint256 reservedMargin = ch._totalReservedMargin(deployer);
        console.log("  Reserved margin:", reservedMargin / 1e18, "USD");

        int256 finalAccountValue = ch.getAccountValue(deployer);
        console.log("  Final account value:", uint256(finalAccountValue >= 0 ? finalAccountValue : -finalAccountValue) / 1e18, "USD");
        console.log("  Value is:", finalAccountValue >= 0 ? "POSITIVE" : "NEGATIVE");
        console.log("");

        vm.stopBroadcast();

        console.log("=== TEST COMPLETE ===");
        console.log("");
        console.log("Summary:");
        console.log("  [OK] Approved mUSDC");
        console.log("  [OK] Deposited 1,000 mUSDC");
        console.log("  [OK] Opened 0.1 GPU-HRS long position");
        console.log("  [OK] Account value is", finalAccountValue >= 0 ? "positive" : "negative");

        require(finalAccountValue >= 0, "Account value should not be negative!");
        console.log("");
        console.log("ALL TESTS PASSED!");
    }
}
