// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

contract OpenInterestCapsTest is BaseTest {
    address internal carol = makeAddr("carol");

    uint256 internal constant DEPOSIT = 20_000 * USDC_UNIT;
    /// @dev Gross cap high enough not to bind, for tests that exercise the net cap.
    uint128 internal constant NO_GROSS_LIMIT = 1_000 ether;

    function setUp() public override {
        super.setUp();
        fundAndDeposit(alice, DEPOSIT);
        fundAndDeposit(bob, DEPOSIT);
        fundAndDeposit(carol, DEPOSIT);
    }

    function _setCaps(uint128 maxGross, uint128 maxNet) internal {
        vm.prank(admin);
        clearingHouse.setOpenInterestCaps(ETH_PERP, maxGross, maxNet);
    }

    function _open(address trader, bool isLong, uint128 size) internal {
        vm.prank(trader);
        clearingHouse.openPosition(ETH_PERP, isLong, size, 0);
    }

    function _expectOpenRevert(address trader, bool isLong, uint128 size, bytes4 selector) internal {
        vm.prank(trader);
        vm.expectRevert(selector);
        clearingHouse.openPosition(ETH_PERP, isLong, size, 0);
    }

    function _net() internal view returns (uint256) {
        uint256 longOI = clearingHouse.totalLongOI(ETH_PERP);
        uint256 shortOI = clearingHouse.totalShortOI(ETH_PERP);
        return longOI > shortOI ? longOI - shortOI : shortOI - longOI;
    }

    function _gross() internal view returns (uint256) {
        return clearingHouse.totalLongOI(ETH_PERP) + clearingHouse.totalShortOI(ETH_PERP);
    }

    // --- Defaults and configuration ---

    function test_NewMarketsHaveNoCaps() public {
        (uint128 maxGross, uint128 maxNet) = clearingHouse.openInterestCaps(ETH_PERP);
        assertEq(maxGross, 0);
        assertEq(maxNet, 0);

        _open(alice, true, ethQty(5));
        _open(bob, true, ethQty(5));
        assertEq(clearingHouse.totalLongOI(ETH_PERP), ethQty(10));
    }

    function test_OwnerCanSetCapsAndEventIsEmitted() public {
        vm.expectEmit(true, false, false, true, address(clearingHouse));
        emit IClearingHouse.OpenInterestCapsSet(ETH_PERP, 10 ether, 4 ether);
        _setCaps(10 ether, 4 ether);

        (uint128 maxGross, uint128 maxNet) = clearingHouse.openInterestCaps(ETH_PERP);
        assertEq(maxGross, 10 ether);
        assertEq(maxNet, 4 ether);
    }

    function test_OnlyOwnerCanSetCaps() public {
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.NotAdmin.selector);
        clearingHouse.setOpenInterestCaps(ETH_PERP, 10 ether, 4 ether);
    }

    function test_SetCapsRejectsUnknownMarket() public {
        vm.prank(admin);
        vm.expectRevert();
        clearingHouse.setOpenInterestCaps(keccak256("NO-SUCH-PERP"), 10 ether, 4 ether);
    }

    function test_SetCapsRejectsNetAboveGross() public {
        vm.prank(admin);
        vm.expectRevert(ClearingHouse.InvalidOpenInterestCaps.selector);
        clearingHouse.setOpenInterestCaps(ETH_PERP, 4 ether, 5 ether);
    }

    function test_NetCapRequiresGrossCap() public {
        vm.prank(admin);
        vm.expectRevert(ClearingHouse.InvalidOpenInterestCaps.selector);
        clearingHouse.setOpenInterestCaps(ETH_PERP, 0, 4 ether);
    }

    function test_GrossCapAloneIsAllowed() public {
        _setCaps(4 ether, 0);
        (uint128 maxGross, uint128 maxNet) = clearingHouse.openInterestCaps(ETH_PERP);
        assertEq(maxGross, 4 ether);
        assertEq(maxNet, 0);
    }

    function test_StorageIsAppendedAtSlot13() public {
        _setCaps(10 ether, 4 ether);
        bytes32 entry = keccak256(abi.encode(ETH_PERP, uint256(13)));
        uint256 packed = uint256(vm.load(address(clearingHouse), entry));
        assertEq(uint128(packed), 10 ether);
        assertEq(packed >> 128, 4 ether);
    }

    // --- Gross cap ---

    function test_GrossCapAllowsTradesUpToTheCap() public {
        _setCaps(4 ether, 0);
        _open(alice, true, ethQty(2));
        _open(bob, false, ethQty(2));
        assertEq(_gross(), 4 ether);
    }

    function test_GrossCapCountsBothSides() public {
        _setCaps(4 ether, 0);
        _open(alice, true, ethQty(2));
        _open(bob, false, ethQty(2));

        _expectOpenRevert(carol, true, ethQty(1), ClearingHouse.ExceedsMaxGrossOI.selector);
        _expectOpenRevert(carol, false, ethQty(1), ClearingHouse.ExceedsMaxGrossOI.selector);
    }

    function test_GrossCapBlocksIncreasingAnExistingPosition() public {
        _setCaps(3 ether, 0);
        _open(alice, true, ethQty(3));
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 2_000 * USDC_UNIT); // enough margin that only the cap can block
        _expectOpenRevert(alice, true, ethQty(1), ClearingHouse.ExceedsMaxGrossOI.selector);
    }

    // --- Net cap ---

    function test_NetCapBlocksOneSidedExposure() public {
        _setCaps(NO_GROSS_LIMIT, 2 ether);
        _open(alice, true, ethQty(2));
        _expectOpenRevert(bob, true, ethQty(1), ClearingHouse.ExceedsMaxNetOI.selector);
    }

    function test_NetCapAllowsBalancedGrowth() public {
        _setCaps(NO_GROSS_LIMIT, 2 ether);
        _open(alice, true, ethQty(2));
        _open(bob, false, ethQty(4)); // net moves from +2 to -2
        _open(carol, true, ethQty(4)); // net moves from -2 to +2

        assertEq(clearingHouse.totalLongOI(ETH_PERP), 6 ether);
        assertEq(clearingHouse.totalShortOI(ETH_PERP), 4 ether);
    }

    function test_NetCapBlocksOvershootOnTheOtherSide() public {
        _setCaps(NO_GROSS_LIMIT, 2 ether);
        _open(alice, true, ethQty(2));
        _expectOpenRevert(bob, false, ethQty(5), ClearingHouse.ExceedsMaxNetOI.selector); // net would be -3
    }

    // --- Lowered caps never trap positions ---

    function test_RiskReducingOpenIsAllowedAboveTheNetCap() public {
        _open(alice, true, ethQty(5));
        _setCaps(NO_GROSS_LIMIT, 2 ether);

        _open(bob, false, ethQty(1)); // net falls from 5 to 4, still above cap
        assertEq(clearingHouse.totalShortOI(ETH_PERP), 1 ether);
    }

    function test_FlippingDownIsAllowedAboveTheGrossCap() public {
        _open(alice, true, ethQty(5));
        _setCaps(2 ether, 0);

        _open(alice, false, ethQty(6)); // long 5 -> short 1, gross falls from 5 to 1
        assertEq(_gross(), 1 ether);
    }

    function test_ReducingViaOpenPositionIsExemptLikeClose() public {
        _open(bob, false, ethQty(2));
        _open(alice, true, ethQty(2));
        _setCaps(NO_GROSS_LIMIT, 1 ether);

        _open(bob, true, ethQty(2)); // bob closes his short via openPosition; net moves 0 -> 2
        assertEq(clearingHouse.totalShortOI(ETH_PERP), 0);
    }

    function test_FlipViaOpenPositionIsStillCapped() public {
        _open(bob, false, ethQty(2));
        _open(alice, true, ethQty(2));
        _setCaps(NO_GROSS_LIMIT, 1 ether);

        // bob short 2 -> long 2: not a pure reduction, net would go 0 -> 4
        _expectOpenRevert(bob, true, ethQty(4), ClearingHouse.ExceedsMaxNetOI.selector);
    }

    function test_ClosingIsAllowedAboveTheCaps() public {
        _open(alice, true, ethQty(5));
        _setCaps(1 ether, 1 ether);

        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, ethQty(5), 0);
        assertEq(_gross(), 0);
    }

    function test_LiquidationIsAllowedAboveTheCaps() public {
        _open(alice, true, ethQty(5));
        _setCaps(1 ether, 1 ether);

        setOraclePrice(1_800 * PRICE_PRECISION);
        assertTrue(isLiquidatable(alice));

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, ethQty(5), 0);
        assertEq(getPosition(alice).size, 0);
    }

    function test_RemovingCapsRestoresUnlimitedTrading() public {
        _setCaps(1 ether, 1 ether);
        _open(alice, true, ethQty(1));
        _setCaps(0, 0);
        _open(bob, true, ethQty(5));
        assertEq(clearingHouse.totalLongOI(ETH_PERP), 6 ether);
    }

    // --- Interaction with existing per-account cap ---

    function test_PerAccountCapStillApplies() public {
        vm.prank(admin);
        clearingHouse.setRiskParams(
            ETH_PERP, IMR_BPS, MMR_BPS, LIQUIDATION_PENALTY_BPS, PENALTY_CAP, 2 ether, MIN_POSITION_SIZE
        );
        _setCaps(10 ether, 10 ether);

        _expectOpenRevert(alice, true, ethQty(3), ClearingHouse.ExceedsMaxSize.selector);
    }

    function testFuzz_CapsHoldAfterEveryAcceptedTrade(uint8[8] memory sizes, bool[8] memory sides) public {
        _setCaps(6 ether, 3 ether);
        address[3] memory traders = [alice, bob, carol];

        for (uint256 i = 0; i < 8; i++) {
            uint128 size = uint128(bound(sizes[i], 1, 4)) * 1 ether;
            address trader = traders[i % 3];
            uint256 netBefore = _net();
            int256 sizeBefore = clearingHouse.getPosition(trader, ETH_PERP).size;
            vm.prank(trader);
            try clearingHouse.openPosition(ETH_PERP, sides[i], size, 0) {} catch {}
            int256 sizeAfter = clearingHouse.getPosition(trader, ETH_PERP).size;

            // Gross is a hard bound. Net is bounded for any trade that grows it, except a
            // pure reduction of the trader's own position, which is exempt like closePosition.
            assertLe(_gross(), 6 ether);
            bool pureReduction = (sizeBefore > 0 && sizeAfter >= 0 && sizeAfter <= sizeBefore)
                || (sizeBefore < 0 && sizeAfter <= 0 && sizeAfter >= sizeBefore);
            uint256 netAfter = _net();
            if (netAfter > netBefore && !pureReduction) assertLe(netAfter, 3 ether);
        }
    }
}
