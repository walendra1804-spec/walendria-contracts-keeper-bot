# Walendria Protocol — Grant Application (master copy)

Paste-ready content for Giveth (primary), Gitcoin Grants, and a GnosisDAO governance
proposal. Fill the same core answers everywhere; only the wrapper changes per platform.

---

## 0. Canonical facts (reuse verbatim)

- **Project name:** Walendria Protocol — "The 28"
- **Website:** https://walendria.org
- **Whitepaper:** https://walendria.org/whitepaper
- **Prior-art / proof page:** https://walendria.org/priority
- **Source code (OSS, MIT):** https://github.com/walendra1804-spec/walendria-contracts-keeper-bot
- **Chain:** Gnosis Chain mainnet (chain id 100) + Gnosis Chiado testnet (10200)
- **Author / on-chain identity:** Panca Walendra — `0xC8bfedCC142b0C915CA83E214a71d6607C89d310`
- **Location:** Bandung, Indonesia
- **Whitepaper on-chain anchor:** DocumentNotary `0x2F1472ad612Be6B015DF666fcd8E5A2bd1497239`
- **Whitepaper Zenodo DOI:** 10.5281/zenodo.21398696
- **License:** MIT

---

## 1. One-liner (≤ 200 chars)

Trustless direct-transfer commerce on Gnosis Chain: buyers recover funds without an escrow
agent, and disputes are resolved by an open market instead of a court, platform, or admin.

## 2. Short description (tweet-length hook)

Every payment "middleman" you trust to keep you safe — a bank, a platform, a court — is also
the one thing that can freeze you, reverse you, or lock you out. Walendria removes the
middleman and answers the only two questions that ever mattered: *how do I get my money back
if the other side cheats*, and *who decides what's true in a dispute* — both on-chain, both
without a trusted intermediary.

## 3. The problem

Commerce between strangers has always required a trusted middleman to be safe — an escrow
agent, a payment processor, a marketplace, a court. Every one of them is a toll booth (it
takes a cut) **and** a single point of failure (it can freeze funds, reverse payments, deny
access, or simply disappear). In much of the world this is lived experience, not theory: in
Indonesia, millions of peer-to-peer trades still route through *Rekber* ("rekening bersama") —
a human escrow you pay and hope is honest. The trust problem is real, global, and unsolved by
the incumbents because the incumbents *are* the trust problem.

## 4. The solution — two reductions, two contracts

Strip every trust apparatus back and only two questions remain. Walendria answers each one
directly on-chain, with no intermediary:

- **"How do I get my money back if the seller cheats?" → the Integrity Bond.** The seller
  posts a bond that self-unlocks and returns to productive use; if the deal goes bad, the
  buyer's recovery comes from it. No escrow agent holds the money, and no one can reverse a
  settled transfer.
- **"Who decides what's true in a dispute?" → the Spectral Market.** Disputes are resolved by
  an open LMSR prediction market on the outcome, not by a platform's support desk or a court.
  Truth becomes a procedure anyone can join and verify, not a verdict handed down by an
  authority.

Nine Solidity contracts, a Node indexer, and a Next.js frontend — all deployed and live on
Gnosis Chain mainnet today.

## 5. Why Gnosis Chain

- **Sub-cent fees** make small, real-world trades economically viable — a payment primitive
  needs near-zero overhead to matter for everyday commerce.
- **xDAI** gives price stability without touching a custodial fiat rail.
- The protocol's public-goods, self-custody, anti-intermediary ethos is native to the Gnosis
  community — this is infrastructure *for* the ecosystem, built on it end to end.

## 6. Safety model (no paid audit — by design)

Instead of a one-time paid audit, Walendria bounds risk structurally and permanently:

- **Immutable per-transaction hardcap** (`ListingManager.maxTransactionValue`, 100 xDAI) caps
  the blast radius of any single exploited path — the maximum at risk in any one transaction is
  bounded and cannot be raised by anyone after deployment.
- **No admin keys / no upgrade path.** Contracts are immutable; there is no privileged function
  that can drain, pause, or rewrite them. "Upgrading" means a fresh deploy at new addresses,
  transparently.
- **Permissionless settlement ("poke").** Markets resolve without the developer being online —
  anyone can trigger settlement, so the system does not depend on a single operator.
