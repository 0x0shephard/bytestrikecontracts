// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {Oracle, PriceIsStale} from "../src/Oracle/Oracle.sol";

/// @dev Chainlink-style feed with a round history; each pushed round is stamped with the current time.
contract RoundHistoryFeed {
    uint8 public decimals = 8;
    int256[] internal answers;
    uint256[] internal times;

    function push(int256 answer) external {
        answers.push(answer);
        times.push(block.timestamp);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint80 id = uint80(answers.length);
        return (id, answers[id - 1], times[id - 1], times[id - 1], id);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(id > 0 && id <= answers.length, "no round");
        return (id, answers[id - 1], times[id - 1], times[id - 1], id);
    }
}

/// @notice Regression for finding 25 (third mitigation review): after a stale quote-token round, the
/// round that makes the price readable again opens addMargin and depositMargin, but liquidations stay
/// closed for LIQUIDATION_REACTION_WINDOW, as after the sequencer grace period.
contract AuditFixesPart2Review25cTest is BaseTest {
    uint256 internal constant STALE_PERIOD = 1 hours;
    Oracle internal quoteOracle;
    RoundHistoryFeed internal usdcFeed;
    uint256 internal resumedAt;

    function setUp() public override {
        super.setUp();
        vm.warp(100_000);
        vm.startPrank(admin);
        quoteOracle = new Oracle();
        usdcFeed = new RoundHistoryFeed();
        usdcFeed.push(1e8);
        quoteOracle.setPriceFeed("USDC", address(usdcFeed));
        quoteOracle.setPriceStalePeriodForToken("USDC", STALE_PERIOD);
        vault.setOracle(address(quoteOracle));
        vm.stopPrank();

        // rounds land every 20 minutes while alice opens a 5 ETH long with all but a little of her deposit
        fundAndDeposit(alice, 650e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 5e18, 0);
        vm.warp(block.timestamp + 20 minutes);
        usdcFeed.push(1e8);

        // the USDC feed goes stale; while it is, the index falls and alice cannot top up
        vm.warp(block.timestamp + STALE_PERIOD + 10 minutes);
        oracle.setPrice(INITIAL_ETH_PRICE * 97 / 100);
        vm.prank(alice);
        vm.expectRevert(PriceIsStale.selector);
        clearingHouse.addMargin(ETH_PERP, 10e18);

        // the next round lands: the price is readable again and the long is liquidatable
        vm.warp(block.timestamp + 30 minutes);
        usdcFeed.push(1e8);
        resumedAt = block.timestamp;
        assertTrue(isLiquidatable(alice), "not liquidatable");
    }

    function test_LiquidationWaitsAfterStaleQuoteRound() public {
        assertEq(quoteOracle.priceResumedAt("USDC", clearingHouse.LIQUIDATION_REACTION_WINDOW()), resumedAt);

        // the keeper cannot liquidate in the block the fresh round lands
        vm.prank(liquidator);
        vm.expectRevert(ClearingHouse.LiquidationReactionWindow.selector);
        clearingHouse.liquidate(alice, ETH_PERP, 5e18, 0);

        // a later round inside the window does not reopen it
        vm.warp(block.timestamp + 10 minutes);
        usdcFeed.push(1e8);
        vm.prank(liquidator);
        vm.expectRevert(ClearingHouse.LiquidationReactionWindow.selector);
        clearingHouse.liquidate(alice, ETH_PERP, 5e18, 0);

        // alice tops up within the window and is safe
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 10e18);
        fundUser(alice, 200e18);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        clearingHouse.depositMargin(ETH_PERP, 100e18);
        vm.stopPrank();
        assertFalse(isLiquidatable(alice), "top-up did not cure");
    }

    function test_LiquidationReopensAfterWindow() public {
        vm.warp(resumedAt + clearingHouse.LIQUIDATION_REACTION_WINDOW());
        assertEq(quoteOracle.priceResumedAt("USDC", clearingHouse.LIQUIDATION_REACTION_WINDOW()), 0);
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 5e18, 0);
        assertLt(getPosition(alice).size, int256(5e18), "not liquidated");
    }

    /// @notice Rounds that never went stale open no window.
    function test_NoStaleRoundNoWindow() public {
        vm.warp(resumedAt + clearingHouse.LIQUIDATION_REACTION_WINDOW());
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 20 minutes);
            usdcFeed.push(1e8);
        }
        assertEq(quoteOracle.priceResumedAt("USDC", clearingHouse.LIQUIDATION_REACTION_WINDOW()), 0);
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 5e18, 0);
    }
}
