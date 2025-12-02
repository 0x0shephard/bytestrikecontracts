# Fix Negative Portfolio - Quick Start Guide

## Problem
User `0xCc624fFA5df1F3F4b30aa8abd30186a86254F406` shows **-$24,731,180.36** in portfolio due to stale storage from vault migration.

## Root Cause
- Old ClearingHouse has `_totalReservedMargin = 24.7M` (stale from old vault)
- New CollateralVault has `userBalance = 0` (correct)
- Formula: `accountValue = 0 - 24.7M = -24.7M` ❌

## Recommended Solution: Option C (Fresh Deployment)

Deploy a brand new ClearingHouse with clean state. **This is the cleanest approach for testnet.**

### Why Option C?
✅ Clean slate - no stale storage
✅ Simple - no complex migration
✅ Best for testnet - users can redeposit
✅ Future-proof - proper vault separation

## Quick Deployment (5 minutes)

### 1. Deploy Fresh ClearingHouse
```bash
forge script script/DeployFreshClearingHouse.s.sol:DeployFreshClearingHouse \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

**Save these addresses from output:**
- New ClearingHouse Proxy: `0x...`
- New ClearingHouse Implementation: `0x...`

### 2. Authorize New ClearingHouse
```bash
NEW_CH=<PASTE_PROXY_ADDRESS_HERE> \
forge script script/AuthorizeNewClearingHouse.s.sol:AuthorizeNewClearingHouse \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

### 3. Update Frontend

#### Generate new ABI:
```bash
forge build
cp out/ClearingHouse.sol/ClearingHouse.json \
   bytestrike3/src/contracts/abis/ClearingHouse.json
```

#### Update addresses in `bytestrike3/src/contracts/addresses.js`:
```javascript
export const SEPOLIA_CONTRACTS = {
  clearingHouse: '<PASTE_NEW_PROXY_ADDRESS>', // ⭐ UPDATE THIS
  clearingHouseImpl: '<PASTE_NEW_IMPL_ADDRESS>', // ⭐ UPDATE THIS
  clearingHouseOld: '0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6', // Deprecated

  // Keep these unchanged:
  marketRegistry: '0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD',
  collateralVault: '0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2',
  // ...
};
```

### 4. Test Frontend
```bash
cd bytestrike3
npm run dev
```

**Verify:**
1. Connect wallet `0xCc624fFA5df1F3F4b30aa8abd30186a86254F406`
2. Check Portfolio page shows:
   - Available Margin: **$0.00** ✅ (not negative!)
   - Total Collateral: **$0.00** ✅
   - Buying Power: **$0.00** ✅

3. Test flow:
   - Deposit 1000 mUSDC
   - Verify shows **$1,000** collateral
   - Open a position
   - Close position
   - Withdraw

## Verification Commands

After deployment, run these to verify:

```bash
NEW_CH=<YOUR_NEW_PROXY_ADDRESS>

# Should return 0 (not negative!)
cast call $NEW_CH "getAccountValue(address)(int256)" \
  0xCc624fFA5df1F3F4b30aa8abd30186a86254F406

# Should return 0 (clean state)
cast call $NEW_CH "_totalReservedMargin(address)(uint256)" \
  0xCc624fFA5df1F3F4b30aa8abd30186a86254F406

# Should return new vault address
cast call $NEW_CH "vault()(address)"
# Expected: 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2
```

## Expected Results

### Before (Old ClearingHouse)
```
Portfolio:
  Available Margin: $-24,731,180.36 ❌
  Total Collateral: $-24,731,180.36 ❌
  Buying Power: $-247,311,803.58 ❌
```

### After (New ClearingHouse)
```
Portfolio (before deposit):
  Available Margin: $0.00 ✅
  Total Collateral: $0.00 ✅
  Buying Power: $0.00 ✅

Portfolio (after depositing 1000 mUSDC):
  Available Margin: $1,000.00 ✅
  Total Collateral: $1,000.00 ✅
  Buying Power: $10,000.00 ✅
```

## Files Reference

- **`FRESH_CLEARINGHOUSE_DEPLOYMENT.md`** - Detailed deployment guide
- **`NEGATIVE_PORTFOLIO_FIX.md`** - Technical root cause analysis
- **`script/DeployFreshClearingHouse.s.sol`** - Deployment script
- **`script/AuthorizeNewClearingHouse.s.sol`** - Authorization script
- **`src/ClearingHouse.sol`** - Updated contract (added `adminClearStuckPosition` for Option B)

## Alternative: Option B (Upgrade Existing)

If you prefer to upgrade the existing ClearingHouse instead of deploying fresh:

1. Use `script/_optionB_UpgradeAndClearStuckPosition.s.sol.bak` (needs fixing)
2. Upgrades existing proxy to V5 with `adminClearStuckPosition()` function
3. Clears stuck position without deploying new proxy

**Note:** Option B is more complex. Option C (fresh deployment) is recommended for testnet.

## Troubleshooting

### "Transaction reverted" during authorization
- Verify you're using the admin wallet that deployed the contracts
- Check the private key in `.env` matches the deployer

### Frontend still shows negative values
- Clear browser cache
- Disconnect and reconnect wallet
- Verify `addresses.js` has the correct new proxy address
- Check browser console for errors

### Can't deposit collateral
- Verify CollateralVault.setClearinghouse() was called successfully
- Check vault authorization: `cast call 0x86A10164eB8F55EA6765185aFcbF5e073b249Dd2 "getClearinghouse()"`
- Should return new ClearingHouse address

## Support

For issues, check:
1. Deployment logs for error messages
2. Sepolia testnet status: https://sepolia.etherscan.io
3. Contract verification on Etherscan

## Summary

**Time:** 5-10 minutes
**Difficulty:** Easy (just run scripts and update frontend)
**Risk:** Low (testnet, clean approach)
**Result:** Portfolio values fixed, users can trade normally

---

**Ready to deploy? Start with Step 1 above! 🚀**
