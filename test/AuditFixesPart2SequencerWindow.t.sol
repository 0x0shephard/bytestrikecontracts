// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {Oracle, GracePeriodNotOver} from "../src/Oracle/Oracle.sol";

/// @dev Chainlink-style feed whose answer and startedAt are set by the test; updatedAt is always now.
contract SequencerTestFeed {
    int256 public answer;
    uint256 public startedAt = 1;
    uint8 public decimals = 8;

    constructor(int256 answer_) {
        answer = answer_;
    }

    function set(int256 answer_, uint256 startedAt_) external {
        answer = answer_;
        startedAt = startedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, block.timestamp, 1);
    }
}

/// @notice Finding 25: liquidations wait a reaction window after the quote oracle's sequencer grace
///         period, in which addMargin works again.
contract AuditFixesPart2SequencerWindowTest is BaseTest {
    Oracle internal quoteOracle;
    SequencerTestFeed internal uptimeFeed;
    uint256 internal restartAt;

    function setUp() public override {
        super.setUp();
        vm.warp(100_000);
        vm.startPrank(admin);
        quoteOracle = new Oracle();
        quoteOracle.setPriceFeed("USDC", address(new SequencerTestFeed(1e8)));
        quoteOracle.setPriceStalePeriodForToken("USDC", 1 days);
        uptimeFeed = new SequencerTestFeed(0);
        quoteOracle.setSequencerUptimeFeed(address(uptimeFeed));
        vault.setOracle(address(quoteOracle));
        vm.stopPrank();

        fundAndDeposit(alice, 2_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);

        // The sequencer restarts; during its grace period the index falls and Alice cannot top up.
        restartAt = block.timestamp;
        uptimeFeed.set(0, restartAt);
        oracle.setPrice(INITIAL_ETH_PRICE * 96 / 100);
        vm.warp(restartAt + 600);
        vm.prank(alice);
        vm.expectRevert(GracePeriodNotOver.selector);
        clearingHouse.addMargin(ETH_PERP, 400e18);
    }

    function test_Finding25_LiquidationWaitsForReactionWindow() public {
        uint256 graceEnd = restartAt + quoteOracle.SEQUENCER_GRACE_PERIOD();
        assertEq(quoteOracle.sequencerGraceEndsAt(), graceEnd);
        vm.warp(graceEnd + 1);
        assertTrue(clearingHouse.isLiquidatable(alice, ETH_PERP));

        // The keeper cannot liquidate in the block the grace period ends.
        vm.prank(liquidator);
        vm.expectRevert(ClearingHouse.LiquidationReactionWindow.selector);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);

        // Alice tops up within the window and is safe.
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 400e18);
        assertFalse(clearingHouse.isLiquidatable(alice, ETH_PERP));
    }

    function test_Finding25_LiquidationReopensAfterWindow() public {
        vm.warp(restartAt + quoteOracle.SEQUENCER_GRACE_PERIOD() + clearingHouse.LIQUIDATION_REACTION_WINDOW());
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);
        assertTrue(clearingHouse.getPosition(alice, ETH_PERP).size < 10e18);
    }

    /// @notice An oracle without an uptime feed leaves liquidation unchanged.
    function test_Finding25_NoUptimeFeedNoWindow() public {
        vm.prank(admin);
        quoteOracle.setSequencerUptimeFeed(address(0));
        assertEq(quoteOracle.sequencerGraceEndsAt(), 0);
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);
    }
}
