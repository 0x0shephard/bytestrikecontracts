// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";

/// @notice Regression tests for paused markets (Cyfrin bytestrike part 2, findings 17 and 28
/// and draft 42).
contract AuditFixesPart2PauseTest is BaseTest {
    function _openThinLongAndPause() internal {
        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, true);
    }

    /// @notice Finding 17: while a market is paused the index keeps moving, so a trader must be able
    /// to add margin and still be healthy when the market is unpaused.
    function test_Finding17_addMarginWhilePausedDefendsPosition() public {
        _openThinLongAndPause();

        setOraclePrice(1_920 * PRICE_PRECISION);
        assertTrue(isLiquidatable(alice), "index move made alice liquidatable");

        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 2_000 * USDC_UNIT);
        assertFalse(isLiquidatable(alice), "top-up restored the position");

        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, false);
        vm.prank(liquidator);
        vm.expectRevert(ClearingHouse.NotLiquidatable.selector);
        clearingHouse.liquidate(alice, ETH_PERP, 10 ether, 0);
    }

    /// @notice Finding 17: only adding margin opens up; removing margin and closing stay blocked.
    function test_Finding17_removeMarginAndCloseStayBlockedWhilePaused() public {
        _openThinLongAndPause();
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 100 * USDC_UNIT);

        vm.startPrank(alice);
        vm.expectRevert(ClearingHouse.MarketNotActive.selector);
        clearingHouse.removeMargin(ETH_PERP, 100 * USDC_UNIT);
        vm.expectRevert();
        clearingHouse.closePosition(ETH_PERP, 10 ether, 0);
        vm.stopPrank();
    }

    /// @notice Draft 42: margin added to a market without a position was never counted against the
    /// balance, so the same balance could be booked repeatedly. addMargin now needs a position.
    function test_Draft42_addMarginWithoutPositionReverts() public {
        fundAndDeposit(alice, 1_000 * USDC_UNIT);
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.NoPosition.selector);
        clearingHouse.addMargin(ETH_PERP, 1_000 * USDC_UNIT);

        assertEq(clearingHouse._totalReservedMargin(alice), 0, "nothing booked");
        assertEq(getMargin(alice), 0, "no margin on the empty position");
    }

    /// @notice Finding 28: unpausing refreshes the cached index, so the first accrual after the pause
    /// prices funding against the current index rather than the one from before the pause.
    function test_Finding28_unpauseRefreshesCachedIndex() public {
        address carol = makeAddr("carol");
        fundAndDeposit(alice, 100_000 * USDC_UNIT);
        fundAndDeposit(carol, 100_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        vm.prank(carol);
        clearingHouse.openPosition(ETH_PERP, false, 1 ether, 0);
        uint256 t = block.timestamp;
        settleFunding(carol); // cache the pre-pause index (mark is above it: longs would pay)

        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, true);
        // During the pause the index moves above the mark: from now on shorts pay.
        uint256 newIndex = (getMarkPrice() * 105) / 100;
        setOraclePrice(newIndex);
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, false);
        assertEq(vamm.cachedIndexPrice(), newIndex, "cache not refreshed on unpause");

        uint256 longPayBefore = vamm.cumulativeLongPayPerUnitX18();
        uint256 shortPayBefore = vamm.cumulativeShortPayPerUnitX18();
        vm.warp(t + 1 hours);
        settleFunding(carol);
        assertEq(vamm.cumulativeLongPayPerUnitX18(), longPayBefore, "longs charged against the stale index");
        assertGt(vamm.cumulativeShortPayPerUnitX18(), shortPayBefore, "shorts not charged");
    }
}
