// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CuOracle} from "../src/Oracle/CuOracle.sol";

/// @notice Regression tests for CuOracle publishers (Cyfrin bytestrike part 2, findings 18 and 22).
contract AuditFixesPart2CuOracleTest is Test {
    bytes32 internal constant ASSET = keccak256("H100");
    address internal owner = makeAddr("owner");
    address internal publisher = makeAddr("publisher");
    CuOracle internal cu;
    uint256 internal ts = 1_000_000;
    uint256 internal nonceSeq;

    function setUp() public {
        vm.warp(ts);
        cu = new CuOracle(owner, 1);
        vm.startPrank(owner);
        cu.registerAsset(ASSET);
        cu.grantRole(publisher);
        vm.stopPrank();
        _reveal(owner, 100e18);
    }

    function _commit(address who, uint256 price) internal returns (bytes32 nonce) {
        nonce = bytes32(++nonceSeq);
        ts += 2;
        vm.warp(ts);
        vm.prank(who);
        cu.commitPrice(ASSET, keccak256(abi.encodePacked(price, nonce)));
        ts += 1;
        vm.warp(ts);
    }

    function _reveal(address who, uint256 price) internal {
        bytes32 nonce = _commit(who, price);
        vm.prank(who);
        cu.updatePrices(ASSET, price, nonce);
    }

    function test_Finding18_defaultMoveBoundIsTight() public view {
        assertEq(cu.maxPriceMoveBps(), 300, "default publisher bound is 3%");
        assertEq(cu.ownerAnchorPrices(ASSET), 100e18, "owner reveal sets the anchor");
    }

    /// @notice Finding 18: chained publisher reveals, each within the per-reveal bound, cannot walk
    /// the price beyond maxPriceMoveBps of the owner's last price.
    function test_Finding18_chainedPublisherRevealsCannotCompound() public {
        _reveal(publisher, 102.9e18); // 2.9% from both the last price and the anchor

        bytes32 nonce = _commit(publisher, 105.5e18); // 2.5% from the last price, 5.5% from the anchor
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(CuOracle.PriceMoveTooLarge.selector, 100e18, 105.5e18));
        cu.updatePrices(ASSET, 105.5e18, nonce);
        assertEq(cu.getLatestPrice(ASSET).price, 102.9e18);
    }

    /// @notice Finding 18: an owner reveal re-centres the anchor, so publishers can follow a trend the
    /// owner has confirmed.
    function test_Finding18_ownerRevealRecentresAnchor() public {
        _reveal(owner, 105.5e18);
        _reveal(publisher, 108e18);
        assertEq(cu.getLatestPrice(ASSET).price, 108e18);
        assertEq(cu.ownerAnchorPrices(ASSET), 105.5e18);
    }

    /// @notice Finding 18: removing an asset clears its anchor, so publishers need a fresh owner price.
    function test_Finding18_removeAssetClearsAnchor() public {
        vm.startPrank(owner);
        cu.removeAsset(ASSET);
        cu.registerAsset(ASSET);
        vm.stopPrank();
        assertEq(cu.ownerAnchorPrices(ASSET), 0);
    }

    function _commitOnly(address who, uint256 price) internal {
        vm.prank(who);
        cu.commitPrice(ASSET, keccak256(abi.encodePacked(price, bytes32(++nonceSeq))));
    }

    /// @notice Finding 22: a publisher renewing its own live commit cannot hold the slot past
    /// maxCommitAge from its first commit; another publisher can then commit.
    function test_Finding22_renewalsDoNotExtendPublisherSlot() public {
        address other = makeAddr("other");
        vm.prank(owner);
        cu.grantRole(other);

        ts += 10;
        vm.warp(ts);
        _commitOnly(publisher, 101e18);
        uint256 firstCommit = ts;

        // The publisher renews twice, each time before its latest commit would expire.
        uint256[2] memory renewals = [uint256(30 minutes), 55 minutes];
        for (uint256 i; i < 2; i++) {
            ts = firstCommit + renewals[i];
            vm.warp(ts);
            vm.prank(other);
            vm.expectRevert(CuOracle.CommitPendingFromAnotherPublisher.selector);
            cu.commitPrice(ASSET, keccak256("x"));
            _commitOnly(publisher, 101e18);
        }

        // Past maxCommitAge from the first commit the slot is open to the other publisher, even though
        // the latest renewal is only 6 minutes old.
        ts = firstCommit + cu.maxCommitAge() + 1;
        vm.warp(ts);
        _commitOnly(other, 101e18);
        assertEq(cu.commitOwners(ASSET), other);
    }

    /// @notice Finding 22: revoking a publisher removes its live commit's slot protection.
    function test_Finding22_revokedPublisherCommitIsReplaceable() public {
        address other = makeAddr("other");
        vm.prank(owner);
        cu.grantRole(other);

        ts += 10;
        vm.warp(ts);
        _commitOnly(publisher, 101e18);

        vm.prank(owner);
        cu.revokeRole(publisher);

        ts += 10;
        vm.warp(ts);
        _commitOnly(other, 101e18);
        assertEq(cu.commitOwners(ASSET), other);
    }

    /// @notice Finding 22: a publisher's renewed commit still reveals after the usual commit-reveal
    /// delay, and the reveal clears the slot.
    function test_Finding22_renewedCommitRevealsNormally() public {
        ts += 10;
        vm.warp(ts);
        _commitOnly(publisher, 101e18);
        ts += 30 minutes;
        vm.warp(ts);
        bytes32 nonce = bytes32(++nonceSeq);
        vm.prank(publisher);
        cu.commitPrice(ASSET, keccak256(abi.encodePacked(uint256(101e18), nonce)));
        ts += 1;
        vm.warp(ts);
        vm.prank(publisher);
        cu.updatePrices(ASSET, 101e18, nonce);
        assertEq(cu.getLatestPrice(ASSET).price, 101e18);
        assertEq(cu.slotTimestamps(ASSET), 0, "slot cleared on reveal");
    }
}
