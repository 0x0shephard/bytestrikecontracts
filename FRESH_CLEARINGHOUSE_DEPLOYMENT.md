# Fresh ClearingHouse Deployment Guide (Option C)

## Overview

This guide walks you through deploying a completely new ClearingHouse proxy + implementation to resolve the negative portfolio issue with a **clean slate approach**.

## Why Option C (Fresh Deployment)?

### Advantages ✅
- **Clean state**: No stale `_totalReservedMargin` mappings
- **No ghost positions**: Fresh start with new vault
- **Simple**: No need for complex migration logic or admin emergency functions
- **Best for testnet**: Perfect for Sepolia where historical data isn't critical
- **Future-proof**: Proper separation between old vault (deprecated) and new vault

### Trade-offs ⚠️
- Users must deposit collateral again (acceptable for testnet)
- Historical positions not accessible from new contract
- Frontend must update all ClearingHouse references
- Old contract remains deployed (for historical reference only)

## Current State

### Problematic Setup
```
Old ClearingHouse: 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6
├── Connected to: Old Vault (deprecated)
├── Stale storage: _totalReservedMargin = 24.7M
└── Issue: Negative portfolio values for users

New CollateralVault: 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2
└── Clean, but old ClearingHouse has stale state
```

### Target Setup
```
New ClearingHouse: <TO_BE_DEPLOYED>
├── Connected to: New Vault (clean)
├── Clean storage: _totalReservedMargin = 0 for all users
└── Result: Positive portfolio values, fresh start

New CollateralVault: 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2
└── Authorized: New ClearingHouse only
```

## Deployment Steps

### Step 1: Deploy Fresh ClearingHouse

```bash
forge script script/DeployFreshClearingHouse.s.sol:DeployFreshClearingHouse \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

**What this does:**
1. Deploys new ClearingHouse implementation (V5 with clean code)
2. Deploys new ERC1967 Proxy
3. Initializes with:
   - New CollateralVault: `0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2`
   - Existing MarketRegistry: `0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD`
4. Sets risk params for H100-PERP market
5. Verifies clean state (reserved margin = 0 for all users)

**Expected output:**
```
New ClearingHouse Proxy: 0x<NEW_PROXY_ADDRESS>
New ClearingHouse Implementation: 0x<NEW_IMPL_ADDRESS>
```

### Step 2: Authorize New ClearingHouse

```bash
NEW_CH=<NEW_PROXY_ADDRESS_FROM_STEP_1> \
forge script script/AuthorizeNewClearingHouse.s.sol:AuthorizeNewClearingHouse \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

**What this does:**
1. Calls `CollateralVault.setClearinghouse(newClearingHouse)`
2. Verifies authorization successful

### Step 3: Update Frontend

#### 3a. Regenerate ABI

```bash
# Compile contracts
forge build

# Copy new ABI to frontend
cp out/ClearingHouse.sol/ClearingHouse.json \
   bytestrike3/src/contracts/abis/ClearingHouse.json
```

#### 3b. Update Contract Addresses

Edit `bytestrike3/src/contracts/addresses.js`:

```javascript
export const SEPOLIA_CONTRACTS = {
  // Core Protocol Contracts
  clearingHouse: '<NEW_PROXY_ADDRESS>', // ⭐ NEW: Fresh ClearingHouse with clean state
  clearingHouseImpl: '<NEW_IMPL_ADDRESS>', // V5 Implementation
  clearingHouseOld: '0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6', // Deprecated (historical only)

  marketRegistry: '0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD', // Unchanged
  collateralVault: '0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2', // Unchanged

  // ... rest of contracts unchanged
};

export const IMPLEMENTATIONS = {
  clearingHouseV5Fresh: '<NEW_IMPL_ADDRESS>', // 2025-11-28 - Fresh deployment with clean state
  clearingHouseV4Old: '0x56a18F7b3348bd35512CCb6710e55344E4Bddc85', // Deprecated
  // ...
};

export const DEPLOYMENT_HISTORY = {
  'fresh-clearinghouse-2025-11-28': {
    date: '2025-11-28',
    description: 'Fresh ClearingHouse deployment to fix stale storage issues',
    proxy: '<NEW_PROXY_ADDRESS>',
    implementation: '<NEW_IMPL_ADDRESS>',
    changes: [
      'Deployed new ClearingHouse proxy with clean state',
      'Connected to new CollateralVault (0x86A10164...)',
      'No stale _totalReservedMargin mappings',
      'Fixed negative portfolio values',
      'Users must redeposit collateral to start trading',
    ],
    deprecated: {
      oldProxy: '0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6',
      reason: 'Stale storage from vault migration',
    },
  },
  // ...
};
```

#### 3c. Test Frontend

```bash
cd bytestrike3
npm run dev
```

**Verify in browser:**
1. Connect wallet with address `0xCc624fFA5df1F3F4b30aa8abd30186a86254F406`
2. Check Portfolio page:
   - Available Margin: **$0.00** ✅ (not negative!)
   - Total Collateral: **$0.00** ✅
   - Buying Power: **$0.00** ✅
3. Deposit fresh collateral (e.g., 1000 mUSDC)
4. Verify positive values appear
5. Test opening a position

### Step 4: Notify Users (If Mainnet)

