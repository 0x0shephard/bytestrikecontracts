// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

/// @notice Finding 54: a flip keeps the market's margin for the new position and reserves only what
/// it is short of the new leg's requirement.
contract AuditFixesPart2FlipMarginTest is BaseTest {
    function setUp() public override {
        super.setUp();
        fundAndDeposit(alice, 50_000e18);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, false, 10e18, 0);
        clearingHouse.addMargin(ETH_PERP, 2_000e18);
        vm.stopPrank();
    }

    /// @notice With the index below the new long's fill, the bare initial margin left the long
    /// immediately liquidatable; the kept margin covers it.
    function test_Finding54_flipKeepsMarginAndPasses() public {
        setOraclePrice(1_950e18);
        IClearingHouse.PositionView memory before = getPosition(alice);

        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 20e18, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);
        assertEq(pos.size, 10e18, "not flipped");
        int256 realized = pos.realizedPnL - before.realizedPnL;
        // The market's margin, net of the closed short's realized result, stays on the new long.
        assertApproxEqAbs(int256(pos.margin), int256(before.margin) + realized, 1e15, "margin not kept");
        assertEq(clearingHouse._totalReservedMargin(alice), pos.margin, "reserved margin");
    }

    /// @notice A flip that passed before dropped the added margin to free collateral; now the kept
    /// margin covers the new leg and nothing more is reserved.
    function test_Finding54_flipReservesOnlyShortfall() public {
        IClearingHouse.PositionView memory before = getPosition(alice);

        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 20e18, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);
        assertEq(pos.size, 10e18, "not flipped");
        assertGt(pos.margin, 2_000e18, "added margin released by the flip");
        int256 realized = pos.realizedPnL - before.realizedPnL;
        assertApproxEqAbs(int256(pos.margin), int256(before.margin) + realized, 1e15, "reserved beyond the kept margin");
    }
}
