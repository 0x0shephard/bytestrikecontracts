// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

/// @notice Finding 40: the initial margin check of an open, increase or flip nets the position's unrealized loss.
contract AuditFixesPart2ImrLossTest is BaseTest {
    function setUp() public override {
        super.setUp();
        fundAndDeposit(alice, 50_000e18);
    }

    /// @dev Margin net of unrealized loss at the index, and the initial margin of the position.
    function _imrState(address user) internal view returns (int256 equity, uint256 required) {
        IClearingHouse.PositionView memory p = getPosition(user);
        uint256 absSize = uint256(p.size > 0 ? p.size : -p.size);
        uint256 index = oracle.getPrice();
        int256 upnl = p.size > 0
            ? (int256(index) - int256(p.entryPriceX18)) * int256(absSize) / 1e18
            : (int256(p.entryPriceX18) - int256(index)) * int256(absSize) / 1e18;
        equity = int256(p.margin) + (upnl < 0 ? upnl : int256(0));
        uint256 mark = getMarkPrice();
        uint256 px = mark > index ? mark : index;
        required = absSize * px / 1e18 * IMR_BPS / 10_000;
    }

    /// @notice A fresh open reserves its own loss at the index, so it starts at the initial margin.
    function test_Finding40_freshOpenStartsAtInitialMargin() public {
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, false, 30e18, 0);
        (int256 equity, uint256 required) = _imrState(alice);
        assertGe(equity, int256(required), "short opens below its initial margin");
    }

    /// @notice A losing long between maintenance and initial margin cannot be grown.
    function test_Finding40_losingLongCannotGrowPastMaxLeverage() public {
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        IClearingHouse.PositionView memory p = getPosition(alice);

        // Index where the equity sits halfway between maintenance and initial margin of 10 ETH.
        // equity = margin + (idx - entry) * 10; target = 3.75% * idx * 10.
        uint256 idx = (p.entryPriceX18 * 10 - p.margin) * 1e18 / (10e18 - 10e18 * 375 / 10_000);
        setOraclePrice(idx);
        assertFalse(isLiquidatable(alice));

        // Bob's short brings the mark just under the index, so the initial margin is priced at the
        // index and the margin reserved at the higher mark covers the old size.
        fundAndDeposit(bob, 50_000e18);
        (uint256 x, uint256 y) = getReserves();
        uint256 xTarget = _sqrtBase((x * y / (idx * 999 / 1000)) * 1e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, uint128(xTarget - x), 0);
        assertFalse(isLiquidatable(alice));

        vm.prank(alice);
        vm.expectRevert(ClearingHouse.IMRBreach.selector);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
    }

    /// @notice A short grown at an unchanged index passes the initial margin check: its averaged entry
    ///         is rounded up, so its loss at the index never exceeds what its slices reserved.
    function test_Finding40_shortGrowsAtUnchangedIndex() public {
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, false, 30e18, 0);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, false, 10e18, 0);
        assertEq(getPosition(alice).size, -40e18);
        (int256 equity, uint256 required) = _imrState(alice);
        assertGe(equity, int256(required), "grown short below its initial margin");
    }
}
