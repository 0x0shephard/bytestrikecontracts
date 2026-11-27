// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CuOracle} from "../src/Oracle/CuOracle.sol";

/// @notice Finding 18 follow-up: only a commitment's maker (or the owner) can reveal it, and the owner anchor
/// moves on the owner's commitments only, so a publisher cannot consume the owner's re-centring reveal.
contract AuditFixesPart2Review18Test is Test {
    bytes32 internal constant ASSET = keccak256("H100");
    address internal owner = makeAddr("owner");
    address internal publisher = makeAddr("publisher");
    address internal publisher2 = makeAddr("publisher2");
    CuOracle internal cu;
    uint256 internal nonceSeq;

    function setUp() public {
        vm.warp(1_000_000);
        cu = new CuOracle(owner, 1);
        vm.startPrank(owner);
        cu.registerAsset(ASSET);
        cu.grantRole(publisher);
        cu.grantRole(publisher2);
        vm.stopPrank();

        // The owner sets the first price, which is also its anchor
        _commitAndReveal(owner, 100e18);
    }

    function _commit(address who, uint256 price) internal returns (bytes32 nonce) {
        nonce = bytes32(++nonceSeq);
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.prank(who);
        cu.commitPrice(ASSET, keccak256(abi.encodePacked(price, nonce)));
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _commitAndReveal(address who, uint256 price) internal {
        bytes32 nonce = _commit(who, price);
        vm.prank(who);
        cu.updatePrices(ASSET, price, nonce);
    }

    function _price() internal view returns (uint256) {
        return cu.getLatestPrice(ASSET).price;
    }

    function test_PublisherCannotRevealOwnerCommitment() public {
        // The owner commits a 3% lower price to re-centre the publisher band
        bytes32 ownerNonce = _commit(owner, 97e18);

        // A publisher holding the owner's nonce can no longer reveal the owner's commitment
        vm.prank(publisher);
        vm.expectRevert(CuOracle.NotCommitOwner.selector);
        cu.updatePrices(ASSET, 97e18, ownerNonce);
        assertEq(_price(), 100e18, "owner price published by publisher");

        // The owner's own reveal still goes through and re-centres the anchor
        vm.prank(owner);
        cu.updatePrices(ASSET, 97e18, ownerNonce);
        assertEq(_price(), 97e18, "owner price not published");
        assertEq(cu.ownerAnchorPrices(ASSET), 97e18, "owner reveal did not re-centre");

        // The band now follows the owner's price, so the publisher cannot climb to 102.9
        _commitAndReveal(publisher, 99.91e18);
        bytes32 n = _commit(publisher, 102.9e18);
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(CuOracle.PriceMoveTooLarge.selector, 97e18, 102.9e18));
        cu.updatePrices(ASSET, 102.9e18, n);
    }

    function test_PublisherCannotRevealAnotherPublishersCommitment() public {
        bytes32 n = _commit(publisher, 101e18);

        vm.prank(publisher2);
        vm.expectRevert(CuOracle.NotCommitOwner.selector);
        cu.updatePrices(ASSET, 101e18, n);

        vm.prank(publisher);
        cu.updatePrices(ASSET, 101e18, n);
        assertEq(_price(), 101e18, "maker reveal failed");
    }

    function test_PublisherRevealNeverMovesAnchor() public {
        // A publisher's own in-band reveal publishes but leaves the owner's anchor where it was
        _commitAndReveal(publisher, 102e18);
        assertEq(_price(), 102e18, "publisher reveal failed");
        assertEq(cu.ownerAnchorPrices(ASSET), 100e18, "publisher reveal moved the anchor");
    }
}
