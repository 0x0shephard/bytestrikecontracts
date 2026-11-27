// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {MultiAssetOracle} from "../src/Oracle/MultiAssetOracle.sol";
import {UpdatableETHOracle} from "../src/Oracle/UpdatableETHOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

/// @notice Regression tests for two-step, non-renounceable ownership (Cyfrin bytestrike part 2, finding 29).
contract AuditFixesPart2OwnershipTest is BaseTest {
    address internal newOwner = makeAddr("newOwner");

    /// @notice ClearingHouse ownership moves only when the new owner accepts.
    function test_Finding29_clearingHouseTransferNeedsAcceptance() public {
        vm.prank(admin);
        clearingHouse.transferOwnership(newOwner);
        assertEq(clearingHouse.owner(), admin, "moved in one step");
        assertEq(clearingHouse.pendingOwner(), newOwner);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        clearingHouse.acceptOwnership();

        vm.prank(newOwner);
        clearingHouse.acceptOwnership();
        assertEq(clearingHouse.owner(), newOwner);
    }

    /// @notice No owner-held contract can be renounced.
    function test_Finding29_renounceDisabledEverywhere() public {
        vm.startPrank(admin);
        vm.expectRevert(ClearingHouse.RenounceOwnershipDisabled.selector);
        clearingHouse.renounceOwnership();
        vm.expectRevert(bytes("vAMM: renounce disabled"));
        vamm.renounceOwnership();
        vm.expectRevert(bytes("FR: renounce disabled"));
        feeRouter.renounceOwnership();
        vm.expectRevert(bytes("IF: renounce disabled"));
        insuranceFund.renounceOwnership();

        MultiAssetOracle mao = new MultiAssetOracle();
        vm.expectRevert(bytes("Oracle: renounce disabled"));
        mao.renounceOwnership();
        UpdatableETHOracle eth = new UpdatableETHOracle(2000e18);
        vm.expectRevert(bytes("Oracle: renounce disabled"));
        eth.renounceOwnership();
        vm.stopPrank();

        assertEq(clearingHouse.owner(), admin);
        assertEq(vamm.owner(), admin);
        assertEq(feeRouter.owner(), admin);
        assertEq(insuranceFund.owner(), admin);
    }

    /// @notice The price oracles hand ownership over in two steps; the old owner keeps writing prices
    /// until the new one accepts.
    function test_Finding29_priceOraclesTransferInTwoSteps() public {
        vm.startPrank(admin);
        MultiAssetOracle mao = new MultiAssetOracle();
        UpdatableETHOracle eth = new UpdatableETHOracle(2000e18);
        mao.transferOwnership(newOwner);
        eth.transferOwnership(newOwner);
        assertEq(mao.owner(), admin);
        assertEq(eth.owner(), admin);
        eth.updatePrice(2100e18);
        vm.stopPrank();

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        eth.updatePrice(2200e18);

        vm.startPrank(newOwner);
        mao.acceptOwnership();
        eth.acceptOwnership();
        eth.updatePrice(2200e18);
        vm.stopPrank();
        assertEq(mao.owner(), newOwner);
        assertEq(eth.getPrice(), 2200e18);
    }

    /// @notice MarketRegistry and CollateralVault keep a single default admin that moves only through
    /// a delayed two-step transfer; it cannot be granted or renounced in one call.
    function test_Finding29_defaultAdminMovesInTwoSteps() public {
        bytes32 role = marketRegistry.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        marketRegistry.grantRole(role, newOwner);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        vault.grantRole(role, newOwner);
        vm.expectRevert();
        marketRegistry.renounceRole(role, admin);
        vm.expectRevert();
        vault.renounceRole(role, admin);

        marketRegistry.beginDefaultAdminTransfer(newOwner);
        vault.beginDefaultAdminTransfer(newOwner);
        vm.stopPrank();

        // Not before the delay.
        vm.prank(newOwner);
        vm.expectRevert();
        marketRegistry.acceptDefaultAdminTransfer();

        vm.warp(block.timestamp + marketRegistry.INITIAL_DEFAULT_ADMIN_DELAY() + 1);
        vm.startPrank(newOwner);
        marketRegistry.acceptDefaultAdminTransfer();
        vault.acceptDefaultAdminTransfer();
        vm.stopPrank();
        assertEq(marketRegistry.defaultAdmin(), newOwner);
        assertEq(vault.defaultAdmin(), newOwner);
        assertFalse(marketRegistry.hasRole(role, admin), "old admin kept the role");
    }
}
