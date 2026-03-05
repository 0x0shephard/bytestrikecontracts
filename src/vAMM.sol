//SPDX-License-Identifier:MIT
pragma solidity 0.8.28;

import {IVAMM} from "./Interfaces/IVAMM.sol";
import {Calculations} from "./Libraries/Calculations.sol";
import {IOracle} from "./Interfaces/IOracle.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";


/// @title vAMM (Uniswap v2-style, constant product, no ticks)
/// @notice Virtual reserves X/Y, fee-on-input swaps, funding, and simple admin. CH-only entry.
contract vAMM is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, IVAMM {
	using Calculations for uint256;

	// ========= Roles =========
	address public clearinghouse;
	address public oracle;

	modifier onlyCH() {
		require(msg.sender == clearinghouse, "Not CH");
		_;
	}

	// ========= Virtual reserves (1e18-scaled units) =========
	uint256 private reserveBase;   // X
	uint256 private reserveQuote;  // Y

	// ========= Params / indices =========
	uint16 public feeBps;                // fee on input, in bps
	uint256 public frMaxBpsPerHour;      // funding clamp per hour (bps)
	uint256 public kFundingX18;          // funding scaling factor (1e18 = 1.0)
	// ========= Reserve Protection =========
	uint256 public minReserveBase;       // Minimum base reserve to prevent depletion (1e18)
	uint256 public minReserveQuote;      // Minimum quote reserve to prevent depletion (1e18)

	uint128 private _liquidity;          // accounting denominator for fee growth (not price impacting)
	uint256 private _feeGrowthGlobalX128;
	uint256 private _cumulativeLongPayPerUnitX18;
	uint256 private _cumulativeLongReceivePerUnitX18;
	uint256 private _cumulativeShortPayPerUnitX18;
	uint256 private _cumulativeShortReceivePerUnitX18;
	uint256 public totalLongOI;
	uint256 public totalShortOI;
	uint64  public lastFundingTimestamp;

	bool public swapsPaused;

	uint256 private _cachedIndexPriceX18; // Cached oracle price for funding between pokeFunding calls

	// ========= Constants =========
	uint256 public constant BPS_DENOMINATOR = 10_000;

	// ========= Price Change Protection =========
	/// @notice Maximum allowed price change per resetReserves call (10% = 1000 bps)
	uint256 public constant MAX_PRICE_CHANGE_BPS = 1000;
	/// @notice Minimum delay between resetReserves calls to prevent chaining
	uint256 public constant RESET_COOLDOWN = 1 hours;
	/// @notice Timestamp of the last resetReserves call
	uint64 public lastResetTimestamp;

	// ========= Events =========
	event Initialized(
		address indexed owner,
		address indexed clearinghouse,
		uint256 priceX18,
		uint256 baseReserve,
		uint256 quoteReserve
	);
	event Swap(address indexed sender, int256 baseDelta, int256 quoteDelta, uint256 avgPriceX18);
	event LiquiditySet(uint128 newLiquidity);
	event ParamsSet(uint16 feeBps, uint256 frMaxBpsPerHour, uint256 kFundingX18);
	event SwapsPaused(bool paused);
	event FundingPoked(uint256 longPay, uint256 longReceive, uint256 shortPay, uint256 shortReceive, uint64 timestamp, int256 fundingRateX18);
	event ClearinghouseChanged(address indexed newCH);
	event OracleChanged(address indexed newOracle);
	event MinReservesSet(uint256 minBase, uint256 minQuote);
	event ReservesReset(uint256 newPrice, uint256 newBaseReserve, uint256 newQuoteReserve);

	// ========= Constructor =========
	constructor() {
		_disableInitializers();
	}

	/// @param _clearinghouse CH that can call swaps.
	/// @param _oracle Oracle used for funding calculations.
	/// @param initialPriceX18 initial mark price (quote per base, 1e18).
	/// @param initialBaseReserve virtual base reserve (1e18 units).
	/// @param liquidity_ fee index denominator.
	/// @param feeBps_ trade fee bps (e.g., 10 = 0.1%).
	/// @param frMaxBpsPerHour_ funding clamp per hour (bps).
	/// @param kFundingX18_ funding scaling factor (1e18 = 1.0).
	function initialize(
		address _clearinghouse,
		address _oracle,
		uint256 initialPriceX18,
		uint256 initialBaseReserve,
		uint128 liquidity_,
		uint16 feeBps_,
		uint256 frMaxBpsPerHour_,
		uint256 kFundingX18_
	) external initializer {
		require(_clearinghouse != address(0), "CH=0");
		require(_oracle != address(0), "Oracle=0");
		require(initialPriceX18 > 0, "price=0");
		require(initialBaseReserve > 0, "baseRes=0");
		require(liquidity_ > 0, "L=0");
		require(feeBps_ <= 300, "Fee too high");
		require(frMaxBpsPerHour_ > 0, "frMax=0");
		require(kFundingX18_ > 0, "kFunding=0");

		__Ownable_init(msg.sender);
		__Ownable2Step_init();
		clearinghouse = _clearinghouse;
		oracle = _oracle;

		reserveBase = initialBaseReserve;
		reserveQuote = Calculations.mulDiv(initialBaseReserve, initialPriceX18, 1e18);
		require(reserveQuote > 0, "quote=0");
		require(getMarkPrice() > 0, "mark price=0");

		_liquidity = liquidity_;
		feeBps = feeBps_;
		frMaxBpsPerHour = frMaxBpsPerHour_;
		kFundingX18 = kFundingX18_;
		lastFundingTimestamp = uint64(block.timestamp);

		// Seed cached oracle price for continuous funding accrual
		try IOracle(_oracle).getPrice() returns (uint256 price) {
			_cachedIndexPriceX18 = price > 0 ? price : initialPriceX18;
		} catch {
			_cachedIndexPriceX18 = initialPriceX18;
		}

		emit Initialized(msg.sender, clearinghouse, initialPriceX18, reserveBase, reserveQuote);
		emit ParamsSet(feeBps, frMaxBpsPerHour, kFundingX18);
		emit LiquiditySet(_liquidity);
	}

	// ========= Swaps (CH-only) =========

	/// @notice Buy base asset by paying quote. Trader receives baseAmount of base.
	/// @param baseAmount Amount of base asset to buy (receive).
	/// @param maxQuoteIn Slippage protection: maximum quote tokens willing to pay. 0 = no limit.
	/// @return baseDelta Positive base received by trader.
	/// @return quoteDelta Negative quote paid by trader.
	/// @return avgPriceX18 Effective execution price.
	function buyBase(
		uint128 baseAmount,
		uint256 maxQuoteIn
	) external onlyCH returns (int256 baseDelta, int256 quoteDelta, uint256 avgPriceX18) {
		require(!swapsPaused, "Swaps paused");
		require(baseAmount > 0, "amount=0");
		uint256 X = reserveBase;
		uint256 Y = reserveQuote;
		require(uint256(baseAmount) < X, "insufficient X");

		// Clamp to available capacity at the reserve boundary so that
		// near-boundary trades are partially filled instead of reverting.
		// This prevents front-running from blocking liquidations.
		if (minReserveBase > 0) {
			uint256 available = X > minReserveBase ? X - minReserveBase : 0;
			require(available > 0, "Reserve base depleted");
			if (uint256(baseAmount) > available) {
				baseAmount = uint128(available);
			}
		}

		// Uniswap v2 inverse formula (solve for gross quote in given base out):
		// inWithFeeScaled = dx * Y * 10000 / (X - dx)
		// grossIn = ceil(inWithFeeScaled / (10000 - feeBps))
		uint256 inWithFeeScaled = Calculations.mulDivRoundingUp(uint256(baseAmount), Y * BPS_DENOMINATOR, X - uint256(baseAmount));
		uint256 grossQuoteIn = Calculations.mulDivRoundingUp(inWithFeeScaled, 1, BPS_DENOMINATOR - feeBps);

		avgPriceX18 = Calculations.mulDivRoundingUp(grossQuoteIn, 1e18, uint256(baseAmount));
		require(maxQuoteIn == 0 || grossQuoteIn <= maxQuoteIn, "slippage");

		// Accrue funding at current (pre-trade) mark price before reserves change
		_accrueFunding();

		// Update reserves (v2 style: reserves add gross input, subtract output)
		reserveQuote = Y + grossQuoteIn;
		reserveBase = X - uint256(baseAmount);

		// Fee accounting
		uint256 fee = grossQuoteIn - Calculations.mulDiv(grossQuoteIn, BPS_DENOMINATOR - feeBps, BPS_DENOMINATOR);
		if (_liquidity > 0 && fee > 0) {
			_feeGrowthGlobalX128 += (fee << 128) / _liquidity;
		}

		baseDelta = int256(uint256(baseAmount));   // +base to trader
		quoteDelta = -int256(grossQuoteIn);        // -quote from trader
		emit Swap(msg.sender, baseDelta, quoteDelta, avgPriceX18);
	}

	/// @notice Sell base asset to receive quote. Used for shorting or closing longs.
	/// @param baseAmount Amount of base asset to sell.
	/// @param minQuoteOut Slippage protection: minimum quote tokens expected to receive. 0 = no limit.
	/// @return baseDelta Negative base sold by trader.
	/// @return quoteDelta Positive quote received by trader.
	/// @return avgPriceX18 Effective execution price.
	function sellBase(
		uint128 baseAmount,
		uint256 minQuoteOut
	) external onlyCH returns (int256 baseDelta, int256 quoteDelta, uint256 avgPriceX18) {
		require(!swapsPaused, "Swaps paused");
		require(baseAmount > 0, "amount=0");
		uint256 X = reserveBase;
		uint256 Y = reserveQuote;

		// Uniswap v2 formula (solve for quote out given base in):
		// out = dy = Y * dx * (10000 - fee) / (X * 10000 + dx * (10000 - fee))
		uint256 grossBaseIn = uint256(baseAmount);
		uint256 numerator = Y * grossBaseIn * (BPS_DENOMINATOR - feeBps);
		uint256 denominator = X * BPS_DENOMINATOR + grossBaseIn * (BPS_DENOMINATOR - feeBps);
		uint256 quoteOut = numerator / denominator;

		// Clamp to available reserve capacity so that near-boundary trades
		// are partially filled instead of reverting.
		if (minReserveQuote > 0) {
			uint256 newReserveQuote = Y - quoteOut;
			if (newReserveQuote < minReserveQuote) {
				uint256 maxQuoteOut = Y > minReserveQuote ? Y - minReserveQuote : 0;
				require(maxQuoteOut > 0, "Reserve quote depleted");
				quoteOut = maxQuoteOut;
				// Reverse-solve for the actual base consumed:
				// quoteOut = Y*dx*f / (X*10000 + dx*f)
				//   → dx = quoteOut * X * 10000 / (f * (Y - quoteOut))
				uint256 f = uint256(BPS_DENOMINATOR - feeBps);
				grossBaseIn = Calculations.mulDivRoundingUp(maxQuoteOut, X * BPS_DENOMINATOR, f * minReserveQuote);
				// Safety: never consume more base than the caller offered
				if (grossBaseIn > uint256(baseAmount)) grossBaseIn = uint256(baseAmount);
			}
		}

		require(quoteOut > 0, "no out");

		avgPriceX18 = Calculations.mulDiv(quoteOut, 1e18, grossBaseIn);
		require(minQuoteOut == 0 || quoteOut >= minQuoteOut, "slippage");

		// Accrue funding at current (pre-trade) mark price before reserves change
		_accrueFunding();

		// Update reserves
		reserveBase = X + grossBaseIn;
		reserveQuote = Y - quoteOut;

		require(getMarkPrice() > 0, "Mark price zero");

		// Fee accounting
		uint256 feeInBase = Calculations.mulDivRoundingUp(grossBaseIn, feeBps, BPS_DENOMINATOR);
		if (_liquidity > 0 && feeInBase > 0) {
			uint256 feeInQuote = Calculations.mulDivRoundingUp(feeInBase, avgPriceX18, 1e18);
			_feeGrowthGlobalX128 += (feeInQuote << 128) / _liquidity;
		}

		baseDelta = -int256(grossBaseIn);  // -base from trader
		quoteDelta = int256(quoteOut);     // +quote to trader
		emit Swap(msg.sender, baseDelta, quoteDelta, avgPriceX18);
	}

	// ========= Views =========

	/// @notice Returns the instantaneous mark price derived from the current virtual reserves.
	/// @dev Mark price is computed as quote reserve divided by base reserve in 1e18 precision.
	function getMarkPrice() public view returns (uint256) {
		require(reserveBase > 0, "X=0");
		return Calculations.mulDiv(reserveQuote, 1e18, reserveBase); // Y/X in 1e18
	}

	/// @notice Exposes the current sqrt price in Uniswap V3 Q96 format for integrations and diagnostics.
	/// @dev Converts the 1e18 mark price into a Q96 value by scaling before taking the square root.
	function getSqrtPriceX96() external view returns (uint160) {
		// sqrtPriceX96 = sqrt(priceX18 * 2^192 / 1e18)
		uint256 priceX18 = getMarkPrice();
		uint256 scaled = Calculations.mulDiv(priceX18, uint256(1) << 192, 1e18);
		uint256 r = Calculations.sqrt(scaled);
		require(r <= type(uint160).max, "sqrt overflow");
		return uint160(r);
	}

	/// @notice Returns the current tick for compatibility with AMM style interfaces.
	/// @dev vAMM emulates constant product pricing with no discrete ticks, so this always returns zero.
	function getTick() external pure returns (int24) {
		// No ticks in v2 style; return 0 for diagnostics.
		return 0;
	}

	/// @notice Returns the virtual liquidity scalar used for fee growth accounting.
	/// @dev This value does not affect pricing and is only used to index protocol fee accumulation per unit liquidity.
	function getLiquidity() external view returns (uint128) {
		// Accounting denominator only; does not affect price
		return _liquidity;
	}

	/// @notice Returns the global fee growth accumulator scaled by 2^128.
	/// @dev Consumers can use this alongside their liquidity share to compute realized protocol fees.
	function feeGrowthGlobalX128() external view returns (uint256) {
		return _feeGrowthGlobalX128;
	}

	function cumulativeLongPayPerUnitX18() external view returns (uint256) {
		return _cumulativeLongPayPerUnitX18;
	}

	function cumulativeLongReceivePerUnitX18() external view returns (uint256) {
		return _cumulativeLongReceivePerUnitX18;
	}

	function cumulativeShortPayPerUnitX18() external view returns (uint256) {
		return _cumulativeShortPayPerUnitX18;
	}

	function cumulativeShortReceivePerUnitX18() external view returns (uint256) {
		return _cumulativeShortReceivePerUnitX18;
	}

	/// @dev Computes the raw funding rate for the elapsed period (view helper).
	function _computeFundingRate() internal view returns (int256 fundingRateX18) {
		if (swapsPaused || _cachedIndexPriceX18 == 0) return 0;

		uint64 nowTs = uint64(block.timestamp);
		uint64 lastTs = lastFundingTimestamp;
		if (nowTs <= lastTs) return 0;

		uint256 markX18 = getMarkPrice();
		uint256 indexPriceX18 = _cachedIndexPriceX18;

		uint256 timeElapsed = nowTs - lastTs;
		if (timeElapsed > MAX_FUNDING_ELAPSED) {
			timeElapsed = MAX_FUNDING_ELAPSED;
		}

		int256 premiumX18 = int256(markX18) - int256(indexPriceX18);
		fundingRateX18 = (premiumX18 * int256(kFundingX18) * int256(timeElapsed)) / (1 days * 1e18);

		uint256 maxRateAbs = (frMaxBpsPerHour * timeElapsed * indexPriceX18) / (1 hours * BPS_DENOMINATOR);
		if (fundingRateX18 > 0 && uint256(fundingRateX18) > maxRateAbs) {
			fundingRateX18 = int256(maxRateAbs);
		}
		if (fundingRateX18 < 0 && uint256(-fundingRateX18) > maxRateAbs) {
			fundingRateX18 = -int256(maxRateAbs);
		}
	}

	function currentCumulativeLongPayPerUnitX18() external view returns (uint256) {
		int256 fundingRateX18 = _computeFundingRate();
		if (fundingRateX18 > 0 && totalLongOI > 0 && totalShortOI > 0) {
			return _cumulativeLongPayPerUnitX18 + uint256(fundingRateX18);
		}
		return _cumulativeLongPayPerUnitX18;
	}

	function currentCumulativeLongReceivePerUnitX18() external view returns (uint256) {
		int256 fundingRateX18 = _computeFundingRate();
		if (fundingRateX18 < 0 && totalLongOI > 0 && totalShortOI > 0) {
			uint256 rate = uint256(-fundingRateX18);
			return _cumulativeLongReceivePerUnitX18 + (rate * totalShortOI) / totalLongOI;
		}
		return _cumulativeLongReceivePerUnitX18;
	}

	function currentCumulativeShortPayPerUnitX18() external view returns (uint256) {
		int256 fundingRateX18 = _computeFundingRate();
		if (fundingRateX18 < 0 && totalLongOI > 0 && totalShortOI > 0) {
			return _cumulativeShortPayPerUnitX18 + uint256(-fundingRateX18);
		}
		return _cumulativeShortPayPerUnitX18;
	}

	function currentCumulativeShortReceivePerUnitX18() external view returns (uint256) {
		int256 fundingRateX18 = _computeFundingRate();
		if (fundingRateX18 > 0 && totalLongOI > 0 && totalShortOI > 0) {
			uint256 rate = uint256(fundingRateX18);
			return _cumulativeShortReceivePerUnitX18 + (rate * totalLongOI) / totalShortOI;
		}
		return _cumulativeShortReceivePerUnitX18;
	}

	/// @notice Returns the cached oracle index price used for continuous funding accrual.
	function cachedIndexPrice() external view returns (uint256) {
		return _cachedIndexPriceX18;
	}

	// ========= Admin / Keepers =========

	/// @notice Updates the virtual liquidity scalar used for fee growth accounting.
	/// @dev Restricted to the owner; reverts if set to zero.
	function setLiquidity(uint128 newLiquidity) external onlyOwner {
		require(newLiquidity > 0, "L=0");
		require(_feeGrowthGlobalX128 == 0, "Fees already accruing");
		_liquidity = newLiquidity; // does not change price; used for fee index scaling
		emit LiquiditySet(newLiquidity);
	}

	/// @notice Updates core trading and funding parameters for the vAMM.
	/// @param feeBps_ New trade fee in basis points (max 3% to match MarketRegistry.MAX_FEE_BPS).
	/// @param frMaxBpsPerHour_ Maximum allowed funding rate drift per hour in basis points.
	/// @param kFundingX18_ Funding sensitivity scaling factor.
	function setParams(
		uint16 feeBps_,
		uint256 frMaxBpsPerHour_,
		uint256 kFundingX18_
	) external onlyOwner {
		// Settle accumulated funding under current parameters before applying new ones
		_pokeFundingInternal();
		require(feeBps_ <= 300, "Fee too high"); // Max 3% (matches MarketRegistry.MAX_FEE_BPS)
		require(frMaxBpsPerHour_ > 0, "frMax=0");
		require(kFundingX18_ > 0, "kFunding=0");
		feeBps = feeBps_;
		frMaxBpsPerHour = frMaxBpsPerHour_;
		kFundingX18 = kFundingX18_;
		emit ParamsSet(feeBps, frMaxBpsPerHour, kFundingX18);
	}

	/// @notice Updates the cumulative funding index using the current mark price and oracle index price.
	/// @dev Funding rate is clamped by frMaxBpsPerHour and accumulated into the long/short cumulative indices.
	/// @dev Gracefully handles oracle failures by advancing the timestamp (preventing accumulation of outage time).
	/// @dev Caps timeElapsed to 1 hour so a single update never covers more than one funding interval.
	uint256 public constant MAX_FUNDING_ELAPSED = 1 hours; // 1 hour cap per update

	function pokeFunding() external {
		_pokeFundingInternal();
	}

	/// @dev Accrue funding for the elapsed period using current mark price and cached oracle price.
	/// Called before every reserve change to make the cumulative index a true time-integral.
	/// Uses two separate indices scaled by OI ratio so total paid == total received.
	function _accrueFunding() internal {
		if (swapsPaused) return;

		uint64 nowTs = uint64(block.timestamp);
		uint64 lastTs = lastFundingTimestamp;
		if (nowTs <= lastTs) return;
		if (_cachedIndexPriceX18 == 0) return;

		// Skip accrual if either side has no OI (nothing to balance)
		if (totalLongOI == 0 || totalShortOI == 0) {
			lastFundingTimestamp = nowTs;
			return;
		}

		uint256 markX18 = getMarkPrice();
		uint256 indexPriceX18 = _cachedIndexPriceX18;

		uint256 timeElapsed = nowTs - lastTs;
		if (timeElapsed > MAX_FUNDING_ELAPSED) {
			timeElapsed = MAX_FUNDING_ELAPSED;
		}

		int256 premiumX18 = int256(markX18) - int256(indexPriceX18);
		int256 fundingRateX18 = (premiumX18 * int256(kFundingX18) * int256(timeElapsed)) / (1 days * 1e18);

		uint256 maxRateAbs = (frMaxBpsPerHour * timeElapsed * indexPriceX18) / (1 hours * BPS_DENOMINATOR);
		if (fundingRateX18 > 0 && uint256(fundingRateX18) > maxRateAbs) {
			fundingRateX18 = int256(maxRateAbs);
		}
		if (fundingRateX18 < 0 && uint256(-fundingRateX18) > maxRateAbs) {
			fundingRateX18 = -int256(maxRateAbs);
		}

		if (fundingRateX18 > 0) {
			// Longs pay shorts
			uint256 rate = uint256(fundingRateX18);
			_cumulativeLongPayPerUnitX18 += rate;
			_cumulativeShortReceivePerUnitX18 += (rate * totalLongOI) / totalShortOI;
		} else if (fundingRateX18 < 0) {
			// Shorts pay longs
			uint256 rate = uint256(-fundingRateX18);
			_cumulativeShortPayPerUnitX18 += rate;
			_cumulativeLongReceivePerUnitX18 += (rate * totalShortOI) / totalLongOI;
		}

		lastFundingTimestamp = nowTs;
	}

	/// @dev Accrue funding at the current cached oracle price, then refresh the oracle cache.
	function _pokeFundingInternal() internal {
		if (swapsPaused) return;

		// Snapshot long pay before accrual to compute the delta for the event
		uint256 longPayBefore = _cumulativeLongPayPerUnitX18;

		// Accrue any pending funding at the current cached oracle price
		_accrueFunding();

		// Refresh cached oracle price for future accruals
		try IOracle(oracle).getPrice() returns (uint256 price) {
			if (price > 0) _cachedIndexPriceX18 = price;
		} catch {
			// Keep old cached price; timestamp already advanced by _accrueFunding
		}

		// Derive the signed funding rate delta from the long pay index change
		int256 fundingRateDelta = int256(_cumulativeLongPayPerUnitX18 - longPayBefore);

		emit FundingPoked(
			_cumulativeLongPayPerUnitX18,
			_cumulativeLongReceivePerUnitX18,
			_cumulativeShortPayPerUnitX18,
			_cumulativeShortReceivePerUnitX18,
			uint64(block.timestamp),
			fundingRateDelta
		);
	}

	/// @notice Toggles the swap execution flag, enabling or disabling all trading through the vAMM.
	/// @param paused True to pause swaps, false to resume.
	function pauseSwaps(bool paused) external {
		require(msg.sender == owner() || msg.sender == clearinghouse, "Not owner or CH");
		if (paused) {
			// Flush any accumulated funding under the current price before pausing
			_pokeFundingInternal();
		} else {
			// Skip the paused interval for funding so it doesn't retroactively accrue
			lastFundingTimestamp = uint64(block.timestamp);
		}
		swapsPaused = paused;
		emit SwapsPaused(paused);
	}

	/// @notice Updates open interest from ClearingHouse for balanced funding scaling.
	/// @param longOI Total long open interest.
	/// @param shortOI Total short open interest.
	function updateOpenInterest(uint256 longOI, uint256 shortOI) external onlyCH {
		totalLongOI = longOI;
		totalShortOI = shortOI;
	}

	/// @notice Updates the clearinghouse contract authorized to interact with the vAMM.
	/// @param newCH Address of the replacement clearinghouse.
	function setClearinghouse(address newCH) external onlyOwner {
		require(newCH != address(0), "CH=0");
		clearinghouse = newCH;
		emit ClearinghouseChanged(newCH);
	}

	/// @notice Sets the oracle used to retrieve index prices for funding calculations.
	/// @dev Flushes pending funding at the old oracle price, then refreshes the cache with the new oracle.
	/// @param newOracle Address of the oracle contract; must not be zero.
	function setOracle(address newOracle) external onlyOwner {
		require(newOracle != address(0), "oracle=0");
		_accrueFunding(); // Flush funding at old oracle price
		oracle = newOracle;
		try IOracle(newOracle).getPrice() returns (uint256 price) {
			if (price > 0) _cachedIndexPriceX18 = price;
		} catch {}
		emit OracleChanged(newOracle);
	}

	/// @notice Sets minimum reserve thresholds to prevent reserve depletion
	/// @param minBase_ Minimum base reserve (1e18 units)
	/// @param minQuote_ Minimum quote reserve (1e18 units)
	function setMinReserves(uint256 minBase_, uint256 minQuote_) external onlyOwner {
		minReserveBase = minBase_;
		minReserveQuote = minQuote_;
		emit MinReservesSet(minBase_, minQuote_);
	}

	/// @notice Emergency function to reset reserves if they become depleted
	/// @dev Only callable by owner. Use to rescue vAMM from broken state.
	/// Price change is limited to MAX_PRICE_CHANGE_BPS (10%) per call to prevent instant liquidations.
	/// @param newPriceX18 New mark price to set (quote per base, 1e18)
	/// @param newBaseReserve New base reserve amount (1e18 units)
	function resetReserves(uint256 newPriceX18, uint256 newBaseReserve) external onlyOwner {
		require(newPriceX18 > 0, "price=0");
		require(newBaseReserve > 0, "base=0");
		require(block.timestamp >= lastResetTimestamp + RESET_COOLDOWN, "Reset cooldown active");

		// Check price change is within allowed limits to prevent instant liquidations
		uint256 currentPrice = getMarkPrice();
		uint256 priceDiff = newPriceX18 > currentPrice
			? newPriceX18 - currentPrice
			: currentPrice - newPriceX18;
		uint256 maxAllowedChange = (currentPrice * MAX_PRICE_CHANGE_BPS) / BPS_DENOMINATOR;
		require(priceDiff <= maxAllowedChange, "Price change too large");

		// Calculate new quote reserve: Y = X * Price
		uint256 newQuoteReserve = Calculations.mulDiv(newBaseReserve, newPriceX18, 1e18);
		require(newQuoteReserve > 0, "quote=0");
		require(Calculations.mulDiv(newQuoteReserve, 1e18, newBaseReserve) > 0, "mark price=0");

		// Ensure new reserves meet minimum requirements
		require(newBaseReserve >= minReserveBase, "base < min");
		require(newQuoteReserve >= minReserveQuote, "quote < min");

		// Flush funding at current (pre-reset) mark price and refresh oracle cache
		_pokeFundingInternal();

		reserveBase = newBaseReserve;
		reserveQuote = newQuoteReserve;
		lastResetTimestamp = uint64(block.timestamp);

		emit ReservesReset(newPriceX18, newBaseReserve, newQuoteReserve);
	}

	// ========= Helpers =========
	/// @notice Returns the current virtual base and quote reserves used for pricing.
	function getReserves() external view returns (uint256 base, uint256 quote) {
		return (reserveBase, reserveQuote);
	}

	function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

}
