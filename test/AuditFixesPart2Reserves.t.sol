// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";

/// @notice Regression tests for vAMM reserve resets (Cyfrin bytestrike part 2, findings 2 and 53).
contract AuditFixesPart2ReservesTest is BaseTest {
    uint128 internal constant SIZE = 20 ether;

    function _pastCooldown() internal {
        vm.warp(vm.getBlockTimestamp() + vamm.RESET_COOLDOWN());
    }

    /// @notice Finding 2: with a net long open, a deeper reset at the same price would let the long
    /// exit with profit no account paid, so it must revert.
    function test_Finding2_depthResetWithNetOpenInterestReverts() public {
        fundAndDeposit(alice, 50_000 * USDC_UNIT);
        openLongPosition(alice, SIZE, 0);
        _pastCooldown();

        uint256 mark = getMarkPrice();
        vm.prank(admin);
        vm.expectRevert("Net OI open");
        vamm.resetReserves(mark, 10 * INITIAL_BASE_RESERVE);
    }

    /// @notice Finding 2 (auditor comment): a price-only reset at the current depth moves the net
    /// side's exit value the same way, so it is blocked too.
    function test_Finding2_priceOnlyResetWithNetOpenInterestReverts() public {
        fundAndDeposit(alice, 50_000 * USDC_UNIT);
        openShortPosition(alice, SIZE, 0);
        _pastCooldown();

        (uint256 base,) = getReserves();
        uint256 mark = getMarkPrice();
        vm.prank(admin);
        vm.expectRevert("Net OI open");
        vamm.resetReserves(mark * 105 / 100, base);
    }

    /// @notice Finding 2: with balanced open interest a reset moves no value to a net side and
    /// remains available.
    function test_Finding2_resetAllowedWithBalancedOpenInterest() public {
        fundAndDeposit(alice, 50_000 * USDC_UNIT);
        fundAndDeposit(bob, 50_000 * USDC_UNIT);
        openLongPosition(alice, SIZE, 0);
        openShortPosition(bob, SIZE, 0);
        assertEq(vamm.totalLongOI(), vamm.totalShortOI(), "balanced book");
        _pastCooldown();

        uint256 mark = getMarkPrice();
        vm.prank(admin);
        vamm.resetReserves(mark, 2 * INITIAL_BASE_RESERVE);
        (uint256 base,) = getReserves();
        assertEq(base, 2 * INITIAL_BASE_RESERVE, "depth reset");
    }

    /// @notice Finding 56: with a base floor set, a buy of at least the whole base reserve is clamped
    /// to the room above the floor like any other oversized order, instead of reverting.
    function test_Finding56_buyOfWholeReserveIsClampedAtFloor() public {
        (uint256 base,) = getReserves();
        forceMinReserves(base - 10 ether, 0);

        vm.prank(address(clearingHouse));
        (int256 baseDelta,,) = vamm.buyBase(uint128(base), 0);
        assertEq(baseDelta, 10 ether, "filled the room above the floor");
        (uint256 baseAfter,) = getReserves();
        assertEq(baseAfter, base - 10 ether);
    }

    /// @notice Finding 56: without a floor, an order of the whole base reserve still reverts.
    function test_Finding56_buyOfWholeReserveRevertsWithoutFloor() public {
        (uint256 base,) = getReserves();
        vm.prank(address(clearingHouse));
        vm.expectRevert("insufficient X");
        vamm.buyBase(uint128(base), 0);
    }

    /// @dev Quote paid for buying `dx` base at the current reserves (state is restored).
    function _quoteToBuy(uint128 dx) internal returns (uint256 cost) {
        uint256 snap = vm.snapshotState();
        vm.prank(address(clearingHouse));
        (, int256 quoteDelta,) = vamm.buyBase(dx, 0);
        cost = uint256(-quoteDelta);
        vm.revertToState(snap);
    }

    /// @notice Finding 39: a buy the base floor clamps is held to the trader's limit price, not to
    /// the full-order total.
    function test_Finding39_clampedBuyKeepsLimitPrice() public {
        (uint256 base,) = getReserves();
        forceMinReserves(base - 4 ether, 0); // 4 ETH of room
        uint256 cost4 = _quoteToBuy(4 ether);

        // A 10 ETH order whose limit price is 1% below the clamped fill's price, but whose total
        // covers the 4 ETH fill 2.5 times over
        uint256 tightLimit = cost4 * 10 / 4 * 99 / 100;
        assertGt(tightLimit, cost4);
        vm.prank(address(clearingHouse));
        vm.expectRevert("slippage");
        vamm.buyBase(10 ether, tightLimit);

        // At a limit price that covers the clamped fill, it is filled
        vm.prank(address(clearingHouse));
        (int256 baseDelta, int256 quoteDelta,) = vamm.buyBase(10 ether, cost4 * 10 / 4 + 10);
        assertEq(baseDelta, 4 ether);
        assertEq(uint256(-quoteDelta), cost4);
    }

    /// @notice Finding 39: a sell the quote floor clamps needs only the limit price on the base it
    /// consumed, not the full-order minimum.
    function test_Finding39_clampedSellScalesMinQuoteOut() public {
        (, uint256 quote) = getReserves();
        uint256 snap = vm.snapshotState();
        vm.prank(address(clearingHouse));
        (, int256 fullOut,) = vamm.sellBase(10 ether, 0);
        vm.revertToState(snap);

        // Floor leaves room for about 4 ETH of the 10 ETH sell
        forceMinReserves(0, quote - uint256(fullOut) * 4 / 10);

        // Limit price 1% under the unclamped average: its full total is more than the clamped fill pays
        uint256 minOut = uint256(fullOut) * 99 / 100;
        vm.prank(address(clearingHouse));
        (int256 baseDelta, int256 quoteDelta,) = vamm.sellBase(10 ether, minOut);
        assertLt(uint256(-baseDelta), 10 ether, "fill was clamped");
        assertLt(uint256(quoteDelta), minOut);
        assertGe(uint256(quoteDelta) * 10 ether, minOut * uint256(-baseDelta), "limit price kept");
    }

    /// @notice Finding 39: a clamped sell below the trader's limit price still reverts.
    function test_Finding39_clampedSellBelowLimitPriceReverts() public {
        (, uint256 quote) = getReserves();
        uint256 snap = vm.snapshotState();
        vm.prank(address(clearingHouse));
        (, int256 fullOut,) = vamm.sellBase(10 ether, 0);
        vm.revertToState(snap);

        forceMinReserves(0, quote - uint256(fullOut) * 4 / 10);

        // The clamped fill sells ~4 ETH at a better average than the full order; ask for 10% more
        vm.prank(address(clearingHouse));
        vm.expectRevert("slippage");
        vamm.sellBase(10 ether, uint256(fullOut) * 115 / 100);
    }

    /// @dev Opens a balanced book (alice long, bob short) so resets are allowed.
    function _balancedBook() internal {
        fundAndDeposit(alice, 50_000 * USDC_UNIT);
        fundAndDeposit(bob, 50_000 * USDC_UNIT);
        openLongPosition(alice, SIZE, 0);
        openShortPosition(bob, SIZE, 0);
        _pastCooldown();
    }

    /// @notice Finding 53: a target more than 10% above the mark at execution is clamped to a 10%
    /// step instead of reverting, so a sell that lands first cannot revert an upward realignment.
    function test_Finding53_resetTargetBeyondLimitIsClamped() public {
        _balancedBook();
        (uint256 base,) = getReserves();
        uint256 markRead = getMarkPrice();
        uint256 target = markRead * 110 / 100; // planned on the limit from the mark read earlier

        // A trade lowers the mark before the reset lands.
        vm.prank(address(clearingHouse));
        vamm.sellBase(1 ether, 0);
        uint256 markAtExec = getMarkPrice();
        assertLt(markAtExec, markRead);

        vm.prank(admin);
        vamm.resetReserves(target, base);
        uint256 expected = markAtExec + markAtExec * vamm.MAX_PRICE_CHANGE_BPS() / vamm.BPS_DENOMINATOR();
        assertApproxEqRel(getMarkPrice(), expected, 1e9, "clamped to a 10% step");
    }

    /// @notice Finding 53: when a buy takes the mark past the target before the reset lands, the
    /// reset still moves it toward the target (down), and an index far away is stepped toward.
    function test_Finding53_resetStepsTowardTarget() public {
        _balancedBook();
        (uint256 base,) = getReserves();
        uint256 mark = getMarkPrice();

        // Target far below: one call moves the mark down by the 10% limit.
        vm.prank(admin);
        vamm.resetReserves(mark / 2, base);
        assertApproxEqRel(getMarkPrice(), mark * 90 / 100, 1e9, "one 10% step down");

        // Target within the limit is set exactly.
        _pastCooldown();
        uint256 markNow = getMarkPrice();
        uint256 near = markNow * 103 / 100;
        vm.prank(admin);
        vamm.resetReserves(near, base);
        assertApproxEqRel(getMarkPrice(), near, 1e9, "target within the limit");
    }
}
