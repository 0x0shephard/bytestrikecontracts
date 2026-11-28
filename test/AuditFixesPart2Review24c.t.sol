// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";

/// @notice Regression for finding 24 (third mitigation review): depositMargin stays open while the
/// market's quote token is being retired (disabled for new deposits), so a fully allocated trader can
/// still top up a position the keeper could otherwise liquidate.
contract AuditFixesPart2Review24cTest is BaseTest {
    function setUp() public override {
        super.setUp();

        // alice opens a 10 ETH long with almost all of her deposit reserved as margin
        fundAndDeposit(alice, 1_400e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);

        // she keeps wallet USDC to top up with
        fundUser(alice, 10_000e18);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        // the quote token is retired: no new deposits, existing balances keep backing positions
        ICollateralVault.CollateralConfig memory cfg = vault.getConfig(address(usdc));
        cfg.enabled = false;
        vm.prank(admin);
        vault.setCollateralParams(address(usdc), cfg);

        // the index falls 3% and the long is liquidatable
        setOraclePrice(INITIAL_ETH_PRICE * 97 / 100);
        assertTrue(isLiquidatable(alice), "not liquidatable");
    }

    function test_DepositMarginCuresWhileQuoteTokenRetired() public {
        // a plain deposit is refused while the token is retired
        vm.prank(alice);
        vm.expectRevert("CV: token disabled");
        clearingHouse.deposit(address(usdc), 300e18);

        // the top-up path still takes the deposit and cures the position
        uint256 marginBefore = getMargin(alice);
        vm.prank(alice);
        clearingHouse.depositMargin(ETH_PERP, 300e18);
        assertEq(getMargin(alice), marginBefore + 300e18, "margin not added");
        assertFalse(isLiquidatable(alice), "top-up did not cure");

        // the keeper has nothing to liquidate
        vm.prank(liquidator);
        vm.expectRevert();
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);
    }

    function test_DepositMarginBoundStillAppliesWhileRetired() public {
        // the clearing house bound still caps the top-up at the initial margin
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("ExceedsMarginTopUp()")));
        clearingHouse.depositMargin(ETH_PERP, 5_000e18);
    }
}
