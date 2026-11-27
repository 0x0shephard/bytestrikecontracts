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
}
