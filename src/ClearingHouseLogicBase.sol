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
/// @dev Storage layout MUST mirror ClearingHouse exactly (slots 11-14 are placeholders).
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
    // Slots 11-14 are set by ClearingHouse only; they are held here so the slots after them line up.
    address private _slot11AllowlistManager; // slot 11
    bool private _slot11AllowlistEnforced; // slot 11 (packed)
    mapping(address => bool) private _slot12AllowedTraders; // slot 12
    mapping(bytes32 => IClearingHouse.OpenInterestCaps) internal openInterestCaps; // slot 13 (read by checkOpenInterestCaps)
    mapping(bytes32 => uint256) private _slot14LiquidationPriceBandBps; // slot 14
    mapping(bytes32 => uint256) internal fundingSurplus; // slot 15
    mapping(address => mapping(address => uint256)) internal pendingTradeFees; // slot 16
    mapping(address => mapping(address => uint256)) internal pendingLiqPenalties; // slot 17
    mapping(bytes32 => IClearingHouse.HoldingFee) internal holdingFees; // slot 18

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

    /// @dev The market's holding fee index brought up to now at its current rate.
    function _holdingFeeIndex(IClearingHouse.HoldingFee storage h) internal view returns (uint256) {
        return h.cumulativeX18 + h.rateBpsPerYear * 1e14 * (block.timestamp - h.updatedAt) / 365 days;
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
        ) - int256(_holdingFeeDue(position, m.oracle, _holdingFeeIndex(holdingFees[marketId])));
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
}
