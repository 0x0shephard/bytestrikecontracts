// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Oracle, Oracle_StalePeriodNotSet, PriceIsStale} from "../src/Oracle/Oracle.sol";

/// @dev Minimal Chainlink-style feed with a settable update time.
contract StaleTestFeed {
    uint256 public updatedAt;

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, updatedAt, updatedAt, 1);
    }
}

/// @notice Regression tests for per-feed Oracle stale periods (Cyfrin bytestrike part 2, finding 33).
contract AuditFixesPart2OracleTest is Test {
    Oracle internal oracle;
    StaleTestFeed internal feed;

    function setUp() public {
        vm.warp(1_000_000);
        oracle = new Oracle();
        feed = new StaleTestFeed();
        feed.setUpdatedAt(block.timestamp);
        oracle.setPriceFeed("USDC", address(feed));
        oracle.setBaseUnit("USDC", 1e6);
    }

    /// @notice Finding 33: a feed whose stale period was never configured cannot be read, instead of
    /// silently falling back to a one-hour default.
    function test_Finding33_unsetStalePeriodReverts() public {
        vm.expectRevert(Oracle_StalePeriodNotSet.selector);
        oracle.getPrice("USDC");
        vm.expectRevert(Oracle_StalePeriodNotSet.selector);
        oracle.getUnderlyingPrice("USDC");
    }

    /// @notice Finding 33: the configured per-feed period is enforced.
    function test_Finding33_perFeedStalePeriodEnforced() public {
        oracle.setPriceStalePeriodForToken("USDC", 600);
        feed.setUpdatedAt(block.timestamp - 600);
        assertEq(oracle.getPrice("USDC"), 1e18);

        feed.setUpdatedAt(block.timestamp - 601);
        vm.expectRevert(PriceIsStale.selector);
        oracle.getPrice("USDC");
    }

    /// @notice Finding 33: clearing a feed's period makes it unreadable again.
    function test_Finding33_clearedStalePeriodReverts() public {
        oracle.setPriceStalePeriodForToken("USDC", 600);
        oracle.setPriceStalePeriodForToken("USDC", 0);
        vm.expectRevert(Oracle_StalePeriodNotSet.selector);
        oracle.getPrice("USDC");
    }
}
