// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

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
}
