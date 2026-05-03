# 🛡️ Security Audit Report — `MarketPlace.sol`

| Field | Detail |
|---|---|
| **Contract** | `MarketPlace.sol` (331 lines) |
| **Solidity** | `0.8.30` (fixed pragma ✔️) |
| **Framework** | Foundry |
| **Target Chain** | Base (L2 — Optimistic rollup) |
| **Token Standard** | USDC (ERC-20), NFT via `ICollectibleCasts` (ERC-721) |
| **Dependencies** | OpenZeppelin `AccessControl` |
| **Audit Mode** | Full Audit — first review |
| **Date** | 2026-05-03 |

> [!CAUTION]
> This audit identified **4 Critical/High severity** issues, including two bugs that send funds to the wrong recipient, causing direct loss of user funds. **Do not deploy this contract without remediation.**

---

## Threat Model Summary

| Actor | Capability |
|---|---|
| **Seller** | Creates auctions/listings by escrowing NFT |
| **Bidder / Buyer** | Places bids or buys listings with USDC |
| **Admin** (`DEFAULT_ADMIN_ROLE`) | Sets fees, bid minimums, duration params, collects protocol fees |
| **Moderator** (`MODERATOR_ROLE`) | Can cancel auctions and listings |

**Crown jewels:** User NFTs escrowed in the contract; USDC bid deposits and sale proceeds.

**Critical invariants:**
1. Auction settlement must pay the **seller**, not the bidder
2. Listing purchase must pay the **seller**, not the buyer
3. Outbid funds must always be refundable
4. NFTs must be returnable when auctions/listings are cancelled

---

## Findings Summary

