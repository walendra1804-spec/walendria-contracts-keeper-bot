# Proof campaign runbook

The protocol is live on Gnosis mainnet and, as of the last check, has **zero** transactions through it.
That is the honest starting line. This runbook turns it into a track record: roughly ten settled
transactions plus at least one dispute driven all the way to a verdict, published at
[walendria.org/track-record](https://walendria.org/track-record) with the transaction hash for every one.

Why this and not marketing: Walendria has no paid audit and no brand. The only claim it can make that a
stranger has any reason to believe is one they can re-derive from the chain themselves. Everything below
exists to produce exactly that, and nothing that only *looks* like it.

---

## 1. What it costs

Measured against the live mainnet bytecode by `test/fork/MainnetCampaignCost.t.sol`, not estimated on paper.
Every figure is a multiple of `P`, the listing price you choose — the ratios held identical at P = 0.1, 1 and
10 xDAI, so **P is a free choice**. Pick it by what you can put up, not by what the protocol needs.

| | multiple of P |
|---|---|
| Seller's Integrity Bond (locked while a slot is live) | 1.5 × P |
| Buyer's payment | 1.0 × P |
| Opening the dispute market (0.5P per side) | 0.5 × P |
| Pushing the market past the 93% threshold | 1.97 × P |
| **Peak capital that must be liquid at one moment** | **4.97 × P** |
| Winner redeems back afterwards | 2.97 × P |

Two things follow.

**The binding constraint is peak liquidity, not loss.** When one operator holds every role in a rehearsal,
almost all of the outlay unwinds, and the part that doesn't — the 0.5% Developer Fee and any swept market
surplus — routes to the Developer Pool, which is the same operator again. Net cost of the whole campaign is
essentially gas, and gas on Gnosis rounds to nothing.

**One bond covers all ten honest transactions** if they run sequentially: the bond unlocks on each
settlement and is immediately reusable. There is no need to fund 10 × 1.5P.

So at **P = 1 xDAI, budget ~5 xDAI** and expect nearly all of it back. Run the honest transactions first and
the dispute last, and the 5 never has to be split.

> Re-run the measurement any time with:
> ```bash
> forge test --match-path test/fork/MainnetCampaignCost.t.sol -vv
> ```

---

## 2. Wallets

| Role | Who | Needs |
|---|---|---|
| **Seller** | deployer wallet `0xC8bfedCC…d310` | 1.5 × P for the bond |
| **Buyer** | a second wallet you control, or a friend's | P per purchase (returns to seller) |
| **Dispute counterparty** | your own second wallet | ~2.5 × P for the guilty side + the push |

Use a friend's wallet as buyer wherever a friend is actually willing — a distinct address on the other side
is stronger evidence than one you control, even when disclosed. For the **dispute**, expect to hold both
sides yourself: it needs ~5 × P and one side is designed to lose. Asking someone to fund a losing position
as a favour is not a reasonable thing to ask.

**Every one of these choices gets disclosed.** See section 5 — it is not optional, and it is the reason the
record is worth anything.

---

## 3. Part A — ten honest transactions

Each cycle is roughly two minutes of clicking. The completion window has a 72-hour floor, but a buyer can
confirm receipt immediately, so **the whole set can be done in one sitting** — no waiting required.

**Once, at the start:**

1. `/integrity-bond` → **Deposit** → 1.5 × P. This is the only capital that stays locked across the run.

**Then repeat ten times:**

2. `/sell` → fill price = P, slots = 1, completion window = 72h (the minimum), a real title and description
   → **Create listing**. Note the listing id.
3. Switch to the buyer wallet → `/pay/<listingId>` → **Pay listing `<id>`**.
   *This emits `Settled` — the event the track record counts as a transaction.*
4. Still as buyer → `/purchases` → **Confirm receipt & release bond**.
   *This emits `SlotCompleted` and unlocks the bond, freeing it for the next cycle.*

Vary the price across the ten rather than repeating one number — a record of ten identical transactions
reads as a script, which is exactly what it would be.

**Do at least one differently:** let a single slot's 72-hour window lapse without confirming, then call
`finalizeExpiredSlot` from `/listings/<id>/slots`. That produces a `SlotFinalized` instead of a
`SlotCompleted`, and proves the seller-protection path works — that a buyer who simply goes silent cannot
strand the seller's bond. It costs three days of waiting, so start it early and run the other nine while it
matures.

---

## 4. Part B — one dispute, all the way to a verdict

This is the part that actually matters. Anyone can build an escrow that works when everyone is honest; the
entire claim of this protocol is what happens when they are not.

1. **Set it up.** Create a listing at price P and pay for it from the buyer wallet, exactly as above — but
   do **not** confirm receipt.
2. **Open the dispute.** As buyer, go to `/disputes/<listingId>/<slotIndex>` → **Fund Guilty side** →
   0.5 × P. The Spectral Market opens once the guilty side is funded; the matching 0.5P on the innocent side
   comes from the seller's locked bond.
3. **Submit evidence.** On the same page, upload a document through the evidence panel → **Submit evidence**.
   A dispute with no evidence attached is a weaker artifact than one with it, and this exercises
   EvidenceRegistry + IPFS end to end.
4. **Push the market.** In the trade panel choose **Guilty** and **Buy Guilty shares**. Budget ~1.97 × P;
   buy in two or three steps and watch the price bar rather than sending one large order.
5. **Wait out the clock.** The Guilty side must hold ≥93% for a *cumulative* hour. The clock pauses the
   moment anyone bets back and never loses time already banked, so an hour of quiet is an hour banked.
6. **Poke.** `/claim` → **Poke settlement**. Permissionless — the keeper bot may well beat you to it, which
   is itself worth noting in the record when it happens.
7. **Finalize.** Back on the dispute page → **Finalize dispute**. This emits `DisputeFinalized` with the
   winning side, slashes the bond to the buyer, and is the single most load-bearing row on the whole page.
8. **Redeem.** `/claim` → **Redeem** on the winning position. Expect ~2.97 × P back.

Note honestly whatever actually happens, including the parts that are unflattering. If the redemption comes
back short of 1:1 per share because the pool was thin, say so — that is the documented LMSR shortfall, not a
bug, and a record that only reports the good outcomes is not evidence of anything.

---

## 5. Part C — publish it honestly

The chain proves a transaction happened. It cannot prove the two sides were strangers, and for this campaign
most of them are not. A reader will check the addresses within a minute of caring, and a record that quietly
implied organic adoption would be worth less than no record at all.

So for every transaction where you know the counterparty was yourself or a friend, add an entry to
`walendria-app/src/lib/trackRecordNotes.ts`, keyed by the lowercased transaction hash:

```ts
export const TRACK_RECORD_NOTES: Record<string, TrackRecordNote> = {
  "0x…": { kind: "self", note: "Rehearsal. Both buyer and seller are the developer's own wallets." },
  "0x…": { kind: "friend", note: "Counterparty is a friend of the developer, who agreed to test the flow." },
};
```

The page already tells readers that an unannotated row claims nothing either way, so silence is never read
as a claim of independence — but only if the notes that *should* be there actually are.

Then:

1. **VPS keeper sync** — the indexer needs the new event streams, and the existing `data.json` predates them,
   so it must be dropped and rebuilt. Follow the "VPS sync" section of `CLAUDE.md` (`git pull` alone is not
   enough — the running process reads an untracked copy under the repo root `src/`). Confirm with:
   ```bash
   curl localhost:4000/events/track-record
   ```
2. **Redeploy the app** — per the "walendria.org" section of `CLAUDE.md`.
3. **Verify** `https://walendria.org/track-record` shows the real rows, and click through at least one
   transaction hash to the block explorer to confirm the page and the chain agree.

---

## 6. Where this leaves the argument

Ten settled transactions is not adoption and this document should not pretend otherwise. What it *is*:
proof that every path in the protocol works against real money on a real chain, that a dispute reaches a
verdict without a court, and that the project publishes its own history including the parts that don't
flatter it.

That is the smallest artifact that makes the next conversation possible — the one where someone who has no
reason to trust you can check for themselves in two minutes instead of taking a whitepaper on faith.
