// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

contract TraderAllowlistTest is BaseTest {
    address internal manager = makeAddr("manager");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant DEPOSIT = 5_000 * USDC_UNIT;
    uint256 internal constant AMOUNT = 100 * USDC_UNIT;
    uint128 internal constant SIZE = 1 ether;

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        clearingHouse.setAllowlistManager(manager);
    }

    function _setAllowed(address trader, bool isAllowed) internal {
        address[] memory traders = new address[](1);
        traders[0] = trader;
        vm.prank(manager);
        clearingHouse.setAllowedTraders(traders, isAllowed);
    }

    function _enforce() internal {
        vm.prank(admin);
        clearingHouse.setAllowlistEnforced(true);
    }

    /// @dev Gives alice a position and free collateral, then enforces with alice listed.
    function _aliceTradingWhileEnforced() internal {
        _setAllowed(alice, true);
        _enforce();
        fundAndDeposit(alice, DEPOSIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, SIZE, 0);
    }

    // --- Rollout ---

    function test_NewDeploymentStartsUnenforced() public {
        assertFalse(clearingHouse.allowlistEnforced());

        fundAndDeposit(alice, DEPOSIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, SIZE, 0);

        assertGt(getPosition(alice).size, 0);
    }

    function test_SwitchingOffRestoresAccess() public {
        _enforce();
        vm.prank(admin);
        clearingHouse.setAllowlistEnforced(false);

        fundAndDeposit(alice, DEPOSIT);
        assertEq(getCollateralBalance(alice), DEPOSIT);
    }

    function test_StorageIsAppendedAfterExistingSlots() public {
        _enforce();

        bytes32 slot11 = vm.load(address(clearingHouse), bytes32(uint256(11)));
        assertEq(address(uint160(uint256(slot11))), manager);
        assertEq(uint256(slot11) >> 160, 1);

        _setAllowed(alice, true);
        bytes32 entry = keccak256(abi.encode(alice, uint256(12)));
        assertEq(uint256(vm.load(address(clearingHouse), entry)), 1);
    }

    // --- Listed traders ---

    function test_ListedTraderCanUseEveryFunction() public {
        _aliceTradingWhileEnforced();

        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, AMOUNT);
        clearingHouse.removeMargin(ETH_PERP, AMOUNT / 2);
        clearingHouse.closePosition(ETH_PERP, SIZE, 0);
        clearingHouse.withdraw(address(usdc), AMOUNT);
        vm.stopPrank();

        assertEq(getPosition(alice).size, 0);
        assertEq(usdc.balanceOf(alice), AMOUNT);
    }

    // --- Unlisted traders ---

    function test_UnlistedTraderIsBlockedFromEveryFunction() public {
        _enforce();
        fundUser(stranger, DEPOSIT);

        vm.startPrank(stranger);
        usdc.approve(address(vault), DEPOSIT);

        vm.expectRevert(ClearingHouse.TraderNotAllowed.selector);
        clearingHouse.deposit(address(usdc), AMOUNT);

        vm.expectRevert(ClearingHouse.TraderNotAllowed.selector);
        clearingHouse.withdraw(address(usdc), AMOUNT);

        vm.expectRevert(ClearingHouse.TraderNotAllowed.selector);
        clearingHouse.addMargin(ETH_PERP, AMOUNT);

        vm.expectRevert(ClearingHouse.TraderNotAllowed.selector);
        clearingHouse.removeMargin(ETH_PERP, AMOUNT);

        vm.expectRevert(ClearingHouse.TraderNotAllowed.selector);
        clearingHouse.openPosition(ETH_PERP, true, SIZE, 0);

        vm.expectRevert(ClearingHouse.TraderNotAllowed.selector);
        clearingHouse.closePosition(ETH_PERP, SIZE, 0);
        vm.stopPrank();
    }

    function test_RemovedTraderIsFrozenButKeepsBalanceAndPosition() public {
        _aliceTradingWhileEnforced();
        uint256 balanceBefore = getCollateralBalance(alice);
        int256 sizeBefore = getPosition(alice).size;

        _setAllowed(alice, false);

        vm.startPrank(alice);
        vm.expectRevert(ClearingHouse.TraderNotAllowed.selector);
        clearingHouse.closePosition(ETH_PERP, SIZE, 0);

        vm.expectRevert(ClearingHouse.TraderNotAllowed.selector);
        clearingHouse.withdraw(address(usdc), AMOUNT);
        vm.stopPrank();

        assertEq(getCollateralBalance(alice), balanceBefore);
        assertEq(getPosition(alice).size, sizeBefore);
    }

    function test_RestoredTraderCanExit() public {
        _aliceTradingWhileEnforced();
        _setAllowed(alice, false);
        _setAllowed(alice, true);

        vm.startPrank(alice);
        clearingHouse.closePosition(ETH_PERP, SIZE, 0);
        clearingHouse.withdraw(address(usdc), AMOUNT);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), AMOUNT);
    }

    // --- Protocol functions stay open ---

    function test_FundingCanBeSettledForRemovedTrader() public {
        _aliceTradingWhileEnforced();
        _setAllowed(alice, false);
        skipTime(1 hours);

        vm.prank(stranger);
        clearingHouse.settleFunding(ETH_PERP, alice);
    }

    function test_RemovedTraderCanStillBeLiquidated() public {
        _aliceTradingWhileEnforced();
        _setAllowed(alice, false);
        setOraclePrice(1_800 * PRICE_PRECISION);
        assertTrue(isLiquidatable(alice));

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, SIZE, 0);

        assertEq(getPosition(alice).size, 0);
    }

    function test_LiquidatorNeedsListingToWithdrawReward() public {
        _aliceTradingWhileEnforced();
        setOraclePrice(1_800 * PRICE_PRECISION);

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, SIZE, 0);
        uint256 reward = getCollateralBalance(liquidator);
        assertGt(reward, 0);

        vm.prank(liquidator);
        vm.expectRevert(ClearingHouse.TraderNotAllowed.selector);
        clearingHouse.withdraw(address(usdc), reward);

        _setAllowed(liquidator, true);
        vm.prank(liquidator);
        clearingHouse.withdraw(address(usdc), reward);

        assertEq(usdc.balanceOf(liquidator), reward);
    }

    // --- Management ---

    function test_ManagerCanUpdateABatch() public {
        address[] memory traders = new address[](2);
        traders[0] = alice;
        traders[1] = bob;

        vm.expectEmit(true, false, false, true, address(clearingHouse));
        emit IClearingHouse.TraderAllowlistUpdated(alice, true);
        vm.expectEmit(true, false, false, true, address(clearingHouse));
        emit IClearingHouse.TraderAllowlistUpdated(bob, true);
        vm.prank(manager);
        clearingHouse.setAllowedTraders(traders, true);

        assertTrue(clearingHouse.allowedTraders(alice));
        assertTrue(clearingHouse.allowedTraders(bob));
    }

    function test_OwnerCanManageWithoutAManager() public {
        vm.startPrank(admin);
        clearingHouse.setAllowlistManager(address(0));
        address[] memory traders = new address[](1);
        traders[0] = alice;
        clearingHouse.setAllowedTraders(traders, true);
        vm.stopPrank();

        assertTrue(clearingHouse.allowedTraders(alice));
    }

    function test_StrangerCannotManageAllowlist() public {
        address[] memory traders = new address[](1);
        traders[0] = stranger;

        vm.prank(stranger);
        vm.expectRevert(ClearingHouse.NotAllowlistManager.selector);
        clearingHouse.setAllowedTraders(traders, true);
    }

    function test_ClearedManagerAddressCannotBeImpersonated() public {
        vm.prank(admin);
        clearingHouse.setAllowlistManager(address(0));
        address[] memory traders = new address[](1);
        traders[0] = stranger;

        vm.prank(manager);
        vm.expectRevert(ClearingHouse.NotAllowlistManager.selector);
        clearingHouse.setAllowedTraders(traders, true);
    }

    function test_ManagerCannotChangeSwitchOrManager() public {
        vm.startPrank(manager);
        vm.expectRevert(ClearingHouse.NotAdmin.selector);
        clearingHouse.setAllowlistEnforced(true);

        vm.expectRevert(ClearingHouse.NotAdmin.selector);
        clearingHouse.setAllowlistManager(stranger);
        vm.stopPrank();
    }
}
