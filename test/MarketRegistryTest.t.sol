// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

/// @title MarketRegistryTest
/// @notice Comprehensive tests for MarketRegistry
contract MarketRegistryTest is BaseTest {

    bytes32 public constant BTC_PERP = keccak256("BTC-PERP");
    address public newVamm;
    address public newOracle;

    function setUp() public override {
        super.setUp();

        newVamm = makeAddr("newVamm");
        newOracle = makeAddr("newOracle");
    }

    // ============ Add Market Tests ============

    function test_AddMarket() public {
        vm.prank(admin);
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: BTC_PERP,
                vamm: newVamm,
                oracle: newOracle,
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: 10,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );

        IMarketRegistry.Market memory market = marketRegistry.getMarket(BTC_PERP);
        assertEq(market.vamm, newVamm, "vAMM not set");
        assertEq(market.oracle, newOracle, "Oracle not set");
        assertTrue(marketRegistry.isActive(BTC_PERP), "Market should be active");
    }

    function test_RevertWhen_AddMarket_NotAdmin() public {
        vm.expectRevert();
        vm.prank(alice);
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: BTC_PERP,
                vamm: newVamm,
                oracle: newOracle,
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: 10,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
    }

    function test_RevertWhen_AddMarket_AlreadyExists() public {
        vm.expectRevert("Market Exists");
        vm.prank(admin);
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: ETH_PERP, // Already registered in BaseTest
                vamm: newVamm,
                oracle: newOracle,
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: 10,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
    }

    function test_RevertWhen_AddMarket_ZeroVamm() public {
        vm.expectRevert("vAMM addr(0)");
        vm.prank(admin);
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: BTC_PERP,
                vamm: address(0),
                oracle: newOracle,
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: 10,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
    }

    function test_RevertWhen_AddMarket_ZeroOracle() public {
        vm.expectRevert("Oracle addr(0)");
        vm.prank(admin);
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: BTC_PERP,
                vamm: newVamm,
                oracle: address(0),
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: 10,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
    }

    function test_RevertWhen_AddMarket_ZeroQuoteToken() public {
        vm.expectRevert("Quote addr(0)");
        vm.prank(admin);
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: BTC_PERP,
                vamm: newVamm,
                oracle: newOracle,
                baseAsset: address(weth),
                quoteToken: address(0),
                baseUnit: 1e18,
                feeBps: 10,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
    }

    // ============ Pause/Unpause Tests ============

    function test_PauseMarket() public {
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, true);

        IMarketRegistry.Market memory market = marketRegistry.getMarket(ETH_PERP);
        assertTrue(market.paused, "Market should be paused");
        assertFalse(marketRegistry.isActive(ETH_PERP), "Market should not be active");
    }

    function test_UnpauseMarket() public {
        // First pause
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, true);

        // Then unpause
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, false);

        IMarketRegistry.Market memory market = marketRegistry.getMarket(ETH_PERP);
        assertFalse(market.paused, "Market should be unpaused");
        assertTrue(marketRegistry.isActive(ETH_PERP), "Market should be active");
    }

    function test_RevertWhen_PauseMarket_NotAdmin() public {
        vm.expectRevert();
        vm.prank(alice);
        marketRegistry.pauseMarket(ETH_PERP, true);
    }

    function test_RevertWhen_PauseMarket_NotExists() public {
        vm.expectRevert("No such market");
        vm.prank(admin);
        marketRegistry.pauseMarket(BTC_PERP, true);
    }

    // ============ Exists Function Test ============

    function test_Exists_ActiveMarket() public view {
        assertTrue(marketRegistry.exists(ETH_PERP), "Market should exist");
    }

    function test_Exists_NonExistentMarket() public view {
        assertFalse(marketRegistry.exists(BTC_PERP), "Market should not exist");
    }

    function test_IsPaused_ActiveMarket() public view {
        assertFalse(marketRegistry.isPaused(ETH_PERP), "Market should not be paused");
    }

    function test_IsPaused_PausedMarket() public {
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, true);

        assertTrue(marketRegistry.isPaused(ETH_PERP), "Market should be paused");
    }

    // ============ View Functions Tests ============

    function test_GetMarket() public view {
        IMarketRegistry.Market memory market = marketRegistry.getMarket(ETH_PERP);
        assertEq(market.vamm, address(vamm), "vAMM incorrect");
        assertEq(market.oracle, address(oracle), "Oracle incorrect");
        assertEq(market.quoteToken, address(usdc), "Quote token incorrect");
    }

    function test_GetMarket_NotExists() public view {
        IMarketRegistry.Market memory market = marketRegistry.getMarket(BTC_PERP);
        assertEq(market.vamm, address(0), "Should return zero address");
    }

    function test_IsActive_ActiveMarket() public view {
        assertTrue(marketRegistry.isActive(ETH_PERP), "Market should be active");
    }

    function test_IsActive_PausedMarket() public {
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, true);

        assertFalse(marketRegistry.isActive(ETH_PERP), "Paused market should not be active");
    }

    function test_IsActive_NonExistentMarket() public view {
        assertFalse(marketRegistry.isActive(BTC_PERP), "Non-existent market should not be active");
    }

    // ============ Role Tests ============

    function test_GrantMarketAdminRole() public {
        bytes32 marketAdminRole = marketRegistry.MARKET_ADMIN_ROLE();

        vm.prank(admin);
        marketRegistry.grantRole(marketAdminRole, alice);

        assertTrue(marketRegistry.hasRole(marketAdminRole, alice), "Role not granted");
    }

    function test_MarketAdminCanAddMarket() public {
        bytes32 marketAdminRole = marketRegistry.MARKET_ADMIN_ROLE();

        vm.prank(admin);
        marketRegistry.grantRole(marketAdminRole, alice);

        vm.prank(alice);
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: BTC_PERP,
                vamm: newVamm,
                oracle: newOracle,
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: 10,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );

        assertTrue(marketRegistry.isActive(BTC_PERP), "Market not added");
    }

    function test_GrantParamAdminRole() public {
        bytes32 paramAdminRole = marketRegistry.PARAM_ADMIN_ROLE();

        vm.prank(admin);
        marketRegistry.grantRole(paramAdminRole, alice);

        assertTrue(marketRegistry.hasRole(paramAdminRole, alice), "Role not granted");
    }

    function test_GrantPauseGuardianRole() public {
        bytes32 pauseGuardianRole = marketRegistry.PAUSE_GUARDIAN_ROLE();

        vm.prank(admin);
        marketRegistry.grantRole(pauseGuardianRole, alice);

        assertTrue(marketRegistry.hasRole(pauseGuardianRole, alice), "Role not granted");
    }

    function test_PauseGuardianCanPause() public {
        bytes32 pauseGuardianRole = marketRegistry.PAUSE_GUARDIAN_ROLE();

        vm.prank(admin);
        marketRegistry.grantRole(pauseGuardianRole, alice);

        vm.prank(alice);
        marketRegistry.pauseMarket(ETH_PERP, true);

        IMarketRegistry.Market memory market = marketRegistry.getMarket(ETH_PERP);
        assertTrue(market.paused, "Market not paused");
    }
}
