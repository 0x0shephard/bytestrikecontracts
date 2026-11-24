// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";

contract PositionSizeLimitsTest is BaseTest {
    uint256 internal constant DEPOSIT = 20_000 * USDC_UNIT;

    function setUp() public override {
        super.setUp();
        fundAndDeposit(alice, DEPOSIT);
        fundAndDeposit(bob, DEPOSIT);
    }

    function _setSizeLimits(uint256 maxSize, uint256 minSize) internal {
        vm.prank(admin);
        clearingHouse.setRiskParams(
            ETH_PERP, IMR_BPS, MMR_BPS, LIQUIDATION_PENALTY_BPS, PENALTY_CAP, maxSize, minSize
        );
    }

    function _open(address trader, bool isLong, uint128 size) internal {
        vm.prank(trader);
        clearingHouse.openPosition(ETH_PERP, isLong, size, 0);
    }

    // --- maxPositionSize ---

    function test_ReducingAboveLoweredMaxSizeViaOpenPositionIsAllowed() public {
        _open(alice, true, ethQty(10));
        _setSizeLimits(5 ether, 0); // alice's long is now above the limit

        _open(alice, false, ethQty(1)); // 10 -> 9, still above the limit
        assertEq(getPosition(alice).size, 9 ether);
    }

    function test_ReducingShortAboveLoweredMaxSizeViaOpenPositionIsAllowed() public {
        _open(alice, false, ethQty(10));
        _setSizeLimits(5 ether, 0);

        _open(alice, true, ethQty(1)); // -10 -> -9
        assertEq(getPosition(alice).size, -9 ether);
    }

    function test_GrowingAboveMaxSizeStillReverts() public {
        _open(alice, true, ethQty(10));
        _setSizeLimits(5 ether, 0);
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 2_000 * USDC_UNIT); // enough margin that only the limit can block

        vm.prank(alice);
        vm.expectRevert(ClearingHouse.ExceedsMaxSize.selector);
        clearingHouse.openPosition(ETH_PERP, true, ethQty(1), 0);
    }

    function test_FlipAboveMaxSizeStillReverts() public {
        _open(alice, true, ethQty(10));
        _setSizeLimits(5 ether, 0);

        // long 10 -> short 6: a flip, checked in full
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.ExceedsMaxSize.selector);
        clearingHouse.openPosition(ETH_PERP, false, ethQty(16), 0);
    }

    // --- minPositionSize on closePosition ---

    function test_FullCloseClampedByReserveFloorLeavesDustWithoutReverting() public {
        _open(alice, false, ethQty(10));
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 2_000 * USDC_UNIT);
        _setSizeLimits(0, 1 ether);

        // Base floor leaves 9.5 ETH of room: a full close of the 10 ETH short is clamped to 9.5
        (uint256 baseReserve,) = getReserves();
        vm.prank(admin);
        vamm.setMinReserves(baseReserve - 9.5 ether, 0);

        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, ethQty(10), 0);
        assertEq(getPosition(alice).size, -0.5 ether, "clamped close leaves the unfilled rest");
    }

    function test_PartialCloseLeavingDustStillReverts() public {
        _open(alice, true, ethQty(10));
        _setSizeLimits(0, 1 ether);

        vm.prank(alice);
        vm.expectRevert(ClearingHouse.RemainingBelowMinCloseFull.selector);
        clearingHouse.closePosition(ETH_PERP, 9.5 ether, 0);

        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, ethQty(9), 0); // leaves exactly the minimum
        assertEq(getPosition(alice).size, 1 ether);
    }
}
