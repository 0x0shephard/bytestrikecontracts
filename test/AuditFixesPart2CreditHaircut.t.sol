// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";

/// @notice Finding 49: funding credits are reserved at the haircut value of the tokens credited.
contract AuditFixesPart2CreditHaircutTest is BaseTest {
    uint16 internal constant HAIRCUT_BPS = 100;
    address internal carol;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("carol");
        vm.startPrank(admin);
        ICollateralVault.CollateralConfig memory cfg = vault.getConfig(address(usdc));
        cfg.haircutBps = HAIRCUT_BPS;
        vault.setCollateralParams(address(usdc), cfg);
        vm.stopPrank();
    }

    function _valueOf(address user) internal view returns (uint256) {
        return vault.getTokenValueX18(address(usdc), getCollateralBalance(user));
    }

    /// @dev Alice holds a short that receives funding and withdraws all free collateral.
    function _receivingShortFullyAllocated() internal {
        fundAndDeposit(alice, 10_000e18);
        fundAndDeposit(carol, 100_000e18);
        vm.prank(carol);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, false, 5e18, 0);
        setOraclePrice(1_960e18); // mark above index: longs pay, shorts receive

        uint256 reserved = clearingHouse._totalReservedMargin(alice);
        uint256 keep = (reserved * 10_000 + 9_899) / (10_000 - HAIRCUT_BPS);
        uint256 free = getCollateralBalance(alice) - keep;
        vm.prank(alice);
        clearingHouse.withdraw(address(usdc), free);

        uint256 t = block.timestamp;
        for (uint256 i; i < 24; i++) {
            t += 1 hours;
            vm.warp(t);
            setOraclePrice(1_960e18);
            clearingHouse.settleFunding(ETH_PERP, carol);
        }
    }

    /// @notice After a funding credit, the balance value still covers the reserved margin.
    function test_Finding49_fundingCreditKeepsReservedMarginBacked() public {
        _receivingShortFullyAllocated();
        uint256 marginBefore = getPosition(alice).margin;
        clearingHouse.settleFunding(ETH_PERP, alice);
        assertGt(getPosition(alice).margin, marginBefore, "no funding credited");

        assertGe(_valueOf(alice), clearingHouse._totalReservedMargin(alice), "credit reserved above its value");
    }

    /// @notice addMargin reverts with InsufficientQuoteBalance (not a panic) without free value.
    function test_Finding49_addMarginWithoutFreeValueReverts() public {
        _receivingShortFullyAllocated();
        clearingHouse.settleFunding(ETH_PERP, alice);
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.InsufficientQuoteBalance.selector);
        clearingHouse.addMargin(ETH_PERP, 1e18);
    }
}
