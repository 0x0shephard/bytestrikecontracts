// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";

/// @notice Findings 1 + 4 (Cyfrin bytestrike part 2): a liquidation's own price impact is bounded.
/// @dev With the band checked only on the pre-trade mark, a full liquidation could fill at any depth
///      and the insurance fund paid the loss beyond the balance to the counterparty. A liquidation
///      now fills at most the size that keeps its average price within mmrBps - penaltyBps of the
///      index; the rest is left for later calls.
contract AuditFixesPart2LiquidationImpactTest is BaseTest {
    // Planned H100 parameters: IMR 10%, MMR 5%, penalty 2%.
    uint256 internal constant H_IMR = 1_000;
    uint256 internal constant H_MMR = 500;
    uint256 internal constant H_PENALTY = 200;

    address internal longAcct;
    address internal shortAcct;

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        clearingHouse.setRiskParams(ETH_PERP, H_IMR, H_MMR, H_PENALTY, PENALTY_CAP, 0, 0);
        longAcct = makeAddr("attackerLong");
        shortAcct = makeAddr("attackerShort");
    }

    function _fundTracked() internal view returns (uint256) {
        return insuranceFund.totalReceived() - insuranceFund.totalPaid();
    }

    function _absSize(address user) internal view returns (uint256) {
        int256 s = getPosition(user).size;
        return uint256(s > 0 ? s : -s);
    }

    /// @dev Effective margin of `user` at the current index (no funding accrues in these tests).
    function _equity(address user) internal view returns (int256) {
        IClearingHouse.PositionView memory pos = getPosition(user);
        int256 index = int256(oracle.getPrice());
        int256 upnl = (index - int256(pos.entryPriceX18)) * pos.size / 1e18;
        return int256(pos.margin) + upnl;
    }

    /// @dev The long account opens `size` with its entry far above the index and only the margin
    ///      needed to sit at the maintenance edge; its vault balance is then exactly that margin.
    function _openLongAtMaintenanceEdge(uint128 size) internal returns (uint256 netDeposit) {
        fundAndDeposit(longAcct, 100_000 * USDC_UNIT);
        vm.startPrank(longAcct);
        clearingHouse.openPosition(ETH_PERP, true, 1 ether, 0);
        clearingHouse.addMargin(ETH_PERP, 8_000 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, true, size - 1 ether, 0);
        uint256 free = getCollateralBalance(longAcct) - clearingHouse._totalReservedMargin(longAcct);
        clearingHouse.withdraw(address(usdc), free);
        vm.stopPrank();
        netDeposit = 100_000 * USDC_UNIT - free;
        assertEq(getCollateralBalance(longAcct), getMargin(longAcct), "balance is the margin");
    }

    /// @dev Sets the index just under the long's maintenance edge:
    ///      margin + (idx - entry) * size = mmr * idx * size.
    function _indexJustBelowEdge(address user) internal {
        IClearingHouse.PositionView memory pos = getPosition(user);
        uint256 s = uint256(pos.size);
        uint256 edge = ((pos.entryPriceX18 * s / 1e18 - pos.margin) * 1e18 / s) * 10_000 / (10_000 - H_MMR);
        setOraclePrice(edge - edge / 10_000);
        assertTrue(isLiquidatable(user));
    }

    /// @dev The attack from the auditor's comment, on the planned H100 parameters. Before the fix
    ///      the full liquidation filled ~9% under the index, the fund paid the loss beyond the long's
    ///      balance and the short account collected it: the pair netted a profit and the fund lost
    ///      the same amount. Now each call fills only what stays within the bound, the short account
    ///      buys back between calls (restoring the mark), and the pair cannot net anything.
    function test_LiquidationImpactBoundStopsFundDrain() public {
        uint128 size = 100 ether;
        uint256 longIn = _openLongAtMaintenanceEdge(size);
        assertGt(getPosition(longAcct).entryPriceX18, INITIAL_ETH_PRICE * 110 / 100, "entry far above index");

        // second account shorts at the elevated mark, bringing it back to the index
        uint256 shortIn = 100_000 * USDC_UNIT;
        fundAndDeposit(shortAcct, shortIn);
        vm.prank(shortAcct);
        clearingHouse.openPosition(ETH_PERP, false, size, 0);

        _indexJustBelowEdge(longAcct);
        uint256 index = oracle.getPrice();
        // What the long's equity is short of the maintenance margin: the only loss beyond its
        // balance that bounded fills can produce.
        uint256 mm = (_absSize(longAcct) * index / 1e18) * H_MMR / 10_000;
        int256 eq = _equity(longAcct);
        uint256 legitShortfall = eq < int256(mm) ? mm - uint256(eq) + 1e15 : 0;
        uint256 fundBefore = _fundTracked();
        uint256 bound = index * (10_000 - (H_MMR - H_PENALTY)) / 10_000;
        uint256 worstFill = type(uint256).max;

        for (uint256 i = 0; i < 20 && getPosition(longAcct).size != 0; i++) {
            (uint256 x0, uint256 y0) = getReserves();
            uint128 request = uint128(_absSize(longAcct));
            vm.prank(liquidator);
            clearingHouse.liquidate(longAcct, ETH_PERP, request, 0);
            (uint256 x1, uint256 y1) = getReserves();
            uint256 filled = x1 - x0;
            uint256 fill = (y0 - y1) * 1e18 / filled;
            if (fill < worstFill) worstFill = fill;
            // the short account buys back the filled size, which restores the mark for the next call
            vm.prank(shortAcct);
            clearingHouse.closePosition(ETH_PERP, uint128(filled), 0);
        }
        assertEq(getPosition(longAcct).size, 0, "long fully liquidated");
        uint256 rest = _absSize(shortAcct);
        if (rest > 0) {
            vm.prank(shortAcct);
            clearingHouse.closePosition(ETH_PERP, uint128(rest), 0);
        }

        uint256 fundAfter = _fundTracked();
        int256 net = int256(getCollateralBalance(shortAcct)) - int256(shortIn)
            + int256(getCollateralBalance(longAcct)) - int256(longIn);
        emit log_named_int("pair net extraction", net);
        emit log_named_int("fund change", int256(fundAfter) - int256(fundBefore));
        emit log_named_uint("worst fill", worstFill);
        emit log_named_uint("fill bound", bound);

        assertGe(fundAfter + legitShortfall, fundBefore, "fund drained beyond the legitimate shortfall");
        assertLe(net, 0, "attacker pair extracted value");
        assertGe(worstFill, bound, "fill worse than index * (1 - (mmr - penalty))");
    }

    /// @dev Closing a short: the average fill stays at or under index * (1 + (mmr - penalty)).
    function test_ShortLiquidationFillBounded() public {
        uint128 size = 100 ether;
        fundAndDeposit(alice, 40_000 * USDC_UNIT);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, false, 1 ether, 0);
        clearingHouse.addMargin(ETH_PERP, 9_000 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, false, size - 1 ether, 0);
        vm.stopPrank();
        // a buyer returns the mark to the index; the index then rises past alice's maintenance edge
        fundAndDeposit(bob, 100_000 * USDC_UNIT);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, true, size, 0);
        uint256 index = 2_020 ether;
        setOraclePrice(index);
        assertTrue(isLiquidatable(alice));

        (uint256 x0, uint256 y0) = getReserves();
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, size, 0);
        (uint256 x1, uint256 y1) = getReserves();
        uint256 filled = x0 - x1;
        assertGt(filled, 0);
        assertLt(filled, size, "size capped by the bound");
        assertEq(_absSize(alice), size - filled);
        assertLe((y1 - y0) * 1e18 / filled, index * (10_000 + (H_MMR - H_PENALTY)) / 10_000);
    }

    /// @dev The penalty is charged on the filled (capped) size, and a request of exactly the bound
    ///      size is exempt from the remainder check like a capped request.
    function test_CappedLiquidationChargesPenaltyOnFilledSize() public {
        uint128 size = 100 ether;
        _openLongAtMaintenanceEdge(size);
        fundAndDeposit(shortAcct, 100_000 * USDC_UNIT);
        vm.prank(shortAcct);
        clearingHouse.openPosition(ETH_PERP, false, size, 0);
        _indexJustBelowEdge(longAcct);
        uint256 index = oracle.getPrice();

        uint256 liqBefore = getCollateralBalance(liquidator);
        vm.prank(liquidator);
        clearingHouse.liquidate(longAcct, ETH_PERP, size, 0);
        uint256 filled = size - _absSize(longAcct);
        assertGt(filled, 0);
        assertLt(filled, size);
        uint256 penalty = (((filled * index) / 1e18) * H_PENALTY + 9_999) / 10_000;
        assertApproxEqAbs(getCollateralBalance(liquidator) - liqBefore, penalty - penalty / 2, 2);

        // After the mark is restored, a keeper that sizes the call to exactly the bound (as an
        // off-chain bot would) is treated as capped: the remainder check does not revert it.
        vm.prank(shortAcct);
        clearingHouse.closePosition(ETH_PERP, uint128(filled), 0);
        uint256 sizeBefore = _absSize(longAcct);
        uint256 maxBase = _boundSizeClosingLong(index);
        assertLt(maxBase, sizeBefore);
        vm.prank(liquidator);
        clearingHouse.liquidate(longAcct, ETH_PERP, uint128(maxBase), 0);
        assertEq(_absSize(longAcct), sizeBefore - maxBase);
    }

    /// @dev Off-chain sizing for closing a long: largest dx with y / (x + dx) >= index * (1 - d).
    function _boundSizeClosingLong(uint256 index) internal view returns (uint256) {
        (uint256 x, uint256 y) = getReserves();
        uint256 floorPx = (index * (10_000 - (H_MMR - H_PENALTY)) + 9_999) / 10_000;
        return y * 1e18 / floorPx - x;
    }
}
