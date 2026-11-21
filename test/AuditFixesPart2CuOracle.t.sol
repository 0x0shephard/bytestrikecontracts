// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CuOracle} from "../src/Oracle/CuOracle.sol";

/// @notice Regression tests for the CuOracle publisher price bound (Cyfrin bytestrike part 2, finding 18).
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
}
