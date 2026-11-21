// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Regression tests for realized losses beyond the trader's vault balance
/// (Cyfrin bytestrike part 2).
contract AuditFixesPart2BadDebtTest is BaseTest {
    bytes32 internal constant ZERO_FEE_PERP = keccak256("H100-ZERO-FEE-PERP");

    vAMM internal zfVamm;
    MockOracle internal zfIndex;

    address internal accountA;
    address internal accountB;
    address internal honest;

    function setUp() public override {
        super.setUp();
        accountA = makeAddr("accountA");
        accountB = makeAddr("accountB");
        honest = makeAddr("honest");

        // Zero-fee market with H100-like parameters: index 4.22, 10,000 base reserve, IMR 10%, MMR 5%.
        vm.startPrank(admin);
        zfIndex = new MockOracle(4.22e18, 18);
        bytes memory init = abi.encodeCall(
            vAMM.initialize, (address(clearingHouse), address(zfIndex), 4.22e18, 10_000e18, 1e24, 0, 100, 1e18)
        );
        zfVamm = vAMM(address(new ERC1967Proxy(address(new vAMM()), init)));
        zfVamm.setRegistry(address(marketRegistry));
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: ZERO_FEE_PERP,
                vamm: address(zfVamm),
                oracle: address(zfIndex),
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: 0,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
        clearingHouse.setRiskParams(ZERO_FEE_PERP, 1000, 500, 200, 10_000e18, 0, 0);
        vm.stopPrank();

        fundAndDeposit(honest, 10_000e18);
    }

    /// @dev Account A opens a long, then account B's large short pushes the mark far below the
    /// index, so A is not liquidatable at the index but closing realizes a loss above its balance.
    function _openPair() internal {
        fundAndDeposit(accountA, 242e18);
        vm.prank(accountA);
        clearingHouse.openPosition(ZERO_FEE_PERP, true, 500e18, 0);

        fundAndDeposit(accountB, 2_000e18);
        vm.prank(accountB);
        clearingHouse.openPosition(ZERO_FEE_PERP, false, 1_500e18, 0);

        assertFalse(clearingHouse.isLiquidatable(accountA, ZERO_FEE_PERP), "A healthy at index");
    }

    // ------------------------------------------------------------------
    // Finding 37
    // ------------------------------------------------------------------

    /// @notice Finding 37: on a zero-fee market a voluntary close whose realized loss exceeds the
    /// trader's vault balance reverts instead of writing the excess off as bad debt.
    function test_Finding37_zeroFeeCloseWithLossAboveBalanceReverts() public {
        _openPair();

        vm.prank(accountA);
        vm.expectRevert(ClearingHouse.InsufficientQuoteCollateral.selector);
        clearingHouse.closePosition(ZERO_FEE_PERP, 500e18, 0);

        assertEq(clearingHouse.totalBadDebt(), 0, "no bad debt written off");
    }

    /// @notice Finding 37: a tiny open on a zero-fee market reserves no margin and pays no fee, yet
    /// it is still checked against collateral, so it cannot add exposure while the quote collateral
    /// is worth less than the margin already reserved. (The original setup stacked margin through
    /// addMargin on a market without a position, which finding 17 / draft 42 now rejects.)
    function test_Finding37_zeroFeeTinyOpenCannotActivateStackedMargin() public {
        fundAndDeposit(alice, 1_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ZERO_FEE_PERP, true, 100e18, 0); // reserves ~42 of 1,000

        vm.prank(admin);
        oracle.setSymbolPrice("USDC", 0.03e18); // vault value 30 < reserved margin

        vm.prank(alice);
        vm.expectRevert(ClearingHouse.InsufficientQuoteCollateral.selector);
        clearingHouse.openPosition(ZERO_FEE_PERP, true, 2, 0);
    }

    /// @notice Finding 37: pure reductions on a zero-fee market are not blocked by the collateral
    /// check, so a trader can still de-risk when collateral value dips below reserved margin.
    function test_Finding37_zeroFeeReductionAllowedWhenCollateralBelowReserved() public {
        fundAndDeposit(alice, 1_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ZERO_FEE_PERP, true, 100e18, 0); // reserves ~42 of 1,000

        // Quote token valuation drops: vault value (1,000 * 0.03 = 30) is below reserved margin.
        vm.prank(admin);
        oracle.setSymbolPrice("USDC", 0.03e18);

        vm.prank(alice);
        clearingHouse.closePosition(ZERO_FEE_PERP, 100e18, 0);
        assertEq(clearingHouse.getPosition(alice, ZERO_FEE_PERP).size, 0, "closed");
    }
}
