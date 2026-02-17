// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICollateralVault
/// @notice Multi-collateral custodial vault for cross-margin accounts.
/// @dev Holds multiple ERC20 collaterals, exposes balances and USD valuation helpers,
///      and gates outflows to the Clearinghouse (implementation enforces roles/CH-only).
interface ICollateralVault {
    struct CollateralConfig {
        address token;            // ERC20 token address
        uint256 baseUnit;         // 10**decimals for the token
        uint16 haircutBps;        // risk haircut (bps) applied to value (e.g., 100 = 1%)
        uint16 liqIncentiveBps;   // liquidation incentive (bps) paid to liquidator
        uint256 cap;              // total token cap across all users (0 = unlimited)
        uint256 accountCap;       // per-account cap for this token (0 = unlimited)
        bool enabled;             // if false, deposits blocked and token excluded from value
        bool depositPaused;       // per-token deposit pause
        bool withdrawPaused;      // per-token withdraw pause
        string oracleSymbol;      // symbol used to query the price from the Oracle (e.g., "USDC")
    }

    // ===== Events =====
    event CollateralRegistered(
        address indexed token,
        uint256 baseUnit,
        uint16 haircutBps,
        uint16 liqIncentiveBps,
        uint256 cap,
        uint256 accountCap,
        bool enabled,
        bool depositPaused,
        bool withdrawPaused,
        string oracleSymbol
    );

    event CollateralParamsUpdated(
        address indexed token,
        uint256 baseUnit,
        uint16 haircutBps,
        uint16 liqIncentiveBps,
        uint256 cap,
        uint256 accountCap,
        bool enabled,
        bool depositPaused,
        bool withdrawPaused,
        string oracleSymbol
    );

    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amount,
        address indexed onBehalfOf,
        uint256 received
    );

    event Withdraw(
        address indexed operator,
        address indexed user,
        address indexed token,
        uint256 amount,
        address to,
        uint256 received
    );

    event Seize(
        address indexed from,
        address indexed to,
        address indexed token,
        uint256 amount
    );

    event PauseUpdated(address indexed token, bool depositsPaused, bool withdrawalsPaused);
    event OracleSet(address indexed oracle);
    event ClearinghouseSet(address indexed clearinghouse);
    event ExternalCredit(address indexed pool, address indexed user, address indexed token, uint256 amount);
    event FeeSwept(address indexed token, address indexed to, uint256 amount);
    event FeeAccumulated(address indexed token, uint256 amount);
    event PnLSettled(address indexed user, address indexed token, int256 amount);

    // ===== Admin wiring =====
    /// @notice Set the global Oracle used for valuation helpers.
    function setOracle(address oracle) external;
    function getOracle() external view returns (address);

    /// @notice Set the Clearinghouse allowed to call outflow functions.
    function setClearinghouse(address clearinghouse) external;
    function getClearinghouse() external view returns (address);

    // ===== Collateral admin =====
    function registerCollateral(CollateralConfig calldata cfg) external;
    function setCollateralParams(address token, CollateralConfig calldata cfg) external;
    function setPause(address token, bool depositsPaused, bool withdrawalsPaused) external;

    // ===== User inflow =====
    /// @notice Deposit collateral; implementation must pull tokens via transferFrom.
    /// @return received The amount accounted after fee-on-transfer adjustments.
    function deposit(address token, uint256 amount, address onBehalfOf) external returns (uint256 received);

    /// @notice Credit a user's balance after collateral has been transferred in externally (e.g., from a liquidity pool).
    function creditFromPool(address pool, address token, address user, uint256 amount) external;

    // ===== CH-gated outflows =====
    /// @notice Withdraw collateral on behalf of user to a destination address (CH only).
    /// @return received Actual amount received by destination (may be less due to transfer fees).
    function withdrawFor(address user, address token, uint256 amount, address to) external returns (uint256 received);

    /// @notice Seize collateral from a user to a recipient (e.g., liquidator) (CH only).
    function seize(address from, address to, address token, uint256 amount) external;

    /// @notice Sweep accumulated fees (CH only). Only sweeps tracked fees, not user balances.
    function sweepFees(address token, address to, uint256 amount) external;

    /// @notice Accumulate protocol fees for a token (CH only).
    function accumulateFee(address token, uint256 amount) external;

    /// @notice Get accumulated fees for a token.
    function getAccumulatedFees(address token) external view returns (uint256);

    /// @notice Settle realized PnL by crediting (profit) or debiting (loss) a user's balance (CH only).
    /// @dev No token transfer occurs. Credits are backed by other traders' debited losses.
    /// @param user Account whose balance is adjusted.
    /// @param token Collateral token for the settlement.
    /// @param amount Signed PnL in token's native decimals. Positive = profit, negative = loss.
    function settlePnL(address user, address token, int256 amount) external;

    // ===== Views =====
    function balanceOf(address user, address token) external view returns (uint256);
    function totalOf(address token) external view returns (uint256);
    function getConfig(address token) external view returns (CollateralConfig memory);

    /// @notice Valuation helpers using the configured Oracle.
    /// @dev Returns USD value scaled to 1e18.
    function getTokenValueX18(address token, uint256 amount) external view returns (uint256 usdX18);
    function getAccountCollateralValueX18(address user) external view returns (uint256 usdX18);

    function isDepositPaused(address token) external view returns (bool);
    function isWithdrawPaused(address token) external view returns (bool);
    function isEnabled(address token) external view returns (bool);
}
