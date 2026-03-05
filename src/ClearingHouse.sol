//SPDX-License-Identifier:MIT
pragma solidity 0.8.28;

import {IClearingHouse} from "./Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "./Interfaces/ICollateralVault.sol";
import {IMarketRegistry} from "./Interfaces/IMarketRegistry.sol";
import {IVAMM} from "./Interfaces/IVAMM.sol";
import {IOracle} from "./Interfaces/IOracle.sol";
import {Calculations} from "./Libraries/Calculations.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IInsuranceFund} from "./Interfaces/IInsuranceFund.sol";
import {IFeeRouter} from "./Interfaces/IFeeRouter.sol";

/// @notice The central contract for managing user positions, margin, and trade settlement for perpetual vAMM markets.
/// @dev It interacts with various components like the CollateralVault, MarketRegistry, and vAMMs.
contract ClearingHouse is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardTransient, IClearingHouse {
    using Calculations for uint256;

    /// @notice Address of the collateral vault contract.
    address public vault;
    /// @notice Address of the market registry contract.
    address public marketRegistry;


    /// @notice Mapping of whitelisted liquidator addresses.
    mapping(address user => bool isWhitelisted) public whitelistedLiquidators;
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

    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Precision for price and value calculations (1e18)
    uint256 public constant PRECISION = 1e18;

    /// @notice Total uncompensated bad debt accumulated across all liquidations
    uint256 public totalBadDebt;

    /// @notice Total long open interest per market (base units, 1e18).
    mapping(bytes32 marketId => uint256) public totalLongOI;
    /// @notice Total short open interest per market (base units, 1e18).
    mapping(bytes32 marketId => uint256) public totalShortOI;

    /// @notice Set of legacy vaults from prior migrations, allowing users to withdraw stranded balances.
    mapping(address => bool) public legacyVaults;

    /// @notice Modifier to restrict access to admin roles.
    modifier onlyAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "CH: not admin");
        _;
    }

    /// @notice Modifier to restrict access to whitelisted liquidators.
    modifier onlyWhitelistedLiquidator() {
        require(whitelistedLiquidators[msg.sender], "CH: not whitelisted liquidator");
        _;
    }

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

        __AccessControl_init();

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
        emit CollateralDeposited(msg.sender, token, amount);
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

        // Ensure the withdrawn token's remaining balance still covers all margin
        // reserved against it.  Each quote token's margin is validated independently
        // so that a surplus in one token cannot mask a deficit in another.
        uint256 reservedForToken = _reservedMarginForToken(msg.sender, token);
        if (reservedForToken > 0) {
            uint256 balAfter = ICollateralVault(vault).balanceOf(msg.sender, token);
            require(balAfter >= amount, "CH: insufficient balance");
            uint256 valueAfter = _quoteValueX18(token, balAfter - amount);
            require(valueAfter >= reservedForToken, "CH: insufficient quote collateral");
        }

        // withdrawFor returns actual received amount (fee-on-transfer support)
        uint256 received = ICollateralVault(vault).withdrawFor(msg.sender, token, amount, msg.sender);

        // Post-withdrawal check: ensure no positions become liquidatable
        bytes32[] memory activeMarkets = _userActiveMarkets[msg.sender];
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            require(!this.isLiquidatable(msg.sender, activeMarkets[i]), "CH: would be liquidatable");
        }

        emit CollateralWithdrawn(msg.sender, token, amount, received);
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
        uint256 reservedForToken = _reservedMarginForToken(msg.sender, m.quoteToken);
        require(amount <= quoteValueX18 - reservedForToken, "CH: insufficient quote balance");
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
        uint256 notionalValue = Calculations.mulDivRoundingUp(positionSize, riskPrice, 1e18);
        return Calculations.mulDivRoundingUp(notionalValue, mmrBps, BPS_DENOMINATOR);
    }

    /// @notice Computes the liquidation penalty for a position using the same formula as liquidate().
    /// @dev penalty = min(notional * liquidationPenaltyBps / 10000, penaltyCap)
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

    /// @notice Internal function to calculate unrealized PnL for a position using mark price.
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
            require(!this.isLiquidatable(msg.sender, activeMarkets[i]), "CH: has liquidatable position");
        }

        require(IMarketRegistry(marketRegistry).isActive(marketId), "CH: market not active");
        require(marketRiskParams[marketId].mmrBps > 0, "CH: risk params not set");
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        require(m.vamm != address(0), "CH: market not found");
        require(size > 0, "CH: size=0");

        IVAMM vamm = IVAMM(m.vamm);
        (int256 baseDelta, int256 quoteDelta, uint256 avgPrice) = isLong
            ? vamm.buyBase(size, amountLimit)
            : vamm.sellBase(size, amountLimit);

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
        // unaffected anyway; when only spot mark remains the trade's own price
        // impact would otherwise distort the penalty calculation.
        uint256 riskPrice = _getRiskPrice(m);

        // Close position via vAMM - scope to free stack
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
            penalty = Calculations.mulDivRoundingUp(notional, marketRiskParams[marketId].liquidationPenaltyBps, BPS_DENOMINATOR);
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

        // After partial liquidation, the remaining position must no longer be
        // liquidatable.  This forces the liquidator to close enough of the
        // position to restore health (or liquidate it entirely), preventing
        // repeated small liquidations that bypass the penaltyCap.
        if (position.size != 0) {
            require(!this.isLiquidatable(account, marketId), "CH: must liquidate more");
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

    /// @notice Returns the preferred risk price for margin checks, preferring oracle/index price with mark price fallback.
    function _getRiskPrice(IMarketRegistry.Market memory m) internal view returns (uint256) {
        require(m.oracle != address(0), "CH: oracle not set");
        uint256 indexPrice = IOracle(m.oracle).getPrice();
        require(indexPrice > 0, "CH: oracle price is 0");
        return indexPrice;
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
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        require(m.vamm != address(0), "CH: market not found");
        IMarketRegistry(marketRegistry).pauseMarket(marketId, paused);
        // Freeze/unfreeze funding on the vAMM: flushes on pause, resets timestamp on unpause
        IVAMM(m.vamm).pauseSwaps(paused);
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

        uint256 currentPay;
        uint256 currentReceive;
        if (position.size > 0) {
            currentPay = vamm.cumulativeLongPayPerUnitX18();
            currentReceive = vamm.cumulativeLongReceivePerUnitX18();
        } else if (position.size < 0) {
            currentPay = vamm.cumulativeShortPayPerUnitX18();
            currentReceive = vamm.cumulativeShortReceivePerUnitX18();
        } else {
            position.lastFundingPayIndex = 0;
            position.lastFundingReceiveIndex = 0;
            return;
        }

        uint256 payDelta = currentPay - position.lastFundingPayIndex;
        uint256 receiveDelta = currentReceive - position.lastFundingReceiveIndex;

        if (payDelta != 0 || receiveDelta != 0) {
            uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);

            int256 fundingPayment;
            if (receiveDelta >= payDelta) {
                fundingPayment = int256(Calculations.mulDiv(receiveDelta - payDelta, absSize, 1e18));
            } else {
                fundingPayment = -int256(Calculations.mulDiv(payDelta - receiveDelta, absSize, 1e18));
            }

            // Settle in vault FIRST so downstream margin/shortfall logic sees post-settlement balances.
            _settlePnLInVault(account, marketId, fundingPayment);

            if (fundingPayment > 0) {
                uint256 credit = uint256(fundingPayment);
                position.margin += credit;
                _totalReservedMargin[account] += credit;
            } else if (fundingPayment < 0) {
                uint256 debit = uint256(-fundingPayment);
                if (debit >= position.margin) {
                    uint256 shortfall = debit - position.margin;
                    _totalReservedMargin[account] = (_totalReservedMargin[account] > position.margin)
                        ? (_totalReservedMargin[account] - position.margin)
                        : 0;
                    position.margin = 0;

                    _recoverShortfall(account, marketId, shortfall);
                } else {
                    position.margin -= debit;
                    _totalReservedMargin[account] -= debit;
                }
            }

            emit FundingSettled(marketId, account, fundingPayment);
        }

        position.lastFundingPayIndex = currentPay;
        position.lastFundingReceiveIndex = currentReceive;
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

        // === Update open interest and push to vAMM for balanced funding ===
        {
            uint256 oldLong = s0 > 0 ? uint256(s0) : 0;
            uint256 newLong = s1 > 0 ? uint256(s1) : 0;
            uint256 oldShort = s0 < 0 ? uint256(-s0) : 0;
            uint256 newShort = s1 < 0 ? uint256(-s1) : 0;
            totalLongOI[marketId] = totalLongOI[marketId] - oldLong + newLong;
            totalShortOI[marketId] = totalShortOI[marketId] - oldShort + newShort;
            IMarketRegistry.Market memory mOI = IMarketRegistry(marketRegistry).getMarket(marketId);
            IVAMM(mOI.vamm).updateOpenInterest(totalLongOI[marketId], totalShortOI[marketId]);
        }

        // Reset funding indices when position direction changes
        {
            IMarketRegistry.Market memory mFI = IMarketRegistry(marketRegistry).getMarket(marketId);
            IVAMM vammFI = IVAMM(mFI.vamm);
            if (s1 > 0 && s0 <= 0) {
                position.lastFundingPayIndex = vammFI.cumulativeLongPayPerUnitX18();
                position.lastFundingReceiveIndex = vammFI.cumulativeLongReceivePerUnitX18();
            } else if (s1 < 0 && s0 >= 0) {
                position.lastFundingPayIndex = vammFI.cumulativeShortPayPerUnitX18();
                position.lastFundingReceiveIndex = vammFI.cumulativeShortReceivePerUnitX18();
            }
        }

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

        // Reflect realized PnL in margin accounting so risk checks see consistent values.
        if (realized > 0) {
            uint256 credit = uint256(realized);
            position.margin += credit;
            _totalReservedMargin[account] += credit;
        } else if (realized < 0) {
            uint256 loss = uint256(-realized);
            if (loss >= position.margin) {
                _totalReservedMargin[account] = _totalReservedMargin[account] > position.margin
                    ? _totalReservedMargin[account] - position.margin
                    : 0;
                position.margin = 0;
            } else {
                position.margin -= loss;
                _totalReservedMargin[account] -= loss;
            }
        }

        // === Margin management (independent of PnL) ===
        // Use the post-trade risk price (max of mark, oracle) for margin allocation so that
        // the allocated amount matches the post-trade IMR check. This prevents the contract
        // from needing to silently auto-commit additional collateral after the trade.
        if (s0 == 0 || ((s0 > 0 && baseDelta > 0) || (s0 < 0 && baseDelta < 0))) {
            // Opening or increasing: allocate IMR margin from available collateral
            IMarketRegistry.Market memory mq = IMarketRegistry(marketRegistry).getMarket(marketId);
            uint256 markPrice = IVAMM(mq.vamm).getMarkPrice();
            uint256 oraclePrice = _getRiskPrice(mq);
            uint256 imrPrice = markPrice > oraclePrice ? markPrice : oraclePrice;
            uint256 tradeNotional = absBaseDelta.mulDiv(imrPrice, 1e18);
            uint256 imrBps = marketRiskParams[marketId].imrBps;
            uint256 marginRequired = tradeNotional.mulDiv(imrBps, BPS_DENOMINATOR);
            if (!isLiquidation && marginRequired > 0) {
                _ensureAvailableCollateral(account, marginRequired, mq.quoteToken);
            }
            position.margin += marginRequired;
            _totalReservedMargin[account] += marginRequired;
        } else {
            // Reducing, closing, or flipping: release margin proportionally to size reduction
            uint256 reduceAmt = absBaseDelta <= absS0 ? absBaseDelta : absS0;
            uint256 marginRelease = (position.margin * reduceAmt) / absS0;
            position.margin -= marginRelease;
            _totalReservedMargin[account] -= marginRelease;

            // If flipping (trade exceeds current position), allocate margin for the new direction
            if (absBaseDelta > absS0) {
                uint256 openAmt = absBaseDelta - absS0;
                IMarketRegistry.Market memory mq = IMarketRegistry(marketRegistry).getMarket(marketId);
                uint256 markPrice = IVAMM(mq.vamm).getMarkPrice();
                uint256 oraclePrice = _getRiskPrice(mq);
                uint256 imrPrice = markPrice > oraclePrice ? markPrice : oraclePrice;
                uint256 openNotional = openAmt.mulDiv(imrPrice, 1e18);
                uint256 imrBps = marketRiskParams[marketId].imrBps;
                uint256 marginRequired = openNotional.mulDiv(imrBps, BPS_DENOMINATOR);
                if (!isLiquidation && marginRequired > 0) {
                    _ensureAvailableCollateral(account, marginRequired, mq.quoteToken);
                }
                position.margin += marginRequired;
                _totalReservedMargin[account] += marginRequired;
            }
        }

        // Protocol trading fee for perps: charge on this trade's notional at execPx
        // Fees are collected directly from available collateral before the IMR check so
        // that position margin remains intact for the risk assessment.
        // Skip fee collection during liquidation to prevent blocking liquidation of underwater users.
        if (!isLiquidation && absBaseDelta > 0) {
            IMarketRegistry.Market memory m2 = IMarketRegistry(marketRegistry).getMarket(marketId);
            if (m2.feeBps > 0) {
                uint256 notional2 = Calculations.mulDivRoundingUp(absBaseDelta, execPxX18, 1e18);
                if (notional2 > 0) {
                    tradeFee = Calculations.mulDivRoundingUp(notional2, m2.feeBps, BPS_DENOMINATOR);
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

            // Revalue margin against real collateral so a depegged quote token
            // cannot mask an IMR breach.
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
            require(marginValue >= requiredMargin, "CH: IMR breach");

            // Post-trade health check: ensure position is NOT immediately liquidatable.
            // IMR only checks raw margin vs required margin. But unrealized PnL (from the
            // trade's price impact) can make effective margin fall below maintenance margin,
            // leaving the position immediately liquidatable after opening.
            // Use oracle/risk price for consistency with isLiquidatable().
            {
                int256 unrealizedPnL = _computeUnrealizedPnL(position, oraclePrice);
                int256 effectiveMargin = int256(marginValue) + unrealizedPnL;
                uint256 riskNotional = Calculations.mulDivRoundingUp(absS1, oraclePrice, 1e18);
                uint256 maintenanceMargin = Calculations.mulDivRoundingUp(riskNotional, marketRiskParams[marketId].mmrBps, BPS_DENOMINATOR);
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

        // Only seize from free collateral (vault balance minus what is reserved
        // for positions using this specific quote token) to prevent a liquidation
        // penalty from creating account-level insolvency.  Uses per-token reserved
        // margin so positions backed by a different quote token do not inflate the
        // reservation.
        uint256 balance = ICollateralVault(vault).balanceOf(account, quoteToken);
        uint256 available;
        {
            uint256 reservedForToken = _reservedMarginForToken(account, quoteToken);
            uint256 reservedInTokenUnits = _notionalToQuoteUnits(reservedForToken, quoteToken);
            available = balance > reservedInTokenUnits ? balance - reservedInTokenUnits : 0;
        }
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
        whitelistedLiquidators[liquidator] = isWhitelisted;
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
        position.lastFundingPayIndex = 0;
        position.lastFundingReceiveIndex = 0;
        position.realizedPnL = 0;

        emit PositionCleared(user, marketId, oldMargin, oldReservedMargin, _totalReservedMargin[user]);
    }

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

        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        uint256 quoteBalance = ICollateralVault(vault).balanceOf(account, m.quoteToken);
        uint256 quoteValueX18 = _quoteValueX18(m.quoteToken, quoteBalance);
        uint256 reservedForToken = _reservedMarginForToken(account, m.quoteToken);
        uint256 freeCollateral = quoteValueX18 > reservedForToken
            ? quoteValueX18 - reservedForToken
            : 0;
        uint256 recovered = shortfall > freeCollateral ? freeCollateral : shortfall;

        if (recovered > 0) {
            _totalReservedMargin[account] += recovered;
            positions[account][marketId].margin += recovered;
        }
        // No bad debt recording — vault-level bad debt is tracked by _settlePnLInVault.
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

        if (realized > 0) {
            uint256 profitInQuote = _notionalToQuoteUnitsDown(uint256(realized), m.quoteToken);
            if (profitInQuote > 0) {
                ICollateralVault(vault).settlePnL(account, m.quoteToken, int256(profitInQuote));
            }
        } else {
            uint256 lossInQuote = _notionalToQuoteUnits(uint256(-realized), m.quoteToken);
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

        // Convert fee from 1e18 USD notional to quote token's native decimals
        // using the live oracle price of the quote token.
        uint256 feeInQuoteDecimals = _notionalToQuoteUnits(fee, m.quoteToken);

        
        if (feeInQuoteDecimals == 0) return;

        (uint256 actualReceived, uint256 shortfall) = _collectQuote(account, m.feeRouter, m.quoteToken, feeInQuoteDecimals, true);
        require(shortfall == 0, "CH: insufficient quote token for fee");
        IFeeRouter(m.feeRouter).onTradeFee(actualReceived);
    }

    /// @dev Sums position.margin for all active positions whose market uses the
    ///      given quote token.  This gives the per-token reservation instead of the
    ///      aggregate _totalReservedMargin, which may include other quote tokens.
    function _reservedMarginForToken(address account, address quoteToken) internal view returns (uint256 reserved) {
        bytes32[] memory markets = _userActiveMarkets[account];
        for (uint256 i = 0; i < markets.length; i++) {
            IMarketRegistry.Market memory mkt = IMarketRegistry(marketRegistry).getMarket(markets[i]);
            if (mkt.quoteToken == quoteToken) {
                reserved += positions[account][markets[i]].margin;
            }
        }
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
        uint256 reservedForToken = _reservedMarginForToken(account, quoteToken);
        require(quoteValueX18 >= reservedForToken + amount, "CH: insufficient quote collateral");
    }

    function _quoteValueX18(address quoteToken, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 v = ICollateralVault(vault).getTokenValueX18(quoteToken, amount);
        require(v > 0, "CH: quote token valuation unavailable");
        return v;
    }

    function _notionalToQuoteUnits(uint256 notionalX18, address quoteToken) internal view returns (uint256) {
        if (notionalX18 == 0) return 0;
        ICollateralVault.CollateralConfig memory cfg = ICollateralVault(vault).getConfig(quoteToken);
        uint256 priceX18 = IOracle(ICollateralVault(vault).oracle()).getPrice(cfg.oracleSymbol);
        require(priceX18 > 0, "CH: quote oracle price unavailable");
        return Calculations.mulDivRoundingUp(notionalX18, cfg.baseUnit, priceX18);
    }

    function _notionalToQuoteUnitsDown(uint256 notionalX18, address quoteToken) internal view returns (uint256) {
        if (notionalX18 == 0) return 0;
        ICollateralVault.CollateralConfig memory cfg = ICollateralVault(vault).getConfig(quoteToken);
        uint256 priceX18 = IOracle(ICollateralVault(vault).oracle()).getPrice(cfg.oracleSymbol);
        require(priceX18 > 0, "CH: quote oracle price unavailable");
        return Calculations.mulDiv(notionalX18, cfg.baseUnit, priceX18);
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

        // Convert penalty from 1e18 USD notional to quote token's native decimals
        // using the live oracle price of the quote token.
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

        // Only route the user-collected portion through FeeRouter.
        // The insurance fund should not subsidize treasury revenue from uncollectable penalties.
        if (actualReceived > 0) {
            IFeeRouter(m.feeRouter).onLiquidationPenalty(actualReceived);
        }
    }
}