For testnet, this step is optional. For mainnet:

```markdown
📢 PROTOCOL UPGRADE NOTICE

We've deployed a fresh ClearingHouse contract to resolve storage issues
from our vault migration.

ACTION REQUIRED:
1. Close all open positions (if any)
2. Withdraw collateral from old contract
3. Deposit collateral to new contract
4. Resume trading

Old ClearingHouse: 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6 (deprecated)
New ClearingHouse: <NEW_PROXY_ADDRESS> (active)

Timeline:
- [Date]: Old contract disabled in frontend
- [Date]: New contract live for trading
```

## Verification Commands

After deployment, verify everything is working:

### Check New ClearingHouse State

```bash
NEW_CH=<NEW_PROXY_ADDRESS>

# 1. Verify vault connection
cast call $NEW_CH "vault()(address)"
# Expected: 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2

# 2. Verify registry connection
cast call $NEW_CH "marketRegistry()(address)"
# Expected: 0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD

# 3. Verify clean state for test user
cast call $NEW_CH "_totalReservedMargin(address)(uint256)" \
  0xCc624fFA5df1F3F4b30aa8abd30186a86254F406
# Expected: 0

# 4. Verify account value is not negative
cast call $NEW_CH "getAccountValue(address)(int256)" \
  0xCc624fFA5df1F3F4b30aa8abd30186a86254F406
# Expected: 0 (not negative!)

# 5. Verify position is clean
cast call $NEW_CH "getPosition(address,bytes32)" \
  0xCc624fFA5df1F3F4b30aa8abd30186a86254F406 \
  0x2bc0c3f3ef82289c7da8a9335c83ea4f2b5b8bd62b67c4f4e0dba00b304c2937
# Expected: All zeros
```

### Check CollateralVault Authorization

```bash
# Verify vault points to new ClearingHouse
cast call 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2 \
  "getClearinghouse()(address)"
# Expected: <NEW_PROXY_ADDRESS>
```

### Check Market Risk Params

```bash
# Verify H100-PERP risk params
cast call $NEW_CH "marketRiskParams(bytes32)" \
  0x2bc0c3f3ef82289c7da8a9335c83ea4f2b5b8bd62b67c4f4e0dba00b304c2937
# Expected: (1000, 500, 250, 1000000000000000000000)
#   IMR: 1000 bps (10%)
#   MMR: 500 bps (5%)
#   Liquidation Penalty: 250 bps (2.5%)
#   Penalty Cap: 1000 * 1e18 ($1000)
```

## Comparison: Before vs After

### Before (Old ClearingHouse)

```
User: 0xCc624fFA5df1F3F4b30aa8abd30186a86254F406

Collateral in new vault: 0 mUSDC
Reserved margin: 24,731,180.36 (1e18) ❌ STALE
Account value: -24,731,180.36 ❌ NEGATIVE

Frontend shows:
  Available Margin: $-24,731,180.36 ❌
  Total Collateral: $-24,731,180.36 ❌
  Buying Power: $-247,311,803.58 ❌
```

### After (New ClearingHouse)

```
User: 0xCc624fFA5df1F3F4b30aa8abd30186a86254F406

Collateral in new vault: 0 mUSDC
Reserved margin: 0 ✅ CLEAN
Account value: 0 ✅ CORRECT

Frontend shows:
  Available Margin: $0.00 ✅
  Total Collateral: $0.00 ✅
  Buying Power: $0.00 ✅

After depositing 1000 mUSDC:
  Available Margin: $1,000.00 ✅
  Total Collateral: $1,000.00 ✅
  Buying Power: $10,000.00 ✅ (10x leverage)
```

## Rollback Plan (If Needed)

If issues arise, you can quickly revert frontend to old ClearingHouse:

```javascript
// In addresses.js, temporarily restore:
clearingHouse: '0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6', // Old proxy
```

Then investigate and redeploy with fixes.

## Files Created

1. **`script/DeployFreshClearingHouse.s.sol`** - Main deployment script
2. **`script/AuthorizeNewClearingHouse.s.sol`** - Authorization script
3. **`FRESH_CLEARINGHOUSE_DEPLOYMENT.md`** - This guide

## Security Considerations

- ✅ New ClearingHouse uses same audited code (just fresh storage)
- ✅ Clean state means no unexpected edge cases from stale data
- ✅ Vault isolation: old ClearingHouse can't access new vault
- ✅ No admin emergency functions needed (cleaner security model)

## Support

If you encounter issues:

1. Check deployment logs for error messages
2. Verify contract addresses in frontend match deployed contracts
3. Clear browser cache and reconnect wallet
4. Check Sepolia testnet status (https://sepolia.etherscan.io)

## Next Steps After Successful Deployment

1. ✅ Verify all verification commands pass
2. ✅ Test full user flow: deposit → open position → close → withdraw
3. ✅ Monitor for any frontend errors
4. ✅ Update documentation with new contract address
5. ✅ Announce to users (if mainnet)

## Summary

This fresh deployment approach gives you a **clean slate** without the complexity of migrating stale storage. It's the recommended approach for testnet environments where historical data preservation isn't critical.

**Estimated time:** 15-20 minutes
**Difficulty:** Medium
**Risk:** Low (testnet environment)
