// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IClearingHouse} from "./Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "./Interfaces/ICollateralVault.sol";
import {IMarketRegistry} from "./Interfaces/IMarketRegistry.sol";
import {IVAMM} from "./Interfaces/IVAMM.sol";
import {Calculations} from "./Libraries/Calculations.sol";
import {ClearingHouseLogicBase} from "./ClearingHouseLogicBase.sol";

/// @notice ClearingHouse views moved out of ClearingHouseLogic for contract size.
/// @dev Deployed by ClearingHouseLogic's constructor and reached through its fallback, i.e. always by
///      delegatecall in ClearingHouse's storage context.
contract ClearingHouseViews is ClearingHouseLogicBase {
    /// @dev Mirrors ClearingHouse.DEFAULT_LIQUIDATION_PRICE_BAND_BPS and MIN_LIQUIDATION_BAND_BPS.
    uint256 internal constant DEFAULT_LIQUIDATION_PRICE_BAND_BPS = 500;
    uint256 internal constant MIN_LIQUIDATION_BAND_BPS = 100;

    error IMRBelowMMR();
    error MMRZero();
    error MinExceedsMax();
    error InvalidLiquidationPriceBand();
    error InvalidOpenInterestCaps();

    // Admin setters, moved from ClearingHouse for size (ClearingHouse checks onlyAdmin and forwards).

    /// @notice Sets the risk parameters for a market. Delegatecall target of ClearingHouse.setRiskParams.
    function setRiskParams(
        bytes32 marketId,
        uint256 imrBps,
        uint256 mmrBps,
        uint256 liquidationPenaltyBps,
        uint256 penaltyCap,
        uint256 maxPositionSize,
        uint256 minPositionSize
    ) external {
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

        marketRiskParams[marketId] = IClearingHouse.MarketRiskParams({
            imrBps: imrBps,
            mmrBps: mmrBps,
            liquidationPenaltyBps: liquidationPenaltyBps,
            penaltyCap: penaltyCap,
            maxPositionSize: maxPositionSize,
            minPositionSize: minPositionSize
        });

        emit IClearingHouse.RiskParamsSet(
            marketId, imrBps, mmrBps, liquidationPenaltyBps, penaltyCap, maxPositionSize, minPositionSize
        );
    }

    /// @notice Sets the aggregate open-interest caps for a market. 0 disables a cap.
    /// @dev Delegatecall target of ClearingHouse.setOpenInterestCaps. Lowering a cap below current OI
    ///      never traps positions: closes, pure reductions and liquidations are never capped. Above the
    ///      gross cap, a trade is accepted only if it moves the vAMM mark toward the index without
    ///      crossing it, so a pushed premium can always be traded back (see checkOpenInterestCaps).
    /// @param maxGrossOI Cap on long OI + short OI, in base units (1e18).
    /// @param maxNetOI Cap on |long OI - short OI|, in base units (1e18). Limits new one-sided exposure only;
    ///        closes can still leave net OI above it. Requires a non-zero maxGrossOI.
    function setOpenInterestCaps(bytes32 marketId, uint128 maxGrossOI, uint128 maxNetOI) external {
        if (!(IMarketRegistry(marketRegistry).getMarket(marketId).vamm != address(0))) revert MarketNotFound();
        // Net OI can be pushed past its cap by building both sides and then closing one, so the
        // gross cap is the hard bound and a net cap is only accepted alongside one.
        if (maxNetOI != 0 && (maxGrossOI == 0 || maxNetOI > maxGrossOI)) revert InvalidOpenInterestCaps();

        openInterestCaps[marketId] = IClearingHouse.OpenInterestCaps({maxGrossOI: maxGrossOI, maxNetOI: maxNetOI});
        emit IClearingHouse.OpenInterestCapsSet(marketId, maxGrossOI, maxNetOI);
    }

    /// @notice Sets how far the pre-trade mark may be worse than the index for a liquidation.
    ///         0 restores the default (5%, capped at mmrBps - liquidationPenaltyBps).
    /// @dev Delegatecall target of ClearingHouse.setLiquidationPriceBand.
    /// @param bandBps Band in bps; at least MIN_LIQUIDATION_BAND_BPS, and bandBps + liquidationPenaltyBps
    ///        must not exceed mmrBps, so the market's risk parameters must be set first.
    function setLiquidationPriceBand(bytes32 marketId, uint256 bandBps) external {
        if (!(IMarketRegistry(marketRegistry).getMarket(marketId).vamm != address(0))) revert MarketNotFound();
        IClearingHouse.MarketRiskParams storage rp = marketRiskParams[marketId];
        if (bandBps != 0 && (bandBps < MIN_LIQUIDATION_BAND_BPS || bandBps + rp.liquidationPenaltyBps > rp.mmrBps)) {
            revert InvalidLiquidationPriceBand();
        }
        _liquidationPriceBandBps[marketId] = bandBps;
        emit IClearingHouse.LiquidationPriceBandSet(marketId, bandBps);
    }

    /// @notice True if a position of the account on `quoteToken`, other than the one in `skip`, is
    ///         liquidatable (ClearingHouse.isLiquidatable).
    /// @dev Delegatecall target of ClearingHouse._hasLiquidatable.
    function hasLiquidatable(address account, address quoteToken, bytes32 skip) external view returns (bool) {
        bytes32[] memory markets = _userActiveMarkets[account];
        for (uint256 i = 0; i < markets.length; i++) {
            if (
                markets[i] != skip && IMarketRegistry(marketRegistry).getMarket(markets[i]).quoteToken == quoteToken
                    && IClearingHouse(address(this)).isLiquidatable(account, markets[i])
            ) return true;
        }
        return false;
    }

    /// @notice Reverts if an openPosition trade (not a pure reduction) breaks the market's OI caps.
    /// @dev Delegatecall target of ClearingHouse.openPosition, after the trade. A trade that leaves gross
    ///      OI above its cap is accepted only if it moved the vAMM mark toward the index without
    ///      crossing it, whether gross rose or not. Arbitrage can then always trade a pushed premium
    ///      back to the index through a filled gross cap, so a pair of offsetting positions cannot
    ///      hold funding at its clamp; above the cap gross grows only by what that takes. Net OI above
    ///      its cap may only fall and stay on its side: moving it up or to the other side is new
    ///      one-sided exposure.
    function checkOpenInterestCaps(bytes32 marketId, uint256 longOIBefore, uint256 shortOIBefore, uint256 markBefore)
        external
        view
    {
        IClearingHouse.OpenInterestCaps memory oiCaps = openInterestCaps[marketId];
        uint256 longOIAfter = totalLongOI[marketId];
        uint256 shortOIAfter = totalShortOI[marketId];

        if (oiCaps.maxGrossOI != 0 && longOIAfter + shortOIAfter > oiCaps.maxGrossOI) {
            IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);
            uint256 markAfter = IVAMM(m.vamm).getMarkPrice();
            uint256 index = _getRiskPrice(m);
            bool towardIndex = markBefore > index
                ? markAfter < markBefore && markAfter >= index
                : markAfter > markBefore && markAfter <= index;
            if (!towardIndex) revert ExceedsMaxGrossOI();
        }

        if (oiCaps.maxNetOI != 0) {
            uint256 netAfter = longOIAfter > shortOIAfter ? longOIAfter - shortOIAfter : shortOIAfter - longOIAfter;
            uint256 netBefore =
                longOIBefore > shortOIBefore ? longOIBefore - shortOIBefore : shortOIBefore - longOIBefore;
            bool sideChanged = (longOIAfter > shortOIAfter) != (longOIBefore > shortOIBefore);
            if (netAfter > oiCaps.maxNetOI && (netAfter > netBefore || sideChanged)) revert ExceedsMaxNetOI();
        }
    }

    /// @notice Funding not yet settled for a position, net of the holding fee accrued since its last
    ///         settlement. View behind ClearingHouse._getPendingFunding.
    function pendingFunding(address account, bytes32 marketId) external view returns (int256) {
        return _pendingFunding(account, marketId);
    }

    /// @notice True if settling the account's funding now would leave the position in `marketId`
    ///         carrying funding debt.
    /// @dev View behind ClearingHouse._isLiquidatable (reached through ClearingHouse.delegateView).
    ///      Replays settleAccountFunding over the account's markets on the same quote token, in the
    ///      same order and with the same rules: a credit adds its tokens to the balance and their value
    ///      to that market's margin; a debit (pending funding net of carried debt) is paid up to the
    ///      backed part of the paying market's margin plus the free collateral value and the balance
    ///      (cutting paid * reserved / value of nominal margin when the balance is worth less than the
    ///      reserve), the rest staying as debt; then markets left in debt are retried. Pending funding is read from the vAMMs'
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
                    uint256 v = _creditValueX18(quote, units);
                    bal += units;
                    margin[i] += v;
                    reserved += v;
                    net[i] = 0;
                } else {
                    uint256 debit = uint256(-x);
                    uint256 value = bal == 0 ? 0 : _quoteValueX18(quote, bal);
                    // Below the reserved margin each margin is backed only in the ratio value / reserved.
                    uint256 cap = value >= reserved
                        ? margin[i] + (value - reserved)
                        : Calculations.mulDiv(margin[i], value, reserved);
                    uint256 paidX18 = debit < cap ? debit : cap;
                    uint256 units = Calculations.mulDivRoundingUp(paidX18, baseUnit, 1e18);
                    if (units > bal) {
                        units = bal;
                        paidX18 = Calculations.mulDiv(bal, 1e18, baseUnit);
                    }
                    bal -= units;
                    uint256 cut = paidX18 == 0 || value >= reserved
                        ? paidX18
                        : Calculations.mulDivRoundingUp(paidX18, reserved, value);
                    if (cut > margin[i]) cut = margin[i];
                    margin[i] -= cut;
                    reserved = reserved > cut ? reserved - cut : 0;
                    net[i] = -int256(debit - paidX18);
                }
            }
        }
        return net[target] < 0;
    }

    // Liquidation penalty steps, moved from ClearingHouseLogic for size (reached through its fallback).

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
    /// @dev Delegatecall target of ClearingHouse.liquidate, after the trade. The penalty is charged on
    ///      the filled size at the pre-trade risk price, and the penalties of one liquidatable episode
    ///      are capped at penaltyCap in total (PositionView.liquidationPenaltyCharged), so a liquidation
    ///      split over several calls pays no more than one done at once. Free collateral (which holds
    ///      the closed slice's released margin) pays first, except the protocol shares earlier calls
    ///      of the account's episodes left owed, which stay there until those episodes end. What it cannot cover is drawn from surplus
    ///      margin on the account's other positions, and only the rest is cut from the margin of the
    ///      liquidated position's remaining size, so a partial liquidation's remainder keeps its margin
    ///      whenever the account holds surplus elsewhere.
    function chargeLiquidationPenalty(
        address account,
        bytes32 marketId,
        address quoteToken,
        uint256 filled,
        uint256 riskPrice
    ) external returns (uint256 notional, uint256 penalty) {
        notional = Calculations.mulDivRoundingUp(filled, riskPrice, 1e18);
        IClearingHouse.MarketRiskParams storage rp = marketRiskParams[marketId];
        penalty = Calculations.mulDivRoundingUp(notional, rp.liquidationPenaltyBps, BPS_DENOMINATOR);
        IClearingHouse.PositionView storage position = positions[account][marketId];
        if (rp.penaltyCap > 0) {
            uint256 charged = position.liquidationPenaltyCharged;
            uint256 left = rp.penaltyCap > charged ? rp.penaltyCap - charged : 0;
            if (penalty > left) penalty = left;
            position.liquidationPenaltyCharged = charged + penalty;
        }
        // The protocol's shares earlier calls left owed stay in free collateral for the episode's end.
        uint256 freeValue = _unowedFreeValue(account, quoteToken, marketId);
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
            freeValue = _unowedFreeValue(account, quoteToken, marketId);
        }
        if (penalty > freeValue) _reduceMargin(account, position, penalty - freeValue);
    }

    /// @notice Free quote value the account can spend or move into margin: the value of its balance
    ///         above the margin reserved on `quoteToken`, less the protocol penalty shares its positions
    ///         on that token still owe (PositionView.liquidationPenaltyOwed, collected when their
    ///         liquidation episode ends). Delegatecall target of ClearingHouse.addMargin.
    /// @dev `marketId`'s owed share is counted even when the position has just been closed and left
    ///      the account's active markets.
    function unowedFreeValue(address account, address quoteToken, bytes32 marketId) external view returns (uint256) {
        return _unowedFreeValue(account, quoteToken, marketId);
    }

    function _unowedFreeValue(address account, address quoteToken, bytes32 marketId) internal view returns (uint256) {
        uint256 owed = positions[account][marketId].liquidationPenaltyOwed;
        bytes32[] memory markets = _userActiveMarkets[account];
        for (uint256 i = 0; i < markets.length; i++) {
            if (markets[i] != marketId && IMarketRegistry(marketRegistry).getMarket(markets[i]).quoteToken == quoteToken) {
                owed += positions[account][markets[i]].liquidationPenaltyOwed;
            }
        }
        uint256 free = _freeQuoteValue(account, quoteToken);
        return free > owed ? free - owed : 0;
    }

}
