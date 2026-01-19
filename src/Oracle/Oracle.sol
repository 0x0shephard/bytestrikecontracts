//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

//@dev - having same stale time period for uptime and price staleness check

import {AggregatorV3Interface, AggregatorInterface} from "./interfaces/AggregatorV3Interface.sol";

// --- Errors ---
error ChainlinkOracle_NoPriceFeed();
error ChainlinkOracle_ZeroPrice();
error Oracle_InvalidAddress();
error SequencerDown();
error PriceIsStale();
error GracePeriodNotOver();
error PriceOutOfBounds();

/**
 * @title Oracle
 * @dev This contract retrieves asset prices using Chainlink Price Feeds.
 * It includes a check for L2 sequencer uptime to prevent stale prices.
 */
contract Oracle {
    address public owner;

    mapping(string => AggregatorV3Interface) public priceFeeds;
    mapping(string => uint256) public baseUnits;
    mapping(string => uint256) public priceStalePeriods;
    AggregatorV3Interface public sequencerUptimeFeed;
    uint256 public priceStalePeriod; // Maximum age of a price update

    /// @notice Grace period to wait after sequencer comes back online before trusting prices
    /// @dev Recommended by Chainlink to avoid stale prices right after sequencer restarts
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600; // 1 hour

    // --- Events ---
    event PriceFeedSet(string indexed tokenSymbol, address indexed priceFeedAddress);
    event BaseUnitSet(string indexed tokenSymbol, uint256 baseUnit);
    event SequencerUptimeFeedSet(address indexed uptimeFeedAddress);
    event PriceStalePeriodSet(uint256 newStalePeriod);
    event PriceStalePeriodSetForToken(string indexed tokenSymbol, uint256 newStalePeriod);

    constructor() {
        owner = msg.sender;
        priceStalePeriod = 3600; // Default to 1 hour
    }

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == owner, "Oracle: Caller is not the owner");
        _;
    }

    // --- Price Oracle Functions ---

    /**
     * @notice Gets the price of a token, normalized to 18 decimals.
     * @param _tokenSymbol The symbol of the token (e.g., "ETH").
     * @return The price normalized to 10**18.
     */
    function getPrice(string memory _tokenSymbol) external view returns (uint256) {
        AggregatorV3Interface priceFeed = priceFeeds[_tokenSymbol];
        if (address(priceFeed) == address(0)) revert ChainlinkOracle_NoPriceFeed();
        
        uint256 feedDecimals = priceFeed.decimals();
        (uint256 price, ) = _getLatestPrice(_tokenSymbol);

        // Normalize price to 18 decimals
        return _normalizeTo1e18(price, feedDecimals);
    }

    /**
     * @notice Gets the price of an underlying asset, normalized for its base unit.
     * @param _tokenSymbol The symbol of the token (e.g., "USDC").
     * @return The normalized price.
     */
    function getUnderlyingPrice(string memory _tokenSymbol) external view returns (uint256) {
        AggregatorV3Interface priceFeed = priceFeeds[_tokenSymbol];
        if (address(priceFeed) == address(0)) revert ChainlinkOracle_NoPriceFeed();
        
        uint256 feedDecimals = priceFeed.decimals();
        (uint256 price, ) = _getLatestPrice(_tokenSymbol);

        uint256 normalizedPrice = _normalizeTo1e18(price, feedDecimals);
        uint256 baseUnit = baseUnits[_tokenSymbol];
        require(baseUnit != 0, "Oracle: base unit not set");
        return (normalizedPrice * 1e18) / baseUnit;
    }

    // --- Owner Functions ---

    /**
     * @notice Sets the address of the price feed for a given token symbol.
     * @param _tokenSymbol The symbol of the token (e.g., "ETH").
     * @param _priceFeedAddress The address of the Chainlink price feed contract.
     */
    function setPriceFeed(string memory _tokenSymbol, address _priceFeedAddress) external onlyOwner {
        if (_priceFeedAddress == address(0)) revert Oracle_InvalidAddress();
        priceFeeds[_tokenSymbol] = AggregatorV3Interface(_priceFeedAddress);
        emit PriceFeedSet(_tokenSymbol, _priceFeedAddress);
    }

    /**
     * @notice Sets the base unit for a token, used in price calculations.
     * @dev The base unit is the token's value with its native decimals (e.g., 1e18 for ETH, 1e6 for USDC).
     * @param _tokenSymbol The symbol of the token (e.g., "ETH").
     * @param _baseUnit The base unit of the token.
     */
    function setBaseUnit(string memory _tokenSymbol, uint256 _baseUnit) external onlyOwner {
        baseUnits[_tokenSymbol] = _baseUnit;
        emit BaseUnitSet(_tokenSymbol, _baseUnit);
    }

    /**
     * @notice Sets the address for the L2 sequencer uptime feed.
     * @dev Find addresses in the Chainlink documentation. Set to address(0) to disable.
     * @param _uptimeFeedAddress The address of the uptime feed contract.
     */
    function setSequencerUptimeFeed(address _uptimeFeedAddress) external onlyOwner {
        sequencerUptimeFeed = AggregatorV3Interface(_uptimeFeedAddress);
        emit SequencerUptimeFeedSet(_uptimeFeedAddress);
    }

    /**
     * @notice Sets the maximum age for a price update to be considered valid.
     * @param _stalePeriod The new stale period in seconds.
     */
    function setPriceStalePeriod(uint256 _stalePeriod) external onlyOwner {
        priceStalePeriod = _stalePeriod;
        emit PriceStalePeriodSet(_stalePeriod);
    }

    /**
     * @notice Sets the maximum age for a price update for a specific token.
     * @param _tokenSymbol The symbol of the token (e.g., "ETH").
     * @param _stalePeriod The new stale period in seconds. Set to 0 to use the global default.
     */
    function setPriceStalePeriodForToken(string memory _tokenSymbol, uint256 _stalePeriod) external onlyOwner {
        priceStalePeriods[_tokenSymbol] = _stalePeriod;
        emit PriceStalePeriodSetForToken(_tokenSymbol, _stalePeriod);
    }

    // --- Internal Functions ---

    /**
     * @dev Internal function to get the latest price and timestamp from a Chainlink feed.
     * It includes checks for L2 sequencer status, grace period, price staleness, and price bounds.
     * @param symbol The token symbol to query.
     * @return uPrice The latest price as a uint256.
     * @return timeStamp The timestamp of the price update.
     */
    function _getLatestPrice(string memory symbol) internal view returns (uint256 uPrice, uint256 timeStamp) {
        // L2 Sequencer Uptime Check
        uint256 stalePeriod = priceStalePeriods[symbol];
        if (stalePeriod == 0) {
            stalePeriod = priceStalePeriod;
        }

        if (address(sequencerUptimeFeed) != address(0)) {
            try sequencerUptimeFeed.latestRoundData() returns (
                uint80 /*roundID*/,
                int256 answer,
                uint256 sequencerStartedAt,
                uint256 /*sequencerUpdatedAt*/,
                uint80 /*answeredInRound*/
            ) {
                // FIX #1: Corrected sequencer check
                // answer == 0: Sequencer is UP (healthy)
                // answer == 1: Sequencer is DOWN
                if (answer != 0) revert SequencerDown();

                // FIX #2: Grace period check after sequencer comes back online
                // Prices may be stale/manipulated right after sequencer restarts
                if (sequencerStartedAt == 0) revert PriceIsStale();
                uint256 timeSinceUp = block.timestamp - sequencerStartedAt;
                if (timeSinceUp <= SEQUENCER_GRACE_PERIOD) {
                    revert GracePeriodNotOver();
                }
            } catch {
                revert SequencerDown();
            }
        }

        AggregatorV3Interface priceFeed = priceFeeds[symbol];
        try priceFeed.latestRoundData() returns (
            uint80 roundID,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            if (price <= 0) revert ChainlinkOracle_ZeroPrice();
            if (startedAt == 0 || block.timestamp < startedAt) revert PriceIsStale();
            if (answeredInRound < roundID) revert PriceIsStale();
            if (block.timestamp - updatedAt > stalePeriod) revert PriceIsStale();

            // FIX #3: Check price is within Chainlink's min/max bounds
            // During flash crashes, oracle may return minAnswer even if actual price is lower
            try priceFeed.aggregator() returns (address aggregatorAddr) {
                if (aggregatorAddr != address(0)) {
                    AggregatorInterface aggregator = AggregatorInterface(aggregatorAddr);
                    int192 minAnswer = aggregator.minAnswer();
                    int192 maxAnswer = aggregator.maxAnswer();

                    if (price <= int256(int192(minAnswer)) || price >= int256(int192(maxAnswer))) {
                        revert PriceOutOfBounds();
                    }
                }
            } catch {
                // If aggregator() call fails, skip bounds check (some feeds may not support it)
            }

            uPrice = uint256(price);
            timeStamp = updatedAt;
        } catch {
            revert ChainlinkOracle_NoPriceFeed();
        }
    }

    function _normalizeTo1e18(uint256 price, uint256 feedDecimals) internal pure returns (uint256) {
        if (feedDecimals == 18) {
            return price;
        }
        if (feedDecimals < 18) {
            return price * (10**(18 - feedDecimals));
        }
        uint256 divisor = 10**(feedDecimals - 18);
        require(divisor != 0, "Oracle: invalid decimals");
        return price / divisor;
    }
}