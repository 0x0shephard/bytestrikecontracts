// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {IFeeRouter} from "../src/Interfaces/IFeeRouter.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

/// @notice Regression for finding 4 (third mitigation review): the protocol's penalty share a capped
/// liquidation call keeps owed stays backed by the account's free collateral. A later call's penalty
/// does not spend it, addMargin cannot move it into the position, and it is collected in full when
/// the episode ends with size still open.
contract AuditFixesPart2Review4cTest is BaseTest {
    address internal restorer;

    uint256 internal constant CAP = 1_000e18;
    uint128 internal constant ALICE_SIZE = 50e18;
    uint256 internal constant INDEX = 1_920e18;
    /// @dev Free collateral alice keeps next to her long before the index falls.
    uint256 internal constant SPARE = 300e18;

    function setUp() public override {
        super.setUp();
        restorer = makeAddr("restorer");
        vm.prank(admin);
        clearingHouse.setRiskParams(
            ETH_PERP, IMR_BPS, MMR_BPS, LIQUIDATION_PENALTY_BPS, CAP, MAX_POSITION_SIZE, MIN_POSITION_SIZE
        );
        fundAndDeposit(restorer, 300_000e18);
        fundAndDeposit(bob, 200_000e18);

        // alice opens a 50 ETH long and keeps SPARE of free collateral next to it
        fundAndDeposit(alice, 16_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, ALICE_SIZE, 0);
        uint256 excess = _free() - SPARE;
        vm.prank(alice);
        clearingHouse.withdraw(address(usdc), excess);
        assertEq(_free(), SPARE);

        // the index falls and bob's short brings the mark to it
        setOraclePrice(INDEX);
        (uint256 x, uint256 y) = getReserves();
        uint256 xTarget = _sqrtBase((x * y / INDEX) * 1e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, uint128(xTarget - x), 0);
        assertTrue(isLiquidatable(alice), "not liquidatable");

        // wallet USDC for depositMargin
        fundUser(alice, 10_000e18);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Value of alice's vault balance above her reserved margin (USDC at par, no haircut).
    function _free() internal view returns (uint256) {
        uint256 bal = vault.balanceOf(alice, address(usdc));
        uint256 reserved = clearingHouse._totalReservedMargin(alice);
        return bal > reserved ? bal - reserved : 0;
    }

    /// @dev One liquidation call for the whole position.
    function _liquidateOnce() internal {
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, ALICE_SIZE, 0);
    }

    /// @dev Trades the mark back to the index with the market fee at 0, as an arbitrageur would.
    function _restoreMark() internal {
        (uint256 x, uint256 y) = getReserves();
        uint256 xTarget = _sqrtBase((x * y / oracle.getPrice()) * 1e18);
        IMarketRegistry.Market memory m = marketRegistry.getMarket(ETH_PERP);
        _setMarketFee(ETH_PERP, m, 0);
        vm.prank(restorer);
        clearingHouse.openPosition(ETH_PERP, xTarget < x, uint128(xTarget < x ? x - xTarget : xTarget - x), 0);
        _setMarketFee(ETH_PERP, m, m.feeBps);
    }

    /// @dev Sum of liquidation penalties the fee router received in `logs`.
    function _routed(Vm.Log[] memory logs) internal view returns (uint256 total) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(feeRouter) && logs[i].topics[0] == IFeeRouter.LiquidationPenaltyRouted.selector) {
                (uint256 amount,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                total += amount;
            }
        }
    }

    function test_LaterPenaltyDoesNotSpendOwedShare() public {
        _liquidateOnce();
        uint256 owed = getPosition(alice).liquidationPenaltyOwed;
        assertGt(owed, 0, "nothing owed");
        assertTrue(isLiquidatable(alice), "healthy after one call");

        // the next capped call's penalty is cut from the remaining margin, not from the owed share
        _restoreMark();
        int256 size = getPosition(alice).size;
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, uint128(uint256(size)), 0);
        assertNotEq(getPosition(alice).size, 0, "closed");
        owed = getPosition(alice).liquidationPenaltyOwed;
        assertGe(_free(), owed, "owed shares spent by a later penalty");
    }

    function test_AddMarginCannotMoveOwedShare() public {
        _liquidateOnce();
        uint256 owed = getPosition(alice).liquidationPenaltyOwed;
        uint256 free = _free();
        assertGt(owed, 0, "nothing owed");
        assertGt(free, owed, "owed share not in free collateral");
        assertTrue(isLiquidatable(alice), "healthy after one call");

        // the owed share cannot be moved into the position
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.InsufficientQuoteBalance.selector);
        clearingHouse.addMargin(ETH_PERP, free);

        // the free collateral above it can
        uint256 allowed = free - owed;
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, allowed);
        assertEq(_free(), owed, "owed share moved");
    }

    function test_MinimalCureCollectsOwedShareInFull() public {
        _liquidateOnce();
        uint256 owed = getPosition(alice).liquidationPenaltyOwed;
        uint256 free = _free();
        assertGt(free, owed, "owed share not in free collateral");

        // alice moves every free unit she can into the position (all of it if allowed, else all but
        // the owed share), then cures it with the smallest depositMargin top-up (in 10 USDC steps)
        vm.prank(alice);
        try clearingHouse.addMargin(ETH_PERP, free) {}
        catch {
            uint256 allowed = free - owed;
            vm.prank(alice);
            clearingHouse.addMargin(ETH_PERP, allowed);
        }
        uint256 badDebtBefore = clearingHouse.totalBadDebt();
        bool cured;
        Vm.Log[] memory logs;
        for (uint256 amount = 10e18; amount <= 5_000e18; amount += 10e18) {
            uint256 snap = vm.snapshotState();
            vm.recordLogs();
            vm.prank(alice);
            try clearingHouse.depositMargin(ETH_PERP, amount) {
                if (!isLiquidatable(alice)) {
                    cured = true;
                    logs = vm.getRecordedLogs();
                    break;
                }
            } catch {}
            vm.revertToState(snap);
        }
        assertTrue(cured, "no top-up cured the position");
        assertNotEq(getPosition(alice).size, 0, "closed");

        // the episode ended with size open just above maintenance: the owed share was collected in full
        assertEq(getPosition(alice).liquidationPenaltyOwed, 0, "owed share left");
        assertEq(clearingHouse.totalBadDebt(), badDebtBefore, "owed share recorded as bad debt");
        assertEq(_routed(logs), owed, "owed share not routed");
    }
}
