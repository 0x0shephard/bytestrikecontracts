// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./BaseTest.sol";

/// @notice Regression tests for the realized PnL and funding token conversion (Cyfrin bytestrike part 2).
contract AuditFixesPart2PnLConversionTest is BaseTest {
    bytes32 internal constant PNL_SETTLED = keccak256("PnLSettled(address,address,int256)");
    bytes32 internal constant FUNDING_SETTLED = keccak256("FundingSettled(bytes32,address,int256)");

    address internal carol;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("carol");
        fundAndDeposit(alice, 200_000e18);
        fundAndDeposit(bob, 200_000e18);
    }

    /// @dev User balances minus tokens held by the vault; positive means unbacked balances.
    function _gap() internal view returns (int256) {
        uint256 owed = getCollateralBalance(alice) + getCollateralBalance(bob);
        return int256(owed) - int256(usdc.balanceOf(address(vault)));
    }

    /// @dev Sum of PnLSettled amounts credited/debited to `user` in the recorded logs.
    function _pnlSettled(Vm.Log[] memory logs, address user) internal view returns (int256 total) {
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(vault) && logs[i].topics[0] == PNL_SETTLED
                    && logs[i].topics[1] == bytes32(uint256(uint160(user)))
            ) {
                total += abi.decode(logs[i].data, (int256));
            }
        }
    }

    function _fundingSettled(Vm.Log[] memory logs, address user) internal view returns (int256 total) {
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(clearingHouse) && logs[i].topics[0] == FUNDING_SETTLED
                    && logs[i].topics[2] == bytes32(uint256(uint160(user)))
            ) {
                total += abi.decode(logs[i].data, (int256));
            }
        }
    }

    /// @notice Finding 7: the loss and gain of one exchange settled at different USDC/USD
    /// answers must not leave user balances above the vault's token holdings.
    function test_Finding7_pnlLegsAtDifferentQuotePricesStayBacked() public {
        assertEq(_gap(), 0, "vault starts fully backed");
        openLongPosition(alice, ethQty(20), 0);
        openShortPosition(bob, ethQty(20), 0);

        closePosition(alice, ethQty(20), 0); // loser settles at 1.00
        vm.prank(admin);
        oracle.setSymbolPrice("USDC", 0.9e18);
        closePosition(bob, ethQty(20), 0); // winner settles at 0.90

        assertLe(_gap(), 0, "balances exceed vault tokens");
        assertEq(clearingHouse.totalBadDebt(), 0, "no bad debt");
    }

    /// @notice Finding 7: realized profit is credited at one quote token per 1e18 of quote value,
    /// whatever the live USDC/USD answer.
    function test_Finding7_realizedProfitCreditedAtFixedRate() public {
        openLongPosition(alice, ethQty(20), 0);
        openShortPosition(bob, ethQty(20), 0);
        closePosition(alice, ethQty(20), 0);

        vm.prank(admin);
        oracle.setSymbolPrice("USDC", 0.9e18);
        int256 realizedBefore = getPosition(bob).realizedPnL;
        vm.recordLogs();
        closePosition(bob, ethQty(20), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        int256 realized = getPosition(bob).realizedPnL - realizedBefore;

        assertGt(realized, 0, "bob realized a profit");
        // baseUnit is 1e18 for the test token: tokens == realized quote value
        assertEq(_pnlSettled(logs, bob), realized, "profit converted at fixed rate");
    }

    /// @notice Finding 7: funding is converted at the fixed rate too, so payer debit and receiver
    /// credit settled at different USDC/USD answers net in tokens.
    function test_Finding7_fundingConvertedAtFixedRate() public {
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 10e18, 0);

        uint256 t = block.timestamp;
        for (uint256 i; i < 5; i++) {
            t += 3600;
            vm.warp(t);
            setOraclePrice(1_900e18); // index below mark: longs pay, shorts receive
            settleFunding(carol);
        }

        vm.recordLogs();
        settleFunding(alice); // payer at 1.00
        Vm.Log[] memory payLogs = vm.getRecordedLogs();

        vm.prank(admin);
        oracle.setSymbolPrice("USDC", 0.9e18);
        vm.recordLogs();
        settleFunding(bob); // receiver at 0.90
        Vm.Log[] memory recvLogs = vm.getRecordedLogs();

        int256 paid = _fundingSettled(payLogs, alice);
        int256 received = _fundingSettled(recvLogs, bob);
        assertLt(paid, 0, "alice paid funding");
        assertGt(received, 0, "bob received funding");
        assertEq(_pnlSettled(payLogs, alice), paid, "payer debit at fixed rate");
        assertEq(_pnlSettled(recvLogs, bob), received, "receiver credit at fixed rate");
        assertLe(_gap(), 0, "balances exceed vault tokens");
    }
}
