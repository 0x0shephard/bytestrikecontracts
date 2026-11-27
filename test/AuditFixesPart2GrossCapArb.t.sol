// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";

/// @notice Finding 50: a filled gross OI cap cannot stop arbitrage from trading a pushed premium back
///         to the index.
contract AuditFixesPart2GrossCapArbTest is BaseTest {
    address internal carol = makeAddr("carol");
    address internal frank = makeAddr("frank");

    function setUp() public override {
        super.setUp();
        fundAndDeposit(alice, 20_000e18);
        fundAndDeposit(bob, 20_000e18);
        fundAndDeposit(carol, 20_000e18);
        fundAndDeposit(frank, 20_000e18);
        vm.prank(admin);
        clearingHouse.setOpenInterestCaps(ETH_PERP, 6 ether, 0);

        // Bob and Carol fill part of the cap with an offsetting pair; Alice's long fills the rest and
        // pushes the mark above the index.
        _open(bob, true, 2 ether);
        _open(carol, false, 2 ether);
        _open(alice, true, 2 ether);
        assertEq(_gross(), 6 ether);
        assertGt(vamm.getMarkPrice(), oracle.getPrice());
    }

    function _open(address trader, bool isLong, uint128 size) internal {
        vm.prank(trader);
        clearingHouse.openPosition(ETH_PERP, isLong, size, 0);
    }

    function _gross() internal view returns (uint256) {
        return clearingHouse.totalLongOI(ETH_PERP) + clearingHouse.totalShortOI(ETH_PERP);
    }

    function test_Finding50_ShortIntoPremiumPassesFullGrossCap() public {
        _open(frank, false, 1 ether);
        assertEq(_gross(), 7 ether);
        assertGe(vamm.getMarkPrice(), oracle.getPrice());
    }

    function test_Finding50_AboveCapTradeMayNotCrossTheIndex() public {
        vm.prank(frank);
        vm.expectRevert(ClearingHouse.ExceedsMaxGrossOI.selector);
        clearingHouse.openPosition(ETH_PERP, false, 3 ether, 0);
    }

    function test_Finding50_AboveCapTradeMayNotMoveAwayFromIndex() public {
        vm.prank(frank);
        vm.expectRevert(ClearingHouse.ExceedsMaxGrossOI.selector);
        clearingHouse.openPosition(ETH_PERP, true, 1 ether, 0);

        // Above the cap even a flip that keeps gross unchanged must move the mark toward the index.
        _open(frank, false, 1 ether);
        vm.prank(carol);
        vm.expectRevert(ClearingHouse.ExceedsMaxGrossOI.selector);
        clearingHouse.openPosition(ETH_PERP, true, 4 ether, 0);
    }
}
