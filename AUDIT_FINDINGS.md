# Audit findings (vAMM.sol + ClearingHouse.sol)

**Scope:**
- `src/vAMM.sol`
- `src/ClearingHouse.sol`

**Date:** 2026-01-18

---

## vAMM.sol

### 1) Fee underflow risk if `feeBps_ > 10000`
- **Lines:** 98–126 (init), 158–163, 203–204, 248–253
- **Issue:** `initialize` does not cap `feeBps_`, but swap math uses `10_000 - feeBps`. If `feeBps_ > 10_000`, math underflows and breaks pricing.
- **Impact:** Incorrect pricing and reserve updates; market becomes unusable or exploitable.
- **Fix:** Add `require(feeBps_ <= 300)` (or at least `<= 10_000`) in `initialize`.
- **Test idea:** Initialize with `feeBps_=20000` and call `buyBase`; observe revert/incorrect output.

### 2) Funding uses oracle price without sanity checks
- **Lines:** 401–433 (especially 410–413)
- **Issue:** `pokeFunding()` assumes oracle price is non-zero and does not handle reverts.
- **Impact:** Trades/liquidations that call funding can be blocked, or funding can be distorted if price is zero.
- **Fix:** Guard `indexPriceX18 > 0` or use `try/catch` with fallback behavior.
- **Test idea:** Use mock oracle returning `0` and call `pokeFunding`.

### 3) TWAP may silently shorten the intended window
- **Lines:** 317–357
- **Issue:** If no observation exists at/before `targetTs`, the algorithm falls back to the most recent observation, shortening the effective window.
- **Impact:** TWAP is less stable than expected during low activity.
- **Fix:** Document the behavior or revert when insufficient history exists.
- **Test idea:** One swap only, then call `getTwap(window >> time since swap)` and observe shorter window behavior.

---

## ClearingHouse.sol

### 1) Critical — IMR reservation does not enforce collateral availability
- **Lines:** 741–757, 787–803
- **Issue:** `_applyTrade` increases reserved margin without checking free collateral unless `position.margin < requiredMargin`. If margin already equals the requirement, no collateral check is performed.
- **Impact:** Users can open/extend positions without sufficient collateral.
- **Fix:** Call `_ensureAvailableCollateral(account, marginRequired)` before or during margin reservation regardless of `position.margin`.
- **Test idea:** With `imrBps > 0`, `feeBps = 0`, user with **zero** collateral opens a position (should revert but currently passes).

### 2) High — Realized losses can be forgiven instead of collected
- **Lines:** 753–767
- **Issue:** When realized loss exceeds `position.margin`, margin is clamped to zero with no attempt to seize free collateral or record bad debt.
- **Impact:** Traders can avoid paying losses beyond reserved margin even if they have free collateral.
- **Fix:** Attempt to collect from free collateral before clamping to zero or record bad debt.
- **Test idea:** Open position with tiny margin, force large adverse move, close; observe loss not fully collected.

### 3) High — IMR uses mark price (manipulable)
- **Lines:** 791–795
- **Issue:** IMR is computed with `markPrice`, which can be manipulated in low-liquidity conditions.
- **Impact:** Under-collateralized positions can be opened by temporarily lowering mark price.
- **Fix:** Use `_getRiskPrice(m)` (oracle/index) for IMR.
- **Test idea:** Manipulate mark down, open position, restore price, observe under-collateralization.

### 4) Medium — Liquidation penalty uses mark price (manipulable)
- **Lines:** 477–481
- **Issue:** Penalty notional is calculated using `markPrice`.
- **Impact:** Liquidation penalties can be reduced by mark manipulation.
- **Fix:** Use `_getRiskPrice(m)`.
- **Test idea:** Manipulate mark down before liquidation and observe reduced penalty.

### 5) Medium — Funding debits beyond margin create silent bad debt
- **Lines:** 659–668
- **Issue:** Negative funding exceeding margin is clamped to zero without collecting free collateral.
- **Impact:** Funding obligations can be avoided even if user has collateral.
- **Fix:** Attempt to collect from free collateral before recording bad debt.
- **Test idea:** Position with free collateral and large negative funding; observe margin zeroed without collateral seizure.

### 6) Edge — O(n) active-market scans can DOS withdraw/open
- **Lines:** 187–191 (withdraw), 358–361 (open)
- **Issue:** Loops over `_userActiveMarkets` can grow large and make operations fail due to gas limits.
- **Impact:** Users can become unable to withdraw or open positions.
- **Fix:** Cap active markets, or implement paginated checks.
- **Test idea:** Open many markets, then attempt withdraw.

---

## Notes
- Findings are based on current code and line numbers from the repository state on 2026-01-18.
- If you want Foundry tests or patch suggestions applied directly, let me know and I’ll implement them.
