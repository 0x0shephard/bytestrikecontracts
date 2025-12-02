#!/bin/bash
# ByteStrike Trading Test Script
# Tests the full trading flow to verify IMR bug fix

set -e  # Exit on error

# Load environment
source .env
export SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/3qoSFfQA1ZOtTO-eyMjN0a1ijwT4AdQy"

# Contract addresses
USDC="0x37D5154731eE25C83E06E1abC312075AB4B4D8fF"
COLLATERAL_VAULT="0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0"
CLEARING_HOUSE="0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6"
MARKET_ID="0xa583a10b2c0991c6f416501cbea19895d7becde9398eff1b7f60ef1120547d53"
DEPLOYER="0xCc624fFA5df1F3F4b30aa8abd30186a86254F406"

# Test parameters
DEPOSIT_AMOUNT="1000000000"  # 1,000 USDC (6 decimals)
POSITION_SIZE="10000000000000000000"  # 10 GPU hours (18 decimals)
PRICE_LIMIT="4000000000000000000"  # $4.00 price limit (18 decimals)

echo "=========================================="
echo "  BYTESTRIKE TRADING TEST"
echo "=========================================="
echo ""
echo "Testing deployment with IMR bug fix"
echo "Network: Sepolia"
echo "Deployer: $DEPLOYER"
echo ""

# Step 1: Check initial USDC balance
echo "Step 1: Checking initial USDC balance..."
INITIAL_BALANCE=$(cast call $USDC "balanceOf(address)(uint256)" $DEPLOYER --rpc-url $SEPOLIA_RPC_URL)
echo "  Initial USDC balance: $INITIAL_BALANCE ($(echo "scale=2; $INITIAL_BALANCE / 1000000" | bc) USDC)"
echo ""

# Step 2: Approve USDC for CollateralVault
echo "Step 2: Approving USDC for CollateralVault..."
cast send $USDC \
  "approve(address,uint256)" \
  $COLLATERAL_VAULT \
  $DEPOSIT_AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy \
  --json > /tmp/approve_tx.json

APPROVE_TX=$(cat /tmp/approve_tx.json | jq -r '.transactionHash')
echo "  ✅ Approval transaction: $APPROVE_TX"
echo ""

# Wait for confirmation
sleep 5

# Step 3: Check allowance
echo "Step 3: Verifying allowance..."
ALLOWANCE=$(cast call $USDC "allowance(address,address)(uint256)" $DEPLOYER $COLLATERAL_VAULT --rpc-url $SEPOLIA_RPC_URL)
echo "  Allowance: $ALLOWANCE ($(echo "scale=2; $ALLOWANCE / 1000000" | bc) USDC)"
echo ""

# Step 4: Deposit collateral
echo "Step 4: Depositing collateral to vault..."
cast send $COLLATERAL_VAULT \
  "deposit(address,uint256)" \
  $USDC \
  $DEPOSIT_AMOUNT \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy \
  --json > /tmp/deposit_tx.json

DEPOSIT_TX=$(cat /tmp/deposit_tx.json | jq -r '.transactionHash')
echo "  ✅ Deposit transaction: $DEPOSIT_TX"
echo ""

# Wait for confirmation
sleep 5

# Step 5: Check collateral balance
echo "Step 5: Checking collateral balance..."
COLLATERAL_BALANCE=$(cast call $COLLATERAL_VAULT "balances(address,address)(uint256)" $DEPLOYER $USDC --rpc-url $SEPOLIA_RPC_URL)
echo "  Collateral balance: $COLLATERAL_BALANCE ($(echo "scale=2; $COLLATERAL_BALANCE / 1000000" | bc) USDC)"
echo ""

# Step 6: Get current mark price
echo "Step 6: Getting current mark price from vAMM..."
VAMM="0x684d4C1133188845EaF9d533bef6E602C1a8b6d2"
MARK_PRICE=$(cast call $VAMM "getMarkPrice()(uint256)" --rpc-url $SEPOLIA_RPC_URL)
echo "  Mark price: $MARK_PRICE ($(echo "scale=2; $MARK_PRICE / 1000000000000000000" | bc) USD/hour)"
echo ""

