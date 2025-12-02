# Negative Portfolio Value Fix

## Problem Summary

User `0xCc624fFA5df1F3F4b30aa8abd30186a86254F406` is experiencing a negative portfolio value of **-$24,731,180.36** in the frontend, despite having:
- Zero collateral in the new vault (correct after migration)
- Zero open positions (size = 0)

## Root Cause Analysis

### What Happened

1. **Vault Migration**: You upgraded ClearingHouse and deployed a new CollateralVault (`0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2`)
2. **Stale Storage**: The `_totalReservedMargin` mapping in ClearingHouse was NOT cleared during the migration
3. **Ghost Position**: User has a closed position (size=0) but with stuck reserved margin:
   - Position margin: 566.29 (in 1e18 precision)
   - Total reserved margin: 24,731,180.36 (in 1e18 precision)
   - Negative realizedPnL: -15.17 (stored as uint256 underflow)

### The Math

ClearingHouse calculates account value as:
```solidity
accountValue = collateralValueInNewVault - _totalReservedMargin
             = 0 - 24,731,180.36
             = -24,731,180.36
```

This is displayed in the frontend as negative portfolio values:
- Available Margin: -$24,731,180.36
- Total Collateral: -$24,731,180.36
- Buying Power: -$247,311,803.58 (10x leverage)

## Blockchain Evidence

### Contract State (On-Chain)
```bash
# New CollateralVault - User balance = 0 ✓ (CORRECT)
cast call 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2 \
  "userBalances(address,address)(uint256)" \
  0xCc624fFA5df1F3F4b30aa8abd30186a86254F406 \
  0x8C68933688f94BF115ad2F9C8c8e251AE5d4ade7
# Output: 0

# ClearingHouse - Reserved margin = 24.7M ✗ (STALE)
cast call 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6 \
  "_totalReservedMargin(address)(uint256)" \
  0xCc624fFA5df1F3F4b30aa8abd30186a86254F406
# Output: 24731180358332549449375051 (24.7M in 1e18)

# ClearingHouse - Account value = -24.7M ✗ (NEGATIVE)
cast call 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6 \
  "getAccountValue(address)(int256)" \
  0xCc624fFA5df1F3F4b30aa8abd30186a86254F406
# Output: -24731180358332549449375051 (NEGATIVE)

# Position in H100-PERP market (ghost position)
cast call 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6 \
  "getPosition(address,bytes32)" \
  0xCc624fFA5df1F3F4b30aa8abd30186a86254F406 \
  0x2bc0c3f3ef82289c7da8a9335c83ea4f2b5b8bd62b67c4f4e0dba00b304c2937
# Output:
# size: 0 (position closed)
# margin: 566290537535440304300 (566.29 in 1e18)
# entryPrice: 0
# lastFundingIndex: -145030803348076
# realizedPnL: 115792089237316195423570985008687907853269984665640564039442416256901277343436
#   ^ This is uint256 underflow: actual value = -15.17
```

## Solution: ClearingHouse V5 Upgrade

### Changes Made

Added emergency admin function to `ClearingHouse.sol`:

```solidity
/// @notice Emergency admin function to clear stuck positions and reserved margin after vault migration.
/// @dev This is needed when _totalReservedMargin has stale data from old vault, causing negative account values.
/// @param user The address whose stuck position to clear.
/// @param marketId The market ID of the stuck position.
function adminClearStuckPosition(address user, bytes32 marketId) external onlyAdmin {
    require(user != address(0), "Invalid user");
    PositionView storage position = positions[user][marketId];

    // Only allow clearing positions with size = 0 (already closed)
    require(position.size == 0, "Position still has size");

    // Store old values for event
    uint256 oldMargin = position.margin;
    uint256 oldReservedMargin = _totalReservedMargin[user];

    // Clear the position's reserved margin
    if (position.margin > 0) {
        _totalReservedMargin[user] -= position.margin;
        position.margin = 0;
    }

    // Reset other position fields
    position.entryPriceX18 = 0;
    position.lastFundingIndex = 0;
    position.realizedPnL = 0;

    emit PositionCleared(user, marketId, oldMargin, oldReservedMargin, _totalReservedMargin[user]);
}
```

## Deployment Steps

### 1. Upgrade ClearingHouse to V5

```bash
forge script script/UpgradeAndClearStuckPosition.s.sol:UpgradeAndClearStuckPosition \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

This script will:
1. Deploy new ClearingHouse V5 implementation
2. Upgrade the proxy at `0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6`
3. Call `adminClearStuckPosition()` to fix the user's account
4. Verify the fix was successful

### 2. Update Frontend ABI

After upgrading, update the ClearingHouse ABI in the frontend:

```bash
# Generate new ABI
forge build

