// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

/// @notice Regression for finding 4 (mitigation review): a position liquidated across several capped
/// calls pays at most penaltyCap in total for one liquidatable episode.
contract AuditFixesPart2Review4Test is BaseTest {
    address internal restorer;

    uint256 internal constant CAP = 1_000e18;
    uint128 internal constant ALICE_SIZE = 50e18;
    uint256 internal constant INDEX = 1_920e18;

    function setUp() public override {
        super.setUp();
        restorer = makeAddr("restorer");

        vm.prank(admin);
        clearingHouse.setRiskParams(
            ETH_PERP, IMR_BPS, MMR_BPS, LIQUIDATION_PENALTY_BPS, CAP, MAX_POSITION_SIZE, MIN_POSITION_SIZE
        );
        fundAndDeposit(restorer, 300_000e18);
    }

    function _openAndGap(address user) internal {
        _openAndGapTo(user, INDEX);
    }

    function _openAndGapTo(address user, uint256 index) internal {
        fundAndDeposit(user, 16_000e18);
        vm.prank(user);
        clearingHouse.openPosition(ETH_PERP, true, ALICE_SIZE, 0);

        setOraclePrice(index);
        fundAndDeposit(bob, 200_000e18);
        (uint256 x, uint256 y) = getReserves();
        uint256 xTarget = _sqrtBase((x * y / index) * 1e18);
        if (xTarget > x) {
            vm.prank(bob);
            clearingHouse.openPosition(ETH_PERP, false, uint128(xTarget - x), 0);
        }
    }

    function _liquidateAndSumPenalties(address user, address arb)
        internal
        returns (uint256 calls, uint256 totalPenalty)
    {
        vm.recordLogs();
        calls = liquidateFully(user, ETH_PERP, arb);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(clearingHouse) || l.topics.length == 0) continue;
            if (l.topics[0] != IClearingHouse.LiquidationExecuted.selector) continue;
            (,, uint256 penalty,,,) = abi.decode(l.data, (uint128, uint256, uint256, uint256, uint256, uint256));
            totalPenalty += penalty;
        }
    }

    function test_ChunkedLiquidationPenaltyCappedPerPosition() public {
        _openAndGap(alice);
        assertTrue(isLiquidatable(alice));
        uint256 wholeNotional = uint256(ALICE_SIZE) * INDEX / 1e18;
        assertGt(wholeNotional * LIQUIDATION_PENALTY_BPS / 10_000, CAP);

        (uint256 calls, uint256 totalPenalty) = _liquidateAndSumPenalties(alice, restorer);
        assertEq(getPosition(alice).size, 0);
        assertGt(calls, 1);
        // the running total is capped: the position pays exactly one cap over all its calls
        assertEq(totalPenalty, CAP);
        assertEq(getPosition(alice).liquidationPenaltyCharged, 0, "not reset on close");
    }

    function test_PenaltyCapResetsForANewPosition() public {
        _openAndGap(alice);
        (, uint256 first) = _liquidateAndSumPenalties(alice, restorer);
        assertEq(first, CAP);

        // a fresh position of the same account starts a new episode with a full cap
        _openAndGapTo(alice, 1_840e18);
        assertTrue(isLiquidatable(alice));
        // a second arbitrageur restores the mark (the first one's long is under water at the new index)
        address restorer2 = makeAddr("restorer2");
        fundAndDeposit(restorer2, 300_000e18);
        (, uint256 second) = _liquidateAndSumPenalties(alice, restorer2);
        assertEq(second, CAP);
    }
}
