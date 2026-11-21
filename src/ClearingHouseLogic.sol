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

/// @notice Logic contract for ClearingHouse heavy functions, called via delegatecall.
/// @dev Storage layout MUST mirror ClearingHouse slots 0-10 exactly.
///      Any addition/removal of storage variables in ClearingHouse must be reflected here.
contract ClearingHouseLogic {
    using Calculations for uint256;

    // =========================================================================
    // Storage layout — must mirror ClearingHouse exactly (slots 0-10)
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

    // =========================================================================
    // External entry points (delegatecall targets from ClearingHouse)
    // =========================================================================

    function applyTrade(
        address account,
        bytes32 marketId,
        int256 baseDelta,
        int256 quoteDelta,
        bool isLiquidation
    ) external {
        _applyTrade(account, marketId, baseDelta, quoteDelta, isLiquidation);
    }

    function settleFundingInternal(bytes32 marketId, address account) external {
        _settleFundingInternal(marketId, account);
    }

    // =========================================================================
    // Core logic (moved from ClearingHouse)
    // =========================================================================

    function _applyTrade(address account, bytes32 marketId, int256 baseDelta, int256 quoteDelta, bool isLiquidation) internal {
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
            if (s0 > 0) {
                realized = (int256(execPxX18) - int256(position.entryPriceX18)) * int256(reduceAmt) / 1e18;
            } else {
                realized = (int256(position.entryPriceX18) - int256(execPxX18)) * int256(reduceAmt) / 1e18;
            }

            if (absS1 == 0) {
                position.entryPriceX18 = 0;
            } else if ((s0 > 0 && s1 < 0) || (s0 < 0 && s1 > 0)) {
                position.entryPriceX18 = execPxX18;
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
            } else if (s1 < 0 && s0 >= 0) {
                position.lastFundingPayIndex = vammFI.cumulativeShortPayPerUnitX18();
                position.lastFundingReceiveIndex = vammFI.cumulativeShortReceivePerUnitX18();
            }
        }

        if (s0 == 0 && s1 != 0) {
            _addActiveMarket(account, marketId);
        } else if (s1 == 0) {
            _removeActiveMarket(account, marketId);
        }

        if (realized != 0) {
            // Only a liquidation may realize a loss beyond the account's vault balance.
            _settlePnLInVault(account, marketId, realized, isLiquidation);
        }

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

        if (s0 == 0 || ((s0 > 0 && baseDelta > 0) || (s0 < 0 && baseDelta < 0))) {
            uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
            uint256 oraclePrice = _getRiskPrice(m);
            uint256 imrPrice = markPrice > oraclePrice ? markPrice : oraclePrice;
            uint256 tradeNotional = absBaseDelta.mulDiv(imrPrice, 1e18);
            uint256 marginRequired = tradeNotional.mulDiv(rp.imrBps, BPS_DENOMINATOR);
            if (!isLiquidation && marginRequired > 0) {
                _ensureAvailableCollateral(account, marginRequired, m.quoteToken);
            }
            position.margin += marginRequired;
            _totalReservedMargin[account] += marginRequired;
        } else {
            uint256 reduceAmt = absBaseDelta <= absS0 ? absBaseDelta : absS0;
            uint256 marginRelease = (position.margin * reduceAmt) / absS0;
            position.margin -= marginRelease;
            _totalReservedMargin[account] -= marginRelease;

            if (absBaseDelta > absS0) {
                uint256 openAmt = absBaseDelta - absS0;
                uint256 markPrice = IVAMM(m.vamm).getMarkPrice();
                uint256 oraclePrice = _getRiskPrice(m);
                uint256 imrPrice = markPrice > oraclePrice ? markPrice : oraclePrice;
                uint256 openNotional = openAmt.mulDiv(imrPrice, 1e18);
                uint256 marginRequired = openNotional.mulDiv(rp.imrBps, BPS_DENOMINATOR);
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
            if (!(marginValue >= requiredMargin)) revert IMRBreach();

            {
                int256 unrealizedPnL = _computeUnrealizedPnL(position, oraclePrice);
                int256 effectiveMargin = int256(marginValue) + unrealizedPnL;
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

        // Funding only accrues while it can be settled in the quote token. If the quote oracle is
        // unavailable (stale round, sequencer down or in grace period), advance the funding clock
        // without accruing so payers are not charged for time in which they cannot act.
        if (!_quoteOracleLive(m.quoteToken)) {
            vamm.skipFunding();
            return;
        }

        (uint256 longPay, uint256 longReceive, uint256 shortPay, uint256 shortReceive) = vamm.pokeFunding();

        IClearingHouse.PositionView storage position = positions[account][marketId];

        uint256 currentPay;
        uint256 currentReceive;
        if (position.size > 0) {
            currentPay = longPay;
            currentReceive = longReceive;
        } else if (position.size < 0) {
            currentPay = shortPay;
            currentReceive = shortReceive;
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

            _settlePnLInVault(account, marketId, fundingPayment, true);

            if (fundingPayment > 0) {
                uint256 credit = uint256(fundingPayment);
                position.margin += credit;
                _totalReservedMargin[account] += credit;
            } else if (fundingPayment < 0) {
                uint256 debit = uint256(-fundingPayment);
                if (debit >= position.margin) {
                    // The vault balance was already debited for the full amount
                    // (capped at the balance) by _settlePnLInVault above, so the
                    // overflow beyond the position margin must not be reserved again.
                    _totalReservedMargin[account] = (_totalReservedMargin[account] > position.margin)
                        ? (_totalReservedMargin[account] - position.margin)
                        : 0;
                    position.margin = 0;
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

    /// @dev Books realized PnL or funding in the vault. Both legs of one zero-sum exchange are
    /// converted at the same fixed rate (see _pnlToQuoteUnits), so the winner's credit and the
    /// loser's debit net in tokens whatever quote-token price each settlement would read.
    /// @param allowBadDebt True for liquidations and funding, where a loss beyond the vault balance
    /// is written off; a voluntary trade with such a loss reverts instead.
    function _settlePnLInVault(address account, bytes32 marketId, int256 realized, bool allowBadDebt) internal {
        IMarketRegistry.Market memory m = IMarketRegistry(marketRegistry).getMarket(marketId);

        if (realized > 0) {
            uint256 profitInQuote = _pnlToQuoteUnits(uint256(realized), m.quoteToken, false);
            if (profitInQuote > 0) {
                ICollateralVault(vault).settlePnL(account, m.quoteToken, int256(profitInQuote));
            }
        } else {
            uint256 lossInQuote = _pnlToQuoteUnits(uint256(-realized), m.quoteToken, true);
            if (lossInQuote > 0) {
                uint256 available = ICollateralVault(vault).balanceOf(account, m.quoteToken);
                if (lossInQuote > available) {
                    if (!allowBadDebt) revert InsufficientQuoteCollateral();
                    uint256 badDebt = lossInQuote - available;
                    lossInQuote = available;
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

        (uint256 actualReceived, uint256 shortfall) = _collectQuote(account, m.feeRouter, m.quoteToken, feeInQuoteDecimals, true);
        if (!(shortfall == 0)) revert InsufficientQuoteForFee();
        IFeeRouter(m.feeRouter).onTradeFee(actualReceived);
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

    /// @dev Converts realized PnL or funding (1e18 quote value) to quote-token units at a fixed
    /// rate of one whole token (`baseUnit`, i.e. 10**decimals) per 1e18 of quote value, independent
    /// of the live quote-token oracle. Profits round down, losses round up.
    /// Fees, penalties and margin valuation keep using the live oracle price.
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