- **Source = bytecode, provably.** A live-fork test suite pins the source to the exact deployed
  addresses, so a green run is direct evidence the on-chain bytecode behaves as the source says.
  All contracts are open-source (MIT) and verifiable on Blockscout.
- **Independent priority record.** The whitepaper's SHA-256 is anchored on-chain and archived
  with a permanent Zenodo DOI, so authorship and timeline are independently checkable.

## 7. Status & traction

- **Engineering-complete and live on Gnosis mainnet** (and on Chiado as staging): 9 contracts,
  an event indexer, and a full dApp at walendria.org.
- **395-test Foundry suite** — unit, fuzz, invariant, and live-fork tests against the deployed
  bytecode (both live-fork lifecycle scenarios green).
- **Whitepaper published, on-chain-notarized, and Zenodo-archived.**
- Now entering the **adoption / bootstrapping phase** — the reason for this grant.

## 8. What the grant funds (use of funds)

Honest, public-goods-aligned line items — none of this is speculative token work:

1. **Reliability of the public infrastructure** — resilient hosting/RPC for the keeper-bot
   indexer and frontend so the protocol's public read layer stays up independently of one
   cheap VPS.
2. **A minimal integration SDK (npm) + integration guide** — so any Gnosis dApp can add
   trustless escrow as a composable primitive in a few lines. Composability is the public good.
3. **Documentation & localization** — first-class Indonesian/SEA docs, mapping the Integrity
   Bond onto the *Rekber* mental model to onboard a large, underserved, fraud-exposed market.
4. **Ecosystem onboarding** — hand-held onboarding of a first cohort of real sellers/buyers to
   bootstrap genuine on-chain activity (digital-goods-first, where settlement is cleanest).

## 9. Milestones

- **M1 (0–1 mo):** Blockscout source-verify all 9 mainnet contracts; publish a plain-language
  "what's the worst that can happen" safety page. Ship the integration guide skeleton.
- **M2 (1–2 mo):** Publish the npm integration package + one reference integration. Indonesian
  docs live.
- **M3 (2–3 mo):** Onboard a founding cohort of real users; first N genuine mainnet
  transactions completed end-to-end (listing → payment → settlement, incl. at least one full
  dispute cycle).

## 10. Team

**Panca Walendra** — solo builder, Bandung, Indonesia. Designed, implemented, tested, deployed,
and operates the entire stack (contracts, indexer, frontend, infra). Public on-chain identity:
`0xC8bfedCC142b0C915CA83E214a71d6607C89d310`.

## 11. Recipient / donation address

Gnosis Chain: `0xC8bfedCC142b0C915CA83E214a71d6607C89d310` (the author's public identity —
consistent with the single-signer priority chain).

---

## Platform-specific wrappers

### A) Giveth (do this first — always-on QF, native Gnosis Chain)

Create-project fields → answers:
- **Title:** Walendria Protocol — The 28
- **Description:** §3 + §4 + §6 + §7 above (Giveth supports rich text — lead with §2 hook).
- **Categories (max 5) — recommended pick:** `financial-services`, `public-goods`,
  `infrastructure`, `tech`, `industry-and-innovation`.
- **Location:** Bandung, Indonesia (or mark "global impact").
- **Image:** a clean Walendria banner (screenshot of walendria.org hero works).
- **Recipient address:** §11, on **Gnosis Chain**.
- After publishing, pursue **Verified** status (needs vouches → unlocks GIVbacks eligibility,
  which materially boosts QF matching).

### B) Gitcoin Grants (when the next round opens)

- Eligibility you already meet: **OSS with an open-source license** (MIT) + **meaningful GitHub
  activity in the prior 3 months** (repo is active).
- Pick the domain that fits the open round (dev tooling / infra / "crypto commerce primitive").
- Application is submitted through the Grants Stack; reuse §1–§9. Emphasize **broad community
  value + composability** (QF rewards many small donors, not one big check).
- Watch grants.gitcoin.co for the next round's open + close dates; rounds are time-boxed.

### C) GnosisDAO governance proposal (larger, later)

- Path: post on **forum.gnosis.io** following the GnosisDAO governance process, then a Snapshot
  vote. This is a direct grant ask (heavier lift than QF).
- Reuse §3–§10 and **add a specific funding amount + detailed milestone budget** (QF platforms
  don't need an amount; a DAO proposal does).
- Best attempted *after* M1–M2 above are done, so the proposal shows live traction + verified
  contracts rather than just a plan.
