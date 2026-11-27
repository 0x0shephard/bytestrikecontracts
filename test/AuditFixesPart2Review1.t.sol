// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockERC20} from "../script/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IInsuranceFund} from "../src/Interfaces/IInsuranceFund.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

// The test quote token after it adopts a 1% transfer fee (burned), same storage layout as MockERC20
contract TransferFeeQuoteToken is MockERC20 {
    uint256 internal constant FEE_BPS = 100;

    constructor() MockERC20("USD Coin", "USDC", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value * FEE_BPS / 10_000;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice Regression for finding 1 (mitigation review): an insurance draw backs the bad debt only
/// with what the vault actually received, so a transfer fee on the payout stays recorded as bad debt.
contract AuditFixesPart2Review1Test is BaseTest {
    address internal carol;
    address internal restorer;

    uint128 internal constant ALICE_SIZE = 30e18;
    uint128 internal constant BOB_SIZE = 84e18;
    uint256 internal constant CAROL_DEPOSIT = 10_000e18;
    uint256 internal constant GAP_INDEX = 1_800e18;
    uint256 internal constant TOKEN_FEE_BPS = 100;
    uint256 internal constant DUST = 1e9;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("carol");
        restorer = makeAddr("restorer");
        fundAndDeposit(carol, CAROL_DEPOSIT);
        fundAndDeposit(restorer, 200_000e18);

        fundAndDeposit(alice, 5_200e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, ALICE_SIZE, 0);

        setOraclePrice(GAP_INDEX);
        fundAndDeposit(bob, 100_000e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, BOB_SIZE, 0);
    }

    function _sumBalances() internal view returns (uint256) {
        return getCollateralBalance(alice) + getCollateralBalance(bob) + getCollateralBalance(carol)
            + getCollateralBalance(liquidator) + getCollateralBalance(restorer)
            + getCollateralBalance(address(feeRouter)) + getCollateralBalance(address(clearingHouse));
    }

    function _deficit() internal view returns (int256) {
        return int256(_sumBalances()) - int256(usdc.balanceOf(address(vault)));
    }

    function _closeAll(address user) internal {
        int256 s = getPosition(user).size;
        if (s == 0) return;
        vm.prank(user);
        clearingHouse.closePosition(ETH_PERP, uint128(uint256(s > 0 ? s : -s)), 0);
    }

    function test_InsuranceDrawCountsOnlyWhatTheVaultReceived() public {
        assertTrue(isLiquidatable(alice));
        IClearingHouse.PositionView memory pos = getPosition(alice);
        assertGt((pos.entryPriceX18 - GAP_INDEX) * uint256(ALICE_SIZE) / 1e18, getCollateralBalance(alice));

        // the same liquidation without a transfer fee, for the bad debt it records
        uint256 badDebtBefore = clearingHouse.totalBadDebt();
        uint256 snap = vm.snapshotState();
        liquidateFully(alice, ETH_PERP, restorer);
        uint256 recordedWithoutFee = clearingHouse.totalBadDebt() - badDebtBefore;
        vm.revertToState(snap);

        TransferFeeQuoteToken withFee = new TransferFeeQuoteToken();
        vm.etch(address(usdc), address(withFee).code);

        int256 deficitBefore = _deficit();
        assertLe(deficitBefore, int256(DUST));

        vm.recordLogs();
        liquidateFully(alice, ETH_PERP, restorer);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(getPosition(alice).size, 0);

        uint256 paidToVault;
        uint256 feeOnPayouts;
        uint256 receivedByVault;
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 0) continue;
            if (
                l.emitter == address(insuranceFund) && l.topics[0] == IInsuranceFund.Payout.selector
                    && address(uint160(uint256(l.topics[1]))) == address(vault)
            ) {
                uint256 amount = abi.decode(l.data, (uint256));
                paidToVault += amount;
                feeOnPayouts += amount * TOKEN_FEE_BPS / 10_000;
            } else if (
                l.emitter == address(usdc) && l.topics[0] == IERC20.Transfer.selector
                    && address(uint160(uint256(l.topics[1]))) == address(insuranceFund)
                    && address(uint160(uint256(l.topics[2]))) == address(vault)
            ) {
                receivedByVault += abi.decode(l.data, (uint256));
            }
        }
        assertGt(paidToVault, 0);
        assertEq(paidToVault - receivedByVault, feeOnPayouts);
        assertGt(feeOnPayouts, DUST);

        // the part of the payouts the vault did not receive stays recorded as bad debt
        uint256 extraBadDebt = clearingHouse.totalBadDebt() - badDebtBefore - recordedWithoutFee;
        assertGe(extraBadDebt, feeOnPayouts);

        _closeAll(bob);
        _closeAll(restorer);

        // every token the vault is short of is accounted for in the recorded bad debt
        int256 deficitAfter = _deficit();
        assertLe(deficitAfter - deficitBefore, int256(extraBadDebt + DUST));
    }
}
