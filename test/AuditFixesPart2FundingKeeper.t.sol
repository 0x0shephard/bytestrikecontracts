// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {FundingKeeper} from "../script/FundingKeeper.s.sol";

/// @notice Regression tests for the funding keeper (Cyfrin bytestrike part 2, finding 41).
contract AuditFixesPart2FundingKeeperTest is BaseTest {
    FundingKeeper internal keeper;
    bytes32[] internal markets;
    uint256 internal _now;

    function setUp() public override {
        super.setUp();
        keeper = new FundingKeeper();
        markets.push(ETH_PERP);

        // Alice is long 10, carol short 1; the index drops so the mark sits above it and longs pay.
        address carol = makeAddr("carol");
        fundAndDeposit(alice, 100_000e18);
        fundAndDeposit(carol, 100_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        vm.prank(carol);
        clearingHouse.openPosition(ETH_PERP, false, 1e18, 0);
        setOraclePrice(1960e18);
        _now = block.timestamp;
        keeper.settleAll(address(clearingHouse), markets); // caches the new index
    }

    /// @notice Finding 41: with the keeper settling every 30 minutes, an 8-hour quiet period is charged
    /// in full; a single settlement after 8 hours books only the first hour (the cap).
    function test_Finding41_keeperAccruesEveryHourOfAQuietPeriod() public {
        uint256 start = vamm.cumulativeLongPayPerUnitX18();
        uint256 interval = keeper.KEEPER_INTERVAL();
        assertLe(interval * 2, vamm.MAX_FUNDING_ELAPSED(), "keeper interval reaches the cap");

        uint256 snap = vm.snapshotState();
        // Without the keeper: one settlement after 8 hours.
        vm.warp(_now + 8 hours);
        settleFunding(alice);
        uint256 unkept = vamm.cumulativeLongPayPerUnitX18() - start;
        vm.revertToState(snap);

        // With the keeper: a settlement every 30 minutes (mark and index unchanged throughout).
        uint256 t = _now;
        uint256 first;
        for (uint256 i; i < 16; i++) {
            t += interval;
            vm.warp(t);
            keeper.settleAll(address(clearingHouse), markets);
            if (i == 0) first = vamm.cumulativeLongPayPerUnitX18() - start;
        }
        uint256 kept = vamm.cumulativeLongPayPerUnitX18() - start;

        assertGt(first, 0, "no funding owed");
        assertApproxEqAbs(kept, 16 * first, 16, "keeper dropped funding");
        assertApproxEqAbs(unkept, 2 * first, 2, "single settlement is capped at one hour");
    }
}
