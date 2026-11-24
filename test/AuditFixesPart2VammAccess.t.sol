// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

/// @notice Regression tests for vAMM admin access (Cyfrin bytestrike part 2).
contract AuditFixesPart2VammAccessTest is BaseTest {
    /// @notice Finding 60: the vAMM's clearinghouse cannot be replaced, so open positions can never be
    /// stranded in a clearinghouse that no longer reaches the vAMM.
    function test_Finding60_clearinghouseCannotBeReplaced() public {
        address newCH = makeAddr("newCH");
        vm.prank(admin);
        (bool ok,) = address(vamm).call(abi.encodeWithSignature("setClearinghouse(address)", newCH));
        assertFalse(ok, "setClearinghouse must not exist");
        assertEq(vamm.clearinghouse(), address(clearingHouse));
    }

    /// @notice Finding 44: only the registry toggles the vAMM's swap flag, so the vAMM owner cannot
    /// restart funding on a market the registry keeps paused.
    function test_Finding44_ownerCannotToggleSwaps() public {
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, true);

        vm.prank(admin);
        vm.expectRevert("Not authorized");
        vamm.pauseSwaps(false);
        assertTrue(vamm.swapsPaused());

        vm.prank(address(clearingHouse));
        vm.expectRevert("Not authorized");
        vamm.pauseSwaps(false);

        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, false);
        assertFalse(vamm.swapsPaused());
    }

    /// @notice Finding 44: funding settlement skips accrual while the registry reports the market
    /// inactive, whatever the vAMM's own flag says.
    function test_Finding44_noFundingAccruesWhileMarketInactive() public {
        fundAndDeposit(alice, 50_000 * USDC_UNIT);
        fundAndDeposit(bob, 50_000 * USDC_UNIT);
        openLongPosition(alice, ethQty(10), 0); // mark above index: longs pay
        openShortPosition(bob, ethQty(1), 0);

        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();
        uint256 t = block.timestamp + 1 hours;
        vm.warp(t);

        vm.mockCall(
            address(marketRegistry), abi.encodeCall(IMarketRegistry.isActive, (ETH_PERP)), abi.encode(false)
        );
        clearingHouse.settleFunding(ETH_PERP, alice);
        vm.clearMockedCalls();

        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "no funding while inactive");
        assertEq(vamm.lastFundingTimestamp(), t, "funding clock advanced past the inactive time");

        // Once active again, funding accrues normally from that point
        vm.warp(t + 1 hours);
        clearingHouse.settleFunding(ETH_PERP, alice);
        assertGt(vamm.cumulativeLongPayPerUnitX18(), payBefore, "funding resumes when active");
    }
}
