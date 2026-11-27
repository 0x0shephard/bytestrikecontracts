// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";

/// @notice Finding 24: a fully allocated trader can top up a position while vault deposits are
///         paused or capped.
contract AuditFixesPart2DepositMarginTest is BaseTest {
    function setUp() public override {
        super.setUp();
        // Alice's whole balance backs a 10 ETH long; the index then falls 4%, below maintenance.
        fundAndDeposit(alice, 1_300e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        oracle.setPrice(INITIAL_ETH_PRICE * 96 / 100);
        assertTrue(clearingHouse.isLiquidatable(alice, ETH_PERP));
        fundUser(alice, 10_000e18);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _setUsdc(bool depositPaused, uint256 cap) internal {
        ICollateralVault.CollateralConfig memory cfg = vault.getConfig(address(usdc));
        cfg.depositPaused = depositPaused;
        cfg.cap = cap;
        vm.prank(admin);
        vault.setCollateralParams(address(usdc), cfg);
    }

    function test_Finding24_TopUpWhileDepositsPaused() public {
        _setUsdc(true, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert("CV: deposits paused");
        clearingHouse.deposit(address(usdc), 400e18);

        uint256 marginBefore = clearingHouse.getPosition(alice, ETH_PERP).margin;
        vm.prank(alice);
        clearingHouse.depositMargin(ETH_PERP, 400e18);
        assertEq(clearingHouse.getPosition(alice, ETH_PERP).margin, marginBefore + 400e18);
        assertFalse(clearingHouse.isLiquidatable(alice, ETH_PERP));
    }

    function test_Finding24_TopUpWhileVaultCapFull() public {
        _setUsdc(false, usdc.balanceOf(address(vault)));
        vm.prank(alice);
        vm.expectRevert("CV: token cap");
        clearingHouse.deposit(address(usdc), 400e18);

        vm.prank(alice);
        clearingHouse.depositMargin(ETH_PERP, 400e18);
        assertFalse(clearingHouse.isLiquidatable(alice, ETH_PERP));
    }

    /// @notice A top-up only restores the initial margin: more reverts, and the margin added stays
    ///         locked while the position is below it.
    function test_Finding24_TopUpBoundedByInitialMargin() public {
        _setUsdc(true, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.ExceedsMarginTopUp.selector);
        clearingHouse.depositMargin(ETH_PERP, 2_000e18);

        vm.prank(alice);
        clearingHouse.depositMargin(ETH_PERP, 400e18);
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.IMRBreach.selector);
        clearingHouse.removeMargin(ETH_PERP, 1e18);
    }

    function test_Finding24_TopUpNeedsPosition() public {
        vm.prank(bob);
        vm.expectRevert(ClearingHouse.NoPosition.selector);
        clearingHouse.depositMargin(ETH_PERP, 1e18);
    }
}
