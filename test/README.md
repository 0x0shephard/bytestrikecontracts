# ByteStrike Test Suite

Comprehensive testing suite for the ByteStrike perpetual vAMM protocol.

## Test Structure

### BaseTest.sol
Base contract that all tests inherit from. Provides:
- Complete protocol deployment setup
- Common helper functions
- Test account management
- Assertion utilities

**Key Features:**
- Automatic deployment of all contracts
- Pre-configured test accounts (alice, bob, liquidator)
- Helper functions for common operations
- Logging utilities for debugging

### Test Files

#### 1. PositionTest.t.sol
Tests for opening and closing positions.

**Coverage:**
- ✅ Opening long positions
- ✅ Opening short positions
- ✅ Closing positions (full and partial)
- ✅ Position profit/loss scenarios
- ✅ Price limits and slippage protection
- ✅ Margin management (add/remove)
- ✅ Multiple users trading
- ✅ Position flipping (long to short)
- ✅ Price impact from large trades
- ✅ Edge cases (tiny positions, etc.)

#### 2. FundingTest.t.sol
Tests for the funding rate mechanism.

**Coverage:**
- ✅ Funding accrual over time
- ✅ Funding payments (long vs short)
- ✅ Funding rate adjustments
- ✅ Funding rate clamping (max per hour)
- ✅ Multiple funding settlements
- ✅ Funding with price changes
- ✅ Mark-index price convergence
- ✅ Funding index tracking

#### 3. LiquidationTest.t.sol
Tests for liquidation mechanisms.

**Coverage:**
- ✅ Liquidation when price moves against position
- ✅ Partial liquidations
- ✅ Liquidation penalties
- ✅ Liquidator incentives
- ✅ Insurance fund interactions
- ✅ Liquidation prevention (add margin)
- ✅ Whitelisted liquidators only
- ✅ Bad debt scenarios
- ✅ Gas usage
- ✅ Edge cases

## Running Tests

### Run All Tests
```bash
forge test
```

### Run Specific Test File
```bash
forge test --match-path test/PositionTest.t.sol
forge test --match-path test/FundingTest.t.sol
forge test --match-path test/LiquidationTest.t.sol
```

### Run Specific Test Function
```bash
forge test --match-test test_OpenLongPosition
forge test --match-test test_Liquidation
```

### Run with Verbosity
```bash
# Show test names
forge test -vv

# Show test names and logs
forge test -vvv

# Show test names, logs, and traces
forge test -vvvv

# Show everything including setup traces
forge test -vvvvv
```

### Run with Gas Report
```bash
forge test --gas-report
```

### Run with Coverage
```bash
forge coverage
```

## Test Configuration

### Default Parameters
```solidity
// Market
INITIAL_ETH_PRICE = $2000
INITIAL_BASE_RESERVE = 1000 ETH
TRADE_FEE_BPS = 10 (0.1%)

// Risk Parameters
IMR_BPS = 500 (5%)
MMR_BPS = 250 (2.5%)
LIQUIDATION_PENALTY_BPS = 200 (2%)
PENALTY_CAP = 10,000 USDC

// Funding
FUNDING_MAX_BPS_PER_HOUR = 100 (1%)
FUNDING_K = 1e18
OBSERVATION_WINDOW = 1 hour
```

### Test Accounts
- `admin` - Protocol administrator
- `treasury` - Fee recipient
- `alice` - Primary test user
- `bob` - Secondary test user
- `liquidator` - Whitelisted liquidator

## Helper Functions Reference

### Account Management
```solidity
fundUser(address user, uint256 amount)
fundAndDeposit(address user, uint256 amount)
```

### Trading
```solidity
openLongPosition(address user, uint128 size, uint256 priceLimit)
openShortPosition(address user, uint128 size, uint256 priceLimit)
closePosition(address user, uint128 size, uint256 priceLimit)
```

### Oracle
```solidity
setOraclePrice(uint256 newPrice)
getMarkPrice() → uint256
```

### Position Info
```solidity
getPosition(address user) → PositionView
getMargin(address user) → uint256
getNotional(address user) → uint256
getMarginRatio(address user) → uint256
isLiquidatable(address user) → bool
```

### Calculations
```solidity
calculateInitialMargin(uint256 notional) → uint256
calculateMaintenanceMargin(uint256 notional) → uint256
```

### Time Manipulation
```solidity
skipTime(uint256 seconds_)
skipBlocks(uint256 blocks_)
```

### Assertions
```solidity
assertPositionSize(address user, int256 expectedSize)
assertApproxEqRelPosition(address user, int256 expectedSize, uint256 maxPercentDelta)
```

