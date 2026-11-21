// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IOracle} from "../src/Interfaces/IOracle.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

/// @notice Regression tests for funding settlement audit fixes (Cyfrin bytestrike part 2).
contract AuditFixesPart2FundingTest is BaseTest {
    address internal carol;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("carol");
    }

    /// @dev Opens a long for alice that pays funding every hour (mark above index).
    function _openPayingLong() internal {
        fundAndDeposit(alice, 100_000e18);
        fundAndDeposit(carol, 100_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        vm.prank(carol);
        clearingHouse.openPosition(ETH_PERP, false, 1e18, 0);
        setOraclePrice(1960e18);
    }

    /// @dev Tracks time explicitly: with via_ir, block.timestamp reads can be cached across warps.
    uint256 internal _now;

    function _accrueHours(uint256 hours_) internal {
        if (_now == 0) _now = block.timestamp;
        for (uint256 i; i < hours_; i++) {
            _now += 3600;
            vm.warp(_now);
            setOraclePrice(1960e18);
            settleFunding(carol);
        }
    }

    /// @notice Finding 23: a funding debit larger than the position margin must not be
    /// re-reserved after the vault has already paid it.
    function test_Finding23_fundingDebitBeyondMarginNotReReserved() public {
        _openPayingLong();
        uint256 marginBefore = getPosition(alice).margin;
        _accrueHours(60);

        uint256 balBefore = getCollateralBalance(alice);
        settleFunding(alice);
        uint256 debit = balBefore - getCollateralBalance(alice);
        assertGt(debit, marginBefore, "debit should exceed margin");

        // Margin is exhausted and the overflow already paid by the vault is not reserved again.
        assertEq(getPosition(alice).margin, 0, "margin should be zero");
        assertEq(clearingHouse._totalReservedMargin(alice), 0, "no re-reserved shortfall");
    }

    /// @notice Finding 23: when the view reports a position liquidatable, liquidate must not
    /// revert NotLiquidatable after settling funding.
    function test_Finding23_viewLiquidatableMatchesLiquidate() public {
        _openPayingLong();
        _accrueHours(120);
        assertTrue(isLiquidatable(alice), "view should report liquidatable");

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);
        assertEq(getPosition(alice).size, 0, "position should be liquidated");
    }

    function _warpHours(uint256 hours_) internal {
        if (_now == 0) _now = block.timestamp;
        _now += hours_ * 3600;
        vm.warp(_now);
    }

    /// @notice Finding 6: while the index oracle reverts, pokes advance the funding clock
    /// without accruing at the stale cached index.
    function test_Finding6_indexOutageDoesNotAccrueFunding() public {
        _openPayingLong();
        _accrueHours(1);
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();
        settleFunding(alice);
        uint256 aliceMargin = getPosition(alice).margin;

        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("getPrice()"), "stale");
        for (uint256 i; i < 6; i++) {
            _warpHours(1);
            vamm.pokeFunding();
            assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "funding accrued during outage");
            assertEq(vamm.lastFundingTimestamp(), _now, "clock not advanced");
        }
        settleFunding(alice);
        assertEq(getPosition(alice).margin, aliceMargin, "payer charged during outage");

        // Recovery: the next poke accrues only the time since the last outage poke.
        vm.clearMockedCalls();
        vamm.pokeFunding(); // same timestamp: refreshes the cache, accrues nothing
        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "accrued at recovery");
        _warpHours(1);
        vamm.pokeFunding();
        assertGt(vamm.cumulativeLongPayPerUnitX18(), payBefore, "funding resumes after recovery");
    }

    /// @notice Finding 6: an index returning zero is treated as an outage.
    function test_Finding6_zeroIndexDoesNotAccrueFunding() public {
        _openPayingLong();
        _accrueHours(1);
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();

        vm.mockCall(address(oracle), abi.encodeWithSignature("getPrice()"), abi.encode(uint256(0)));
        _warpHours(1);
        vamm.pokeFunding();
        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "funding accrued on zero index");
        assertEq(vamm.lastFundingTimestamp(), _now, "clock not advanced");
    }

    /// @notice Finding 6: setOracle flushes through the same path, so outage time on the old
    /// oracle is not charged when switching oracles.
    function test_Finding6_setOracleSkipsOutageOfOldOracle() public {
        _openPayingLong();
        _accrueHours(1);
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();

        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("getPrice()"), "stale");
        _warpHours(1);
        MockOracle newOracle = new MockOracle(1960e18, 18);
        vm.prank(admin);
        vamm.setOracle(address(newOracle));

        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "outage time charged on setOracle");
        assertEq(vamm.lastFundingTimestamp(), _now, "clock not advanced");
        assertEq(vamm.cachedIndexPrice(), 1960e18, "cache not refreshed from new oracle");
    }
}
