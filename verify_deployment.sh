#!/bin/bash
RPC="https://eth-sepolia.g.alchemy.com/v2/3qoSFfQA1ZOtTO-eyMjN0a1ijwT4AdQy"

echo "=== ByteStrike Deployment Verification ==="
echo ""
echo "Tokens:"
echo -n "  Mock USDC (0x37D5154731eE25C83E06E1abC312075AB4B4D8fF): "
[[ $(cast code 0x37D5154731eE25C83E06E1abC312075AB4B4D8fF --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo -n "  Mock WETH (0x92e525D76400a50aF648bc606cdde5F7CF5BEeb1): "
[[ $(cast code 0x92e525D76400a50aF648bc606cdde5F7CF5BEeb1 --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo ""
echo "Oracles:"
echo -n "  CuOracle (0xB28502a76ED13877fCCd33dc9301b8250b14efd5): "
[[ $(cast code 0xB28502a76ED13877fCCd33dc9301b8250b14efd5 --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo -n "  CuOracleAdapter (0x7150591E1b4BDEE29E8420b554Fee0ECdeE3662c): "
[[ $(cast code 0x7150591E1b4BDEE29E8420b554Fee0ECdeE3662c --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo -n "  Oracle (0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c): "
[[ $(cast code 0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo ""
echo "Core Contracts:"
echo -n "  MarketRegistry (0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD): "
[[ $(cast code 0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo -n "  CollateralVault (0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0): "
[[ $(cast code 0xfe2c9c2A1f0c700d88C78dCBc2E7bD1a8BB30DF0 --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo -n "  InsuranceFund (0xBF747923736903B209C5dA46442cfe53B8d11fAb): "
[[ $(cast code 0xBF747923736903B209C5dA46442cfe53B8d11fAb --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo -n "  ClearingHouse Impl (0x47E0F65909E565405f443ffB47D9A1dDf6a5D612): "
[[ $(cast code 0x47E0F65909E565405f443ffB47D9A1dDf6a5D612 --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo -n "  ClearingHouse Proxy (0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6): "
[[ $(cast code 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6 --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo -n "  FeeRouter (0x79d19cea18EDf042f66D6d10Cee7Dd73B06D31cb): "
[[ $(cast code 0x79d19cea18EDf042f66D6d10Cee7Dd73B06D31cb --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo -n "  vAMM Impl (0x27ECdeAf132078636E351030CfB5406Dec48C954): "
[[ $(cast code 0x27ECdeAf132078636E351030CfB5406Dec48C954 --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo -n "  vAMM Proxy (0x684d4C1133188845EaF9d533bef6E602C1a8b6d2): "
[[ $(cast code 0x684d4C1133188845EaF9d533bef6E602C1a8b6d2 --rpc-url $RPC) != "0x" ]] && echo "✅ DEPLOYED" || echo "❌ NOT DEPLOYED"

echo ""
echo "=== Verification Complete ==="
