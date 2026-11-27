// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Finding 59: closePosition and addMargin while another position of the account is liquidatable.
contract AuditFixesPart2CloseGuardTest is BaseTest {
    bytes32 internal constant B_PERP = keccak256("B-PERP");
    MockOracle internal oracleB;
    vAMM internal vammB;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        oracleB = new MockOracle(INITIAL_ETH_PRICE, 18);
        vAMM impl = new vAMM();
        bytes memory initData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(clearingHouse),
            address(oracleB),
            INITIAL_ETH_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY_INDEX,
            VAMM_FEE_BPS,
            FUNDING_MAX_BPS_PER_HOUR,
            FUNDING_K
        );
        vammB = vAMM(address(new ERC1967Proxy(address(impl), initData)));
        vammB.setRegistry(address(marketRegistry));
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: B_PERP,
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
        clearingHouse.setRiskParams(
            B_PERP, IMR_BPS, MMR_BPS, LIQUIDATION_PENALTY_BPS, PENALTY_CAP, MAX_POSITION_SIZE, MIN_POSITION_SIZE
        );
        vm.stopPrank();

        // Alice: a 10 ETH long on ETH_PERP (A) and a 1 ETH long on B_PERP (B), with free collateral.
        fundAndDeposit(alice, 2_500e18);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        clearingHouse.openPosition(B_PERP, true, 1e18, 0);
        vm.stopPrank();

        // The ETH_PERP index falls 5%: A is below maintenance, B is untouched.
        oracle.setPrice(INITIAL_ETH_PRICE * 95 / 100);
        assertTrue(clearingHouse.isLiquidatable(alice, ETH_PERP));
        assertFalse(clearingHouse.isLiquidatable(alice, B_PERP));
    }

    /// @notice The close of a healthy position reverts while another position on its quote token is
    ///         liquidatable, so its loss cannot move the collateral the liquidation draws on.
    function test_Finding59_CloseBlockedWhileOtherPositionLiquidatable() public {
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.HasLiquidatablePosition.selector);
        clearingHouse.closePosition(B_PERP, 1e18, 0);
    }

    /// @notice Free collateral cannot be parked on the healthy position either.
    function test_Finding59_AddMarginOnlyToLiquidatablePosition() public {
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.HasLiquidatablePosition.selector);
        clearingHouse.addMargin(B_PERP, 10e18);

        // Curing the liquidatable position is allowed, after which B closes again.
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 800e18);
        assertFalse(clearingHouse.isLiquidatable(alice, ETH_PERP));
        vm.prank(alice);
        clearingHouse.closePosition(B_PERP, 1e18, 0);
        assertEq(clearingHouse.getPosition(alice, B_PERP).size, 0);
    }
}
