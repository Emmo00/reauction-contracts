# Security Audit Report — `src/MarketPlace.sol`

**Date:** 2026-06-23
**Auditor:** Claude (Opus 4.8)
**Commit baseline:** `master` @ `ae859a6`
**Scope:** `src/MarketPlace.sol` (English auctions + fixed-price listings, USDC settlement, `ICollectibleCasts` ERC721 escrow)
**Dependencies reviewed:** OZ `AccessControl`, `ReentrancyGuard`, `ERC721Holder`; `src/interfaces/ICollectibleCasts.sol`

---

## Summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| H-1 | High | Failed seller payout permanently locks NFT + winning bid (no rescue path) | **Fixed** |
| M-1 | Medium | Push-refund in `placeBid` lets a stuck prior bidder freeze the auction (DoS) | **Fixed** |
| M-2 | Medium | Seller can cancel an auction that already has bids | **Fixed** |
| M-3 | Medium | Protocol fee applied at settlement time, not locked at creation | **Fixed** |
| L-1 | Low | Shared `isTokenOnSale` with sentinel-0 slots — cross-type calls revert only by accident | Noted |
| L-2 | Low | Raw `transfer`/`transferFrom` instead of `SafeERC20` | Noted |
| L-3 | Low | No pause / emergency stop | Noted |
| L-4 | Low | NFT delivered with `transferFrom`, not `safeTransferFrom` | Noted |
| L-5 | Low | Centralization: moderators cancel any sale; admin params have no timelock | Noted |
| I-1 | Info | Misleading `endTime` event params; no `indexed` fields | Noted |
| I-2 | Info | Strict-inequality dead second at `endTime` | Noted |
| I-3 | Info | Constructor trusts unvalidated `usdcDecimals_` | Noted |
| I-4 | Info | Same-bidder top-up logic is unintuitive | Noted |
| I-5 | Info | Self-dealing (wash trading) allowed | Noted |

The contract's reentrancy posture (CEI + `nonReentrant`) and escrow solvency were sound at baseline. The material risks were **push-payment liveness locks** and **retroactive/centralized fee control**, both addressed in this revision.

---

## High

### H-1 · Failed seller payout permanently locks the NFT and winning bid

**Location:** `settleAuction` (line 245, `_pushPayment(seller, amountToSettle)`)

`settleAuction` was the only way to finalize a bidded auction and it *pushed* USDC to the seller inline. If `USDC.transfer(seller, …)` reverts permanently (seller is USDC-blacklisted, or USDC is upgraded with a reverting hook), settlement reverts forever. Since `cancelAuction` is blocked after `endTime`, there was **no alternative path** — the escrowed NFT and the winner's USDC would be locked permanently, with no admin rescue.

**Remediation (implemented):** Seller proceeds are now **credited** to a `pendingWithdrawals` balance and claimed via a separate `withdraw()` call (pull-over-push). A failing transfer can no longer block settlement; only the affected account's own withdrawal is impacted, and the NFT still transfers to the winner.

---

## Medium

### M-1 · Push-refund in `placeBid` enables auction-freeze DoS

**Location:** `placeBid` (lines 181–183)

The previous high bidder was refunded inline on every new bid. If that bidder could not receive USDC (blacklist), all subsequent bids reverted at the refund, freezing the auction at the stuck bidder's price and effectively letting them win.

**Remediation (implemented):** Outbid refunds are credited to `pendingWithdrawals` instead of pushed. Bidding can no longer be DoS'd by a non-receiving prior bidder.

### M-2 · Seller could cancel an auction that already had bids

**Location:** `cancelAuction` (line 194)

`cancelAuction` allowed the seller to cancel at any time before `endTime`, even with active bids — refunding the high bidder and denying them the asset. This breaks the core auction guarantee.

**Remediation (implemented):** Once a bid exists (`highestBidder != address(0)`), the seller can no longer cancel; only `MODERATOR_ROLE` may cancel (emergency/abuse path), and the high bidder is refunded via the pull mechanism. Sellers may still cancel a bid-free auction.

### M-3 · Protocol fee applied at settlement time, not locked at creation

**Location:** `settleAuction` (line 241), `purchaseItem` (line 294), `setProtocolFee` (line 367)

Fees were computed from the live `protocolFeeBps` at settlement, and `setProtocolFee` allowed up to 100%. Admin could raise the fee on in-flight sales and capture the entire proceeds.

**Remediation (implemented):**
- The fee rate is **snapshotted** into each `Auction`/`Listing` at creation (`feeBps` field) and used at settlement, so in-flight sales are unaffected by later changes.
- `setProtocolFee` is now bounded by `MAX_PROTOCOL_FEE_BPS = 2000` (20%).

---

## Low (noted, not changed)

- **L-1 — Shared `isTokenOnSale` + sentinel-0 slots.** Calling the wrong settlement function for a sale type routes to the `id == 0` default struct and currently reverts only incidentally (via NFT transfer to `address(0)` or `endTime == 0` checks). Recommend an explicit per-token `SaleType` guard.
- **L-2 — Raw ERC20 calls.** `require(USDC.transfer(...))` is correct for canonical USDC but brittle if the (upgradeable) token changes semantics. Prefer `SafeERC20`.
- **L-3 — No pause.** Consider OZ `Pausable` on user entry points for incident response.
- **L-4 — `transferFrom` to winner.** NFT delivery uses `transferFrom`; a non-ERC721-aware contract winner could strand the token. Acceptable, but `safeTransferFrom` would surface the error.
- **L-5 — Centralization.** Moderators can cancel any sale; admin params change instantly. Document trust assumptions; consider a timelock.

## Informational (noted)

- **I-1** — `ListingPurchased`/`ListingCancelled` emit a field named `endTime` that is `block.timestamp`; no event fields are `indexed`.
- **I-2** — `placeBid` requires `endTime > now` and `settleAuction` requires `endTime < now`, leaving a 1-second window where neither is callable.
- **I-3** — Constructor trusts `usdcDecimals_` without validation.
- **I-4** — Same-bidder top-up requires re-paying the full min increment and is additive; confirm intended.
- **I-5** — Sellers can bid on / buy their own sales (wash trading); only the fee is lost.

---

## Verified safe

- **Escrow solvency:** `feeAccrued`, active-bid escrow, and `pendingWithdrawals` are disjoint liabilities, all backed by contract USDC balance; `collectProtocolFees` zeroes before transfer and never touches escrow.
- **Reentrancy:** all state-changers are `nonReentrant` with CEI ordering; `_collectNft` uses `safeTransferFrom` with the callback landing on this `ERC721Holder`.
- **Listing/auction creation ownership:** `_collectNft` reverts unless `msg.sender` is the real owner and approved the marketplace.
- **Sentinel id 0:** counters are pre-incremented, reserving id 0 as "none".
- **Arithmetic:** percentage and extension math cannot under/overflow under realistic values (0.8.x checked).

---

## Changes applied in this revision

1. Added `pendingWithdrawals` balance + `withdraw()` (pull payments) and `_creditPayment` helper.
2. `settleAuction`, `placeBid` refund, and `cancelAuction` refund now credit instead of push.
3. `cancelAuction` blocks seller cancellation once a bid exists (moderator-only).
4. `feeBps` snapshotted into `Auction` and `Listing` at creation and used at settlement.
5. `setProtocolFee` bounded by `MAX_PROTOCOL_FEE_BPS = 2000`.
