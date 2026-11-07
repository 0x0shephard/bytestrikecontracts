// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CuOracle} from "../src/Oracle/CuOracle.sol";
import {Oracle, Oracle_RenounceOwnershipDisabled} from "../src/Oracle/Oracle.sol";

contract KeyManagementCutoverTest is Test {
    CuOracle internal cuOracle;
    Oracle internal collateralOracle;

    address internal owner = address(0xA11CE);
    address internal publisher = address(0xB0B);
    address internal stranger = address(0xE0A);
    address internal multisig = address(0x5AFE);
    bytes32 internal assetId = keccak256("H100-GPU");
    uint256 internal price = 4e18;
    bytes32 internal nonce = keccak256("nonce");

    // Tracked here because via_ir can reuse an earlier block.timestamp within one test.
    uint256 internal currentTime = 1;

    function setUp() external {
        cuOracle = new CuOracle(owner, 1);
        collateralOracle = new Oracle();

        vm.startPrank(owner);
        cuOracle.registerAsset(assetId);
        cuOracle.grantRole(publisher);
        vm.stopPrank();
    }

    function _advanceTime() internal {
        currentTime += 2;
        vm.warp(currentTime);
    }

    function _commit(address caller, uint256 newPrice) internal {
        _advanceTime();
        vm.prank(caller);
        cuOracle.commitPrice(assetId, keccak256(abi.encodePacked(newPrice, nonce)));
        _advanceTime();
    }

    function _publish(address caller, uint256 newPrice) internal {
        _commit(caller, newPrice);
        vm.prank(caller);
        cuOracle.updatePrices(assetId, newPrice, nonce);
    }

    function _latestPrice() internal view returns (uint256) {
        return cuOracle.getLatestPrice(assetId).price;
    }

    // --- Publisher limits ---

    function testAllowedPublisherCanCommitAndRevealPrice() external {
        _publish(owner, price);
        _publish(publisher, 4.2e18);

        CuOracle.PriceData memory data = cuOracle.getLatestPrice(assetId);
        assertEq(data.price, 4.2e18);
        assertEq(data.lastUpdatedAt, currentTime - 2);
    }

    function testUnauthorizedAddressCannotRevealPrice() external {
        _commit(publisher, price);

        vm.prank(stranger);
        vm.expectRevert(CuOracle.OnlyAllowedRole.selector);
        cuOracle.updatePrices(assetId, price, nonce);
    }

    function testPublisherCanMoveExactlyToTheLimit() external {
        _publish(owner, price);

        _publish(publisher, 4.8e18);
        assertEq(_latestPrice(), 4.8e18);

        _publish(publisher, 3.84e18);
        assertEq(_latestPrice(), 3.84e18);
    }

    function testPublisherCannotMovePriceUpPastTheLimit() external {
        _publish(owner, price);
        uint256 tooHigh = 4.8e18 + 1;
        _commit(publisher, tooHigh);

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(CuOracle.PriceMoveTooLarge.selector, price, tooHigh));
        cuOracle.updatePrices(assetId, tooHigh, nonce);

        assertEq(_latestPrice(), price);
    }

    function testPublisherCannotMovePriceDownPastTheLimit() external {
        _publish(owner, price);
        uint256 tooLow = 3.2e18 - 1;
        _commit(publisher, tooLow);

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(CuOracle.PriceMoveTooLarge.selector, price, tooLow));
        cuOracle.updatePrices(assetId, tooLow, nonce);

        assertEq(_latestPrice(), price);
    }

    function testPublisherCannotSetFirstPrice() external {
        _commit(publisher, price);

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(CuOracle.PriceMoveTooLarge.selector, 0, price));
        cuOracle.updatePrices(assetId, price, nonce);
    }

    function testOwnerCanRevealPublisherCommitAfterItIsRejected() external {
        _publish(owner, price);
        uint256 largeMove = 8e18;
        _commit(publisher, largeMove);

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(CuOracle.PriceMoveTooLarge.selector, price, largeMove));
        cuOracle.updatePrices(assetId, largeMove, nonce);

        vm.prank(owner);
        cuOracle.updatePrices(assetId, largeMove, nonce);
        assertEq(_latestPrice(), largeMove);
    }

    function testOwnerCanUpdateTheLimit() external {
        _publish(owner, price);

        vm.prank(owner);
        cuOracle.updateMaxPriceMoveBps(5_000);

        _publish(publisher, 6e18);
        assertEq(_latestPrice(), 6e18);
    }

    function testStrangerCannotUpdateTheLimit() external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        cuOracle.updateMaxPriceMoveBps(10_000);
    }

    function testPublisherCannotUpdateTheLimit() external {
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, publisher));
        cuOracle.updateMaxPriceMoveBps(10_000);
    }

    function testInvalidLimitsAreRejected() external {
        vm.startPrank(owner);
        vm.expectRevert(CuOracle.InvalidPriceMoveLimit.selector);
        cuOracle.updateMaxPriceMoveBps(0);

        vm.expectRevert(CuOracle.InvalidPriceMoveLimit.selector);
        cuOracle.updateMaxPriceMoveBps(10_001);
        vm.stopPrank();
    }

    // --- CuOracle ownership ---

    // --- Pending commits are bound to their maker ---

    function _bareCommit(address caller, uint256 newPrice, bytes32 salt) internal {
        _advanceTime();
        vm.prank(caller);
        cuOracle.commitPrice(assetId, keccak256(abi.encodePacked(newPrice, salt)));
    }

    function testPublisherCannotOverwriteOwnersPendingCommit() external {
        _publish(owner, price);
        uint256 bigMove = price * 2;
        _bareCommit(owner, bigMove, nonce);
        assertEq(cuOracle.commitOwners(assetId), owner);

        _advanceTime();
        vm.prank(publisher);
        vm.expectRevert(CuOracle.CommitPendingFromAnotherPublisher.selector);
        cuOracle.commitPrice(assetId, keccak256(abi.encodePacked(price, keccak256("other"))));

        vm.prank(owner);
        cuOracle.updatePrices(assetId, bigMove, nonce);
        assertEq(_latestPrice(), bigMove);
        assertEq(cuOracle.commitOwners(assetId), address(0));
    }

    function testPublisherCannotOverwriteAnotherPublishersCommit() external {
        address publisher2 = address(0xB0B2);
        vm.prank(owner);
        cuOracle.grantRole(publisher2);
        _publish(owner, price);

        _bareCommit(publisher, price, nonce);
        _advanceTime();
        vm.prank(publisher2);
        vm.expectRevert(CuOracle.CommitPendingFromAnotherPublisher.selector);
        cuOracle.commitPrice(assetId, keccak256(abi.encodePacked(price, keccak256("other"))));
    }

    function testCommitterCanReplaceOwnCommit() external {
        _publish(owner, price);
        _bareCommit(publisher, price, keccak256("first"));
        _bareCommit(publisher, price, nonce);
        _advanceTime();

        vm.prank(publisher);
        cuOracle.updatePrices(assetId, price, nonce);
        assertEq(_latestPrice(), price);
    }

    function testOwnerCanReplacePublishersCommit() external {
        _publish(owner, price);
        _bareCommit(publisher, price, keccak256("publisher"));
        _bareCommit(owner, price * 3, nonce);
        assertEq(cuOracle.commitOwners(assetId), owner);
        _advanceTime();

        vm.prank(owner);
        cuOracle.updatePrices(assetId, price * 3, nonce);
        assertEq(_latestPrice(), price * 3);
    }

    function testExpiredCommitCanBeReplacedByAnotherPublisher() external {
        _publish(owner, price);
        _bareCommit(owner, price * 2, keccak256("stale"));

        currentTime += 1 hours + 1;
        vm.warp(currentTime);
        vm.prank(publisher);
        cuOracle.commitPrice(assetId, keccak256(abi.encodePacked(price, nonce)));
        assertEq(cuOracle.commitOwners(assetId), publisher);
    }

    function testRemovingAssetClearsCommitOwner() external {
        _publish(owner, price);
        _bareCommit(publisher, price, nonce);
        vm.prank(owner);
        cuOracle.removeAsset(assetId);
        assertEq(cuOracle.commitOwners(assetId), address(0));
    }

    function testCuOracleOwnershipNeedsAcceptance() external {
        vm.prank(owner);
        cuOracle.transferOwnership(multisig);

        assertEq(cuOracle.owner(), owner);
        assertEq(cuOracle.pendingOwner(), multisig);

        vm.prank(multisig);
        cuOracle.acceptOwnership();

        assertEq(cuOracle.owner(), multisig);
        assertEq(cuOracle.pendingOwner(), address(0));
    }

    function testCuOracleOwnershipRejectsWrongAcceptor() external {
        vm.prank(owner);
        cuOracle.transferOwnership(multisig);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        cuOracle.acceptOwnership();

        assertEq(cuOracle.owner(), owner);
    }

    function testCuOracleMistakenTransferCanBeCorrected() external {
        vm.startPrank(owner);
        cuOracle.transferOwnership(stranger);
        cuOracle.transferOwnership(multisig);
        vm.stopPrank();

        assertEq(cuOracle.pendingOwner(), multisig);
    }

    function testCuOracleCannotBeRenounced() external {
        vm.prank(owner);
        vm.expectRevert(CuOracle.RenounceOwnershipDisabled.selector);
        cuOracle.renounceOwnership();

        assertEq(cuOracle.owner(), owner);
    }

    // --- Collateral Oracle ownership ---

    function testCollateralOracleOwnershipNeedsAcceptance() external {
        collateralOracle.transferOwnership(multisig);

        assertEq(collateralOracle.owner(), address(this));
        assertEq(collateralOracle.pendingOwner(), multisig);

        vm.prank(multisig);
        collateralOracle.acceptOwnership();

        assertEq(collateralOracle.owner(), multisig);
    }

    function testCollateralOracleOwnershipRejectsWrongAcceptor() external {
        collateralOracle.transferOwnership(multisig);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        collateralOracle.acceptOwnership();

        assertEq(collateralOracle.owner(), address(this));
    }

    function testCollateralOracleTransferToZeroKeepsCurrentOwner() external {
        collateralOracle.transferOwnership(address(0));

        assertEq(collateralOracle.owner(), address(this));
    }

    function testCollateralOracleCannotBeRenounced() external {
        vm.expectRevert(Oracle_RenounceOwnershipDisabled.selector);
        collateralOracle.renounceOwnership();

        assertEq(collateralOracle.owner(), address(this));
    }
}
