# Planned Features / Changes

A backlog of features and changes that have been discussed and are worth doing, but are **not yet
implemented**. Each entry should have enough detail that implementation can start directly from this file
without re-deriving the reasoning. Move an entry to a commit message / whitepaper section once it ships,
and delete it from here.

---

## Seller-initiated completion window extension

**Status:** Not started. Contracts, app, and docs all need changes.

**What:** Let a seller voluntarily push out `completionDeadline` for one of their own
`PaymentConfirmed` slots, any time before it expires.

**Why this is safe, not a risk:**
- The completion window only exists to protect the *buyer* — it's the deadline by which they must call
  `fundGuiltySide` if something's wrong, or lose that right forever (Section 2.5). A longer window is
  strictly more time for the buyer to notice a problem and act. There is no direction in which extending it
  helps a dishonest seller: it cannot shorten the buyer's reaction time, cannot un-freeze a slot that's
  already `Disputed`, and cannot claw back anything already paid.
- The only capital cost of a longer window is the seller's *own* Locked IB staying locked longer — that's
  self-inflicted, not something imposed on the buyer or the protocol.
- It doubles as a trust signal: a seller who proactively extends the window (e.g. because a delivery is
  running late) is visibly giving the buyer *more* protection, not less. Worth surfacing this in the UI as a
  positive indicator, not just a passive deadline change.

**Design sketch (`ListingManager.sol`):**
```solidity
event WindowExtended(uint256 indexed listingId, uint256 indexed slotIndex, uint256 newDeadline);

error NotSeller(address caller, address seller);          // already exists
error DeadlineNotLater(uint256 current, uint256 attempted);
error SlotNotPaymentConfirmed(uint256 listingId, uint256 slotIndex); // already exists

function extendWindow(uint256 listingId, uint256 slotIndex, uint256 newDeadline) external {
    Listing storage listing = _requireListing(listingId);
    if (msg.sender != listing.seller) revert NotSeller(msg.sender, listing.seller);

    Slot storage slot = slots[listingId][slotIndex];
    if (slot.status != SlotStatus.PaymentConfirmed) revert SlotNotPaymentConfirmed(listingId, slotIndex);
    if (newDeadline <= slot.completionDeadline) revert DeadlineNotLater(slot.completionDeadline, newDeadline);

    slot.completionDeadline = newDeadline;
    emit WindowExtended(listingId, slotIndex, newDeadline);
}
```

**Constraints to preserve:**
- Seller-only (`msg.sender == listing.seller`) — this is a favor the seller opts into, not something a
  buyer or third party should be able to force or block.
- Only while `status == PaymentConfirmed`. Once `Disputed`, the window is already permanently frozen and
  irrelevant to finalization (Section 2.5's "a dispute freezes the window" rule) — extending it then would
  be meaningless, so the status check alone already blocks it correctly.
- Monotonic only: `newDeadline` must be strictly greater than the current `completionDeadline`. Never allow
  shortening it through this function — that would undo the one protection this feature is supposed to add.
- No upper cap needed on the extension length or how many times it's called — every extension is
  buyer-favorable by construction, so there's no protocol-level reason to limit it. (A seller who extends
  forever only ties up their own bond forever; that's their own cost to bear, not an attack surface.)

**Open questions before implementing:**
- Should this be callable after the original deadline has *already* passed but before anyone has called
  `finalizeExpiredSlot` yet (i.e. can a seller "revive" a slot that's technically expired but not yet
  finalized)? Leaning yes — same reasoning applies (still strictly buyer-favorable, and permissionless
  `finalizeExpiredSlot` racing against this extension is an acceptable, symmetric outcome), but should be a
  deliberate decision, not an accident of the `<=` check above.
- Whitepaper needs a new subsection once this ships (Section 2.5 currently states the window as fixed at
  creation time).

**App-side work once the contract change ships:**
- A button/form somewhere in `SellerDashboard.tsx` (or a new per-slot seller view) to call `extendWindow`.
- Surface the new deadline (and ideally the `WindowExtended` event history) on the dispute detail page
  (`/disputes/[listingId]/[slotIndex]`) next to `CompletionWindowTimer`, so a buyer watching that page sees
  the extension happen live — this is the "buyer trust" signal from the rationale above, and it only works
  if it's actually visible.
- Rules page (`/rules`) needs a new bullet under "How to be a correct Seller" once this ships.

---

## Remove the Protocol Liquidity Buffer ($5 depth top-up)

**Status:** Agreed in principle (2026-07-07 discussion) — not started. Whitepaper v28 already reflects this
decision; contracts do not yet.

**What:** Delete the mechanism that tops up a dispute's initial market depth to a $5-equivalent floor
whenever `halfPrice * 2` (Section 2.6.7) would otherwise fall short — `DisputeManager._pullLiquidityBufferIfNeeded`
and everything that exists only to support it.

**Why:** The floor was originally added out of concern that thin-liquidity disputes wouldn't attract
traders. Two separate arguments were weighed:
1. **Security (self-dealing) — not a reason to keep it.** The Boundary Theorem (whitepaper Section 2.6.9)
   is scale-invariant: H(p) is proportional to `b`, which is itself proportional to P (`b = 1 * P`), so the
   ratio between "capital needed to force an uncontested resolution" and "capital a manipulator realistically
   has" is identical at any transaction size. The $5 floor never protected this ratio.
2. **Genuine market-depth/participation — a real trade-off, kept, but not as the stated reason.** A thinner
   market is easier for one small trade to move, which is a real cost for small-P disputes. The decision to
   remove the floor anyway is a **principled** one, not a claim that this cost doesn't exist: Walendria
   imposes no minimum transaction size anywhere in the world, and a fixed-dollar floor is an implicitly
   culturally-relative judgment about what counts as a "meaningful" amount of money. **Do not write the
   removal rationale as "$5 is small at realistic/mainnet scale" — that framing was rejected explicitly.**
   The correct rationale is reason 1 above, plus the principled "no artificial floor, ever" stance — see
   whitepaper v28 Section 2.6.7 for the exact wording to reuse in commit messages / code comments.

**Scope — this removal cascades further than the one call site**, since the liquidity buffer was the
*only* reason `developerPool` ever held shares in a Spectral Market. Once it's gone, the following become
dead code and should be removed in the same change, not left orphaned:
- `DeveloperPool.pullLiquidityBuffer` (nothing will call it)
- `DeveloperPool.redeemFromMarket` and its auto-trigger in `DisputeManager._finalize` (nothing for
  DeveloperPool to ever redeem — it will never hold shares)
- `SpectralMarket`'s DeveloperPool exemption from `distinctHolderCount`/`_markHolder` tracking (no longer a
  holder at all, exempt or otherwise)
