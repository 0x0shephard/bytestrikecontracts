// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockERC20} from "../script/MockERC20.sol";

/// @title InsuranceFundTest
/// @notice Comprehensive tests for InsuranceFund
contract InsuranceFundTest is BaseTest {

    function setUp() public override {
        super.setUp();
    }

    // ============ Basic Functionality Tests ============

    function test_InitialState() public view {
        assertEq(insuranceFund.quoteToken(), address(usdc), "Quote token incorrect");
        assertEq(insuranceFund.clearinghouse(), address(clearingHouse), "Clearinghouse incorrect");
        assertTrue(insuranceFund.isAuthorized(address(clearingHouse)), "Clearinghouse should be authorized");
        assertTrue(insuranceFund.isRouter(address(feeRouter)), "FeeRouter should be authorized");
    }

    function test_GetBalance() public view {
        uint256 balance = insuranceFund.balance();
        assertEq(balance, 100000 * USDC_UNIT, "Initial balance incorrect"); // Set in BaseTest
    }

    function test_GetTotalReceived() public view {
        uint256 totalReceived = insuranceFund.totalReceived();
        assertEq(totalReceived, 0, "Initial total received should be 0");
    }

    function test_GetTotalPaid() public view {
        uint256 totalPaid = insuranceFund.totalPaid();
        assertEq(totalPaid, 0, "Initial total paid should be 0");
    }

    // ============ Fee Reception Tests ============

    function test_OnFeeReceived() public {
        uint256 feeAmount = 1000 * USDC_UNIT;

        // Simulate fee router with funds and approve InsuranceFund to pull
        usdc.mint(address(feeRouter), feeAmount);
        
        vm.prank(address(feeRouter));
        usdc.approve(address(insuranceFund), feeAmount);

        vm.prank(address(feeRouter));
        insuranceFund.onFeeReceived(feeAmount);

        assertEq(insuranceFund.totalReceived(), feeAmount, "Total received not updated");
    }

    function test_OnFeeReceived_Multiple() public {
        uint256 fee1 = 1000 * USDC_UNIT;
        uint256 fee2 = 500 * USDC_UNIT;
        uint256 fee3 = 750 * USDC_UNIT;
        uint256 totalFees = fee1 + fee2 + fee3;

        // Mint to feeRouter and approve all at once
        usdc.mint(address(feeRouter), totalFees);
        
        vm.prank(address(feeRouter));
        usdc.approve(address(insuranceFund), totalFees);

        vm.startPrank(address(feeRouter));
        insuranceFund.onFeeReceived(fee1);
        insuranceFund.onFeeReceived(fee2);
        insuranceFund.onFeeReceived(fee3);
        vm.stopPrank();

        assertEq(insuranceFund.totalReceived(), totalFees, "Total received incorrect");
    }

    function test_RevertWhen_OnFeeReceived_NotAuthorized() public {
        vm.expectRevert("IF: not router");
        vm.prank(alice);
        insuranceFund.onFeeReceived(1000 * USDC_UNIT);
    }

    function test_RevertWhen_OnFeeReceived_ZeroAmount() public {
        vm.expectRevert("IF: amount=0");
        vm.prank(address(feeRouter));
        insuranceFund.onFeeReceived(0);
    }

    // ============ Payout Tests ============

    function test_Payout() public {
        uint256 payoutAmount = 5000 * USDC_UNIT;

        uint256 balanceBefore = usdc.balanceOf(address(insuranceFund));
        uint256 bobBalanceBefore = usdc.balanceOf(bob);

        vm.prank(address(clearingHouse));
        insuranceFund.payout(bob, payoutAmount);

        assertEq(usdc.balanceOf(bob), bobBalanceBefore + payoutAmount, "Bob did not receive payout");
        assertEq(usdc.balanceOf(address(insuranceFund)), balanceBefore - payoutAmount, "Insurance fund balance incorrect");
        assertEq(insuranceFund.totalPaid(), payoutAmount, "Total paid not updated");
    }

    function test_Payout_Multiple() public {
        uint256 payout1 = 2000 * USDC_UNIT;
        uint256 payout2 = 3000 * USDC_UNIT;

        vm.startPrank(address(clearingHouse));
        insuranceFund.payout(bob, payout1);
        insuranceFund.payout(alice, payout2);
        vm.stopPrank();

        assertEq(insuranceFund.totalPaid(), payout1 + payout2, "Total paid incorrect");
    }

    function test_RevertWhen_Payout_NotAuthorized() public {
        vm.expectRevert("IF: not authorized");
        vm.prank(alice);
        insuranceFund.payout(bob, 5000 * USDC_UNIT);
    }

    function test_RevertWhen_Payout_ZeroAmount() public {
        vm.expectRevert("IF: amount=0");
        vm.prank(address(clearingHouse));
        insuranceFund.payout(bob, 0);
    }

    function test_RevertWhen_Payout_InsufficientBalance() public {
        uint256 totalBalance = usdc.balanceOf(address(insuranceFund));

        // ERC20 will revert with ERC20InsufficientBalance, not a custom error
        vm.expectRevert();
        vm.prank(address(clearingHouse));
        insuranceFund.payout(bob, totalBalance + 1);
    }

    // ============ Donation Tests ============

    function test_Donate() public {
        uint256 donationAmount = 10000 * USDC_UNIT;

        usdc.mint(alice, donationAmount);

        uint256 balanceBefore = insuranceFund.balance();
        uint256 totalReceivedBefore = insuranceFund.totalReceived();

        vm.startPrank(alice);
        // Approve InsuranceFund to pull tokens (donate uses safeTransferFrom)
        usdc.approve(address(insuranceFund), donationAmount);
        insuranceFund.donate(donationAmount);
        vm.stopPrank();

        assertEq(insuranceFund.balance(), balanceBefore + donationAmount, "Balance not increased");
        assertEq(insuranceFund.totalReceived(), totalReceivedBefore + donationAmount, "Total received not updated");
    }

    function test_Donate_MultipleDonors() public {
        uint256 aliceDonation = 5000 * USDC_UNIT;
        uint256 bobDonation = 7000 * USDC_UNIT;

        usdc.mint(alice, aliceDonation);
        usdc.mint(bob, bobDonation);

        vm.startPrank(alice);
        usdc.approve(address(insuranceFund), aliceDonation);
        insuranceFund.donate(aliceDonation);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(insuranceFund), bobDonation);
        insuranceFund.donate(bobDonation);
        vm.stopPrank();

        uint256 expectedTotal = 100000 * USDC_UNIT + aliceDonation + bobDonation; // Initial + donations
        assertEq(insuranceFund.balance(), expectedTotal, "Total balance incorrect");
    }

    function test_RevertWhen_Donate_ZeroAmount() public {
        vm.expectRevert("IF: amount=0");
        vm.prank(alice);
        insuranceFund.donate(0);
    }

    // ============ Authorization Tests ============

    function test_SetAuthorized() public {
        address newCaller = makeAddr("newCaller");

        vm.prank(admin);
        insuranceFund.setAuthorized(newCaller, true);

        assertTrue(insuranceFund.isAuthorized(newCaller), "Caller not authorized");
    }

    function test_RemoveAuthorized() public {
        vm.prank(admin);
        insuranceFund.setAuthorized(address(clearingHouse), false);

        assertFalse(insuranceFund.isAuthorized(address(clearingHouse)), "Caller still authorized");
    }

    function test_RevertWhen_SetAuthorized_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        insuranceFund.setAuthorized(makeAddr("newCaller"), true);
    }

    function test_SetFeeRouter() public {
        address newFeeRouter = makeAddr("newFeeRouter");

        vm.prank(admin);
        insuranceFund.setFeeRouter(newFeeRouter, true);

        assertTrue(insuranceFund.isRouter(newFeeRouter), "Fee router not authorized");
    }

    function test_RemoveFeeRouter() public {
        vm.prank(admin);
        insuranceFund.setFeeRouter(address(feeRouter), false);

        assertFalse(insuranceFund.isRouter(address(feeRouter)), "Fee router still authorized");
    }

    function test_RevertWhen_SetFeeRouter_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        insuranceFund.setFeeRouter(makeAddr("newFeeRouter"), true);
    }

    // ============ Rescue Token Tests ============

    function test_RescueToken() public {
        // Create a different token accidentally sent to the fund
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        uint256 rescueAmount = 10000 * 1e18;
        randomToken.mint(address(insuranceFund), rescueAmount);

        uint256 treasuryBefore = randomToken.balanceOf(treasury);

        vm.prank(admin);
        insuranceFund.rescueToken(address(randomToken), treasury, rescueAmount);

        assertEq(randomToken.balanceOf(treasury), treasuryBefore + rescueAmount, "Treasury did not receive rescued tokens");
    }

    function test_RevertWhen_RescueToken_NotOwner() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(address(insuranceFund), 10000 * 1e18);

        vm.expectRevert();
        vm.prank(alice);
        insuranceFund.rescueToken(address(randomToken), alice, 10000 * 1e18);
    }

    // ============ Integration Tests ============

    function test_FullCycle_FeeToPayoutToDonation() public {
        // 1. Receive fees via pull-pattern
        uint256 feeAmount = 5000 * USDC_UNIT;
        usdc.mint(address(feeRouter), feeAmount);
        vm.prank(address(feeRouter));
        usdc.approve(address(insuranceFund), feeAmount);
        
        vm.prank(address(feeRouter));
        insuranceFund.onFeeReceived(feeAmount);

        // 2. Payout for bad debt
        uint256 payoutAmount = 3000 * USDC_UNIT;
        vm.prank(address(clearingHouse));
        insuranceFund.payout(bob, payoutAmount);

        // 3. Receive donation
        uint256 donationAmount = 2000 * USDC_UNIT;
        usdc.mint(alice, donationAmount);
        vm.startPrank(alice);
        usdc.approve(address(insuranceFund), donationAmount);
        insuranceFund.donate(donationAmount);
        vm.stopPrank();

        // Verify accounting
        assertEq(insuranceFund.totalReceived(), feeAmount + donationAmount, "Total received incorrect");
        assertEq(insuranceFund.totalPaid(), payoutAmount, "Total paid incorrect");

        uint256 expectedBalance = 100000 * USDC_UNIT + feeAmount - payoutAmount + donationAmount;
        assertEq(insuranceFund.balance(), expectedBalance, "Final balance incorrect");
    }

    function test_CanHandleZeroBalance() public {
        // Drain all funds via payouts
        uint256 totalBalance = insuranceFund.balance();
        vm.prank(address(clearingHouse));
        insuranceFund.payout(treasury, totalBalance);

        assertEq(insuranceFund.balance(), 0, "Balance should be 0");

        // Receive new fees via pull-pattern
        uint256 newFee = 1000 * USDC_UNIT;
        usdc.mint(address(feeRouter), newFee);
        vm.prank(address(feeRouter));
        usdc.approve(address(insuranceFund), newFee);
        
        vm.prank(address(feeRouter));
        insuranceFund.onFeeReceived(newFee);

        assertEq(insuranceFund.balance(), newFee, "Balance incorrect after new fees");
    }

    function test_NetPosition() public {
        // Receive 10k in fees via pull-pattern
        usdc.mint(address(feeRouter), 10000 * USDC_UNIT);
        vm.prank(address(feeRouter));
        usdc.approve(address(insuranceFund), 10000 * USDC_UNIT);
        
        vm.prank(address(feeRouter));
        insuranceFund.onFeeReceived(10000 * USDC_UNIT);

        // Pay out 7k
        vm.prank(address(clearingHouse));
        insuranceFund.payout(bob, 7000 * USDC_UNIT);

        // Net position = initial (100k) + received (10k) - paid (7k) = 103k
        uint256 expectedBalance = 100000 * USDC_UNIT + 10000 * USDC_UNIT - 7000 * USDC_UNIT;
        assertEq(insuranceFund.balance(), expectedBalance, "Net position incorrect");
    }
}
