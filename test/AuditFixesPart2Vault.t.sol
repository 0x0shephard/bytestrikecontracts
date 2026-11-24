// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";

/// @notice Regression tests for CollateralVault audit fixes (Cyfrin bytestrike part 2).
contract AuditFixesPart2VaultTest is BaseTest {
    function _setUsdcAccountCap(uint256 accountCap) internal {
        ICollateralVault.CollateralConfig memory cfg = vault.getConfig(address(usdc));
        cfg.accountCap = accountCap;
        vm.prank(admin);
        vault.setCollateralParams(address(usdc), cfg);
    }

    /// @notice Finding 11: seize moves collateral between internal balances and must not
    /// apply the deposit accountCap to the recipient.
    function test_Finding11_seizeIgnoresRecipientAccountCap() public {
        fundAndDeposit(alice, 1_000 * USDC_UNIT);
        fundAndDeposit(liquidator, 1_000 * USDC_UNIT);
        _setUsdcAccountCap(1_000 * USDC_UNIT);

        vm.prank(address(clearingHouse));
        vault.seize(alice, liquidator, address(usdc), 300 * USDC_UNIT);

        assertEq(vault.balanceOf(liquidator, address(usdc)), 1_300 * USDC_UNIT, "recipient credited above cap");
        assertEq(vault.balanceOf(alice, address(usdc)), 700 * USDC_UNIT, "source debited");
    }

    /// @notice Finding 11: a keeper whose vault balance sits at the account cap can still liquidate.
    function test_Finding11_liquidationSucceedsWithKeeperAtCap() public {
        fundAndDeposit(alice, 1_000 * USDC_UNIT);
        fundAndDeposit(liquidator, 1_000 * USDC_UNIT);
        _setUsdcAccountCap(1_000 * USDC_UNIT);

        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 8e18, 0);
        setOraclePrice(1_880e18);
        assertTrue(isLiquidatable(alice), "alice should be liquidatable");

        uint256 keeperBefore = getCollateralBalance(liquidator);
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 8e18, 0);

        assertEq(getPosition(alice).size, 0, "position liquidated");
        assertGt(getCollateralBalance(liquidator), keeperBefore, "keeper received incentive");
    }

    function _setUsdcEnabled(bool enabled) internal {
        ICollateralVault.CollateralConfig memory cfg = vault.getConfig(address(usdc));
        cfg.enabled = enabled;
        vm.prank(admin);
        vault.setCollateralParams(address(usdc), cfg);
    }

    /// @notice Finding 64: a 100% haircut would value every balance at 0, so it is rejected.
    function test_Finding64_fullHaircutRejected() public {
        ICollateralVault.CollateralConfig memory cfg = vault.getConfig(address(usdc));
        cfg.haircutBps = 10_000;
        vm.prank(admin);
        vm.expectRevert("CV: haircutBps exceeds max");
        vault.setCollateralParams(address(usdc), cfg);

        cfg.haircutBps = 9_999;
        vm.prank(admin);
        vault.setCollateralParams(address(usdc), cfg);
    }

    /// @notice Finding 64: disabling the quote token blocks new deposits only. Existing balances keep
    /// their value, so a trader can still top up and close.
    function test_Finding64_disabledQuoteTokenStillAllowsTopUpAndClose() public {
        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 9e18, 0);

        _setUsdcEnabled(false);
        assertGt(vault.getTokenValueX18(address(usdc), 1_000 * USDC_UNIT), 0, "existing balances keep value");

        // New deposits are blocked
        usdc.mint(alice, 100 * USDC_UNIT);
        vm.prank(alice);
        usdc.approve(address(vault), 100 * USDC_UNIT);
        vm.prank(address(clearingHouse));
        vm.expectRevert("CV: token disabled");
        vault.deposit(address(usdc), 100 * USDC_UNIT, alice);

        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, 500 * USDC_UNIT);
        clearingHouse.closePosition(ETH_PERP, 9e18, 0);
        vm.stopPrank();
        assertEq(getPosition(alice).size, 0, "alice closed");
    }

    /// @notice Finding 64: a position quoted in a disabled token can still be liquidated.
    function test_Finding64_disabledQuoteTokenStillAllowsLiquidation() public {
        fundAndDeposit(alice, 1_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 8e18, 0);

        _setUsdcEnabled(false);
        setOraclePrice(1_880e18);
        assertTrue(isLiquidatable(alice), "alice should be liquidatable");

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 8e18, 0);
        assertEq(getPosition(alice).size, 0, "position liquidated");
    }

    /// @notice Finding 64: an unregistered token is still valued at 0.
    function test_Finding64_unregisteredTokenValuedAtZero() public {
        assertEq(vault.getTokenValueX18(makeAddr("unregistered"), 1e18), 0);
    }
}
