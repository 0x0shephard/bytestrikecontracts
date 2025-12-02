#!/bin/bash

# ByteStrike Contract Verification Script
# Run this after Etherscan API cooldown (1-2 hours)

ETHERSCAN_API_KEY="YKRZ535CPBDTH4Q4142K66DCXQK3W2VNW93"
CHAIN_ID=11155111

echo "Starting contract verification..."
echo "This will take several minutes. Please wait..."

# Add delays between verifications to avoid rate limiting
DELAY=10

# 1. Verify Mock USDC
echo ""
echo "1/11: Verifying Mock USDC..."
forge verify-contract 0x71075745A2A63dff3BD4819e9639D0E412c14AA9 \
  script/MockERC20.sol:MockERC20 \
  --chain-id $CHAIN_ID \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(string,string,uint8)" "Mock USDC" "mUSDC" 6) \
  --watch
sleep $DELAY

# 2. Verify Mock WETH
echo ""
echo "2/11: Verifying Mock WETH..."
forge verify-contract 0x36EC0f183Bd4014097934dcD7e23d9A5F0a69b40 \
  script/MockERC20.sol:MockERC20 \
  --chain-id $CHAIN_ID \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(string,string,uint8)" "Mock Wrapped Ether" "mWETH" 18) \
  --watch
sleep $DELAY

# 3. Verify MockOracle
echo ""
echo "3/11: Verifying MockOracle..."
forge verify-contract 0x3cA2Da03e4b6dB8fe5a24c22Cf5EB2A34B59cbad \
  test/mocks/MockOracle.sol:MockOracle \
  --chain-id $CHAIN_ID \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(uint256,uint8)" 2000000000000000000000 18) \
  --watch
sleep $DELAY

# 4. Verify CollateralVault
echo ""
echo "4/11: Verifying CollateralVault..."
forge verify-contract 0x46615074Bb2bAA2b33553d50A25D0e4f2ec4542e \
  src/CollateralVault.sol:CollateralVault \
  --chain-id $CHAIN_ID \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch
sleep $DELAY

# 5. Verify MarketRegistry
echo ""
echo "5/11: Verifying MarketRegistry..."
forge verify-contract 0x6d96DFC1a209B500Eb928C83455F415cb96AFF3C \
  src/MarketRegistry.sol:MarketRegistry \
  --chain-id $CHAIN_ID \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch
sleep $DELAY

# 6. Verify ClearingHouse Implementation
echo ""
echo "6/11: Verifying ClearingHouse Implementation..."
forge verify-contract 0x09B85497fD5180222dbBA9A69741331D7bf735A0 \
  src/ClearingHouse.sol:ClearingHouse \
  --chain-id $CHAIN_ID \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch
sleep $DELAY

# 7. Verify vAMM Implementation
echo ""
echo "7/11: Verifying vAMM Implementation..."
forge verify-contract 0x91D47bFE9A6242a1D5b20B8913c02CA9e2Feb17e \
  src/vAMM.sol:vAMM \
  --chain-id $CHAIN_ID \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch
sleep $DELAY

# 8. Verify InsuranceFund
echo ""
echo "8/11: Verifying InsuranceFund..."
forge verify-contract 0x7d8B6B91aAC78F65EBc1D39d0a5c3608115Afe42 \
  src/InsuranceFund.sol:InsuranceFund \
  --chain-id $CHAIN_ID \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address)" 0x71075745A2A63dff3BD4819e9639D0E412c14AA9 0x4C86E0759117ceC6029fd01Cb10F28B324078e43) \
  --watch
sleep $DELAY

# 9. Verify FeeRouter
echo ""
echo "9/11: Verifying FeeRouter..."
forge verify-contract 0xc6B7aE853742992297a7526F5De7fdbF8164e687 \
  src/FeeRouter.sol:FeeRouter \
  --chain-id $CHAIN_ID \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,uint16,uint16)" 0x71075745A2A63dff3BD4819e9639D0E412c14AA9 0x7d8B6B91aAC78F65EBc1D39d0a5c3608115Afe42 0xCc624fFA5df1F3F4b30aa8abd30186a86254F406 0x4C86E0759117ceC6029fd01Cb10F28B324078e43 5000 5000) \
  --watch
sleep $DELAY

# 10. Verify ClearingHouse Proxy
echo ""
echo "10/11: Verifying ClearingHouse Proxy..."
forge verify-contract 0x4C86E0759117ceC6029fd01Cb10F28B324078e43 \
  lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --chain-id $CHAIN_ID \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch
sleep $DELAY

# 11. Verify vAMM Proxy
echo ""
echo "11/11: Verifying vAMM Proxy..."
forge verify-contract 0xb46928829C728e3CE1B20eA4157a23553eeA5701 \
  lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --chain-id $CHAIN_ID \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch

echo ""
echo "========================================="
echo "Verification Complete!"
echo "========================================="
echo "Check your contracts on Sepolia Etherscan:"
echo "https://sepolia.etherscan.io/address/0x4C86E0759117ceC6029fd01Cb10F28B324078e43"