### Debugging
```solidity
logPosition(address user, string memory label)
```

## Writing New Tests

### Template
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseTest} from "./BaseTest.sol";

contract MyTest is BaseTest {

    function setUp() public override {
        super.setUp();
        // Additional setup if needed
    }

    function test_MyFeature() public {
        // 1. Setup
        fundAndDeposit(alice, 10000 * USDC_UNIT);

        // 2. Execute
        openLongPosition(alice, 1 * ETH_UNIT, 0);

        // 3. Assert
        assertPositionSize(alice, int256(1 * ETH_UNIT));
    }
}
```

### Best Practices

1. **Use Descriptive Names**
   - `test_OpenLongPosition_WithPriceLimit`
   - `testFail_Liquidation_NotWhitelisted`

2. **Test One Thing**
   - Each test should verify one specific behavior

3. **Use Helper Functions**
   - Leverage BaseTest helpers for cleaner tests

4. **Test Edge Cases**
   - Zero amounts
   - Maximum values
   - Boundary conditions

5. **Test Failure Modes**
   - Use `testFail_` prefix for expected reverts
   - Use `vm.expectRevert()` for specific error messages

6. **Add Comments**
   - Explain complex test scenarios
   - Document expected outcomes

## Common Test Patterns

### Setup → Execute → Assert
```solidity
function test_Example() public {
    // Setup
    fundAndDeposit(alice, 10000 * USDC_UNIT);

    // Execute
    openLongPosition(alice, 1 * ETH_UNIT, 0);

    // Assert
    assertEq(getPosition(alice).size, int256(1 * ETH_UNIT));
}
```

### Price Movement Tests
```solidity
function test_ProfitOnPriceIncrease() public {
    fundAndDeposit(alice, 10000 * USDC_UNIT);
    openLongPosition(alice, 1 * ETH_UNIT, 0);

    // Price goes up
    setOraclePrice(2200 * PRICE_PRECISION);

    closePosition(alice, 1 * ETH_UNIT, 0);

    assertTrue(getPosition(alice).realizedPnL > 0);
}
```

### Multi-User Tests
```solidity
function test_TwoUsersOppositePositions() public {
    fundAndDeposit(alice, 10000 * USDC_UNIT);
    fundAndDeposit(bob, 10000 * USDC_UNIT);

    openLongPosition(alice, 1 * ETH_UNIT, 0);
    openShortPosition(bob, 1 * ETH_UNIT, 0);

    // Verify opposite positions
    assertEq(getPosition(alice).size, -getPosition(bob).size);
}
```

### Time-Based Tests
```solidity
function test_FundingOverTime() public {
    fundAndDeposit(alice, 10000 * USDC_UNIT);
    openLongPosition(alice, 1 * ETH_UNIT, 0);

    uint256 marginBefore = getMargin(alice);

    skipTime(1 hours);
    settleFunding(alice);

    uint256 marginAfter = getMargin(alice);
    // Assert funding affected margin
}
```

## Debugging Failed Tests

### View Logs
```bash
forge test --match-test test_MyFailingTest -vvvv
```

### Use Console Logging
```solidity
import {console} from "forge-std/Test.sol";

console.log("Position size:", getPosition(alice).size);
console.log("Mark price:", getMarkPrice());
```

### Use logPosition Helper
```solidity
logPosition(alice, "After opening long");
```

### Check State
```solidity
logPosition(alice, "Before");
// ... do something ...
logPosition(alice, "After");
```

## Coverage Goals

Target coverage:
- [ ] Lines: > 90%
- [ ] Branches: > 85%
- [ ] Functions: > 95%

Run coverage:
```bash
forge coverage --report summary
forge coverage --report lcov
```

## CI/CD Integration

Tests run automatically on:
- Pull requests
- Pushes to main
- Nightly builds

### GitHub Actions Example
```yaml
- name: Run tests
  run: forge test --gas-report
```

## Known Issues

1. **Funding rate precision** - Some funding tests may have small rounding differences
2. **Gas estimates** - Gas usage may vary slightly between runs
3. **Time-dependent tests** - Use `vm.warp()` instead of actual delays

## Contributing

When adding new features:
1. Write tests first (TDD approach)
2. Ensure all existing tests pass
3. Add tests for edge cases
4. Update this README if needed

## Support

For test issues:
- Check test output with `-vvvv`
- Use `logPosition()` for debugging
- Review BaseTest.sol for available helpers
- Check forge documentation: https://book.getfoundry.sh/
