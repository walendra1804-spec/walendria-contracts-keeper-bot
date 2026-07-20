# Planned Features / Changes

A backlog of features and changes that have been discussed and are worth doing, but are **not yet
implemented**. Each entry should have enough detail that implementation can start directly from this file
without re-deriving the reasoning. Move an entry to a commit message / whitepaper section once it ships,
and delete it from here.

---

- **Whitepaper erratum — Section 3.2 / Section 4 "breakeven" is wrong, should be +0.5P.** In the base
  innocent case (forced positions only, no third-party trading), a seller who is falsely disputed and
  vindicated nets **+0.5P better** than a no-dispute transaction, not "approximately breakeven". Worked:
  the seller's 0.5P Innocent position (drawn from Locked IB) redeems ~1P from the 1P pool — their own 0.5P
  back plus the forfeited 0.5P Guilty stake — while the remaining 1.0P Locked IB unlocks untouched; net
  vs. the no-dispute baseline = +0.5P, credited to the seller's wallet. Fix two places: (1) Section 3.2's
  "Seller net: approximately breakeven relative to a transaction with no dispute at all" line, and (2) the
  Section 4 payoff table's two "False dispute … resolves correctly" rows, which read "~ +0.995P (breakeven
  vs. no-dispute baseline)" and should reflect the +0.5P gain. The article `stop-paying-to-be-trusted`
  already states the correct +0.5P outcome, so this is a whitepaper-only correction that brings it into
  line with the article and the contract behavior — deferred here (not done inline) because the whitepaper
  is notarized on Gnosis mainnet (tx 0x0acc13f5…, block 47264479, sha256 6a7fb075…) and published on
  Zenodo (DOI 10.5281/zenodo.21398696): editing the `.md` desyncs both, so it must be batched into the
  next whitepaper revision and shipped through the full re-hash → re-notarize (`cast send` from the
  deployer wallet) → new Zenodo version → update `priorityDocuments.ts` cycle in one pass. See the
  "Priority protection — DocumentNotary + Zenodo runbook" section of CLAUDE.md for the exact steps.

Recently shipped (removed from the backlog once implemented):

Recently shipped (removed from the backlog once implemented):

- **Seller-initiated completion window extension** — `ListingManager.extendWindow(listingId, slotIndex,
  newWindow)`. Per-slot, seller-only, monotonic (can only lengthen, never below the 72h floor). Works on both
  an Empty slot (pre-setting its next buyer's window) and a live PaymentConfirmed slot (pushing the deadline
  out immediately). Per-sale: the override clears when a slot recycles. Stored in a standalone
  `slotWindowOverride` mapping so the public `slots` getter's shape stayed unchanged. Surfaced in the app on
  the per-listing slots page, and in wallet History / Notifications via the `SlotWindowExtended` event.
