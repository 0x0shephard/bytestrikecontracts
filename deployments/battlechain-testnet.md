# ByteStrike — BattleChain Testnet Deployment

**Chain:** BattleChain (chain ID 627)
**Date:** 2026-03-28 (last updated)

## Contract Addresses

### Core Protocol

| Contract | Address | Notes |
|----------|---------|-------|
| ClearingHouse (proxy) | `0x79299Dc44AFEC5e816d7EFD89f698Eca8Efb305c` | UUPS, main entry point |
| ClearingHouse (impl) | `0xE25dE08316Fe45C2235f17Af27f0449774d1c8Bd` | |
| ClearingHouseLogic | `0x4Ed8079654eBA6a31c02B1d2Ed631bA215eC7B4a` | delegatecall target |
| CollateralVault | `0x5eb81A19Bc42CA3Fb034C5250EbFC00E4D0F3a7e` | |
| MarketRegistry | `0xa75839A6D2Bb2f47FE98dc81EC47eaD01D4A2c1F` | |
| vAMM (impl) | `0x6c9e72A4aFAc084d733B2D0d70d7ef3EB6E5450e` | shared impl for all vAMM proxies |

### Oracles

| Contract | Address | Notes |
|----------|---------|-------|
| CuOracle | `0x2E3f3D9aC763C3c7D8F5A9D6A94dD745D76D9e8f` | commit-reveal, owner = deployer |
| CuOracleAdapter (CU-PERP) | `0x3C1085dF918a38A95F84945E6705CC857b664074` | wraps CuOracle for CU asset |
| CuOracleAdapter (H100-PERP) | `0x4719869E2EceaADa61536906eeE68d483C6acABc` | wraps CuOracle for H100 asset |
| VaultOracle (MockOracle) | `0xebE1D241b937e9D816aaA3a1816fA0D198d626ab` | USDC = $1.00; set on CollateralVault 2026-03-28 |

### Tokens

| Contract | Address | Notes |
|----------|---------|-------|
| USDC (live MockERC20) | `0x445Fa8890562Ec6220A60b3911C692DffaD49AcB` | working; used by H100-PERP-LIVE |
| USDC (dead — nonce 85 failure) | `0x5033F54b2d97Bdbf21886bd311773E9b2B17bD98` | no code; do not use |

### H100-PERP-LIVE Market ✓ (tradeable)

| Contract | Address |
|----------|---------|
| vAMM proxy | `0xE56190a8a3a3a33e4C49418649a48d8174a82aE4` |
| InsuranceFund | `0x5BfEC48dBf17690d429E04324Fe16c3e060b9A0a` |
| FeeRouter | `0x5AE261f4B595419bc5EDD82AAefa6b6000E49662` |

### CU-PERP Market ✗ (not tradeable — dead quoteToken)

| Contract | Address | Notes |
|----------|---------|-------|
| vAMM proxy | `0xb6d7EFEF7578C0C261cd753E8448887f0C2FD7Ed` | has code; market unusable |
| InsuranceFund | `0x7bb834d07f8bB95E0DCad864943De2E4D5fB00E9` | references dead USDC |
| FeeRouter | `0x63aE79E8D02Bb7F6f048Fa8B0543BAf44305a862` | references dead USDC |

### H100-PERP Market ✗ (not tradeable — dead quoteToken)

| Contract | Address | Notes |
|----------|---------|-------|
| vAMM proxy | `0x69Ad44e1b57c18b61E4665Bca2664F6C422268D0` | has code; market unusable |

> CU-PERP and H100-PERP share the same InsuranceFund and FeeRouter as the original deployment, both of which reference the dead USDC at `0x5033F54b...`. SafeERC20 reverts on any token transfer.

### Safe Harbor

| Contract | Address | Notes |
|----------|---------|-------|
| Agreement v2 (active) | `0xD39E1bd7367B7Bd22727F626Be82A10F5705f6D3` | 13 contracts in scope; adopted 2026-03-28 |
| Agreement v1 (superseded) | `0x205BD0D6ea2A8E73142FF1185248c38981d1717f` | wrong scope — replaced |
| Safe Harbor Registry | `0xCb2A561395118895e2572A04C2D8AB8eCA8d7E5D` | BattleChain testnet |
| Attack Registry | `0x9E62988ccA776ff6613Fa68D34c9AB5431Ce57e1` | BattleChain testnet |

## Market IDs

