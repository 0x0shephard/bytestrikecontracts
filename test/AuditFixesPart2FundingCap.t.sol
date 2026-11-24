// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Finding 61: a position's funding is paid only from its own margin and the account's free
/// collateral, never from collateral that backs the account's other positions.
contract AuditFixesPart2FundingCapTest is BaseTest {
    bytes32 internal constant MARKET_B = keccak256("B-PERP");
    address internal carol;
    vAMM internal vammB;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("carol");

        vm.startPrank(admin);
        MockOracle oracleB = new MockOracle(2_000e18, 18);
        bytes memory init = abi.encodeCall(
            vAMM.initialize,
            (address(clearingHouse), address(oracleB), 2_000e18, INITIAL_BASE_RESERVE, LIQUIDITY_INDEX, 0, 100, 1e18)
        );
        vammB = vAMM(address(new ERC1967Proxy(address(new vAMM()), init)));
        vammB.setRegistry(address(marketRegistry));
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: MARKET_B,
                vamm: address(vammB),
                oracle: address(oracleB),
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: TRADE_FEE_BPS,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
        clearingHouse.setRiskParams(MARKET_B, IMR_BPS, MMR_BPS, LIQUIDATION_PENALTY_BPS, PENALTY_CAP, 0, 0);
        vm.stopPrank();
    }

    /// @dev Alice holds a long in each market and no free collateral. Her ETH long is in profit but
    /// pays funding beyond its margin; the B long pays nothing.
    function _payerBeyondItsMargin() internal {
        fundAndDeposit(alice, 10_000e18);
        fundAndDeposit(bob, 10_000e18);
        fundAndDeposit(carol, 100_000e18);
        vm.startPrank(alice);
        clearingHouse.openPosition(MARKET_B, true, 10e18, 0);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        vm.stopPrank();
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 1e18, 0);
        setOraclePrice(2_150e18); // index above alice's entry, below the mark: longs pay
        vm.prank(carol);
        clearingHouse.openPosition(ETH_PERP, true, 50e18, 0); // mark well above alice's entry

        uint256 free = getCollateralBalance(alice) - clearingHouse._totalReservedMargin(alice);
        vm.prank(alice);
        clearingHouse.withdraw(address(usdc), free);

        uint256 t = block.timestamp;
        for (uint256 i; i < 30; i++) {
            t += 1 hours;
            vm.warp(t);
            setOraclePrice(2_150e18);
            clearingHouse.settleFunding(ETH_PERP, carol);
        }
    }

    function test_Finding61_fundingAboveMarginIsCarriedAsDebt() public {
        _payerBeyondItsMargin();
        uint256 marginB = clearingHouse.getPosition(alice, MARKET_B).margin;

        // The view counts funding above the payer's margin plus free collateral as debt.
        assertTrue(isLiquidatable(alice), "payer not reported liquidatable");
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B long reported liquidatable");

        clearingHouse.settleFunding(ETH_PERP, alice);

        assertGt(clearingHouse.getPosition(alice, ETH_PERP).fundingDebt, 0, "no debt carried");
        assertEq(clearingHouse.getPosition(alice, ETH_PERP).margin, 0, "payer margin left");
        assertEq(clearingHouse.getPosition(alice, MARKET_B).margin, marginB, "B margin changed");
        assertGe(getCollateralBalance(alice), marginB, "B long lost its backing");
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B long liquidatable after settle");
        assertTrue(isLiquidatable(alice), "payer with debt not liquidatable");
    }

    /// @notice Liquidating the payer pays its debt from its own margin and free collateral only and
    /// leaves the B long backed.
    function test_Finding61_liquidatingPayerLeavesOtherPositionBacked() public {
        _payerBeyondItsMargin();
        uint256 marginB = clearingHouse.getPosition(alice, MARKET_B).margin;
        liquidateFully(alice, ETH_PERP, carol);

        assertEq(getPosition(alice).size, 0, "payer not liquidated");
        assertGe(getCollateralBalance(alice), marginB, "B long lost its backing");
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B long liquidatable");
    }
}
