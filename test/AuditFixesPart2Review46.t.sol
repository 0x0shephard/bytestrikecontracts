// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";

/// @notice Regression for finding 46 (mitigation review): a short increase at an unchanged index
/// with no funding paid must not revert IMRBreach because of the averaged entry's rounding.
contract AuditFixesPart2Review46Test is BaseTest {
    // a non-round index, held unchanged for the whole test
    uint256 internal constant INDEX = 2_000_123_456_789_123_456_789;

    function setUp() public override {
        super.setUp();
        fundAndDeposit(alice, 1_000_000 * USDC_UNIT);
        setOraclePrice(INDEX);
    }

    function test_ShortIncreaseAtUnchangedIndexPassesDespiteEntryRounding() public {
        uint128[6] memory opens = [
            uint128(23_456_789_012_345_678_901),
            31_415_926_535_897_932_384,
            47_123_456_789_987_654_321,
            29_876_543_210_123_456_789,
            52_718_281_828_459_045_235,
            38_461_538_461_538_461_538
        ];
        uint128[6] memory adds = [
            uint128(7_654_321_098_765_432_109),
            11_235_813_213_455_891_442,
            13_579_246_813_579_246_813,
            19_283_746_501_928_374_650,
            9_876_543_219_876_543_219,
            15_384_615_384_615_384_615
        ];

        for (uint256 i = 0; i < opens.length; i++) {
            uint256 snap = vm.snapshotState();

            vm.prank(alice);
            clearingHouse.openPosition(ETH_PERP, false, opens[i], 0);
            assertLt(getMarkPrice(), INDEX);

            uint256 free = getCollateralBalance(alice) - clearingHouse._totalReservedMargin(alice);
            assertGt(free, 900_000 * USDC_UNIT);

            // same block, same index, no funding paid: the add goes through without extra margin
            vm.prank(alice);
            clearingHouse.openPosition(ETH_PERP, false, adds[i], 0);
            assertEq(getPosition(alice).size, -int256(uint256(opens[i]) + uint256(adds[i])));

            vm.revertToState(snap);
        }
    }
}
