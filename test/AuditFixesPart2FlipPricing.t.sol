// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

/// @notice Finding 58: a flip realizes the closed position at its own fill and enters the new one at
/// its own fill, as closePosition followed by openPosition does.
contract AuditFixesPart2FlipPricingTest is BaseTest {
    uint128 internal constant OLD = 10e18;

    function setUp() public override {
        super.setUp();
        fundAndDeposit(alice, 50_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, OLD, 0);
    }

    function _check(uint128 flipSize) internal {
        uint256 snap = vm.snapshotState();

        // Close, then open the rest on the other side.
        vm.startPrank(alice);
        clearingHouse.closePosition(ETH_PERP, OLD, 0);
        int256 realizedSplit = getPosition(alice).realizedPnL;
        clearingHouse.openPosition(ETH_PERP, false, flipSize - OLD, 0);
        vm.stopPrank();
        IClearingHouse.PositionView memory split = getPosition(alice);
        uint256 balSplit = getCollateralBalance(alice);

        vm.revertToState(snap);

        // One flip.
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, false, flipSize, 0);
        IClearingHouse.PositionView memory flip = getPosition(alice);

        assertEq(flip.size, split.size, "size");
        assertApproxEqAbs(flip.realizedPnL, realizedSplit, 1e6, "closed leg not realized at its own fill");
        assertApproxEqAbs(flip.entryPriceX18, split.entryPriceX18, 1e6, "new leg not entered at its own fill");
        assertApproxEqAbs(getCollateralBalance(alice), balSplit, 1e6, "balance differs from close then open");
    }

    function test_Finding58_flipMatchesCloseThenOpen() public {
        _check(2 * OLD);
    }

    function test_Finding58_largerFlipMatchesCloseThenOpen() public {
        _check(3 * OLD);
    }

    /// @notice The caller's limit applies to the summed quote of both swaps.
    function test_Finding58_flipLimitOnSummedQuote() public {
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, false, 2 * OLD, 0);
        (, uint256 yAfter) = getReserves();
        vm.revertToState(snap);
        (, uint256 yBefore) = getReserves();
        uint256 quoteOut = yBefore - yAfter;

        vm.prank(alice);
        vm.expectRevert(bytes("slippage"));
        clearingHouse.openPosition(ETH_PERP, false, 2 * OLD, quoteOut + 1);

        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, false, 2 * OLD, quoteOut);
        assertEq(getPosition(alice).size, -int256(uint256(OLD)), "flip at the limit");
    }
}
