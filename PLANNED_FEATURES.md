# Planned Features / Changes

A backlog of features and changes that have been discussed and are worth doing, but are **not yet
implemented**. Each entry should have enough detail that implementation can start directly from this file
without re-deriving the reasoning. Move an entry to a commit message / whitepaper section once it ships,
and delete it from here.

---

## QRIS mutation poller for the top-up desk (walendria-app)

The desk at `/topup` ships complete except for one leg: nothing reads the merchant account, so payments are
confirmed by hand from `/topup/admin`. Everything else — order ledger, unique-nominal allocation, two-tier
admission, the dynamic-QRIS converter, the buyer status page — is built and tested. This entry is only the
automation on top.

- **Blocked on an account, not on code.** OkeConnect is the H2H side of OrderKuota, and registration
  requires the OrderKuota Android app (Play Store only, no iOS build, and the web dashboard only serves
  accounts that already exist). Until there is Android access — emulator, borrowed handset, or a cheap
  used device — the credentials cannot be obtained. Once they are: dashboard → Payment H2H → API
  Integration gives a Merchant Code and API Key plus the mutation endpoint's real spec. **Copy that spec
  from the dashboard rather than from any third-party write-up**; it is an unofficial API and it moves.
- **Where it plugs in.** A worker polls the mutation list every 10-20s and, on an exact `totalIdr` match
  against an order whose code is still held, calls the same `markPaid(id)` the admin console already calls.
  That function is idempotent, so a duplicate poll cannot double-credit. The admin console stays as the
  override for anything the poller cannot match.
- **Idempotency is the load-bearing part.** Persist every mutation ID ever seen and mark it consumed in the
  same write as the status change. Without that, a worker restart mid-send pays twice, and the money is
  genuinely gone.
- **Own pm2 process, own `.env`.** Not folded into keeper-bot: the keeper holds a token amount and can
  restart freely, while this worker holds real float and its failure costs a buyer their goods. Different
  blast radius, different process.
- **Auto-send is a second, separate step.** Watch the hot wallet balance and drain `PAID` orders oldest
  first across both tiers when it rises. Cap per-order and per-day in code, so a compromised VPS key loses
  a day's float rather than the wallet.
- **Unmatched money must never be dropped.** An incoming nominal matching no order goes to an `unmatched`
  table and pings the operator. It is somebody's money.
- Credentials go in `.env.local` **without** a `NEXT_PUBLIC_` prefix, and polling never runs from a page
  request — a page load must not be able to hit the provider's rate limit.

Before any of this: **measure the real restock round-trip** (rupiah → CEX → xDAI on Gnosis, timed end to
end with the smallest possible amount). The 12-hour promise in `TOPUP_LIMITS.scheduledWindowMs` is a
guess until that number exists, and it is worse to publish a window that is missed than to publish a
longer one that is kept. If the CEX cannot withdraw natively on Gnosis and a bridge is involved, the
window has to be set from the bridged timing, not the direct one.

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
