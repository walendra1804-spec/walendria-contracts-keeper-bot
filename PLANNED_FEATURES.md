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

## Percentage-based pokeSettlement bounty (0.1% of P), paid from the market surplus

**Status:** Agreed in principle (2026-07-07 discussion) — not started.

**What:** Replace the fixed `pokeBounty` constant with a bounty proportional to the transaction's own price
P, so the incentive scales with dispute size instead of one constant that is oversized for a tiny transaction
and undersized for a huge one. Set it at **0.1% of P** (`pokeBountyBps = 10`), and **source it from the
market's own settlement surplus** — the residual pool that already flows to the Developer Pool under
whitepaper Section 2.6.6 once a resolved market has paid its winning shares. At settlement the surplus is
split: **0.1% of P skimmed to whoever successfully called `pokeSettlement`, the remainder to the Developer
Pool (the founder wallet) exactly as today.** No separately-funded `bountyPool`, and no `DeveloperPool`
gas-floor pull — both are removed by this change.

**Why 0.1%, and why from the surplus (2026-07-07 decision):** an earlier sketch in this file paid a 1%
bounty from a manually-funded `bountyPool`, topped up from the Developer Pool when short. The user replaced
both choices: the rate drops to 0.1%, and the source becomes the market surplus itself, so the bounty is
paid out of money the dispute's own trading generated rather than a pre-funded pot that has to be replenished
(today's live failure mode: `bountyPool` is currently 0 on Chiado, so a poke pays nothing). This also deletes
more code than it adds — `bountyPool`, `fundBounty()`, and the `DeveloperPool` gas-floor pull all disappear,
on top of the liquidity-buffer cascade above.

**Design sketch:**
```solidity
// SettlementConditions.sol — replace the fixed pokeBounty constant with a bps rate:
uint256 public immutable pokeBountyBps;   // 10 = 0.1% of P (b == P at open, Section 2.6.4)

// At resolution (inside pokeSettlement, or wherever the surplus is finalized), before the surplus
// is swept to the Developer Pool:
//   uint256 surplus     = totalPooled - totalWinningPayout;      // >= 0 by construction
//   uint256 bounty      = (b * pokeBountyBps) / 10_000;          // 0.1% of P
//   uint256 paidToPoker = bounty <= surplus ? bounty : surplus;  // capped at what the surplus holds
//   // pay paidToPoker to the poke caller; sweep (surplus - paidToPoker) to the Developer Pool
```

**The one real open question — surplus shortfall in a quiet dispute.** The surplus is *not* a fixed 0.1%; it
is whatever losing trades left behind after winners are paid $1/share (Section 2.6.6). In a contested dispute
with real counter-trading it is comfortably larger than 0.1% of P. But in a *quiet* dispute — the base case
where only the two forced initial positions ever trade — the winning side's payout consumes almost the whole
~1P pool, so the surplus is near zero (whitepaper Section 3.2: the winner "recovers approximately 1P"). There
`paidToPoker` is capped near zero: little or nothing in the surplus to pay a poker. This is the exact liveness
case the old gas-floor was invented to protect, reopened by sourcing purely from the surplus. Two coherent
resolutions, decide before coding:
  1. **Accept it — rely on the winner self-poking.** In a quiet dispute the winner has their own full payout
     waiting behind the poke, so they are strongly motivated to call it themselves; the external bounty is
     redundant there and only matters when the winner is passive. Simplest, and consistent with the "no
     artificial floor, everything from the market" philosophy — but it makes whitepaper 2.6.8's current claim
     ("any address, at any time, can *profitably* call pokeSettlement") false for a zero-surplus dispute
     poked by a non-winner, so that prose would need softening.
  2. **Keep a minimal floor** drawn from the Developer Pool's accumulated fees (not the per-market surplus)
     only when the surplus can't cover the bounty — the old gas-floor idea, but funded from the founder's own
     accrued 0.5% fees rather than a dedicated pool. Preserves 2.6.8's guarantee verbatim, at the cost of the
     founder occasionally subsidizing a tiny quiet poke.

**Other open questions:**
- Confirm the intended split: this entry treats "0.5% to founder" (user's words) as the *existing* Developer
  take (0.5% fee in 2.7 + the rest of the surplus in 2.6.6), NOT a new second 0.5% skim from the surplus. If
  the user meant a distinct additional 0.5% carved from the surplus alongside the 0.1% poke, revisit here.
- `pokeBountyBps` wants a sanity check against real gas: 0.1% of a very small P may be below the gas cost of
  the call itself, which is exactly why resolution (1) leans on the winner's own incentive for tiny quiet
  disputes. `forge test --gas-report` on `pokeSettlement` against Chiado's actual gas price, not a guess.
- **Whitepaper sync:** this change makes the Abstract (para 4), Section 2.6.6, and Section 2.6.8 point 5 of
  v28 stale — they still describe the old "gas-cost floor drawn from the Developer Pool" design. Reconcile
  them with 0.1%-from-surplus once the shortfall question above is decided (the prose can't be finalized
  before the mechanism is). Do NOT leave v28 claiming a mechanism the contracts won't implement.
- **App-side:** `PokeCard.tsx` shows `min(pokeBounty, bountyPool)` today — needs rewriting to show 0.1% of P
  (and, if resolution (1) is chosen, to explain the bounty may be ~0 in a quiet dispute where the winner is
  expected to self-poke).

---

## Immutable per-transaction value hardcap (bug blast-radius ceiling)

**Status:** Agreed in principle (2026-07-07 discussion). Whitepaper v28 Section 9 and Section 10 already
reflect this (they replaced the earlier "deploy only after independent audit" promise); contracts do not
implement it yet.

**What:** A single immutable ceiling, fixed at deployment in bytecode, on the value any one transaction may
carry — enforced in the payment path so no transaction for a price P above the cap can settle. Because every
downstream amount (Locked IB at 1.5P, dispute stakes at 0.5P, market depth at 1P, IB slashing at 1.5P) is a
multiple of P, capping P caps the total value any single exploited code path can put at risk.

**Why (this is the audit replacement, not a supplement to it):** the user rejects paid audit firms and public
bug bounties (memory `project_no_paid_audit`). This hardcap is the deliberate substitute: rather than claim a
bug-freeness no audit can actually establish, bound what any latent bug can *cost*. It is a disclosed,
deliberately-chosen worst-case exposure ceiling, in the same "bound and disclose the residual risk rather
than deny it" spirit as the Boundary Theorem (Section 2.6.9).

**Constraints to preserve:**
- **Immutable, not admin-adjustable.** The cap is a deployment constant, never a settable parameter — a
  settable cap would be exactly the admin key Section 2.8 forbids. Raising it is done only by deploying a
  fresh contract at a new address that users consciously adopt (the staged-redeployment path Section 2.8
  already describes for any logic change). Start low on mainnet, prove it out, redeploy higher.
- The check belongs in the atomic settlement path — reject at `createListing` (clear seller-side error) AND
  keep a defensive check at `pay` so the invariant holds even for a listing that predates the cap. Fail
  closed, before any state that assumes the payment is valid.

**Open questions before implementing:**
- The cap value is a launch-time decision, deliberately conservative for a first mainnet deployment, and
  re-derived (not reused) per deployment — same discipline Section 2.9 already demands for threshold/b.
- Whether the cap is denominated in the chain's native unit (xDAI) directly, given the protocol has no price
  oracle by design — leaning yes (native unit, no oracle), consistent with everything else being P-relative.
