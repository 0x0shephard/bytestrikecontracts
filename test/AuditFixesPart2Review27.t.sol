// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "../script/MockERC20.sol";
import {vAMM} from "../src/vAMM.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice A market can only be pointed at an insurance fund that holds the market's quote token, so a
/// liquidation shortfall sized in the market's units is never paid out in another token's units
contract AuditFixesPart2Review27Test is BaseTest {
    bytes32 internal constant ETH2_PERP = keccak256("ETH2-PERP");
    uint256 internal constant OTHER_FUND_BALANCE = 50_000e6;

    MockERC20 internal usdc6;
    InsuranceFund internal otherFund;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        // A fund that holds a 6-decimal stablecoin, funded with 50,000 of it
        usdc6 = new MockERC20("USD Coin 6", "USDC6", 6);
        otherFund = new InsuranceFund(address(usdc6), address(clearingHouse));
        usdc6.mint(admin, OTHER_FUND_BALANCE);
        usdc6.approve(address(otherFund), OTHER_FUND_BALANCE);
        otherFund.donate(OTHER_FUND_BALANCE);
        marketRegistry.grantRole(marketRegistry.PARAM_ADMIN_ROLE(), admin);
        vm.stopPrank();
        assertTrue(otherFund.quoteToken() != marketRegistry.getMarket(ETH_PERP).quoteToken, "tokens match");
    }

    function _newVamm(MockOracle index2) internal returns (vAMM v) {
        bytes memory init = abi.encodeCall(
            vAMM.initialize,
            (
                address(clearingHouse),
                address(index2),
                INITIAL_ETH_PRICE,
                INITIAL_BASE_RESERVE,
                LIQUIDITY_INDEX,
                VAMM_FEE_BPS,
                FUNDING_MAX_BPS_PER_HOUR,
                FUNDING_K
            )
        );
        v = vAMM(address(new ERC1967Proxy(address(new vAMM()), init)));
        v.setRegistry(address(marketRegistry));
    }

    function _config(address vamm_, address oracle_, address fund) internal view returns (IMarketRegistry.AddMarketConfig memory) {
        return IMarketRegistry.AddMarketConfig({
            marketId: ETH2_PERP,
            vamm: vamm_,
            oracle: oracle_,
            baseAsset: address(weth),
            quoteToken: address(usdc),
            baseUnit: 1e18,
            feeBps: TRADE_FEE_BPS,
            feeRouter: address(feeRouter),
            insuranceFund: fund
        });
    }

    function test_SetMarketParams_RejectsFundWithOtherQuoteToken() public {
        vm.prank(admin);
        vm.expectRevert(bytes("IF quote mismatch"));
        marketRegistry.setMarketParams(ETH_PERP, TRADE_FEE_BPS, address(feeRouter), address(otherFund));
        assertEq(marketRegistry.getMarket(ETH_PERP).insuranceFund, address(insuranceFund), "fund changed");
        // The fund keeps its whole balance
        assertEq(otherFund.totalReceived() - otherFund.totalPaid(), OTHER_FUND_BALANCE, "fund drained");
    }

    function test_SetMarketParams_AcceptsFundWithSameQuoteToken() public {
        vm.startPrank(admin);
        InsuranceFund usdcFund = new InsuranceFund(address(usdc), address(clearingHouse));
        marketRegistry.setMarketParams(ETH_PERP, TRADE_FEE_BPS, address(feeRouter), address(usdcFund));
        vm.stopPrank();
        assertEq(marketRegistry.getMarket(ETH_PERP).insuranceFund, address(usdcFund), "fund not set");
    }

    function test_AddMarket_RejectsFundWithOtherQuoteToken() public {
        vm.startPrank(admin);
        MockOracle index2 = new MockOracle(INITIAL_ETH_PRICE, 18);
        vAMM v = _newVamm(index2);
        vm.expectRevert(bytes("IF quote mismatch"));
        marketRegistry.addMarket(_config(address(v), address(index2), address(otherFund)));

        // The same market with a fund holding its quote token lists fine
        marketRegistry.addMarket(_config(address(v), address(index2), address(insuranceFund)));
        vm.stopPrank();
        assertEq(marketRegistry.getMarket(ETH2_PERP).insuranceFund, address(insuranceFund), "market not listed");
    }
}
