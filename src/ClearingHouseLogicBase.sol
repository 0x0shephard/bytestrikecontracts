// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IClearingHouse} from "./Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "./Interfaces/ICollateralVault.sol";
import {IMarketRegistry} from "./Interfaces/IMarketRegistry.sol";
import {IOracle} from "./Interfaces/IOracle.sol";
import {IVAMM} from "./Interfaces/IVAMM.sol";
import {Calculations} from "./Libraries/Calculations.sol";

/// @notice Storage layout and shared helpers of the ClearingHouse delegatecall targets
///         (ClearingHouseLogic and ClearingHouseViews).
/// @dev Storage layout MUST mirror ClearingHouse exactly (slots 11-12 are placeholders).
///      Any addition/removal of storage variables in ClearingHouse must be reflected here.
abstract contract ClearingHouseLogicBase {
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
    // Slots 11-12 are set by ClearingHouse only; they are held here so the slots after them line up.
    address private _slot11AllowlistManager; // slot 11
    bool private _slot11AllowlistEnforced; // slot 11 (packed)
    mapping(address => bool) private _slot12AllowedTraders; // slot 12
    mapping(bytes32 => IClearingHouse.OpenInterestCaps) internal openInterestCaps; // slot 13 (read by checkOpenInterestCaps)
    mapping(bytes32 => uint256) internal _liquidationPriceBandBps; // slot 14 (set by ClearingHouseViews.setLiquidationPriceBand)
    mapping(bytes32 => uint256) internal fundingSurplus; // slot 15
    mapping(address => mapping(address => uint256)) internal pendingTradeFees; // slot 16
    mapping(address => mapping(address => uint256)) internal pendingLiqPenalties; // slot 17
    mapping(bytes32 => IClearingHouse.HoldingFee) internal holdingFees; // slot 18
    mapping(bytes32 => uint256) internal holdingFeeLiveSecondsAt; // slot 19

    uint256 internal constant BPS_DENOMINATOR = 10_000;

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
    error ExceedsMaxGrossOI();
    error ExceedsMaxNetOI();
    error InvalidHoldingFeeRate();
    error BackingRatioLowered();

    // =========================================================================
    // Shared helpers
    // =========================================================================

    /// @dev The market's holding fee index brought up to now at its current rate, over the funding
    ///      seconds the vAMM would have accrued by now (IVAMM.currentLiveFundingSeconds).
    function _holdingFeeIndex(bytes32 marketId, address vamm) internal view returns (uint256) {
        IClearingHouse.HoldingFee storage h = holdingFees[marketId];
        uint256 live = IVAMM(vamm).currentLiveFundingSeconds();
        uint256 at = holdingFeeLiveSecondsAt[marketId];
        return live > at ? h.cumulativeX18 + h.rateBpsPerYear * 1e14 * (live - at) / 365 days : h.cumulativeX18;
    }

    /// @dev Holding fee a position owes up to index `feeIndex`: its absolute notional at the index
    ///      times the index's growth since the position's snapshot, rounded up. 0 if the index price
    ///      cannot be read (funding settlement is then skipped as well).
    function _holdingFeeDue(IClearingHouse.PositionView storage position, address oracle, uint256 feeIndex)
        internal
        view
        returns (uint256)
    {
        if (feeIndex == position.lastHoldingFeeIndexX18 || position.size == 0) return 0;
        uint256 indexPrice;
        try IOracle(oracle).getPrice() returns (uint256 p) {
            indexPrice = p;
        } catch {
            return 0;
        }
        uint256 notional = Calculations.mulDivRoundingUp(
            uint256(position.size > 0 ? position.size : -position.size), indexPrice, 1e18
        );
        return Calculations.mulDivRoundingUp(notional, feeIndex - position.lastHoldingFeeIndexX18, 1e18);
    }

    /// @dev Funding not yet settled for a position, from the vAMM's current (accrued) indices, minus
    ///      the holding fee accrued since its last settlement.
    function _pendingFunding(address account, bytes32 marketId) internal view returns (int256) {
        IClearingHouse.PositionView storage position = positions[account][marketId];
        if (position.size == 0) return 0;
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
        IVAMM vamm = IVAMM(m.vamm);
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
        return (
            receiveDelta >= payDelta
                ? int256(Calculations.mulDiv(receiveDelta - payDelta, absSize, 1e18))
                : -int256(Calculations.mulDivRoundingUp(payDelta - receiveDelta, absSize, 1e18))
        ) - int256(_holdingFeeDue(position, m.oracle, _holdingFeeIndex(marketId, m.vamm)));
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

    /// @dev Value of a quote-token amount as margin: the vault's haircut oracle value, with the token
    ///      price capped at par (1e18 per whole token, before the haircut). Realized PnL and funding
    ///      are debited at par, so a token must not back more margin than it pays at that rate.
    function _quoteValueX18(address quoteToken, uint256 amount) internal view returns (uint256) {
        return _parValueX18(quoteToken, amount, true);
    }

    /// @dev Value of credited tokens (realized profit or funding credit) as margin: the same par-capped
    ///      value, but a credit the vault values at zero (dust after the haircut) backs no margin
    ///      instead of reverting, so a dust credit cannot block the settlement that carries it.
    function _creditValueX18(address quoteToken, uint256 amount) internal view returns (uint256) {
        return _parValueX18(quoteToken, amount, false);
    }

    function _parValueX18(address quoteToken, uint256 amount, bool strict) private view returns (uint256) {
        if (amount == 0) return 0;
        uint256 v = ICollateralVault(vault).getTokenValueX18(quoteToken, amount);
        if (v == 0) {
            if (strict) revert QuoteTokenValuationUnavailable();
            return 0;
        }
        ICollateralVault.CollateralConfig memory cfg = ICollateralVault(vault).getConfig(quoteToken);
        uint256 par = Calculations.mulDiv(
            Calculations.mulDiv(1e18, amount, cfg.baseUnit), BPS_DENOMINATOR - cfg.haircutBps, BPS_DENOMINATOR
        );
        return v < par ? v : par;
    }

    function _getRiskPrice(IMarketRegistry.Market memory m) internal view returns (uint256) {
        if (!(m.oracle != address(0))) revert OracleNotSet();
        uint256 indexPrice = IOracle(m.oracle).getPrice();
        if (!(indexPrice > 0)) revert OraclePriceZero();
        return indexPrice;
    }

    // Moved from ClearingHouseLogic for size: shared by Logic and Views.

    /// @dev Value of the account's quote-token balance above the margin reserved on that token.
    function _freeQuoteValue(address account, address quoteToken) internal view returns (uint256) {
        (uint256 value, uint256 reserved) = _quoteBacking(account, quoteToken);
        return value > reserved ? value - reserved : 0;
    }

    /// @dev Value of the account's quote-token balance and the margin reserved on that token.
    function _quoteBacking(address account, address quoteToken)
        internal
        view
        returns (uint256 value, uint256 reserved)
    {
        uint256 balance = ICollateralVault(vault).balanceOf(account, quoteToken);
        value = balance == 0 ? 0 : _quoteValueX18(quoteToken, balance);
        reserved = _reservedMarginForToken(account, quoteToken);
    }

    /// @dev Lowers a position's margin and the account's reserved margin by `amount`, floored at zero.
    function _reduceMargin(address account, IClearingHouse.PositionView storage position, uint256 amount) internal {
        uint256 cut = amount < position.margin ? amount : position.margin;
        position.margin -= cut;
        _totalReservedMargin[account] = _totalReservedMargin[account] > cut ? _totalReservedMargin[account] - cut : 0;
    }

    function _notionalToQuoteUnits(uint256 notionalX18, address quoteToken) internal view returns (uint256) {
        if (notionalX18 == 0) return 0;
        ICollateralVault.CollateralConfig memory cfg = ICollateralVault(vault).getConfig(quoteToken);
        uint256 priceX18 = IOracle(ICollateralVault(vault).oracle()).getPrice(cfg.oracleSymbol);
        if (!(priceX18 > 0)) revert QuoteOracleUnavailable();
        return Calculations.mulDivRoundingUp(notionalX18, cfg.baseUnit, priceX18);
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

    /// @dev Takes up to `need` token units from margin the account's open positions in `quoteToken` hold
    ///      above both their maintenance requirement (equity net of funding debt and of pending funding
    ///      owed) and their liquidation penalty floor, lowering those margins so reserved margin stays
    ///      backed by the balance. A market whose index cannot be read keeps its margin instead of
    ///      reverting the liquidation.
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
            // Funding it still owes (unsettled, e.g. flushed when its market was paused) is charged at its
            // next settlement, so it is not surplus either; pending credits are not counted.
            {
                int256 pending = _pendingFunding(account, markets[i]);
                if (pending < 0) equity += pending;
            }
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

}
