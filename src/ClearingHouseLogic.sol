// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IClearingHouse} from "./Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "./Interfaces/ICollateralVault.sol";
import {IMarketRegistry} from "./Interfaces/IMarketRegistry.sol";
import {IVAMM} from "./Interfaces/IVAMM.sol";
import {IOracle} from "./Interfaces/IOracle.sol";
import {IInsuranceFund} from "./Interfaces/IInsuranceFund.sol";
import {IFeeRouter} from "./Interfaces/IFeeRouter.sol";
import {Calculations} from "./Libraries/Calculations.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Logic contract for ClearingHouse heavy functions, called via delegatecall.
/// @dev Storage layout MUST mirror ClearingHouse exactly (slots 11-14 are placeholders).
///      Any addition/removal of storage variables in ClearingHouse must be reflected here.
contract ClearingHouseLogic {
    using Calculations for uint256;

    // =========================================================================
    // Storage layout — must mirror ClearingHouse exactly
    // =========================================================================

    address public vault;           // slot 0
    address public marketRegistry;  // slot 1
    mapping(address => bool) public whitelistedLiquidators; // slot 2
    mapping(address => mapping(bytes32 => IClearingHouse.PositionView)) internal positions; // slot 3
    mapping(address => uint256) internal _totalReservedMargin; // slot 4
    mapping(bytes32 => IClearingHouse.MarketRiskParams) internal marketRiskParams; // slot 5
    mapping(address => bytes32[]) internal _userActiveMarkets; // slot 6
    mapping(address => mapping(bytes32 => bool)) internal _isMarketActive; // slot 7
    uint256 internal totalBadDebt; // slot 8
    mapping(bytes32 => uint256) internal totalLongOI; // slot 9
    mapping(bytes32 => uint256) internal totalShortOI; // slot 10
    // Slots 11-14 are used by ClearingHouse only; they are held here so the slots after them line up.
    address private _slot11AllowlistManager; // slot 11
    bool private _slot11AllowlistEnforced; // slot 11 (packed)
    mapping(address => bool) private _slot12AllowedTraders; // slot 12
    mapping(bytes32 => IClearingHouse.OpenInterestCaps) private _slot13OpenInterestCaps; // slot 13
    mapping(bytes32 => uint256) private _slot14LiquidationPriceBandBps; // slot 14
    mapping(bytes32 => uint256) internal fundingSurplus; // slot 15
    mapping(address => mapping(address => uint256)) internal pendingTradeFees; // slot 16
    mapping(address => mapping(address => uint256)) internal pendingLiqPenalties; // slot 17

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 private constant BPS_DENOMINATOR = 10_000;

    // =========================================================================
    // Events — signatures must match IClearingHouse exactly so that events
    // emitted via delegatecall are decodable from the ClearingHouse ABI.
    // =========================================================================

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
    event FundingSettled(bytes32 indexed marketId, address indexed account, int256 fundingPayment);
    event BadDebtRecorded(address indexed account, bytes32 indexed marketId, uint256 shortfall);
    event FundingSurplusSwept(bytes32 indexed marketId, address indexed insuranceFund, uint256 amount);

    // =========================================================================
    // Errors — must match ClearingHouse custom errors exactly
    // =========================================================================

    error OracleNotSet();
    error OraclePriceZero();
    error MarketNotFound();
    error QuoteTokenValuationUnavailable();
    error QuoteOracleUnavailable();
    error InsufficientQuoteCollateral();
    error InsufficientQuoteForFee();
    error IMRBreach();
    error ImmediatelyLiquidatable();
    error AmountZero();
    error ZeroAddress();

    // =========================================================================
    // External entry points (delegatecall targets from ClearingHouse)
    // =========================================================================

    function applyTrade(
        address account,
        bytes32 marketId,
        int256 baseDelta,
        int256 quoteDelta,
        bool isLiquidation,
        uint256 closeQuote
    ) external {
        _applyTrade(account, marketId, baseDelta, quoteDelta, isLiquidation, closeQuote);
    }

    /// @notice Fills an openPosition trade on the vAMM; ClearingHouse then applies it with applyTrade.
    /// @dev Delegatecall target of ClearingHouse.openPosition. A flip (an opposite-side trade larger
    ///      than the position) is filled as two swaps, the closing size first and then the rest, so
    ///      the closed position is realized at the closing swap's price and the new position entered
    ///      at the opening swap's price, as closePosition followed by openPosition would. The caller's
    ///      amountLimit applies to the summed quote (scaled to the filled size if a reserve floor
    ///      clamps a leg); if the closing swap is clamped, the opening one is skipped.
    ///      Returns the trade deltas, the closing swap quote of a flip (else 0) and the average price.
    function fillOpen(address account, bytes32 marketId, bool isLong, uint128 size, uint256 amountLimit)
        external
        returns (int256 baseDelta, int256 quoteDelta, uint256 closeQuote, uint256 avgPriceX18)
    {
        IVAMM vamm = IVAMM(IMarketRegistry(marketRegistry).getMarket(marketId).vamm);
        int256 s0 = positions[account][marketId].size;
        uint256 absS0 = uint256(s0 >= 0 ? s0 : -s0);
        if (s0 == 0 || (s0 > 0) == isLong || uint256(size) <= absS0) {
            (baseDelta, quoteDelta, avgPriceX18) = _swap(vamm, isLong, size, amountLimit);
        } else {
            (baseDelta, quoteDelta,) = _swap(vamm, isLong, uint128(absS0), 0);
            closeQuote = uint256(quoteDelta >= 0 ? quoteDelta : -quoteDelta);
            if (uint256(baseDelta >= 0 ? baseDelta : -baseDelta) == absS0) {
                (int256 b2, int256 q2,) = _swap(vamm, isLong, size - uint128(absS0), 0);
                baseDelta += b2;
                quoteDelta += q2;
            }
            uint256 filled = uint256(baseDelta >= 0 ? baseDelta : -baseDelta);
            uint256 totalQuote = uint256(quoteDelta >= 0 ? quoteDelta : -quoteDelta);
            if (amountLimit != 0) {
                // Same rule as the vAMM: a total for `size`, scaled to the filled size.
                require(
                    isLong
                        ? totalQuote <= Calculations.mulDiv(amountLimit, filled, size)
                        : totalQuote >= Calculations.mulDivRoundingUp(amountLimit, filled, size),
                    "slippage"
                );
            }
            avgPriceX18 = Calculations.mulDiv(totalQuote, 1e18, filled);
        }
    }

    function _swap(IVAMM vamm, bool isLong, uint128 size, uint256 limit)
        internal
        returns (int256, int256, uint256)
    {
        return isLong ? vamm.buyBase(size, limit) : vamm.sellBase(size, limit);
    }

    function settleFundingInternal(bytes32 marketId, address account) external {
        _settleFundingInternal(marketId, account);
    }

    /// @notice Settles funding for `account` in its active markets and in `marketId` (skipped when 0).
    /// @dev With `sameQuoteOnly`, only markets sharing `marketId`'s quote token are settled, so markets
    ///      on other quote tokens cannot block a close or liquidation. Markets left carrying funding
    ///      debt are settled again afterwards with the free collateral left at the end. A credit in
    ///      another market is reserved as that market's margin and does not pay the debt (finding 61).
    function settleAccountFunding(address account, bytes32 marketId, bool sameQuoteOnly) external {
        address quote;
        if (sameQuoteOnly) quote = IMarketRegistry(marketRegistry).getMarket(marketId).quoteToken;
        bytes32[] memory markets = _userActiveMarkets[account];
        bool[] memory settled = new bool[](markets.length);
        for (uint256 i = 0; i < markets.length; i++) {
            if (!sameQuoteOnly || IMarketRegistry(marketRegistry).getMarket(markets[i]).quoteToken == quote) {
                _settleFundingInternal(markets[i], account);
                settled[i] = true;
            }
        }
        if (marketId != bytes32(0) && !_isMarketActive[account][marketId]) {
            _settleFundingInternal(marketId, account);
        }
        for (uint256 i = 0; i < markets.length; i++) {
            if (settled[i] && positions[account][markets[i]].fundingDebt != 0) {
                _settleFundingInternal(markets[i], account);
            }
        }
    }

    /// @notice Moves a market's booked funding surplus out of the vault to the market's insurance fund.
    /// @dev Delegatecall target of ClearingHouse.sweepFundingSurplus (which holds the reentrancy guard).
    function sweepFundingSurplus(bytes32 marketId) external {
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (!(m.vamm != address(0))) revert MarketNotFound();
        uint256 amount = fundingSurplus[marketId];
        if (amount == 0) revert AmountZero();
        if (m.insuranceFund == address(0)) revert ZeroAddress();
        fundingSurplus[marketId] = 0;

        // The payers' excess debits sit in the vault with no owner: book them to the clearing house,
        // withdraw them, and donate them to the fund (pull pattern).
        ICollateralVault(vault).settlePnL(address(this), m.quoteToken, int256(amount));
        uint256 received = ICollateralVault(vault).withdrawFor(address(this), m.quoteToken, amount, address(this));
        SafeERC20.forceApprove(IERC20(m.quoteToken), m.insuranceFund, received);
        IInsuranceFund(m.insuranceFund).donate(received);
        emit FundingSurplusSwept(marketId, m.insuranceFund, received);
    }

    /// @notice Takes up to `need` token units of surplus margin from the account's positions in
    ///         `quoteToken` (except `skipMarket`) into free collateral; see _drawSurplusMargin.
    /// @dev Delegatecall target of ClearingHouse._collectQuote.
    function drawSurplusMargin(address account, address quoteToken, uint256 need, uint256 balanceLeft, bytes32 skipMarket)
        external
        returns (uint256)
    {
        return _drawSurplusMargin(account, quoteToken, need, balanceLeft, skipMarket);
    }

    /// @notice Makes a liquidation penalty of `penalty` (1e18 quote value) collectable from the account.
    /// @dev Delegatecall target of ClearingHouse.liquidate, after the trade. Free collateral (which holds
    ///      the closed slice's released margin) pays first. What it cannot cover is drawn from surplus
    ///      margin on the account's other positions, and only the rest is cut from the margin of the
    ///      liquidated position's remaining size, so a partial liquidation's remainder keeps its margin
    ///      whenever the account holds surplus elsewhere.
    function freePenaltyCollateral(address account, bytes32 marketId, address quoteToken, uint256 penalty) external {
        uint256 freeValue = _freeQuoteValue(account, quoteToken);
        if (penalty > freeValue) {
            uint256 balance = ICollateralVault(vault).balanceOf(account, quoteToken);
            uint256 reservedUnits = _notionalToQuoteUnits(_reservedMarginForToken(account, quoteToken), quoteToken);
            _drawSurplusMargin(
                account,
                quoteToken,
                _notionalToQuoteUnits(penalty - freeValue, quoteToken),
                balance < reservedUnits ? balance : reservedUnits,
                marketId
            );
            freeValue = _freeQuoteValue(account, quoteToken);
        }
        if (penalty > freeValue) _reduceMargin(account, positions[account][marketId], penalty - freeValue);
    }

    /// @notice True if settling the account's funding now would leave the position in `marketId`
    ///         carrying funding debt.
    /// @dev View behind ClearingHouse._isLiquidatable (reached through ClearingHouse.delegateView).
    ///      Replays settleAccountFunding over the account's markets on the same quote token, in the
    ///      same order and with the same rules: a credit adds its tokens to the balance and their value
    ///      to that market's margin; a debit (pending funding net of carried debt) is paid up to the
    ///      paying market's margin plus the free collateral value and the balance, the rest staying as
    ///      debt; then markets left in debt are retried. Pending funding is read from the vAMMs'
    ///      current indices.
    function carriesFundingDebt(address account, bytes32 marketId) external view returns (bool) {
        if (_pendingFunding(account, marketId) - int256(positions[account][marketId].fundingDebt) >= 0) {
            return false;
        }
        address quote = IMarketRegistry(marketRegistry).getMarket(marketId).quoteToken;
        // Funding is not settled while the quote oracle is down: the carried debt stays as it is.
        if (!_quoteOracleLive(quote)) return positions[account][marketId].fundingDebt != 0;

        bytes32[] memory markets = _userActiveMarkets[account];
        uint256 n = markets.length;
        int256[] memory net = new int256[](n);
        uint256[] memory margin = new uint256[](n);
        bool[] memory sameQuote = new bool[](n);
        uint256 target;
        for (uint256 i = 0; i < n; i++) {
            if (IMarketRegistry(marketRegistry).getMarket(markets[i]).quoteToken != quote) continue;
            sameQuote[i] = true;
            IClearingHouse.PositionView storage p = positions[account][markets[i]];
            net[i] = _pendingFunding(account, markets[i]) - int256(p.fundingDebt);
            margin[i] = p.margin;
            if (markets[i] == marketId) target = i;
        }

        uint256 bal = ICollateralVault(vault).balanceOf(account, quote);
        uint256 reserved = _reservedMarginForToken(account, quote);
        uint256 baseUnit = ICollateralVault(vault).getConfig(quote).baseUnit;
        // Pass 0 settles every market; pass 1 retries those left in debt.
        for (uint256 pass = 0; pass < 2; pass++) {
            for (uint256 i = 0; i < n; i++) {
                int256 x = net[i];
                if (!sameQuote[i] || x == 0 || (pass == 1 && x > 0)) continue;
                if (x > 0) {
                    uint256 units = Calculations.mulDiv(uint256(x), baseUnit, 1e18);
                    uint256 v = _quoteValueX18(quote, units);
                    bal += units;
                    margin[i] += v;
                    reserved += v;
                    net[i] = 0;
                } else {
                    uint256 debit = uint256(-x);
                    uint256 value = bal == 0 ? 0 : _quoteValueX18(quote, bal);
                    uint256 cap = margin[i] + (value > reserved ? value - reserved : 0);
                    uint256 paidX18 = debit < cap ? debit : cap;
                    uint256 units = Calculations.mulDivRoundingUp(paidX18, baseUnit, 1e18);
                    if (units > bal) {
                        units = bal;
                        paidX18 = Calculations.mulDiv(bal, 1e18, baseUnit);
                    }
                    bal -= units;
                    uint256 cut = paidX18 < margin[i] ? paidX18 : margin[i];
                    margin[i] -= cut;
                    reserved = reserved > cut ? reserved - cut : 0;
                    net[i] = -int256(debit - paidX18);
                }
            }
        }
        return net[target] < 0;
    }

    /// @dev Funding not yet settled for a position, from the vAMM's current (accrued) indices.
    function _pendingFunding(address account, bytes32 marketId) internal view returns (int256) {
        IClearingHouse.PositionView storage position = positions[account][marketId];
        if (position.size == 0) return 0;
        IVAMM vamm = IVAMM(IMarketRegistry(marketRegistry).getMarket(marketId).vamm);
        uint256 payDelta;
        uint256 receiveDelta;
        if (position.size > 0) {
            payDelta = vamm.currentCumulativeLongPayPerUnitX18() - position.lastFundingPayIndex;
            receiveDelta = vamm.currentCumulativeLongReceivePerUnitX18() - position.lastFundingReceiveIndex;
        } else {
            payDelta = vamm.currentCumulativeShortPayPerUnitX18() - position.lastFundingPayIndex;
            receiveDelta = vamm.currentCumulativeShortReceivePerUnitX18() - position.lastFundingReceiveIndex;
        }
        uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);
        return receiveDelta >= payDelta
            ? int256(Calculations.mulDiv(receiveDelta - payDelta, absSize, 1e18))
            : -int256(Calculations.mulDiv(payDelta - receiveDelta, absSize, 1e18));
    }

    /// @dev Value of the account's quote-token balance above the margin reserved on that token.
    function _freeQuoteValue(address account, address quoteToken) internal view returns (uint256) {
        uint256 balance = ICollateralVault(vault).balanceOf(account, quoteToken);
        uint256 value = balance == 0 ? 0 : _quoteValueX18(quoteToken, balance);
        uint256 reserved = _reservedMarginForToken(account, quoteToken);
        return value > reserved ? value - reserved : 0;
    }

    // =========================================================================
    // Core logic (moved from ClearingHouse)
    // =========================================================================

    /// @param closeQuote For a flip filled as two swaps, the quote of the swap that closed the old
    ///        position (0 otherwise): the closed size is realized at its price and the new position
    ///        entered at the price of the rest of the quote.
    function _applyTrade(
        address account,
        bytes32 marketId,
        int256 baseDelta,
        int256 quoteDelta,
        bool isLiquidation,
        uint256 closeQuote
    ) internal {
        IClearingHouse.PositionView storage position = positions[account][marketId];
        int256 s0 = position.size;
        int256 s1 = s0 + baseDelta;
        uint256 absBaseDelta = uint256(baseDelta >= 0 ? baseDelta : -baseDelta);
        uint256 absS0 = uint256(s0 >= 0 ? s0 : -s0);
        uint256 absS1 = uint256(s1 >= 0 ? s1 : -s1);
        uint256 absQuote = uint256(quoteDelta >= 0 ? quoteDelta : -quoteDelta);
        uint256 tradeFee = 0;

        uint256 execPxX18 = Calculations.mulDiv(absQuote, 1e18, absBaseDelta);

        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        IClearingHouse.MarketRiskParams memory rp = marketRiskParams[marketId];

        int256 realized = 0;
        if (s0 == 0) {
            position.entryPriceX18 = execPxX18;
        } else if ((s0 > 0 && baseDelta > 0) || (s0 < 0 && baseDelta < 0)) {
            uint256 oldNotional = absS0 * position.entryPriceX18;
            uint256 newNotional = oldNotional + (absBaseDelta * execPxX18);
            position.entryPriceX18 = newNotional / absS1;
        } else {
            uint256 reduceAmt = absBaseDelta <= absS0 ? absBaseDelta : absS0;
            bool flips = (s0 > 0 && s1 < 0) || (s0 < 0 && s1 > 0);
            // A flip filled as two swaps prices each leg at its own fill.
            uint256 closePxX18 = flips && closeQuote != 0 ? Calculations.mulDiv(closeQuote, 1e18, absS0) : execPxX18;
            if (s0 > 0) {
                realized = (int256(closePxX18) - int256(position.entryPriceX18)) * int256(reduceAmt) / 1e18;
            } else {
                realized = (int256(position.entryPriceX18) - int256(closePxX18)) * int256(reduceAmt) / 1e18;
            }

            if (absS1 == 0) {
                position.entryPriceX18 = 0;
            } else if (flips) {
                position.entryPriceX18 =
                    closeQuote != 0 ? Calculations.mulDiv(absQuote - closeQuote, 1e18, absS1) : execPxX18;
            }
        }

        position.size = s1;
        position.realizedPnL += realized;

        {
            uint256 oldLong = s0 > 0 ? uint256(s0) : 0;
            uint256 newLong = s1 > 0 ? uint256(s1) : 0;
            uint256 oldShort = s0 < 0 ? uint256(-s0) : 0;
            uint256 newShort = s1 < 0 ? uint256(-s1) : 0;
            totalLongOI[marketId] = totalLongOI[marketId] - oldLong + newLong;
            totalShortOI[marketId] = totalShortOI[marketId] - oldShort + newShort;
            IVAMM(m.vamm).updateOpenInterest(totalLongOI[marketId], totalShortOI[marketId]);
        }

        {
            IVAMM vammFI = IVAMM(m.vamm);
            if (s1 > 0 && s0 <= 0) {
                position.lastFundingPayIndex = vammFI.cumulativeLongPayPerUnitX18();
                position.lastFundingReceiveIndex = vammFI.cumulativeLongReceivePerUnitX18();
                position.lastFundingSurplusIndex = vammFI.cumulativeLongSurplusPerUnitX18();
            } else if (s1 < 0 && s0 >= 0) {
                position.lastFundingPayIndex = vammFI.cumulativeShortPayPerUnitX18();
                position.lastFundingReceiveIndex = vammFI.cumulativeShortReceivePerUnitX18();
                position.lastFundingSurplusIndex = vammFI.cumulativeShortSurplusPerUnitX18();
            }
        }

        if (s0 == 0 && s1 != 0) {
            _addActiveMarket(account, marketId);
        } else if (s1 == 0) {
            _removeActiveMarket(account, marketId);
        }

        // A realized profit backs margin at the haircut value of the tokens actually credited, as
        // the margin checks value the balance, so the credit never leaves reserved margin unbacked.
        uint256 creditValue;
        if (realized != 0) {
            // Only a liquidation may realize a loss beyond the account's vault balance.
            uint256 credited = _settlePnLInVault(account, marketId, realized, isLiquidation, 0, type(uint256).max);
            if (realized > 0) creditValue = _quoteValueX18(m.quoteToken, credited);
        }

        // Margin share of the closed slice, taken from the margin before any realized loss.
        bool reducing = s0 != 0 && ((s0 > 0) != (baseDelta > 0));
        uint256 sliceMargin;
        if (reducing) {
            uint256 reduceAmt = absBaseDelta <= absS0 ? absBaseDelta : absS0;
            sliceMargin = (position.margin * reduceAmt) / absS0;
        }

        if (realized > 0) {
            position.margin += creditValue;
            _totalReservedMargin[account] += creditValue;
        } else if (realized < 0) {
            // The closed slice's own margin absorbs its loss; only the excess is charged to the
            // margin of the size that stays open.
            uint256 loss = uint256(-realized);
            loss = loss > sliceMargin ? loss - sliceMargin : 0;
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

        if (s0 == 0 || ((s0 > 0 && baseDelta > 0) || (s0 < 0 && baseDelta < 0))) {
            uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
            uint256 oraclePrice = _getRiskPrice(m);
            uint256 imrPrice = markPrice > oraclePrice ? markPrice : oraclePrice;
            // Rounded up at both steps so the slices' reserves always cover the requirement on the
            // whole position, which is rounded down once.
            uint256 tradeNotional = Calculations.mulDivRoundingUp(absBaseDelta, imrPrice, 1e18);
            uint256 marginRequired = Calculations.mulDivRoundingUp(tradeNotional, rp.imrBps, BPS_DENOMINATOR);
            if (!isLiquidation && marginRequired > 0) {
                _ensureAvailableCollateral(account, marginRequired, m.quoteToken);
            }
            position.margin += marginRequired;
            _totalReservedMargin[account] += marginRequired;
        } else {
            // After a loss, release the slice's pre-loss margin share (its loss was netted against
            // it above). After a gain outside a liquidation, release the slice's pre-trade share plus
            // the whole credited profit, which is already in the vault balance, so the size that stays
            // open keeps only its own share. A liquidation in profit or a break-even releases a
            // proportional share.
            uint256 marginRelease;
            if (realized < 0) {
                marginRelease = sliceMargin <= position.margin ? sliceMargin : position.margin;
            } else if (realized > 0 && !isLiquidation) {
                marginRelease = sliceMargin + creditValue;
            } else {
                uint256 reduceAmt = absBaseDelta <= absS0 ? absBaseDelta : absS0;
                marginRelease = (position.margin * reduceAmt) / absS0;
            }
            position.margin -= marginRelease;
            _totalReservedMargin[account] -= marginRelease;

            // Funding debt carried on the side being reduced is paid from the balance, which now
            // includes any profit this trade realized.
            if (position.fundingDebt != 0) {
                _settleFundingDebt(account, marketId, position, m.quoteToken, absBaseDelta >= absS0, isLiquidation);
            }

            if (absBaseDelta > absS0) {
                uint256 openAmt = absBaseDelta - absS0;
                uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
                uint256 oraclePrice = _getRiskPrice(m);
                uint256 imrPrice = markPrice > oraclePrice ? markPrice : oraclePrice;
                uint256 openNotional = Calculations.mulDivRoundingUp(openAmt, imrPrice, 1e18);
                uint256 marginRequired = Calculations.mulDivRoundingUp(openNotional, rp.imrBps, BPS_DENOMINATOR);
                if (!isLiquidation && marginRequired > 0) {
                    _ensureAvailableCollateral(account, marginRequired, m.quoteToken);
                }
                position.margin += marginRequired;
                _totalReservedMargin[account] += marginRequired;
            }
        }

        if (!isLiquidation && absBaseDelta > 0) {
            if (m.feeBps > 0) {
                uint256 notional2 = Calculations.mulDivRoundingUp(absBaseDelta, execPxX18, 1e18);
                tradeFee = Calculations.mulDivRoundingUp(notional2, m.feeBps, BPS_DENOMINATOR);
            }
            // Every voluntary trade that opens, increases or flips must leave the quote collateral
            // value at or above reserved margin plus fee, even on a zero-fee market. A pure
            // reduction checks only its fee, so de-risking is not blocked.
            bool pureReduction = (s0 > 0 && s1 >= 0 && s1 < s0) || (s0 < 0 && s1 <= 0 && s1 > s0);
            if (tradeFee > 0 || !pureReduction) {
                _ensureAvailableCollateral(account, tradeFee, m.quoteToken);
            }
            if (tradeFee > 0) {
                _routeTradeFee(account, tradeFee, m);
            }
        }

        if (!isLiquidation && absS1 > 0) {
            uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
            uint256 oraclePrice = _getRiskPrice(m);
            uint256 imrPrice = markPrice > oraclePrice ? markPrice : oraclePrice;
            uint256 notional = absS1.mulDiv(imrPrice, 1e18);
            uint256 requiredMargin = notional.mulDiv(rp.imrBps, BPS_DENOMINATOR);

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
            // IMR applies to trades that open, increase or flip. A trade that only shrinks the
            // position on the same side adds no exposure and is bounded by the maintenance check.
            bool onlyReduces = s0 != 0 && (s0 > 0) == (s1 > 0) && absS1 < absS0;
            if (!onlyReduces && !(marginValue >= requiredMargin)) revert IMRBreach();

            {
                int256 unrealizedPnL = _computeUnrealizedPnL(position, oraclePrice);
                int256 effectiveMargin = int256(marginValue) + unrealizedPnL - int256(position.fundingDebt);
                uint256 riskNotional = Calculations.mulDivRoundingUp(absS1, oraclePrice, 1e18);
                uint256 maintenanceMargin = Calculations.mulDivRoundingUp(riskNotional, rp.mmrBps, BPS_DENOMINATOR);
                if (!(effectiveMargin >= int256(maintenanceMargin))) revert ImmediatelyLiquidatable();
            }
        }

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

    function _settleFundingInternal(bytes32 marketId, address account) internal {
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        if (!(m.vamm != address(0))) revert MarketNotFound();

        IVAMM vamm = IVAMM(m.vamm);

        // No funding accrues while the market is not active: its traders cannot top up, trade or close.
        if (!IMarketRegistry(marketRegistry).isActive(marketId)) {
            vamm.skipFunding();
            return;
        }

        // Funding only accrues while it can be settled in the quote token. If the quote oracle is
        // unavailable (stale round, sequencer down or in grace period), advance the funding clock
        // without accruing so payers are not charged for time in which they cannot act.
        // The same holds while the market's index oracle (the risk price) is down, since positions can
        // then be neither closed nor liquidated.
        if (!_quoteOracleLive(m.quoteToken) || !_indexOracleLive(m.oracle)) {
            vamm.skipFunding();
            return;
        }

        (uint256 longPay, uint256 longReceive, uint256 shortPay, uint256 shortReceive) = vamm.pokeFunding();

        IClearingHouse.PositionView storage position = positions[account][marketId];

        uint256 currentPay;
        uint256 currentReceive;
        uint256 currentSurplus;
        if (position.size > 0) {
            currentPay = longPay;
            currentReceive = longReceive;
            currentSurplus = vamm.cumulativeLongSurplusPerUnitX18();
        } else if (position.size < 0) {
            currentPay = shortPay;
            currentReceive = shortReceive;
            currentSurplus = vamm.cumulativeShortSurplusPerUnitX18();
        } else {
            position.lastFundingPayIndex = 0;
            position.lastFundingReceiveIndex = 0;
            position.lastFundingSurplusIndex = 0;
            return;
        }

        uint256 payDelta = currentPay - position.lastFundingPayIndex;
        uint256 receiveDelta = currentReceive - position.lastFundingReceiveIndex;
        uint256 debt = position.fundingDebt;

        if (payDelta != 0 || receiveDelta != 0 || debt != 0) {
            uint256 absSize = uint256(position.size > 0 ? position.size : -position.size);

            int256 fundingPayment;
            if (receiveDelta >= payDelta) {
                fundingPayment = int256(Calculations.mulDiv(receiveDelta - payDelta, absSize, 1e18));
            } else {
                fundingPayment = -int256(Calculations.mulDiv(payDelta - receiveDelta, absSize, 1e18));
            }

            // New funding is netted against funding still owed from earlier settlements. What the
            // vault balance cannot pay stays on the position as debt instead of being written off.
            int256 net = fundingPayment - int256(debt);
            position.fundingDebt = 0;
            // This position's share of the payment no receiver is credited (owed to the insurance
            // fund): this interval's share plus the share carried with earlier unpaid debt.
            uint256 surplusX18 = position.fundingDebtSurplus
                + Calculations.mulDiv(currentSurplus - position.lastFundingSurplusIndex, absSize, 1e18);
            position.fundingDebtSurplus = 0;
            if (net > 0) {
                // Reserved at the haircut value of the tokens credited, as the margin checks value
                // the balance, so a credit never leaves the account's other margins unbacked.
                uint256 creditValue =
                    _quoteValueX18(m.quoteToken, _settlePnLInVault(account, marketId, net, true, 0, 0));
                position.margin += creditValue;
                _totalReservedMargin[account] += creditValue;
            } else if (net < 0) {
                (uint256 paidX18, uint256 unpaidX18) = _chargeFunding(account, position, m.quoteToken, uint256(-net));
                position.fundingDebt = unpaidX18;
                // Only what the vault actually paid leaves the margin; the unpaid part is the debt.
                _reduceMargin(account, position, paidX18);
                // The surplus is the last part of the debit to be paid: up to the unpaid amount of it is
                // carried with the debt, and only the rest, which the payer actually paid, is booked.
                surplusX18 = _carryDebtSurplus(position, surplusX18, unpaidX18);
            }
            _bookFundingSurplus(marketId, m.quoteToken, surplusX18);

            if (payDelta != 0 || receiveDelta != 0) emit FundingSettled(marketId, account, fundingPayment);
        }

        position.lastFundingPayIndex = currentPay;
        position.lastFundingReceiveIndex = currentReceive;
        position.lastFundingSurplusIndex = currentSurplus;
    }

    // =========================================================================
    // Helpers — moved exclusively from ClearingHouse
    // =========================================================================

    function _addActiveMarket(address user, bytes32 marketId) internal {
        if (!_isMarketActive[user][marketId]) {
            _userActiveMarkets[user].push(marketId);
            _isMarketActive[user][marketId] = true;
        }
    }

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

    /// @dev Debits up to `debitX18` of funding (converted at the fixed PnL rate, rounded up) from the
    /// account's vault balance, but never more than the paying position's margin plus the account's
    /// free collateral value (_fundingCapX18), so one position's funding never takes the collateral
    /// that backs the account's other positions. Returns the value paid and the value left unpaid,
    /// which the caller carries as funding debt.
    function _chargeFunding(
        address account,
        IClearingHouse.PositionView storage position,
        address quoteToken,
        uint256 debitX18
    ) internal returns (uint256 paidX18, uint256 unpaidX18) {
        uint256 cap = _fundingCapX18(account, position.margin, quoteToken);
        paidX18 = debitX18 < cap ? debitX18 : cap;
        uint256 paid = _pnlToQuoteUnits(paidX18, quoteToken, true);
        uint256 available = ICollateralVault(vault).balanceOf(account, quoteToken);
        if (paid > available) {
            paid = available;
            paidX18 = Calculations.mulDiv(available, 1e18, ICollateralVault(vault).getConfig(quoteToken).baseUnit);
        }
        unpaidX18 = debitX18 - paidX18;
        if (paid > 0) ICollateralVault(vault).settlePnL(account, quoteToken, -int256(paid));
    }

    /// @dev Most funding a position with `margin` can be charged now: its margin plus the value of
    /// the account's collateral that no position reserves.
    function _fundingCapX18(address account, uint256 margin, address quoteToken) internal view returns (uint256) {
        return margin + _freeQuoteValue(account, quoteToken);
    }

    /// @dev Lowers a position's margin and the account's reserved margin by `amount`, floored at zero.
    function _reduceMargin(address account, IClearingHouse.PositionView storage position, uint256 amount) internal {
        uint256 cut = amount < position.margin ? amount : position.margin;
        position.margin -= cut;
        _totalReservedMargin[account] = _totalReservedMargin[account] > cut ? _totalReservedMargin[account] - cut : 0;
    }

    /// @dev Settles funding debt carried by a position that a trade reduces. A close or flip settles
    /// all of it, writing off what the balance cannot pay only in a liquidation (a voluntary trade
    /// reverts). A partial reduction pays what the balance allows and keeps the rest as debt.
    function _settleFundingDebt(
        address account,
        bytes32 marketId,
        IClearingHouse.PositionView storage position,
        address quoteToken,
        bool closesSide,
        bool isLiquidation
    ) internal {
        uint256 debt = position.fundingDebt;
        uint256 surplusX18 = position.fundingDebtSurplus;
        position.fundingDebt = 0;
        position.fundingDebtSurplus = 0;
        if (closesSide) {
            // Paid from the position's margin and the free collateral only (see _chargeFunding); in a
            // liquidation the rest is written off, a voluntary trade reverts.
            uint256 capUnits = _pnlToQuoteUnits(_fundingCapX18(account, position.margin, quoteToken), quoteToken, true);
            _settlePnLInVault(account, marketId, -int256(debt), isLiquidation, surplusX18, capUnits);
        } else {
            (uint256 paidX18, uint256 unpaidX18) = _chargeFunding(account, position, quoteToken, debt);
            position.fundingDebt = unpaidX18;
            _reduceMargin(account, position, paidX18);
            _bookFundingSurplus(marketId, quoteToken, _carryDebtSurplus(position, surplusX18, unpaidX18));
        }
    }

    /// @dev Carries min(surplusX18, unpaidX18) of a funding surplus share with the position's unpaid
    /// funding debt and returns the rest, which the payer paid and which can be booked.
    function _carryDebtSurplus(IClearingHouse.PositionView storage position, uint256 surplusX18, uint256 unpaidX18)
        internal
        returns (uint256 paidSurplusX18)
    {
        uint256 carried = surplusX18 < unpaidX18 ? surplusX18 : unpaidX18;
        position.fundingDebtSurplus = carried;
        return surplusX18 - carried;
    }

    /// @dev Books paid funding surplus for the insurance fund, in token units at the fixed PnL rate,
    /// rounded down.
    function _bookFundingSurplus(bytes32 marketId, address quoteToken, uint256 surplusX18) internal {
        if (surplusX18 > 0) fundingSurplus[marketId] += _pnlToQuoteUnits(surplusX18, quoteToken, false);
    }

    /// @dev Books realized PnL or funding in the vault. Both legs of one zero-sum exchange are
    /// converted at the same fixed rate (see _pnlToQuoteUnits), so the winner's credit and the
    /// loser's debit net in tokens whatever quote-token price each settlement would read.
    /// @param allowBadDebt True for liquidations and funding, where a loss beyond the vault balance
    /// is written off; a voluntary trade with such a loss reverts instead.
    /// @param surplusX18 Part of a loss that is funding surplus owed to the insurance fund (funding
    /// debt's carried share). It is the last part paid: what the balance pays of it is booked to
    /// fundingSurplus, and a written-off remainder of it is dropped instead of drawn from the fund.
    /// @param maxLossUnits Most quote-token units a loss may take from the balance; beyond it the loss
    /// is treated as exceeding the balance. Unused for a profit.
    /// @return credited Quote-token units credited for a profit (0 for a loss).
    function _settlePnLInVault(
        address account,
        bytes32 marketId,
        int256 realized,
        bool allowBadDebt,
        uint256 surplusX18,
        uint256 maxLossUnits
    ) internal returns (uint256 credited) {
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);

        if (realized > 0) {
            credited = _pnlToQuoteUnits(uint256(realized), m.quoteToken, false);
            if (credited > 0) {
                ICollateralVault(vault).settlePnL(account, m.quoteToken, int256(credited));
            }
        } else {
            uint256 lossInQuote = _pnlToQuoteUnits(uint256(-realized), m.quoteToken, true);
            uint256 surplusUnits = _pnlToQuoteUnits(surplusX18, m.quoteToken, false);
            if (lossInQuote > 0) {
                uint256 available = ICollateralVault(vault).balanceOf(account, m.quoteToken);
                if (available > maxLossUnits) available = maxLossUnits;
                if (lossInQuote > available) {
                    if (!allowBadDebt) revert InsufficientQuoteCollateral();
                    uint256 badDebt = lossInQuote - available;
                    lossInQuote = available;
                    // The unpaid part is the surplus share first: no receiver's credit stands behind
                    // it, so it is dropped rather than drawn from the fund it is owed to.
                    uint256 dropped = surplusUnits < badDebt ? surplusUnits : badDebt;
                    surplusUnits -= dropped;
                    badDebt -= dropped;
                    // The winners' credits sit in the vault: back the uncovered loss with insurance
                    // tokens paid into the vault, and record only what the fund cannot pay.
                    badDebt -= _drawInsurance(m, badDebt);
                    if (badDebt > 0) {
                        totalBadDebt += badDebt;
                        emit BadDebtRecorded(account, marketId, badDebt);
                    }
                }
                if (lossInQuote > 0) {
                    ICollateralVault(vault).settlePnL(account, m.quoteToken, -int256(lossInQuote));
                }
            }
            if (surplusUnits > 0) fundingSurplus[marketId] += surplusUnits;
        }
    }

    /// @dev Pays up to `amount` quote tokens from the market's insurance fund into the vault, capped
    /// at the fund's tracked balance (what payout enforces). Returns the amount paid; 0 if the fund
    /// is unset, holds a different token, is empty, or the payout reverts.
    function _drawInsurance(IMarketRegistry.Market memory m, uint256 amount) internal returns (uint256 paid) {
        if (m.insuranceFund == address(0)) return 0;
        IInsuranceFund fund = IInsuranceFund(m.insuranceFund);
        if (fund.quoteToken() != m.quoteToken) return 0;
        uint256 tracked = fund.totalReceived() - fund.totalPaid();
        paid = amount < tracked ? amount : tracked;
        if (paid == 0) return 0;
        try fund.payout(vault, paid) {} catch {
            paid = 0;
        }
    }

    function _routeTradeFee(address account, uint256 fee, IMarketRegistry.Market memory m) internal {
        if (fee == 0 || m.feeRouter == address(0)) return;

        uint256 feeInQuoteDecimals = _notionalToQuoteUnits(fee, m.quoteToken);
        if (feeInQuoteDecimals == 0) return;

        // The fee is booked to the router's vault balance first. Withdrawing it to the router and
        // splitting it run as one self-call (ClearingHouse.pushFee); if that fails (withdrawals or
        // the token paused, a blacklisted router or fund) the fee stays booked for sweepFees, so the
        // trade itself never reverts on the push.
        (uint256 seized, uint256 shortfall) = _collectQuote(account, m.feeRouter, m.quoteToken, feeInQuoteDecimals);
        if (!(shortfall == 0)) revert InsufficientQuoteForFee();
        (bool ok,) = address(this).call(
            abi.encodeWithSignature("pushFee(address,address,uint256,bool)", m.feeRouter, m.quoteToken, seized, false)
        );
        if (!ok) pendingTradeFees[m.feeRouter][m.quoteToken] += seized;
    }

    /// @dev Requires quote collateral value >= reserved margin + amount. With amount 0 it still
    /// checks that the reserved margin is fully backed.
    function _ensureAvailableCollateral(address account, uint256 amount, address quoteToken) internal view {
        uint256 quoteBalance = ICollateralVault(vault).balanceOf(account, quoteToken);
        uint256 quoteValueX18 = _quoteValueX18(quoteToken, quoteBalance);
        uint256 reservedForToken = _reservedMarginForToken(account, quoteToken);
        if (!(quoteValueX18 >= reservedForToken + amount)) revert InsufficientQuoteCollateral();
    }

    // =========================================================================
    // Helpers — duplicated from ClearingHouse (also needed there for liquidate)
    // =========================================================================

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
            uint256 reservedForToken = _reservedMarginForToken(account, quoteToken);
            uint256 reservedInTokenUnits = _notionalToQuoteUnits(reservedForToken, quoteToken);
            available = balance > reservedInTokenUnits ? balance - reservedInTokenUnits : 0;
        }
        uint256 seized = amount <= available ? amount : available;
        actualReceived = seized;

        if (seized > 0) {
            ICollateralVault(vault).seize(account, recipient, quoteToken, seized);
        }
        shortfall = amount - seized;
    }

    /// @dev Takes up to `need` token units from margin the account's open positions in `quoteToken` hold
    ///      above both their maintenance requirement (equity net of funding debt) and their liquidation
    ///      penalty floor, lowering those margins so reserved margin stays backed by the balance. A
    ///      market whose index cannot be read keeps its margin instead of reverting the liquidation.
    ///      `skipMarket` (the market being liquidated, or 0) is never drawn from.
    function _drawSurplusMargin(
        address account,
        address quoteToken,
        uint256 need,
        uint256 balanceLeft,
        bytes32 skipMarket
    ) internal returns (uint256 drawn) {
        if (balanceLeft == 0) return 0;
        if (need > balanceLeft) need = balanceLeft;
        uint256 reserved = _reservedMarginForToken(account, quoteToken);
        if (reserved == 0) return 0;
        uint256 valueX18 = _quoteValueX18(quoteToken, balanceLeft);
        // A balance worth less than the reserved margin backs each margin only in that ratio.
        uint256 backedX18 = valueX18 < reserved ? valueX18 : reserved;
        bytes32[] memory markets = _userActiveMarkets[account];
        for (uint256 i = 0; i < markets.length && drawn < need; i++) {
            IMarketRegistry.Market memory mkt = IMarketRegistry(marketRegistry).getMarket(markets[i]);
            if (markets[i] == skipMarket || mkt.quoteToken != quoteToken || mkt.oracle == address(0)) continue;
            IClearingHouse.PositionView storage p = positions[account][markets[i]];
            if (p.size == 0 || p.margin == 0) continue;
            uint256 riskPrice;
            try IOracle(mkt.oracle).getPrice() returns (uint256 price) {
                riskPrice = price;
            } catch {
                continue;
            }
            if (riskPrice == 0) continue;
            IClearingHouse.MarketRiskParams storage rp = marketRiskParams[markets[i]];
            uint256 notional = Calculations.mulDivRoundingUp(uint256(p.size > 0 ? p.size : -p.size), riskPrice, 1e18);
            uint256 penaltyFloor = Calculations.mulDivRoundingUp(notional, rp.liquidationPenaltyBps, BPS_DENOMINATOR);
            if (rp.penaltyCap > 0 && penaltyFloor > rp.penaltyCap) penaltyFloor = rp.penaltyCap;
            if (p.margin <= penaltyFloor) continue;
            uint256 mm = Calculations.mulDivRoundingUp(notional, rp.mmrBps, BPS_DENOMINATOR);
            uint256 backedMargin = Calculations.mulDiv(p.margin, backedX18, reserved);
            int256 equity = int256(backedMargin) + _computeUnrealizedPnL(p, riskPrice) - int256(p.fundingDebt);
            if (equity <= int256(mm)) continue;
            // Value that can leave: above maintenance, within the backed margin, and leaving the
            // position at least its penalty floor (taken in nominal margin below).
            uint256 x = uint256(equity - int256(mm));
            if (x > backedMargin) x = backedMargin;
            uint256 wantX18 = Calculations.mulDivRoundingUp(need - drawn, valueX18, balanceLeft);
            uint256 units;
            if (x >= wantX18) {
                x = wantX18;
                units = need - drawn;
            } else {
                units = Calculations.mulDiv(x, balanceLeft, valueX18);
            }
            uint256 take = Calculations.mulDivRoundingUp(x, reserved, backedX18);
            uint256 maxTake = p.margin - penaltyFloor;
            if (take > maxTake) {
                // Scale the draw down to what the penalty floor allows.
                units = Calculations.mulDiv(units, maxTake, take);
                take = maxTake;
            }
            p.margin -= take;
            _totalReservedMargin[account] = _totalReservedMargin[account] >= take ? _totalReservedMargin[account] - take : 0;
            drawn += units;
        }
    }

    function _reservedMarginForToken(address account, address quoteToken) internal view returns (uint256 reserved) {
        bytes32[] memory markets = _userActiveMarkets[account];
        for (uint256 i = 0; i < markets.length; i++) {
            IMarketRegistry.Market memory mkt = IMarketRegistry(marketRegistry).getMarket(markets[i]);
            if (mkt.quoteToken == quoteToken) {
                reserved += positions[account][markets[i]].margin;
            }
        }
    }

    /// @dev True when the vault's oracle returns a non-zero price for the quote token.
    function _quoteOracleLive(address quoteToken) internal view returns (bool) {
        ICollateralVault.CollateralConfig memory cfg = ICollateralVault(vault).getConfig(quoteToken);
        try IOracle(ICollateralVault(vault).oracle()).getPrice(cfg.oracleSymbol) returns (uint256 priceX18) {
            return priceX18 > 0;
        } catch {
            return false;
        }
    }

    /// @dev True when the market's index oracle is set and returns a non-zero price.
    function _indexOracleLive(address oracle) internal view returns (bool) {
        if (oracle == address(0)) return false;
        try IOracle(oracle).getPrice() returns (uint256 priceX18) {
            return priceX18 > 0;
        } catch {
            return false;
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

    /// @dev Converts realized PnL or funding (1e18 quote value) to quote-token units at a fixed
    /// rate of one whole token (`baseUnit`, i.e. 10**decimals) per 1e18 of quote value, independent
    /// of the live quote-token oracle. Profits round down, losses round up.
    /// Fees and penalties keep using the live oracle price; margin valuation uses it capped at par.
    function _pnlToQuoteUnits(uint256 amountX18, address quoteToken, bool roundUp) internal view returns (uint256) {
        if (amountX18 == 0) return 0;
        uint256 baseUnit = ICollateralVault(vault).getConfig(quoteToken).baseUnit;
        return roundUp
            ? Calculations.mulDivRoundingUp(amountX18, baseUnit, 1e18)
            : Calculations.mulDiv(amountX18, baseUnit, 1e18);
    }

    function _getRiskPrice(IMarketRegistry.Market memory m) internal view returns (uint256) {
        if (!(m.oracle != address(0))) revert OracleNotSet();
        uint256 indexPrice = IOracle(m.oracle).getPrice();
        if (!(indexPrice > 0)) revert OraclePriceZero();
        return indexPrice;
    }

    function _computeUnrealizedPnL(IClearingHouse.PositionView storage position, uint256 priceX18) internal view returns (int256) {
        int256 size = position.size;
        uint256 entryPrice = position.entryPriceX18;
        if (priceX18 == 0 || size == 0 || entryPrice == 0) {
            return 0;
        }

        uint256 absSize = uint256(size > 0 ? size : -size);
        if (size > 0) {
            return (int256(priceX18) - int256(entryPrice)) * int256(absSize) / 1e18;
        } else {
            return (int256(entryPrice) - int256(priceX18)) * int256(absSize) / 1e18;
        }
    }
}
