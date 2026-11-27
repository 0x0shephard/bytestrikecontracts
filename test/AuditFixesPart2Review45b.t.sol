// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {Oracle, PriceOutOfBounds} from "../src/Oracle/Oracle.sol";
import {CuOracle} from "../src/Oracle/CuOracle.sol";
import {CuOracleAdapter} from "../src/Oracle/CuOracleAdapter.sol";

/// @notice Regression for finding 45 (mitigation review): the vAMM's own funding flushes (pause, oracle
/// change, parameter change, reserve reset) skip time in which the quote token cannot be valued, as
/// ClearingHouse settlement does; an index outage accrues the live time before the index went stale
/// when the index oracle reports that moment; and a quote round at the aggregator bounds is an unknown
/// outage start.
contract AuditFixesPart2Review45bTest is BaseTest {
    uint128 internal constant LONG_SIZE = 10 * 1e18;
    uint128 internal constant SHORT_SIZE = 1 * 1e18;
    uint256 internal constant INDEX_PRICE = 1960 * 1e18;

    address internal carol;
    address internal poker;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("carol");
        poker = makeAddr("poker");

        // Alice holds the larger long side, carol the short side
        fundAndDeposit(alice, 100_000 * USDC_UNIT);
        fundAndDeposit(carol, 100_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, LONG_SIZE, 0);
        vm.prank(carol);
        clearingHouse.openPosition(ETH_PERP, false, SHORT_SIZE, 0);

        // The index sits below the mark, so longs pay shorts
        setOraclePrice(INDEX_PRICE);
    }

    function test_PauseFlushSkipsQuoteOutage() public {
        // A live settlement caches the index and brings both accounts up to date
        uint256 t0 = vm.getBlockTimestamp() + 1 hours;
        vm.warp(t0);
        settleFunding(alice);
        settleFunding(carol);
        uint256 aliceMargin = getMargin(alice);

        // The USDC feed becomes unreadable right after while the index stays live, and a keeper settlement skips
        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("getPrice(string)", "USDC"), "stale");
        uint256 tSkip = t0 + 5 minutes;
        vm.warp(tSkip);
        vm.prank(poker);
        clearingHouse.settleFunding(ETH_PERP, poker);
        assertEq(uint256(vamm.lastFundingTimestamp()), tSkip, "clock not advanced");
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();

        // 25 outage minutes later the pause guardian pauses the market: the flush skips the outage minutes
        uint256 tPause = tSkip + 25 minutes;
        vm.warp(tPause);
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, true);
        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "pause flush accrued outage time");

        // The market is unpaused and the feed returns later, at the same second
        uint256 tResume = t0 + 3 hours;
        vm.warp(tResume);
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, false);
        vm.clearMockedCalls();

        // Alice's first settlement charges her nothing for the outage
        settleFunding(alice);
        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "settlement accrued outage time");
        assertEq(getMargin(alice), aliceMargin, "outage charged");
    }

    function test_SetParamsFlushSkipsQuoteOutage() public {
        uint256 t0 = vm.getBlockTimestamp() + 1 hours;
        vm.warp(t0);
        settleFunding(alice);
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();

        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("getPrice(string)", "USDC"), "stale");
        vm.warp(t0 + 20 minutes);
        vm.prank(vamm.owner());
        vamm.setParams(0, FUNDING_MAX_BPS_PER_HOUR, FUNDING_K);
        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "setParams flush accrued outage time");
        assertEq(uint256(vamm.lastFundingTimestamp()), t0 + 20 minutes, "clock not advanced");
    }

    function test_FlushAccruesNormallyWhileQuoteLive() public {
        uint256 t0 = vm.getBlockTimestamp() + 1 hours;
        vm.warp(t0);
        settleFunding(alice);
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();
        vm.warp(t0 + 20 minutes);
        uint256 expected = vamm.currentCumulativeLongPayPerUnitX18();
        assertGt(expected, payBefore, "no funding owed");
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, true);
        assertEq(vamm.cumulativeLongPayPerUnitX18(), expected, "live time before the pause not accrued");
    }

    function test_IndexOutageAccruesLiveTimeBeforeStaleness() public {
        uint256 t0 = vm.getBlockTimestamp() + 1 hours;
        vm.warp(t0);
        settleFunding(alice);
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();

        // the index stops being readable at t1 and its oracle reports that moment
        uint256 t1 = t0 + 5 minutes;
        vm.warp(t1);
        uint256 expected = vamm.currentCumulativeLongPayPerUnitX18();
        assertGt(expected, payBefore, "no funding owed before the outage");
        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("getPrice()"), "stale");
        vm.mockCall(
            address(oracle), abi.encodeWithSignature("priceUnavailableSince(string)", ""), abi.encode(t1)
        );

        // a settlement 15 minutes into the outage accrues the five live minutes and skips the rest
        vm.warp(t1 + 15 minutes);
        settleFunding(alice);
        assertEq(vamm.cumulativeLongPayPerUnitX18(), expected, "live time before the index outage not accrued");
        assertEq(uint256(vamm.lastFundingTimestamp()), t1 + 15 minutes, "clock not advanced");
    }

    function test_CuOracleAdapterReportsStaleBoundary() public {
        address cu = makeAddr("cuOracle");
        CuOracleAdapter adapter = new CuOracleAdapter(cu, keccak256("H100"), 1 hours);
        uint256 updated = vm.getBlockTimestamp();
        vm.mockCall(
            cu,
            abi.encodeWithSelector(CuOracle.getLatestPrice.selector, keccak256("H100")),
            abi.encode(CuOracle.PriceData({price: 4e18, lastUpdatedAt: updated}))
        );
        // fresh: readable, no outage
        assertEq(adapter.priceUnavailableSince(""), 0);
        // stale: unreadable since lastUpdatedAt + maxAge
        vm.warp(updated + 2 hours);
        vm.expectRevert(CuOracleAdapter.CuOracleAdapter_PriceStale.selector);
        adapter.getPrice();
        assertEq(adapter.priceUnavailableSince("H100"), updated + 1 hours);
    }
}