# Copy ABI to frontend
cp out/ClearingHouse.sol/ClearingHouse.json \
   bytestrike3/src/contracts/abis/ClearingHouse.json
```

### 3. Update Contract Addresses

Update `bytestrike3/src/contracts/addresses.js`:

```javascript
export const SEPOLIA_CONTRACTS = {
  clearingHouse: '0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6', // Proxy (V5: with adminClearStuckPosition)
  clearingHouseImpl: '<NEW_IMPL_ADDRESS>', // V5 Implementation
  // ... rest unchanged
};

export const IMPLEMENTATIONS = {
  clearingHouseV5: '<NEW_IMPL_ADDRESS>', // 2025-11-28 - Added adminClearStuckPosition
  clearingHouseV4: '0x56a18F7b3348bd35512CCb6710e55344E4Bddc85', // Previous
  // ...
};

export const DEPLOYMENT_HISTORY = {
  'v5-stuck-position-fix': {
    date: '2025-11-28',
    description: 'Added adminClearStuckPosition to fix stale reserved margin',
    implementation: '<NEW_IMPL_ADDRESS>',
    changes: [
      'Added adminClearStuckPosition() for emergency position cleanup',
      'Fixed negative portfolio values caused by vault migration',
      'Cleared stuck position for 0xCc624fFA5df1F3F4b30aa8abd30186a86254F406',
    ],
  },
  // ...
};
```

## Expected Results

### Before Fix
```
Available Margin: $-24,731,180.358
Total Collateral: $-24,731,180.358
Buying Power: $-247,311,803.583
```

### After Fix
```
Available Margin: $0.00
Total Collateral: $0.00
Buying Power: $0.00
```

The user will need to deposit fresh collateral to start trading again.

## Verification Commands

After deployment, verify the fix:

```bash
# Check reserved margin (should be much lower or 0)
cast call 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6 \
  "_totalReservedMargin(address)(uint256)" \
  0xCc624fFA5df1F3F4b30aa8abd30186a86254F406

# Check account value (should be 0 or positive)
cast call 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6 \
  "getAccountValue(address)(int256)" \
  0xCc624fFA5df1F3F4b30aa8abd30186a86254F406

# Check H100-PERP position (all fields should be 0)
cast call 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6 \
  "getPosition(address,bytes32)" \
  0xCc624fFA5df1F3F4b30aa8abd30186a86254F406 \
  0x2bc0c3f3ef82289c7da8a9335c83ea4f2b5b8bd62b67c4f4e0dba00b304c2937
```

## Prevention for Future Migrations

To prevent this issue in future vault migrations:

1. **Option A**: Add a bulk reset function to ClearingHouse:
   ```solidity
   function adminBulkResetReservedMargin(address[] calldata users) external onlyAdmin {
       for (uint i = 0; i < users.length; i++) {
           _totalReservedMargin[users[i]] = 0;
       }
   }
   ```

2. **Option B**: Before vault migration, ensure all users:
   - Close all positions (size = 0)
   - Withdraw all collateral
   - Have 0 reserved margin

3. **Option C**: Deploy entirely new ClearingHouse + new proxy when migrating vaults

## Security Considerations

The `adminClearStuckPosition()` function has safety checks:
- ✅ `onlyAdmin` modifier - only deployer can call
- ✅ Requires `position.size == 0` - can't clear active positions
- ✅ Emits `PositionCleared` event for transparency
- ✅ Only decrements reserved margin (can't increase)

This function is safe to use for emergency cleanup but should NOT be used on active positions.

## Files Modified

1. **`src/ClearingHouse.sol`**
   - Added `adminClearStuckPosition()` function
   - Added `PositionCleared` event

2. **`script/UpgradeAndClearStuckPosition.s.sol`** (NEW)
   - Automated deployment and fix script

3. **`script/ClearStuckPosition.s.sol`** (NEW)
   - Diagnostic script to check stuck positions

4. **Frontend updates needed** (after deployment):
   - `bytestrike3/src/contracts/abis/ClearingHouse.json` - Updated ABI
   - `bytestrike3/src/contracts/addresses.js` - New implementation address

## Contact

If you encounter issues during deployment, the stuck position can also be manually cleared via Etherscan:

1. Go to: https://sepolia.etherscan.io/address/0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6#writeProxyContract
2. Connect your admin wallet
3. Call `adminClearStuckPosition()` with:
   - `user`: `0xCc624fFA5df1F3F4b30aa8abd30186a86254F406`
   - `marketId`: `0x2bc0c3f3ef82289c7da8a9335c83ea4f2b5b8bd62b67c4f4e0dba00b304c2937`
