// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IClearingHouse Interface
/// @notice Margin, PnL, funding, fee routing, and liquidation orchestration for perpetual vAMM markets only.
interface IClearingHouse {
    struct PositionView {
        int256 size;
        uint256 margin;
        uint256 entryPriceX18;
        uint256 lastFundingPayIndex;
        uint256 lastFundingReceiveIndex;
        int256 realizedPnL;
    }

    struct MarketRiskParams {
        uint256 imrBps; // initial margin requirement bps
        uint256 mmrBps; // maintenance margin requirement bps
        uint256 liquidationPenaltyBps;
        uint256 penaltyCap; // absolute cap in quote units (1e18)
        uint256 maxPositionSize; // max position size per user in base units (0 = unlimited)
        uint256 minPositionSize; // min position size in base units (0 = no minimum)
    }

    // ===== Events =====
    event MarginAdded(address indexed user, bytes32 indexed marketId, uint256 amount);
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount, uint256 received);
    event MarginRemoved(address indexed user, bytes32 indexed marketId, uint256 amount);
    event RiskParamsSet(
        bytes32 indexed marketId,
        uint256 imrBps,
        uint256 mmrBps,
        uint256 liquidationPenaltyBps,
        uint256 penaltyCap,
        uint256 maxPositionSize,
        uint256 minPositionSize
    );
    event FundingSettled(bytes32 indexed marketId, address indexed account, int256 fundingPayment);
    event MarketPaused(bytes32 indexed marketId, bool isPaused);
    event LiquidatorWhitelistUpdated(address indexed liquidator, bool isWhitelisted);
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event LegacyVaultWithdrawal(address indexed user, address indexed legacyVault, address indexed token, uint256 amount, uint256 received);
    event LiquidationExecuted(
        bytes32 indexed marketId,
        address indexed liquidator,
        address indexed account,
        uint128 size,
        uint256 notional,
        uint256 penalty,
        uint256 liquidatorReward,
        uint256 protocolFee,
        uint256 insurancePayout
    );
    event PositionOpened(
        address indexed user,
        bytes32 indexed marketId,
        bool isLong,
        uint128 size,
        uint256 entryPrice,
        uint256 margin
    );
    event PositionClosed(
        address indexed user,
        bytes32 indexed marketId,
        uint128 size,
        uint256 exitPrice,
        int256 realizedPnL
    );
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
    event BadDebtRecorded(
        address indexed account,
        bytes32 indexed marketId,
        uint256 shortfall
    );
    event PositionCleared(
        address indexed user,
        bytes32 indexed marketId,
        uint256 clearedMargin,
        uint256 oldReservedMargin,
        uint256 newReservedMargin
    );

    /// @notice Deposit collateral into the vault.
    function deposit(address token, uint256 amount) external;

    /// @notice Withdraw collateral from the vault.
    function withdraw(address token, uint256 amount) external;

    /// @notice Add margin to a specific position.
    function addMargin(bytes32 marketId, uint256 amount) external;

    /// @notice Remove margin from a specific position.
    function removeMargin(bytes32 marketId, uint256 amount) external;

    /// @notice Open or increase a position.
    /// @param marketId Bytes32 key (e.g., keccak256("H100-PERP"))
    /// @param isLong True for long (buy base), false for short (sell base)
    /// @param size Base units (1e18) to add in absolute value
    /// @param amountLimit For longs (buying base): max quote to spend. For shorts (selling base): min quote to receive. 0 = no limit.
    function openPosition(bytes32 marketId, bool isLong, uint128 size, uint256 amountLimit) external;

    /// @notice Close or reduce a position size in base units.
    /// @param amountLimit For closing longs (selling base): min quote to receive. For closing shorts (buying base): max quote to spend. 0 = no limit.
    function closePosition(bytes32 marketId, uint128 size, uint256 amountLimit) external;

    /// @notice Liquidate a portion or full position if below maintenance margin.
    /// @param amountLimit For closing longs (selling base): min quote to receive. For closing shorts (buying base): max quote to spend. 0 = no limit.
    function liquidate(address account, bytes32 marketId, uint128 size, uint256 amountLimit) external;

    /// @notice Settle funding up to latest index for a given account on a market.
    function settleFunding(bytes32 marketId, address account) external;

    /// @notice Set risk parameters for a market.
    function setRiskParams(
        bytes32 marketId,
        uint256 imrBps,
        uint256 mmrBps,
        uint256 liquidationPenaltyBps,
        uint256 penaltyCap,
        uint256 maxPositionSize,
        uint256 minPositionSize
    ) external;

    /// @notice Pause or unpause a market.
    function pauseMarket(bytes32 marketId, bool paused) external;

    /// @notice Check if a position is liquidatable.
    function isLiquidatable(address account, bytes32 marketId) external view returns (bool);

    /// @notice Get position details.
    function getPosition(address account, bytes32 marketId) external view returns (PositionView memory);

    /// @notice Get notional value of a position.
    function getNotional(address account, bytes32 marketId) external view returns (uint256);

    /// @notice Get margin ratio of a position.
    function getMarginRatio(address account, bytes32 marketId) external view returns (uint256);

    /// @notice Get total account value.
    function getAccountValue(address account) external view returns (int256);
}