| ID | Severity | Title |
|---|---|---|
| [C-01](#c-01) | **Critical** | `settleAuction` pays the **highest bidder** instead of the **seller** |
| [C-02](#c-02) | **Critical** | `purchaseItem` pays the **buyer** instead of the listing **seller** |
| [H-01](#h-01) | **High** | Contract cannot receive NFTs via `safeTransferFrom` — all `createAuction`/`createListing` calls will revert |
| [H-02](#h-02) | **High** | Unchecked `USDC.transfer` return value in `collectProtocolFees` |
| [M-01](#m-01) | **Medium** | Same bidder accumulates bids without minimum-increment enforcement on stacked amount |
| [M-02](#m-02) | **Medium** | No minimum or maximum auction duration validation |
| [M-03](#m-03) | **Medium** | `cancelAuction` does not return the NFT to the seller |
| [M-04](#m-04) | **Medium** | No reentrancy protection on any function |
| [L-01](#l-01) | **Low** | Admin setters lack bounds validation — fee can be set to 100% |
| [L-02](#l-02) | **Low** | `setAuctionMinBidAmount` records the **new** value as `oldValue` in the event |
| [L-03](#l-03) | **Low** | Missing error messages on several `require` statements |
| [L-04](#l-04) | **Low** | `purchaseItem` does not verify listing is in `Active` state |
| [I-01](#i-01) | **Informational** | Contract does not implement `IERC165.supportsInterface` for ERC-721 receiver |
| [I-02](#i-02) | **Informational** | `isTokenOnSale` is shared across auctions and listings — collision possible |
| [I-03](#i-03) | **Informational** | Missing zero-address checks in constructor |

---

## Critical Findings

<a id="c-01"></a>
### [C-01] `settleAuction` pays the highest bidder instead of the seller

**Severity**: Critical
**Category**: Business Logic Error — Wrong Recipient
**Location**: [MarketPlace.sol#L194](file:///home/rimuru/Projects/miniapp-contracts/reauction-contracts/src/MarketPlace.sol#L194)

#### Description

In `settleAuction`, after calculating the protocol fee and the net settlement amount, the contract calls `_pushPayment(highestBidder, amountToSettle)` — sending the sale proceeds **back to the buyer** instead of to the `auction.seller`.

```solidity
// Line 194 — BUG: sends to highestBidder instead of auction.seller
_pushPayment(highestBidder, amountToSettle);
```

#### Impact

**Direct, unconditional loss of funds for every successful auction.** The seller loses their NFT and receives nothing. The winning bidder effectively gets the NFT for free (only the protocol fee is deducted from their bid, and the remainder is returned to them).

#### Proof of Concept

1. Alice creates an auction for tokenId 42
2. Bob bids 100 USDC → `_collectPayment(100, Bob)` pulls 100 USDC from Bob
3. Auction ends; anyone calls `settleAuction(42)`
4. Protocol fee (10 USDC) is accrued; `_pushPayment(Bob, 90)` sends 90 USDC **back to Bob**
5. Bob gets the NFT **and** 90 USDC back — net cost: 10 USDC (the fee)
6. Alice receives nothing

#### Recommendation

```diff
- _pushPayment(highestBidder, amountToSettle);
+ _pushPayment(auction.seller, amountToSettle);
```

---

<a id="c-02"></a>
### [C-02] `purchaseItem` pays the buyer instead of the listing seller

**Severity**: Critical
**Category**: Business Logic Error — Wrong Recipient
**Location**: [MarketPlace.sol#L234](file:///home/rimuru/Projects/miniapp-contracts/reauction-contracts/src/MarketPlace.sol#L234)

#### Description

Identical root cause to C-01 but in the fixed-price listing flow. `purchaseItem` calls `_pushPayment(buyer, amountToSettle)`, returning the purchase price (minus fee) **back to the buyer**.

```solidity
// Line 234 — BUG: sends to buyer instead of listing.seller
_pushPayment(buyer, amountToSettle);
```

#### Impact

**Direct, unconditional loss of funds for every listing purchase.** The seller loses their NFT and receives nothing. The buyer gets the NFT and most of their USDC back.

#### Proof of Concept

1. Alice lists tokenId 42 for 100 USDC
2. Bob calls `purchaseItem(42)` → 100 USDC pulled from Bob
3. Protocol fee (10 USDC) accrued; `_pushPayment(Bob, 90)` returns 90 USDC to Bob
4. Bob gets NFT + 90 USDC back; Alice gets nothing

#### Recommendation

```diff
- _pushPayment(buyer, amountToSettle);
+ _pushPayment(listing.seller, amountToSettle);
```

---

## High Findings

<a id="h-01"></a>
### [H-01] Contract cannot receive NFTs — missing `onERC721Received` / `ERC721Holder`

**Severity**: High
**Category**: Missing Interface Implementation
**Location**: [MarketPlace.sol#L271](file:///home/rimuru/Projects/miniapp-contracts/reauction-contracts/src/MarketPlace.sol#L271)

#### Description

`_collectNFT` calls `COLLECTIBLES.safeTransferFrom(owner, address(this), tokenId)`. The ERC-721 `safeTransferFrom` checks whether the receiver implements `onERC721Received()`. Since `MarketPlace` does not implement this callback (no `ERC721Holder` inheritance, no manual implementation), **every call to `createAuction` and `createListing` will revert**.

Compare with `Auction.sol` which correctly inherits `ERC721HolderUpgradeable`.

#### Impact

The entire marketplace is non-functional. No auctions or listings can be created.

#### Recommendation

```diff
+ import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

- contract MarketPlace is AccessControl {
+ contract MarketPlace is AccessControl, ERC721Holder {
```

---

<a id="h-02"></a>
### [H-02] Unchecked `USDC.transfer` return value in `collectProtocolFees`

**Severity**: High
**Category**: Unchecked Return Value (SWC-104)
**Location**: [MarketPlace.sol#L286](file:///home/rimuru/Projects/miniapp-contracts/reauction-contracts/src/MarketPlace.sol#L286)

#### Description

`collectProtocolFees` calls `USDC.transfer(receiver, amount)` without checking the return value, then **zeros out `feeAccrued`**. If the transfer silently fails (returns `false`), the protocol fees are permanently lost.

```solidity
function collectProtocolFees(address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 amount = feeAccrued;
    USDC.transfer(receiver, amount); // ← return value not checked
    feeAccrued = 0; // ← fees zeroed regardless
    ...
}
```

Note: While USDC on Base typically reverts on failure, the contract uses the generic `IERC20` interface, making it possible for non-reverting ERC-20 tokens (or future USDC upgrades) to silently fail. The rest of the contract correctly checks returns via `require`.

#### Impact

Protocol fees may be zeroed without actually being transferred, resulting in permanent loss of accrued fees.

#### Recommendation

```diff
- USDC.transfer(receiver, amount);
+ require(USDC.transfer(receiver, amount), "Failed to collect protocol fees");
```

Or use OpenZeppelin's `SafeERC20`:
```solidity
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
using SafeERC20 for IERC20;
// ...
USDC.safeTransfer(receiver, amount);
```

---

## Medium Findings

<a id="m-01"></a>
### [M-01] Same bidder can stack bids without increment enforcement on the total

**Severity**: Medium
**Category**: Business Logic Error
**Location**: [MarketPlace.sol#L134-L135](file:///home/rimuru/Projects/miniapp-contracts/reauction-contracts/src/MarketPlace.sol#L134-L135)

#### Description

When the current highest bidder places another bid, the code simply adds to their existing bid:

```solidity
if (auction.highestBidder == bidder) {
    auction.highestBid += amount;
}
```

However, the minimum bid check at L130 validates `amount >= expectedMinimumBid`, where `expectedMinimumBid` is based on the full `highestBid`. This means the bidder can place many tiny bids (each meeting the absolute minimum `auctionMinBidAmount` of 1 USDC) to increment their position by 1 USDC at a time, even though the BPS-based increment would require a much larger jump for a new bidder.

#### Impact

A bidder can park at the top by making trivially small stacking bids (1 USDC at a time), subverting the intended auction increment mechanism. This produces auction behavior that doesn't match the protocol's economic design.

#### Recommendation

When the same bidder adds to their bid, validate that their **new total** (`auction.highestBid + amount`) meets the minimum increment relative to a hypothetical competing bidder:

```solidity
if (auction.highestBidder == bidder) {
    // The new amount being added must itself meet the minimum bid requirement
    // to prevent trivial stacking
    auction.highestBid += amount;
} else {
    // Existing logic for new bidders...
}
```

Or alternatively, require the `amount` itself to meet the increment threshold.

---

<a id="m-02"></a>
### [M-02] No minimum or maximum auction duration validation

**Severity**: Medium
**Category**: Missing Input Validation
**Location**: [MarketPlace.sol#L100](file:///home/rimuru/Projects/miniapp-contracts/reauction-contracts/src/MarketPlace.sol#L100)

#### Description

`createAuction` accepts any `duration` value with no bounds checking. A seller can create an auction with:
- **`duration = 0`**: The auction instantly ends (endTime = block.timestamp) and can be settled in the same block, potentially before anyone can bid
- **`duration = type(uint256).max`**: An auction that effectively never ends, locking the NFT forever

Compare with `Auction.sol` which enforces `minDuration` (1 hour) and `maxDuration` (30 days).

#### Impact

- Zero-duration auction allows a seller to game the marketplace (create + settle in same TX)
- Extremely long auctions lock NFTs indefinitely
- The `auctionDurationExtension` mechanism compounds the issue, as extensions can push the end time even further

#### Recommendation

```solidity
uint256 public auctionMinDuration = 1 hours;
uint256 public auctionMaxDuration = 30 days;

function createAuction(uint256 tokenId, uint256 duration) external ... {
    require(duration >= auctionMinDuration, "Duration too short");
    require(duration <= auctionMaxDuration, "Duration too long");
    ...
}
```

---

<a id="m-03"></a>
### [M-03] `cancelAuction` does not return the NFT to the seller

**Severity**: Medium
**Category**: Business Logic Error — Locked Asset
**Location**: [MarketPlace.sol#L155-L173](file:///home/rimuru/Projects/miniapp-contracts/reauction-contracts/src/MarketPlace.sol#L155-L173)

#### Description

When an auction is cancelled, the function refunds the highest bidder and updates state, but **never transfers the NFT back to the seller**. The NFT remains locked in the contract with no mechanism to retrieve it.

Compare with `cancelListing` (L254) which correctly calls `_pushNFT(address(this), listing.seller, tokenId)`, and `Auction.sol` which calls `_sendNFT(tokenId, creator)`.

```solidity
function cancelAuction(uint256 tokenId) external onlyOnSale(tokenId) {
    // ... refunds highest bidder ...
    auction.state = AuctionState.Cancelled;
    activeAuctionId[tokenId] = 0;
    isTokenOnSale[tokenId] = false;
    // ← Missing: _pushNFT(address(this), auction.seller, tokenId);
}
```

#### Impact

**Permanent loss of NFT** for any seller who cancels their auction. The token is stuck in the contract with no recovery path.

#### Recommendation

```diff
  activeAuctionId[tokenId] = 0;
  isTokenOnSale[tokenId] = false;
+ _pushNFT(address(this), auction.seller, tokenId);

  emit AuctionCancelled(tokenId, auctionId);
```

---

<a id="m-04"></a>
### [M-04] No reentrancy protection on any function

**Severity**: Medium
**Category**: Reentrancy (SWC-107)
**Location**: Entire contract

#### Description

The contract makes multiple external calls (USDC `transfer`/`transferFrom`, NFT `safeTransferFrom`/`transferFrom`) without any reentrancy guard. While USDC on Base does not have reentrancy hooks, the `ICollectibleCasts` contract could potentially have callbacks (especially via `safeTransferFrom`), and if the USDC address is ever changed or wrapped, reentrancy becomes possible.

The `Auction.sol` contract uses `ReentrancyGuardUpgradeable` for defense-in-depth. This contract has none.

Several functions also violate CEI (Checks-Effects-Interactions):
- `cancelAuction` (L164): `_pushPayment` before state updates (L166-170)
- `settleAuction` (L187-194): external NFT transfer and payment before state updates (L197-199)
- `purchaseItem` (L226-234): external calls before state updates (L237-239)

#### Impact

If the NFT contract or a future USDC implementation has callbacks, an attacker could re-enter and exploit the pre-update state.

#### Recommendation

1. Add OpenZeppelin `ReentrancyGuard` and apply `nonReentrant` to all public functions
2. Reorder all functions to follow CEI (Checks-Effects-Interactions)

```diff
+ import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

- contract MarketPlace is AccessControl {
+ contract MarketPlace is AccessControl, ReentrancyGuard {
```

---

## Low / Informational Findings

<a id="l-01"></a>
### [L-01] Admin setters lack bounds validation

**Severity**: Low
**Category**: Centralization Risk / Missing Validation
**Location**: [MarketPlace.sol#L293-L329](file:///home/rimuru/Projects/miniapp-contracts/reauction-contracts/src/MarketPlace.sol#L293-L329)

#### Description

- `setProtocolFee` allows setting `protocolFeeBps` up to `type(uint256).max` — a fee of 100% or more would make `amountToSettle` underflow (though Solidity 0.8 would revert, it still makes the marketplace non-functional)
- `setAuctionMinBidIncrementBps` has no upper bound
- No lower bound on `auctionDurationExtension` or `auctionDurationExtensionThreshold`

Compare with `Auction.sol` which validates all config parameters.

#### Recommendation

Add bounds checks:
```solidity
require(protocolFeeBps_ <= BPS_DENOMINATOR, "Fee too high");
require(auctionMinBidIncrementBps_ <= BPS_DENOMINATOR, "Increment too high");
```

---

<a id="l-02"></a>
### [L-02] `setAuctionMinBidAmount` records wrong `oldValue`

**Severity**: Low
**Category**: Logic Error
**Location**: [MarketPlace.sol#L301](file:///home/rimuru/Projects/miniapp-contracts/reauction-contracts/src/MarketPlace.sol#L301)

#### Description

```solidity
function setAuctionMinBidAmount(uint256 auctionMinBidAmount_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 oldValue = auctionMinBidAmount_; // ← BUG: should be auctionMinBidAmount (state var)
    auctionMinBidAmount = auctionMinBidAmount_;
    emit AuctionMinBidAmountUpdated(oldValue, auctionMinBidAmount_);
}
```

`oldValue` is assigned the **input parameter** instead of the **current state variable**. The emitted event will always show `oldValue == newValue`.

#### Recommendation

```diff
- uint256 oldValue = auctionMinBidAmount_;
+ uint256 oldValue = auctionMinBidAmount;
```

---

<a id="l-03"></a>
### [L-03] Missing error messages on `require` statements

**Severity**: Low
**Category**: Code Quality
**Location**: [MarketPlace.sol#L67](file:///home/rimuru/Projects/miniapp-contracts/reauction-contracts/src/MarketPlace.sol#L67), [L72](file:///home/rimuru/Projects/miniapp-contracts/reauction-contracts/src/MarketPlace.sol#L72)

`onlyNotOnSale` and `onlyOnSale` modifiers have bare `require` statements without error messages, making debugging and UX difficult.

---

<a id="l-04"></a>
### [L-04] `purchaseItem` does not verify listing is in `Active` state

**Severity**: Low
**Category**: Missing State Validation
**Location**: [MarketPlace.sol#L217-L242](file:///home/rimuru/Projects/miniapp-contracts/reauction-contracts/src/MarketPlace.sol#L217-L242)

#### Description

`purchaseItem` only checks `onlyOnSale(tokenId)` via the global `isTokenOnSale` mapping but does not verify that `listing.state == ListingState.Active`. While the `isTokenOnSale` flag is reset on purchase/cancel, relying on a single flag rather than the canonical state introduces a trust gap.

#### Recommendation

Add explicit state check:
```solidity
require(listing.state == ListingState.Active, "Listing not active");
```

---

<a id="i-01"></a>
### [I-01] No `IERC165.supportsInterface` for ERC-721 receiver

**Severity**: Informational

The contract inherits `AccessControl` which implements `supportsInterface`, but it does not declare support for `IERC721Receiver`. After fixing H-01, if inheriting `ERC721Holder`, this is handled automatically.

---

<a id="i-02"></a>
### [I-02] Shared `isTokenOnSale` across auctions and listings

**Severity**: Informational

A single `isTokenOnSale[tokenId]` flag is used for both auctions and listings. If a bug in one path fails to clear the flag, the token is locked from both flows. Consider using separate flags or a more explicit mechanism.

---

<a id="i-03"></a>
### [I-03] Missing zero-address checks in constructor

**Severity**: Informational

The constructor does not validate that `usdc_`, `collectibles_`, or `admin_` are non-zero. Compare with `Auction.sol` which validates all constructor addresses.

```solidity
require(usdc_ != address(0), "Zero address");
require(collectibles_ != address(0), "Zero address");
require(admin_ != address(0), "Zero address");
```

---

## Gas Optimizations

| ID | Description | Savings |
|---|---|---|
| G-01 | Modifier logic in `onlyMinted`, `onlyNotOnSale`, `onlyOnSale` should be wrapped in internal functions per Foundry lint recommendation | ~200 gas per call site |
| G-02 | `protocolFeeBps` is `uint256` but BPS values only need `uint16` — packing with other storage would save gas | 1 SLOAD per read |
| G-03 | `feeAccrued` in `collectProtocolFees` should be set to 0 before the external call (CEI) but also avoids re-reading storage | Marginal |

---

## Comparison with `Auction.sol`

The `Auction.sol` contract in the same repository is significantly more mature. Key differences:

| Feature | `MarketPlace.sol` | `Auction.sol` |
|---|---|---|
| Reentrancy Guard | ❌ None | ✅ `ReentrancyGuardUpgradeable` |
| Pausable | ❌ None | ✅ `PausableUpgradeable` |
| ERC721 Receiver | ❌ Missing | ✅ `ERC721HolderUpgradeable` |
| Pull-over-push for refunds | ❌ Direct push | ✅ `pendingWithdrawals` pattern |
| Duration validation | ❌ None | ✅ min/max enforced |
| Config validation | ❌ No bounds | ✅ Full bounds checking |
| NFT return on cancel | ❌ Missing | ✅ Implemented |
| Payment recipient | ❌ **Wrong** | ✅ Correct |
| CEI compliance | ❌ Multiple violations | ✅ Mostly compliant |

> [!IMPORTANT]
> `MarketPlace.sol` appears to be an early draft. It is strongly recommended to **not deploy** this contract and instead extend or refactor `Auction.sol`, which already implements the same functionality with proper security patterns.

---

## Recommendations Summary

### Must Fix Before Deployment (Critical/High)

1. **Fix payment recipients** in `settleAuction` (→ `auction.seller`) and `purchaseItem` (→ `listing.seller`)
2. **Add `ERC721Holder`** inheritance so the contract can receive NFTs
3. **Check return value** of `USDC.transfer` in `collectProtocolFees`

### Strongly Recommended (Medium)

4. **Add `ReentrancyGuard`** and enforce CEI ordering in all functions
5. **Return NFT to seller** in `cancelAuction`
6. **Add auction duration bounds** (min/max)
7. **Fix same-bidder bid stacking** to enforce increment on total

### Should Fix (Low)

8. Add bounds validation to all admin setters
9. Fix `oldValue` bug in `setAuctionMinBidAmount`
10. Add error messages to all `require` statements
11. Add zero-address checks in constructor

---

> [!NOTE]
> This audit is a manual review of a single contract. It does not guarantee the absence of all vulnerabilities. Formal verification, fuzzing (Foundry/Echidna), and a professional third-party audit are recommended before mainnet deployment.
