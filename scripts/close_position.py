#!/usr/bin/env python3
"""Close stuck position on ClearingHouse."""

import os
from decimal import Decimal
from web3 import Web3
from eth_account import Account

# Configuration
SEPOLIA_RPC_URL = os.getenv("SEPOLIA_RPC_URL", "https://rpc.sepolia.org")
PRIVATE_KEY = os.getenv("PRIVATE_KEY", "0x7857dfba6a2faf4f52f5e7b28a28d5a66be4bdf588437d03d5fd5d8522cf8348")

CLEARING_HOUSE = "0x445Fa8890562Ec6220A60b3911C692DffaD49AcB"
MARKET_ID = "0x923fe13dd90eff0f2f8b82db89ef27daef5f899aca7fba59ebb0b01a6343bfb5"  # H100-PERP

# ClearingHouse ABI (minimal - just closePosition)
CLEARING_HOUSE_ABI = [
    {
        "type": "function",
        "name": "closePosition",
        "inputs": [
            {"name": "marketId", "type": "bytes32"},
            {"name": "size", "type": "uint128"},
            {"name": "priceLimitX18", "type": "uint256"}
        ],
        "outputs": [],
        "stateMutability": "nonpayable"
    },
    {
        "type": "function",
        "name": "getPosition",
        "inputs": [
            {"name": "marketId", "type": "bytes32"},
            {"name": "trader", "type": "address"}
        ],
        "outputs": [
            {"name": "size", "type": "int256"},
            {"name": "margin", "type": "uint256"},
            {"name": "entryPriceX18", "type": "uint256"},
            {"name": "lastFundingIndex", "type": "int256"},
            {"name": "realizedPnL", "type": "int256"}
        ],
        "stateMutability": "view"
    }
]

def main():
    # Connect to Sepolia
    print("=" * 60)
    print("CLOSING STUCK POSITION")
    print("=" * 60)

    w3 = Web3(Web3.HTTPProvider(SEPOLIA_RPC_URL))
    if not w3.is_connected():
        print(f"❌ Failed to connect to Sepolia RPC: {SEPOLIA_RPC_URL}")
        return

    print(f"✅ Connected to Sepolia (Chain ID: {w3.eth.chain_id})")
    print(f"   Block: {w3.eth.block_number}")

    # Setup account
    account = Account.from_key(PRIVATE_KEY)
    address = account.address
    balance = w3.eth.get_balance(address)

    print(f"   Trader: {address}")
    print(f"   Balance: {w3.from_wei(balance, 'ether'):.4f} ETH")
    print()

    # Setup contract
    clearing_house = w3.eth.contract(
        address=Web3.to_checksum_address(CLEARING_HOUSE),
        abi=CLEARING_HOUSE_ABI
    )

    # Try to get position (might fail due to struct incompatibility)
    print("Checking position...")
    try:
        position = clearing_house.functions.getPosition(
            bytes.fromhex(MARKET_ID[2:]),
            address
        ).call()

        size, margin, entry_price, _, realized_pnl = position

        print(f"   Size: {size / 1e18:.4f} (negative = short)")
        print(f"   Margin: ${margin / 1e18:.2f}")
        print(f"   Entry Price: ${entry_price / 1e18:.2f}")
        print(f"   Realized PnL: ${realized_pnl / 1e18:.2f}")
        print()

        if size == 0:
            print("❌ No position to close!")
            return

        # Calculate absolute size
        abs_size = abs(size)

    except Exception as e:
        print(f"⚠️  Could not query position: {e}")
        print(f"   Using size from frontend: 65252366.6746 GPU-HRS")
        abs_size = int(65252366.6746 * 1e18)
        print()

    # Close the position
    print("=" * 60)
    print("CLOSING POSITION")
    print("=" * 60)
    print(f"   Size to close: {abs_size / 1e18:.4f} GPU-HRS")
    print(f"   Price limit: Market (0 = no limit)")
    print()

    # Build transaction
    nonce = w3.eth.get_transaction_count(address)
    gas_price = w3.eth.gas_price

    # Estimate gas first
    try:
        gas_estimate = clearing_house.functions.closePosition(
            bytes.fromhex(MARKET_ID[2:]),
            abs_size,
            0  # Market price (no limit)
        ).estimate_gas({'from': address})

        gas_limit = int(gas_estimate * 1.2)  # Add 20% buffer
        print(f"   Estimated gas: {gas_estimate:,}")
        print(f"   Gas limit: {gas_limit:,}")

    except Exception as e:
        print(f"⚠️  Gas estimation failed: {e}")
        gas_limit = 500_000  # Use safe default
        print(f"   Using default gas limit: {gas_limit:,}")

    print(f"   Gas price: {w3.from_wei(gas_price, 'gwei'):.2f} gwei")
    print()

    # Build and sign transaction
    tx = clearing_house.functions.closePosition(
        bytes.fromhex(MARKET_ID[2:]),
        abs_size,
        0  # Market price
    ).build_transaction({
        'from': address,
        'nonce': nonce,
        'gas': gas_limit,
        'gasPrice': gas_price,
        'chainId': 11155111
    })

    # Sign transaction
    signed_tx = account.sign_transaction(tx)

    # Send transaction
    print("📤 Sending transaction...")
    try:
        tx_hash = w3.eth.send_raw_transaction(signed_tx.rawTransaction)
        tx_hash_hex = tx_hash.hex()

        print(f"✅ Transaction sent!")
        print(f"   TX Hash: {tx_hash_hex}")
        print(f"   Etherscan: https://sepolia.etherscan.io/tx/{tx_hash_hex}")
        print()
        print("⏳ Waiting for confirmation...")

        # Wait for receipt
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)

        print()
        print("=" * 60)
        if receipt['status'] == 1:
            print("✅ POSITION CLOSED SUCCESSFULLY!")
        else:
            print("❌ TRANSACTION FAILED")
        print("=" * 60)
        print(f"   Block: {receipt['blockNumber']}")
        print(f"   Gas used: {receipt['gasUsed']:,}")
        print(f"   TX: {tx_hash_hex}")
        print()

        if receipt['status'] == 1:
            print("Your position has been closed!")
            print("Check your wallet for returned margin.")
        else:
            print("Transaction reverted. Possible reasons:")
            print("  - Insufficient margin")
            print("  - Market paused")
            print("  - Price slippage too high")

    except Exception as e:
        print()
        print("=" * 60)
        print("❌ TRANSACTION FAILED")
        print("=" * 60)
        print(f"Error: {e}")
        print()
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()