/// @dev Chainlink-style feed with a round history that is also its own aggregator, so the
///      Oracle reads minAnswer and maxAnswer from it as it does from a live Chainlink proxy
contract BoundedRoundFeed {
    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
    }

    mapping(uint80 => Round) internal _rounds;
    uint80 public latestRound;
    int192 public immutable minAnswer;
    int192 public immutable maxAnswer;

    constructor(int192 minAnswer_, int192 maxAnswer_) {
        minAnswer = minAnswer_;
        maxAnswer = maxAnswer_;
    }

    function push(int256 answer, uint256 startedAt, uint256 updatedAt) external {
        latestRound++;
        _rounds[latestRound] = Round(answer, startedAt, updatedAt);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function aggregator() external view returns (address) {
        return address(this);
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

/// @notice Finding 45: a quote round at the aggregator bounds counts as an unknown outage start.
contract AuditFixesPart2Review45bBoundsTest is BaseTest {
    // USDC/USD feed bounds (8 decimals): the aggregator clamps its answer to minAnswer when the price falls to it
    int192 internal constant MIN_ANSWER = 1e6;
    int192 internal constant MAX_ANSWER = 1e10;
    uint256 internal constant STALE_PERIOD = 600;

    address internal carol;
    Oracle internal chainlink;
    BoundedRoundFeed internal usdcFeed;
    BoundedRoundFeed internal sequencerFeed;

    // Time is tracked explicitly: with via_ir, block.timestamp reads can be cached across warps
    uint256 internal _now;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("carol");
        _now = vm.getBlockTimestamp();

        // Alice holds a 10 ETH long that pays funding (mark above index); carol holds a 1 ETH short
        fundAndDeposit(alice, 100_000e18);
        fundAndDeposit(carol, 100_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        vm.prank(carol);
        clearingHouse.openPosition(ETH_PERP, false, 1e18, 0);
        setOraclePrice(1960e18);

        // Two hours of keeper settlements
        for (uint256 i; i < 2; i++) {
            _now += 1 hours;
            vm.warp(_now);
            settleFunding(carol);
        }

        // The vault values USDC through the Chainlink Oracle, 600 s stale period, sequencer up since genesis
        vm.startPrank(admin);
        chainlink = new Oracle();
        usdcFeed = new BoundedRoundFeed(MIN_ANSWER, MAX_ANSWER);
        sequencerFeed = new BoundedRoundFeed(0, type(int192).max);
        usdcFeed.push(1e8, _now, _now);
        sequencerFeed.push(0, 1, 1);
        chainlink.setPriceFeed("USDC", address(usdcFeed));
        chainlink.setPriceStalePeriodForToken("USDC", STALE_PERIOD);
        chainlink.setSequencerUptimeFeed(address(sequencerFeed));
        vault.setOracle(address(chainlink));
        // The market also charges a holding fee of 10% a year
        clearingHouse.setHoldingFeeRate(ETH_PERP, 1_000);
        vm.stopPrank();
    }

    /// @dev Long pay index the vAMM would hold if funding were accrued up to `t`
    function _longPayIndexAt(uint256 t) internal returns (uint256 idx) {
        vm.warp(t);
        idx = vamm.currentCumulativeLongPayPerUnitX18();
        vm.warp(_now);
    }

    function test_OutOfBoundsQuoteRoundSkipsWholeInterval() public {
        // t0: last healthy settlement, funding and holding fee clocks both at t0
        uint256 t0 = _now;
        assertEq(vamm.lastFundingTimestamp(), t0, "funding clock not at t0");
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();
        (, uint256 feeCumBefore,) = clearingHouse.holdingFees(ETH_PERP);

        // t1 = t0 + 5 min: the USDC round lands on the aggregator's minAnswer and the feed then stops updating
        uint256 t1 = t0 + 5 minutes;
        _now = t1;
        vm.warp(_now);
        usdcFeed.push(int256(MIN_ANSWER), t1, t1);
        vm.expectRevert(PriceOutOfBounds.selector);
        chainlink.getPrice("USDC");

        // the out-of-bounds round is not a known outage start, fresh or stale
        assertEq(chainlink.priceUnavailableSince("USDC"), 0, "fresh out-of-bounds round reported");
        _now = t0 + 28 minutes;
        vm.warp(_now);
        assertEq(chainlink.priceUnavailableSince("USDC"), 0, "stale out-of-bounds round reported");

        // the keeper's settlement skips the whole interval: nothing after getPrice stopped working is charged
        settleFunding(carol);
        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "outage time charged");
        assertEq(vamm.lastFundingTimestamp(), _now, "clock not advanced");
        (, uint256 feeCum,) = clearingHouse.holdingFees(ETH_PERP);
        assertEq(feeCum, feeCumBefore, "outage holding fee charged");
    }
}
