//SPDX-License-Identifier:MIT
pragma solidity 0.8.28;

import {IClearingHouse} from "./Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "./Interfaces/ICollateralVault.sol";
import {IMarketRegistry} from "./Interfaces/IMarketRegistry.sol";
import {IVAMM} from "./Interfaces/IVAMM.sol";
import {IOracle} from "./Interfaces/IOracle.sol";
import {Calculations} from "./Libraries/Calculations.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IInsuranceFund} from "./Interfaces/IInsuranceFund.sol";
import {IFeeRouter} from "./Interfaces/IFeeRouter.sol";

/// @notice The central contract for managing user positions, margin, and trade settlement for perpetual vAMM markets.
/// @dev It interacts with various components like the CollateralVault, MarketRegistry, and vAMMs.
contract ClearingHouse is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuardTransient, IClearingHouse {
    using Calculations for uint256;

    // =========================================================================
    // Storage layout — must match ClearingHouseLogic exactly.
    // Do NOT reorder or insert variables without updating ClearingHouseLogic.
    // Slots 11-14 are used here only; ClearingHouseLogic holds placeholders for them.
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

    /// @notice Address that can add and remove allowlisted traders alongside the owner.
    address public allowlistManager; // slot 11
    /// @notice Whether trader functions are restricted to allowlisted wallets.
    bool public allowlistEnforced; // slot 11 (packed with allowlistManager)
    /// @notice Wallets allowed to call trader functions while the allowlist is enforced.
    mapping(address trader => bool isAllowed) public allowedTraders; // slot 12

    /// @notice Per-market caps on aggregate open interest (gross and net, base units).
    mapping(bytes32 marketId => OpenInterestCaps) public openInterestCaps; // slot 13

    /// @notice Per-market limit on how far below (long) or above (short) the index the pre-trade vAMM
    ///         mark may be for a liquidation to proceed, in bps.
    /// @dev 0 means DEFAULT_LIQUIDATION_PRICE_BAND_BPS. Read through liquidationPriceBandBps().
    mapping(bytes32 marketId => uint256 bandBps) internal _liquidationPriceBandBps; // slot 14

    /// @notice Funding surplus per market, in quote-token units: what payers paid into the vault beyond
    ///         the receiving side's credit, owed to the market's insurance fund. Moved by sweepFundingSurplus.
    /// @dev Mirrored in ClearingHouseLogic, which books it at funding settlement.
    mapping(bytes32 marketId => uint256 amount) public fundingSurplus; // slot 15

    /// @notice Trade fees booked to a fee router's vault balance because pushing them out failed.
    /// @dev Mirrored in ClearingHouseLogic, which routes trade fees.
    mapping(address feeRouter => mapping(address token => uint256 amount)) public pendingTradeFees; // slot 16
    /// @notice Liquidation penalty shares booked to a fee router's vault balance because pushing them out failed.
    mapping(address feeRouter => mapping(address token => uint256 amount)) public pendingLiqPenalties; // slot 17

    /// @notice Per-market holding fee rate and accrual index (see ClearingHouseLogic.setHoldingFeeRate).
    /// @dev Mirrored in ClearingHouseLogic, which accrues and charges it at funding settlement.
    mapping(bytes32 marketId => HoldingFee) public holdingFees; // slot 18

    /// @notice Band used when a market has none set: 5%.
    uint256 public constant DEFAULT_LIQUIDATION_PRICE_BAND_BPS = 500;
    /// @notice Narrowest liquidation price band a market may have, and so the smallest allowed gap
    ///         mmrBps - liquidationPenaltyBps: 1%. A narrower band blocks the next liquidation of a
    ///         long (short) as soon as one liquidation leaves the mark that far below (above) the index.
    uint256 public constant MIN_LIQUIDATION_BAND_BPS = 100;
    /// @notice Time after the quote oracle's post-restart sequencer grace period during which
    ///         liquidation stays closed, so traders can top up first.
    uint256 public constant LIQUIDATION_REACTION_WINDOW = 30 minutes;

    // =========================================================================
    // Logic contract (immutable — embedded in implementation bytecode, not proxy storage)
    // =========================================================================

    /// @notice Address of ClearingHouseLogic — called via delegatecall for heavy functions.
    address private immutable _logic;

    // Custom errors
    error AmountZero();
    error BelowMinSize();
    error ExceedsMarginTopUp();
    error ExceedsMaxSize();
    error ExceedsMaxGrossOI();
    error ExceedsMaxNetOI();
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
    error InvalidHoldingFeeRate();
    error InvalidLiquidationPriceBand();
    error InvalidLogic();
    error InvalidOpenInterestCaps();
    error InvalidRegistry();
    error InvalidSize();
    error InvalidVault();
    error LiquidationPriceOutOfBand(uint256 markPriceX18, uint256 indexPriceX18);
    error LiquidationReactionWindow();
    error MMRZero();
    error MarginBelowPenalty();
    error MarketNotActive();
    error MarketNotFound();
    error MinExceedsMax();
    error MustLiquidateMore();
    error NoPosition();
    error NotAdmin();
    error NotAllowlistManager();
    error NotLiquidatable();
    error NotWhitelistedLiquidator();
    error OracleNotSet();
    error OraclePriceZero();
    error PositionLiquidatable();
    error QuoteOracleUnavailable();
    error RenounceOwnershipDisabled();
    error QuoteTokenValuationUnavailable();
    error ReduceExceedsPosition();
    error RemainingBelowMinCloseFull();
    error RemainingBelowMinLiquidateFull();
    error RiskParamsNotSet();
    error SizeZero();
    error TraderNotAllowed();
    error WouldBeLiquidatable();
    error ZeroAddress();

    /// @notice Emitted when booked fees and penalty shares are pushed to their fee router.
    event FeesSwept(address indexed feeRouter, address indexed token, uint256 tradeFees, uint256 liqPenalties);
    error NotSelf();

    /// @notice Emitted when a market's funding surplus is moved to its insurance fund.
    event FundingSurplusSwept(bytes32 indexed marketId, address indexed insuranceFund, uint256 amount);

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

    /// @notice Modifier to restrict access to the allowlist manager or the owner.
    modifier onlyAllowlistManager() {
        if (msg.sender != allowlistManager && msg.sender != owner()) revert NotAllowlistManager();
        _;
    }

    /// @notice Modifier to restrict risk-increasing trader functions (openPosition) while the allowlist is enforced.
    /// @dev Exits (closePosition, addMargin, removeMargin, withdraw) stay open so a removed wallet can always de-risk and leave.
    ///      deposit is gated only for wallets without an open position, so a removed holder can top up.
    /// @dev Reads the wallet's entry first so a listed trader pays for one storage read.
    modifier onlyAllowedTrader() {
        if (!allowedTraders[msg.sender] && allowlistEnforced) revert TraderNotAllowed();
        _;
    }

    constructor(address logic) {
        if (logic.code.length == 0) revert InvalidLogic();
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

    /// @notice Disabled: renouncing would permanently remove upgrade and risk-parameter authority.
    /// @dev Ownership moves in two steps (transferOwnership, then acceptOwnership by the new owner);
    ///      the pending owner lives in Ownable2StepUpgradeable's namespaced slot, so the proxy's
    ///      sequential storage layout is unchanged.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }


    /// @notice Deposits collateral into the vault for the caller.
    /// @param token The address of the ERC20 token to deposit.
    /// @param amount The amount of the token to deposit.
    /// @dev While the allowlist is enforced, an unlisted wallet can deposit only if it has an open
    ///      position, so a holder removed from the allowlist can still top up its margin.
    function deposit(address token, uint256 amount) external override nonReentrant {
        if (allowlistEnforced && !allowedTraders[msg.sender] && _userActiveMarkets[msg.sender].length == 0) {
            revert TraderNotAllowed();
        }
        if (!(amount > 0)) revert AmountZero();
        ICollateralVault(vault).deposit(token, amount, msg.sender);
        emit CollateralDeposited(msg.sender, token, amount);
    }

    /// @notice Deposits quote tokens and adds them to an open position's margin in one call.
    /// @dev Stays open while the vault's deposits are paused or its caps are full, so a fully allocated
    ///      trader can always defend a position. Bounded: the position's equity after the top-up (margin
    ///      valued at the backing collateral, plus min(unrealized PnL at the index, 0), minus funding
    ///      debt, as removeMargin measures it) may not exceed its initial margin at max(mark, index), so
    ///      a top-up only restores what the position needs. Profit does not count, so a position in
    ///      profit but carrying funding debt it cannot pay can still be cured. removeMargin keeps that margin locked while the position is below it.
    /// @param marketId The market of the position.
    /// @param amount The amount of the market's quote token to deposit, in token units.
    function depositMargin(bytes32 marketId, uint256 amount) external override nonReentrant {
        _settleFundingInternal(marketId, msg.sender);
        if (!(amount > 0)) revert AmountZero();
        PositionView storage position = positions[msg.sender][marketId];
        if (position.size == 0) revert NoPosition();
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        uint256 valueX18 =
            _quoteValueX18(m.quoteToken, ICollateralVault(vault).depositForMargin(m.quoteToken, amount, msg.sender));
        position.margin += valueX18;
        _totalReservedMargin[msg.sender] += valueX18;
        (int256 equityAfter,) = _marginState(msg.sender, marketId);
        uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
        uint256 riskPrice = _getRiskPrice(m);
        {
            // Unrealized profit does not count, as in removeMargin: min(unrealized PnL at the index, 0).
            int256 unrealizedPnL = _computeUnrealizedPnL(position, riskPrice);
            if (unrealizedPnL > 0) equityAfter -= unrealizedPnL;
        }
        uint256 imrMargin = uint256(position.size > 0 ? position.size : -position.size).mulDiv(
            markPrice > riskPrice ? markPrice : riskPrice, 1e18
        ).mulDiv(marketRiskParams[marketId].imrBps, BPS_DENOMINATOR);
        if (equityAfter > int256(imrMargin)) revert ExceedsMarginTopUp();
        _endPenaltyEpisode(msg.sender, marketId);
        emit CollateralDeposited(msg.sender, m.quoteToken, amount);
        emit MarginAdded(msg.sender, marketId, valueX18);
    }

    /// @notice Withdraws collateral from the vault for the caller.
    /// @dev Checks that the withdrawal does not compromise the user's total reserved margin
    ///      and that no positions would become liquidatable after withdrawal.
    /// @param token The address of the ERC20 token to withdraw.
    /// @param amount The amount of the token to withdraw.
    function withdraw(address token, uint256 amount) external override nonReentrant {
        if (!(amount > 0)) revert AmountZero();

        // Settle funding for all active markets to ensure margin values are current
        _settleAccountFunding(msg.sender, bytes32(0), false);

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

        // Post-withdrawal check: no position backed by the withdrawn token may become liquidatable.
        // Positions on other quote tokens are unaffected, so their feeds cannot block the withdrawal.
        if (_hasLiquidatable(msg.sender, token, bytes32(0))) revert WouldBeLiquidatable();

        emit CollateralWithdrawn(msg.sender, token, amount, received);
    }

    /// @notice Adds margin to a specific position from the user's available collateral.
    /// @dev Requires an open position in the market. Allowed while the market is paused, since it
    ///      touches no vAMM state and lets traders defend positions whose index keeps moving. While
    ///      another position on the same quote token is liquidatable, only a liquidatable position
    ///      can take margin, so free collateral stays available to that liquidation. A position whose
    ///      own index cannot be read counts as not liquidatable for this check, so a lone position can
    ///      still be topped up during its index outage.
    /// @param marketId The ID of the market for the position.
    /// @param amount The amount of margin to add (in quote currency value, 1e18).
    function addMargin(bytes32 marketId, uint256 amount) external override {
        _settleFundingInternal(marketId, msg.sender);
        if (!(amount > 0)) revert AmountZero();
        if (positions[msg.sender][marketId].size == 0) revert NoPosition();
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        // The topped-up position counts as not liquidatable while its own index cannot be read: it
        // cannot be liquidated until the index is back, so its outage must not block its top-up.
        bool ownLiquidatable;
        try IOracle(m.oracle).getPrice() returns (uint256 indexPrice) {
            ownLiquidatable = indexPrice > 0 && _isLiquidatable(msg.sender, marketId);
        } catch {}
        if (!ownLiquidatable && _hasLiquidatable(msg.sender, m.quoteToken, marketId)) {
            revert HasLiquidatablePosition();
        }
        uint256 quoteBalance = ICollateralVault(vault).balanceOf(msg.sender, m.quoteToken);
        uint256 quoteValueX18 = _quoteValueX18(m.quoteToken, quoteBalance);
        uint256 reservedForToken = _reservedMarginForToken(msg.sender, m.quoteToken);
        if (quoteValueX18 < reservedForToken || amount > quoteValueX18 - reservedForToken) {
            revert InsufficientQuoteBalance();
        }
        positions[msg.sender][marketId].margin += amount;
        _totalReservedMargin[msg.sender] += amount;
        _endPenaltyEpisode(msg.sender, marketId);
        emit MarginAdded(msg.sender, marketId, amount);
    }

    /// @notice Removes margin from a specific position, making it available for withdrawal or use in other positions.
    /// @dev The margin left plus min(unrealized PnL at the index, 0) must meet the initial margin of the
    ///      whole position at the higher of mark and index, the margin left must stay above maintenance
    ///      (PnL at the index) and cover the liquidation penalty. Unrealized profit never counts.
    /// @param marketId The ID of the market for the position.
    /// @param amount The amount of margin to remove (in quote currency value, 1e18).
    function removeMargin(bytes32 marketId, uint256 amount) external override {
        _settleFundingInternal(marketId, msg.sender);
        if (!(amount > 0)) revert AmountZero();
        if (!(IMarketRegistry(marketRegistry).isActive(marketId))) revert MarketNotActive();
        PositionView storage position = positions[msg.sender][marketId];
        if (!(position.margin >= amount)) revert InsufficientMargin();
        // Unrealized PnL is taken at the index only: the vAMM mark can be moved for one call by a
        // second account, so it must not decide how much margin leaves. Profit never counts towards
        // the initial margin below.
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        uint256 riskPrice = _getRiskPrice(m);
        int256 unrealizedPnL = _computeUnrealizedPnL(position, riskPrice);
        uint256 maintenanceMargin = _getMaintenanceMargin(msg.sender, marketId);
        // Use real-time collateral value for the margin component
        uint256 nominalAfter = position.margin - amount;
        uint256 marginValueAfter = nominalAfter;
        {
            // Value the post-removal state: `amount` leaves the reserved sum together with the margin.
            uint256 reserved = _reservedMarginForToken(msg.sender, m.quoteToken);
            if (_isMarketActive[msg.sender][marketId]) reserved -= amount;
            if (reserved > 0) {
                uint256 vaultBal = ICollateralVault(vault).balanceOf(msg.sender, m.quoteToken);
                uint256 vaultValX18 = _quoteValueX18(m.quoteToken, vaultBal);
                if (vaultValX18 < reserved) {
                    marginValueAfter = Calculations.mulDiv(nominalAfter, vaultValX18, reserved);
                }
            }
        }
        // Funding debt the position carries counts against the margin left.
        int256 debt = int256(position.fundingDebt);
        int256 effectiveMarginAfter = int256(marginValueAfter) + unrealizedPnL - debt;
        if (!(effectiveMarginAfter >= int256(maintenanceMargin))) revert WouldBeLiquidatable();

        if (position.size != 0) {
            // Enforce minimum margin floor: position margin must always cover the liquidation penalty
            uint256 minMargin = _getLiquidationPenalty(msg.sender, marketId);
            if (!(nominalAfter >= minMargin)) revert MarginBelowPenalty();

            // The margin left plus min(unrealized PnL at the index, 0), net of funding debt, must meet
            // the initial margin of the whole position at max(mark, index), the price and rate of an
            // open or increase. Moving the mark can only raise this requirement.
            uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
            uint256 imrPrice = markPrice > riskPrice ? markPrice : riskPrice;
            uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);
            uint256 requiredMargin =
                absSize.mulDiv(imrPrice, 1e18).mulDiv(marketRiskParams[marketId].imrBps, BPS_DENOMINATOR);
            int256 imrEquity = int256(marginValueAfter) + (unrealizedPnL < 0 ? unrealizedPnL : int256(0)) - debt;
            if (!(imrEquity >= int256(requiredMargin))) revert IMRBreach();
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

    /// @dev True if a position of the account on `quoteToken`, other than the one in `skip`, is
    ///      liquidatable.
    function _hasLiquidatable(address account, address quoteToken, bytes32 skip) internal view returns (bool) {
        bytes32[] memory markets = _userActiveMarkets[account];
        for (uint256 i = 0; i < markets.length; i++) {
            if (
                markets[i] != skip && IMarketRegistry(marketRegistry).getMarket(markets[i]).quoteToken == quoteToken
                    && _isLiquidatable(account, markets[i])
            ) return true;
        }
        return false;
    }

    /// @dev A position is liquidatable below maintenance margin, and also whenever it carries funding
    ///      debt the vault balance cannot pay, counting funding not yet settled.
    function _isLiquidatable(address account, bytes32 marketId) internal view returns (bool) {
        if (positions[account][marketId].size == 0) return false;
        (int256 effectiveMargin, uint256 maintenanceMargin) = _marginState(account, marketId);
        return effectiveMargin < int256(maintenanceMargin) || _carriesFundingDebt(account, marketId);
    }

    /// @dev True if settling funding now would leave the position with funding debt: each funding
    ///      debit is paid only up to the paying position's margin plus the account's free collateral
    ///      value, so funding above that is carried as debt. Replays the account's settlement in
    ///      ClearingHouseLogic.carriesFundingDebt (a delegatecall inside a static self-call).
    function _carriesFundingDebt(address account, bytes32 marketId) internal view returns (bool) {
        return abi.decode(
            _logicView(abi.encodeWithSignature("carriesFundingDebt(address,bytes32)", account, marketId)), (bool)
        );
    }

    /// @dev Runs a ClearingHouseLogic view through a static self-call to delegateView.
    function _logicView(bytes memory data) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = address(this).staticcall(abi.encodeCall(this.delegateView, (data)));
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
        return abi.decode(ret, (bytes));
    }

    /// @notice Runs a ClearingHouseLogic view against this contract's storage.
    /// @dev Self-call only: views reach it through a staticcall, so the logic cannot change state.
    function delegateView(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(this)) revert NotSelf();
        return _delegate(data);
    }

    /// @dev Effective margin (margin valued at the backing collateral, plus pending funding and
    ///      unrealized PnL at the index, minus carried funding debt) and maintenance margin of an
    ///      open position.
    function _marginState(address account, bytes32 marketId)
        internal
        view
        returns (int256 effectiveMargin, uint256 maintenanceMargin)
    {
        PositionView storage position = positions[account][marketId];

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
        effectiveMargin = int256(marginValue) + pendingFunding + unrealizedPnL - int256(position.fundingDebt);
        maintenanceMargin = _getMaintenanceMargin(account, marketId);
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
        // A liquidation inside the band must leave a position at the maintenance threshold enough
        // margin to fund the penalty: band + penalty <= mmr. An unset band is capped by the getter
        // at mmr - penalty, which must itself leave at least the minimum band.
        {
            uint256 band = _liquidationPriceBandBps[marketId];
            if (band < MIN_LIQUIDATION_BAND_BPS) band = MIN_LIQUIDATION_BAND_BPS;
            if (!(band + liquidationPenaltyBps <= mmrBps)) revert InvalidLiquidationPriceBand();
        }

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

    /// @notice View-safe helper to compute unsettled funding for a position, net of the holding fee
    ///         accrued since its last settlement (ClearingHouseLogic.pendingFunding).
    function _getPendingFunding(address account, bytes32 marketId) internal view returns (int256) {
        return abi.decode(
            _logicView(abi.encodeWithSignature("pendingFunding(address,bytes32)", account, marketId)), (int256)
        );
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


    /// @notice Sets the aggregate open-interest caps for a market. 0 disables a cap.
    /// @dev Lowering a cap below current OI never traps positions: closes, pure reductions and
    ///      liquidations are never capped. Above the gross cap, a trade is accepted only if it moves
    ///      the vAMM mark toward the index without crossing it, so a pushed premium can always be
    ///      traded back (see ClearingHouseLogic.checkOpenInterestCaps).
    /// @param marketId The market to configure.
    /// @param maxGrossOI Cap on long OI + short OI, in base units (1e18).
    /// @param maxNetOI Cap on |long OI - short OI|, in base units (1e18). Limits new one-sided exposure only;
    ///        closes can still leave net OI above it. Requires a non-zero maxGrossOI.
    function setOpenInterestCaps(bytes32 marketId, uint128 maxGrossOI, uint128 maxNetOI) external onlyAdmin {
        if (!(IMarketRegistry(marketRegistry).getMarket(marketId).vamm != address(0))) revert MarketNotFound();
        // Net OI can be pushed past its cap by building both sides and then closing one, so the
        // gross cap is the hard bound and a net cap is only accepted alongside one.
        if (maxNetOI != 0 && (maxGrossOI == 0 || maxNetOI > maxGrossOI)) revert InvalidOpenInterestCaps();

        openInterestCaps[marketId] = OpenInterestCaps({maxGrossOI: maxGrossOI, maxNetOI: maxNetOI});
        emit OpenInterestCapsSet(marketId, maxGrossOI, maxNetOI);
    }

    /// @notice True if the position kept its side (or closed) and did not grow.
    function _isPureReduction(int256 sizeBefore, int256 sizeAfter) internal pure returns (bool) {
        if (sizeBefore > 0) return sizeAfter >= 0 && sizeAfter <= sizeBefore;
        if (sizeBefore < 0) return sizeAfter <= 0 && sizeAfter >= sizeBefore;
        return false;
    }

    /// @notice Opens a new position or increases an existing one in a perpetual market.
    /// @param marketId The ID of the perpetual market.
    /// @param isLong True for a long position, false for a short position.
    /// @param size The amount of base asset to trade.
    /// @param amountLimit For longs (buying base): max quote to spend. For shorts (selling base): min quote to receive. 0 = no limit.
    function openPosition(bytes32 marketId, bool isLong, uint128 size, uint256 amountLimit) external override onlyAllowedTrader nonReentrant {
        // Settle funding for all active markets and the target market to ensure margin values are current
        _settleAccountFunding(msg.sender, marketId, false);

        // Block new positions if the user has a liquidatable position on the target market's quote
        // token (the collateral the trade draws on); other quote tokens' feeds cannot block the open.
        if (_hasLiquidatable(msg.sender, IMarketRegistry(marketRegistry).getMarket(marketId).quoteToken, bytes32(0))) {
            revert HasLiquidatablePosition();
        }

        if (!(IMarketRegistry(marketRegistry).isActive(marketId))) revert MarketNotActive();
        if (!(marketRiskParams[marketId].mmrBps > 0)) revert RiskParamsNotSet();
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (!(m.vamm != address(0))) revert MarketNotFound();
        if (!(size > 0)) revert SizeZero();

        // Snapshot aggregate OI only when the market has a cap (one storage read otherwise).
        OpenInterestCaps memory oiCaps = openInterestCaps[marketId];
        bool oiCapped = oiCaps.maxGrossOI != 0 || oiCaps.maxNetOI != 0;
        uint256 longOIBefore;
        uint256 shortOIBefore;
        uint256 markBefore;
        int256 sizeBefore = positions[msg.sender][marketId].size;
        if (oiCapped) {
            longOIBefore = totalLongOI[marketId];
            shortOIBefore = totalShortOI[marketId];
            markBefore = IVAMM(m.vamm).getMarkPrice();
        }

        // Fills the trade (a flip as a closing and an opening swap, each leg priced at its own fill).
        (int256 baseDelta, int256 quoteDelta, uint256 closeQuote, uint256 avgPrice) = abi.decode(
            _delegate(
                abi.encodeWithSignature(
                    "fillOpen(address,bytes32,bool,uint128,uint256)", msg.sender, marketId, isLong, size, amountLimit
                )
            ),
            (int256, int256, uint256, uint256)
        );
        _applyTrade(msg.sender, marketId, baseDelta, quoteDelta, false, closeQuote);

        // A trade that only shrinks the trader's position (no flip) is exempt from the OI caps and
        // maxPositionSize, matching closePosition. A flip is checked in full.
        bool pureReduction = _isPureReduction(sizeBefore, positions[msg.sender][marketId].size);
        if (oiCapped && !pureReduction) {
            _delegate(
                abi.encodeWithSignature(
                    "checkOpenInterestCaps(bytes32,uint256,uint256,uint256)",
                    marketId,
                    longOIBefore,
                    shortOIBefore,
                    markBefore
                )
            );
        }

        // Check position size limits
        PositionView storage position = positions[msg.sender][marketId];
        uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);

        MarketRiskParams memory rp = marketRiskParams[marketId];

        // Check max position size (0 = unlimited)
        uint256 maxSize = rp.maxPositionSize;
        if (maxSize > 0 && !pureReduction) {
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
    /// @dev Reverts while any of the account's positions on the same quote token is liquidatable: the
    ///      close's loss is paid from the balance that liquidation draws on, so a close pushed by a
    ///      second account could otherwise move that collateral out before the keeper acts. The trader
    ///      can cure the liquidatable position with addMargin, after which closes pass again.
    /// @param marketId The ID of the perpetual market.
    /// @param size The amount of base asset to trade for closing the position.
    /// @param amountLimit For closing longs (selling base): min quote to receive. For closing shorts (buying base): max quote to spend. 0 = no limit.
    function closePosition(bytes32 marketId, uint128 size, uint256 amountLimit) external override nonReentrant {
        _settleAccountFunding(msg.sender, marketId, true);
        if (_isLiquidatable(msg.sender, marketId)) revert PositionLiquidatable();
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (_hasLiquidatable(msg.sender, m.quoteToken, marketId)) revert HasLiquidatablePosition();
        if (!(IMarketRegistry(marketRegistry).isActive(marketId))) revert MarketNotActive();
        if (!(m.vamm != address(0))) revert MarketNotFound();
        if (!(size > 0)) revert SizeZero();

        PositionView storage position = positions[msg.sender][marketId];
        if (!(position.size != 0)) revert NoPosition();
        uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);
        if (!(uint256(size) <= absSize)) revert ReduceExceedsPosition();

        // Enforce minPositionSize on the requested remainder to prevent dust. A fill the vAMM reserve
        // floor clamps may leave less; the trader closes it in full once there is room.
        {
            uint256 remainingSize = absSize - uint256(size);
            uint256 minSize = marketRiskParams[marketId].minPositionSize;
            if (minSize > 0 && remainingSize > 0) {
                if (!(remainingSize >= minSize)) revert RemainingBelowMinCloseFull();
            }
        }

        IVAMM vamm = IVAMM(m.vamm);
        // If long, sell base to close; if short, buy base to close
        (int256 baseDelta, int256 quoteDelta, uint256 avgPrice) = position.size > 0
            ? vamm.sellBase(size, amountLimit)
            : vamm.buyBase(size, amountLimit);

        // Store realized PnL before applying trade
        int256 oldRealizedPnL = position.realizedPnL;
        _applyTrade(msg.sender, marketId, baseDelta, quoteDelta, false, 0);

        emit PositionClosed(
            msg.sender,
            marketId,
            size,
            avgPrice,
            position.realizedPnL - oldRealizedPnL
        );
    }

    /// @notice Liquidates a position that is below the maintenance margin requirement.
    /// @dev Can only be called by a whitelisted liquidator. Reverts if the vAMM mark before the close
    ///      is outside the market's band around the index (on the side that hurts the position). The
    ///      fill is capped at the size whose average price stays within mmrBps - liquidationPenaltyBps
    ///      of the index (see _maxLiquidationBase), with amountLimit scaled to the capped size. The
    ///      penalty is charged on the filled size. A partial liquidation must leave the remainder with
    ///      a margin ratio no worse than before, unless the fill was capped. The close trades through
    ///      the vAMM reserve floors (vAMM.liquidationSwap), so a parked reserve cannot block it.
    ///      Closed for LIQUIDATION_REACTION_WINDOW after the quote oracle's sequencer grace period
    ///      ends, since addMargin cannot value collateral during that grace period.
    /// @param account The address of the user whose position is being liquidated.
    /// @param marketId The ID of the market.
    /// @param size The amount of the position to liquidate.
    function liquidate(address account, bytes32 marketId, uint128 size, uint256 amountLimit) external override nonReentrant onlyWhitelistedLiquidator {
        _settleAccountFunding(account, marketId, true);
        if (!_isLiquidatable(account, marketId)) revert NotLiquidatable();
        if (!(IMarketRegistry(marketRegistry).isActive(marketId))) revert MarketNotActive();
        {
            // A failed call or short return data (an oracle without the function) reads as no grace.
            (bool ok, bytes memory data) =
                ICollateralVault(vault).oracle().staticcall(abi.encodeWithSignature("sequencerGraceEndsAt()"));
            if (ok && data.length >= 32) {
                uint256 graceEndsAt = abi.decode(data, (uint256));
                if (graceEndsAt != 0 && block.timestamp < graceEndsAt + LIQUIDATION_REACTION_WINDOW) {
                    revert LiquidationReactionWindow();
                }
            }
        }
        PositionView storage position = positions[account][marketId];
        MarketRiskParams memory rp = marketRiskParams[marketId];
        // Pre-trade size and effective margin, to compare the remainder of a partial liquidation with.
        uint256 absSizeBefore = uint256(position.size > 0 ? position.size : -position.size);
        (int256 effectiveMarginBefore,) = _marginState(account, marketId);
        {
            uint256 absSize = absSizeBefore;
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

        // Close position via vAMM, ignoring its reserve floors. The fill is capped at the size whose
        // average price stays within the fill bound; the rest of `size` is then left for later calls
        // and the remainder check below does not apply.
        uint256 filled;
        bool capped;
        {
            IVAMM vamm = IVAMM(m.vamm);
            bool closingLong = position.size > 0;
            _checkLiquidationMark(marketId, closingLong, vamm.getMarkPrice(), riskPrice);
            uint256 maxBase = _maxLiquidationBase(vamm, rp, closingLong, riskPrice);
            if (maxBase == 0) revert LiquidationPriceOutOfBand(vamm.getMarkPrice(), riskPrice);
            uint128 tradeSize = size;
            if (uint256(size) >= maxBase) {
                capped = true;
                tradeSize = uint128(maxBase);
                // Scale the quote limit with the size so it keeps the same average price.
                amountLimit = Calculations.mulDiv(amountLimit, maxBase, size);
            }
            (int256 baseDelta, int256 quoteDelta, ) = vamm.liquidationSwap(!closingLong, tradeSize, amountLimit);
            _applyTrade(account, marketId, baseDelta, quoteDelta, true, 0);
            filled = uint256(baseDelta >= 0 ? baseDelta : -baseDelta);
        }

        // Penalty on the filled size at the pre-trade risk price, capped at penaltyCap over the whole
        // liquidatable episode. Free collateral pays first, then surplus margin on the account's other
        // positions; only the part neither covers is taken from the margin of the size that stays open.
        (uint256 notional, uint256 penalty) = abi.decode(
            _delegate(
                abi.encodeWithSignature(
                    "chargeLiquidationPenalty(address,bytes32,address,uint256,uint256)",
                    account,
                    marketId,
                    m.quoteToken,
                    filled,
                    riskPrice
                )
            ),
            (uint256, uint256)
        );
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


            // Pay liquidator from collateral, insurance covers shortfall (up to available balance)
            insurancePayout = 0;
            uint256 uncompensatedBadDebt = 0;
            uint256 liqIncentiveInQuote = _notionalToQuoteUnits(liqIncentive, m.quoteToken);
            (, uint256 liqShortfall) = _collectQuote(account, msg.sender, m.quoteToken, liqIncentiveInQuote);
            if (liqShortfall > 0) {
                if (m.insuranceFund != address(0)) {
                    uint256 fundBalance = _insuranceTrackedBalance(m.insuranceFund);
                    uint256 actualPayout = liqShortfall > fundBalance ? fundBalance : liqShortfall;
                    // Sized by the fund's tracked balance, which is what payout enforces. If the
                    // payout still reverts, record the shortfall as bad debt and finish.
                    if (actualPayout > 0) {
                        try IInsuranceFund(m.insuranceFund).payout(msg.sender, actualPayout) {
                            insurancePayout = actualPayout;
                        } catch {
                            actualPayout = 0;
                        }
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

            // The protocol's share stays owed until the episode ends (below), so while size stays
            // open the account's collateral first covers the loss of the later calls.
            position.liquidationPenaltyOwed += routeAmount;
        }

        // A partial liquidation must not leave the remainder with a worse margin ratio than the
        // position had before (effective margin per unit of size; the index is unchanged), with
        // 1 wei of slack for the rounding of the released slice margin and of unrealized PnL. A fill
        // capped by the fill bound is exempt, so the rest can be liquidated once the mark allows.
        if (position.size != 0 && !capped) {
            uint256 absSizeAfter = uint256(position.size > 0 ? position.size : -position.size);
            (int256 effectiveMarginAfter,) = _marginState(account, marketId);
            if ((effectiveMarginAfter + 1) * int256(absSizeBefore) < effectiveMarginBefore * int256(absSizeAfter)) {
                revert MustLiquidateMore();
            }
        }

        // The episode ends once the position is healthy again (or closed): the protocol's owed share is
        // collected and the next episode gets a full cap.
        _endPenaltyEpisode(account, marketId);

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

    /// @notice Effective liquidation price band for a market, in bps.
    /// @dev The set band (or the default when unset), never wider than mmrBps - liquidationPenaltyBps,
    ///      so a liquidation inside the band leaves a position at the maintenance threshold enough
    ///      margin to fund the penalty.
    function liquidationPriceBandBps(bytes32 marketId) public view returns (uint256) {
        uint256 band = _liquidationPriceBandBps[marketId];
        if (band == 0) band = DEFAULT_LIQUIDATION_PRICE_BAND_BPS;
        MarketRiskParams storage rp = marketRiskParams[marketId];
        uint256 maxBand = rp.mmrBps > rp.liquidationPenaltyBps ? rp.mmrBps - rp.liquidationPenaltyBps : 0;
        return band < maxBand ? band : maxBand;
    }

    /// @notice Sets how far the pre-trade mark may be worse than the index for a liquidation.
    ///         0 restores the default (5%, capped at mmrBps - liquidationPenaltyBps).
    /// @param bandBps Band in bps; at least MIN_LIQUIDATION_BAND_BPS, and bandBps + liquidationPenaltyBps
    ///        must not exceed mmrBps, so the market's risk parameters must be set first.
    function setLiquidationPriceBand(bytes32 marketId, uint256 bandBps) external onlyAdmin {
        if (!(IMarketRegistry(marketRegistry).getMarket(marketId).vamm != address(0))) revert MarketNotFound();
        MarketRiskParams storage rp = marketRiskParams[marketId];
        if (bandBps != 0 && (bandBps < MIN_LIQUIDATION_BAND_BPS || bandBps + rp.liquidationPenaltyBps > rp.mmrBps)) {
            revert InvalidLiquidationPriceBand();
        }
        _liquidationPriceBandBps[marketId] = bandBps;
        emit LiquidationPriceBandSet(marketId, bandBps);
    }

    /// @notice Reverts if the vAMM mark before a liquidation is worse than the index by more than the
    ///         market's band.
    /// @dev Stops an attacker from pushing the vAMM price just before a liquidation to turn the
    ///      victim's loss into bad debt. Only the side that hurts the protocol is checked: a mark below
    ///      the index when closing a long, or above it when closing a short. The close's own price
    ///      impact is bounded separately by capping the filled size (_maxLiquidationBase).
    function _checkLiquidationMark(
        bytes32 marketId,
        bool closingLong,
        uint256 markPriceX18,
        uint256 indexPriceX18
    ) internal view {
        uint256 band = liquidationPriceBandBps(marketId);

        if (closingLong) {
            uint256 floorPx = Calculations.mulDiv(indexPriceX18, BPS_DENOMINATOR - band, BPS_DENOMINATOR);
            if (markPriceX18 < floorPx) revert LiquidationPriceOutOfBand(markPriceX18, indexPriceX18);
        } else {
            uint256 ceilPx = Calculations.mulDiv(indexPriceX18, BPS_DENOMINATOR + band, BPS_DENOMINATOR);
            if (markPriceX18 > ceilPx) revert LiquidationPriceOutOfBand(markPriceX18, indexPriceX18);
        }
    }

    /// @notice Largest base size a liquidation can close from the current vAMM reserves with its
    ///         average fill no worse than index * (1 - d) closing a long, or index * (1 + d) closing
    ///         a short, where d = mmrBps - liquidationPenaltyBps.
    /// @dev Bounds the close's own price impact, so a position at the maintenance edge always keeps
    ///      enough margin for its loss and the penalty. Constant product with no swap fee (the vAMM
    ///      fee is fixed at 0): selling dx fills at y / (x + dx), buying dx at y / (x - dx).
    function _maxLiquidationBase(IVAMM vamm, MarketRiskParams memory rp, bool closingLong, uint256 indexPriceX18)
        internal
        view
        returns (uint256)
    {
        uint256 d = rp.mmrBps > rp.liquidationPenaltyBps ? rp.mmrBps - rp.liquidationPenaltyBps : 0;
        (uint256 x, uint256 y) = vamm.getReserves();
        if (closingLong) {
            uint256 xMax = Calculations.mulDiv(
                y, 1e18, Calculations.mulDivRoundingUp(indexPriceX18, BPS_DENOMINATOR - d, BPS_DENOMINATOR)
            );
            return xMax > x ? xMax - x : 0;
        }
        uint256 xMin = Calculations.mulDivRoundingUp(
            y, 1e18, Calculations.mulDiv(indexPriceX18, BPS_DENOMINATOR + d, BPS_DENOMINATOR)
        );
        return x > xMin ? x - xMin : 0;
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

    /// @notice Gets the margin ratio for a user's position (1e18 = 100%).
    /// @dev Equity divided by notional, both at the risk (index) price as in isLiquidatable, with the
    ///      notional rounded up as in the maintenance margin. So a ratio below mmrBps * 1e14 means the
    ///      position is below maintenance. isLiquidatable is also true for a position that would carry
    ///      funding debt after settlement, which the ratio does not show.
    function getMarginRatio(address account, bytes32 marketId) external view override returns (uint256) {
        PositionView storage p = positions[account][marketId];
        if (p.size == 0) return type(uint256).max;
        uint256 absSize = uint256(p.size > 0 ? p.size : -p.size);
        uint256 notional = Calculations.mulDivRoundingUp(absSize, _getRiskPrice(_getMarketInfo(marketId)), 1e18);
        if (notional == 0) return type(uint256).max;
        (int256 effectiveMargin,) = _marginState(account, marketId);
        if (effectiveMargin <= 0) return 0;
        return uint256(effectiveMargin).mulDiv(1e18, notional);
    }

    /// @notice Gets the total value of a user's account.
    function getAccountValue(address account) external view override returns (int256) {
        uint256 collateralValue = ICollateralVault(vault).getAccountCollateralValueX18(account);
        return int256(collateralValue) - int256(_totalReservedMargin[account]);
    }


    /// @notice Sets a market's holding fee: a continuing fee per year, in bps, on every open position's
    ///         absolute notional at the index, charged at funding settlement and routed to the fee router.
    /// @dev Makes holding open interest cost something even for a delta-neutral pair, so filling a
    ///      gross OI cap is not free. Accrues the old rate up to now first. Runs in ClearingHouseLogic.
    function setHoldingFeeRate(bytes32 marketId, uint256 rateBpsPerYear) external onlyAdmin {
        _delegate(abi.encodeWithSignature("setHoldingFeeRate(bytes32,uint256)", marketId, rateBpsPerYear));
    }

    /// @notice Settles funding payments for a user in a perpetual market.
    /// @dev Also settles the account's other markets on the same quote token, so a funding debt carried
    ///      in one market is paid by a credit due in another whatever order they are settled in.
    function settleFunding(bytes32 marketId, address account) public override nonReentrant {
        _settleAccountFunding(account, marketId, true);
    }

    /// @notice Moves a market's booked funding surplus out of the vault to the market's insurance fund.
    /// @dev Callable by anyone: the amount can only go to the insurance fund, and only surplus that
    ///      payers have already paid into the vault is booked. Reverts while withdrawals are paused.
    ///      Runs in ClearingHouseLogic.
    function sweepFundingSurplus(bytes32 marketId) external nonReentrant {
        _delegate(abi.encodeWithSignature("sweepFundingSurplus(bytes32)", marketId));
    }

    // =========================================================================
    // Delegatecall stubs — forward to ClearingHouseLogic
    // =========================================================================

    /// @dev Forwards to ClearingHouseLogic.applyTrade via delegatecall.
    ///      The logic contract shares this contract's storage, msg.sender, and address(this).
    ///      `closeQuote` is the closing swap's quote for a flip filled as two swaps, else 0.
    function _applyTrade(
        address account,
        bytes32 marketId,
        int256 baseDelta,
        int256 quoteDelta,
        bool isLiquidation,
        uint256 closeQuote
    ) internal {
        _delegate(
            abi.encodeWithSignature(
                "applyTrade(address,bytes32,int256,int256,bool,uint256)",
                account,
                marketId,
                baseDelta,
                quoteDelta,
                isLiquidation,
                closeQuote
            )
        );
    }

    /// @dev Forwards to ClearingHouseLogic.settleFundingInternal via delegatecall.
    function _settleFundingInternal(bytes32 marketId, address account) internal {
        _delegate(abi.encodeWithSignature("settleFundingInternal(bytes32,address)", marketId, account));
    }

    /// @dev Forwards to ClearingHouseLogic.settleAccountFunding via delegatecall.
    ///      Settles the account's active markets (only those sharing marketId's quote token when
    ///      sameQuoteOnly) and marketId itself (when non-zero), then retries markets left in funding debt.
    function _settleAccountFunding(address account, bytes32 marketId, bool sameQuoteOnly) internal {
        _delegate(
            abi.encodeWithSignature("settleAccountFunding(address,bytes32,bool)", account, marketId, sameQuoteOnly)
        );
    }

    /// @notice Ends a position's liquidation penalty episode if it is no longer liquidatable.
    /// @dev Self-call only (ClearingHouseLogic.settleAccountFunding).
    function endPenaltyEpisode(address account, bytes32 marketId) external {
        if (msg.sender != address(this)) revert NotSelf();
        _endPenaltyEpisode(account, marketId);
    }

    /// @dev While the position is liquidatable, or its state cannot be read (e.g. its index is down),
    ///      nothing changes. Otherwise the running penalty total is reset and the protocol's owed share
    ///      of the episode's penalties is collected (_routeLiqPenalty).
    function _endPenaltyEpisode(address account, bytes32 marketId) internal {
        try this.isLiquidatable(account, marketId) returns (bool liquidatable) {
            if (liquidatable) return;
        } catch {
            return;
        }
        PositionView storage position = positions[account][marketId];
        position.liquidationPenaltyCharged = 0;
        uint256 owed = position.liquidationPenaltyOwed;
        position.liquidationPenaltyOwed = 0;
        _routeLiqPenalty(account, marketId, owed, IMarketRegistry(marketRegistry).getMarket(marketId));
    }

    /// @dev Delegatecalls ClearingHouseLogic with `data`, bubbling up any revert; returns its return data.
    function _delegate(bytes memory data) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = _logic.delegatecall(data);
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
    // Trader allowlist management
    // =========================================================================

    /// @notice Sets the address that can manage the trader allowlist.
    /// @param manager The new manager, or address(0) to leave management with the owner.
    function setAllowlistManager(address manager) external onlyAdmin {
        allowlistManager = manager;
        emit AllowlistManagerUpdated(manager);
    }

    /// @notice Turns allowlist enforcement on or off for all trader functions.
    function setAllowlistEnforced(bool enforced) external onlyAdmin {
        allowlistEnforced = enforced;
        emit AllowlistEnforcementUpdated(enforced);
    }

    /// @notice Adds or removes a batch of wallets from the trader allowlist.
    /// @param traders The wallets to update.
    /// @param isAllowed Whether the wallets can call trader functions.
    function setAllowedTraders(address[] calldata traders, bool isAllowed) external onlyAllowlistManager {
        for (uint256 i = 0; i < traders.length; i++) {
            allowedTraders[traders[i]] = isAllowed;
            emit TraderAllowlistUpdated(traders[i], isAllowed);
        }
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

    /// @dev Value of a quote-token amount as margin: the vault's haircut oracle value, with the token
    ///      price capped at par (1e18 per whole token, before the haircut). Realized PnL and funding
    ///      are debited at par, so a token must not back more margin than it pays at that rate.
    function _quoteValueX18(address quoteToken, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 v = ICollateralVault(vault).getTokenValueX18(quoteToken, amount);
        if (!(v > 0)) revert QuoteTokenValuationUnavailable();
        ICollateralVault.CollateralConfig memory cfg = ICollateralVault(vault).getConfig(quoteToken);
        uint256 par = Calculations.mulDiv(
            Calculations.mulDiv(1e18, amount, cfg.baseUnit), BPS_DENOMINATOR - cfg.haircutBps, BPS_DENOMINATOR
        );
        return v < par ? v : par;
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
        uint256 amount
    ) internal returns (uint256 actualReceived, uint256 shortfall) {
        if (amount == 0) {
            return (0, 0);
        }

        uint256 balance = ICollateralVault(vault).balanceOf(account, quoteToken);
        uint256 available;
        {
            // Free is the share of the balance whose haircut value exceeds the reserved margin, as the
            // margin, withdrawal and health checks value the balance.
            uint256 reservedForToken = _reservedMarginForToken(account, quoteToken);
            if (reservedForToken == 0) {
                available = balance;
            } else if (balance > 0) {
                uint256 balanceValueX18 = _quoteValueX18(quoteToken, balance);
                available = balanceValueX18 > reservedForToken
                    ? Calculations.mulDiv(balance, balanceValueX18 - reservedForToken, balanceValueX18)
                    : 0;
            }
        }
        uint256 seized = amount <= available ? amount : available;
        if (seized < amount) {
            seized += abi.decode(
                _delegate(
                    abi.encodeWithSignature(
                        "drawSurplusMargin(address,address,uint256,uint256,bytes32)",
                        account,
                        quoteToken,
                        amount - seized,
                        balance - seized,
                        bytes32(0)
                    )
                ),
                (uint256)
            );
        }
        actualReceived = seized;

        if (seized > 0) {
            ICollateralVault(vault).seize(account, recipient, quoteToken, seized);
        }
        shortfall = amount - seized;
    }

    /// @dev Amount the insurance fund can pay out: its tracked balance, not its raw token balance
    /// (a plain transfer raises the latter without making it payable).
    function _insuranceTrackedBalance(address fund) internal view returns (uint256) {
        return IInsuranceFund(fund).totalReceived() - IInsuranceFund(fund).totalPaid();
    }

    /// @notice Collects a liquidation penalty's protocol share for the market's fee router.
    /// @dev Free collateral first, then surplus margin on the account's positions (_collectQuote); the
    ///      part neither covers is recorded as bad debt, which the insurance fund does not pay.
    function _routeLiqPenalty(
        address account,
        bytes32 marketId,
        uint256 amount,
        IMarketRegistry.Market memory m
    ) internal {
        if (amount == 0 || m.feeRouter == address(0)) return;

        uint256 penaltyInQuoteDecimals = _notionalToQuoteUnits(amount, m.quoteToken);

        if (penaltyInQuoteDecimals == 0) return;

        (uint256 seized, uint256 shortfall) = _collectQuote(account, m.feeRouter, m.quoteToken, penaltyInQuoteDecimals);
        if (shortfall > 0) {
            totalBadDebt += shortfall;
            emit BadDebtRecorded(account, marketId, shortfall);
        }

        // Booked to the router's vault balance; pushed and split in one self-call, or left booked
        // for sweepFees if that fails, so the caller never reverts on the push.
        if (seized > 0) {
            (bool ok,) = address(this).call(abi.encodeCall(this.pushFee, (m.feeRouter, m.quoteToken, seized, true)));
            if (!ok) pendingLiqPenalties[m.feeRouter][m.quoteToken] += seized;
        }
    }

    /// @notice Pushes trade fees and liquidation penalty shares that stayed booked in the vault to
    ///         their fee router, which splits them.
    /// @dev Callable by anyone: the amounts can only go to the router. Reverts, keeping them booked,
    ///      while the push still fails (e.g. withdrawals of the token paused).
    function sweepFees(address feeRouter, address token) external nonReentrant {
        uint256 tradeFees = pendingTradeFees[feeRouter][token];
        uint256 liqPenalties = pendingLiqPenalties[feeRouter][token];
        delete pendingTradeFees[feeRouter][token];
        delete pendingLiqPenalties[feeRouter][token];
        if (tradeFees > 0) _sendFee(feeRouter, token, tradeFees, false);
        if (liqPenalties > 0) _sendFee(feeRouter, token, liqPenalties, true);
        emit FeesSwept(feeRouter, token, tradeFees, liqPenalties);
    }

    /// @notice Withdraws a fee booked on a fee router's vault balance to the router and runs its split.
    /// @dev Self-call only, so a failing withdrawal or split reverts both and the fee stays booked.
    function pushFee(address feeRouter, address token, uint256 amount, bool isLiquidationPenalty) external {
        if (msg.sender != address(this)) revert NotSelf();
        _sendFee(feeRouter, token, amount, isLiquidationPenalty);
    }

    function _sendFee(address feeRouter, address token, uint256 amount, bool isLiquidationPenalty) internal {
        uint256 received = ICollateralVault(vault).withdrawFor(feeRouter, token, amount, feeRouter);
        if (isLiquidationPenalty) IFeeRouter(feeRouter).onLiquidationPenalty(received);
        else IFeeRouter(feeRouter).onTradeFee(received);
    }
}
