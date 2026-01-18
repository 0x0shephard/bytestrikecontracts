// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MockERC20} from "../script/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {vAMM} from "../src/vAMM.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title BaseTest
/// @notice Base test contract with common setup and helper functions
/// @dev All test contracts should inherit from this
abstract contract BaseTest is Test {
    // Contracts
    MockERC20 public usdc;
    MockERC20 public weth;
    MockOracle public oracle;
    CollateralVault public vault;
    MarketRegistry public marketRegistry;
    ClearingHouse public clearingHouse;
    vAMM public vamm;
    FeeRouter public feeRouter;
    InsuranceFund public insuranceFund;

    // Test accounts
    address public admin;
    address public treasury;
    address public alice;
    address public bob;
    address public liquidator;

    // Market configuration
    bytes32 public constant ETH_PERP = keccak256("ETH-PERP");
    uint256 public constant INITIAL_ETH_PRICE = 2000 * 1e18; // $2000
    uint256 public constant INITIAL_BASE_RESERVE = 1000 * 1e18; // 1000 ETH
    uint128 public constant LIQUIDITY_INDEX = 1e24;

    // Fee configuration
    uint16 public constant TRADE_FEE_BPS = 10; // 0.1%
    uint256 public constant FUNDING_MAX_BPS_PER_HOUR = 100; // 1%
    uint256 public constant FUNDING_K = 1e18;
    uint32 public constant OBSERVATION_WINDOW = 3600; // 1 hour
    uint16 public constant FEE_TO_INSURANCE_BPS = 5000; // 50%

    // Risk parameters
    uint256 public constant IMR_BPS = 500; // 5%
    uint256 public constant MMR_BPS = 250; // 2.5%
    uint256 public constant LIQUIDATION_PENALTY_BPS = 200; // 2%
    uint256 public constant PENALTY_CAP = 10000 * 1e18; // 10k USDC
    uint256 public constant MAX_POSITION_SIZE = 0; // unlimited
    uint256 public constant MIN_POSITION_SIZE = 0; // no minimum

    // Helper constants
    uint256 public constant USDC_UNIT = 1e18; // Using 18 decimals for test USDC to match vAMM precision
    uint256 public constant ETH_UNIT = 1e18;
    uint256 public constant PRICE_PRECISION = 1e18;

    function setUp() public virtual {
        // Setup test accounts
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        liquidator = makeAddr("liquidator");

        vm.startPrank(admin);

        // 1. Deploy tokens and oracle
        usdc = new MockERC20("USD Coin", "USDC", 18); // Using 18 decimals to match vAMM precision
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(INITIAL_ETH_PRICE, 18);
        oracle.setSymbol("ETH");

        // 2. Deploy core infrastructure
        vault = new CollateralVault();
        vault.setOracle(address(oracle));

        marketRegistry = new MarketRegistry();

        // Deploy ClearingHouse with proxy
        ClearingHouse clearingHouseImpl = new ClearingHouse();
        bytes memory clearingHouseInitData = abi.encodeWithSelector(
            ClearingHouse.initialize.selector,
            address(vault),
            address(marketRegistry),
            admin
        );
        ERC1967Proxy clearingHouseProxy = new ERC1967Proxy(
            address(clearingHouseImpl),
            clearingHouseInitData
        );
        clearingHouse = ClearingHouse(address(clearingHouseProxy));

        // 3. Deploy vAMM with proxy
        vAMM vammImpl = new vAMM();
        bytes memory vammInitData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(clearingHouse),
            address(oracle),
            INITIAL_ETH_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY_INDEX,
            TRADE_FEE_BPS,
            FUNDING_MAX_BPS_PER_HOUR,
            FUNDING_K,
            OBSERVATION_WINDOW
        );
        ERC1967Proxy vammProxy = new ERC1967Proxy(address(vammImpl), vammInitData);
        vamm = vAMM(address(vammProxy));

        // 4. Deploy fee infrastructure
        insuranceFund = new InsuranceFund(address(usdc), address(clearingHouse));

        feeRouter = new FeeRouter(
            address(usdc),
            address(insuranceFund),
            treasury,
            address(clearingHouse),
            FEE_TO_INSURANCE_BPS,
            FEE_TO_INSURANCE_BPS
        );

        // 5. Wire contracts
        insuranceFund.setFeeRouter(address(feeRouter), true);
        insuranceFund.setAuthorized(address(clearingHouse), true);
        vault.setClearinghouse(address(clearingHouse));

        // 6. Register collateral
        vault.registerCollateral(
            ICollateralVault.CollateralConfig({
                token: address(usdc),
                baseUnit: 1e18, // Match 18-decimal test USDC
                haircutBps: 0,
                liqIncentiveBps: uint16(LIQUIDATION_PENALTY_BPS),
                cap: type(uint256).max,
                accountCap: type(uint256).max,
                enabled: true,
                depositPaused: false,
                withdrawPaused: false,
                oracleSymbol: "USDC"
            })
        );

        // 7. Register market
        marketRegistry.grantRole(marketRegistry.MARKET_ADMIN_ROLE(), admin);

        IMarketRegistry.AddMarketConfig memory marketConfig = IMarketRegistry.AddMarketConfig({
            marketId: ETH_PERP,
            vamm: address(vamm),
            oracle: address(oracle),
            baseAsset: address(weth),
            quoteToken: address(usdc),
            baseUnit: 1e18,
            feeBps: TRADE_FEE_BPS,
            feeRouter: address(feeRouter),
            insuranceFund: address(insuranceFund)
        });
        marketRegistry.addMarket(marketConfig);

        // 8. Set risk parameters
        clearingHouse.setRiskParams(
            ETH_PERP,
            IMR_BPS,
            MMR_BPS,
            LIQUIDATION_PENALTY_BPS,
            PENALTY_CAP,
            MAX_POSITION_SIZE,
            MIN_POSITION_SIZE
        );

        // 9. Setup liquidator
        clearingHouse.setWhitelistedLiquidator(liquidator, true);

        // 10. Fund insurance fund
        usdc.mint(address(insuranceFund), 100000 * USDC_UNIT);

        vm.stopPrank();
    }

    // ============ Helper Functions ============

    /// @notice Fund a user with USDC
    function fundUser(address user, uint256 usdcAmount) public {
        usdc.mint(user, usdcAmount);
    }

    /// @notice Fund user and deposit into ClearingHouse
    function fundAndDeposit(address user, uint256 usdcAmount) public {
        fundUser(user, usdcAmount);

        vm.startPrank(user);
        usdc.approve(address(vault), usdcAmount);
        clearingHouse.deposit(address(usdc), usdcAmount);
        vm.stopPrank();
    }

    /// @notice Open a long position for a user
    function openLongPosition(
        address user,
        uint128 size,
        uint256 priceLimit
    ) public {
        // Calculate required margin for the position
        // Estimate notional value (actual execution price may vary slightly)
        uint256 estimatedPrice = getMarkPrice();
        uint256 estimatedNotional = (uint256(size) * estimatedPrice) / 1e18;

        // Required margin = IMR + fees (with 10% buffer for price impact)
        uint256 requiredIMR = (estimatedNotional * IMR_BPS) / 10000;
        uint256 estimatedFees = (estimatedNotional * TRADE_FEE_BPS) / 10000;
        uint256 requiredMargin = ((requiredIMR + estimatedFees) * 110) / 100;

        // Use all available collateral if test explicitly wants a risky/undercollateralized position
        uint256 availableCollateral = getCollateralBalance(user);
        uint256 marginToAdd = requiredMargin > availableCollateral ? availableCollateral : requiredMargin;

        vm.startPrank(user);
        clearingHouse.addMargin(ETH_PERP, marginToAdd);
        clearingHouse.openPosition(ETH_PERP, true, size, priceLimit);
        vm.stopPrank();
    }

    /// @notice Open a short position for a user
    function openShortPosition(
        address user,
        uint128 size,
        uint256 priceLimit
    ) public {
        // Calculate required margin for the position
        // Estimate notional value (actual execution price may vary slightly)
        uint256 estimatedPrice = getMarkPrice();
        uint256 estimatedNotional = (uint256(size) * estimatedPrice) / 1e18;

        // Required margin = IMR + fees (with 10% buffer for price impact)
        uint256 requiredIMR = (estimatedNotional * IMR_BPS) / 10000;
        uint256 estimatedFees = (estimatedNotional * TRADE_FEE_BPS) / 10000;
        uint256 requiredMargin = ((requiredIMR + estimatedFees) * 110) / 100;

        // Use all available collateral if test explicitly wants a risky/undercollateralized position
        uint256 availableCollateral = getCollateralBalance(user);
        uint256 marginToAdd = requiredMargin > availableCollateral ? availableCollateral : requiredMargin;

        vm.startPrank(user);
        clearingHouse.addMargin(ETH_PERP, marginToAdd);
        clearingHouse.openPosition(ETH_PERP, false, size, priceLimit);
        vm.stopPrank();
    }

    /// @notice Close a position for a user
    function closePosition(
        address user,
        uint128 size,
        uint256 priceLimit
    ) public {
        vm.prank(user);
        clearingHouse.closePosition(ETH_PERP, size, priceLimit);
    }

    /// @notice Update oracle price
    function setOraclePrice(uint256 newPrice) public {
        oracle.setPrice(newPrice);
    }

    /// @notice Get user's position
    function getPosition(address user) public view returns (IClearingHouse.PositionView memory) {
        return clearingHouse.getPosition(user, ETH_PERP);
    }

    /// @notice Get user's collateral balance
    function getCollateralBalance(address user) public view returns (uint256) {
        return vault.balanceOf(user, address(usdc));
    }

    /// @notice Get user's margin for a market
    function getMargin(address user) public view returns (uint256) {
        IClearingHouse.PositionView memory pos = getPosition(user);
        return pos.margin;
    }

    /// @notice Get mark price from vAMM
    function getMarkPrice() public view returns (uint256) {
        return vamm.getMarkPrice();
    }

    /// @notice Get notional value of position
    function getNotional(address user) public view returns (uint256) {
        return clearingHouse.getNotional(user, ETH_PERP);
    }

    /// @notice Get margin ratio
    function getMarginRatio(address user) public view returns (uint256) {
        return clearingHouse.getMarginRatio(user, ETH_PERP);
    }

    /// @notice Check if position is liquidatable
    function isLiquidatable(address user) public view returns (bool) {
        return clearingHouse.isLiquidatable(user, ETH_PERP);
    }

    /// @notice Calculate required initial margin
    function calculateInitialMargin(uint256 notional) public pure returns (uint256) {
        return (notional * IMR_BPS) / 10000;
    }

    /// @notice Calculate required maintenance margin
    function calculateMaintenanceMargin(uint256 notional) public pure returns (uint256) {
        return (notional * MMR_BPS) / 10000;
    }

    /// @notice Settle funding for a user
    function settleFunding(address user) public {
        clearingHouse.settleFunding(ETH_PERP, user);
    }

    /// @notice Skip time forward
    function skipTime(uint256 seconds_) public {
        vm.warp(block.timestamp + seconds_);
    }

    /// @notice Skip blocks forward
    function skipBlocks(uint256 blocks_) public {
        vm.roll(block.number + blocks_);
    }

    /// @notice Helper to express position sizes in whole ETH units.
    /// @dev Multiplies the desired ETH amount by 1e18 and casts to uint128 with overflow protection.
    function ethQty(uint256 amount) internal pure returns (uint128) {
        if (amount == 0) {
            return 0;
        }

        uint256 value = amount * ETH_UNIT;
        require(value / amount == ETH_UNIT, "ethQty overflow");
        require(value <= type(uint128).max, "ethQty too large");
        return uint128(value);
    }

    /// @notice Get vAMM reserves
    function getReserves() public view returns (uint256 baseReserve, uint256 quoteReserve) {
        return vamm.getReserves();
    }

    /// @notice Get cumulative funding rate
    function getCumulativeFunding() public view returns (int256) {
        return vamm.cumulativeFundingPerUnitX18();
    }

    /// @notice Assert position size
    function assertPositionSize(address user, int256 expectedSize) public {
        IClearingHouse.PositionView memory pos = getPosition(user);
        assertEq(pos.size, expectedSize, "Position size mismatch");
    }

    /// @notice Assert position is approximately equal (within 1%)
    function assertApproxEqRelPosition(address user, int256 expectedSize, uint256 maxPercentDelta) public {
        IClearingHouse.PositionView memory pos = getPosition(user);
        assertApproxEqRel(
            uint256(pos.size > 0 ? pos.size : -pos.size),
            uint256(expectedSize > 0 ? expectedSize : -expectedSize),
            maxPercentDelta,
            "Position size not within tolerance"
        );
    }

    /// @notice Log position info (useful for debugging)
    function logPosition(address user, string memory label) public view {
        IClearingHouse.PositionView memory pos = getPosition(user);
        console.log("=== Position:", label, "===");
        console.log("User:", user);
        console.logInt(pos.size);
        console.log("Margin:", pos.margin);
        console.log("Entry Price:", pos.entryPriceX18);
        console.logInt(pos.lastFundingIndex);
        console.logInt(pos.realizedPnL);
        console.log("Notional:", getNotional(user));
        console.log("Margin Ratio:", getMarginRatio(user));
        console.log("===================");
    }
}
