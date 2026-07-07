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
