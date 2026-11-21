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
        clearingHouse.openPosition(ETH_PERP, true, 9e18, 0);
        setOraclePrice(1_880e18);
        assertTrue(isLiquidatable(alice), "alice should be liquidatable");

        uint256 keeperBefore = getCollateralBalance(liquidator);
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 9e18, 0);

        assertEq(getPosition(alice).size, 0, "position liquidated");
        assertGt(getCollateralBalance(liquidator), keeperBefore, "keeper received incentive");
    }
}