# Step 7: Check risk parameters
echo "Step 7: Checking market risk parameters..."
RISK_PARAMS=$(cast call $CLEARING_HOUSE "marketRiskParams(bytes32)" $MARKET_ID --rpc-url $SEPOLIA_RPC_URL)
echo "  Risk params: $RISK_PARAMS"
echo "  (IMR, MMR, Liquidation Penalty, Penalty Cap)"
echo ""

# Step 8: Open a long position
echo "Step 8: Opening a LONG position (10 GPU hours)..."
echo "  This is the critical test for the IMR bug fix!"
echo "  Old deployment would fail with 'IMR breach after trade'"
echo ""

cast send $CLEARING_HOUSE \
  "openPosition(bytes32,bool,uint256,uint256)" \
  $MARKET_ID \
  true \
  $POSITION_SIZE \
  $PRICE_LIMIT \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy \
  --json > /tmp/open_position_tx.json

if [ $? -eq 0 ]; then
    OPEN_TX=$(cat /tmp/open_position_tx.json | jq -r '.transactionHash')
    echo "  ✅ Position opened successfully!"
    echo "  Transaction: $OPEN_TX"
    echo ""
    echo "  🎉 IMR BUG FIX VERIFIED! Position opened without error!"
else
    echo "  ❌ Position failed to open"
    cat /tmp/open_position_tx.json
    exit 1
fi

# Wait for confirmation
sleep 5

# Step 9: Check position details
echo ""
echo "Step 9: Checking position details..."
# Note: We need to decode the position struct
# For now, let's check account value
ACCOUNT_VALUE=$(cast call $CLEARING_HOUSE "getAccountValue(address)(int256)" $DEPLOYER --rpc-url $SEPOLIA_RPC_URL 2>/dev/null || echo "0")
echo "  Account value: $ACCOUNT_VALUE"
echo ""

# Step 10: Check updated collateral balance
echo "Step 10: Checking updated collateral balance..."
COLLATERAL_BALANCE_AFTER=$(cast call $COLLATERAL_VAULT "balances(address,address)(uint256)" $DEPLOYER $USDC --rpc-url $SEPOLIA_RPC_URL)
echo "  Collateral balance after trade: $COLLATERAL_BALANCE_AFTER ($(echo "scale=2; $COLLATERAL_BALANCE_AFTER / 1000000" | bc) USDC)"
echo "  Fees deducted: $(echo "scale=2; ($COLLATERAL_BALANCE - $COLLATERAL_BALANCE_AFTER) / 1000000" | bc) USDC"
echo ""

# Step 11: Close the position
echo "Step 11: Closing the position..."
cast send $CLEARING_HOUSE \
  "closePosition(bytes32,uint256,uint256)" \
  $MARKET_ID \
  $POSITION_SIZE \
  "3000000000000000000" \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy \
  --json > /tmp/close_position_tx.json

if [ $? -eq 0 ]; then
    CLOSE_TX=$(cat /tmp/close_position_tx.json | jq -r '.transactionHash')
    echo "  ✅ Position closed successfully!"
    echo "  Transaction: $CLOSE_TX"
else
    echo "  ❌ Position failed to close"
    cat /tmp/close_position_tx.json
fi

echo ""
echo "=========================================="
echo "  TEST COMPLETE"
echo "=========================================="
echo ""
echo "Summary:"
echo "  ✅ USDC approved for CollateralVault"
echo "  ✅ Collateral deposited: 1,000 USDC"
echo "  ✅ Long position opened: 10 GPU hours"
echo "  ✅ IMR bug fix verified (no 'IMR breach' error)"
echo "  ✅ Position closed successfully"
echo ""
echo "Transactions:"
echo "  Approve: https://sepolia.etherscan.io/tx/$APPROVE_TX"
echo "  Deposit: https://sepolia.etherscan.io/tx/$DEPOSIT_TX"
echo "  Open Position: https://sepolia.etherscan.io/tx/$OPEN_TX"
echo "  Close Position: https://sepolia.etherscan.io/tx/$CLOSE_TX"
echo ""
echo "🎉 All tests passed! Deployment is working correctly."
