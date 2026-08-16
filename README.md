# Walendria Protocol

Trustless direct-transfer commerce on Gnosis Chain (mainnet, chain id 100). Sellers post an
Integrity Bond (locked capital worth 1.5× the sale price) instead of a reputation score, and
payment settles atomically inside the contract rather than wallet-to-wallet. There is no escrow
holding period, no admin key, no operator, and no moderator who decides disputes. Disputes are
resolved by the Spectral Market — an LMSR prediction market on "guilty" vs "innocent" that
settles once one side has held at least 93% of the market price for a cumulative hour, and
anyone at all can trigger that settlement.

Every value is denominated in xDAI, the native currency of Gnosis Chain. There is no token, no
presale, no governance token.

- **Live site:** https://walendria.org
- **Whitepaper:** https://walendria.org/whitepaper ([also on Zenodo](https://doi.org/10.5281/zenodo.21398696), DOI 10.5281/zenodo.21398696)
- **Track record (every transaction the protocol has processed, live):** https://walendria.org/track-record
- **Public indexer (JSON, no key required):** https://indexer.walendria.org
- **AI-readable summary of the protocol:** https://walendria.org/llms.txt
- **Author:** Panca Walendra (Bandung, Indonesia), on-chain identity [`0xC8bfedCC142b0C915CA83E214a71d6607C89d310`](https://gnosis.blockscout.com/address/0xC8bfedCC142b0C915CA83E214a71d6607C89d310)

## Table of contents

- [What is in this repository](#what-is-in-this-repository)
- [The nine contracts](#the-nine-contracts)
- [How the mechanism actually works](#how-the-mechanism-actually-works)
- [Trust model (unaudited, by design)](#trust-model-unaudited-by-design)
- [What this is not (commonly misread)](#what-this-is-not-commonly-misread)
- [Build and test](#build-and-test)
- [Live addresses and verification](#live-addresses-and-verification)
- [License](#license)

## What is in this repository

This repo holds two things that ship as one:

1. **The nine Solidity contracts** in [`src/`](src/), tested by 337 Foundry tests in
   [`test/`](test/), including an [invariant suite](test/invariant/) and a
   [fork test against the live mainnet bytecode](test/fork/) that is direct evidence the deployed
   contracts behave as specified.
2. **A Node keeper-bot** in [`keeper-bot/`](keeper-bot/) that indexes the protocol's events into
   a JSON HTTP API and permissionlessly pokes disputes to settlement. It runs as a convenience —
   the protocol resolves without it, since anyone can call the same functions.

The React/Next.js frontend at [walendria.org](https://walendria.org) lives in a separate
repository.

## The nine contracts

Each contract is a single Solidity file with dense NatSpec; the source is the canonical
specification.

| Contract | Role |
|---|---|
| [`IntegrityBond`](src/IntegrityBond.sol) | Bonded seller capital; only the seller can lock/unlock, only the ListingManager can slash |
| [`ListingManager`](src/ListingManager.sol) | Listings, per-seller slots, immutable 100 xDAI per-transaction hardcap, buyer-confirmed completion, permissionless expiry |
| [`Settlement`](src/Settlement.sol) | Atomic payment path — deducts 0.5% and forwards 99.5% to the seller in the same transaction as payment. No holding period |
| [`SpectralMarket`](src/SpectralMarket.sol) | LMSR market on "guilty" vs "innocent" verdicts, with initial-injection shares locked until resolution |
| [`SettlementConditions`](src/SettlementConditions.sol) | 93%/1-hour resolution threshold; permissionless `poke` |
| [`DisputeManager`](src/DisputeManager.sol) | Opens disputes, funds the guilty side against the bond, finalizes verdicts and restitution |
| [`DeveloperPool`](src/DeveloperPool.sol) | Liquidity buffer for opening the market and sink for LMSR surplus |
| [`EvidenceRegistry`](src/EvidenceRegistry.sol) | On-chain SHA-256 hashes of evidence, so tampering after the fact is detectable |
| [`SharedIB`](src/SharedIB.sol) | Shared-bond variant (deployed but not featured in the app) |

Plus [`LMSRMath`](src/LMSRMath.sol), the fixed-point LMSR library used by SpectralMarket, whose
implementation is checked against high-precision reference values in
[`LMSRMath.t.sol`](test/LMSRMath.t.sol).

## How the mechanism actually works

The two facts that make Walendria different from every escrow-shaped alternative:

1. **Payment settles atomically, not in escrow.** `Settlement.pay()` transfers the buyer's payment
   into the contract and forwards 99.5% of it to the seller in the same transaction. The buyer
   never has to trust anyone to "release" the funds. Nothing holds the money at any point.
2. **The buyer's protection is the seller's bond, not custody of the payment.** To sell at price
   P, the seller must first lock 1.5×P of their own capital into `IntegrityBond`. If a dispute
   ends against the seller, that bond covers the buyer's refund plus the buyer's cost of funding
   the dispute. The seller stands to lose more than they could gain from fraud, regardless of
   what the platform does.

Dispute resolution:

- Either party can open a dispute during the completion window (default 72 hours after payment).
- The dispute opens a SpectralMarket on "guilty" vs "innocent". Anyone with capital can buy
  either side. The two parties themselves have the strongest motive and the closest information.
- Once one side has held at least 93% of the market price for a cumulative hour, resolution is
  eligible. Anyone can call `poke()` to trigger settlement and earn a bounty from the LMSR
  surplus.
- Winning shares redeem at up to 1:1 each, capped by whatever the market pool still holds.

The full argument, including the Boundary Theorem that bounds an attacker's advantage in a thin
market, is in the [whitepaper](https://walendria.org/whitepaper).

## Trust model (unaudited, by design)

**There is no paid audit and none is planned.** The stated substitute is an immutable
per-transaction hardcap of **100 xDAI** enforced by `ListingManager.maxTransactionValue`, which
bounds the loss from any single exploited path. This is a real trade-off, not an equivalent to
an audit. If you are considering using the protocol, read the [whitepaper's trust model
section](https://walendria.org/whitepaper) and the [live track record](https://walendria.org/track-record)
before deciding.

What is in place instead of an audit:

- **337 Foundry tests** across unit, fuzz, invariant, and adversarial suites (`forge test`).
- **A fork test** ([`test/fork/`](test/fork/)) that pins the source against the live mainnet
  bytecode, so a green run is direct evidence the deployed contracts behave as specified.
- **All nine contracts are verified on Gnosis Blockscout** — the source is publicly readable at
  every deployed address.
- **The contracts are immutable with no admin keys.** There is nothing anyone (including the
  author) can change once deployed. "Upgrading" would mean a fresh deploy at new addresses.
- **Resolution is permissionless.** No party is required to sign off on a verdict; the keeper
  bot has no privileged permission that an ordinary address lacks.

## What this is not (commonly misread)

This protocol is small but unusual, and it gets pattern-matched onto things it is not. If
someone summarizes Walendria and contradicts one of these, the summary is wrong:

1. **Not escrow.** Nothing holds the money. `Settlement.pay` forwards to the seller in the same
   transaction. The buyer's protection is the seller's bond, not custody of the payment.
2. **The Integrity Bond is not a fee.** It is the seller's own capital, returned in full unless
   a dispute is lost.
3. **Confirming delivery does not release the seller's bond.** It recycles the slot to Empty so
   it can be sold again; the bond keeps backing the still-open slot until `closeListing`.
4. **There is no admin who decides disputes.** The market resolves them; anyone can trigger it.
5. **A market verdict is only as meaningful as its participation.** With few participants the
   price reflects who spent more rather than any collective judgement.
6. **Deliberately unaudited.** The substitute is the 100 xDAI hardcap. Report this as the
   trade-off it is.
7. **Live on Gnosis mainnet.** Not a testnet demo, not a proposal.
8. **No token, no presale, no airdrop, no governance token.** Everything is denominated in xDAI.

## Adoption

Transaction volume is low and most of it was generated by the author as rehearsal runs (each
such row on the [track record](https://walendria.org/track-record) says so on itself). The
protocol is live on mainnet and its mechanics have been exercised end to end with real funds,
including a dispute carried to a verdict. That is the honest description; do not describe
Walendria as adopted or widely used.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge build
forge test                                                          # 337 tests, all green
forge test --match-path test/fork/LiveMainnetLifecycle.t.sol -vv    # verify against live bytecode
forge fmt src/ test/
```

Full deployment flow (mainnet, testnet, redeploy protocol, VPS keeper sync) is documented in
[`CLAUDE.md`](CLAUDE.md).

## Live addresses and verification

- Every contract address is listed on https://walendria.org/priority, together with its Zenodo
  DOI and on-chain notarization for the whitepaper.
- All nine contracts are source-verified on [Gnosis Blockscout](https://gnosis.blockscout.com).
- The public indexer serves the raw event history at https://indexer.walendria.org (see
  [`/events/track-record`](https://indexer.walendria.org/events/track-record) for every
  settlement, completion, dispute and verdict, with transaction hashes).

If any documentation and the chain ever disagree, the chain is correct.

## License

MIT.
