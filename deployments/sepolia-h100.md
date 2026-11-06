# ByteStrike Sepolia Deployment — H100-PERP

Live on **Sepolia** (chain id `11155111`), market **H100-PERP**, mark = index = **$4.22**, IMR **10%**, MMR **5%**, liquidation penalty **2%** (cap $10,000).

Deployed: 2026-05-06 (UTC) via `script/DeploySepoliaH100.s.sol` and `script/SeedAndUnpauseH100.s.sol` against fix commit `9e6477430c98...`.

---

## Core protocol addresses

| Contract | Address |
|---|---|
| **ClearingHouse** (UUPS proxy) | [`0xDf4DDD4019097B335dD507f916984A1A53E40a0d`](https://sepolia.etherscan.io/address/0xDf4DDD4019097B335dD507f916984A1A53E40a0d) |
| ClearingHouse implementation | [`0x914F7C5E7f870E3E77ce4d7AC6ba5cDf82f81873`](https://sepolia.etherscan.io/address/0x914F7C5E7f870E3E77ce4d7AC6ba5cDf82f81873) |
| ClearingHouseLogic (delegatecall target) | [`0x8a7FD495fECBc46e427A309d0f3cC5FC9355860d`](https://sepolia.etherscan.io/address/0x8a7FD495fECBc46e427A309d0f3cC5FC9355860d) |
| **CollateralVault** | [`0x44345dFCD97973329A88aaE8c1432ea90525Ed13`](https://sepolia.etherscan.io/address/0x44345dFCD97973329A88aaE8c1432ea90525Ed13) |
| **MarketRegistry** | [`0x236b75D39203506ee3180Ef2E1c7460a188C43c6`](https://sepolia.etherscan.io/address/0x236b75D39203506ee3180Ef2E1c7460a188C43c6) |
| **InsuranceFund** | [`0x132Ba3d3073FDa7440fb0594210C47eC19087eaD`](https://sepolia.etherscan.io/address/0x132Ba3d3073FDa7440fb0594210C47eC19087eaD) |
| **FeeRouter** | [`0xBCEA366b30eb1dcAC6968AECcc215E8797553a5e`](https://sepolia.etherscan.io/address/0xBCEA366b30eb1dcAC6968AECcc215E8797553a5e) |

## H100-PERP market

| Component | Address |
|---|---|
| **vAMM** (UUPS proxy, market-specific) | [`0x3e9Fb18d7C19Dfc25bC2d102be9453ee992D1993`](https://sepolia.etherscan.io/address/0x3e9Fb18d7C19Dfc25bC2d102be9453ee992D1993) |
| vAMM implementation (shared) | [`0xC943C963DAFc8043E349a9191D4c567f2CB693AA`](https://sepolia.etherscan.io/address/0xC943C963DAFc8043E349a9191D4c567f2CB693AA) |
| H100 base asset (placeholder mock) | [`0xd1F8374cFA52a2b6d7803dCCEf2615b269e59Ca3`](https://sepolia.etherscan.io/address/0xd1F8374cFA52a2b6d7803dCCEf2615b269e59Ca3) |

| Market parameter | Value |
|---|---|
| `marketId` | `keccak256("H100-PERP")` = `0x2bc0c3f3ef82289c7da8a9335c83ea4f2b5b8bd62b67c4f4e0dba00b304c2937` |
| Initial mark / index price | `$4.22` (`4_220_000_000_000_000_000`) |
| Initial base reserve (virtual) | `10_000` H100-hr |
| Initial quote reserve (virtual) | `42_200` USDC |
| Trade fee | `10` bps (0.10%) |
| Funding clamp | `100` bps/hour |
| Funding k | `1e18` |
| **IMR** | **`1000` bps (10%)** |
| **MMR** | **`500` bps (5%)** |
| Liquidation penalty | `200` bps (2%) |
| Penalty cap | `$10,000` |

## Oracle stack

| Contract | Address | Notes |
|---|---|---|
| Oracle (Chainlink, collateral valuation) | [`0x27F4970bd037c09440823755657c5fcF107532ae`](https://sepolia.etherscan.io/address/0x27F4970bd037c09440823755657c5fcF107532ae) | USDC/USD via `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E`, stale period 24h |
| **CuOracle** (commit-reveal H100 index) | [`0x97f557594bA32e51c0eA215B1886111F24E957af`](https://sepolia.etherscan.io/address/0x97f557594bA32e51c0eA215B1886111F24E957af) | Owner = deployer; H100 asset registered |
| CuOracleAdapter (IOracle wrapper) | [`0xbb296DB60A9BE18CB12ec05e098f8DcfEe4049AD`](https://sepolia.etherscan.io/address/0xbb296DB60A9BE18CB12ec05e098f8DcfEe4049AD) | `assetId = keccak256("H100")`, `maxAge = 1h` |

## Tokens

| Token | Address | Decimals | Notes |
|---|---|---|---|
| **USDC** (mock, quote/collateral) | [`0x947Cc17D8CbC0Fc1E64de138eE4947d3AF9C26EE`](https://sepolia.etherscan.io/address/0x947Cc17D8CbC0Fc1E64de138eE4947d3AF9C26EE) | 6 | `mint(address,uint256)` is open — anyone can mint test USDC |
| H100 (mock, placeholder base) | [`0xd1F8374cFA52a2b6d7803dCCEf2615b269e59Ca3`](https://sepolia.etherscan.io/address/0xd1F8374cFA52a2b6d7803dCCEf2615b269e59Ca3) | 18 | Synthetic; never transferred during trades |

## Roles & accounts

| Role | Address |
|---|---|
| Deployer (DEFAULT_ADMIN on registry / vault, vAMM / IF / FeeRouter / CuOracle owner) | `0xCc624fFA5df1F3F4b30aa8abd30186a86254F406` |
| Treasury admin (FeeRouter) | `0xCc624fFA5df1F3F4b30aa8abd30186a86254F406` |
| Seed long wallet | `0x5618343fce114678a99Cf1Bb214b3E7271D48818` |
| Seed short wallet | `0xc29D6094F96E7Fd30F18AF95C6A550c40fe85C27` |

> Seed wallet private keys + the H100 oracle nonce are stored in `.env` (gitignored). The same nonce **must not be reused** for any future commit on this CuOracle instance — generate a fresh `openssl rand -hex 32` each cycle (audit I-12).

## Initial state (verified post-deployment)

- vAMM mark price: `$4.22008…` (drift from $4.22 caused by seed long + short executing in the same block)
- Total long OI: `100` H100-hr
- Total short OI: `100` H100-hr (audit M-12 satisfied — funding has counterparties)
- Market active (unpaused): `true`
- Insurance fund balance: `100,000.42` USDC (100k seed donate + ~$0.42 trade fees from seed trades)

## Parameters configured

- USDC collateral registered: 1% haircut, 5% liq incentive, 10M global cap, 1M per-account cap.
- Oracle stale period: 24h (Sepolia testnet feed cadence).
- vAMM funding parameters: non-zero (audit L-18 mitigation).
- vAMM `setMinReserves` not called — defaults to zero, no reserve floor on testnet.

## Operational reminders (post-audit caveats)

| Caveat | Action required |
|---|---|
| **M-16** USD/USDC unit mixing | Keeper must submit prices in USDC-denominated terms during any USDC depeg. |
| **L-10** stale `isLiquidatable` view | Liquidator bot must use `eth_call` simulation: settleFunding → isLiquidatable → liquidate. |
| **L-25** instant risk param activation | Announce `setRiskParams` changes ≥ 24h in advance. Move admin behind multi-sig + timelock for mainnet. |
| **I-12** predictable nonce | Always generate `H100_NONCE` via CSPRNG. Already enforced in deployment script via env var. |
| **I-21** unbounded markets per account | Add per-account market cap before launching the 5th market. |

## Reproducing this deployment

Scripts:

- `script/DeploySepoliaH100.s.sol` — Phases 1–4 (tokens, oracles, core, market, commit).
- `script/SeedAndUnpauseH100.s.sol` — Phase 5 (reveal + seed long/short + unpause).

Required env vars (kept in `.env`):

```
PRIVATE_KEY=<deployer EOA>
SEPOLIA_RPC_URL=<provider RPC>
ETHERSCAN_API_KEY=<for verification>
TREASURY_ADDR=<fee treasury>
SEED_LONG_ADDR=<seed long address>
SEED_SHORT_ADDR=<seed short address>
SEED_LONG_PK=<seed long private key>
SEED_SHORT_PK=<seed short private key>
H100_NONCE=<openssl rand -hex 32, prefixed 0x>
```

Run:

```bash
forge script script/DeploySepoliaH100.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --slow

# wait ≥ 1 block (Sepolia: ~12-15 s) for CuOracle minCommitRevealDelay

forge script script/SeedAndUnpauseH100.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --slow
```

## Smoke trade for any user

```bash
USDC=0x947Cc17D8CbC0Fc1E64de138eE4947d3AF9C26EE
VAULT=0x44345dFCD97973329A88aaE8c1432ea90525Ed13
CH=0xDf4DDD4019097B335dD507f916984A1A53E40a0d
H100_PERP=0x2bc0c3f3ef82289c7da8a9335c83ea4f2b5b8bd62b67c4f4e0dba00b304c2937

cast send --rpc-url $SEPOLIA_RPC_URL --private-key $YOUR_PK \
  $USDC "mint(address,uint256)" $YOUR_ADDR 1000000000   # 1000 USDC

cast send --rpc-url $SEPOLIA_RPC_URL --private-key $YOUR_PK \
  $USDC "approve(address,uint256)" $VAULT 1000000000

cast send --rpc-url $SEPOLIA_RPC_URL --private-key $YOUR_PK \
  $CH "deposit(address,uint256)" $USDC 1000000000

cast send --rpc-url $SEPOLIA_RPC_URL --private-key $YOUR_PK \
  $CH "addMargin(bytes32,uint256)" $H100_PERP 100000000000000000000   # $100 in WAD

cast send --rpc-url $SEPOLIA_RPC_URL --private-key $YOUR_PK \
  $CH "openPosition(bytes32,bool,uint128,uint256)" \
  $H100_PERP true 10000000000000000000 50000000000000000000   # 10 H100-hr long, max $50 spend
```
