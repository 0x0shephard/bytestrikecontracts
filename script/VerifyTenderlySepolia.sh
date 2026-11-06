#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NETWORK_ID="${NETWORK_ID:-11155111}"
TENDERLY_VISIBILITY="${TENDERLY_VISIBILITY:-private}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

if [[ -z "${TENDERLY_ACCOUNT:-}" || -z "${TENDERLY_PROJECT:-}" ]]; then
  if [[ "${TENDERLY_API_URL:-}" =~ /account/([^/]+)/project/([^/]+)/? ]]; then
    TENDERLY_ACCOUNT="${TENDERLY_ACCOUNT:-${BASH_REMATCH[1]}}"
    TENDERLY_PROJECT="${TENDERLY_PROJECT:-${BASH_REMATCH[2]}}"
  elif [[ "${TENDERLY_DASHBOARD_URL:-}" =~ dashboard\.tenderly\.co/([^/]+)/([^/]+)/? ]]; then
    TENDERLY_ACCOUNT="${TENDERLY_ACCOUNT:-${BASH_REMATCH[1]}}"
    TENDERLY_PROJECT="${TENDERLY_PROJECT:-${BASH_REMATCH[2]}}"
  fi
fi

required=(
  TENDERLY_ACCOUNT
  TENDERLY_PROJECT
  TENDERLY_ACCESS_KEY
  SEPOLIA_RPC_URL
)

for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: $name" >&2
    exit 1
  fi
done

VERIFIER_URL="https://api.tenderly.co/api/v1/account/${TENDERLY_ACCOUNT}/project/${TENDERLY_PROJECT}/etherscan/verify/network/${NETWORK_ID}"
if [[ "$TENDERLY_VISIBILITY" == "public" ]]; then
  VERIFIER_URL="${VERIFIER_URL}/public"
elif [[ "$TENDERLY_VISIBILITY" != "private" ]]; then
  echo "TENDERLY_VISIBILITY must be 'private' or 'public'" >&2
  exit 1
fi

COMMON_ARGS=(
  --chain "$NETWORK_ID"
  --rpc-url "$SEPOLIA_RPC_URL"
  --verifier custom
  --verifier-url "$VERIFIER_URL"
  --etherscan-api-key "$TENDERLY_ACCESS_KEY"
  --compiler-version "v0.8.28+commit.7893614a"
  --optimizer-runs 1
  --evm-version prague
  --via-ir
  --watch
  --skip-is-verified-check
)

verify_target() {
  local address="$1"
  local contract="$2"
  local constructor_args="$3"
  local label="${4:-$contract}"

  echo
  echo "==> Verifying ${label}"
  echo "    ${address} ${contract}"

  if [[ -n "$constructor_args" ]]; then
    forge verify-contract "$address" "$contract" \
      "${COMMON_ARGS[@]}" \
      --constructor-args "$constructor_args"
  else
    forge verify-contract "$address" "$contract" \
      "${COMMON_ARGS[@]}"
  fi
}

echo "Building with pinned deployment settings..."
forge build --force

echo
echo "Submitting Sepolia contracts to Tenderly (${TENDERLY_VISIBILITY})..."
echo "Tenderly project: ${TENDERLY_ACCOUNT}/${TENDERLY_PROJECT}"

tmp_targets="$(mktemp)"
node <<'NODE' > "$tmp_targets"
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const desired = new Map();
function want(address, label, contractName) {
  if (!address || !/^0x[0-9a-fA-F]{40}$/.test(address)) return;
  desired.set(address.toLowerCase(), { label: label.replace(/[|\t]/g, " "), contractName });
}

