// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IClearingHouse} from "./Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "./Interfaces/ICollateralVault.sol";
import {Oracle} from "./Oracle/Oracle.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


/// @title CollateralVault
/// @notice Custodial multi-collateral vault for cross-margin accounts.
/// @dev
/// - Holds ERC20 balances per user for a set of registered collateral tokens.
/// - Admins configure per-token risk params, caps, and per-token pause flags.
/// - Only Clearinghouse can move funds out (withdrawFor / seize / sweepFees).
/// - Valuation helpers call an external Oracle by symbol and apply haircuts.
contract CollateralVault is ICollateralVault, AccessControl {

    using SafeERC20 for IERC20;

    /// @notice Address of the price Oracle used for valuation helpers.
    address public oracle;
    /// @notice Clearinghouse contract allowed to execute outflows.
    address public clearinghouse;
    /// @notice Per-token configuration keyed by token address.
    mapping(address token => CollateralConfig) public collateralConfigs;
    /// @notice Per-user balances for each token held in the vault.
    mapping(address user => mapping(address token => uint256 amount)) public userBalances;
    /// @notice List of registered collateral token addresses for iteration in views.
    address[] public registeredTokens;
    /// @notice Additional admin role besides DEFAULT_ADMIN_ROLE.
    bytes32 public constant VAULT_ADMIN_ROLE = keccak256("VAULT_ADMIN_ROLE");

    /// @dev Allow DEFAULT_ADMIN_ROLE or VAULT_ADMIN_ROLE.
    modifier onlyAllowed() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(VAULT_ADMIN_ROLE, msg.sender), "CV: not allowed");
        _;  
    }

    /// @dev Restrict to the wired Clearinghouse.
    modifier onlyClearingHouse() {
        require(msg.sender == clearinghouse, "CV: not clearinghouse");
        _;
    }

    /// @notice Initializes the admin to the deployer.
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Set the global Oracle contract used for valuation.
    /// @param _oracle Oracle address implementing getPrice(symbol) returning 1e18 price.
    function setOracle(address _oracle) external onlyAllowed override {
        oracle = _oracle;
        emit OracleSet(_oracle);
    }

    /// @notice Wire the Clearinghouse that can initiate outflows.
    /// @param _clearinghouse Clearinghouse contract address.
    function setClearinghouse(address _clearinghouse) external onlyAllowed override {
        clearinghouse = _clearinghouse;
        emit ClearinghouseSet(_clearinghouse);
    }

    /// @notice Register a new collateral token with full params.
    /// @dev If the token already exists, config is updated but not re-added to array.
    /// Be mindful that changing baseUnit or oracleSymbol affects valuation.
    function registerCollateral(CollateralConfig calldata cfg) external onlyAllowed override {
        require(cfg.token != address(0), "CV: token=0");

        // Only add to array if this is a new token (prevents duplicates)
        if (collateralConfigs[cfg.token].token == address(0)) {
            registeredTokens.push(cfg.token);
        }

        collateralConfigs[cfg.token] = cfg;
        emit CollateralRegistered(
            cfg.token,
            cfg.baseUnit,
            cfg.haircutBps,
            cfg.liqIncentiveBps,
            cfg.cap,
            cfg.accountCap,
            cfg.enabled,
            cfg.depositPaused,
            cfg.withdrawPaused,
            cfg.oracleSymbol
        );
    }

    /// @notice Update an existing token's configuration.
    /// @param token Collateral token address to update.
    /// @param cfg New configuration values.
    function setCollateralParams(address token, CollateralConfig calldata cfg) external onlyAllowed override {
        collateralConfigs[token] = cfg;
        emit CollateralParamsUpdated(
            token,
            cfg.baseUnit,
            cfg.haircutBps,
            cfg.liqIncentiveBps,
            cfg.cap,
            cfg.accountCap,
            cfg.enabled,
            cfg.depositPaused,
            cfg.withdrawPaused,
            cfg.oracleSymbol
        );
    }

    /// @notice Update per-token deposit/withdraw pause flags.
    function setPause(address token, bool depositsPaused, bool withdrawalsPaused) external onlyAllowed override {
        CollateralConfig storage cfg = collateralConfigs[token];
        cfg.depositPaused = depositsPaused;
        cfg.withdrawPaused = withdrawalsPaused;
        emit PauseUpdated(token, depositsPaused, withdrawalsPaused);
    }

    /// @notice Deposit collateral into the vault for a user.
    /// @dev Uses balance delta to support fee-on-transfer tokens. Caps of 0 mean unlimited.
    /// Reverts if token disabled or deposits paused. Caller must have approved tokens.
    /// @param token ERC20 collateral token.
    /// @param amount Amount to transferFrom.
    /// @param onBehalfOf Account whose internal balance increases.
    /// @return received Actual amount credited after transfer fees, if any.
    function deposit(address token, uint256 amount, address onBehalfOf) external onlyClearingHouse override returns (uint256 received) {
        CollateralConfig memory cfg = collateralConfigs[token];
        require(cfg.enabled, "CV: token disabled");
        require(!cfg.depositPaused, "CV: deposits paused");
        require(amount > 0, "CV: amount=0");
        require(onBehalfOf != address(0), "CV: zero address");
        
        // Pull tokens and compute the exact received by checking the balance delta.
        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(onBehalfOf, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - beforeBal;
        // Enforce caps (0 means unlimited) using the credited amount.
        if (cfg.accountCap != 0) {
            require(userBalances[onBehalfOf][token] + received <= cfg.accountCap, "CV: account cap");
        }
        if (cfg.cap != 0) {
            require(IERC20(token).balanceOf(address(this)) <= cfg.cap, "CV: token cap");
        }
        userBalances[onBehalfOf][token] += received;
        emit Deposit(msg.sender, token, amount, onBehalfOf, received);
        return received;

    }

    /// @notice Withdraw collateral on behalf of a user to a destination address. CH only.
    /// @dev Uses balance delta to support fee-on-transfer tokens. Returns actual amount received.
    /// @param user Account whose balance is decreased.
    /// @param token ERC20 token to withdraw.
    /// @param amount Amount to withdraw from user's balance.
    /// @param to Destination address receiving the tokens.
    /// @return received Actual amount received by destination (may be less due to transfer fees).
    function withdrawFor(address user, address token, uint256 amount, address to) external onlyClearingHouse override returns (uint256 received) {
        require(!collateralConfigs[token].withdrawPaused, "CV: withdrawals paused");
        require(amount > 0, "CV: amount=0");
        require(user != address(0), "CV: zero address");
        require(to != address(0), "CV: to zero address");
        require(userBalances[user][token] >= amount, "CV: insufficient balance");

        userBalances[user][token] -= amount;

        // Use balance delta for fee-on-transfer support
        uint256 balanceBefore = IERC20(token).balanceOf(to);
        IERC20(token).safeTransfer(to, amount);
        received = IERC20(token).balanceOf(to) - balanceBefore;

        emit Withdraw(msg.sender, user, token, amount, to, received);
    }

    /// @notice Move collateral internally between users (e.g., liquidation). CH only.
    function seize(address from, address to, address token, uint256 amount) external onlyClearingHouse override {
        require(amount > 0, "CV: amount=0");
        require(from != address(0) && to != address(0), "CV: zero address");
        require(userBalances[from][token] >= amount, "CV: insufficient balance");
        userBalances[from][token] -= amount;
        userBalances[to][token] += amount;
        emit Seize(from, to, token, amount);
    }

    /// @notice Settle realized PnL by adjusting a user's internal balance.
    /// @dev Positive amount credits (profit), negative debits (loss). No token transfer occurs.
    /// Credits are backed by debits from other traders' losses, maintaining vault solvency.
    /// @param user Account whose balance is adjusted.
    /// @param token Collateral token for the settlement.
    /// @param amount Signed PnL in token's native decimals. Positive = profit, negative = loss.
    function settlePnL(address user, address token, int256 amount) external onlyClearingHouse override {
        require(user != address(0), "CV: zero address");
        if (amount > 0) {
            userBalances[user][token] += uint256(amount);
        } else if (amount < 0) {
            uint256 debit = uint256(-amount);
            require(userBalances[user][token] >= debit, "CV: insufficient balance");
            userBalances[user][token] -= debit;
        }
        emit PnLSettled(user, token, amount);
    }

    /////////////////////////////////////////////
    //////////External View Functions////////////
    /////////////////////////////////////////////
    /// @inheritdoc ICollateralVault
    function getOracle() external view override returns (address) {
        return oracle;
    }

    /// @inheritdoc ICollateralVault
    function getClearinghouse() external view override returns (address) {
        return clearinghouse;
    }

    /// @notice Get user's internal balance for a token.
    function balanceOf(address user, address token) external view override returns (uint256) {
        return userBalances[user][token];
    }

    /// @notice Total contract balance of a token (sum of all users and any fees).
    function totalOf(address token) external view override returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Value a token amount in USD 1e18 using oracleSymbol and baseUnit, applying haircut.
    /// @dev Returns 0 if oracle call fails to prevent blocking critical operations.
    function getTokenValueX18(address token, uint256 amount) external view override returns (uint256 usdX18) {
        CollateralConfig memory cfg = collateralConfigs[token];
        if (!cfg.enabled || amount == 0) return 0;

        // Safe oracle call - return 0 if oracle fails to prevent blocking operations
        uint256 pxX18;
        try Oracle(oracle).getPrice(cfg.oracleSymbol) returns (uint256 price) {
            pxX18 = price;
        } catch {
            return 0; // Oracle failed - treat as valueless rather than reverting
        }

        if (pxX18 == 0) return 0;

        // Normalize by base unit and apply haircut
        usdX18 = (pxX18 * amount) / cfg.baseUnit;
        if (cfg.haircutBps != 0) {
            usdX18 = (usdX18 * (10_000 - cfg.haircutBps)) / 10_000;
        }
    }

    /// @notice Sum haircut-adjusted USD value across all enabled collaterals for a user.
    /// @dev Skips tokens whose oracle fails to prevent blocking critical operations.
    function getAccountCollateralValueX18(address user) external view override returns (uint256 usdX18) {
        address[] memory tokens = registeredTokens;
        for (uint256 i = 0; i < tokens.length; i++) {
            CollateralConfig memory cfg = collateralConfigs[tokens[i]];
            if (!cfg.enabled) continue;
            uint256 bal = userBalances[user][tokens[i]];
            if (bal == 0) continue;

            // Safe oracle call - skip token if oracle fails to prevent blocking operations
            uint256 pxX18;
            try Oracle(oracle).getPrice(cfg.oracleSymbol) returns (uint256 price) {
                pxX18 = price;
            } catch {
                continue; // Skip this token if oracle fails
            }

            if (pxX18 == 0) continue;

            uint256 v = (pxX18 * bal) / cfg.baseUnit;
            if (cfg.haircutBps != 0) {
                v = (v * (10_000 - cfg.haircutBps)) / 10_000;
            }
            usdX18 += v;
        }
        return usdX18;
    }

    /// @notice Whether deposits are paused for a token.
    function isDepositPaused(address token) external view override returns (bool) {
        return collateralConfigs[token].depositPaused;
    }

    /// @notice Whether withdrawals are paused for a token.
    function isWithdrawPaused(address token) external view override returns (bool) {
        return collateralConfigs[token].withdrawPaused;
    }

    /// @notice Whether the token is enabled for valuation and deposits.
    function isEnabled(address token) external view override returns (bool) {
        return collateralConfigs[token].enabled;
    }

    /// @notice Read the full configuration for a token.
    function getConfig(address token) external view override returns (CollateralConfig memory) {
        return collateralConfigs[token];
    }

}