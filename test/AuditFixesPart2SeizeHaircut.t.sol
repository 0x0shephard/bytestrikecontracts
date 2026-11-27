// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Finding 20: liquidation seizure treats as free only the share of the balance whose haircut
/// value exceeds the reserved margin, so it never leaves the account's other positions unbacked.
contract AuditFixesPart2SeizeHaircutTest is BaseTest {
    bytes32 internal constant MARKET_B = keccak256("B-PERP");
    uint16 internal constant HAIRCUT_BPS = 100;
    uint256 internal constant INDEX = 1_900e18;

    MockOracle internal indexB;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        ICollateralVault.CollateralConfig memory cfg = vault.getConfig(address(usdc));
        cfg.haircutBps = HAIRCUT_BPS;
        vault.setCollateralParams(address(usdc), cfg);

        // Market B on the same quote token with its own index, so A's index drop leaves it alone.
        indexB = new MockOracle(INITIAL_ETH_PRICE, 18);
        bytes memory initData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(clearingHouse),
            address(indexB),
            INITIAL_ETH_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY_INDEX,
            VAMM_FEE_BPS,
            FUNDING_MAX_BPS_PER_HOUR,
            FUNDING_K
        );
        vAMM vammB = vAMM(address(new ERC1967Proxy(address(new vAMM()), initData)));
        vammB.setRegistry(address(marketRegistry));
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: MARKET_B,
                vamm: address(vammB),
                oracle: address(indexB),
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: TRADE_FEE_BPS,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
        // IMR equal to MMR: a fresh position on B sits at its maintenance margin and holds no surplus
        // margin a liquidation elsewhere could draw.
        clearingHouse.setRiskParams(MARKET_B, 500, 500, 400, PENALTY_CAP, 0, 0);
        vm.stopPrank();
    }

    function _value(address user) internal view returns (uint256) {
        return vault.getTokenValueX18(address(usdc), getCollateralBalance(user));
    }

    function test_Finding20_liquidationSeizureKeepsOtherMarginsBacked() public {
        fundAndDeposit(alice, 10_000e18);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        clearingHouse.openPosition(MARKET_B, true, 20e18, 0);
        // Keep only what backs the reserved margin at the haircut value.
        uint256 reserved = clearingHouse._totalReservedMargin(alice);
        uint256 keep = (reserved * 10_000 + 9_899) / (10_000 - HAIRCUT_BPS);
        clearingHouse.withdraw(address(usdc), getCollateralBalance(alice) - keep);
        vm.stopPrank();
        assertGe(_value(alice), reserved, "setup: reserved margin unbacked");

        // A's mark and index drop; its liquidation loss leaves it short of the penalty.
        fundAndDeposit(bob, 100_000e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 30e18, 0);
        setOraclePrice(INDEX);
        assertTrue(clearingHouse.isLiquidatable(alice, ETH_PERP), "A not liquidatable");
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B liquidatable");

        liquidateFully(alice, ETH_PERP, bob);

        // The seizure stopped where the balance's haircut value meets B's reserved margin, so B's
        // margin is still fully backed.
        assertEq(getPosition(alice).size, 0, "A not closed");
        assertGe(_value(alice), clearingHouse._totalReservedMargin(alice), "B's margin left unbacked");
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B left liquidatable");
    }
}