want("0x947Cc17D8CbC0Fc1E64de138eE4947d3AF9C26EE", "Mock USDC", "MockERC20");
want("0xd1F8374cFA52a2b6d7803dCCEf2615b269e59Ca3", "H100 placeholder token", "MockERC20");
want("0x27F4970bd037c09440823755657c5fcF107532ae", "Collateral Oracle", "Oracle");
want("0x97f557594bA32e51c0eA215B1886111F24E957af", "CuOracle", "CuOracle");
want("0x236b75D39203506ee3180Ef2E1c7460a188C43c6", "MarketRegistry", "MarketRegistry");
want("0x44345dFCD97973329A88aaE8c1432ea90525Ed13", "CollateralVault", "CollateralVault");
want("0x8a7FD495fECBc46e427A309d0f3cC5FC9355860d", "ClearingHouseLogic", "ClearingHouseLogic");
want("0x914F7C5E7f870E3E77ce4d7AC6ba5cDf82f81873", "ClearingHouse implementation", "ClearingHouse");
want("0xDf4DDD4019097B335dD507f916984A1A53E40a0d", "ClearingHouse ERC1967 proxy", "ERC1967Proxy");
want("0x132Ba3d3073FDa7440fb0594210C47eC19087eaD", "InsuranceFund", "InsuranceFund");
want("0xBCEA366b30eb1dcAC6968AECcc215E8797553a5e", "FeeRouter", "FeeRouter");
want("0xC943C963DAFc8043E349a9191D4c567f2CB693AA", "vAMM implementation", "vAMM");
want("0xbb296DB60A9BE18CB12ec05e098f8DcfEe4049AD", "H100 CuOracleAdapter", "CuOracleAdapter");
want("0x3e9Fb18d7C19Dfc25bC2d102be9453ee992D1993", "H100 vAMM ERC1967 proxy", "ERC1967Proxy");

const adapters = JSON.parse(fs.readFileSync("deployments/sepolia-adapters-12h.json", "utf8"));
for (const value of Object.values(adapters)) {
  if (!value || typeof value !== "object" || !value.name) continue;
  want(value.newAdapter, `${value.name} CuOracleAdapter`, "CuOracleAdapter");
  want(value.vamm, `${value.name} vAMM ERC1967 proxy`, "ERC1967Proxy");
}

const contracts = {
  MockERC20: ["script/MockERC20.sol:MockERC20", "constructor(string,string,uint8)"],
  Oracle: ["src/Oracle/Oracle.sol:Oracle", ""],
  CuOracle: ["src/Oracle/CuOracle.sol:CuOracle", "constructor(address,uint256)"],
  CuOracleAdapter: ["src/Oracle/CuOracleAdapter.sol:CuOracleAdapter", "constructor(address,bytes32,uint256)"],
  MarketRegistry: ["src/MarketRegistry.sol:MarketRegistry", ""],
  CollateralVault: ["src/CollateralVault.sol:CollateralVault", ""],
  ClearingHouseLogic: ["src/ClearingHouseLogic.sol:ClearingHouseLogic", ""],
  ClearingHouse: ["src/ClearingHouse.sol:ClearingHouse", "constructor(address)"],
  ERC1967Proxy: ["lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy", "constructor(address,bytes)"],
  InsuranceFund: ["src/InsuranceFund.sol:InsuranceFund", "constructor(address,address)"],
  FeeRouter: ["src/FeeRouter.sol:FeeRouter", "constructor(address,address,address,address,uint16,uint16)"],
  vAMM: ["src/vAMM.sol:vAMM", ""],
};

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (entry.isFile() && entry.name.endsWith(".json") && !full.includes(`${path.sep}dry-run${path.sep}`)) out.push(full);
  }
  return out;
}

function encode(sig, args) {
  if (!sig) return "";
  const result = spawnSync("cast", ["abi-encode", sig, ...args.map(String)], { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`cast abi-encode failed for ${sig}: ${result.stderr || result.stdout}`);
  }
  return result.stdout.trim();
}

const creates = new Map();
for (const file of walk("broadcast")) {
  let json;
  try {
    json = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    continue;
  }
  for (const tx of json.transactions || []) {
    if (tx.transactionType !== "CREATE" || !tx.contractAddress) continue;
    const key = tx.contractAddress.toLowerCase();
    const wanted = desired.get(key);
    if (!wanted || creates.has(key) || tx.contractName !== wanted.contractName) continue;
    const meta = contracts[tx.contractName];
    if (!meta) continue;
    creates.set(key, {
      address: tx.contractAddress,
      label: wanted.label,
      contract: meta[0],
      args: encode(meta[1], tx.arguments || []) || "-",
    });
  }
}

for (const [address, wanted] of desired) {
  const target = creates.get(address);
  if (!target) {
    console.error(`WARN missing broadcast CREATE for ${wanted.label} ${address}`);
    continue;
  }
  console.log([target.address, target.contract, target.args, target.label].join("|"));
}
NODE

while IFS='|' read -r address contract constructor_args label; do
  if [[ "$constructor_args" == "-" ]]; then
    constructor_args=""
  fi
  verify_target "$address" "$contract" "$constructor_args" "$label"
done < "$tmp_targets"

rm -f "$tmp_targets"

echo
echo "Tenderly verification submissions complete."
