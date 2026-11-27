// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IClearingHouse} from "./Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "./Interfaces/ICollateralVault.sol";
import {IMarketRegistry} from "./Interfaces/IMarketRegistry.sol";
import {IVAMM} from "./Interfaces/IVAMM.sol";
import {IOracle, IOracleAvailability} from "./Interfaces/IOracle.sol";
import {IInsuranceFund} from "./Interfaces/IInsuranceFund.sol";
import {IFeeRouter} from "./Interfaces/IFeeRouter.sol";
import {Calculations} from "./Libraries/Calculations.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ClearingHouseLogicBase} from "./ClearingHouseLogicBase.sol";
import {ClearingHouseViews} from "./ClearingHouseViews.sol";

/// @notice Logic contract for ClearingHouse heavy functions, called via delegatecall.
/// @dev Storage layout comes from ClearingHouseLogicBase and MUST mirror ClearingHouse exactly.
///      Selectors not implemented here (views moved out for size) are forwarded by the fallback to
///      ClearingHouseViews, which runs in the same storage context.
contract ClearingHouseLogic is ClearingHouseLogicBase {
    using Calculations for uint256;

    /// @dev ClearingHouseViews instance deployed with this contract; the fallback delegates to it.
    address private immutable _views;

    constructor() {
        _views = address(new ClearingHouseViews());
    }

    /// @dev Forwards the views that live in ClearingHouseViews (pendingFunding, carriesFundingDebt,
    ///      checkOpenInterestCaps). Reached only through ClearingHouse's delegatecall, so the second
    ///      delegatecall keeps ClearingHouse's storage, msg.sender and address(this).
    fallback() external {
        address target = _views;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := delegatecall(gas(), target, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            if iszero(ok) { revert(ptr, returndatasize()) }
            return(ptr, returndatasize())
        }
    }

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev Highest holding fee rate: 100% of notional per year.
    uint256 private constant MAX_HOLDING_FEE_BPS_PER_YEAR = 10_000;

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
    event HoldingFeeRateSet(bytes32 indexed marketId, uint256 rateBpsPerYear);

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

    /// @notice Sets a market's holding fee rate, in bps of notional per year.
    /// @dev Delegatecall target of ClearingHouse.setHoldingFeeRate (owner only). The old rate is
    ///      accrued up to now first, so a change applies from this moment on.
    function setHoldingFeeRate(bytes32 marketId, uint256 rateBpsPerYear) external {
        if (IMarketRegistry(marketRegistry).getMarket(marketId).vamm == address(0)) revert MarketNotFound();
        if (rateBpsPerYear > MAX_HOLDING_FEE_BPS_PER_YEAR) revert InvalidHoldingFeeRate();
        _accrueHoldingFee(marketId, block.timestamp);
        holdingFees[marketId].rateBpsPerYear = rateBpsPerYear;
        emit HoldingFeeRateSet(marketId, rateBpsPerYear);
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

    /// @dev Brings the market's holding fee clock up to now, accruing at the current rate only up to
    ///      `liveUntil` (capped at now): block.timestamp accrues the whole interval, 0 none of it (time
    ///      in which funding is skipped), and the moment the quote feed became unavailable accrues the
    ///      live time before it, as vAMM.skipFunding does for funding. Returns the index.
    function _accrueHoldingFee(bytes32 marketId, uint256 liveUntil) internal returns (uint256) {
        IClearingHouse.HoldingFee storage h = holdingFees[marketId];
        uint256 until = liveUntil < block.timestamp ? liveUntil : block.timestamp;
        if (until > h.updatedAt) h.cumulativeX18 += h.rateBpsPerYear * 1e14 * (until - h.updatedAt) / 365 days;
        h.updatedAt = block.timestamp;
        return h.cumulativeX18;
    }

    /// @dev Charges a position's holding fee like a funding debit: paid up to its margin plus the free
    ///      collateral, the paid part credited to the market's fee router (booked for sweepFees) or,
    ///      without a router, to the funding surplus for the insurance fund. The unpaid part is carried
    ///      as funding debt with a surplus share, so once paid it goes to the insurance fund.
    function _chargeHoldingFee(
        address account,
        bytes32 marketId,
        IClearingHouse.PositionView storage position,
        IMarketRegistry.Market memory m,
        uint256 feeX18
    ) internal {
        (uint256 paidX18, uint256 unpaidX18) = _chargeFunding(account, position, m.quoteToken, feeX18);
        _reduceMargin(account, position, paidX18);
        position.fundingDebt += unpaidX18;
        position.fundingDebtSurplus += unpaidX18;
        uint256 units = _pnlToQuoteUnits(paidX18, m.quoteToken, false);
        if (units == 0) return;
        if (m.feeRouter == address(0)) {
            fundingSurplus[marketId] += units;
        } else {
            ICollateralVault(vault).settlePnL(m.feeRouter, m.quoteToken, int256(units));
            pendingTradeFees[m.feeRouter][m.quoteToken] += units;
        }
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
            // Rounded toward the smaller loss (down for a long, up for a short), so the averaged
            // position's unrealized loss never exceeds the losses its slices reserved.
            position.entryPriceX18 = s0 > 0 ? newNotional / absS1 : (newNotional + absS1 - 1) / absS1;
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

        // A voluntary trade's realized loss is paid only up to the position's margin plus the account's
        // free collateral, the same cap as a funding debit, so it never takes the collateral that backs
        // the account's other positions; a larger loss reverts. Taken before the position changes (a
        // full close drops the market from the reserved total, which would count its margin twice).
        uint256 lossCapUnits = type(uint256).max;
        if (realized < 0 && !isLiquidation) {
            lossCapUnits = _pnlToQuoteUnits(_fundingCapX18(account, position.margin, m.quoteToken), m.quoteToken, true);
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
            // Only a liquidation may realize a loss beyond the account's vault balance or the cap above.
            uint256 credited = _settlePnLInVault(account, marketId, realized, isLiquidation, 0, lossCapUnits);
            if (realized > 0) creditValue = _quoteValueX18(m.quoteToken, credited);
        }

        // Margin share of the closed slice, taken from the margin before any realized loss. A flip
        // keeps the market's whole margin for the new position, so its closed size has no slice
        // margin and its realized loss is charged to that margin.
        bool reducing = s0 != 0 && ((s0 > 0) != (baseDelta > 0));
        bool flip = reducing && absBaseDelta > absS0;
        uint256 sliceMargin;
        if (reducing && !flip) {
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
            // whole position, which is rounded down once. The slice also reserves its own loss at
            // the index from its fill, so a fresh open meets the initial margin net of that loss.
            uint256 tradeNotional = Calculations.mulDivRoundingUp(absBaseDelta, imrPrice, 1e18);
            uint256 marginRequired = Calculations.mulDivRoundingUp(tradeNotional, rp.imrBps, BPS_DENOMINATOR)
                + _sliceLoss(baseDelta > 0, execPxX18, absBaseDelta, oraclePrice);
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
            // proportional share. A flip releases nothing: the new position keeps the margin.
            uint256 marginRelease;
            if (flip) {
                // kept for the new position
            } else if (realized < 0) {
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
                uint256 debt = position.fundingDebt;
                _settleFundingDebt(account, marketId, position, m.quoteToken, absBaseDelta >= absS0, isLiquidation);
                // A flip pays the whole debt (a voluntary trade reverts otherwise) from the balance
                // backing the kept margin, so the margin drops by it.
                if (flip) _reduceMargin(account, position, debt);
            }

            if (flip) {
                uint256 openAmt = absBaseDelta - absS0;
                uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
                uint256 oraclePrice = _getRiskPrice(m);
                uint256 imrPrice = markPrice > oraclePrice ? markPrice : oraclePrice;
                uint256 openNotional = Calculations.mulDivRoundingUp(openAmt, imrPrice, 1e18);
                uint256 marginRequired = Calculations.mulDivRoundingUp(openNotional, rp.imrBps, BPS_DENOMINATOR)
                    + _sliceLoss(s1 > 0, position.entryPriceX18, openAmt, oraclePrice);
                // Only what the kept margin is short of the new position's requirement is reserved.
                marginRequired = marginRequired > position.margin ? marginRequired - position.margin : 0;
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
            int256 unrealizedPnL = _computeUnrealizedPnL(position, oraclePrice);
            // IMR applies to trades that open, increase or flip: the margin, net of unrealized loss at
            // the index (profit ignored) and of funding debt, must cover the initial margin of the
            // whole position. An existing shortfall reverts the trade; it is not pulled from free
            // collateral. A trade that only shrinks the position on the same side, with a realized
            // loss its closed slice's margin covers, adds no exposure and leaves the remaining size's
            // margin untouched, so only the maintenance check applies. A reduction whose loss exceeds
            // the slice's margin takes the excess from the remaining size and is checked in full.
            bool onlyReduces = s0 != 0 && (s0 > 0) == (s1 > 0) && absS1 < absS0
                && (realized >= 0 || uint256(-realized) <= sliceMargin);
            if (
                !onlyReduces
                    && int256(marginValue) + (unrealizedPnL < 0 ? unrealizedPnL : int256(0))
                        - int256(position.fundingDebt) < int256(requiredMargin)
            ) revert IMRBreach();

            {
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
            vamm.skipFunding(0);
            _accrueHoldingFee(marketId, 0);
            return;
        }

        // Funding only accrues while it can be settled in the quote token. If the quote oracle is
        // unavailable (stale round, sequencer down or in grace period), funding is accrued up to the
        // moment it became unavailable and the clock is then advanced without accruing, so payers are
        // not charged for time in which they cannot act and the live time before it is not dropped.
        // The same holds while the market's index oracle (the risk price) is down, since positions can
        // then be neither closed nor liquidated; that time is skipped entirely.
        // The holding fee index follows the same clock.
        if (!_indexOracleLive(m.oracle)) {
            vamm.skipFunding(0);
            _accrueHoldingFee(marketId, 0);
            return;
        }
        if (!_quoteOracleLive(m.quoteToken)) {
            uint64 liveUntil = _quoteUnavailableSince(m.quoteToken);
            vamm.skipFunding(liveUntil);
            _accrueHoldingFee(marketId, liveUntil);
            return;
        }

        (uint256 longPay, uint256 longReceive, uint256 shortPay, uint256 shortReceive) = vamm.pokeFunding();
        uint256 feeIndex = _accrueHoldingFee(marketId, block.timestamp);

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
            // A position opened next is charged the holding fee from now on.
            position.lastHoldingFeeIndexX18 = feeIndex;
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
                // A payer's debit rounds up, like fees and margin requirements; a credit rounds down.
                fundingPayment = -int256(Calculations.mulDivRoundingUp(payDelta - receiveDelta, absSize, 1e18));
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

        // The holding fee accrued since the last settlement, charged after funding (finding 26).
        {
            uint256 feeX18 = _holdingFeeDue(position, m.oracle, feeIndex);
            position.lastHoldingFeeIndexX18 = feeIndex;
            if (feeX18 != 0) _chargeHoldingFee(account, marketId, position, m, feeX18);
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

    /// @dev When the vault oracle's quote-token price became unreadable (0 if unknown or unsupported).
    function _quoteUnavailableSince(address quoteToken) internal view returns (uint64) {
        string memory sym = ICollateralVault(vault).getConfig(quoteToken).oracleSymbol;
        try IOracleAvailability(ICollateralVault(vault).oracle()).priceUnavailableSince(sym) returns (uint256 t) {
            return t > block.timestamp ? 0 : uint64(t);
        } catch {
            return 0;
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

    /// @dev Loss at `indexX18` of `qty` base just filled at `pxX18` on the long (`isLong`) or short
    /// side, rounded up; 0 if the fill is no worse than the index.
    function _sliceLoss(bool isLong, uint256 pxX18, uint256 qty, uint256 indexX18) internal pure returns (uint256) {
        if (isLong ? pxX18 <= indexX18 : pxX18 >= indexX18) return 0;
        return Calculations.mulDivRoundingUp(isLong ? pxX18 - indexX18 : indexX18 - pxX18, qty, 1e18);
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
