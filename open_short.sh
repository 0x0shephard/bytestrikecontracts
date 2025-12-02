#!/bin/bash

# Open SHORT Position Script
# This will open a -0.1 ETH SHORT position on ETH-PERP-V2 market

echo "🔴 Opening SHORT Position on ETH-PERP-V2"
echo "Position Size: -0.1 ETH (SHORT)"
echo "Market: ETH-PERP-V2 ($3.75)"
echo ""

# Contract Addresses
CLEARING_HOUSE="0x4ee4d55310B49c1DC3034fD95Cee61c88EB4A9Cc"
MARKET_ID="0x385badc5603eb47056a6bdcd6ac81a50df49d7a4e8a7451405e580bd12087a28"
RPC_URL="https://eth-sepolia.g.alchemy.com/v2/3qoSFfQA1ZOtTO-eyMjN0a1ijwT4AdQy"

# Position parameters
# Negative size = SHORT position
POSITION_SIZE="-100000000000000000"  # -0.1 ETH in wei
MIN_QUOTE_AMOUNT="0"                  # Accept any slippage for testnet

echo "Parameters:"
echo "- Market ID: $MARKET_ID"
echo "- Position Size: $POSITION_SIZE wei (-0.1 ETH)"
echo "- Min Quote: $MIN_QUOTE_AMOUNT"
echo ""

# Check if private key is provided
if [ -z "$PRIVATE_KEY" ]; then
    echo "❌ Error: PRIVATE_KEY environment variable not set"
    echo ""
    echo "Usage:"
    echo "  export PRIVATE_KEY=your_private_key_here"
    echo "  ./open_short.sh"
    echo ""
    echo "Or run directly:"
    echo "  PRIVATE_KEY=your_key ./open_short.sh"
    exit 1
fi

echo "📡 Sending transaction..."
echo ""

# Execute the transaction
cast send $CLEARING_HOUSE \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  "openPosition(bytes32,int256,uint256)" \
  $MARKET_ID \
  -- $POSITION_SIZE $MIN_QUOTE_AMOUNT

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ SHORT position opened successfully!"
    echo ""
    echo "📊 Position Details:"
    echo "- Market: ETH-PERP-V2"
    echo "- Side: SHORT 🔴"
    echo "- Size: 0.1 ETH"
    echo "- Entry Price: ~$3.75"
    echo "- Notional Value: ~$0.375"
    echo ""
    echo "💡 Your position will profit if ETH price goes DOWN"
    echo ""
    echo "🔍 Check your position:"
    echo "cast call $CLEARING_HOUSE \"getPosition(bytes32,address)\" $MARKET_ID 0xCc624fFA5df1F3F4b30aa8abd30186a86254F406 --rpc-url $RPC_URL"
else
    echo ""
    echo "❌ Transaction failed!"
    echo ""
    echo "Common issues:"
    echo "1. Insufficient collateral deposited"
    echo "2. Position would breach margin requirements"
    echo "3. Wrong network or RPC URL"
    echo "4. Invalid private key"
fi
