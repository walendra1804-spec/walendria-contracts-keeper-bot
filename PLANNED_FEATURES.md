# Planned Features / Changes

A backlog of features and changes that have been discussed and are worth doing, but are **not yet
implemented**. Each entry should have enough detail that implementation can start directly from this file
without re-deriving the reasoning. Move an entry to a commit message / whitepaper section once it ships,
and delete it from here.

---

## First-visit onboarding popup (walendria-app)

A dismissible popup on first visit that asks the newcomer two questions and routes them into a tutorial
written for the answer, instead of dropping them into a protocol homepage written for people who already
know what an Integrity Bond is.

- **Q1: "Is this your first time here?"** Skip the whole thing on "no", and remember that in
  `localStorage` so it never fires twice for the same browser.
- **Q2: "Which jual-beli world are you coming from?"** Free-text plus a few known options (Roblox
  top-up / Blox Fruits / Blade Ball / Free Fire / other). The answer selects which worked example the
  tutorial uses, so the reader sees their own goods in the walkthrough rather than an abstract "item".
- **The tutorial itself** runs end to end, hulu ke hilir: get a wallet, get xDAI into it, get a listing ID
  from the seller, pay through the contract, confirm completion or open a dispute. Tone is friendly and
  plain — the audience has never touched crypto and will quit at the first unexplained word. Indonesian
  first, since `/id` is the entry point this is meant to serve.
- Must not `setState` synchronously inside a `useEffect` (repo lint rule `react-hooks/set-state-in-effect`);
  read `localStorage` in an event handler or via `useSyncExternalStore`.
- Should degrade to nothing with JS disabled, and must not block the page for a returning visitor.

Deferred deliberately: the tutorial is only worth writing once the funding path it describes is settled,
otherwise it documents a route that is about to change.

---

Recently shipped (removed from the backlog once implemented):

- **Seller-initiated completion window extension** — `ListingManager.extendWindow(listingId, slotIndex,
  newWindow)`. Per-slot, seller-only, monotonic (can only lengthen, never below the 72h floor). Works on both
  an Empty slot (pre-setting its next buyer's window) and a live PaymentConfirmed slot (pushing the deadline
  out immediately). Per-sale: the override clears when a slot recycles. Stored in a standalone
  `slotWindowOverride` mapping so the public `slots` getter's shape stayed unchanged. Surfaced in the app on
  the per-listing slots page, and in wallet History / Notifications via the `SlotWindowExtended` event.