- `DisputeManager._buildGuiltyArrays` / `_buildInnocentArrays`'s DeveloperPool branch (simplifies to just
  the recorded funders / the seller, no extra array entry)
- `MIN_LIQUIDITY_DEPTH` constant and `LiquidityBufferToppedUp` event

**Open questions before implementing:**
- Confirm `openMarket`'s array-based signature (added specifically to support the joint DeveloperPool
  credit) doesn't need anything else once this simplifies — it may collapse back toward a simpler shape.
- Full regression pass needed on every test that asserts DeveloperPool involvement in a Spectral Market
  (`DeveloperPool.t.sol`, `DisputeManager.t.sol`, `Integration.t.sol`, and the live adversarial scripts from
  Phase 11 that specifically isolated DeveloperPool's top-up as a confound — those tests' *reasoning* about
  why they subtracted DeveloperPool's shares becomes moot, not just their assertions).

---

## Percentage-based pokeSettlement bounty with a gas-cost floor

**Status:** Agreed in principle (2026-07-07 discussion) — not started.

**What:** Replace the fixed `pokeBounty` constant with a bounty proportional to the transaction's own price
P, so the incentive scales with dispute size instead of being one constant that's oversized for a tiny
transaction and potentially undersized for a huge one. Add a floor beneath it so the bounty never falls
below what it actually costs in gas to call `pokeSettlement` — otherwise a percentage-based bounty makes
tiny disputes (which this protocol explicitly supports, see the liquidity-buffer removal above) *worse* to
poke than today's flawed-but-fixed amount, undermining Section 2.6.8's permissionless-resolution guarantee
for exactly the transactions this protocol just committed to treating as first-class.

**Why not pure percentage (rejected):** gas cost to call `pokeSettlement` doesn't shrink with P. A pure
percentage bounty on a very small P could be smaller than the gas needed to submit the call, so nobody would
ever bother — worse than the current oversized-but-workable fixed 0.001 xDAI, not better.

**Design sketch:**
```solidity
// SettlementConditions.sol — replace the immutable pokeBounty constant:
uint256 public immutable pokeBountyBps;      // e.g. 100 = 1% of the transaction's b (b == P at open, Section 2.6.4)
uint256 public immutable pokeGasFloor;       // deployment-time estimate: measured pokeSettlement gas cost * expected gas price + margin

function _computeBounty(uint256 marketId) internal view returns (uint256) {
    (uint256 b, , , , , ,) = spectralMarket.markets(marketId);   // b == P at market-open time
    uint256 percentageBounty = (b * pokeBountyBps) / 10_000;
    return percentageBounty > pokeGasFloor ? percentageBounty : pokeGasFloor;
}
```
At payout time in `pokeSettlement`: keep `bountyPool`/`fundBounty()` exactly as they work today for the
normal case (`min(computedBounty, bountyPool)`), but when `bountyPool` can't cover the full computed amount,
pull the shortfall on demand from `developerPool` — the same on-demand, capped-at-available pull pattern
`pullLiquidityBuffer` already used (before its removal above), just repurposed for this instead of deleted
outright. This draw should be small and rare by construction: it only ever fires when a transaction is small
enough that even a fair percentage doesn't clear gas cost, or when `bountyPool` itself happens to be
underfunded (today's actual failure mode, confirmed live: `bountyPool` is currently 0 on Chiado).

**Open questions before implementing:**
- Exact `pokeBountyBps` and `pokeGasFloor` values need real gas profiling (`forge test --gas-report` on
  `pokeSettlement`) against this deployment's actual gas price, not a guess.
- Whether `developerPool` needs a new dedicated function for this pull (e.g. `pullBountyShortfall`) or can
  reuse a generalized version of the same pull-capped-at-available primitive `pullLiquidityBuffer` used —
  leaning toward one generalized primitive rather than two near-identical ones, decide at implementation time.
- Whitepaper v28 Section 2.6.8 point 5 already reflects this design in prose; keep it in sync if the exact
  mechanism changes during implementation.
- App-side: `PokeCard.tsx` already shows the real `min(pokeBounty, bountyPool)` payout (fixed 2026-07-07) —
  needs updating again once the bounty computation itself changes to the percentage+floor formula.
