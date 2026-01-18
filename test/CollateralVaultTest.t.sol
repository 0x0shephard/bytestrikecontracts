// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {MockERC20} from "../script/MockERC20.sol";

/// @title CollateralVaultTest
/// @notice Comprehensive tests for CollateralVault
contract CollateralVaultTest is BaseTest {

    MockERC20 public dai;
    MockERC20 public wbtc;

    function setUp() public override {
        super.setUp();

        // Deploy additional test tokens
        vm.startPrank(admin);
        dai = new MockERC20("DAI", "DAI", 18);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        vm.stopPrank();
    }

    // ============ Admin Functions ============

    function test_SetOracle() public {
        address newOracle = makeAddr("newOracle");

        vm.prank(admin);
        vault.setOracle(newOracle);

        assertEq(vault.getOracle(), newOracle, "Oracle not updated");
    }

    function test_RevertWhen_SetOracle_NotAdmin() public {
        address newOracle = makeAddr("newOracle");

        vm.expectRevert();
        vm.prank(alice);
        vault.setOracle(newOracle);
    }

    // Note: setOracle does not validate zero address

    function test_SetClearinghouse() public {
        address newClearinghouse = makeAddr("newClearinghouse");

        vm.prank(admin);
        vault.setClearinghouse(newClearinghouse);

        assertEq(vault.getClearinghouse(), newClearinghouse, "Clearinghouse not updated");
    }

    function test_RevertWhen_SetClearinghouse_NotAdmin() public {
        address newClearinghouse = makeAddr("newClearinghouse");

        vm.expectRevert();
        vm.prank(alice);
        vault.setClearinghouse(newClearinghouse);
    }

    // Note: setClearinghouse does not validate zero address

    function test_RegisterCollateral() public {
        vm.prank(admin);
        vault.registerCollateral(
            ICollateralVault.CollateralConfig({
                token: address(dai),
                baseUnit: 1e18,
                haircutBps: 500, // 5%
                liqIncentiveBps: 200,
                cap: 1000000 * 1e18,
                accountCap: 50000 * 1e18,
                enabled: true,
                depositPaused: false,
                withdrawPaused: false,
                oracleSymbol: "DAI"
            })
        );

        assertTrue(vault.isEnabled(address(dai)), "Collateral not enabled");
    }

    function test_RevertWhen_RegisterCollateral_NotAdmin() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.registerCollateral(
            ICollateralVault.CollateralConfig({
                token: address(dai),
                baseUnit: 1e18,
                haircutBps: 500,
                liqIncentiveBps: 200,
                cap: 1000000 * 1e18,
                accountCap: 50000 * 1e18,
                enabled: true,
                depositPaused: false,
                withdrawPaused: false,
                oracleSymbol: "DAI"
            })
        );
    }

    // Note: CollateralVault does not validate zero address or duplicate registration
    // These operations will succeed without reverting

    function test_SetCollateralParams() public {
        vm.prank(admin);
        vault.setCollateralParams(
            address(usdc),
            ICollateralVault.CollateralConfig({
                token: address(usdc),
                baseUnit: 1e18,
                haircutBps: 1000, // Changed to 10%
                liqIncentiveBps: 300, // Changed to 3%
                cap: 2000000 * 1e18,
                accountCap: 100000 * 1e18,
                enabled: true,
                depositPaused: false,
                withdrawPaused: false,
                oracleSymbol: "USDC"
            })
        );

        ICollateralVault.CollateralConfig memory cfg = vault.getConfig(address(usdc));
        assertEq(cfg.haircutBps, 1000, "Haircut not updated");
        assertEq(cfg.liqIncentiveBps, 300, "Liq incentive not updated");
    }

    function test_RevertWhen_SetCollateralParams_NotAdmin() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.setCollateralParams(
            address(usdc),
            ICollateralVault.CollateralConfig({
                token: address(usdc),
                baseUnit: 1e18,
                haircutBps: 1000,
                liqIncentiveBps: 300,
                cap: 2000000 * 1e18,
                accountCap: 100000 * 1e18,
                enabled: true,
                depositPaused: false,
                withdrawPaused: false,
                oracleSymbol: "USDC"
            })
        );
    }

    // Note: setCollateralParams does not validate if token is registered
    // It will create a new entry even for unregistered tokens

    function test_SetPause() public {
        vm.prank(admin);
        vault.setPause(address(usdc), true, true);

        assertTrue(vault.isDepositPaused(address(usdc)), "Deposits not paused");
        assertTrue(vault.isWithdrawPaused(address(usdc)), "Withdrawals not paused");

        vm.prank(admin);
        vault.setPause(address(usdc), false, false);

        assertFalse(vault.isDepositPaused(address(usdc)), "Deposits still paused");
        assertFalse(vault.isWithdrawPaused(address(usdc)), "Withdrawals still paused");
    }

    function test_RevertWhen_SetPause_NotAdmin() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.setPause(address(usdc), true, true);
    }

    // ============ Deposit Tests ============

    function test_Deposit_Basic() public {
        uint256 amount = 1000 * USDC_UNIT;
        fundUser(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);

        vm.stopPrank();

        vm.prank(address(clearingHouse));
        uint256 received = vault.deposit(address(usdc), amount, alice);

        assertEq(received, amount, "Received amount incorrect");
        assertEq(vault.balanceOf(alice, address(usdc)), amount, "Balance not updated");
    }

    function test_RevertWhen_Deposit_NotClearinghouse() public {
        uint256 amount = 1000 * USDC_UNIT;
        fundUser(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);

        vm.expectRevert();
        vault.deposit(address(usdc), amount, alice);
        vm.stopPrank();
    }

    function test_RevertWhen_Deposit_Paused() public {
        vm.prank(admin);
        vault.setPause(address(usdc), true, false);

        uint256 amount = 1000 * USDC_UNIT;
        fundUser(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vm.stopPrank();

        vm.expectRevert("Deposits paused");
        vm.prank(address(clearingHouse));
        vault.deposit(address(usdc), amount, alice);
    }

    function test_RevertWhen_Deposit_NotEnabled() public {
        // Register DAI but disable it
        vm.prank(admin);
        vault.registerCollateral(
            ICollateralVault.CollateralConfig({
                token: address(dai),
                baseUnit: 1e18,
                haircutBps: 500,
                liqIncentiveBps: 200,
                cap: 1000000 * 1e18,
                accountCap: 50000 * 1e18,
                enabled: false, // Disabled
                depositPaused: false,
                withdrawPaused: false,
                oracleSymbol: "DAI"
            })
        );

        uint256 amount = 1000 * 1e18;
        dai.mint(alice, amount);

        vm.prank(alice);
        dai.approve(address(vault), amount);

        vm.expectRevert("Token not enabled");
        vm.prank(address(clearingHouse));
        vault.deposit(address(dai), amount, alice);
    }

    // ============ Withdraw Tests ============

    function test_WithdrawFor_Basic() public {
        uint256 depositAmount = 1000 * USDC_UNIT;
        fundAndDeposit(alice, depositAmount);

        uint256 withdrawAmount = 500 * USDC_UNIT;

        vm.prank(address(clearingHouse));
        vault.withdrawFor(alice, address(usdc), withdrawAmount, alice);

        assertEq(vault.balanceOf(alice, address(usdc)), depositAmount - withdrawAmount, "Balance incorrect");
        assertEq(usdc.balanceOf(alice), withdrawAmount, "Withdrawn amount incorrect");
    }

    function test_RevertWhen_WithdrawFor_NotClearinghouse() public {
        fundAndDeposit(alice, 1000 * USDC_UNIT);

        vm.expectRevert();
        vm.prank(alice);
        vault.withdrawFor(alice, address(usdc), 500 * USDC_UNIT, alice);
    }

    function test_RevertWhen_WithdrawFor_Paused() public {
        fundAndDeposit(alice, 1000 * USDC_UNIT);

        vm.prank(admin);
        vault.setPause(address(usdc), false, true);

        vm.expectRevert("Withdrawals paused");
        vm.prank(address(clearingHouse));
        vault.withdrawFor(alice, address(usdc), 500 * USDC_UNIT, alice);
    }

    function test_RevertWhen_WithdrawFor_InsufficientBalance() public {
        fundAndDeposit(alice, 1000 * USDC_UNIT);

        vm.expectRevert("Insufficient balance");
        vm.prank(address(clearingHouse));
        vault.withdrawFor(alice, address(usdc), 2000 * USDC_UNIT, alice);
    }

    // ============ Seize Tests ============

    function test_Seize() public {
        fundAndDeposit(alice, 1000 * USDC_UNIT);

        uint256 seizeAmount = 300 * USDC_UNIT;

        vm.prank(address(clearingHouse));
        vault.seize(alice, bob, address(usdc), seizeAmount);

        assertEq(vault.balanceOf(alice, address(usdc)), 1000 * USDC_UNIT - seizeAmount, "Alice balance incorrect");
        assertEq(vault.balanceOf(bob, address(usdc)), seizeAmount, "Bob balance incorrect");
    }

    function test_RevertWhen_Seize_NotClearinghouse() public {
        fundAndDeposit(alice, 1000 * USDC_UNIT);

        vm.expectRevert();
        vm.prank(alice);
        vault.seize(alice, bob, address(usdc), 300 * USDC_UNIT);
    }

    function test_RevertWhen_Seize_InsufficientBalance() public {
        fundAndDeposit(alice, 1000 * USDC_UNIT);

        vm.expectRevert("Insufficient balance");
        vm.prank(address(clearingHouse));
        vault.seize(alice, bob, address(usdc), 2000 * USDC_UNIT);
    }

    // ============ View Function Tests ============

    function test_GetTokenValueX18() public {
        uint256 amount = 1000 * USDC_UNIT;
        uint256 value = vault.getTokenValueX18(address(usdc), amount);

        // With 18 decimal USDC and oracle price of $2000 (set in BaseTest for "USDC" symbol)
        // Value should be amount * oraclePrice / baseUnit
        assertTrue(value > 0, "Value should be > 0");
    }

    function test_GetAccountCollateralValueX18() public {
        fundAndDeposit(alice, 5000 * USDC_UNIT);

        uint256 value = vault.getAccountCollateralValueX18(alice);
        assertTrue(value > 0, "Account value should be > 0");
    }

    function test_GetAccountCollateralValueX18_MultipleTokens() public {
        // Register DAI
        vm.prank(admin);
        vault.registerCollateral(
            ICollateralVault.CollateralConfig({
                token: address(dai),
                baseUnit: 1e18,
                haircutBps: 500,
                liqIncentiveBps: 200,
                cap: 1000000 * 1e18,
                accountCap: 50000 * 1e18,
                enabled: true,
                depositPaused: false,
                withdrawPaused: false,
                oracleSymbol: "DAI"
            })
        );

        oracle.setSymbol("DAI");
        oracle.setPrice(1 * 1e18); // $1

        // Deposit USDC
        fundAndDeposit(alice, 5000 * USDC_UNIT);

        // Deposit DAI
        uint256 daiAmount = 3000 * 1e18;
        dai.mint(alice, daiAmount);
        vm.prank(alice);
        dai.approve(address(vault), daiAmount);
        vm.prank(address(clearingHouse));
        vault.deposit(address(dai), daiAmount, alice);

        uint256 totalValue = vault.getAccountCollateralValueX18(alice);
        assertTrue(totalValue > 0, "Total value should be > 0");
    }

    function test_BalanceOf() public {
        fundAndDeposit(alice, 5000 * USDC_UNIT);
        assertEq(vault.balanceOf(alice, address(usdc)), 5000 * USDC_UNIT, "Balance incorrect");
    }

    function test_TotalOf() public {
        fundAndDeposit(alice, 5000 * USDC_UNIT);
        fundAndDeposit(bob, 3000 * USDC_UNIT);

        assertEq(vault.totalOf(address(usdc)), 8000 * USDC_UNIT, "Total incorrect");
    }

    function test_GetConfig() public {
        ICollateralVault.CollateralConfig memory cfg = vault.getConfig(address(usdc));
        assertEq(cfg.token, address(usdc), "Token address incorrect");
        assertTrue(cfg.enabled, "Should be enabled");
    }
}
