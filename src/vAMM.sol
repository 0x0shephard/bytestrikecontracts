//SPDX-License-Identifier:MIT
pragma solidity 0.8.28;

import {IVAMM} from "./Interfaces/IVAMM.sol";
import {Calculations} from "./Libraries/Calculations.sol";
import {IOracle} from "./Interfaces/IOracle.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";


/// @title vAMM (Uniswap v2-style, constant product, no ticks)
/// @notice Virtual reserves X/Y, fee-on-input swaps, TWAP, and simple admin. CH-only entry.
contract vAMM is Initializable, UUPSUpgradeable, IVAMM {
	using Calculations for uint256;

	// ========= Roles =========
	address public owner;
	address public clearinghouse;
	address public oracle;

	modifier onlyOwner() {
		require(msg.sender == owner, "Not owner");
		_;
	}
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
	uint32 public observationWindow;     // default TWAP window (s)

	// ========= Reserve Protection =========
	uint256 public minReserveBase;       // Minimum base reserve to prevent depletion (1e18)
	uint256 public minReserveQuote;      // Minimum quote reserve to prevent depletion (1e18)

	uint128 private _liquidity;          // accounting denominator for fee growth (not price impacting)
	uint256 private _feeGrowthGlobalX128;
	int256 private _cumulativeFundingPerUnitX18;
	uint64  public lastFundingTimestamp;

	bool public swapsPaused;

	// ========= Price Change Protection =========
	/// @notice Maximum allowed price change per resetReserves call (10% = 1000 bps)
	uint256 public constant MAX_PRICE_CHANGE_BPS = 1000;

	// ========= TWAP (v2-style cumulative) =========
	struct Observation {
		uint32 timestamp;
		uint256 priceCumulativeX128; // sum(priceX128 * dt)
	}
	uint16 private constant OBS_CARDINALITY = 64;
	Observation[OBS_CARDINALITY] private _obs;
	uint16 private _obsIndex;
	bool   private _obsInit;

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
	event ParamsSet(uint16 feeBps, uint256 frMaxBpsPerHour, uint256 kFundingX18, uint32 observationWindow);
	event SwapsPaused(bool paused);
	event FundingPoked(int256 cumulativeFundingPerUnitX18, uint64 timestamp, int256 fundingRateX18);
	event OwnerChanged(address indexed newOwner);
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
	/// @param observationWindow_ default TWAP window (s).
	function initialize(
		address _clearinghouse,
		address _oracle,
		uint256 initialPriceX18,
		uint256 initialBaseReserve,
		uint128 liquidity_,
		uint16 feeBps_,
		uint256 frMaxBpsPerHour_,
		uint256 kFundingX18_,
		uint32 observationWindow_
	) external initializer {
		require(_clearinghouse != address(0), "CH=0");
		require(_oracle != address(0), "Oracle=0");
		require(initialPriceX18 > 0, "price=0");
		require(initialBaseReserve > 0, "baseRes=0");
		require(liquidity_ > 0, "L=0");
		require(feeBps_ <= 300, "Fee too high"); 

		owner = msg.sender;
		clearinghouse = _clearinghouse;
		oracle = _oracle;

		reserveBase = initialBaseReserve;
		reserveQuote = Calculations.mulDiv(initialBaseReserve, initialPriceX18, 1e18);

		_liquidity = liquidity_;
		feeBps = feeBps_;
		frMaxBpsPerHour = frMaxBpsPerHour_;
		kFundingX18 = kFundingX18_;
		observationWindow = observationWindow_;
		lastFundingTimestamp = uint64(block.timestamp);

		_obs[0] = Observation({timestamp: uint32(block.timestamp), priceCumulativeX128: 0});
		_obsIndex = 0;
		_obsInit = true;

		emit Initialized(owner, clearinghouse, initialPriceX18, reserveBase, reserveQuote);
		emit ParamsSet(feeBps, frMaxBpsPerHour, kFundingX18, observationWindow);
		emit LiquiditySet(_liquidity);
	}

	// ========= Swaps (CH-only) =========

	/// @notice Buy base asset by paying quote. Trader receives baseAmount of base.
	/// @param baseAmount Amount of base asset to buy (receive).
	/// @param priceLimitX18 Maximum acceptable price (quote per base, 1e18). 0 = no limit.
	/// @return baseDelta Positive base received by trader.
	/// @return quoteDelta Negative quote paid by trader.
	/// @return avgPriceX18 Effective execution price.
	function buyBase(
		uint128 baseAmount,
		uint256 priceLimitX18
	) external onlyCH returns (int256 baseDelta, int256 quoteDelta, uint256 avgPriceX18) {
		require(!swapsPaused, "Swaps paused");
		require(baseAmount > 0, "amount=0");
		uint256 X = reserveBase;
		uint256 Y = reserveQuote;
		require(uint256(baseAmount) < X, "insufficient X");

		_accumulatePrice(); // update cumulative before price move

		// Uniswap v2 inverse formula (solve for gross quote in given base out):
		// inWithFeeScaled = dx * Y * 10000 / (X - dx)
		// grossIn = ceil(inWithFeeScaled / (10000 - feeBps))
		uint256 inWithFeeScaled = Calculations.mulDivRoundingUp(uint256(baseAmount), Y * 10_000, X - uint256(baseAmount));
		uint256 grossQuoteIn = Calculations.mulDivRoundingUp(inWithFeeScaled, 1, 10_000 - feeBps);

		avgPriceX18 = Calculations.mulDiv(grossQuoteIn, 1e18, uint256(baseAmount));
		require(priceLimitX18 == 0 || avgPriceX18 <= priceLimitX18, "slippage");

		// Update reserves (v2 style: reserves add gross input, subtract output)
		uint256 newReserveBase = X - uint256(baseAmount);
		require(newReserveBase >= minReserveBase, "Reserve base depleted");

		reserveQuote = Y + grossQuoteIn;
		reserveBase = newReserveBase;

		// Fee accounting
		uint256 fee = grossQuoteIn - Calculations.mulDiv(grossQuoteIn, 10_000 - feeBps, 10_000);
		if (_liquidity > 0 && fee > 0) {
			_feeGrowthGlobalX128 += (fee << 128) / _liquidity;
		}

		baseDelta = int256(uint256(baseAmount));   // +base to trader
		quoteDelta = -int256(grossQuoteIn);        // -quote from trader
		_writeObservation();
		emit Swap(msg.sender, baseDelta, quoteDelta, avgPriceX18);
	}

	/// @notice Sell base asset to receive quote. Used for shorting or closing longs.
	/// @param baseAmount Amount of base asset to sell.
	/// @param priceLimitX18 Minimum acceptable price (quote per base, 1e18). 0 = no limit.
	/// @return baseDelta Negative base sold by trader.
	/// @return quoteDelta Positive quote received by trader.
	/// @return avgPriceX18 Effective execution price.
	function sellBase(
		uint128 baseAmount,
		uint256 priceLimitX18
	) external onlyCH returns (int256 baseDelta, int256 quoteDelta, uint256 avgPriceX18) {
		require(!swapsPaused, "Swaps paused");
		require(baseAmount > 0, "amount=0");
		uint256 X = reserveBase;
		uint256 Y = reserveQuote;

		_accumulatePrice();

		// Uniswap v2 formula (solve for quote out given base in):
		// out = dy = Y * dx * (10000 - fee) / (X * 10000 + dx * (10000 - fee))
		uint256 grossBaseIn = uint256(baseAmount);
		uint256 numerator = Y * grossBaseIn * (10_000 - feeBps);
		uint256 denominator = X * 10_000 + grossBaseIn * (10_000 - feeBps);
		uint256 quoteOut = numerator / denominator;

		require(quoteOut > 0, "no out");

		avgPriceX18 = Calculations.mulDiv(quoteOut, 1e18, grossBaseIn);
		require(priceLimitX18 == 0 || avgPriceX18 >= priceLimitX18, "slippage");

		// Update reserves with protection
		uint256 newReserveQuote = Y - quoteOut;
		require(newReserveQuote >= minReserveQuote, "Reserve quote depleted");

		reserveBase = X + grossBaseIn;
		reserveQuote = newReserveQuote;

		require(getMarkPrice() > 0, "Mark price zero");

		// Fee accounting
		uint256 feeInBase = Calculations.mulDiv(grossBaseIn, feeBps, 10_000);
		if (_liquidity > 0 && feeInBase > 0) {
			uint256 feeInQuote = feeInBase.mulDiv(avgPriceX18, 1e18);
			_feeGrowthGlobalX128 += (feeInQuote << 128) / _liquidity;
		}

		baseDelta = -int256(grossBaseIn);  // -base from trader
		quoteDelta = int256(quoteOut);     // +quote to trader
		_writeObservation();
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

	/// @notice Computes the time-weighted average mark price over a lookback window.
	/// @param window Number of seconds to look back; defaults to configured observationWindow when zero.
	/// @return twapX18 TWAP mark price in 1e18 precision.
	function getTwap(uint32 window) public view returns (uint256) {
		if (!_obsInit) revert("TWAP: not initialized");
		if (window == 0) window = observationWindow;
		require(window > 0, "TWAP: window=0");

		(uint256 cumNow, uint32 tsNow) = _peekCumulative();
		if (window >= tsNow) {
			window = tsNow;
		}
		uint32 targetTs = tsNow - window;

		// Scan back across ring buffer to find obs at/before targetTs
		uint16 idx = _obsIndex;
		uint16 scanned;
		Observation memory obsPast;
		bool found;
		while (scanned < OBS_CARDINALITY) {
			Observation memory o = _obs[idx];
			if (o.timestamp == 0) {
				break;
			}
			obsPast = o;
			if (o.timestamp <= targetTs) {
				found = true;
				break;
			}
			idx = (idx == 0) ? (OBS_CARDINALITY - 1) : (idx - 1);
			scanned++;
		}

		require(obsPast.timestamp != 0, "TWAP: no observations");
		require(tsNow > obsPast.timestamp, "TWAP: same timestamp");

		// Require actual span covers at least half the requested window
		uint32 actualSpan = tsNow - uint32(obsPast.timestamp);
		require(actualSpan >= window / 2, "TWAP: insufficient history");

		uint256 deltaCum = cumNow - obsPast.priceCumulativeX128;
		uint256 twapX128 = deltaCum / actualSpan;
		return (twapX128 * 1e18) >> 128;
	}

	/// @notice Returns the global fee growth accumulator scaled by 2^128.
	/// @dev Consumers can use this alongside their liquidity share to compute realized protocol fees.
	function feeGrowthGlobalX128() external view returns (uint256) {
		return _feeGrowthGlobalX128;
	}

	/// @notice Returns the cumulative funding index per unit position size.
	/// @dev Clearinghouse snapshots this value to calculate per-trader funding payments.
	function cumulativeFundingPerUnitX18() external view returns (int256) {
		return _cumulativeFundingPerUnitX18;
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
	/// @param observationWindow_ Default TWAP lookback window in seconds.
	function setParams(
		uint16 feeBps_,
		uint256 frMaxBpsPerHour_,
		uint256 kFundingX18_,
		uint32 observationWindow_
	) external onlyOwner {
		require(feeBps_ <= 300, "Fee too high"); // Max 3% (matches MarketRegistry.MAX_FEE_BPS)
		feeBps = feeBps_;
		frMaxBpsPerHour = frMaxBpsPerHour_;
		kFundingX18 = kFundingX18_;
		observationWindow = observationWindow_;
		emit ParamsSet(feeBps, frMaxBpsPerHour, kFundingX18, observationWindow);
	}

	/// @notice Updates the cumulative funding index using the latest TWAP and oracle index prices.
	/// @dev Funding rate is clamped by frMaxBpsPerHour and accumulated into _cumulativeFundingPerUnitX18.
	/// @dev Gracefully handles oracle failures by advancing the timestamp (preventing accumulation of outage time).
	/// @dev Caps timeElapsed to 1 hour so a single update never covers more than one funding interval.
	uint256 public constant MAX_FUNDING_ELAPSED = 3600; // 1 hour cap per update

	function pokeFunding() external {
		uint64 nowTs = uint64(block.timestamp);
		uint64 lastTs = lastFundingTimestamp;
		if (nowTs <= lastTs) {
			return; // Funding already up to date
		}

		// Fetch TWAP - skip funding calc if TWAP has insufficient history
		uint256 twapX18;
		try this.getTwap(observationWindow) returns (uint256 twap) {
			twapX18 = twap;
		} catch {
			lastFundingTimestamp = nowTs; // Advance timestamp to prevent accumulation
			return;
		}

		// Safe oracle fetch - skip funding calc if oracle fails or returns zero
		uint256 indexPriceX18;
		try IOracle(oracle).getPrice() returns (uint256 price) {
			indexPriceX18 = price;
		} catch {
			lastFundingTimestamp = nowTs; // Advance timestamp to prevent accumulation
			return;
		}

		if (indexPriceX18 == 0) {
			lastFundingTimestamp = nowTs; // Advance timestamp to prevent accumulation
			return;
		}

		// Cap timeElapsed so a single update never covers more than one funding interval
		uint256 timeElapsed = nowTs - lastTs;
		if (timeElapsed > MAX_FUNDING_ELAPSED) {
			timeElapsed = MAX_FUNDING_ELAPSED;
		}

		// Calculate funding rate
		int256 premiumX18 = int256(twapX18) - int256(indexPriceX18);
		int256 fundingRateX18 = (premiumX18 * int256(kFundingX18) * int256(timeElapsed)) / (24 * 3600 * 1e18);

		// Clamp funding rate
		uint256 maxRateAbs = (frMaxBpsPerHour * timeElapsed * 1e18) / (3600 * 10000);
		if (fundingRateX18 > 0 && uint256(fundingRateX18) > maxRateAbs) {
			fundingRateX18 = int256(maxRateAbs);
		}
		if (fundingRateX18 < 0 && uint256(-fundingRateX18) > maxRateAbs) {
			fundingRateX18 = -int256(maxRateAbs);
		}

		_cumulativeFundingPerUnitX18 += fundingRateX18;
		lastFundingTimestamp = nowTs;

		emit FundingPoked(_cumulativeFundingPerUnitX18, nowTs, fundingRateX18);
	}

	/// @notice Toggles the swap execution flag, enabling or disabling all trading through the vAMM.
	/// @param paused True to pause swaps, false to resume.
	function pauseSwaps(bool paused) external onlyOwner {
		if (paused) {
			// Snapshot current price into TWAP so pause duration isn't credited later
			_accumulatePrice();
		} else {
			// Reset observation timestamp to now so the pause gap is excluded
			_obs[_obsIndex].timestamp = uint32(block.timestamp);
		}
		swapsPaused = paused;
		emit SwapsPaused(paused);
	}

	/// @notice Updates the clearinghouse contract authorized to interact with the vAMM.
	/// @param newCH Address of the replacement clearinghouse.
	function setClearinghouse(address newCH) external onlyOwner {
		require(newCH != address(0), "CH=0");
		clearinghouse = newCH;
		emit ClearinghouseChanged(newCH);
	}

	/// @notice Transfers contract ownership to a new admin address.
	/// @param newOwner Address of the new owner; must not be zero.
	function transferOwnership(address newOwner) external onlyOwner {
		require(newOwner != address(0), "owner=0");
		owner = newOwner;
		emit OwnerChanged(newOwner);
	}

	/// @notice Sets the oracle used to retrieve index prices for funding calculations.
	/// @param newOracle Address of the oracle contract; must not be zero.
	function setOracle(address newOracle) external onlyOwner {
		require(newOracle != address(0), "oracle=0");
		oracle = newOracle;
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

		// Check price change is within allowed limits to prevent instant liquidations
		uint256 currentPrice = getMarkPrice();
		uint256 priceDiff = newPriceX18 > currentPrice
			? newPriceX18 - currentPrice
			: currentPrice - newPriceX18;
		uint256 maxAllowedChange = (currentPrice * MAX_PRICE_CHANGE_BPS) / 10000;
		require(priceDiff <= maxAllowedChange, "Price change too large");

		// Calculate new quote reserve: Y = X * Price
		uint256 newQuoteReserve = Calculations.mulDiv(newBaseReserve, newPriceX18, 1e18);
		require(newQuoteReserve > 0, "quote=0");

		// Ensure new reserves meet minimum requirements
		require(newBaseReserve >= minReserveBase, "base < min");
		require(newQuoteReserve >= minReserveQuote, "quote < min");

		// Snapshot old price into TWAP before changing reserves
		_accumulatePrice();

		reserveBase = newBaseReserve;
		reserveQuote = newQuoteReserve;

		// Start new observation from the updated price
		_writeObservation();

		emit ReservesReset(newPriceX18, newBaseReserve, newQuoteReserve);
	}

	// ========= Internal: TWAP accumulation =========
	/// @dev Updates the cumulative price observation at the current index with elapsed time since the last update.
	function _accumulatePrice() internal {
		uint32 tsNow = uint32(block.timestamp);
		Observation memory last = _obs[_obsIndex];
		
		if (tsNow == last.timestamp) return;

		uint256 pxX18 = getMarkPrice();
		uint256 pxX128 = (pxX18 << 128) / 1e18;
		uint256 dt = tsNow - last.timestamp;
		
		_obs[_obsIndex].priceCumulativeX128 += pxX128 * dt;
		_obs[_obsIndex].timestamp = tsNow;
	}

	/// @dev Advances the observation ring buffer by copying the latest cumulative price into the next slot.
	function _writeObservation() internal {
		// This single call updates the latest observation.
		// The ring buffer advances by carrying this new value to the next slot.
		_accumulatePrice();
		uint16 next = (_obsIndex + 1) % OBS_CARDINALITY;
		_obs[next] = _obs[_obsIndex];
		_obsIndex = next;
	}

	/// @dev Returns the up-to-date cumulative price by simulating an accumulation at the current timestamp.
	function _peekCumulative() internal view returns (uint256 cum, uint32 tsNow) {
		tsNow = uint32(block.timestamp);
		Observation memory last = _obs[_obsIndex];
		if (last.timestamp == 0) return (0, tsNow);
		uint256 pxX18 = getMarkPrice();
		uint256 pxX128 = (pxX18 << 128) / 1e18;
		uint256 dt = tsNow - last.timestamp;
		cum = last.priceCumulativeX128 + pxX128 * dt;
	}

	// ========= Helpers =========
	/// @notice Returns the current virtual base and quote reserves used for pricing.
	function getReserves() external view returns (uint256 base, uint256 quote) {
		return (reserveBase, reserveQuote);
	}

	function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

}