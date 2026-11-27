// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

/// @notice Finding 35: a funding payer's debit rounds up; a receiver's credit rounds down.
contract AuditFixesPart2FundingRoundingTest is BaseTest {
    uint128 internal constant ODD_SIZE = 3_333_333_333_333_333_333;

    function _ceil(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + 1e18 - 1) / 1e18;
    }

    function test_Finding35_PayerDebitRoundsUp() public {
        fundAndDeposit(alice, 10_000e18);
        fundAndDeposit(bob, 10_000e18);
        // Alice's long lifts the mark above the index, so longs pay funding.
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, ODD_SIZE, 0);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 1e18, 0);

        vm.warp(block.timestamp + 37 minutes);
        IClearingHouse.PositionView memory p = clearingHouse.getPosition(alice, ETH_PERP);
        uint256 payDelta = vamm.currentCumulativeLongPayPerUnitX18() - p.lastFundingPayIndex;
        uint256 receiveDelta = vamm.currentCumulativeLongReceivePerUnitX18() - p.lastFundingReceiveIndex;
        assertGt(payDelta, receiveDelta);
        uint256 exact = (payDelta - receiveDelta) * ODD_SIZE;
        assertTrue(exact % 1e18 != 0, "test needs a fractional payment");
        uint256 expected = _ceil(payDelta - receiveDelta, ODD_SIZE);

        uint256 balBefore = vault.balanceOf(alice, address(usdc));
        clearingHouse.settleFunding(ETH_PERP, alice);
        assertEq(balBefore - vault.balanceOf(alice, address(usdc)), expected);
    }
}
