#!/bin/bash

# Close position script using cast
set -e

CLEARING_HOUSE="0x445Fa8890562Ec6220A60b3911C692DffaD49AcB"
MARKET_ID="0x385badc5603eb47056a6bdcd6ac81a50df49d7a4e8a7451405e580bd12087a28"  # ETH-PERP-V2
SIZE="65252366674599997635297280"  # 65252366.6746 * 1e18
PRICE_LIMIT="0"  # Market price (no limit)
PRIVATE_KEY="${PRIVATE_KEY:-0x7857dfba6a2faf4f52f5e7b28a28d5a66be4bdf588437d03d5fd5d8522cf8348}"

echo "============================================"
echo "CLOSING POSITION"
echo "============================================"
echo "ClearingHouse: $CLEARING_HOUSE"
echo "Market ID: $MARKET_ID"
echo "Size: 65252366.6746 GPU-HRS"
echo ""

# Generate the function selector and calldata
FUNCTION_SIG="closePosition(bytes32,uint128,uint256)"
echo "Generating transaction..."

# Use cast to send the transaction
echo ""
echo "Sending transaction..."

cast send "$CLEARING_HOUSE" \
  "$FUNCTION_SIG" \
  "$MARKET_ID" \
  "$SIZE" \
  "$PRICE_LIMIT" \
  --rpc-url "${SEPOLIA_RPC_URL:-https://rpc.sepolia.org}" \
  --private-key "$PRIVATE_KEY" \
  --gas-limit 700000 \
  --legacy

if [ $? -eq 0 ]; then
  echo ""
  echo "============================================"
  echo "✅ POSITION CLOSED SUCCESSFULLY!"
  echo "============================================"
else
  echo ""
  echo "============================================"
  echo "❌ TRANSACTION FAILED"
  echo "============================================"
  exit 1
fi
