//SPDX-License-Identifier:MIT
pragma solidity 0.8.28;

import {IClearingHouse} from "./Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "./Interfaces/ICollateralVault.sol";
import {IMarketRegistry} from "./Interfaces/IMarketRegistry.sol";
import {IVAMM} from "./Interfaces/IVAMM.sol";
import {IOracle} from "./Interfaces/IOracle.sol";
import {Calculations} from "./Libraries/Calculations.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IInsuranceFund} from "./Interfaces/IInsuranceFund.sol";
import {IFeeRouter} from "./Interfaces/IFeeRouter.sol";

/// @notice The central contract for managing user positions, margin, and trade settlement for perpetual vAMM markets.
/// @dev It interacts with various components like the CollateralVault, MarketRegistry, and vAMMs.
contract ClearingHouse is Initializable, AccessControl, UUPSUpgradeable, ReentrancyGuard, IClearingHouse {
    using Calculations for uint256;

    /// @notice Address of the collateral vault contract.
    address public vault;
    /// @notice Address of the market registry contract.
    address public marketRegistry;


    /// @notice Mapping of whitelisted liquidator addresses.
    mapping(address user => bool isWhitelisted) public WhitelistedLiquidators;
    /// @notice Mapping from user address to their position in a specific market.
    mapping(address user => mapping(bytes32 marketId => PositionView)) public positions;
    /// @notice Mapping of total margin reserved by a user across all their positions.
    mapping(address user => uint256 amount) public _totalReservedMargin;
    /// @notice Mapping of risk parameters for each market.
    mapping(bytes32 marketId => MarketRiskParams) public marketRiskParams;
    /// @notice Mapping of active market IDs per user for withdrawal checks.
    mapping(address user => bytes32[] marketIds) private _userActiveMarkets;
    /// @notice Helper mapping to check if a market is in user's active list.
    mapping(address user => mapping(bytes32 marketId => bool)) private _isMarketActive;

    /// @notice Struct defining the risk parameters for a market.
    struct MarketRiskParams {
        uint256 imrBps; // initial margin requirement bps
        uint256 mmrBps; // maintenance margin requirement bps
        uint256 liquidationPenaltyBps;
        uint256 penaltyCap; // absolute cap in quote units (1e18)
        uint256 maxPositionSize; // max position size per user in base units (0 = unlimited)
        uint256 minPositionSize; // min position size in base units (0 = no minimum)
    }

    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Precision for price and value calculations (1e18)
    uint256 public constant PRECISION = 1e18;

    /// @notice Total uncompensated bad debt accumulated across all liquidations
    uint256 public totalBadDebt;

    /// @notice Set of legacy vaults from prior migrations, allowing users to withdraw stranded balances.
    mapping(address => bool) public legacyVaults;

    /// @notice Modifier to restrict access to admin roles.
    modifier onlyAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "CH: not admin");
        _;
    }

    /// @notice Modifier to restrict access to whitelisted liquidators.
    modifier onlyWhitelistedLiquidator() {
        require(WhitelistedLiquidators[msg.sender], "CH: not whitelisted liquidator");
        _;
    }

    event MarginAdded(address indexed user, bytes32 indexed marketId, uint256 amount);
    event collateralDeposited(address indexed user, address indexed token, uint256 amount);
    event collateralWithdrawn(address indexed user, address indexed token, uint256 amount, uint256 received);
    event MarginRemoved(address indexed user, bytes32 indexed marketId, uint256 amount);
    event RiskParamsSet(
        bytes32 indexed marketId,
        uint256 imrBps,
        uint256 mmrBps,
        uint256 liquidationPenaltyBps,
        uint256 penaltyCap,
        uint256 maxPositionSize,
        uint256 minPositionSize
    );
    event FundingSettled(bytes32 indexed marketId, address indexed account, int256 fundingPayment);
    event MarketPaused(bytes32 indexed marketId, bool isPaused);
    event LiquidatorWhitelistUpdated(address indexed liquidator, bool isWhitelisted);
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event LegacyVaultWithdrawal(address indexed user, address indexed legacyVault, address indexed token, uint256 amount, uint256 received);
    event LiquidationExecuted(
        bytes32 indexed marketId,
        address indexed liquidator,
        address indexed account,
        uint128 size,
        uint256 notional,
        uint256 penalty,
        uint256 liquidatorReward,
        uint256 protocolFee,
        uint256 insurancePayout
    );
    event PositionOpened(
        address indexed user,
        bytes32 indexed marketId,
        bool isLong,
        uint128 size,
        uint256 entryPrice,
        uint256 margin
    );
    event PositionClosed(
        address indexed user,
        bytes32 indexed marketId,
        uint128 size,
        uint256 exitPrice,
        int256 realizedPnL
    );
    event TradeExecuted(
        address indexed user,
        bytes32 indexed marketId,
        int256 baseDelta,
        int256 quoteDelta,
        uint256 executionPrice,
        int256 newSize,
        uint256 newMargin,
        int256 realizedPnL,
        uint256 fee
    );
    event BadDebtRecorded(
        address indexed account,
        bytes32 indexed marketId,
        uint256 shortfall
    );

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer replacing constructor for upgradeable deployment.
    /// @param _vault The address of the CollateralVault contract.
    /// @param _marketRegistry The address of the MarketRegistry contract.
    /// @param admin The address that will receive the default admin role.
    function initialize(address _vault, address _marketRegistry, address admin) external initializer {
        require(_vault != address(0), "CH: invalid vault");
        require(_marketRegistry != address(0), "CH: invalid registry");
        require(admin != address(0), "CH: invalid admin");

        vault = _vault;
        marketRegistry = _marketRegistry;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Updates the vault address (for migration purposes).
    /// @param _newVault The address of the new CollateralVault contract.
    /// @dev Only callable by admin. Used when migrating to a new vault.
    function setVault(address _newVault) external onlyAdmin {
        require(_newVault != address(0), "CH: invalid vault");
        address oldVault = vault;
        if (oldVault != address(0)) {
            legacyVaults[oldVault] = true;
        }
        vault = _newVault;
        emit VaultUpdated(oldVault, _newVault);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}


    /// @notice Deposits collateral into the vault for the caller.
    /// @param token The address of the ERC20 token to deposit.
    /// @param amount The amount of the token to deposit.
    function deposit(address token, uint256 amount) external override nonReentrant {
        require(amount > 0, "CH: amount=0");
        ICollateralVault(vault).deposit(token, amount, msg.sender);
        emit collateralDeposited(msg.sender, token, amount);
    }

    /// @notice Withdraws collateral from the vault for the caller.
    /// @dev Checks that the withdrawal does not compromise the user's total reserved margin
    ///      and that no positions would become liquidatable after withdrawal.
    /// @param token The address of the ERC20 token to withdraw.
    /// @param amount The amount of the token to withdraw.
    function withdraw(address token, uint256 amount) external override nonReentrant {
        require(amount > 0, "CH: amount=0");

        // Settle funding for all active markets to ensure margin values are current
        bytes32[] memory markets = _userActiveMarkets[msg.sender];
        for (uint256 i = 0; i < markets.length; i++) {
            _settleFundingInternal(markets[i], msg.sender);
        }

        // Ensure reserved margin remains backed by quote-token collateral after withdrawal.
        // Non-quote tokens don't back margin, so only quote token withdrawals can breach this.
        uint256 userTotalReserveMargin = _totalReservedMargin[msg.sender];
        if (userTotalReserveMargin > 0) {
            uint256 quoteCollateralValue = _getQuoteCollateralValueX18(msg.sender);
            uint256 withdrawQuoteImpact = _isQuoteTokenInActiveMarkets(msg.sender, token)
                ? _quoteValueX18(token, amount)
                : 0;
            require(quoteCollateralValue >= userTotalReserveMargin + withdrawQuoteImpact, "CH: insufficient quote collateral");
        }

        // withdrawFor returns actual received amount (fee-on-transfer support)
        uint256 received = ICollateralVault(vault).withdrawFor(msg.sender, token, amount, msg.sender);

        // Post-withdrawal check: ensure no positions become liquidatable
        bytes32[] memory activeMarkets = _userActiveMarkets[msg.sender];
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            require(!this.isLiquidatable(msg.sender, activeMarkets[i]), "CH: would be liquidatable");
        }

        emit collateralWithdrawn(msg.sender, token, amount, received);
    }

    /// @notice Migrate a user's stranded collateral from a legacy vault into the current vault.
    /// @dev Admin-only. Withdraws tokens from the legacy vault directly to the current vault,
    ///      then credits the user's balance in the current vault via settlePnL.
    /// @param legacyVault The address of the previous vault contract.
    /// @param user The user whose balance is being migrated.
    /// @param token The ERC20 token to migrate.
    /// @param amount The amount to migrate.
    function withdrawFromLegacyVault(address legacyVault, address user, address token, uint256 amount) external onlyAdmin nonReentrant {
        require(legacyVaults[legacyVault], "CH: not a legacy vault");
        require(amount > 0, "CH: amount=0");
        require(user != address(0), "CH: zero address");

        // Withdraw from legacy vault, sending tokens directly to the current vault
        uint256 received = ICollateralVault(legacyVault).withdrawFor(user, token, amount, vault);

        // Credit the user's balance in the current vault
        if (received > 0) {
            ICollateralVault(vault).settlePnL(user, token, int256(received));
        }

        emit LegacyVaultWithdrawal(user, legacyVault, token, amount, received);
    }

    /// @notice Adds margin to a specific position from the user's available collateral.
    /// @param marketId The ID of the market for the position.
    /// @param amount The amount of margin to add (in quote currency value, 1e18).
    function addMargin(bytes32 marketId, uint256 amount) external override {
        _settleFundingInternal(marketId, msg.sender);
        require(amount > 0, "CH: amount=0");
        require(IMarketRegistry(marketRegistry).isActive(marketId), "CH: market not active");
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        uint256 quoteBalance = ICollateralVault(vault).balanceOf(msg.sender, m.quoteToken);
        uint256 quoteValueX18 = _quoteValueX18(m.quoteToken, quoteBalance);
        uint256 userTotalReserveMargin = _totalReservedMargin[msg.sender];
        require(amount <= quoteValueX18 - userTotalReserveMargin, "CH: insufficient quote balance");
        positions[msg.sender][marketId].margin += amount;
        _totalReservedMargin[msg.sender] += amount;
        emit MarginAdded(msg.sender, marketId, amount);
    }

    /// @notice Removes margin from a specific position, making it available for withdrawal or use in other positions.
    /// @dev Checks that removing margin does not leave the position below the maintenance margin requirement.
    /// @param marketId The ID of the market for the position.
    /// @param amount The amount of margin to remove (in quote currency value, 1e18).
    function removeMargin(bytes32 marketId, uint256 amount) external override {
        _settleFundingInternal(marketId, msg.sender);
        require(amount > 0, "CH: amount=0");
        require(IMarketRegistry(marketRegistry).isActive(marketId), "CH: market not active");
        PositionView storage position = positions[msg.sender][marketId];
        require(position.margin >= amount, "CH: insufficient margin");
        // Use the less favorable price between oracle and mark to prevent
        // margin extraction when mark diverges from oracle.
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        uint256 riskPrice = _getRiskPrice(m);
        uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
        uint256 conservativePrice = position.size > 0
            ? (riskPrice < markPrice ? riskPrice : markPrice)
            : (riskPrice > markPrice ? riskPrice : markPrice);
        int256 unrealizedPnL = _computeUnrealizedPnL(position, conservativePrice);
        uint256 maintenanceMargin = _getMaintenanceMargin(msg.sender, marketId);
        int256 effectiveMarginAfter = int256(position.margin - amount) + unrealizedPnL;
        require(effectiveMarginAfter >= int256(maintenanceMargin), "CH: would be liquidatable");

        // Enforce minimum margin floor: position margin must always cover the liquidation penalty
        // so that the penalty can be paid from the user's reserved margin and not the insurance fund.
        if (position.size != 0) {
            uint256 minMargin = _getLiquidationPenalty(msg.sender, marketId);
            require(position.margin - amount >= minMargin, "CH: margin below liquidation penalty");
        }

        position.margin -= amount;
        _totalReservedMargin[msg.sender] -= amount;
        emit MarginRemoved(msg.sender, marketId, amount);
    }


    /// @notice Checks if an account's position in a given market is subject to liquidation.
    /// @dev Uses oracle (risk) price for both PnL and maintenance margin to prevent
    ///      mark-price manipulation attacks. Consistent with getMarginRatio.
    /// @param account The address of the user.
    /// @param marketId The ID of the market.
    /// @return A boolean indicating if the position is liquidatable.
    function isLiquidatable(address account, bytes32 marketId) external view override returns (bool) {
        PositionView storage position = positions[account][marketId];
        if (position.size == 0) return false;

        // Include unsettled funding in effective margin so off-chain callers
        // (keepers, UIs) see accurate liquidation status without requiring
        // a prior settleFunding transaction.
        int256 pendingFunding = _getPendingFunding(account, marketId);

        // Calculate effective margin including unrealized PnL at oracle (risk) price
        int256 unrealizedPnL = _getUnrealizedPnLAtOracle(account, marketId);
        int256 effectiveMargin = int256(position.margin) + pendingFunding + unrealizedPnL;

        // Position is liquidatable if effective margin falls below maintenance margin
        uint256 maintenanceMargin = _getMaintenanceMargin(account, marketId);
        return effectiveMargin < int256(maintenanceMargin);
    }

    /// @notice Sets the risk parameters for a market.
    /// @param marketId The ID of the market.
    /// @param imrBps The initial margin requirement in basis points.
    /// @param mmrBps The maintenance margin requirement in basis points.
    /// @param liquidationPenaltyBps The liquidation penalty in basis points.
    /// @param penaltyCap The maximum liquidation penalty in quote units (1e18).
    function setRiskParams(
        bytes32 marketId,
        uint256 imrBps,
        uint256 mmrBps,
        uint256 liquidationPenaltyBps,
        uint256 penaltyCap,
        uint256 maxPositionSize,
        uint256 minPositionSize
    ) external override onlyAdmin {
        require(IMarketRegistry(marketRegistry).getMarket(marketId).vamm != address(0), "CH: market not found");
        require(imrBps >= mmrBps, "CH: IMR must be >= MMR");
        require(mmrBps > 0, "CH: MMR=0");
        require(minPositionSize <= maxPositionSize || maxPositionSize == 0, "CH: min > max");

        marketRiskParams[marketId] = MarketRiskParams({
            imrBps: imrBps,
            mmrBps: mmrBps,
            liquidationPenaltyBps: liquidationPenaltyBps,
            penaltyCap: penaltyCap,
            maxPositionSize: maxPositionSize,
            minPositionSize: minPositionSize
        });

        emit RiskParamsSet(marketId, imrBps, mmrBps, liquidationPenaltyBps, penaltyCap, maxPositionSize, minPositionSize);
    }

    /// @notice Gets the maintenance margin required for a position.
    /// @param account The address of the user.
    /// @param marketId The ID of the market.
    /// @return The maintenance margin amount.
    function getMaintenanceMargin(address account, bytes32 marketId) external view returns (uint256) {
        return _getMaintenanceMargin(account, marketId);
    }

    /// @notice Internal function to calculate the maintenance margin for a position.
    /// @param account The address of the user.
    /// @param marketId The ID of the market.
    /// @return The maintenance margin amount.
    function _getMaintenanceMargin(address account, bytes32 marketId) internal view returns (uint256) {
        PositionView storage position = positions[account][marketId];
        if (position.size == 0) {
            return 0;
        }

        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        require(m.vamm != address(0), "CH: market not found");

        uint256 mmrBps = marketRiskParams[marketId].mmrBps;
        uint256 positionSize = uint256(position.size > 0 ? position.size : -position.size);
        uint256 riskPrice = _getRiskPrice(m);
        uint256 notionalValue = positionSize.mulDiv(riskPrice, 1e18);
        return notionalValue.mulDiv(mmrBps, BPS_DENOMINATOR);
    }

    /// @notice Computes the liquidation penalty for a position using the same formula as liquidate().
    /// @dev penalty = min(notional * liquidationPenaltyBps / 10000, penaltyCap)
    function _getLiquidationPenalty(address account, bytes32 marketId) internal view returns (uint256) {
        PositionView storage position = positions[account][marketId];
        if (position.size == 0) return 0;

        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        uint256 riskPrice = _getRiskPrice(m);
        uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);
        uint256 notional = Calculations.mulDiv(absSize, riskPrice, 1e18);
        uint256 penalty = Calculations.mulDiv(notional, marketRiskParams[marketId].liquidationPenaltyBps, BPS_DENOMINATOR);
        uint256 cap = marketRiskParams[marketId].penaltyCap;
        if (cap > 0 && penalty > cap) {
            penalty = cap;
        }
        return penalty;
    }

    /// @notice Internal function to calculate unrealized PnL for a position using mark price.
    function _getUnrealizedPnL(address account, bytes32 marketId) internal view returns (int256) {
        PositionView storage position = positions[account][marketId];
        if (position.size == 0 || position.entryPriceX18 == 0) {
            return 0;
        }

        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (m.vamm == address(0)) return 0;

        uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
        return _computeUnrealizedPnL(position, markPrice);
    }

    /// @notice Internal function to calculate unrealized PnL for liquidation risk using oracle (index) price.
    function _getUnrealizedPnLAtOracle(address account, bytes32 marketId) internal view returns (int256) {
        PositionView storage position = positions[account][marketId];
        if (position.size == 0 || position.entryPriceX18 == 0) {
            return 0;
        }

        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (m.vamm == address(0)) return 0;

        uint256 riskPrice = _getRiskPrice(m);
        return _computeUnrealizedPnL(position, riskPrice);
    }

    /// @notice View-safe helper to compute unsettled funding for a position.
    /// @dev Reads the current cumulative funding index from the vAMM and computes
    ///      the delta against the position's last settled index. Does not modify state.
    function _getPendingFunding(address account, bytes32 marketId) internal view returns (int256) {
        PositionView storage position = positions[account][marketId];
        if (position.size == 0) return 0;

        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (m.vamm == address(0)) return 0;

        int256 currentIndex = IVAMM(m.vamm).cumulativeFundingPerUnitX18();
        int256 deltaIndex = currentIndex - position.lastFundingIndex;
        if (deltaIndex == 0) return 0;

        return -(deltaIndex * position.size) / int256(1e18);
    }

    /// @notice Shared helper to compute unrealized PnL from a provided price.
    function _computeUnrealizedPnL(PositionView storage position, uint256 priceX18) internal view returns (int256) {
        if (priceX18 == 0 || position.size == 0 || position.entryPriceX18 == 0) {
            return 0;
        }

        uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);
        if (position.size > 0) {
            // Long position: PnL = (price - entry) * size
            return (int256(priceX18) - int256(position.entryPriceX18)) * int256(absSize) / 1e18;
        } else {
            // Short position: PnL = (entry - price) * size
            return (int256(position.entryPriceX18) - int256(priceX18)) * int256(absSize) / 1e18;
        }
    }


    /// @notice Opens a new position or increases an existing one in a perpetual market.
    /// @param marketId The ID of the perpetual market.
    /// @param isLong True for a long position, false for a short position.
    /// @param size The amount of base asset to trade.
    /// @param priceLimitX18 The price limit for the trade (slippage protection).
    function openPosition(bytes32 marketId, bool isLong, uint128 size, uint256 priceLimitX18) external override nonReentrant {
        // Settle funding for all active markets to ensure margin values are current
        bytes32[] memory activeMarkets = _userActiveMarkets[msg.sender];
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            _settleFundingInternal(activeMarkets[i], msg.sender);
        }
        // Also settle for target market if not already active
        if (activeMarkets.length == 0 || !_isMarketActive[msg.sender][marketId]) {
            _settleFundingInternal(marketId, msg.sender);
        }

        // Block new positions if user has any liquidatable position
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            require(!this.isLiquidatable(msg.sender, activeMarkets[i]), "CH: has liquidatable position");
        }

        require(IMarketRegistry(marketRegistry).isActive(marketId), "CH: market not active");
        require(marketRiskParams[marketId].mmrBps > 0, "CH: risk params not set");
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        require(m.vamm != address(0), "CH: market not found");
        require(size > 0, "CH: size=0");

        IVAMM vamm = IVAMM(m.vamm);
        (int256 baseDelta, int256 quoteDelta, uint256 avgPrice) = isLong
            ? vamm.buyBase(size, priceLimitX18)
            : vamm.sellBase(size, priceLimitX18);

        _applyTrade(msg.sender, marketId, baseDelta, quoteDelta, false);

        // Check position size limits
        PositionView storage position = positions[msg.sender][marketId];
        uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);

        // Check max position size (0 = unlimited)
        uint256 maxSize = marketRiskParams[marketId].maxPositionSize;
        if (maxSize > 0) {
            require(absSize <= maxSize, "CH: exceeds max size");
        }

        // Check min position size (0 = no minimum)
        uint256 minSize = marketRiskParams[marketId].minPositionSize;
        if (minSize > 0 && absSize > 0) {
            require(absSize >= minSize, "CH: below min size");
        }

        // Emit position opened event
        emit PositionOpened(
            msg.sender,
            marketId,
            isLong,
            size,
            avgPrice,
            position.margin
        );
    }

    /// @notice Closes or reduces an existing position in a perpetual market.
    /// @param marketId The ID of the perpetual market.
    /// @param size The amount of base asset to trade for closing the position.
    /// @param priceLimitX18 The price limit for the trade (slippage protection).
    function closePosition(bytes32 marketId, uint128 size, uint256 priceLimitX18) external override nonReentrant {
        _settleFundingInternal(marketId, msg.sender);
        require(!this.isLiquidatable(msg.sender, marketId), "CH: position liquidatable");
        require(IMarketRegistry(marketRegistry).isActive(marketId), "CH: market not active");
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        require(m.vamm != address(0), "CH: market not found");
        require(size > 0, "CH: size=0");

        PositionView storage position = positions[msg.sender][marketId];
        require(position.size != 0, "CH: no position");
        uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);
        require(uint256(size) <= absSize, "CH: reduce > position");

        IVAMM vamm = IVAMM(m.vamm);
        // If long, sell base to close; if short, buy base to close
        (int256 baseDelta, int256 quoteDelta, uint256 avgPrice) = position.size > 0
            ? vamm.sellBase(size, priceLimitX18)
            : vamm.buyBase(size, priceLimitX18);

        // Store realized PnL before applying trade
        int256 oldRealizedPnL = position.realizedPnL;
        _applyTrade(msg.sender, marketId, baseDelta, quoteDelta, false);

        // Enforce minPositionSize on remaining position to prevent dust
        {
            uint256 remainingSize = uint256(position.size > 0 ? position.size : -position.size);
            uint256 minSize = marketRiskParams[marketId].minPositionSize;
            if (minSize > 0 && remainingSize > 0) {
                require(remainingSize >= minSize, "CH: remaining below min, close full");
            }
        }

        // Emit position closed event
        emit PositionClosed(
            msg.sender,
            marketId,
            size,
            avgPrice,
            position.realizedPnL - oldRealizedPnL
        );
    }

    /// @notice Liquidates a position that is below the maintenance margin requirement.
    /// @dev Can only be called by a whitelisted liquidator.
    /// @param account The address of the user whose position is being liquidated.
    /// @param marketId The ID of the market.
    /// @param size The amount of the position to liquidate.
    function liquidate(address account, bytes32 marketId, uint128 size, uint256 priceLimitX18) external override nonReentrant onlyWhitelistedLiquidator {
        // Settle funding first to ensure accurate liquidation check
        _settleFundingInternal(marketId, account);
        require(this.isLiquidatable(account, marketId), "CH: not liquidatable");
        require(IMarketRegistry(marketRegistry).isActive(marketId), "CH: market not active");
        PositionView storage position = positions[account][marketId];
        {
            uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);
            require(size > 0 && uint256(size) <= absSize, "CH: invalid size");

            // Check remaining position meets min size (prevent dust after partial liquidation)
            uint256 remainingSize = absSize - uint256(size);
            uint256 minSize = marketRiskParams[marketId].minPositionSize;
            if (minSize > 0 && remainingSize > 0) {
                require(remainingSize >= minSize, "CH: remaining below min, liquidate full");
            }
        }

        IMarketRegistry.Market memory m = _getMarketInfo(marketId);

        // Snapshot risk price before the vAMM trade so the penalty is computed
        // against the pre-trade price.  When the oracle is available it is
        // unaffected anyway; when only mark/TWAP remain the trade's own price
        // impact would otherwise distort the penalty calculation.
        uint256 riskPrice = _getRiskPrice(m);

        // Close position via vAMM - scope to free stack
        {
            IVAMM vamm = IVAMM(m.vamm);
            (int256 baseDelta, int256 quoteDelta, ) = position.size > 0
                ? vamm.sellBase(size, priceLimitX18)
                : vamm.buyBase(size, priceLimitX18);
            _applyTrade(account, marketId, baseDelta, quoteDelta, true);
        }

        // Calculate penalty using the pre-trade risk price snapshot
        uint256 notional;
        uint256 penalty;
        {
            notional = Calculations.mulDiv(uint256(size), riskPrice, 1e18);
            penalty = Calculations.mulDiv(notional, marketRiskParams[marketId].liquidationPenaltyBps, BPS_DENOMINATOR);
            if (penalty > marketRiskParams[marketId].penaltyCap) {
                penalty = marketRiskParams[marketId].penaltyCap;
            }
        }
        // Split penalty and process payments
        uint256 liqIncentive;
        uint256 routeAmount;
        uint256 insurancePayout;
        {
            liqIncentive = penalty;
            routeAmount = 0;
            if (m.feeRouter != address(0)) {
                routeAmount = penalty / 2;
                liqIncentive = penalty - routeAmount;
            }

            // Deduct penalty from margin first
            uint256 marginApplied = penalty <= position.margin ? penalty : position.margin;
            if (marginApplied > 0) {
                position.margin -= marginApplied;
                _totalReservedMargin[account] = (_totalReservedMargin[account] >= marginApplied)
                    ? (_totalReservedMargin[account] - marginApplied)
                    : 0;
            }

            // Pay liquidator from collateral, insurance covers shortfall (up to available balance)
            insurancePayout = 0;
            uint256 uncompensatedBadDebt = 0;
            uint256 baseUnit = ICollateralVault(vault).getConfig(m.quoteToken).baseUnit;
            uint256 liqIncentiveInQuote = Calculations.mulDivRoundingUp(liqIncentive, baseUnit, 1e18);
            (, uint256 liqShortfall) = _collectQuote(account, msg.sender, m.quoteToken, liqIncentiveInQuote, false);
            if (liqShortfall > 0) {
                if (m.insuranceFund != address(0)) {
                    uint256 fundBalance = IInsuranceFund(m.insuranceFund).balance();
                    uint256 actualPayout = liqShortfall > fundBalance ? fundBalance : liqShortfall;
                    if (actualPayout > 0) {
                        IInsuranceFund(m.insuranceFund).payout(msg.sender, actualPayout);
                        insurancePayout = actualPayout;
                    }
                    uncompensatedBadDebt = liqShortfall - actualPayout;
                } else {
                    uncompensatedBadDebt = liqShortfall;
                }
            }

            // Track bad debt for later socialization or reporting
            if (uncompensatedBadDebt > 0) {
                totalBadDebt += uncompensatedBadDebt;
                emit BadDebtRecorded(account, marketId, uncompensatedBadDebt);
            }

            // Route protocol share of penalty
            if (routeAmount > 0) {
                _routeLiqPenalty(account, marketId, routeAmount, m);
            }
        }

        emit LiquidationExecuted(
            marketId,
            msg.sender,
            account,
            size,
            notional,
            penalty,
            liqIncentive,
            routeAmount,
            insurancePayout
        );
    }

    /// @notice Internal function to get market information from the registry.
    /// @param marketId The ID of the market.
    /// @return The market struct.
    function _getMarketInfo(bytes32 marketId) internal view returns (IMarketRegistry.Market memory) {
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        require(m.vamm != address(0), "CH: market not found");
        return m;
    }

    /// @notice Returns the preferred risk price for margin checks, preferring oracle/index price with TWAP fallback.
    function _getRiskPrice(IMarketRegistry.Market memory m) internal view returns (uint256) {
        if (m.oracle != address(0)) {
            try IOracle(m.oracle).getPrice() returns (uint256 indexPrice) {
                if (indexPrice > 0) {
                    return indexPrice;
                }
            } catch {}
        }

        require(m.vamm != address(0), "CH: market not found");
        try IVAMM(m.vamm).getTwap(0) returns (uint256 twapPrice) {
            if (twapPrice > 0) {
                return twapPrice;
            }
        } catch {}

        return IVAMM(m.vamm).getMarkPrice();
    }


    /// @notice Gets the position details for a user in a specific market.
    /// @param account The address of the user.
    /// @param marketId The ID of the market.
    /// @return The PositionView struct containing position details.
    function getPosition(address account, bytes32 marketId) external view override returns (PositionView memory) {
        return positions[account][marketId];
    }

    /// @notice Gets the notional value of a user's position in a market.
    /// @param account The address of the user.
    /// @param marketId The ID of the market.
    /// @return The notional value of the position.
    function getNotional(address account, bytes32 marketId) external view override returns (uint256) {
        PositionView storage p = positions[account][marketId];
        if (p.size == 0) return 0;
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (m.vamm == address(0)) return 0;
        uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
        uint256 absSize = uint256(p.size > 0 ? p.size : -p.size);
        return absSize.mulDiv(markPrice, 1e18);
    }

    /// @notice Gets the margin ratio for a user's position.
    /// @param account The address of the user.
    /// @param marketId The ID of the market.
    /// @return The margin ratio ((margin + unrealizedPnL) / notional value). Returns 0 if effective margin is negative.
    ///         Uses oracle (risk) price for consistency with isLiquidatable.
    function getMarginRatio(address account, bytes32 marketId) external view override returns (uint256) {
        PositionView storage p = positions[account][marketId];
        if (p.size == 0) return type(uint256).max;
        uint256 notional = this.getNotional(account, marketId);
        if (notional == 0) return type(uint256).max;
        int256 unrealizedPnL = _getUnrealizedPnLAtOracle(account, marketId);
        int256 effectiveMargin = int256(p.margin) + unrealizedPnL;
        if (effectiveMargin <= 0) return 0;
        return uint256(effectiveMargin).mulDiv(1e18, notional);
    }

    /// @notice Gets the total value of a user's account.
    /// @dev This is a simplification; a full implementation would sum collateral and unrealized PnL across all positions.
    /// @param account The address of the user.
    /// @return The account value.
    function getAccountValue(address account) external view override returns (int256) {
        uint256 collateralValue = ICollateralVault(vault).getAccountCollateralValueX18(account);
        // This is a simplification. A full account value would iterate all positions and calculate unrealized PnL.
        return int256(collateralValue) - int256(_totalReservedMargin[account]);
    }


    /// @notice Pauses or unpauses a market.
    /// @dev Thin wrapper around MarketRegistry's pauseMarket function. Only callable by an admin.
    /// @param marketId The ID of the market.
    /// @param paused True to pause, false to unpause.
    function pauseMarket(bytes32 marketId, bool paused) external override onlyAdmin {
        // Thin wrapper to MarketRegistry
        IMarketRegistry(marketRegistry).pauseMarket(marketId, paused);
        emit MarketPaused(marketId, paused);
    }

    /// @notice Settles funding payments for a user in a perpetual market.
    /// @dev Updates the user's margin based on the funding rate since their last settlement.
    /// @param marketId The ID of the perpetual market.
    /// @param account The address of the user.
    function settleFunding(bytes32 marketId, address account) public override nonReentrant {
        _settleFundingInternal(marketId, account);
    }

    /// @notice Internal funding settlement logic.
    function _settleFundingInternal(bytes32 marketId, address account) internal {
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        require(m.vamm != address(0), "CH: market not found");

        IVAMM vamm = IVAMM(m.vamm);
        vamm.pokeFunding();

        PositionView storage position = positions[account][marketId];
        int256 currentIndex = vamm.cumulativeFundingPerUnitX18();

        if (position.size == 0) {
            position.lastFundingIndex = currentIndex;
            return;
        }

        int256 userIndex = position.lastFundingIndex;
        int256 deltaIndex = currentIndex - userIndex;
        if (deltaIndex != 0) {
            int256 fundingPayment = -(deltaIndex * position.size) / int256(1e18);
            if (fundingPayment > 0) {
                uint256 credit = uint256(fundingPayment);
                position.margin += credit;
                _totalReservedMargin[account] += credit;
            } else if (fundingPayment < 0) {
                uint256 debit = uint256(-fundingPayment);
                if (debit >= position.margin) {
                    // First, drain position margin completely
                    uint256 shortfall = debit - position.margin;
                    _totalReservedMargin[account] = (_totalReservedMargin[account] > position.margin)
                        ? (_totalReservedMargin[account] - position.margin)
                        : 0;
                    position.margin = 0;

                    // Attempt to recover shortfall from free collateral before recording bad debt
                    _recoverShortfall(account, marketId, shortfall);
                } else {
                    position.margin -= debit;
                    _totalReservedMargin[account] -= debit;
                }
            }
            // Settle funding in vault: credit profit / debit loss from actual collateral.
            // Without this, funding only adjusts margin accounting and never moves real balances.
            _settlePnLInVault(account, marketId, fundingPayment);

            emit FundingSettled(marketId, account, fundingPayment);
        }

        position.lastFundingIndex = currentIndex;
    }


    /// @notice Internal function to apply the results of a trade to a user's position.
    /// @dev Updates position size, entry price, realized PnL, and margin. Performs IMR check.
    /// @param account The address of the user.
    /// @param marketId The ID of the market.
    /// @param baseDelta The change in the base asset amount.
    /// @param quoteDelta The change in the quote asset amount.
    /// @param isLiquidation If true, skip fee collection and IMR top-up (liquidation context).
    function _applyTrade(address account, bytes32 marketId, int256 baseDelta, int256 quoteDelta, bool isLiquidation) internal {
        PositionView storage position = positions[account][marketId];
        int256 s0 = position.size;
        int256 s1 = s0 + baseDelta;
        uint256 absBaseDelta = uint256(baseDelta >= 0 ? baseDelta : -baseDelta);
        uint256 absS0 = uint256(s0 >= 0 ? s0 : -s0);
        uint256 absS1 = uint256(s1 >= 0 ? s1 : -s1);
        uint256 absQuote = uint256(quoteDelta >= 0 ? quoteDelta : -quoteDelta);
        uint256 tradeFee = 0; // Track fee for event emission

        // Execution price in 1e18 (avoid division by zero as absBaseDelta>0 when called)
        uint256 execPxX18 = Calculations.mulDiv(absQuote, 1e18, absBaseDelta);

        int256 realized = 0;
        if (s0 == 0) {
            // New position: set entry to execution price
            position.entryPriceX18 = execPxX18;
        } else if ((s0 > 0 && baseDelta > 0) || (s0 < 0 && baseDelta < 0)) {
            // Increasing same direction: weighted average entry
            uint256 oldNotional = absS0 * position.entryPriceX18;
            uint256 newNotional = oldNotional + (absBaseDelta * execPxX18);
            position.entryPriceX18 = newNotional / absS1;
        } else { // Reducing or flipping
            uint256 reduceAmt = absBaseDelta <= absS0 ? absBaseDelta : absS0;
            if (s0 > 0) { // Realizing PnL on a long position
                realized = (int256(execPxX18) - int256(position.entryPriceX18)) * int256(reduceAmt) / 1e18;
            } else { // Realizing PnL on a short position
                realized = (int256(position.entryPriceX18) - int256(execPxX18)) * int256(reduceAmt) / 1e18;
            }

            if (absS1 == 0) { // Closed
                position.entryPriceX18 = 0;
            } else if ((s0 > 0 && s1 < 0) || (s0 < 0 && s1 > 0)) { // Flipped
                position.entryPriceX18 = execPxX18;
            }
        }

        position.size = s1;
        position.realizedPnL += realized;

        // Track active markets for withdrawal checks
        if (s0 == 0 && s1 != 0) {
            // New position opened
            _addActiveMarket(account, marketId);
        } else if (s1 == 0) {
            // Position fully closed
            _removeActiveMarket(account, marketId);
        }

        // === Settle realized PnL in collateral ===
        // Credits profit to user's vault balance; debits loss from it.
        // This ensures PnL is reflected in withdrawable collateral, not just margin accounting.
        if (realized != 0) {
            _settlePnLInVault(account, marketId, realized);
        }

        // === Margin management (independent of PnL) ===
        if (s0 == 0 || ((s0 > 0 && baseDelta > 0) || (s0 < 0 && baseDelta < 0))) {
            // Opening or increasing: allocate IMR margin from available collateral
            uint256 tradeNotional = Calculations.mulDiv(absBaseDelta, execPxX18, 1e18);
            uint256 imrBps = marketRiskParams[marketId].imrBps;
            uint256 marginRequired = Calculations.mulDiv(tradeNotional, imrBps, BPS_DENOMINATOR);
            position.margin += marginRequired;
            _totalReservedMargin[account] += marginRequired;
        } else {
            // Reducing or closing: release margin proportionally to size reduction
            uint256 reduceAmt = absBaseDelta <= absS0 ? absBaseDelta : absS0;
            uint256 marginRelease = (position.margin * reduceAmt) / absS0;
            position.margin -= marginRelease;
            _totalReservedMargin[account] -= marginRelease;
        }

        // Protocol trading fee for perps: charge on this trade's notional at execPx
        // Fees are collected directly from available collateral before the IMR check so
        // that position margin remains intact for the risk assessment.
        // Skip fee collection during liquidation to prevent blocking liquidation of underwater users.
        if (!isLiquidation && absBaseDelta > 0) {
            IMarketRegistry.Market memory m2 = IMarketRegistry(marketRegistry).getMarket(marketId);
            if (m2.feeBps > 0) {
                uint256 notional2 = Calculations.mulDiv(absBaseDelta, execPxX18, 1e18);
                if (notional2 > 0) {
                    tradeFee = Calculations.mulDiv(notional2, m2.feeBps, BPS_DENOMINATOR);
                    if (tradeFee > 0) {
                        _ensureAvailableCollateral(account, tradeFee, m2.quoteToken);
                        _routeTradeFee(account, tradeFee, m2);
                    }
                }
            }
        }

        // Post-trade IMR check. This is the most critical check.
        // It ensures the remaining margin is sufficient for the new/updated position AFTER fees.
        // Skip during liquidation: liquidated users cannot meet IMR and the check would block liquidation.
        if (!isLiquidation && absS1 > 0) {
            uint256 imrBps = marketRiskParams[marketId].imrBps;
            IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
            uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
            uint256 oraclePrice = _getRiskPrice(m);
            uint256 imrPrice = markPrice > oraclePrice ? markPrice : oraclePrice;
            uint256 notional = absS1.mulDiv(imrPrice, 1e18);
            uint256 requiredMargin = notional.mulDiv(imrBps, BPS_DENOMINATOR);
            if (position.margin < requiredMargin) {
                uint256 shortfall = requiredMargin - position.margin;
                _ensureAvailableCollateral(account, shortfall, m.quoteToken);
                position.margin += shortfall;
                _totalReservedMargin[account] += shortfall;
            }
            require(position.margin >= requiredMargin, "CH: IMR breach");

            // Post-trade health check: ensure position is NOT immediately liquidatable.
            // IMR only checks raw margin vs required margin. But unrealized PnL (from the
            // trade's price impact) can make effective margin fall below maintenance margin,
            // leaving the position immediately liquidatable after opening.
            // Use oracle/risk price for consistency with isLiquidatable().
            {
                int256 unrealizedPnL = _computeUnrealizedPnL(position, oraclePrice);
                int256 effectiveMargin = int256(position.margin) + unrealizedPnL;
                uint256 riskNotional = absS1.mulDiv(oraclePrice, 1e18);
                uint256 maintenanceMargin = riskNotional.mulDiv(marketRiskParams[marketId].mmrBps, BPS_DENOMINATOR);
                require(effectiveMargin >= int256(maintenanceMargin), "CH: immediately liquidatable");
            }
        }
        
        // Emit trade executed event
        emit TradeExecuted(
            account,
            marketId,
            baseDelta,
            quoteDelta,
            execPxX18,
            s1,
            position.margin,
            realized,
            tradeFee
        );
    }


    /// @dev Attempt to seize quote collateral up to `amount` for a recipient. Returns actual received and shortfall.
    /// @param account The account to seize from.
    /// @param recipient The recipient of the seized collateral.
    /// @param quoteToken The token to seize.
    /// @param amount The amount to seize.
    /// @param withdrawToRecipient If true, withdraws tokens to recipient address (actual transfer).
    /// @return actualReceived The actual amount received by recipient (accounts for fee-on-transfer).
    /// @return shortfall The amount that could not be seized due to insufficient balance.
    function _collectQuote(
        address account,
        address recipient,
        address quoteToken,
        uint256 amount,
        bool withdrawToRecipient
    ) internal returns (uint256 actualReceived, uint256 shortfall) {
        if (amount == 0) {
            return (0, 0);
        }

        uint256 available = ICollateralVault(vault).balanceOf(account, quoteToken);
        uint256 seized = amount <= available ? amount : available;
        actualReceived = seized; // Default: internal transfer, no fee

        if (seized > 0) {
            ICollateralVault(vault).seize(account, recipient, quoteToken, seized);
            if (withdrawToRecipient) {
                // withdrawFor returns actual received amount (fee-on-transfer support)
                actualReceived = ICollateralVault(vault).withdrawFor(recipient, quoteToken, seized, recipient);
            }
        }
        shortfall = amount - seized;
    }

    /// @notice Whitelists an address, allowing it to call liquidation functions.
    /// @param liquidator The address to whitelist.
    /// @param isWhitelisted The whitelist status.
    function setWhitelistedLiquidator(address liquidator, bool isWhitelisted) external onlyAdmin {
        WhitelistedLiquidators[liquidator] = isWhitelisted;
        emit LiquidatorWhitelistUpdated(liquidator, isWhitelisted);
    }

    /// @notice Emergency admin function to clear stuck positions and reserved margin after vault migration.
    /// @dev This is needed when _totalReservedMargin has stale data from old vault, causing negative account values.
    /// @param user The address whose stuck position to clear.
    /// @param marketId The market ID of the stuck position.
    function adminClearStuckPosition(address user, bytes32 marketId) external onlyAdmin {
        require(user != address(0), "CH: invalid user");

        PositionView storage position = positions[user][marketId];

        // Only allow clearing positions with size = 0 (already closed)
        require(position.size == 0, "CH: position has size");

        // Store old values for event
        uint256 oldMargin = position.margin;
        uint256 oldReservedMargin = _totalReservedMargin[user];

        // Clear the position's reserved margin (clamp to avoid underflow in inconsistent state)
        if (position.margin > 0) {
            _totalReservedMargin[user] = _totalReservedMargin[user] >= position.margin
                ? _totalReservedMargin[user] - position.margin
                : 0;
            position.margin = 0;
        }

        // Reset other position fields
        position.entryPriceX18 = 0;
        position.lastFundingIndex = 0;
        position.realizedPnL = 0;

        emit PositionCleared(user, marketId, oldMargin, oldReservedMargin, _totalReservedMargin[user]);
    }

    /// @notice Event emitted when an admin clears a stuck position.
    event PositionCleared(
        address indexed user,
        bytes32 indexed marketId,
        uint256 clearedMargin,
        uint256 oldReservedMargin,
        uint256 newReservedMargin
    );

    // ===== Internal helpers (Active Markets Tracking) =====
    /// @notice Adds a market to user's active markets list if not already present.
    function _addActiveMarket(address user, bytes32 marketId) internal {
        if (!_isMarketActive[user][marketId]) {
            _userActiveMarkets[user].push(marketId);
            _isMarketActive[user][marketId] = true;
        }
    }

    /// @notice Removes a market from user's active markets list.
    function _removeActiveMarket(address user, bytes32 marketId) internal {
        if (_isMarketActive[user][marketId]) {
            bytes32[] storage markets = _userActiveMarkets[user];
            for (uint256 i = 0; i < markets.length; i++) {
                if (markets[i] == marketId) {
                    
                    markets[i] = markets[markets.length - 1];
                    markets.pop();
                    break;
                }
            }
            _isMarketActive[user][marketId] = false;
        }
    }

    /// @notice Returns user's active market IDs.
    function getUserActiveMarkets(address user) external view returns (bytes32[] memory) {
        return _userActiveMarkets[user];
    }

    // ===== Internal helpers (Quote Collateral Valuation) =====

    /// @notice Returns the total USD value of quote-token-only collateral for a user.
    /// @dev Iterates active markets to identify quote tokens. Only these tokens
    ///      are counted for margin backing, preventing non-quote collateral from
    ///      backing margin that can only be settled in the quote token.
    function _getQuoteCollateralValueX18(address account) internal view returns (uint256 totalValue) {
        bytes32[] memory markets = _userActiveMarkets[account];
        uint256 numMarkets = markets.length;
        if (numMarkets == 0) return 0;

        address[] memory seen = new address[](numMarkets);
        uint256 seenCount;

        for (uint256 i = 0; i < numMarkets; i++) {
            address qt = IMarketRegistry(marketRegistry).getMarket(markets[i]).quoteToken;
            bool isDuplicate;
            for (uint256 j = 0; j < seenCount; j++) {
                if (seen[j] == qt) { isDuplicate = true; break; }
            }
            if (!isDuplicate) {
                seen[seenCount++] = qt;
                uint256 bal = ICollateralVault(vault).balanceOf(account, qt);
                if (bal > 0) {
                    totalValue += _quoteValueX18(qt, bal);
                }
            }
        }
    }

    /// @notice Checks if a token is the quote token of any of the user's active markets.
    function _isQuoteTokenInActiveMarkets(address account, address token) internal view returns (bool) {
        bytes32[] memory markets = _userActiveMarkets[account];
        for (uint256 i = 0; i < markets.length; i++) {
            if (IMarketRegistry(marketRegistry).getMarket(markets[i]).quoteToken == token) {
                return true;
            }
        }
        return false;
    }

    // ===== Internal helpers (Bad Debt Recovery) =====
    /// @notice Attempts to recover a shortfall from user's free collateral before recording bad debt.
    /// @param account The user's address.
    /// @param marketId The market ID for the bad debt event.
    /// @param shortfall The amount that needs to be recovered.
    function _recoverShortfall(address account, bytes32 marketId, uint256 shortfall) internal {
        if (shortfall == 0) return;

        uint256 quoteCollateralValue = _getQuoteCollateralValueX18(account);
        uint256 freeCollateral = quoteCollateralValue > _totalReservedMargin[account]
            ? quoteCollateralValue - _totalReservedMargin[account]
            : 0;
        uint256 recovered = shortfall > freeCollateral ? freeCollateral : shortfall;

        if (recovered > 0) {
            _totalReservedMargin[account] += recovered;
            positions[account][marketId].margin += recovered;
        }

        uint256 finalBadDebt = shortfall - recovered;
        if (finalBadDebt > 0) {
            emit BadDebtRecorded(account, marketId, finalBadDebt);
        }
    }

    // ===== Internal helpers (PnL Settlement) =====
    /// @notice Settles realized PnL by crediting or debiting the user's vault balance.
    /// @dev On profit, credits the user's vault (backed by counterparty losses in the vAMM).
    ///      On loss, debits the user's vault; any shortfall is recorded as bad debt.
    /// @param account The user's address.
    /// @param marketId The market ID (for quote token lookup and bad debt events).
    /// @param realized The realized PnL in 1e18 precision (positive = profit, negative = loss).
    function _settlePnLInVault(address account, bytes32 marketId, int256 realized) internal {
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        uint256 baseUnit = ICollateralVault(vault).getConfig(m.quoteToken).baseUnit;

        if (realized > 0) {
            uint256 profitInQuote = Calculations.mulDiv(uint256(realized), baseUnit, 1e18);
            if (profitInQuote > 0) {
                ICollateralVault(vault).settlePnL(account, m.quoteToken, int256(profitInQuote));
            }
        } else {
            uint256 lossInQuote = Calculations.mulDivRoundingUp(uint256(-realized), baseUnit, 1e18);
            if (lossInQuote > 0) {
                uint256 available = ICollateralVault(vault).balanceOf(account, m.quoteToken);
                if (lossInQuote > available) {
                    uint256 badDebt = lossInQuote - available;
                    lossInQuote = available;
                    totalBadDebt += badDebt;
                    emit BadDebtRecorded(account, marketId, badDebt);
                }
                if (lossInQuote > 0) {
                    ICollateralVault(vault).settlePnL(account, m.quoteToken, -int256(lossInQuote));
                }
            }
        }
    }

    // ===== Internal helpers (Fees) =====
    /// @notice Internal function to route trade fees to the fee router.
    /// @param account The user's address.
    /// @param fee The fee amount in 1e18 precision.
    /// @param m The market struct.
    function _routeTradeFee(
        address account,
        uint256 fee,
        IMarketRegistry.Market memory m
    ) internal {
        if (fee == 0 || m.feeRouter == address(0)) return;

        // Convert fee from 1e18 to quote token's native decimals using rounding up
        // to prevent precision loss for small fees (e.g., USDC with 6 decimals)
        uint256 baseUnit = ICollateralVault(vault).getConfig(m.quoteToken).baseUnit;
        uint256 feeInQuoteDecimals = Calculations.mulDivRoundingUp(fee, baseUnit, 1e18);

        
        if (feeInQuoteDecimals == 0) return;

        (uint256 actualReceived, uint256 shortfall) = _collectQuote(account, m.feeRouter, m.quoteToken, feeInQuoteDecimals, true);
        require(shortfall == 0, "CH: insufficient quote token for fee");
        IFeeRouter(m.feeRouter).onTradeFee(actualReceived);
    }

    /// @notice Ensures the account has sufficient free quote-token collateral to cover additional reservations.
    /// @dev Only counts the specified quote token's balance, preventing non-quote tokens
    ///      from backing margin that can only be settled in the quote token.
    /// @param account The user's address.
    /// @param amount The additional amount to reserve (1e18 precision).
    /// @param quoteToken The market's quote token to check balance of.
    function _ensureAvailableCollateral(address account, uint256 amount, address quoteToken) internal view {
        if (amount == 0) return;
        uint256 quoteBalance = ICollateralVault(vault).balanceOf(account, quoteToken);
        uint256 quoteValueX18 = _quoteValueX18(quoteToken, quoteBalance);
        require(quoteValueX18 >= _totalReservedMargin[account] + amount, "CH: insufficient quote collateral");
    }

    /// @notice Oracle-resilient valuation for a quote token amount.
    /// @dev Tries the vault's oracle-based valuation first. If the oracle reverts
    ///      (sequencer down, stale feed, etc.), falls back to baseUnit normalization
    ///      assuming the quote token ≈ $1. This prevents false bad debt and frozen
    ///      positions during temporary oracle outages.
    function _quoteValueX18(address quoteToken, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        try ICollateralVault(vault).getTokenValueX18(quoteToken, amount) returns (uint256 v) {
            return v;
        } catch {
            uint256 baseUnit = ICollateralVault(vault).getConfig(quoteToken).baseUnit;
            return (amount * 1e18) / baseUnit;
        }
    }

    /// @notice Internal function to route liquidation penalties.
    /// @param account The user's address.
    /// @param amount The penalty amount in 1e18 precision.
    /// @param m The market struct.
    function _routeLiqPenalty(
        address account,
        bytes32 marketId,
        uint256 amount,
        IMarketRegistry.Market memory m
    ) internal {
        if (amount == 0 || m.feeRouter == address(0)) return;

        // Convert penalty from 1e18 to quote token's native decimals using rounding up
        // to prevent precision loss for small amounts (e.g., USDC with 6 decimals)
        uint256 baseUnit = ICollateralVault(vault).getConfig(m.quoteToken).baseUnit;
        uint256 penaltyInQuoteDecimals = Calculations.mulDivRoundingUp(amount, baseUnit, 1e18);

        
        if (penaltyInQuoteDecimals == 0) return;

        (uint256 actualReceived, uint256 shortfall) = _collectQuote(account, m.feeRouter, m.quoteToken, penaltyInQuoteDecimals, true);
        uint256 insuranceCovered = 0;
        if (shortfall > 0 && m.insuranceFund != address(0)) {
            uint256 fundBalance = IInsuranceFund(m.insuranceFund).balance();
            uint256 actualPayout = shortfall > fundBalance ? fundBalance : shortfall;
            if (actualPayout > 0) {
                IInsuranceFund(m.insuranceFund).payout(m.feeRouter, actualPayout);
                insuranceCovered = actualPayout;
            }
            uint256 uncovered = shortfall - actualPayout;
            if (uncovered > 0) {
                totalBadDebt += uncovered;
                emit BadDebtRecorded(account, marketId, uncovered);
            }
        } else if (shortfall > 0) {
            totalBadDebt += shortfall;
            emit BadDebtRecorded(account, marketId, shortfall);
        }

        IFeeRouter(m.feeRouter).onLiquidationPenalty(actualReceived + insuranceCovered);
    }
}