| Market | ID |
|--------|-----|
| CU-PERP | `0x6bccb238fe13d418dea51fee67e9783f4d9c23cd8fb14a17ab35312d1c2f1d03` |
| CU_ASSET_ID (oracle) | `0x2cb39337dc2f90e1578ad7f3ba41430cb4ae796ca5b7d7d2aaced43f80bf42e4` |
| H100-PERP | `0x2bc0c3f3ef82289c7da8a9335c83ea4f2b5b8bd62b67c4f4e0dba00b304c2937` |
| H100_ASSET_ID (oracle) | `0x4af9fd38a31e980043173ab5907026770c7559ea203999da89b6c8a7a625f6c6` |
| H100-PERP-LIVE | `0x8dd61670d4e8e2935b874e08cab1320dabec987fdfc3cd2387466c8e7bced482` |

## Oracle Status

CuOracle seeded on 2026-03-27:

**CU-PERP:**
- Price: `3000000000000000000` ($3.00 per compute unit, 1e18 format)
- Commit tx: `0x067f5275fe36af37c5ad1d4aff29b6659866987133ddeea5520bf7089f74da00` (block 2000)
- Reveal tx: `0x66cbd772afae6f88781ca59f2884595c582f675ac9a032dd3311430ce097a4df` (block 2001)

**H100-PERP:**
- Price: `3000000000000000000` ($3.00 per H100 GPU hour, 1e18 format)
- Commit tx: `0xecfaa881f25527f61e6c33ca265b780d25499887489ecb29df0289c140be0d2a` (block 2098)
- Reveal tx: `0x0df7052258ce4003b991a946d6ca28e8fc42766b103efad3f2b706cd4067dabe` (block 2160)

## Risk Parameters

### CU-PERP

| Parameter | Value |
|-----------|-------|
| Initial Margin Requirement | 5% (500 bps) |
| Maintenance Margin Requirement | 2.5% (250 bps) |
| Liquidation Penalty | 2% (200 bps) |
| Liquidation Penalty Cap | $10,000 |
| Trade Fee | 0.1% (10 bps) |
| 50% of trade fees → InsuranceFund |
| 30% of liquidation penalties → InsuranceFund |

### H100-PERP

| Parameter | Value |
|-----------|-------|
| Initial Margin Requirement | 10% (1000 bps) |
| Maintenance Margin Requirement | 5% (500 bps) |
| Liquidation Penalty | 2% (200 bps) |
| Liquidation Penalty Cap | $10,000 |
| Trade Fee | 0.1% (10 bps) |

### H100-PERP-LIVE (tradeable market, uses live USDC)

| Parameter | Value |
|-----------|-------|
| Initial Margin Requirement | 10% (1000 bps) |
| Maintenance Margin Requirement | 5% (500 bps) |
| Liquidation Penalty | 2% (200 bps) |
| Liquidation Penalty Cap | $10,000 |
| Trade Fee | 0.1% (10 bps) |
| Quote Token | USDC (live MockERC20) |
| Oracle | CuOracleAdapter (H100), price $3.00 |

> **Note:** CU-PERP and H100-PERP use a dead quoteToken (nonce 85 deployment failure).
> H100-PERP-LIVE is the tradeable market. Vault oracle and collateral fixed 2026-03-28.

## Test Position (deployer)

Opened 2026-03-28 on H100-PERP-LIVE:
- Direction: **LONG**
- Size: `1e18` (1 H100 GPU hour)
- Entry price: ~$3.006 (slight slippage from $3.00 initial mark)
- Margin: ~$0.30 (10% IMR of $3.00 notional)
- Account: `0xCc624fFA5df1F3F4b30aa8abd30186a86254F406`

## Safe Harbor & Attack Mode

Two agreements exist:

| Agreement | Address | Status |
|-----------|---------|--------|
| v1 (original, wrong scope) | `0x205BD0D6ea2A8E73142FF1185248c38981d1717f` | Superseded — 2/7 scoped addresses had no code; CH proxy, Vault, CuOracle were missing |
| **v2 (current, correct scope)** | `0xD39E1bd7367B7Bd22727F626Be82A10F5705f6D3` | **Active** — 13 contracts, all live protocol + H100-PERP-LIVE surface |

Registry (`0xCb2A561395118895e2572A04C2D8AB8eCA8d7E5D`) now returns v2 for deployer `0xCc624...`.

### Scope (v2) — 13 contracts
CuOracle, CuOracleAdapter (CU-PERP), CuOracleAdapter (H100-PERP), MarketRegistry,
CollateralVault, ClearingHouse (proxy + impl + logic), vAMM impl,
vAMM proxy (H100-PERP-LIVE), InsuranceFund (H100-PERP-LIVE), FeeRouter (H100-PERP-LIVE), VaultOracle

### Attack Mode
`requestUnderAttack` fails programmatically because contracts were deployed via `new Contract()` instead of BattleChainDeployer. **Request attack mode manually via the BattleChain UI:**

```
Agreement: 0xD39E1bd7367B7Bd22727F626Be82A10F5705f6D3
```
