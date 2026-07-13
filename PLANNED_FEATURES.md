# Planned Features / Changes

A backlog of features and changes that have been discussed and are worth doing, but are **not yet
implemented**. Each entry should have enough detail that implementation can start directly from this file
without re-deriving the reasoning. Move an entry to a commit message / whitepaper section once it ships,
and delete it from here.

---

_Backlog is currently empty._

Recently shipped (removed from the backlog once implemented):

- **Seller-initiated completion window extension** — `ListingManager.extendWindow(listingId, slotIndex,
  newWindow)`. Per-slot, seller-only, monotonic (can only lengthen, never below the 72h floor). Works on both
  an Empty slot (pre-setting its next buyer's window) and a live PaymentConfirmed slot (pushing the deadline
  out immediately). Per-sale: the override clears when a slot recycles. Stored in a standalone
  `slotWindowOverride` mapping so the public `slots` getter's shape stayed unchanged. Surfaced in the app on
  the per-listing slots page, and in wallet History / Notifications via the `SlotWindowExtended` event.
