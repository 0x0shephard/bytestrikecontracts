// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";

/// @notice Regression tests for liquidation audit fixes (Cyfrin bytestrike part 2).
contract AuditFixesPart2LiquidationTest is BaseTest {
    /// @dev Quote the vAMM pays for selling `dx` base (mirrors vAMM.sellBase without the clamp).
    function _quoteOutForSell(uint256 dx) internal view returns (uint256) {
        (uint256 x, uint256 y) = getReserves();
        uint256 f = 10_000 - uint256(TRADE_FEE_BPS);
        return (y * dx * f) / (x * 10_000 + dx * f);
    }

    /// @dev Sets the vAMM quote floor so that selling base fills only about `dx`.
    function _clampSellsTo(uint256 dx) internal {
        (, uint256 y) = getReserves();
        uint256 minQuote = y - _quoteOutForSell(dx);
        vm.prank(admin);
        vamm.setMinReserves(0, minQuote);
    }

    // ---------------------------------------------------------------------
    // Draft finding 21: penalty on the filled size
    // ---------------------------------------------------------------------

    /// @dev A long liquidated while the mark trades well above its entry and the index, with the
    /// vAMM reserve floor clamping the fill to half the requested size: the penalty is charged
    /// on the filled half only.
    function test_LiquidationPenaltyOnFilledSize() public {
        fundAndDeposit(alice, 1_100 * USDC_UNIT);
        fundAndDeposit(bob, 200_000 * USDC_UNIT);

        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);

        // mark rallies well above alice's entry while the index drops below her maintenance
        setOraclePrice(2_300 ether);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, true, 60 ether, 0);
        uint256 index = 1_925 ether;
        setOraclePrice(index);
        assertTrue(isLiquidatable(alice));

        _clampSellsTo(5 ether);

        uint256 liqBefore = vault.balanceOf(liquidator, address(usdc));
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10 ether, 0);

        IClearingHouse.PositionView memory pos = getPosition(alice);
        uint256 filled = 10 ether - uint256(pos.size);
        assertGt(pos.size, 0, "fill was clamped");
        assertApproxEqAbs(filled, 5 ether, 1e6);

        uint256 penalty = (((filled * index) / 1e18) * LIQUIDATION_PENALTY_BPS + 9_999) / 10_000;
        uint256 liqIncentive = penalty - penalty / 2;
        assertApproxEqAbs(vault.balanceOf(liquidator, address(usdc)) - liqBefore, liqIncentive, 2);
    }

    // ---------------------------------------------------------------------
    // Findings 4 + 5: band on the pre-trade mark, partial liquidations
    // ---------------------------------------------------------------------

    /// @dev Effective margin of `user` at the index (no pending funding in these tests) and its size.
    function _effAndSize(address user) internal view returns (int256 eff, uint256 absSize) {
        IClearingHouse.PositionView memory pos = getPosition(user);
        absSize = uint256(pos.size > 0 ? pos.size : -pos.size);
        int256 index = int256(oracle.getPrice());
        int256 upnl = pos.size > 0
            ? (index - int256(pos.entryPriceX18)) * int256(absSize) / 1e18
            : (int256(pos.entryPriceX18) - index) * int256(absSize) / 1e18;
        eff = int256(pos.margin) + upnl;
    }

    /// @dev Moves the vAMM mark to about `target` with a trade from bob (who holds ample margin).
    function _bobMovesMarkTo(uint256 target) internal {
        fundAndDeposit(bob, 500_000 * USDC_UNIT);
        vm.prank(bob);
        clearingHouse.addMargin(ETH_PERP, 300_000 * USDC_UNIT);
        (uint256 x, uint256 y) = getReserves();
        // constant product: x' = sqrt(k / target)
        uint256 xTarget = _sqrt((x * y / target) * 1e18);
        vm.prank(bob);
        if (xTarget > x) clearingHouse.openPosition(ETH_PERP, false, uint128(xTarget - x), 0);
        else clearingHouse.openPosition(ETH_PERP, true, uint128(x - xTarget), 0);
    }

    function _sqrt(uint256 a) internal pure returns (uint256 r) {
        if (a == 0) return 0;
        r = a;
        uint256 k = a / 2 + 1;
        while (k < r) {
            r = k;
            k = (a / k + k) / 2;
        }
    }

    /// @dev Finding 4: a long of 8% of the base reserve, liquidatable with the mark at the index,
    /// used to revert because its own price impact pushed the average fill below the band.
    function test_LargeLiquidationFromUnpushedMarkSucceeds() public {
        uint128 size = 80 ether;
        fundAndDeposit(alice, 40_000 * USDC_UNIT);
        setOraclePrice(2_400 ether);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, size, 0);

        // index and mark both end at 2,000, below alice's entry
        _bobMovesMarkTo(INITIAL_ETH_PRICE);
        setOraclePrice(INITIAL_ETH_PRICE);
        assertApproxEqRel(getMarkPrice(), INITIAL_ETH_PRICE, 0.001e18);
        assertTrue(isLiquidatable(alice));

        // the close's own average fill is more than 5% under the index
        assertLt(_quoteOutForSell(size) * 1e18 / size, INITIAL_ETH_PRICE * 95 / 100);

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, size, 0);
        assertEq(getPosition(alice).size, 0);
    }

    /// @dev Finding 4: a mark pushed beyond the band still blocks a liquidation of any size.
    function test_PushedMarkBlocksEvenTinyLiquidation() public {
        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        setOraclePrice(1_900 ether);
        assertTrue(isLiquidatable(alice));

        _bobMovesMarkTo(1_790 ether); // ~5.8% under the index

        vm.prank(liquidator);
        vm.expectPartialRevert(ClearingHouse.LiquidationPriceOutOfBand.selector);
        clearingHouse.liquidate(alice, ETH_PERP, 0.01 ether, 0);
    }

    /// @dev Opens alice's 10 ETH long with extra margin, then moves index and mark to `index`.
    function _liquidatableLong(uint256 extraMargin, uint256 index) internal {
        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        if (extraMargin > 0) clearingHouse.addMargin(ETH_PERP, extraMargin);
        vm.stopPrank();
        setOraclePrice(index);
        _bobMovesMarkTo(index);
        assertTrue(isLiquidatable(alice));
    }

    /// @dev Finding 5: a partial liquidation whose slice loss is covered by the slice's margin
    /// used to revert MustLiquidateMore because the remainder stayed liquidatable. It now passes,
    /// pays the penalty from free collateral and leaves the remainder's ratio no worse.
    function test_PartialLiquidationAtLossWithinSliceMarginSucceeds() public {
        _liquidatableLong(530 ether, 1_900 ether);
        (int256 effBefore, uint256 sizeBefore) = _effAndSize(alice);
        uint256 marginBefore = getMargin(alice);

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 5 ether, 0);

        (int256 effAfter, uint256 sizeAfter) = _effAndSize(alice);
        assertEq(sizeAfter, 5 ether);
        // the remainder keeps its proportional margin: the penalty came from free collateral
        assertEq(getMargin(alice), marginBefore - (marginBefore * 5 ether) / sizeBefore);
        assertGe(effAfter * int256(sizeBefore), effBefore * int256(sizeAfter));
        assertTrue(isLiquidatable(alice));

        // the rest is liquidated in a second call
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 5 ether, 0);
        assertEq(getPosition(alice).size, 0);
    }

    /// @dev A partial liquidation whose slice loss exceeds the slice's margin would worsen the
    /// remainder's ratio, so a liquidator-chosen partial size still reverts.
    function test_PartialLiquidationThatWorsensRatioReverts() public {
        _liquidatableLong(0, 1_900 ether);

        vm.prank(liquidator);
        vm.expectRevert(ClearingHouse.MustLiquidateMore.selector);
        clearingHouse.liquidate(alice, ETH_PERP, 5 ether, 0);

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10 ether, 0);
        assertEq(getPosition(alice).size, 0);
    }

    /// @dev Finding 5: a fill the vAMM reserve floor clamps below the requested size is exempt from
    /// the remainder check, so the liquidation closes what reserves allow.
    function test_ClampedLiquidationAtLossSucceeds() public {
        _liquidatableLong(0, 1_900 ether);
        _clampSellsTo(5 ether);

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10 ether, 0);
        int256 remaining = getPosition(alice).size;
        assertGt(remaining, 0);
        assertLt(remaining, 10 ether);
    }
}
