# Proof campaign runbook

The protocol is live on Gnosis mainnet and, as of the last check, has **zero** transactions through it.
That is the honest starting line. This runbook turns it into a track record: a handful of settled
transactions plus at least one dispute driven all the way to a verdict, published at
[walendria.org/track-record](https://walendria.org/track-record) with the transaction hash for every one.
It is scripted end to end — two commands, one keystore prompt each.

Why this and not marketing: Walendria has no paid audit and no brand. The only claim it can make that a
stranger has any reason to believe is one they can re-derive from the chain themselves. Everything below
exists to produce exactly that, and nothing that only *looks* like it.

---

## 1. What it costs

Measured against the live mainnet bytecode by `test/fork/MainnetCampaignCost.t.sol`, not estimated on paper.

### Capital: a multiple of P, and P is yours to choose

| | multiple of P |
|---|---|
| Seller's Integrity Bond (locked while a slot is live) | 1.5 × P |
| Buyer's payment | 1.0 × P |
| Opening the dispute market (0.5P per side) | 0.5 × P |
| Pushing the market past the 93% threshold | 1.97 × P |
| **Peak capital that must be liquid at one moment** | **4.966 × P** |
| Winner redeems back afterwards | 2.966 × P |

`test_Fork_SmallestViablePrice` sweeps P across **seven orders of magnitude** — 0.000001, 0.00001, 0.0001,
0.001 and 0.01 xDAI — and the ratio comes back as `4.96616574718` at every single one, identical to fifteen
significant figures. The contracts impose almost no floor either: ListingManager rejects only `price == 0`,
DisputeManager only `price / 2 == 0`. So **P is genuinely a free choice**, and the capital line of the budget
is whatever you decide it is. Pick P by what you can put up; the protocol does not care.

**One bond covers every honest transaction** — but not for the reason it first appears. `confirmCompletion`
recycles the slot to `Empty` and deliberately *leaves the bond locked*, because that slot is still on offer
to the next buyer: Locked IB backs an open listing slot, not an individual sale, and is only released by
`closeListing`/`reduceSlots`. So ten separate listings would demand ten simultaneous 1.5P locks.

The structure that actually works is **one listing with one slot, sold over and over**. Each payment bumps
the slot's `cycle`, so every sale still gets its own distinct dispute market, and the whole campaign runs on
a single 1.5P lock. That is also the more faithful demonstration — a real seller lists a thing once and sells
it repeatedly, which is precisely what the slot-recycling design exists for.

**And almost all of it comes back.** When one operator holds every role in a rehearsal, the outlay unwinds,
and the part that doesn't — the 0.5% Developer Fee and any swept market surplus — routes to the Developer
Pool, which is the same operator again.

### Gas: the part that is actually spent

Capital loops; gas does not. Measured per operation by `test_Fork_MeasureCampaignGas` against the deployed
bytecode:

| operation | gas |
|---|---|
| `integrityBond.deposit` (once per campaign) | 33,577 |
| `createListing` | 240,134 |
| `settlement.pay` | 136,661 |
| `confirmCompletion` | 24,790 |
| `fundGuiltySide` (also opens the LMSR market) | 516,488 |
| `spectralMarket.buy` | 115,921 |
| `pokeSettlement` | 56,225 |
| `finalizeDispute` | 44,575 |
| `redeem` | 35,140 |
| **one honest transaction** on a reused slot (pay + confirm) | **161,451** |
| plus, once per campaign: `deposit` + `createListing` | 273,711 |

### Putting it together

Total ≈ `4.966 × P` (returns) + `gas × gasPrice` (spent), and the second term is the one that rounds to
nothing. Simulating phase 1 of the campaign script — three honest sales plus a dispute opened and pushed
past 93% — against live mainnet state, `forge` estimated **2,747,002 gas at 0.000004522 gwei**, i.e. a total
of **0.0000000124 xDAI**. Phase 2 adds roughly a further 250,000 gas.

So gas is genuinely not a line item on Gnosis; the budget is the capital, and the capital comes back:

| P | peak capital | total to have on hand |
|---|---|---|
| 0.00005 | 0.00025 | **~0.0003** |
| 0.001 | 0.0050 | **~0.005** |
| 0.01 | 0.0497 | **~0.05** |
| 0.1 | 0.497 | **~0.5** |
| 1 | 4.97 | **~5** |

The fork test confirms where the money ends up. Across four sales at P = 0.00005, the operator's balance
fell by exactly **4 × 0.5% × P** — the Developer Fee on each sale, which for a self-operated rehearsal lands
in the operator's own Developer Pool. Every other wei came back through redemption and the bond claim.

> Re-run any of these measurements with:
> ```bash
> forge test --match-path test/fork/MainnetCampaignCost.t.sol -vv
> ```

---

### Which P to run at

Pick the one you can fund **today**, not the one you could fund eventually. Every size produces real
transaction hashes on mainnet and exercises identical code paths; the only thing P changes is how much a
sceptic can say the amounts were trivial.

There is a real answer to that objection, and it should be given rather than dodged: the protocol's
per-transaction hardcap is 100 xDAI, so nothing here is ever demonstrating behaviour at a scale it was not
built for, and the dispute mechanism is a fixed ratio of P — it behaves identically at every size, which is
exactly what the seven-orders-of-magnitude sweep above establishes.

A dispute run at a tiny P and published honestly beats a large one that never happens. If funds arrive
later, run it again at a bigger P — the track record accumulates, and a second entry at a larger size is
itself evidence that the first was not a fluke.

## 2. Running it

`script/live/ProofCampaign.s.sol` runs the whole thing as two broadcasts. **You run them** — the keystore
password is entered interactively, never passed on a command line or into a chat.

### Phase 1 — bond, honest sales, dispute opened and pushed past 93%

```bash
CAMPAIGN_PRICE=50000000000000 CAMPAIGN_HONEST_COUNT=3 \
forge script script/live/ProofCampaign.s.sol:ProofCampaignPhase1 \
  --rpc-url gnosis --account walendria-chiado --broadcast --slow
```

`CAMPAIGN_PRICE` is P in wei (the example is 0.00005 xDAI). `--slow` is mandatory: the public RPC pool
scrambles nonces if forge pipelines transactions.

**Shell note — this repo is worked on from Windows.** The `VAR=value command` prefix above is bash/Git Bash
syntax; in Command Prompt it fails with `'CAMPAIGN_PRICE' is not recognized`. The cmd.exe equivalent is:

```cmd
set "CAMPAIGN_PRICE=50000000000000" && set "CAMPAIGN_HONEST_COUNT=3" && forge script script/live/ProofCampaign.s.sol:ProofCampaignPhase1 --rpc-url gnosis --account walendria-chiado --broadcast --slow
```

Keep the quotes: unquoted, `set X=1 && ...` stores the trailing space as part of the value and `vm.envOr`
fails to parse the number. In PowerShell it is `$env:CAMPAIGN_PRICE="50000000000000"; …` instead.

Before spending anything the script checks the wallet covers the peak, so an underfunded run fails costing
nothing rather than halfway through leaving a half-open dispute nobody can finish. At the end it prints the
listing id and asserts the Guilty price actually crossed 93% — a failure surfaces there, not an hour later.

### Wait ~1 hour

The Spectral Market resolves only after one side holds ≥93% for a *cumulative* hour. The clock pauses the
moment anyone bets back and never loses time already banked, so an hour of quiet is an hour banked. This is
a protocol property, not a scripting limitation — nothing collapses it into one transaction.

### Phase 2 — resolve, finalize, collect

```bash
CAMPAIGN_LISTING_ID=<id printed by phase 1> \
forge script script/live/ProofCampaign.s.sol:ProofCampaignPhase2 \
  --rpc-url gnosis --account walendria-chiado --broadcast --slow
```

or, from Command Prompt:

```cmd
set "CAMPAIGN_LISTING_ID=<id printed by phase 1>" && forge script script/live/ProofCampaign.s.sol:ProofCampaignPhase2 --rpc-url gnosis --account walendria-chiado --broadcast --slow
```

Pokes settlement (skipping it gracefully if the keeper bot got there first), finalizes the dispute, claims
the slashed bond — restitution is a *pull* payment, so it does have to be claimed — and redeems the winning
shares.

### What it does, and why that shape

One listing, one slot, sold `CAMPAIGN_HONEST_COUNT` times and then disputed on the final sale. One address
plays both buyer and seller: in a rehearsal it is the same operator either way, and deriving throwaway
identities would make the on-chain trail *look* like two strangers while changing nothing about who is
behind it. Each listing states the arrangement in its own on-chain description, which is a firmer
disclosure than a note on a web page anyone could edit later.

### It is tested before it spends anything

- `test/fork/ProofCampaign.t.sol` inherits the script's own `_phase1`/`_phase2` and runs the complete arc
  against a Gnosis mainnet fork — including the hour, via `vm.warp`. The code exercised is the code that
  broadcasts. It asserts the market resolves Guilty, the dispute finalizes, nothing is left unclaimed or
  unredeemed, and net capital consumed stays below 0.5 × P.
- Phase 1 can also be dry-run against real live state, as your real address, before committing:
  ```bash
  CAMPAIGN_PRICE=50000000000000 forge script script/live/ProofCampaign.s.sol:ProofCampaignPhase1 \
    --rpc-url gnosis --sender 0xC8bfedCC142b0C915CA83E214a71d6607C89d310
  ```
  No `--broadcast`, so nothing is sent; it reports the gas and whether the threshold would be crossed.

### Optional: the expired-window variant

Worth doing once, separately, because it proves the seller-protection path: pay for a slot, let the 72-hour
window lapse without confirming, then call `finalizeExpiredSlot` from `/listings/<id>/slots`. That emits
`SlotFinalized` instead of `SlotCompleted` and demonstrates that a buyer who simply goes silent cannot
strand the seller's bond. It costs three days of waiting and a second 1.5P lock, so it is left out of the
script rather than made to hold up the rest.

### Report what actually happens

Including the unflattering parts. If a redemption comes back short of 1:1 per share because the pool was
thin, say so — that is the documented LMSR shortfall, not a bug, and a record that only reports good
outcomes is not evidence of anything.

---

## 3. Publish it honestly

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

## 4. Where this leaves the argument

Ten settled transactions is not adoption and this document should not pretend otherwise. What it *is*:
proof that every path in the protocol works against real money on a real chain, that a dispute reaches a
verdict without a court, and that the project publishes its own history including the parts that don't
flatter it.

That is the smallest artifact that makes the next conversation possible — the one where someone who has no
reason to trust you can check for themselves in two minutes instead of taking a whitepaper on faith.
