// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";

/// @notice Finding 43: a trade that parks a vAMM reserve on its floor cannot block liquidations.
contract AuditFixesPart2LiquidationFloorTest is BaseTest {
    function setUp() public override {
        super.setUp();
        fundAndDeposit(alice, 1_100 * USDC_UNIT);
        fundAndDeposit(bob, 100_000 * USDC_UNIT);
    }

    /// @notice An oversized short parks the quote reserve on its floor; the long is still liquidated.
    function test_Finding43_longLiquidationPassesParkedQuoteFloor() public {
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        setOraclePrice(1_925 ether);
        assertTrue(isLiquidatable(alice));

        // Floor 100 quote below the reserve; bob's oversized short fills to it.
        (, uint256 y) = getReserves();
        vm.prank(admin);
        vamm.setMinReserves(0, y - 100 ether);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 10 ether, 0);
        (, y) = getReserves();
        assertEq(y, vamm.minReserveQuote(), "quote reserve parked on its floor");

        // Ordinary trades on that side still hit the floor.
        vm.prank(bob);
        vm.expectRevert(bytes("Reserve quote depleted"));
        clearingHouse.openPosition(ETH_PERP, false, 1 ether, 0);

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10 ether, 0);
        assertEq(getPosition(alice).size, 0, "long not liquidated");
    }

    /// @notice An oversized long parks the base reserve on its floor; the short is still liquidated.
    function test_Finding43_shortLiquidationPassesParkedBaseFloor() public {
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, false, 10 ether, 0);
        setOraclePrice(2_075 ether);
        assertTrue(isLiquidatable(alice));

        (uint256 x,) = getReserves();
        vm.prank(admin);
        vamm.setMinReserves(x - 0.05 ether, 0);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        (x,) = getReserves();
        assertEq(x, vamm.minReserveBase(), "base reserve parked on its floor");

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10 ether, 0);
        assertEq(getPosition(alice).size, 0, "short not liquidated");
    }

    /// @notice Only the ClearingHouse can trade through the floors.
    function test_Finding43_liquidationSwapIsClearingHouseOnly() public {
        vm.expectRevert(bytes("Not CH"));
        vamm.liquidationSwap(true, 1 ether, 0);
    }
}
