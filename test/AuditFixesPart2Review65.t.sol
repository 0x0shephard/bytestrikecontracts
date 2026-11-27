// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {SeedLimits} from "../script/SeedLimits.sol";

/// @notice SeedB200ProviderMarkets (and SetupH100Live) take their seed limits from SeedLimits, so a buy
/// sequenced ahead of a seed long makes the seed revert instead of filling near a loose 110% limit
contract AuditFixesPart2Review65Test is BaseTest {
    // Seed size at 1% of the base reserve, as the B200 script's 100 units against its 10,000 base reserve
    uint128 internal constant SEED_SIZE = 10e18;
    uint128 internal constant FRONT_RUN_SIZE = 41e18;

    address internal seedLong = makeAddr("seedLong");

    function test_B200SeedScriptUsesSeedLimits() public view {
        string memory src = vm.readFile("./script/DeployB200ProviderMarkets.s.sol");
        assertTrue(vm.indexOf(src, "contract SeedB200ProviderMarkets") != type(uint256).max, "seed contract gone");
        assertEq(vm.indexOf(src, "LONG_MAX_BPS"), type(uint256).max, "loose long limit still there");
        assertEq(vm.indexOf(src, "SHORT_MIN_BPS"), type(uint256).max, "loose short limit still there");
        assertTrue(vm.indexOf(src, "SeedLimits.longMaxQuoteIn(market.vamm, SEED_SIZE)") != type(uint256).max, "long");
        assertTrue(vm.indexOf(src, "SeedLimits.shortMinQuoteOut(market.vamm, SEED_SIZE)") != type(uint256).max, "short");

        string memory live = vm.readFile("./script/SetupH100Live.s.sol");
        assertTrue(vm.indexOf(live, "SeedLimits.longMaxQuoteIn(") != type(uint256).max, "H100 live limit");
        assertEq(vm.indexOf(live, "POSITION_SIZE, 0)"), type(uint256).max, "H100 live opens with no limit");
    }

    function test_B200SeedLongRevertsAfterFrontRun() public {
        fundAndDeposit(seedLong, 10_000 * USDC_UNIT);
        fundAndDeposit(bob, 100_000 * USDC_UNIT);
        address v = SeedLimits.vammOf(address(marketRegistry), ETH_PERP);

        // Bob buys ahead of the seed long, which reads its limit at the reserves before his trade
        uint256 maxQuoteIn = SeedLimits.longMaxQuoteIn(v, SEED_SIZE);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, true, FRONT_RUN_SIZE, 0);

        // The seed long now reverts instead of overpaying
        vm.prank(seedLong);
        vm.expectRevert(bytes("slippage"));
        clearingHouse.openPosition(ETH_PERP, true, SEED_SIZE, maxQuoteIn);
        assertEq(getPosition(seedLong).size, 0, "seed filled");
    }
}
