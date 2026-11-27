// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {SeedLimits} from "../script/SeedLimits.sol";

/// @notice Regression tests for the launch scripts' seed slippage limits (Cyfrin bytestrike part 2,
/// finding 65).
contract AuditFixesPart2SeedLimitsTest is BaseTest {
    uint128 internal constant SEED = 1 ether;
    address internal seedLong = makeAddr("seedLong");
    address internal seedShort = makeAddr("seedShort");

    function setUp() public override {
        super.setUp();
        fundAndDeposit(seedLong, 10_000 * USDC_UNIT);
        fundAndDeposit(seedShort, 10_000 * USDC_UNIT);
        fundAndDeposit(bob, 100_000 * USDC_UNIT);
    }

    /// @notice Finding 65: the limits sit a few bps from the expected fill and both seeds fill.
    function test_Finding65_seedLimitsFillAtExpectedPrice() public {
        address v = SeedLimits.vammOf(address(marketRegistry), ETH_PERP);
        uint256 expectedIn = SeedLimits.expectedLongQuoteIn(v, SEED);
        uint256 maxIn = SeedLimits.longMaxQuoteIn(v, SEED);
        assertLe(maxIn, expectedIn * 10_010 / 10_000, "long limit more than 10 bps above the fill");

        (, uint256 quoteBefore) = getReserves();
        vm.prank(seedLong);
        clearingHouse.openPosition(ETH_PERP, true, SEED, maxIn);
        (, uint256 quoteAfter) = getReserves();
        assertEq(quoteAfter - quoteBefore, expectedIn, "long filled at the expected quote");

        uint256 expectedOut = SeedLimits.expectedShortQuoteOut(v, SEED);
        uint256 minOut = SeedLimits.shortMinQuoteOut(v, SEED);
        assertGe(minOut, expectedOut * 9_990 / 10_000, "short limit more than 10 bps below the fill");
        vm.prank(seedShort);
        clearingHouse.openPosition(ETH_PERP, false, SEED, minOut);
        (, uint256 quoteEnd) = getReserves();
        assertEq(quoteAfter - quoteEnd, expectedOut, "short filled at the expected quote");
    }

    /// @notice Finding 65: a buy sequenced ahead of the seed long makes it revert instead of filling
    /// at a worse price for the front-runner's profit.
    function test_Finding65_frontRunBuyRevertsSeedLong() public {
        address v = SeedLimits.vammOf(address(marketRegistry), ETH_PERP);
        uint256 maxIn = SeedLimits.longMaxQuoteIn(v, SEED);

        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, true, 5 ether, 0);

        vm.prank(seedLong);
        vm.expectRevert(bytes("slippage"));
        clearingHouse.openPosition(ETH_PERP, true, SEED, maxIn);
    }

    /// @notice Finding 65: a sell sequenced ahead of the seed short makes it revert.
    function test_Finding65_frontRunSellRevertsSeedShort() public {
        address v = SeedLimits.vammOf(address(marketRegistry), ETH_PERP);
        uint256 minOut = SeedLimits.shortMinQuoteOut(v, SEED);

        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 5 ether, 0);

        vm.prank(seedShort);
        vm.expectRevert(bytes("slippage"));
        clearingHouse.openPosition(ETH_PERP, false, SEED, minOut);
    }

    /// @notice Finding 65: every seeding script takes its limits from SeedLimits, and the first
    /// market's script seeds behind the trader allowlist.
    function test_Finding65_seedScriptsUseTightLimits() public view {
        string[4] memory scripts = [
            "./script/SeedAndUnpauseH100.s.sol",
            "./script/SeedMoreMarkets.s.sol",
            "./script/CompleteSepoliaMarkets.s.sol",
            "./script/SeedMarket.s.sol"
        ];
        for (uint256 i; i < scripts.length; i++) {
            string memory src = vm.readFile(scripts[i]);
            assertTrue(vm.indexOf(src, "SeedLimits.longMaxQuoteIn(") != type(uint256).max, scripts[i]);
            assertTrue(vm.indexOf(src, "SeedLimits.shortMinQuoteOut(") != type(uint256).max, scripts[i]);
            assertEq(vm.indexOf(src, "LONG_MAX_BPS"), type(uint256).max, scripts[i]);
            assertEq(vm.indexOf(src, "LONG_MAX_QUOTE_IN_X18"), type(uint256).max, scripts[i]);
        }
        string memory h100 = vm.readFile(scripts[0]);
        assertTrue(vm.indexOf(h100, "setAllowlistEnforced(true)") != type(uint256).max, "H100 seeds behind allowlist");
    }
}
