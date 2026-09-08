# Planned Features / Changes

A backlog of features and changes that have been discussed and are worth doing, but are **not yet
implemented**. Each entry should have enough detail that implementation can start directly from this file
without re-deriving the reasoning. Move an entry to a commit message / whitepaper section once it ships,
and delete it from here.

---

## Let a settled dispute be closed by agreement even after outsiders traded (walendria-contracts)

`DisputeManager.mutualClose` is permanently disabled for a dispute the moment any address other than the
buyer and the seller has *ever* held a position in its market. `_requireNoThirdParty` reads
`SpectralMarket.distinctHolderCount`, which is monotonic and never decremented, so an outside trader who
bought and then fully exited leaves the path closed forever. That is deliberate and correct as written: if
two parties could close a market that still held a stranger's money, they could agree on whichever verdict
zeroed that stranger's position.

**What it costs in practice, and why this is worth revisiting.** Two parties who reconcile after an outsider
has traded have exactly one route left: buy the agreed side up to the 93% threshold, wait out
`CUMULATIVE_DURATION`, and let anyone poke. That route is permissionless, so nobody can be held hostage by a
counterparty who walks away, and the pusher recovers nearly all of the outlay by redeeming. But it costs
`P * ln((e^x + 1) / 2)` where `x = ln(0.93/0.07)`, which is **~1.97 * P of working capital** held for an
hour, and it always ends with a winner and a loser. There is no draw. Whichever verdict they agree on, the
0.5P that funded the Guilty side transfers to the other party.

**The part that is a real risk, not just an inconvenience.** Restoring the draw means the winner sending
0.5P back off-chain, by ordinary transfer, on nothing but their word. That is precisely the trust the whole
protocol exists to remove, reintroduced at the last step and at the worst moment: the buyer has just been
persuaded to accept an Innocent verdict, and the only thing standing between them and losing 0.5P is a
counterparty who has already left the on-chain flow and has no further obligation the contracts can see. A
seller who intended to walk has every reason to push for reconciliation first. So "they made peace" and "the
buyer got their money back" are not the same event, and the protocol currently cannot tell them apart.

**Shape of a fix, for the next deployment.** Not settled, and deliberately not designed here beyond the
constraint it has to satisfy: any relaxation must make the outside traders whole from the market itself
before the two parties may close it, so that closing by agreement is never a way to reach into a third
party's position. One candidate is a `mutualCloseWithRefund` that requires every address in
`distinctHolderCount` beyond the two parties to hold a zero balance AND to have been bought out at the
last traded price, funded by the closing parties. Another is a genuine draw verdict that returns each side's
0.5P instead of paying one side, which removes the off-chain settlement entirely and is probably the more
honest primitive, but it changes `_finalize`, the `Side` enum, and every test that destructures a verdict.

Whichever is chosen, it is a redeploy at new addresses (the deployment is immutable), so it belongs in the
same batch as any other contract change rather than on its own.

---

## QRIS mutation poller for the top-up desk (walendria-app)

The desk at `/topup` ships complete except for one leg: nothing reads the merchant account, so payments are
confirmed by hand from `/topup/admin`. Everything else — order ledger, unique-nominal allocation, two-tier
admission, the dynamic-QRIS converter, the buyer status page — is built and tested. This entry is only the
automation on top.

- **Not on the critical path.** The desk runs today on a merchant QRIS obtained from an e-wallet with an
  iOS app (DANA Bisnis, GoPay Merchant, OVO, ShopeePay, LinkAja — micro-merchant tier needs KTP and a
  photo of the business, no NPWP below Rp500 juta/year turnover, 1-7 working days to verify). None of
  those expose a mutation API, so confirmation stays manual, which is fine well past the volume that
  currently exists. Only the raw static QRIS payload is needed for `TOPUP_QRIS_PAYLOAD`; scan the issued
  QR with any reader to read it out.
- **OkeConnect is the upgrade, and it is Android-gated.** It is the H2H side of OrderKuota, and
  registration requires the OrderKuota app from the Play Store — no iOS build, and the web dashboard only
  serves accounts that already exist. Emulator, borrowed handset, or a cheap used device. Once in:
  dashboard → Payment H2H → API Integration gives a Merchant Code and API Key plus the mutation
  endpoint's real spec. **Copy that spec from the dashboard rather than from any third-party write-up**;
  it is an unofficial API and it moves.
- **The migration costs the buyer nothing.** Same unique nominal, same status page, same order ledger.
  Only the confirmation leg swaps, from a person reading a notification to a worker reading an endpoint.
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

**Restock round-trip is measured: about four minutes.** Rupiah balance → Pintu → buy ETH → withdraw to an
ERC-20 wallet (those three, 2-3 minutes) → bridge to Gnosis on relay.link (1 minute). So the fulfilment
window is not about mechanics at all, it is about how soon a human notices; it now lives in
`TopupConfig.scheduledWindowMs` and is set from `/topup/admin`.

Two things that measurement opens up, neither done yet:

- **Per-restock cost is now the constraint, not per-restock time.** Every cycle pays an L1 withdrawal fee
  plus a bridge fee, which is a fixed cost against a variable order size, so restocking once per order
  destroys the margin on small ones. Batch instead: restock in chunks sized to a day, not to an order.
- **Check whether Pintu can withdraw on a cheaper network than Ethereum L1.** relay.link bridges from
  Base, Arbitrum, Polygon and others, so if any of those is a supported withdrawal network the L1 fee
  disappears from every cycle. Worth one look; it is pure margin.

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
