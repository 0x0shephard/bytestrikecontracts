// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IOracle} from "../src/Interfaces/IOracle.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {Oracle} from "../src/Oracle/Oracle.sol";

/// @dev Chainlink-style feed with a round history (price feed or sequencer uptime feed).
contract RoundHistoryFeed {
    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
    }

    mapping(uint80 => Round) internal _rounds;
    uint80 public latestRound;

    function push(int256 answer, uint256 startedAt, uint256 updatedAt) external {
        latestRound++;
        _rounds[latestRound] = Round(answer, startedAt, updatedAt);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = _rounds[latestRound];
        return (latestRound, r.answer, r.startedAt, r.updatedAt, latestRound);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(id != 0 && id <= latestRound, "no round");
        Round memory r = _rounds[id];
        return (id, r.answer, r.startedAt, r.updatedAt, id);
    }
}

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
            vm.prank(address(clearingHouse));
            vamm.pokeFunding();
            assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "funding accrued during outage");
            assertEq(vamm.lastFundingTimestamp(), _now, "clock not advanced");
        }
        settleFunding(alice);
        assertEq(getPosition(alice).margin, aliceMargin, "payer charged during outage");

        // Recovery: the next poke accrues only the time since the last outage poke.
        vm.clearMockedCalls();
        vm.prank(address(clearingHouse));
        vamm.pokeFunding(); // same timestamp: refreshes the cache, accrues nothing
        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "accrued at recovery");
        _warpHours(1);
        vm.prank(address(clearingHouse));
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
        vm.prank(address(clearingHouse));
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
        marketRegistry.setOracle(ETH_PERP, address(newOracle));

        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "outage time charged on setOracle");
        assertEq(vamm.lastFundingTimestamp(), _now, "clock not advanced");
        assertEq(vamm.cachedIndexPrice(), 1960e18, "cache not refreshed from new oracle");
    }

    /// @notice Finding 45: only the ClearingHouse can poke or skip funding on the vAMM.
    function test_Finding45_pokeFundingIsClearingHouseOnly() public {
        vm.expectRevert(bytes("Not CH"));
        vamm.pokeFunding();

        vm.expectRevert(bytes("Not CH"));
        vamm.skipFunding(0);
    }

    /// @notice Finding 45: while the quote-token oracle reverts, settleFunding advances the
    /// funding clock without accruing, so payers are not charged for hours they cannot act.
    function test_Finding45_quoteOracleOutageDoesNotAccrueFunding() public {
        _openPayingLong();
        _accrueHours(1);
        settleFunding(alice);
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();
        uint256 aliceMargin = getPosition(alice).margin;
        uint256 aliceBal = getCollateralBalance(alice);

        // Quote (USDC) feed goes down; the index oracle stays live.
        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("getPrice(string)", "USDC"), "stale");
        address poker = makeAddr("poker");
        for (uint256 i; i < 6; i++) {
            _warpHours(1);
            // Permissionless settle for an account with no position must not accrue funding.
            vm.prank(poker);
            clearingHouse.settleFunding(ETH_PERP, poker);
            assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "funding accrued during quote outage");
            assertEq(vamm.lastFundingTimestamp(), _now, "clock not advanced");
        }

        // Quote feed recovers: the payer is not charged for the outage hours.
        vm.clearMockedCalls();
        settleFunding(alice);
        assertEq(getPosition(alice).margin, aliceMargin, "payer charged for outage");
        assertEq(getCollateralBalance(alice), aliceBal, "vault debited for outage");
        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "accrued at recovery");

        // Funding resumes normally afterwards.
        _accrueHours(1);
        assertGt(vamm.cumulativeLongPayPerUnitX18(), payBefore, "funding resumes after recovery");
    }

    /// @notice Finding 45: a quote oracle returning zero is treated as unavailable.
    function test_Finding45_zeroQuotePriceDoesNotAccrueFunding() public {
        _openPayingLong();
        _accrueHours(1);
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();

        vm.mockCall(address(oracle), abi.encodeWithSignature("getPrice(string)", "USDC"), abi.encode(uint256(0)));
        _warpHours(1);
        settleFunding(carol);
        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "funding accrued on zero quote price");
        assertEq(vamm.lastFundingTimestamp(), _now, "clock not advanced");
    }

    RoundHistoryFeed internal usdcFeed;
    RoundHistoryFeed internal sequencerFeed;

    /// @dev Values the vault's USDC through a Chainlink Oracle (600s stale period) fed by mock feeds,
    ///      with the USDC round fresh now and the sequencer up since genesis.
    function _useChainlinkQuoteOracle() internal {
        if (_now == 0) _now = block.timestamp;
        vm.startPrank(admin);
        Oracle chainlink = new Oracle();
        usdcFeed = new RoundHistoryFeed();
        sequencerFeed = new RoundHistoryFeed();
        usdcFeed.push(1e8, _now, _now);
        sequencerFeed.push(0, 1, 1); // up since genesis (callers run past the grace period first)
        chainlink.setPriceFeed("USDC", address(usdcFeed));
        chainlink.setPriceStalePeriodForToken("USDC", 600);
        chainlink.setSequencerUptimeFeed(address(sequencerFeed));
        vault.setOracle(address(chainlink));
        vm.stopPrank();
    }

    /// @dev Long pay index the vAMM would hold if funding were accrued at `t` (view at that time).
    function _longPayIndexAt(uint256 t) internal returns (uint256 idx) {
        vm.warp(t);
        idx = vamm.currentCumulativeLongPayPerUnitX18();
    }

    /// @notice Finding 45 (follow-up): a settle while the quote feed is stale accrues the live time
    /// up to the moment the feed went stale and skips only the time after it.
    function test_Finding45_staleQuoteFeedKeepsLiveTimeBeforeIt() public {
        _openPayingLong();
        _accrueHours(2);
        _useChainlinkQuoteOracle();
        settleFunding(carol);
        uint256 t0 = _now;
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();

        // The USDC round updated at t0 goes stale at t0 + 600; nobody settles until t0 + 28 minutes.
        uint256 expected = _longPayIndexAt(t0 + 600);
        assertGt(expected, payBefore, "no funding owed");
        _now = t0 + 28 minutes;
        vm.warp(_now);
        settleFunding(carol);

        assertEq(vamm.cumulativeLongPayPerUnitX18(), expected, "live time before the stale round dropped");
        assertEq(vamm.lastFundingTimestamp(), _now, "clock not advanced past the outage");

        // A later settle in the same outage accrues nothing more.
        _now += 10 minutes;
        vm.warp(_now);
        settleFunding(carol);
        assertEq(vamm.cumulativeLongPayPerUnitX18(), expected, "outage time accrued");
    }

    /// @notice Finding 45 (follow-up): the first settle inside the sequencer's grace period accrues the
    /// live time up to the moment the sequencer went down, and skips the outage and the grace period.
    function test_Finding45_sequencerRestartKeepsLiveTimeBeforeOutage() public {
        _openPayingLong();
        _accrueHours(2);
        _useChainlinkQuoteOracle();
        settleFunding(carol);
        uint256 t0 = _now;
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();

        // Live for 15 minutes, sequencer down for 25 minutes, back up 10 minutes before the settle.
        uint256 expected = _longPayIndexAt(t0 + 15 minutes);
        assertGt(expected, payBefore, "no funding owed");
        sequencerFeed.push(1, t0 + 15 minutes, t0 + 15 minutes);
        sequencerFeed.push(0, t0 + 40 minutes, t0 + 40 minutes);
        _now = t0 + 50 minutes;
        vm.warp(_now);
        usdcFeed.push(1e8, _now, _now);
        settleFunding(carol);

        assertEq(vamm.cumulativeLongPayPerUnitX18(), expected, "live time before the outage dropped");
        assertEq(vamm.lastFundingTimestamp(), _now, "clock not advanced past the outage");
    }

    /// @notice Finding 45 (follow-up): when the start of the outage cannot be read, the whole interval
    /// is still skipped (no charge for time that may have been an outage).
    function test_Finding45_unknownOutageStartSkipsWholeInterval() public {
        _openPayingLong();
        _accrueHours(2);
        _useChainlinkQuoteOracle();
        settleFunding(carol);
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();

        _now += 20 minutes;
        vm.warp(_now);
        usdcFeed.push(0, _now, _now); // zero price: unreadable, start unknown
        settleFunding(carol);
        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "accrued with unknown outage start");
        assertEq(vamm.lastFundingTimestamp(), _now, "clock not advanced");
    }

    /// @notice Finding 45 with the finding 26 holding fee: a settle while the quote feed is stale
    /// accrues the holding fee index up to the moment the feed went stale, like funding, and the
    /// outage time after it is not charged.
    function test_Finding45_staleQuoteFeedKeepsHoldingFeeTimeBeforeIt() public {
        _openPayingLong();
        _accrueHours(2);
        _useChainlinkQuoteOracle();
        vm.prank(admin);
        clearingHouse.setHoldingFeeRate(ETH_PERP, 1_000);
        uint256 t0 = _now;
        (, uint256 cumBefore, uint256 updatedAt) = clearingHouse.holdingFees(ETH_PERP);
        assertEq(updatedAt, t0, "clock not at t0");

        // The USDC round updated at t0 goes stale at t0 + 600; nobody settles until t0 + 28 minutes.
        _now = t0 + 28 minutes;
        vm.warp(_now);
        settleFunding(carol);
        uint256 expected = cumBefore + uint256(1_000) * 1e14 * 600 / 365 days;
        (, uint256 cum, uint256 clock) = clearingHouse.holdingFees(ETH_PERP);
        assertEq(cum, expected, "live time before the stale round dropped or outage charged");
        assertEq(clock, _now, "clock not advanced past the outage");

        // A later settle in the same outage accrues nothing more.
        _now += 10 minutes;
        vm.warp(_now);
        settleFunding(carol);
        (, cum,) = clearingHouse.holdingFees(ETH_PERP);
        assertEq(cum, expected, "outage time accrued");
    }
}
