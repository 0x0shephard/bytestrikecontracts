//SPDX-License-Identifier:MIT
pragma solidity 0.8.28;

import {IClearingHouse} from "./Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "./Interfaces/ICollateralVault.sol";
import {IMarketRegistry} from "./Interfaces/IMarketRegistry.sol";
import {IVAMM} from "./Interfaces/IVAMM.sol";
import {IOracle} from "./Interfaces/IOracle.sol";
import {Calculations} from "./Libraries/Calculations.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IInsuranceFund} from "./Interfaces/IInsuranceFund.sol";
import {IFeeRouter} from "./Interfaces/IFeeRouter.sol";

/// @notice The central contract for managing user positions, margin, and trade settlement for perpetual vAMM markets.
/// @dev It interacts with various components like the CollateralVault, MarketRegistry, and vAMMs.
contract ClearingHouse is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardTransient, IClearingHouse {
    using Calculations for uint256;

    // =========================================================================
    // Storage layout (slots 0-10) — must match ClearingHouseLogic exactly.
    // Do NOT reorder or insert variables without updating ClearingHouseLogic.
    // =========================================================================

    /// @notice Address of the collateral vault contract.
    address public vault;           // slot 0
    /// @notice Address of the market registry contract.
    address public marketRegistry;  // slot 1

    /// @notice Mapping of whitelisted liquidator addresses.
    mapping(address user => bool isWhitelisted) public whitelistedLiquidators; // slot 2
    /// @notice Mapping from user address to their position in a specific market.
    mapping(address user => mapping(bytes32 marketId => PositionView)) public positions; // slot 3
    /// @notice Mapping of total margin reserved by a user across all their positions.
    mapping(address user => uint256 amount) public _totalReservedMargin; // slot 4
    /// @notice Mapping of risk parameters for each market.
    mapping(bytes32 marketId => MarketRiskParams) public marketRiskParams; // slot 5
    /// @notice Mapping of active market IDs per user for withdrawal checks.
    mapping(address user => bytes32[] marketIds) private _userActiveMarkets; // slot 6
    /// @notice Helper mapping to check if a market is in user's active list.
    mapping(address user => mapping(bytes32 marketId => bool)) private _isMarketActive; // slot 7

    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Precision for price and value calculations (1e18)
    uint256 public constant PRECISION = 1e18;

    /// @notice Total uncompensated bad debt accumulated across all liquidations
    uint256 public totalBadDebt; // slot 8

    /// @notice Total long open interest per market (base units, 1e18).
    mapping(bytes32 marketId => uint256) public totalLongOI; // slot 9
    /// @notice Total short open interest per market (base units, 1e18).
    mapping(bytes32 marketId => uint256) public totalShortOI; // slot 10

    // =========================================================================
    // Logic contract (immutable — embedded in implementation bytecode, not proxy storage)
    // =========================================================================

    /// @notice Address of ClearingHouseLogic — called via delegatecall for heavy functions.
    address private immutable _logic;

    // Custom errors
    error AmountZero();
    error BelowMinSize();
    error ExceedsMaxSize();
    error HasLiquidatablePosition();
    error IMRBelowMMR();
    error IMRBreach();
    error ImmediatelyLiquidatable();
    error InsufficientBalance();
    error InsufficientMargin();
    error InsufficientQuoteBalance();
    error InsufficientQuoteCollateral();
    error InsufficientQuoteForFee();
    error InvalidAdmin();
    error InvalidRegistry();
    error InvalidSize();
    error InvalidVault();
    error MMRZero();
    error MarginBelowPenalty();
    error MarketNotActive();
    error MarketNotFound();
    error MinExceedsMax();
    error MustLiquidateMore();
    error NoPosition();
    error NotAdmin();
    error NotLiquidatable();
    error NotWhitelistedLiquidator();
    error OracleNotSet();
    error OraclePriceZero();
    error PositionLiquidatable();
    error QuoteOracleUnavailable();
    error QuoteTokenValuationUnavailable();
    error ReduceExceedsPosition();
    error RemainingBelowMinCloseFull();
    error RemainingBelowMinLiquidateFull();
    error RiskParamsNotSet();
    error SizeZero();
    error WouldBeLiquidatable();
    error ZeroAddress();

    /// @notice Modifier to restrict access to admin roles.
    modifier onlyAdmin() {
        if (!(owner() == msg.sender)) revert NotAdmin();
        _;
    }

    /// @notice Modifier to restrict access to whitelisted liquidators.
    modifier onlyWhitelistedLiquidator() {
        if (!(whitelistedLiquidators[msg.sender])) revert NotWhitelistedLiquidator();
        _;
    }

    constructor(address logic) {
        _logic = logic;
        _disableInitializers();
    }

    /// @notice Initializer replacing constructor for upgradeable deployment.
    /// @param _vault The address of the CollateralVault contract.
    /// @param _marketRegistry The address of the MarketRegistry contract.
    /// @param admin The address that will receive the default admin role.
    function initialize(address _vault, address _marketRegistry, address admin) external initializer {
        if (!(_vault != address(0))) revert InvalidVault();
        if (!(_marketRegistry != address(0))) revert InvalidRegistry();
        if (!(admin != address(0))) revert InvalidAdmin();

        __Ownable_init(admin);

        vault = _vault;
        marketRegistry = _marketRegistry;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}


    /// @notice Deposits collateral into the vault for the caller.
    /// @param token The address of the ERC20 token to deposit.
    /// @param amount The amount of the token to deposit.
    function deposit(address token, uint256 amount) external override nonReentrant {
        if (!(amount > 0)) revert AmountZero();
        ICollateralVault(vault).deposit(token, amount, msg.sender);
        emit CollateralDeposited(msg.sender, token, amount);
    }

    /// @notice Withdraws collateral from the vault for the caller.
    /// @dev Checks that the withdrawal does not compromise the user's total reserved margin
    ///      and that no positions would become liquidatable after withdrawal.
    /// @param token The address of the ERC20 token to withdraw.
    /// @param amount The amount of the token to withdraw.
    function withdraw(address token, uint256 amount) external override nonReentrant {
        if (!(amount > 0)) revert AmountZero();

        // Settle funding for all active markets to ensure margin values are current
        bytes32[] memory markets = _userActiveMarkets[msg.sender];
        for (uint256 i = 0; i < markets.length; i++) {
            _settleFundingInternal(markets[i], msg.sender);
        }

        // Ensure the withdrawn token's remaining balance still covers all margin
        // reserved against it.
        uint256 reservedForToken = _reservedMarginForToken(msg.sender, token);
        if (reservedForToken > 0) {
            uint256 balAfter = ICollateralVault(vault).balanceOf(msg.sender, token);
            if (!(balAfter >= amount)) revert InsufficientBalance();
            uint256 valueAfter = _quoteValueX18(token, balAfter - amount);
            if (!(valueAfter >= reservedForToken)) revert InsufficientQuoteCollateral();
        }

        // withdrawFor returns actual received amount (fee-on-transfer support)
        uint256 received = ICollateralVault(vault).withdrawFor(msg.sender, token, amount, msg.sender);

        // Post-withdrawal check: ensure no positions become liquidatable
        for (uint256 i = 0; i < markets.length; i++) {
            if (_isLiquidatable(msg.sender, markets[i])) revert WouldBeLiquidatable();
        }

        emit CollateralWithdrawn(msg.sender, token, amount, received);
    }

    /// @notice Adds margin to a specific position from the user's available collateral.
    /// @param marketId The ID of the market for the position.
    /// @param amount The amount of margin to add (in quote currency value, 1e18).
    function addMargin(bytes32 marketId, uint256 amount) external override {
        _settleFundingInternal(marketId, msg.sender);
        if (!(amount > 0)) revert AmountZero();
        if (!(IMarketRegistry(marketRegistry).isActive(marketId))) revert MarketNotActive();
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        uint256 quoteBalance = ICollateralVault(vault).balanceOf(msg.sender, m.quoteToken);
        uint256 quoteValueX18 = _quoteValueX18(m.quoteToken, quoteBalance);
        uint256 reservedForToken = _reservedMarginForToken(msg.sender, m.quoteToken);
        if (!(amount <= quoteValueX18 - reservedForToken)) revert InsufficientQuoteBalance();
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
        if (!(amount > 0)) revert AmountZero();
        if (!(IMarketRegistry(marketRegistry).isActive(marketId))) revert MarketNotActive();
        PositionView storage position = positions[msg.sender][marketId];
        if (!(position.margin >= amount)) revert InsufficientMargin();
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
        // Use real-time collateral value for the margin component
        uint256 nominalAfter = position.margin - amount;
        uint256 marginValueAfter = nominalAfter;
        {
            uint256 reserved = _reservedMarginForToken(msg.sender, m.quoteToken);
            if (reserved > 0) {
                uint256 vaultBal = ICollateralVault(vault).balanceOf(msg.sender, m.quoteToken);
                uint256 vaultValX18 = _quoteValueX18(m.quoteToken, vaultBal);
                if (vaultValX18 < reserved) {
                    marginValueAfter = Calculations.mulDiv(nominalAfter, vaultValX18, reserved);
                }
            }
        }
        int256 effectiveMarginAfter = int256(marginValueAfter) + unrealizedPnL;
        if (!(effectiveMarginAfter >= int256(maintenanceMargin))) revert WouldBeLiquidatable();

        // Enforce minimum margin floor: position margin must always cover the liquidation penalty
        if (position.size != 0) {
            uint256 minMargin = _getLiquidationPenalty(msg.sender, marketId);
            if (!(position.margin - amount >= minMargin)) revert MarginBelowPenalty();
        }

        position.margin -= amount;
        _totalReservedMargin[msg.sender] -= amount;
        emit MarginRemoved(msg.sender, marketId, amount);
    }


    /// @notice Checks if an account's position in a given market is subject to liquidation.
    /// @param account The address of the user.
    /// @param marketId The ID of the market.
    /// @return A boolean indicating if the position is liquidatable.
    function isLiquidatable(address account, bytes32 marketId) external view override returns (bool) {
        return _isLiquidatable(account, marketId);
    }

    function _isLiquidatable(address account, bytes32 marketId) internal view returns (bool) {
        PositionView storage position = positions[account][marketId];
        if (position.size == 0) return false;

        // Include unsettled funding in effective margin so off-chain callers
        // (keepers, UIs) see accurate liquidation status without requiring
        // a prior settleFunding transaction.
        int256 pendingFunding = _getPendingFunding(account, marketId);

        // Use real-time collateral value for the margin component so that a
        // depeg of the quote token triggers liquidation instead of being masked
        // by a stale nominal position.margin value.
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        uint256 marginValue = position.margin;
        {
            uint256 reserved = _reservedMarginForToken(account, m.quoteToken);
            if (reserved > 0) {
                uint256 vaultBal = ICollateralVault(vault).balanceOf(account, m.quoteToken);
                uint256 vaultValX18 = _quoteValueX18(m.quoteToken, vaultBal);
                if (vaultValX18 < reserved) {
                    marginValue = Calculations.mulDiv(position.margin, vaultValX18, reserved);
                }
            }
        }

        // Calculate effective margin including unrealized PnL at oracle (risk) price
        int256 unrealizedPnL = _getUnrealizedPnLAtOracle(account, marketId);
        int256 effectiveMargin = int256(marginValue) + pendingFunding + unrealizedPnL;

        // Position is liquidatable if effective margin falls below maintenance margin
        uint256 maintenanceMargin = _getMaintenanceMargin(account, marketId);
        return effectiveMargin < int256(maintenanceMargin);
    }

    /// @notice Sets the risk parameters for a market.
    function setRiskParams(
        bytes32 marketId,
        uint256 imrBps,
        uint256 mmrBps,
        uint256 liquidationPenaltyBps,
        uint256 penaltyCap,
        uint256 maxPositionSize,
        uint256 minPositionSize
    ) external override onlyAdmin {
        if (!(IMarketRegistry(marketRegistry).getMarket(marketId).vamm != address(0))) revert MarketNotFound();
        if (!(imrBps >= mmrBps)) revert IMRBelowMMR();
        if (!(mmrBps > 0)) revert MMRZero();
        if (!(minPositionSize <= maxPositionSize || maxPositionSize == 0)) revert MinExceedsMax();

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

    /// @notice Internal function to calculate the maintenance margin for a position.
    function _getMaintenanceMargin(address account, bytes32 marketId) internal view returns (uint256) {
        PositionView storage position = positions[account][marketId];
        if (position.size == 0) {
            return 0;
        }

        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (!(m.vamm != address(0))) revert MarketNotFound();

        uint256 mmrBps = marketRiskParams[marketId].mmrBps;
        uint256 positionSize = uint256(position.size > 0 ? position.size : -position.size);
        uint256 riskPrice = _getRiskPrice(m);
        uint256 notionalValue = Calculations.mulDivRoundingUp(positionSize, riskPrice, 1e18);
        return Calculations.mulDivRoundingUp(notionalValue, mmrBps, BPS_DENOMINATOR);
    }

    /// @notice Computes the liquidation penalty for a position using the same formula as liquidate().
    function _getLiquidationPenalty(address account, bytes32 marketId) internal view returns (uint256) {
        PositionView storage position = positions[account][marketId];
        if (position.size == 0) return 0;

        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        uint256 riskPrice = _getRiskPrice(m);
        uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);
        uint256 notional = Calculations.mulDivRoundingUp(absSize, riskPrice, 1e18);
        uint256 penalty = Calculations.mulDivRoundingUp(notional, marketRiskParams[marketId].liquidationPenaltyBps, BPS_DENOMINATOR);
        uint256 cap = marketRiskParams[marketId].penaltyCap;
        if (cap > 0 && penalty > cap) {
            penalty = cap;
        }
        return penalty;
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
    function _getPendingFunding(address account, bytes32 marketId) internal view returns (int256) {
        PositionView storage position = positions[account][marketId];
        if (position.size == 0) return 0;

        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (m.vamm == address(0)) return 0;

        uint256 currentPay;
        uint256 currentReceive;
        if (position.size > 0) {
            currentPay = IVAMM(m.vamm).currentCumulativeLongPayPerUnitX18();
            currentReceive = IVAMM(m.vamm).currentCumulativeLongReceivePerUnitX18();
        } else {
            currentPay = IVAMM(m.vamm).currentCumulativeShortPayPerUnitX18();
            currentReceive = IVAMM(m.vamm).currentCumulativeShortReceivePerUnitX18();
        }

        uint256 payDelta = currentPay - position.lastFundingPayIndex;
        uint256 receiveDelta = currentReceive - position.lastFundingReceiveIndex;
        if (payDelta == 0 && receiveDelta == 0) return 0;

        uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);
        if (receiveDelta >= payDelta) {
            return int256(Calculations.mulDiv(receiveDelta - payDelta, absSize, 1e18));
        } else {
            return -int256(Calculations.mulDiv(payDelta - receiveDelta, absSize, 1e18));
        }
    }

    /// @notice Shared helper to compute unrealized PnL from a provided price.
    function _computeUnrealizedPnL(PositionView storage position, uint256 priceX18) internal view returns (int256) {
        int256 size = position.size;
        uint256 entryPrice = position.entryPriceX18;
        if (priceX18 == 0 || size == 0 || entryPrice == 0) {
            return 0;
        }

        uint256 absSize = uint256(size > 0 ? size : -size);
        if (size > 0) {
            // Long position: PnL = (price - entry) * size
            return (int256(priceX18) - int256(entryPrice)) * int256(absSize) / 1e18;
        } else {
            // Short position: PnL = (entry - price) * size
            return (int256(entryPrice) - int256(priceX18)) * int256(absSize) / 1e18;
        }
    }


    /// @notice Opens a new position or increases an existing one in a perpetual market.
    /// @param marketId The ID of the perpetual market.
    /// @param isLong True for a long position, false for a short position.
    /// @param size The amount of base asset to trade.
    /// @param amountLimit For longs (buying base): max quote to spend. For shorts (selling base): min quote to receive. 0 = no limit.
    function openPosition(bytes32 marketId, bool isLong, uint128 size, uint256 amountLimit) external override nonReentrant {
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
            if (_isLiquidatable(msg.sender, activeMarkets[i])) revert HasLiquidatablePosition();
        }

        if (!(IMarketRegistry(marketRegistry).isActive(marketId))) revert MarketNotActive();
        if (!(marketRiskParams[marketId].mmrBps > 0)) revert RiskParamsNotSet();
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (!(m.vamm != address(0))) revert MarketNotFound();
        if (!(size > 0)) revert SizeZero();

        IVAMM vamm = IVAMM(m.vamm);
        (int256 baseDelta, int256 quoteDelta, uint256 avgPrice) = isLong
            ? vamm.buyBase(size, amountLimit)
            : vamm.sellBase(size, amountLimit);

        _applyTrade(msg.sender, marketId, baseDelta, quoteDelta, false);

        // Check position size limits
        PositionView storage position = positions[msg.sender][marketId];
        uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);

        MarketRiskParams memory rp = marketRiskParams[marketId];

        // Check max position size (0 = unlimited)
        uint256 maxSize = rp.maxPositionSize;
        if (maxSize > 0) {
            if (!(absSize <= maxSize)) revert ExceedsMaxSize();
        }

        // Check min position size (0 = no minimum)
        uint256 minSize = rp.minPositionSize;
        if (minSize > 0 && absSize > 0) {
            if (!(absSize >= minSize)) revert BelowMinSize();
        }

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
    /// @param amountLimit For closing longs (selling base): min quote to receive. For closing shorts (buying base): max quote to spend. 0 = no limit.
    function closePosition(bytes32 marketId, uint128 size, uint256 amountLimit) external override nonReentrant {
        // Settle funding for all active markets so vault balances and
        // _totalReservedMargin are current before any shortfall recovery.
        bytes32[] memory activeMarkets = _userActiveMarkets[msg.sender];
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            _settleFundingInternal(activeMarkets[i], msg.sender);
        }
        if (activeMarkets.length == 0 || !_isMarketActive[msg.sender][marketId]) {
            _settleFundingInternal(marketId, msg.sender);
        }
        if (_isLiquidatable(msg.sender, marketId)) revert PositionLiquidatable();
        if (!(IMarketRegistry(marketRegistry).isActive(marketId))) revert MarketNotActive();
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (!(m.vamm != address(0))) revert MarketNotFound();
        if (!(size > 0)) revert SizeZero();

        PositionView storage position = positions[msg.sender][marketId];
        if (!(position.size != 0)) revert NoPosition();
        uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);
        if (!(uint256(size) <= absSize)) revert ReduceExceedsPosition();

        IVAMM vamm = IVAMM(m.vamm);
        // If long, sell base to close; if short, buy base to close
        (int256 baseDelta, int256 quoteDelta, uint256 avgPrice) = position.size > 0
            ? vamm.sellBase(size, amountLimit)
            : vamm.buyBase(size, amountLimit);

        // Store realized PnL before applying trade
        int256 oldRealizedPnL = position.realizedPnL;
        _applyTrade(msg.sender, marketId, baseDelta, quoteDelta, false);

        // Enforce minPositionSize on remaining position to prevent dust
        {
            uint256 remainingSize = uint256(position.size > 0 ? position.size : -position.size);
            uint256 minSize = marketRiskParams[marketId].minPositionSize;
            if (minSize > 0 && remainingSize > 0) {
                if (!(remainingSize >= minSize)) revert RemainingBelowMinCloseFull();
            }
        }

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
    function liquidate(address account, bytes32 marketId, uint128 size, uint256 amountLimit) external override nonReentrant onlyWhitelistedLiquidator {
        // Settle funding for all active markets so vault balances and
        // _totalReservedMargin are current before any shortfall recovery.
        bytes32[] memory userMarkets = _userActiveMarkets[account];
        for (uint256 i = 0; i < userMarkets.length; i++) {
            _settleFundingInternal(userMarkets[i], account);
        }
        if (userMarkets.length == 0 || !_isMarketActive[account][marketId]) {
            _settleFundingInternal(marketId, account);
        }
        if (!_isLiquidatable(account, marketId)) revert NotLiquidatable();
        if (!(IMarketRegistry(marketRegistry).isActive(marketId))) revert MarketNotActive();
        PositionView storage position = positions[account][marketId];
        MarketRiskParams memory rp = marketRiskParams[marketId];
        {
            uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);
            if (!(size > 0 && uint256(size) <= absSize)) revert InvalidSize();

            // Check remaining position meets min size (prevent dust after partial liquidation)
            uint256 remainingSize = absSize - uint256(size);
            if (rp.minPositionSize > 0 && remainingSize > 0) {
                if (!(remainingSize >= rp.minPositionSize)) revert RemainingBelowMinLiquidateFull();
            }
        }

        IMarketRegistry.Market memory m = _getMarketInfo(marketId);

        // Snapshot risk price before the vAMM trade
        uint256 riskPrice = _getRiskPrice(m);

        // Close position via vAMM
        {
            IVAMM vamm = IVAMM(m.vamm);
            (int256 baseDelta, int256 quoteDelta, ) = position.size > 0
                ? vamm.sellBase(size, amountLimit)
                : vamm.buyBase(size, amountLimit);
            _applyTrade(account, marketId, baseDelta, quoteDelta, true);
        }

        // Calculate penalty using the pre-trade risk price snapshot
        uint256 notional;
        uint256 penalty;
        {
            notional = Calculations.mulDivRoundingUp(uint256(size), riskPrice, 1e18);
            penalty = Calculations.mulDivRoundingUp(notional, rp.liquidationPenaltyBps, BPS_DENOMINATOR);
            if (rp.penaltyCap > 0 && penalty > rp.penaltyCap) {
                penalty = rp.penaltyCap;
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
            uint256 liqIncentiveInQuote = _notionalToQuoteUnits(liqIncentive, m.quoteToken);
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

        // After partial liquidation, the remaining position must no longer be liquidatable.
        if (position.size != 0) {
            if (_isLiquidatable(account, marketId)) revert MustLiquidateMore();
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
    function _getMarketInfo(bytes32 marketId) internal view returns (IMarketRegistry.Market memory) {
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (!(m.vamm != address(0))) revert MarketNotFound();
        return m;
    }

    /// @notice Returns the preferred risk price for margin checks, preferring oracle/index price with mark price fallback.
    function _getRiskPrice(IMarketRegistry.Market memory m) internal view returns (uint256) {
        if (!(m.oracle != address(0))) revert OracleNotSet();
        uint256 indexPrice = IOracle(m.oracle).getPrice();
        if (!(indexPrice > 0)) revert OraclePriceZero();
        return indexPrice;
    }


    /// @notice Gets the position details for a user in a specific market.
    function getPosition(address account, bytes32 marketId) external view override returns (PositionView memory) {
        return positions[account][marketId];
    }

    /// @notice Gets the notional value of a user's position in a market.
    function getNotional(address account, bytes32 marketId) external view override returns (uint256) {
        return _getNotional(account, marketId);
    }

    function _getNotional(address account, bytes32 marketId) internal view returns (uint256) {
        PositionView storage p = positions[account][marketId];
        if (p.size == 0) return 0;
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (m.vamm == address(0)) return 0;
        uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
        uint256 absSize = uint256(p.size > 0 ? p.size : -p.size);
        return absSize.mulDiv(markPrice, 1e18);
    }

    /// @notice Gets the margin ratio for a user's position.
    function getMarginRatio(address account, bytes32 marketId) external view override returns (uint256) {
        PositionView storage p = positions[account][marketId];
        if (p.size == 0) return type(uint256).max;
        uint256 notional = _getNotional(account, marketId);
        if (notional == 0) return type(uint256).max;
        int256 unrealizedPnL = _getUnrealizedPnLAtOracle(account, marketId);
        int256 pendingFunding = _getPendingFunding(account, marketId);
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        uint256 marginValue = p.margin;
        {
            uint256 reserved = _reservedMarginForToken(account, m.quoteToken);
            if (reserved > 0) {
                uint256 vaultBal = ICollateralVault(vault).balanceOf(account, m.quoteToken);
                uint256 vaultValX18 = _quoteValueX18(m.quoteToken, vaultBal);
                if (vaultValX18 < reserved) {
                    marginValue = Calculations.mulDiv(p.margin, vaultValX18, reserved);
                }
            }
        }
        int256 effectiveMargin = int256(marginValue) + unrealizedPnL + pendingFunding;
        if (effectiveMargin <= 0) return 0;
        return uint256(effectiveMargin).mulDiv(1e18, notional);
    }

    /// @notice Gets the total value of a user's account.
    function getAccountValue(address account) external view override returns (int256) {
        uint256 collateralValue = ICollateralVault(vault).getAccountCollateralValueX18(account);
        return int256(collateralValue) - int256(_totalReservedMargin[account]);
    }


    /// @notice Settles funding payments for a user in a perpetual market.
    function settleFunding(bytes32 marketId, address account) public override nonReentrant {
        _settleFundingInternal(marketId, account);
    }

    // =========================================================================
    // Delegatecall stubs — forward to ClearingHouseLogic
    // =========================================================================

    /// @dev Forwards to ClearingHouseLogic.applyTrade via delegatecall.
    ///      The logic contract shares this contract's storage, msg.sender, and address(this).
    function _applyTrade(address account, bytes32 marketId, int256 baseDelta, int256 quoteDelta, bool isLiquidation) internal {
        (bool ok,) = _logic.delegatecall(
            abi.encodeWithSelector(
                bytes4(keccak256("applyTrade(address,bytes32,int256,int256,bool)")),
                account, marketId, baseDelta, quoteDelta, isLiquidation
            )
        );
        if (!ok) assembly { returndatacopy(0, 0, returndatasize()) revert(0, returndatasize()) }
    }

    /// @dev Forwards to ClearingHouseLogic.settleFundingInternal via delegatecall.
    function _settleFundingInternal(bytes32 marketId, address account) internal {
        (bool ok,) = _logic.delegatecall(
            abi.encodeWithSelector(
                bytes4(keccak256("settleFundingInternal(bytes32,address)")),
                marketId, account
            )
        );
        if (!ok) assembly { returndatacopy(0, 0, returndatasize()) revert(0, returndatasize()) }
    }

    // =========================================================================
    // Whitelisted liquidator management
    // =========================================================================

    /// @notice Whitelists an address, allowing it to call liquidation functions.
    function setWhitelistedLiquidator(address liquidator, bool isWhitelisted) external onlyAdmin {
        whitelistedLiquidators[liquidator] = isWhitelisted;
        emit LiquidatorWhitelistUpdated(liquidator, isWhitelisted);
    }

    // =========================================================================
    // Internal helpers (Quote Collateral)
    // =========================================================================

    function _reservedMarginForToken(address account, address quoteToken) internal view returns (uint256 reserved) {
        bytes32[] memory markets = _userActiveMarkets[account];
        for (uint256 i = 0; i < markets.length; i++) {
            IMarketRegistry.Market memory mkt = IMarketRegistry(marketRegistry).getMarket(markets[i]);
            if (mkt.quoteToken == quoteToken) {
                reserved += positions[account][markets[i]].margin;
            }
        }
    }

    function _quoteValueX18(address quoteToken, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 v = ICollateralVault(vault).getTokenValueX18(quoteToken, amount);
        if (!(v > 0)) revert QuoteTokenValuationUnavailable();
        return v;
    }

    function _notionalToQuoteUnits(uint256 notionalX18, address quoteToken) internal view returns (uint256) {
        if (notionalX18 == 0) return 0;
        ICollateralVault.CollateralConfig memory cfg = ICollateralVault(vault).getConfig(quoteToken);
        uint256 priceX18 = IOracle(ICollateralVault(vault).oracle()).getPrice(cfg.oracleSymbol);
        if (!(priceX18 > 0)) revert QuoteOracleUnavailable();
        return Calculations.mulDivRoundingUp(notionalX18, cfg.baseUnit, priceX18);
    }

    // =========================================================================
    // Internal helpers (Liquidation Fees)
    // =========================================================================

    /// @dev Attempt to seize quote collateral up to `amount` for a recipient. Returns actual received and shortfall.
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

        uint256 balance = ICollateralVault(vault).balanceOf(account, quoteToken);
        uint256 available;
        {
            uint256 reservedForToken = _reservedMarginForToken(account, quoteToken);
            uint256 reservedInTokenUnits = _notionalToQuoteUnits(reservedForToken, quoteToken);
            available = balance > reservedInTokenUnits ? balance - reservedInTokenUnits : 0;
        }
        uint256 seized = amount <= available ? amount : available;
        actualReceived = seized;

        if (seized > 0) {
            ICollateralVault(vault).seize(account, recipient, quoteToken, seized);
            if (withdrawToRecipient) {
                actualReceived = ICollateralVault(vault).withdrawFor(recipient, quoteToken, seized, recipient);
            }
        }
        shortfall = amount - seized;
    }

    /// @notice Internal function to route liquidation penalties.
    function _routeLiqPenalty(
        address account,
        bytes32 marketId,
        uint256 amount,
        IMarketRegistry.Market memory m
    ) internal {
        if (amount == 0 || m.feeRouter == address(0)) return;

        uint256 penaltyInQuoteDecimals = _notionalToQuoteUnits(amount, m.quoteToken);

        if (penaltyInQuoteDecimals == 0) return;

        (uint256 actualReceived, uint256 shortfall) = _collectQuote(account, m.feeRouter, m.quoteToken, penaltyInQuoteDecimals, true);
        if (shortfall > 0 && m.insuranceFund != address(0)) {
            uint256 fundBalance = IInsuranceFund(m.insuranceFund).balance();
            uint256 actualPayout = shortfall > fundBalance ? fundBalance : shortfall;
            uint256 uncovered = shortfall - actualPayout;
            if (uncovered > 0) {
                totalBadDebt += uncovered;
                emit BadDebtRecorded(account, marketId, uncovered);
            }
        } else if (shortfall > 0) {
            totalBadDebt += shortfall;
            emit BadDebtRecorded(account, marketId, shortfall);
        }

        if (actualReceived > 0) {
            IFeeRouter(m.feeRouter).onLiquidationPenalty(actualReceived);
        }
    }
}
