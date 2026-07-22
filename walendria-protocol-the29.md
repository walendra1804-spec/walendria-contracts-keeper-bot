# WALENDRIA PROTOCOL: A TRUSTLESS DIRECT TRANSFER SYSTEM
Public Draft — The 29 — No Minimum Transaction Floor

---

## Abstract

Walendria Protocol is a peer-to-peer transaction system engineered to make cheating a negative-expected-value strategy for both parties under conditions of adequate market participation, and to make the residual risk in low-participation disputes an explicit, computable, disclosed quantity rather than a hidden or unbounded one. Sellers deposit an Integrity Bond (IB) as a universal guarantee of honest behavior; buyer payment settles through a single atomic, non-discretionary contract call — no party holds funds or decides their release (Section 2.3). A fixed 0.5% Developer Fee is assessed on every completed transaction and routed automatically to the developer's designated wallet, funding protocol operations. A dispute opens only once 0.5P of capital — from the buyer, from anyone who backs the buyer's public case, or from any combination of the two — has been locked to purchase "Seller Guilty" shares; only then does a matching 0.5P from the seller's Locked IB purchase "Seller Innocent" shares, jointly seeding the Spectral Market's opening liquidity (Section 2.4). In case of dispute, the Spectral Market — a purpose-built on-chain prediction market powered by the LMSR bonding curve — resolves the matter through open, capital-backed price discovery. The LMSR curve is path-independent: coordinated multi-wallet attacks provide zero mathematical advantage over a single large purchase (Section 2.6.4). Any price deviation from evidence-supported equilibrium creates a profitable counter-trading opportunity for any independent participant who engages it (Section 6); Section 2.6.9 states the boundary of that guarantee — what happens, and at what disclosed cost, when no independent participant does. The Shared Integrity Bond enables small sellers to participate without compromising any security invariant. Settlement of a disputed transaction is guaranteed by a deterministic checkpoint-and-poke mechanism requiring no oracle, no off-chain timer, and no trusted keeper; settlement of an undisputed transaction is guaranteed by a protocol-bounded completion window (Section 2.5). The protocol smart contract is deployed immutably — no upgrade key exists, no admin can modify it after deployment.

**The 29 corrects a numeric error carried since The 28 in Section 3.2 and the Section 4 payoff table, and changes nothing else.** A seller who is disputed falsely and correctly vindicated was summarized as netting "approximately breakeven relative to a transaction with no dispute at all." That understated the outcome. In the base case (forced positions only), the seller's winning 0.5P Innocent position redeems the full ~1P pool — their own returned 0.5P plus the forfeited 0.5P from whoever funded the losing Guilty side — while the remaining 1.0P of Locked IB unlocks untouched. The seller therefore nets approximately **+0.5P better** than a no-dispute sale (~ +1.495P against the +0.995P honest baseline), not breakeven: a falsely accused, correctly vindicated seller is made more than whole, capturing the failed accuser's forfeited stake. Section 2.6.6's developer surplus makes the recovery marginally short of a full 1P, which the "approximately" preserves. This is a documentation correction only — no mechanism, parameter, or contract behavior changes; the deployed contract already produces this outcome, and Section 3.2's own mechanical description of the ~1P recovery already stated it correctly. The fix touches the Section 3.2 net-summary line and the two false-dispute rows of Section 4, bringing the whitepaper into line with both the contract and the published article corpus.

**This document further amends The 27 below: the Protocol Liquidity Buffer (formerly Section 2.6.7) is retired, and the `pokeSettlement` bounty (Section 2.6.8) changes from a fixed amount to 0.1% of the transaction price, paid from the resolved market's own settlement surplus (Section 2.6.6) rather than a pre-funded pool. In a quiet dispute whose surplus is too thin to pay it, resolution does not depend on that bounty at all: the winning side holds its entire payout behind the poke and is therefore always incentivized to call it, whether or not any surplus rewards a third party for doing so.**

The Protocol Liquidity Buffer subsidized any dispute whose initial 1P depth fell short of a $5-equivalent floor, funded from the Developer Pool. Removing it does not weaken the protocol's core security property: the Boundary Theorem (Section 2.6.9) and the capital-wall calibration built on it are scale-invariant by construction — H(p) is proportional to b, which is itself proportional to P (Section 2.6.4), so the ratio between the capital required to force an uncontested resolution and the capital a manipulator has on hand (their share of the 0.5P stake, or a guilty seller's 0.995P sale proceeds) is identical whether P is $0.0001 or $100,000. A fixed dollar floor never protected that ratio; it only ever protected market *depth* for disputes below that floor, a genuine but separate concern (Section 2.6.9's own distinction between depth and participation). This document declines to reintroduce it, on principle, not as a claim that thin depth carries no real trade-off: Walendria imposes no minimum transaction size, implicit or explicit, anywhere in the world. A fixed-dollar floor — $5, or any other figure — is an implicitly culturally and economically relative judgment about what counts as a "meaningful" amount of money, one this protocol declines to make. No transaction is inflated to resemble a larger one to make its resolution look more legitimate than it is; every transaction gets exactly the mechanism its own price supports, and nothing more or less.

The `pokeSettlement` bounty changes for a related but distinct reason. A fixed bounty, sized for a transaction of some assumed reference value, becomes disproportionate at any other scale: potentially oversized relative to a very small dispute, potentially undersized relative to a very large one. This document replaces the fixed amount with a bounty set at 0.1% of the transaction price P, scaling the same way b already does, and paid from the resolved market's own settlement surplus (Section 2.6.6) rather than from any pre-funded or subsidized pool. This does change the shape of the guarantee Section 2.6.8 makes, and this document states the change plainly rather than papering over it. A contested dispute — one that drew real counter-trading — generates surplus comfortably larger than 0.1% of P, so any address can profitably resolve it. A quiet dispute, where only the two forced initial positions ever traded, leaves almost no surplus, so a third party has little to earn by poking it. Resolution is still guaranteed there, but for a different and stronger reason than a bounty: the winning side holds its entire payout behind the poke, and therefore always has a strict incentive to call `pokeSettlement` itself, at any transaction size, whether or not a surplus happens to reward anyone else for doing it first.

**A note on this document's name.** *The 29* is the name of this whitepaper's latest revision — the ninth major public revision, internally v2.9, carrying its number as a public name under the same convention *The 27* introduced below. Its immediate predecessor, *The 28*, held one further, personal significance: 28 also happens to be the developer's date of birth — a coincidence, not a protocol claim, recorded here because the developer wanted that particular revision to carry it permanently in this document's history.

**This document further clarifies The 28's Section 2.6.1, and the deployed contract now enforces it: the two initial joint-injection positions being "locked until the case resolves" is stated in its literal, enforced sense — neither a Guilty-side funder nor the seller may *sell* the shares that opening injection credits them. Those shares are the market's own opening liquidity; letting whoever seeded a side sell them straight back would hand that party a risk-free profit and drain the very depth the dispute is meant to keep in place. Only shares bought afterward on the open market (Section 2.6.3) are sellable; the locked opening position can only be redeemed or forfeited at resolution. Earlier drafts stated the positions were "locked" without spelling out that this forbids selling them specifically — the mechanism was always intended, and is now both stated plainly and enforced on-chain.**

**This document further amends The 28 below: an undisputed transaction's completion - whether by the completion window elapsing or the buyer confirming receipt early - no longer permanently retires that transaction slot. Section 2.5 now states that the slot recycles for resale, its Locked IB continuing to back it exactly as it did before any buyer paid, so a seller offering a repeatable good or service is not required to create a new listing for every sale at the same price. A transaction that is ever disputed is unaffected by this change and still permanently retires its slot regardless of verdict, because the 0.5P joint-injection draw at dispute-open (Section 2.6.1) already commits half that slot's collateral irreversibly before any verdict exists.**

**This document further amends The 27's own threshold recalibration below: the Spectral Market's settlement mechanism is unified into a single cumulative-time condition, and the separate 90% instant-resolution condition described below no longer exists at any price. Resolution now requires cumulative time at or above 93% to reach 1 hour (Section 2.6.5, 2.6.8) — no trade, however large, resolves a case in the same transaction it is made, including one that reaches 99% or effectively 100% in a single step.**

The instant-threshold condition is removed entirely because it collapsed reaction time to zero: a single, sufficiently capitalized transaction that crossed 90% resolved the case irreversibly in that same transaction, regardless of how many other participants would have counter-traded given even a few minutes' notice — the "one-shot" attack this document now closes structurally rather than merely discouraging economically. The cumulative condition survives as the sole path to resolution, recalibrated from 87%/3 hours to 93%/1 hour: every price level, including 99% or effectively 100%, now only ever contributes to the same pausable, never-resetting timer described in Section 2.6.8 — a single transaction can move price anywhere in an instant, but it can never, by itself, resolve a case. H(93%) = 1.966P (Section 2.6.9), a wider margin over the 0.995P sale-proceeds floor discussed below than either the 87% or 90% figures it replaces, and still comfortably below the $0.97–$0.99 range at which real-money prediction markets like Polymarket price genuinely settled outcomes (Section 2.6.5).

**This revision recalibrates the Spectral Market's resolution thresholds from 70%/75% to 87%/90% (Condition B / Condition A, Section 2.6.5), and adds an optional mutual early-resolution path for disputes with no third-party capital at risk (Section 2.6.10).**

Section 2.6.9's own H(p) relationship, applied to the 70%/75% thresholds used throughout every prior draft, shows that the capital required to force an uncontested resolution at those thresholds — 0.511P and 0.693P respectively — is less than the 0.995P in sale proceeds a seller holds unconditionally and immediately the moment any dispute opens (Section 2.4), regardless of whether that seller is guilty. A guilty seller could clear both of this document's own headline example thresholds using only the defrauded buyer's own payment, without risking a single unit of independent capital. This was always implied by Section 2.6.9's statement that a manipulator's realistic capital includes "(for a seller) the 0.995P sale proceeds," but no prior draft cross-referenced that statement against its own H(p) table to state the consequence plainly. That revision did. 87% (H = 1.347P) and 90% (H = 1.609P) both cleared the 0.995P floor with a margin of roughly a third, chosen so a guilty seller needed meaningfully more than their victim's own payment alone to attempt an uncontested resolution; both figures are superseded by the unified 93% condition above, which clears the same floor by a wider margin still — see Section 2.6.9 for the updated table and Section 2.6.5 for the deployed value.

A dispute with no third-party capital at risk also gains a second, optional exit: the buyer and seller may mutually agree to resolve it immediately rather than waiting on price discovery (Section 2.6.10). This is strictly narrower than it may first sound — the instant any outside address holds a share on either side, this path is permanently disabled for that dispute, precisely because resolving a market a third party has capital in is no longer a decision that only the original two parties are entitled to make (Section 5.3).

**A note on this document's name.** This is the seventh major public revision of this whitepaper — internally, v2.7. It is titled *The 27* instead of a version number, a choice made by the protocol's developer for identity and branding reasons: a bare version tag reads as an internal engineering artifact, and the developer wanted this document to carry a distinct public name going forward. This is a labeling change only. It does not indicate a larger scope of change than any other revision in this document's history — the single substantive change in that revision was the threshold recalibration stated above, itemized like every change in every version before it, exactly as the historical changes below are.

**Version 2.6 replaces the buyer-funded dispute bond with open, anyone-may-fund dispute capital, makes payment-to-dispute-eligibility sequencing atomic rather than implied, and adds a protocol-enforced floor on a parameter v2.5 left unspecified: how long an undisputed transaction stays open before it finalizes.**

v2.5 required the disputing buyer personally to post the 0.5P stake that opens the Spectral Market, matched by the seller's 0.5P. Under further review, this bond was doing two jobs at once, and conflating them obscured which job it was actually solving. The first job was preventing a dispute from attaching to a transaction that was never genuinely paid for. The second was preventing a dispute from being opened by a party who risks nothing of their own. v2.6 separates them and solves each directly. Section 2.3's atomic settlement now closes the first job structurally: a transaction cannot become dispute-eligible until the contract itself has verified full payment in the same atomic step that forwards proceeds to the seller — there is no window in which a dispute can attach to an unfunded transaction, regardless of any bond. The second job no longer requires the buyer specifically. Section 2.4 now allows any party — the buyer, or anyone their public evidence convinces — to fund the 0.5P that opens a dispute. A genuinely defrauded buyer without spare capital can recruit that stake from someone who finds their case credible; a fabricated claim, unable to attract genuine outside conviction, typically cannot clear the same bar. This is not a weaker floor than v2.5's bond. It is the same floor, sourced more flexibly, closing a real accessibility gap the bond left in Section 8.1 without reopening the zero-capital manipulation surface v2.4 originally had.

This version also states, for the first time, what happens to a transaction that nobody ever disputes. v2.5 left the trigger for final settlement of an undisputed transaction unspecified. v2.6 introduces the completion window (Section 2.5): a seller-configurable duration, bounded below by a protocol-enforced minimum, after which an undisputed transaction finalizes and its Locked IB releases. The floor exists because the incentive to shorten this window is not symmetric between honest and dishonest sellers, and Section 8.4 states why market self-selection alone cannot be relied on to police it.

Three smaller corrections accompany these changes. Section 2.6.2 now states plainly that evidence is submitted off-chain by design and referenced on-chain by content hash — the prior draft's "submitted on-chain" language was never literally achievable for media evidence at defensible cost and should not have implied otherwise. Section 4's payoff table now distinguishes a buyer's outcome by whether they personally funded the Guilty-side position or relied on outside backers, which resolves a numeric inconsistency between that table and the worked b=P example already present in Section 2.6.9, and corrects an arithmetic slip in the honest-trade row. Section 2.5 also states, for the first time, the Locked IB accounting for a listing supporting more than one simultaneous transaction slot.

No mechanism found sound under review has been weakened by any of these changes, including the threshold recalibration above or the subsequent unification onto a single cumulative condition. This document supersedes all prior versions.

No trust is required beyond the disclosed boundary. Only cold, rational self-interest — and the mathematics that governs it, stated once, completely.

---

## 1. The Problem with Traditional Escrow

Online transactions usually require a trusted third party to hold funds. This creates a fundamental asymmetry: the buyer controls release or withholding of payment, enabling extortion. Mediators can be bribed, make mistakes, or collude. Decentralized oracle systems with human juror panels suffer from a different class of failures: individual jurors can be identified and approached before verdicts are revealed; incentive structures reward conformity to perceived majority opinion rather than objective evidence; and receipt-freeness cannot be guaranteed without airtight cryptographic specifications.

Walendria Protocol removes discretionary escrow entirely and replaces both human judgment and oracle committees with two things: a mathematical bond structure that makes cheating strictly loss-making under adequate market participation, and a capital-backed prediction market that makes truth-finding profitable when that participation is present. Neither requires trust in any person or institution. Section 2.6.9 states, without euphemism, what happens when that participation is absent.

---

## 2. Core Mechanisms

### 2.1 Integrity Bond (IB)

Before creating any listing, a seller locks a single Integrity Bond into a public smart contract. The bond is non-withdrawable while backing any active listing (Section 2.5) or open transaction. It can only be slashed if the seller is found to have committed fraud. The minimum required IB for a transaction of price P is **1.5 x P**. The larger the bond, the more the seller can transact — and the more they lose if they cheat.

Sellers are presumed honest by default. No identity disclosure is required. No age verification. No physical or digital storefront. No prior reputation. The bond is the only credential — and it is sufficient, because it is financial.

### 2.2 Shared Integrity Bond (Shared IB)

For sellers who cannot immediately afford 1.5P of locked capital, a **Shared IB** pool exists. External depositors stake capital into a shared bond pool managed by a smart contract. Depositors receive pool tokens representing their proportional share. Sellers rent bond capacity from the pool by paying a recurring fee to depositors.

If a backed seller cheats, the pool is slashed proportionally. Depositors therefore have a direct financial incentive to vet and select the sellers they back. If the seller operates honestly, depositors earn fees. This transforms trust into a yield-bearing asset and solves the cold-start capital problem without loosening any security invariant.

**Lock guarantee, no exceptions:** the portion of pool capital backing any seller's active listing is locked under the exact same rule as direct IB (Section 2.1) — non-withdrawable until the listing closes or the transaction and any dispute resolve. A depositor may add capital to the pool at any time; a depositor may only withdraw the *unlocked* portion of their share. There is no mechanism, code path, or admin override by which a depositor can exit their locked share early to front-run an anticipated slash. A dispute that clears the 0.5P Guilty-side funding threshold (Section 2.4) draws a matching 0.5P from the backed seller's Locked IB — depositors backing high-dispute-rate sellers should price this into their fee terms.

New sellers may begin with small transactions, build a track record, accumulate revenue, and scale their own IB over time.

**Deployment status — specified and deployed, not yet integrated (this deployment).** The Shared IB pool is defined here and deployed as a standalone contract, but it is *not yet wired into the live protocol*: no listing on the current deployment is backed by pool capital, and no contract path yet rents pool capacity on a seller's behalf. Every listing today locks direct IB (Section 2.1) only. The unresolved piece is a consent question this section deliberately leaves open — *how* a pool selects and agrees to back a specific seller — which is a product-design decision rather than a protocol-math one; building it as an undocumented side effect was declined in favor of shipping direct-IB listings first. Two consequences follow and are disclosed here so no reader mistakes the mechanism above for something currently operational: (1) depositing into the pool on this deployment is idle capital, not active seller backing, so the cold-start mechanism this section describes, while specified, is not yet available in practice; and (2) the Section 2.6.10 restriction that mutual early resolution is unavailable on any Shared-IB-backed listing is presently satisfied *structurally* — no such listing can exist — rather than by a dedicated runtime check, which is the correct and safe posture until the integration above ships and is exactly where that check must be added when it does.

### 2.3 Atomic Settlement

The buyer pays into the smart contract — not directly to the seller's wallet. In a single atomic call, the contract:

1. Verifies the amount received is at least P. If less than P was sent, the entire call reverts and any funds sent are returned; there is no partial-payment state that persists.
2. Refunds any amount received in excess of P, in the same transaction.
3. Deducts the **0.5% Developer Fee** (0.005 x P) and routes it to the Developer Pool.
4. Forwards the remainder (0.995 x P) to the seller's wallet.
5. Marks the transaction **dispute-eligible** (Section 2.5).

All five effects happen together or none do. There is no intermediate state in which payment has partially landed, and no state in which a transaction is dispute-eligible without the contract itself having verified full payment.

This is deliberately not the discretionary escrow Section 1 argues against. Traditional escrow's failure mode is a party who holds funds and decides whether or when to release them — a decision that can be delayed, bribed, or gotten wrong. Here, no party decides anything: the contract's role is a single, non-discretionary, atomic pass-through, with no holding period between confirmation and payout. The buyer loses the ability to hold funds hostage — the classical buyer-extortion vector is eliminated at the structural level — and because the same atomic step is what makes a transaction dispute-eligible, no dispute can ever attach to a transaction whose payment the contract never actually verified (Section 2.4).

### 2.4 Dispute Funding and Market Opening

A buyer who believes they have been defrauded may publicize their case; opening a dispute itself requires no application and no permission, only capital. What opens the Spectral Market is not a filing transaction but the accumulation of real money on the Guilty side: any address — the buyer, a friend the buyer convinces, a stranger who finds the buyer's public evidence credible, or several of these together — may purchase **"Seller Guilty"** shares against the transaction. Before this accumulates to 0.5P, there is no dispute object in the contract, no additional draw against the seller's IB, and no change to the transaction's ordinary path toward its completion window (Section 2.5).

The moment cumulative Guilty-side purchases reach 0.5P, that capital is locked as the market's initial Guilty-side position — credited to whichever addresses funded it, in proportion to their contribution — and this threshold crossing, not a separate act of filing, is what opens the dispute. In the same atomic step, the seller's Locked IB contributes a matching **0.5P** to purchase **"Seller Innocent"** shares, credited to the seller. Both positions are computed as a single joint state transition against the market's starting point, never as two sequential trades (Section 2.6.1) — the seller's IB is therefore never touched until real, externally-verified conviction already exists on the other side.

**Who may fund the Guilty side, and why this is not a weaker floor.** A genuinely defrauded buyer who lacks 0.5P of spare capital is not excluded from disputing — they are asked to make their case publicly (Section 2.6.2) and let anyone who finds it credible put capital behind it, which Section 2.6.3 and Section 8.3 already establish is a rational, profit-seeking trade for that backer, not a favor. A fabricated claim faces the identical requirement and typically cannot clear it: convincing a stranger to risk money on a story is a materially higher bar than convincing them to click a free filing button, and a would-be manipulator unable to clear that bar with real outside capital is left exactly where a manipulator with zero capital was under any bonded design — unable to open a contest at all. Where a manipulator is willing to fund the 0.5P themselves, the floor functions exactly as it did under a mandatory bond: they must risk real money to find out whether anyone contests it (Section 2.6.9).

**The seller's defense is not limited to the drawn 0.5P.** By the time a dispute opens, the seller already holds the 0.995P sale proceeds in a liquid wallet, forwarded automatically at atomic settlement (Section 2.3) — money the buyer themselves transferred. Nothing in the protocol prevents the seller from using that capital to buy additional "Innocent" shares. If the seller is in fact innocent, doing so is a positive-expected-value trade for the same reason any correctly-informed trade is positive-expected-value (Section 2.6.3): the seller is not spending money to "buy a verdict," they are buying shares in an outcome they know to be true. This gives every seller — not just well-capitalized ones — a direct, low-friction, financially rational tool to contest a false dispute, and because the seller's Locked IB is never drawn until real opposing capital already exists, no seller is ever asked to defend against a threat that cost its maker nothing.

**Below-threshold Guilty-side funding is reclaimable, never stranded.** Capital contributed toward the 0.5P threshold is held as pending liquidity, not spent, for as long as the funding window remains open. If that window closes before cumulative funding reaches 0.5P — the completion window elapses, the buyer confirms receipt, or the slot is otherwise recycled for resale (Section 2.5) — no dispute ever opens, no matching IB is ever drawn, and the accumulated contributions never become market positions. In that case every contributor may withdraw their exact contribution back in full. This funding is *locked* while the contest is live, in the same enforced sense the initial positions are once a dispute does open (Section 2.6.1), but it is never forfeited to anyone: a contribution that fails to open a dispute belongs to the contributor and returns to them on demand, at any scale, with no residue left in the contract. This closes what would otherwise be a fund-loss trap for exactly the under-capitalized, genuinely-defrauded buyer this protocol is most concerned with (Section 8.1) — one who assembles part of the 0.5P but does not clear it in time loses their payment to the failed transaction, but not, on top of that, the funding they staked trying to contest it.

### 2.5 Locked IB, the Listing Lifecycle, and the Completion Window

A seller commits Locked IB per listing, not per trade in progress. Creating a listing for a transaction of price P, supporting N simultaneous transaction slots (N = 1 by default), locks **1.5 x P x N** of the seller's total IB immediately — before any buyer has appeared. The remaining balance is Free IB.

> **Total Locked IB across all active listings <= Total IB**

Locking at listing time, rather than at the moment a specific buyer pays, removes any race between two buyers competing for the same seller's limited free capacity: capacity is reserved when the listing goes live, not contested later. A seller may close or reduce a listing at any time, releasing the corresponding IB back to Free IB — **except** for any slot whose payment has already been confirmed by the contract (Section 2.3). Payment confirmation and listing cancellation are mutually exclusive outcomes for a given slot; whichever the chain executes first is final, and a confirmed slot proceeds only through the completion or dispute path below, never through unilateral seller cancellation.

**The completion window.** Every listing specifies a completion window: a duration, starting at payment confirmation, during which the transaction remains open to dispute funding (Section 2.4). A buyer satisfied before the window elapses may confirm receipt directly, waiving the remainder of that window immediately; otherwise the window elapsing with no dispute ever reaching the 0.5P funding threshold finalizes the transaction automatically. Either way, the slot returns to Empty rather than closing permanently: its Locked IB is untouched by an undisputed completion, so the same 1.5P continues backing that slot index for whichever buyer pays it next - a seller offering a repeatable good or service is never required to create a new listing at the same price just to keep selling. A seller who instead wants to stop offering a given slot reclaims its Locked IB at any time it is sitting Empty, whether never yet sold or freshly recycled, through the same close-or-reduce mechanism above. If a dispute does open within the window, the slot stays locked pending resolution regardless of how much of the window remained - and, win or lose, that dispute permanently retires the slot: Section 2.6.1's 0.5P joint-injection draw already commits half its collateral irreversibly the instant the dispute opens, before any verdict exists, so nothing remains that could back a fresh sale of that same slot even on a verdict clearing the seller.

The window's length is set by the seller, per listing type — buyers who consider a given window too short to reasonably notice and respond to a problem are free to decline the transaction, and a seller who wants more buyers is free to lengthen it. This alone is not a sufficient safeguard, and this document does not treat it as one: an honest seller loses only capital-efficiency from a longer window, while a dishonest one gains something categorically different — the specific ability to outlast a genuinely defrauded buyer's need to notice a problem, gather evidence, publicize it, and recruit 0.5P of Guilty-side conviction (Section 2.4) before the window closes, a process realistically measured in hours to days for anyone without a pre-existing audience, not minutes. Because the incentive to shorten the window is asymmetric — weak for honest sellers, strong for dishonest ones — buyer self-selection alone cannot be relied on to discipline it (Section 8.4). The protocol therefore enforces a **minimum completion window** as a deployment-time constant, set to **72 hours** from payment confirmation for this deployment (Section 2.9): sellers may offer a longer window; none may offer shorter.

**If a dispute opens against an active transaction**, 0.5P of that seller's Locked IB is drawn only once the Guilty side independently reaches 0.5P (Section 2.4); the remaining 1.0P stays locked pending resolution, regardless of how much time was left on the completion window when the dispute opened — an open dispute is never subject to the window's expiry.

### 2.6 The Spectral Market

The Spectral Market is a purpose-built on-chain prediction market serving as the dispute resolution engine. There are no designated jurors. There are no hidden votes. Anyone may participate. Capital decides — Section 2.6.9 states precisely what "capital decides" means when only one side's capital shows up.

#### 2.6.1 Initial Positions and Their Joint Funding

A dispute opens the instant cumulative purchases of "Seller Guilty" shares — from the buyer, from anyone backing the buyer's public case, or any combination — reach 0.5P (Section 2.4). At that instant, two things happen as one atomic state transition, not as sequential trades:

1. The accumulated **0.5P** of Guilty-side purchases is locked as the market's initial Guilty position, credited to whichever addresses funded it, in proportion to their contribution.
2. **0.5P**, drawn from the seller's Locked IB, auto-purchases **"Seller Innocent"** shares, credited to the seller.

Both positions are solved jointly against the market's starting state, not one after the other. This matters: if the two positions were bought in sequence, whichever side moved second would be buying into a market already tilted by the first trade, and would receive more shares per dollar at a price already favoring their side — a free, evidence-independent head start with no basis in the case's merits. Computing both positions as a single joint injection removes this artifact entirely; the market opens at an unbiased 50/50 price regardless of how many separate addresses funded either side, or in what order their individual transactions were broadcast.

Both positions are locked until the case resolves — locked in the literal, enforced sense: neither the Guilty-side funders nor the seller can *sell* the shares this joint injection credits them. That opening stake stays in the market as permanent liquidity for the dispute's entire life; it can only be redeemed (if it wins) or forfeited (if it loses) at resolution, never sold back mid-dispute for a risk-free exit. Only shares bought *afterward* on the open market (Section 2.6.3) carry no such lock and are freely tradeable — selling those is what moves the price, while the 1P of opening depth (0.5P per side) can never be withdrawn early by the very parties that seeded it. This creates initial market liquidity of **1P total** (0.5P per side), capitalized only once real, externally-verified conviction exists on the Guilty side — the seller's IB is never drawn against a claim that has not itself already attracted 0.5P of real capital. This is always exactly 1P, at any transaction size, with no floor or subsidy applied in either direction (Section 2.6.7).

#### 2.6.2 Evidence Specification

Evidence is submitted off-chain by design and referenced on-chain by content hash at the moment of submission. Video, audio, and high-resolution images cannot be stored on any current chain at a defensible gas cost, and this document does not claim otherwise. In practice, evidence lives on participants' own social channels or on a purpose-built companion feed, made publicly reachable to all market participants; the on-chain record is the hash, not the content, so that the record used for resolution cannot be silently edited or deleted after submission even if the live post is. The protocol does not pre-filter, validate, or adjudicate evidence — the market weighs it collectively through capital-staking.

- **Accepted formats**: All document types — text, images, video, audio, metadata, on-chain transaction records, and any other format — hosted off-chain, hash-committed on-chain at submission.
- **Permitted submitters**: Both buyer and seller may submit evidence at any time.
- **Submission deadline**: None, while the market remains open.
- **Contradictory evidence**: Both sets remain publicly visible. It is each party's responsibility to argue their position effectively — the same way courts handle conflicting testimony. The protocol does not determine which evidence is true; the market does, when a market with genuine participants exists to do it (Section 2.6.9).
- **Public visibility as a mechanism, not a side effect**: because Guilty-side funding is open to anyone (Section 2.4), a publicly compelling case is not merely a matter of record — it is the direct means by which a genuine claimant recruits the capital needed to open a dispute at all (Section 8.3).

#### 2.6.3 Open Market Phase

After the initial positions are set, the Spectral Market opens to all external participants. Any party may purchase "Seller Guilty" or "Seller Innocent" shares based on their assessment of the publicly available evidence.

Settlement payoff is fixed: **every winning share pays up to $1.00**, regardless of purchase price, capped at whatever the market's own pool actually holds at redemption time. That cap is not a theoretical footnote: Section 2.6.9's Boundary Theorem is exactly the statement that a heavily-traded winning side can be credited more in shares than the pool collected in payment for them, and a real Chiado dispute has already hit this - see the disclosure at the end of 2.6.9.

- A trader who buys "Guilty" at $.40 and wins: **150% return, 2.5x their capital.**
- A trader who buys "Guilty" at $.70 and wins: **~43% return.**
- A trader who buys "Guilty" at $.90 and wins: **~11% return.**

The Spectral Market rewards those who correctly identify the truth earliest and most aggressively. This is also, precisely, why a genuinely defrauded buyer publicizing their case is not appealing to charity — they are offering real, calculable financial upside to anyone who verifies the evidence and agrees (Section 8.3).

#### 2.6.4 The LMSR Bonding Curve

The Spectral Market uses the **Logarithmic Market Scoring Rule (LMSR)** as its pricing mechanism.

**Formal Specification:**

```
C(q_G, q_I) = b * ln(exp(q_G / b) + exp(q_I / b))
```

where q_G and q_I are total Guilty/Innocent shares outstanding, and b is a liquidity parameter calibrated proportionally to P at dispute creation — b = 1 x P for this deployment (Section 2.6.1), with no floor or ceiling applied at any transaction size (Section 2.6.7).

```
p_G = exp(q_G / b) / (exp(q_G / b) + exp(q_I / b))
```

Price of Innocent: p_I = 1 - p_G. Prices always sum to 1 and remain strictly bounded in (0, 1). The correct proportionality constant for b is a deployment-time trade-off, not a universal one — Section 2.6.9 formally derives the relationship between b, the resolution threshold, and the capital required to force an uncontested outcome.

**Path Independence — Proof Against Multi-Wallet Coordinated Attacks:**

The cost to move from state (q_G_0, q_I_0) to (q_G_1, q_I_1) is `dC = C(q_G_1, q_I_1) - C(q_G_0, q_I_0)`, which depends only on the initial and final states — not on the number of transactions, wallets, or the sequence of purchases.

**Proof (two-wallet case, generalizes to N wallets):** if wallet_1 buys dq_1 Guilty shares, then wallet_2 buys dq_2 Guilty shares, the sum of their individual costs telescopes to `C(q_G_0 + dq_1 + dq_2, q_I_0) - C(q_G_0, q_I_0)` — identical to one wallet buying (dq_1 + dq_2) in a single transaction. QED.

**Consequence:** a 1,000-wallet coordinated attack costs exactly the same in aggregate as one wallet buying the same total volume. Multi-wallet coordination provides zero mathematical advantage, closing the "spray-and-pray" class of attack entirely, regardless of participation levels. It does not, on its own, address a single actor trading alone against no opponent at all — that case is the subject of Section 2.6.9. The same path-independence is why Section 2.6.1's joint funding of the initial positions is order-independent once both sides have actually been purchased — it is *when* the two sides are purchased relative to each other, not by how many wallets, that can introduce an artifact, which is why they are solved jointly rather than sequentially.

#### 2.6.5 The Settlement Condition

**Cumulative Stability — the sole resolution condition.** A cumulative (stopwatch-style) timer tracks total time either side's price remains at or above **93%**. The timer pauses below 93% — it does not reset. Once cumulative time above 93% reaches **1 hour** for this deployment, the case resolves. There is no separate instant-resolution path at any price: a single transaction may move price arbitrarily far in one step — to 93%, to 99%, to anywhere below 100% — but no price, however high, ever resolves a case in the same transaction that reaches it. This duration is not the mechanism's only security property — the "pauses, never resets" behavior is what defeats a cheap timer-reset attempt, regardless of the duration chosen — its additional job, since a prior revision's separate instant threshold was retired, is guaranteeing every participant a fixed, computable minimum reaction window before any dispute can resolve via price, independent of how much capital a single actor deploys in a single transaction.

**Why the instant-resolution path was retired.** A prior revision resolved a case the instant either side's price touched 90% in a single transaction. This let one sufficiently capitalized trade force an irreversible resolution with zero reaction time for any other participant — a "one-shot" attack: a party who could afford to cross 90% in one step captured the outcome before anyone else had a chance to notice the price move, let alone counter-trade it, no matter how transient or narrow the crossing was. Retiring that path closes the gap structurally rather than merely disclosing it: every crossing, at every price, now only ever contributes elapsed time to the same pausable timer described below, and a counter-trader who notices within the 1-hour window can push price back below 93% at any moment, pausing the clock exactly as it already paused against a slower version of the same attack.

The cumulative condition eliminates cheap timer-reset attacks the same way it always did: momentarily pushing price below 93% gains nothing. Preventing resolution requires sustaining price suppression for longer than all accumulated consensus time — a continuously loss-making activity against genuine counter-trading. Section 2.6.9 addresses the case where no counter-trading exists to sustain in the first place. The threshold value (93%) is a deployment parameter, chosen so that H(p) (Section 2.6.9) clears the 0.995P a seller unconditionally holds in sale proceeds the moment a dispute opens, with a wide margin, and so that the 1-hour duration gives genuine participants a real, fixed window to respond to any price move, of any size, before it can resolve anything. Raising the threshold further, or lengthening the duration, trades resolution speed — for contested and uncontested cases alike — for a higher minimum capital requirement or a longer guaranteed reaction window, respectively (Section 2.6.9).

**Why 93% is conservative relative to how real markets price certainty, not loose.** Measured against genuinely near-certain outcomes rather than against this document's own earlier (70%/75%, then 87%/90%) drafts, 93% sits meaningfully below where a liquid, real-money prediction market prices an outcome once it is publicly and unambiguously known. Polymarket, cited elsewhere in this document (Section 8.3) as a peer system, routinely prices such outcomes at $0.97–$0.99 before treating them as settled — a genuinely obvious case is not one where price barely clears the resolution bar, it is one where price runs well past it. A dispute with evidence that clear reaches 93% as a byproduct of that same clarity, not because anyone paid above what the evidence supports to force it there. The threshold is a live concern only for a dispute that remains genuinely, irreducibly ambiguous even after full investigation and publicity — addressed directly in Section 8.5, not assumed away here.

#### 2.6.6 Developer Protocol Surplus

Winning shares pay up to $1.00 each, capped at whatever the pool still holds if a heavily-traded market ran it short (Section 2.6.9), drawn from the total pool collected from all trading on both sides over the market's life — a losing position's capital funds the winning side's payout, not a void. The **surplus** — the difference between total pool funds and total required payout, arising because losing trades are made at prices whose sum does not perfectly match the winning payout obligation — is disposed of in two steps at resolution: first, **0.1% of the transaction price P is paid to whichever address successfully called `pokeSettlement`** (Section 2.6.8) as the resolution bounty, capped at whatever the surplus actually holds; then the remainder transfers to the Developer Pool. This surplus is generated almost exclusively by failed manipulators and late-moving arbitragers with thin margins; honest early participants retain the majority of their profit. A quiet dispute with little or no such trading leaves little or no surplus, so both the bounty and the Developer Pool's cut approach zero for it — the developer's reliable revenue is the flat 0.5% transaction fee (Section 2.7), assessed on every completed transaction regardless of whether it is ever disputed, not this variable surplus.

#### 2.6.7 No Minimum Liquidity Floor

Prior revisions of this document (through The 27) automatically topped up any dispute's initial 1P depth to a $5-equivalent floor, funded from the Developer Pool, whenever a transaction's own price left that depth thinner. **This document retires that mechanism entirely.** Initial market depth is always exactly 1P (Section 2.6.1), for a transaction of any size, with no subsidy applied in either direction, and no minimum imposed.

This is a deliberate choice, not an oversight. The former floor never protected the Boundary Theorem's core guarantee (Section 2.6.9): H(p), the capital required to force an uncontested resolution, is proportional to b, itself proportional to P (Section 2.6.4), so the ratio between that requirement and a manipulator's realistic available capital is identical at every transaction size — a $5 floor changed nothing about that ratio, whether the underlying transaction cleared it on its own or not. What a depth floor did add was thicker order books for small-P disputes, making it costlier for even a single honest bettor to move price with a small trade — a genuine, disclosed trade-off (see Section 9's revised entry on thin markets), traded away here for a different and, this document holds, more important principle: **Walendria imposes no minimum transaction size, anywhere in the world.** A fixed-dollar floor, at $5 or any other figure, is a culturally and economically relative judgment about what counts as a "real" or "meaningful" amount of money — a judgment this protocol declines to make on anyone's behalf. Every dispute's market depth is exactly what its own transaction supports; no transaction is inflated to resemble a larger one to make its resolution look more legitimate, and none needs to be.

#### 2.6.8 Deterministic Settlement Guarantee — The Checkpoint-and-Poke Mechanism

This section specifies how the resolution condition resolves in every case, including when price crosses 93% and no further trade ever occurs. No oracle, off-chain timer, or designated keeper is required.

Because LMSR price only changes when a trade executes, elapsed time at a given price is exactly computable by any observer from on-chain trade timestamps alone — never estimated.

**Mechanism:**

1. **Checkpoint on every trade.** Before any buy/sell is applied, the contract adds elapsed time to whichever side was above 93% since the last checkpoint, then applies the trade and updates state. Paid for by the trader's own gas.
2. **No instant resolution at any price.** A single transaction may move price arbitrarily far in one step — to 93%, to 99%, to anywhere below 100% — but no trade resolves a case by itself; every crossing only ever contributes elapsed time to the same cumulative timer in point 1, with no separate fast path at a higher price.
3. **Permissionless poke function.** Any address, at any time, may call `pokeSettlement`, which re-runs the checkpoint against the current block timestamp and resolves the case if the accumulated-time threshold has been reached — no whitelist, no special permission.
4. **The resolution timestamp is public and computable in advance**, because price cannot change without a trade, and any trade would itself trigger a fresh checkpoint.
5. **Bounty funding, from the market's own surplus.** Whoever successfully calls `pokeSettlement` at or after the computed resolution time is paid a bounty of **0.1% of the transaction price P** — scaling the same way market depth already does (Section 2.6.1), rather than a single constant assumed to fit every transaction size — paid from the resolved market's settlement surplus (Section 2.6.6), capped at whatever that surplus holds, with no pre-funded pool and no subsidy drawn from anywhere else. In a *contested* dispute the surplus comfortably exceeds 0.1% of P, so this creates an open, competitive race among independent bots and keepers to resolve it. In a *quiet* dispute — only the two forced initial positions, no counter-trading — the surplus is near zero, so a third party has little to earn by poking. The timing guarantee does not weaken there, because it does not rest on the third-party bounty at all: the winning side holds its entire payout behind the poke and is therefore always strictly incentivized to call `pokeSettlement` itself. The case resolves at its computed time because at minimum the winner wants their money — the external bounty is redundancy that matters most exactly where surplus exists to fund it, and is not load-bearing where it does not.

This closes the *timing* gap — a case can never hang indefinitely. It says nothing about whether the price it resolves at reflects genuine contested evidence or a single uncontested actor; that question is answered separately in Section 2.6.9.

**Implementation note (chain-agnostic):** this mechanism does not require Chainlink Automation, Gelato, or any specific keeper network — it is self-incentivizing by construction. Where such networks exist, they may register the poke function as additional redundancy, but correctness does not depend on it.

#### 2.6.9 Boundary Theorem: Cost-Payout Relationship in Uncontested Resolution

This section states, once and formally, a mathematical limitation shared by any LMSR-based market — or any bounded-price, proper-scoring-rule prediction market of any shape.

**Theorem.** For any cost function C(q) whose marginal price remains strictly bounded in (0,1) — required for the market to represent valid probabilities (Section 2.6.4) — the cost to acquire Q shares of an outcome is strictly less than the payout if the outcome resolves in their favor:

```
Cost(Q) = C(Q) - C(0) = Integral[0 to Q] price(q) dq  <  Integral[0 to Q] 1 dq  =  Q times $1
```

because price(q) < 1 for every finite q.

**Consequence.** In a dispute where one party can single-handedly determine the resolution — because no independent, informed capital opposes their trades — acquiring a winning position at any price below the resolution threshold is unconditionally profitable, for any LMSR calibration and any threshold below 100%. This holds for every valid probability-consistent curve, not only the logarithmic form in Section 2.6.4, and it is not specific to Walendria's calibration — it is the boundary condition governing every AMM-based prediction market ever deployed (Section 2.9).

**What the funding floor changes, and what it does not.** Requiring 0.5P of real Guilty-side conviction — from any source — before the market opens, matched by the seller's 0.5P, raises the minimum committed capital anyone needs before attempting to control an uncontested resolution, exactly as a bond would. Sourcing that 0.5P from any willing party rather than the buyer alone does not lower this floor: a manipulator with no genuine case still has to either risk their own money or persuade someone else to risk money on a story that person has no independent reason to believe, and the second path is generally the harder one. This is a genuine floor, not a cosmetic one: it removes the zero-capital class of manipulation attempt entirely. It does **not** change the sign of the theorem above. A party willing to lose 0.5P — their own, or successfully solicited from someone else — to win a larger uncontested payout still profits from doing so, for exactly the same reason a party willing to lose nothing did. The funding floor raises the price of attempting manipulation; only the threshold-and-b calibration below raises the price of *succeeding* at it.

**The same asymmetry can leave the pool short at redemption, not just profitable to attack.** Cost(Q) < Q dollars is the same inequality whether the buyer is a manipulator or an honest late-moving trader on the side that goes on to win - either way, the pool collects less than the $1-per-share it now owes that trader. In the worst case this shortfall approaches `b * ln(2)`, a standard, computable LMSR bound, independent of P's scale (Section 2.6.4). This is not hypothetical: a real dispute on the Chiado deployment hit almost exactly this bound after a single large post-open Guilty-side buy, leaving the pool unable to pay the full claim of whichever winning-side holder redeemed last. The contract's response is to pay that redemption whatever the pool still holds rather than reverting to zero (Section 2.6.3) - a partial, final payout is strictly better than a claim stuck forever behind a revert, since nothing in this design ever tops the pool back up after resolution. This is the same trade-off Section 2.6.7 already made explicit for market depth: no subsidy is layered on top of the curve's own bounded-loss property, in either direction.

**The lever this protocol exposes, honestly: threshold as a capital wall, not a profitability deterrent.** Raising the resolution threshold p does not change the sign of the manipulator's profit, but it raises the absolute capital H required to reach it:

```
H(p) = b * [ ln(1 + p/(1-p)) - ln(2) ]
```

Example, for a transaction of price P with b set equal to P — this ratio holds at any P, however small or large, since both H and a manipulator's realistic capital (their share of the 0.5P stake, or a guilty seller's 0.995P sale proceeds) scale together with P:

| Threshold p | H required | Manipulator profit if uncontested | Return on H |
|---|---|---|---|
| 70% | 0.511 x P | 0.337 x P | 66% |
| 75% | 0.693 x P | 0.405 x P | 58% |
| 80% | 0.916 x P | 0.470 x P | 51% |
| 85% | 1.204 x P | 0.531 x P | 44% |
| 87% | 1.347 x P | 0.554 x P | 41% |
| 90% | 1.609 x P | 0.588 x P | 37% |
| **93%** † | **1.966 x P** | **0.621 x P** | **32%** |
| 95% | 2.303 x P | 0.642 x P | 28% |
| 99% | 3.912 x P | 0.683 x P | 17% |

† Deployed value for this deployment (Section 2.6.5), chosen primarily to close the one-shot instant-resolution gap described there — no threshold, however high, resolves a case without the mechanism's mandatory 1-hour cumulative confirmation — and secondarily because it clears the 0.995P floor (the sale proceeds every seller holds unconditionally the instant a dispute opens, Section 2.4) by a wider margin than the 87%/90% pair used in a prior revision, which is no longer deployed. 87% and 90% remain in the table above only to illustrate the general shape of the H(p) relationship across a spread of round-number thresholds.

H grows without bound as p approaches 100%, while a manipulator's realistic available capital is bounded by whatever they are willing to lose beyond their share of the forced 0.5P stake, plus (for a seller) the 0.995P sale proceeds. A deployer can choose a threshold at which H(p) exceeds a manipulator's plausible available capital for a given transaction size, making an uncontested single-actor attack **capital-infeasible**, not merely unprofitable-on-average. Deployers should treat threshold and b jointly as this trade-off, sized to the transaction-size distribution they expect (Section 2.9).

Section 8.3 discusses the remaining, non-curve-based mitigations that apply once this boundary is disclosed.

#### 2.6.10 Mutual Early Resolution

Section 2.6.5 describes how a dispute resolves when the Spectral Market runs its course, and Section 8.5 discloses what happens when a genuinely ambiguous one does not. A dispute with no third-party capital at risk has a third option: the buyer and seller may jointly agree to resolve it immediately, without waiting for price to reach 93%.

**Scope: available only while the dispute has no third-party participation.** This path exists only when the buyer — not backers — funded 100% of the Guilty-side position, and no other address has purchased shares on either side during the open market phase (Section 2.6.3). This is checked on-chain as a strict invariant, not a policy: the buyer's Guilty-share balance must equal total Guilty shares outstanding, and symmetrically, the seller's IB-funded Innocent-share balance must equal total Innocent shares outstanding. The instant any *other* address holds a share on either side, this path is permanently and irrevocably disabled for that dispute — it does not reopen even if that address later exits their position.

The same principle extends to the seller's side of the bond, not only the market side. This path is unavailable if any portion of the seller's Locked IB backing this listing is Shared IB (Section 2.2) rather than 100% direct IB (Section 2.1). A seller backed even partially by pool depositors is not the sole party with capital at risk in a Guilty verdict — depositors are, without having agreed to anything — and letting that seller unilaterally consent to a slash on their own behalf would expose depositors to exactly the collusion risk this section otherwise closes for Spectral Market backers. A seller who wants access to mutual early resolution for a given listing must back that listing with direct IB alone. *(On the current deployment this restriction is guaranteed structurally rather than by a runtime check, because no Shared-IB-backed listing can exist yet — see Section 2.2's deployment-status note. When Shared IB is integrated, the explicit check belongs here.)*

**Mechanism.** The buyer and the seller each call a `mutualClose(verdict)` function specifying the same verdict — Guilty or Innocent. Once both calls agree, the market resolves immediately to that verdict, triggering the identical payout mechanics of Section 3.1 or 3.2 as though the verdict had been reached by threshold-crossing. A call from only one party, or two calls specifying different verdicts, changes nothing — this is mutual consent, not a majority vote of two.

**Why the scope restriction is not optional.** Once a third party has capital staked on either side, resolving the case is no longer a decision that affects only the buyer and seller — it determines whether that third party's shares are worth $1 or $0. Letting the two original parties jointly override that outcome, even in good faith, would let them settle a private disagreement (or a private side-payment invisible to the contract) at a third party's expense — exactly the unilateral power over an outcome Section 5.3 says no individual should hold under adequate participation. Restricting this path to disputes no third party has ever entered removes that risk entirely: a mutual close under this scope only ever moves money between the two parties who were already exposed to each other's decisions from the moment the original transaction occurred.

**Why this is useful.** A dispute the buyer funded entirely themselves, where the seller recognizes a genuine mistake — or the buyer recognizes their claim was weaker than they thought — has no need to wait on price discovery neither party actually disputes the outcome of; mutual close releases the seller's uncommitted IB and settles the case in one step instead of requiring price to organically grind to threshold. It is also a narrow escape hatch for exactly the case Section 8.5 discloses as deliberately left open: a genuinely ambiguous dispute that never attracted outside backers can still end, by the two original parties simply agreeing to stop contesting it, even though the market alone never would have resolved it.

### 2.7 Developer Transaction Fee

A fixed fee of **0.5% of P** is assessed on every buyer-to-seller payment at the time of transaction, regardless of whether the transaction completes smoothly or proceeds to dispute. Automatically deducted by the contract, routed to the Developer Pool, non-refundable under all circumstances, applied only to the original transaction amount — not to dispute-market trades or IB deposits.

The developer may designate any Ethereum-compatible wallet as the withdrawal recipient, updatable at any time without affecting any active transaction, open dispute, or Spectral Market.

The 0.5% fee is the cost of accessing the Walendria infrastructure. It does not alter the dominant strategy analysis under adequate participation (Section 4): honest trading (+0.995P) is still strictly preferred over getting caught cheating (net approximately -0.505P) for all P greater than 0.

### 2.8 Contract Immutability

The Walendria Protocol smart contract is deployed **immutably**. No upgrade mechanism, no admin key held by any party after deployment. The contract cannot be paused, modified, or redeployed to the same address. Any revision to protocol logic requires fresh deployment at a new contract address, which all participants would need to consciously and independently adopt.

The system is not merely trustless in design; it is trustless in execution. The only parameter the developer may update post-deployment is the Developer Pool withdrawal address, which affects only where fees are sent, not how the protocol operates — it is the single mutable value in the entire contract; every other parameter is fixed permanently at deployment. Because the contract is immutable, the threshold and b calibration discussed in Section 2.6.9, the minimum completion window discussed in Section 2.5, and the per-transaction value hardcap discussed in Section 9 must all be chosen correctly before deployment.

### 2.9 Deployment Chain Considerations

Walendria's mechanisms are chain-agnostic by design. Chain selection is a deployment decision governed by two practical factors:

1. **Fixed-point math tooling.** LMSR requires exponential and logarithm functions unsupported natively by the EVM or WASM VMs. Multiple independently audited fixed-point libraries already implement this (e.g., PRBMath, ABDKMath64x64), and LMSR itself has prior audited implementations in production (Gnosis, Augur) to draw on.
2. **Keeper ecosystem depth.** Section 2.6.8's guarantee holds on any chain, since it is self-incentivizing by construction. It is strengthened in practice by existing keeper networks (Chainlink Automation, Gelato) that lower real-world latency, and by deeper existing trader liquidity that strengthens Section 6's counter-trading guarantee — liquidity that is precisely what makes Section 2.6.9's uncontested-manipulation boundary irrelevant in practice for a given deployment.

Both factors currently favor mature, sufficiently decentralized EVM environments over newer non-EVM environments, as a matter of ecosystem maturity, not a protocol-level requirement. This deployment targets **Gnosis Chain**: 145,000+ independent validators and GnosisDAO governance (no single corporate sequencer operator, unlike a company-run L2), sub-cent gas fees, live Chainlink Automation and Gelato support, and prior audited LMSR/prediction-market precedent from Gnosis's own Omen already cited above — a chain whose validator set and governance structure carries no single identifiable corporate choke point comparable to a company-operated L2 sequencer.

**Calibration addendum:** a deployer should set the resolution threshold, its cumulative duration, and b as a function of the target transaction-size distribution, using the H(p) relationship in Section 2.6.9 to ensure the capital required for an uncontested attack exceeds what a typical claim's funding, a seller's IB, or sale proceeds can fund for that size class. A deployment intended for very small transactions carries a smaller absolute H at any given threshold — H scales with P by construction (Section 2.6.9), with no floor beneath it (Section 2.6.7) — and should either set a higher threshold for that class or disclose the resulting H explicitly to users (Section 8.3). The minimum completion window (Section 2.5, 8.4) is a separate calibration choice governed by a different trade-off: long enough that a genuine buyer without a pre-existing audience has a realistic chance to recruit 0.5P of Guilty-side conviction, short enough that honest sellers are not made to carry Locked IB longer than the goods or service category plausibly requires. This deployment applies the threshold method concretely at 93% (Section 2.6.5), sized to clear a guilty seller's unconditional 0.995P sale-proceeds capital with a wide margin; a deployer targeting a materially different transaction-size distribution should re-derive this number from H(p) rather than reuse it directly. The minimum completion window for this deployment is set to 72 hours (Section 2.5), chosen to cover a full weekend and multiple timezones for the social process of recruiting Guilty-side backers (Section 8.4) without holding an honest seller's capital longer than that. The resolution condition's cumulative-time duration (Section 2.6.5) is set to 1 hour, chosen to give any counter-trading participant a fixed, guaranteed minimum reaction window against a price move of any size, including one that instantaneously reaches 99% or higher in a single transaction — since the reset-resistance comes from the pause-not-reset property rather than the duration itself, lengthening this window trades resolution speed for a larger reaction margin, not additional manipulation resistance.

---

## 3. Dispute Outcomes

### 3.1 Seller Guilty

- The seller's "Innocent" position (0.5P, drawn from Locked IB) resolves worthless. The Guilty-side position (0.5P, from whoever funded it under Section 2.4) pays out in full to those holding the winning shares, in proportion to what they bought and at what price (Section 2.6.3).
- The seller's remaining **1.0P** Locked IB is slashed and paid directly to the **buyer** as restitution — regardless of who funded the Guilty-side position. Restitution compensates the defrauded party; the share payout compensates whoever correctly traded, and these are not always the same address.
- **Total seller IB loss: 1.5P.**
- **Buyer net, canonical case (Guilty side backed by others):** the 1.0P restitution recovers the value of the original payment. Only sustained loss: the 0.5% Developer Fee, non-refundable in all cases — this is the baseline used in Section 4.
- **Buyer net, if the buyer personally funded some or all of the Guilty position:** the same restitution, plus the winning-share payout on whatever they personally bought, at whatever price they bought it — a real trading profit, for the same reason any correctly-informed position is profitable (Section 2.6.3). A buyer with spare capital is never prevented from taking this position themselves; doing so is strictly better than relying entirely on backers, never worse.
- **Backer net:** whoever funded the winning Guilty-side shares earns the same return any correctly-informed trader earns (Section 2.6.3) — this return, not charity, is what makes backing a genuine claim a rational trade in the first place.
- **Seller net:** received 0.995P initially, lost 1.5P in IB — net approximately -0.505P. Fraud still costs more than it earns, under the participation condition of Section 2.6.9.

### 3.2 Seller Innocent (Dispute Filed Falsely, or Filed and Lost)

- The seller's "Innocent" position (0.5P) wins. The pool funding the payout includes the now-worthless Guilty-side stake — a losing position's capital funds the winning position's payout, net of any developer surplus (Section 2.6.6). In the base case (forced positions only), the seller recovers approximately **1P** from the market — their own returned 0.5P plus the forfeited 0.5P from whoever funded the Guilty side.
- The seller's remaining 1.0P Locked IB, untouched, unlocks back to Free IB.
- **Seller net:** approximately **+0.5P better** than a transaction with no dispute at all (~ +1.495P against the +0.995P honest baseline). The seller keeps the 0.995P sale proceeds and, through the winning Innocent position, additionally captures the forfeited 0.5P Guilty-side stake; the 0.5% Developer Fee is still paid on the settled sale, and Section 2.6.6's developer surplus trims the recovery marginally below a full 1P. A falsely accused, correctly vindicated seller is made more than whole — never merely even.
- **Whoever funded the losing Guilty side loses that stake in full.** Where the buyer funded it personally, this is the buyer's own 0.5P loss, exactly as under a mandatory bond. Where outside backers funded it, the backers absorb the loss, and the buyer's own position is limited to having already paid for and received an item they falsely disputed, plus the fee — a real but smaller personal cost than a self-funded false claim would have been.

**A disclosed, deliberate trade-off.** Sourcing the funding floor from any willing party, rather than fixing it on the buyer alone, means a false claimant's personal deterrent now scales with how much of the stake they funded themselves, down to zero if they funded none of it. This does not make false claims profitable in expectation: a backer who funds an unconvincing story still loses if it fails, and rational backers price that risk before funding anyone (Section 2.6.3), which is precisely why fabricated claims struggle to attract outside funding at all (Section 2.4). What it does change is where the personal cost of a failed false claim lands. Section 8.1 states this trade-off in full.

---

## 4. Game Theory Analysis

| Action | Seller Payoff | Buyer Payoff |
|---|:---:|:---:|
| Honest trade, no dispute | +0.995P | V - P |
| Seller cheats, dispute opens and resolves correctly, Guilty side backed by others | ~ -0.505P | ~ -0.005P (restitution recovers payment; loses only the fee) |
| Seller cheats, dispute opens and resolves correctly, buyer personally funded the Guilty side | ~ -0.505P | ~ -0.005P, plus the winning-share trading profit on their own funded position (Section 2.6.3) — strictly better than the row above, never worse |
| False dispute opens and resolves correctly, funded entirely by outside backers | ~ +1.495P (+0.5P better than the no-dispute baseline — captures the forfeited 0.5P Guilty stake) | ~ -0.005P (already paid for and received the item; loses only the fee — backers absorb the forfeited 0.5P) |
| False dispute opens and resolves correctly, buyer personally funded it | ~ +1.495P (+0.5P better than the no-dispute baseline — captures the forfeited 0.5P Guilty stake) | ~ -0.505P (item value minus payment minus fee minus their own forfeited stake) |

**For the seller:** cheating still yields approximately -0.505P against approximately +0.995P for honesty, provided the dispute resolves correctly — conditional on adequate market participation, formally bounded in Section 2.6.9 and discussed practically in Section 8.3. Honesty remains the dominant strategy under the participation conditions the protocol is designed to attract. This conclusion does not depend on who funded the Guilty side that caught them; it depends only on the case resolving correctly.

**For the buyer:** publicizing a case costs nothing directly — funding it does, if the buyer is the one who supplies the capital. A false claim the buyer funds personally costs 0.5P with certainty if it fails; a false claim the buyer instead convinces others to fund costs the buyer nothing directly if it fails, though it costs the backers, and a buyer who makes a habit of this will find backers increasingly unwilling to fund them (Section 8.1). A genuine claim recovers in full regardless of who funded it, because restitution (Section 3.1) is paid to the defrauded buyer specifically, independent of the funding source.

**For external backers:** funding shares that reflect true evidence earliest yields the highest returns; the only durably profitable strategy is honest, early, well-evidenced backing. This is the same incentive that governs every other participant in the Spectral Market (Section 2.6.3) — a backer is a trader, not a benefactor.

The equilibrium under adequate participation is: **seller delivers honestly; if disputed regardless, seller defends with sale proceeds; the case resolves correctly, whoever supplied the capital that opened it.** Section 2.6.9 and 8.3 state what "adequate participation" means and what remains true in its absence.

---

## 5. Why Extortion Is Difficult

### 5.1 Buyer's Leverage Against the Seller

There is no discretionary escrow. The buyer's payment (0.995P) is already with the seller, forwarded automatically at atomic settlement (Section 2.3). A false-dispute threat is not automatically backed by the buyer's own capital — but it still requires 0.5P of real Guilty-side conviction to become a live dispute at all (Section 2.4), and a seller who is actually innocent can rebut a weak public case simply by being visibly, verifiably innocent: a story with no supporting evidence is a poor pitch to the very outside capital the buyer would need to recruit, and a seller who rationally defends with sale proceeds (Section 2.4) wins if the case does open. This makes the threat largely self-defeating to make in the absence of a genuine grievance: either the buyer risks their own 0.5P with the same certainty of loss a mandatory bond once imposed, or they attempt to recruit backers for a story that, being false, is structurally harder to make convincing than a true one (Section 8.3) — and if they succeed regardless, they have simply relocated the loss to whoever they convinced, at the cost of their own credibility with that person going forward. This is structurally analogous to the deterrent against frivolous small-claims filings in traditional commerce — not free to make credible, and rarely profitable to the filer or their backers.

### 5.2 Seller Cannot Extort Buyer

Any failure to deliver triggers IB slashing of 1.5P — a loss exceeding the transaction value. The seller's rational choice is always to deliver.

### 5.3 Market Participants Cannot Extort Either Party

There are no designated jurors. The judge is the aggregate market price, when a market with genuine participants exists (Section 2.6.9). No individual holds unilateral power over the outcome under adequate participation. Bribing the market requires purchasing enough shares to move price, subject to slippage and immediate counter-trading under that same condition.

---

## 6. Why Market Manipulation Is Self-Defeating — Under Contested Conditions

Everything below describes what happens when independent, profit-seeking capital is present to counter-trade a manipulator. Section 2.6.9 formally proves that in its absence — a dispute where only the disputing parties ever trade — the defense below does not apply, and controlling the resolution is profitable for whoever controls it, for any curve calibration. This section is scoped by that fact: it states exactly what protects a dispute that draws real participants, which Section 8.3 argues a genuine grievance is structurally more likely to draw than a fabricated one.

The Spectral Market's defense operates through the **no-arbitrage self-correction property**:

**Any price deviation from the truth-supported equilibrium creates a profitable counter-trading opportunity that rational, profit-seeking market participants will immediately exploit, if any such participants are present.**

If a guilty seller pushes "Innocent" price toward 93% by purchasing Innocent shares, they push price above its true equilibrium. Honest traders who see Guilty at, say, $.40 when evidence supports ~$.85 settlement value can buy Guilty for a 150% expected return per share. Profit-seeking traders counter-buy, pushing price back toward truth. The manipulator must continuously buy more Innocent to maintain the mispricing — against a growing pool of profit-motivated counter-traders, where one exists. Every additional purchase costs more (slippage), makes the counter-trade more profitable, and attracts more capital to the correct side.

For manipulation to succeed against a contested market, the seller must outspend every rational, profit-seeking participant simultaneously and indefinitely — economically impossible for any finite actor when evidence is publicly assessable and at least one independent, informed participant is present to act on it.

For **failed manipulation** — price pushed but corrected before 93%, or pushed past it but not sustained for the full cumulative hour — the manipulator's shares resolve worthless, and the capital they deployed transfers to honest counter-traders and the Developer Pool. The failed manipulator did not harm the protocol; they funded it.

**Multi-wallet coordination: zero advantage**, per the path-independence proof in Section 2.6.4.

---

## 7. On Objectivity, Evidence, Herding, and Procedural Truth

### 7.1 No System Determines Objective Truth

Courts do not determine objective truth. Arbitration panels do not. Human juries do not. They all produce **procedural truth**: the best available approximation given the evidence presented, the participants available, and the incentive structures in place. Walendria does not claim to be better at reaching objective truth than a court. It claims to produce better incentive alignment around truth-seeking than any alternative, when the process draws genuine participants (Section 2.6.9).

### 7.2 The Spectral Market Is a Superior Procedural Truth Engine, Under Participation

Jurors have no financial stake in being correct; conformity is costless. In the Spectral Market, being wrong costs money for anyone who trades, and being right early — against the crowd — pays the most. This incentivizes independent evidence assessment, deep investigation, domain expertise, and speed, in venues that draw sustained participation. Over time, this creates a self-selecting class of professional evidence investigators and fraud detectors who participate because their skills are directly monetizable.

### 7.3 Truth Is Determined by Majority — Where a Majority of Genuine Participants Exists

The Spectral Market produces capital-weighted majority consensus among whoever chooses to participate. A "majority" of zero or one genuine participant is not a majority in the sense this argument relies on — Section 2.6.9 treats that case separately. In a population of rational, capital-at-risk actors, majority consensus tracks truth with high probability: dishonest assessors continuously lose capital and exit; honest assessors continuously gain capital and grow their influence.

### 7.4 On Herding

Herding is a valid critique of opinion polls and human juries, where there is no financial stake in being correct. In the Spectral Market, herding is expensive wherever there is enough capital present for a correction to occur — capital at risk converts social conformity from the dominant strategy into the losing one.

### 7.5 On Partial and Off-Chain Evidence

Not all evidence is objectively verifiable from digital records alone — true of every transaction ever conducted. The protocol does not pretend otherwise. Both parties submit all relevant evidence publicly (Section 2.6.2); the market collectively weighs it. Parties that fail to submit relevant evidence or argue their position poorly bear the consequences, same as a litigant who fails to present their case in court.

---

## 8. Remaining Frictions

### 8.1 Opening a Dispute Requires Conviction, Capital From Somewhere, Effort, and Awareness

A dispute does not open until 0.5P of real capital backs the Guilty side, from the buyer, from others, or both (Section 2.4). This is a real, deliberate barrier, not an oversight — it is the same deterrent that makes baseless claims costly (Section 3.2), now applied to whoever actually supplies the capital rather than fixed on the buyer alone. A buyer with spare capital and a strong case can simply fund it themselves, exactly as under a mandatory bond. A buyer without spare capital must instead make their case publicly and rely on someone finding it convincing enough to trade on (Section 2.6.2, 8.3) — a real, different friction: reach and persuasiveness, not just cash on hand. Some buyers, particularly for low-value transactions or without any public audience, will not clear this bar regardless of merit — the same reason many consumers do not dispute small credit-card charges even when eligible, or never find representation for a small claim. The dominant-strategy result in Section 4 holds for the population of disputes that clear the funding threshold, not for the entire population of defrauded buyers. This is a constraint shared by every dispute mechanism that has ever existed, small-claims courts included.

**A note on asymmetric personal deterrence.** Because funding can come from anyone, a buyer who convinces others to fund a false claim does not personally forfeit 0.5P if it fails (Section 3.2) — the backers do. This does not make false claims profitable in expectation: a losing backer still loses, and rational backers diligence what they fund (Section 2.6.3). It does mean the buyer's own personal financial deterrent scales with how much of the stake they funded themselves, down to zero if they funded none of it. What remains constant regardless of funding source: restitution (Section 3.1) is paid to the defrauded buyer specifically whenever a claim is genuine and correctly resolved, and a buyer who repeatedly brings backers into losing claims will find backers increasingly unwilling to fund them — a reputational cost external to the protocol's own accounting, but a real one.

### 8.2 Residual Market Error Rate

For disputes with ambiguous or primarily off-chain evidence, the Spectral Market may resolve incorrectly with small probability epsilon, even under adequate participation. This creates a theoretical extortion space: a party threatening a bad-faith claim imposes an expected cost of epsilon times the amount at stake on their counterparty. Whether that threat is rational depends on the ratio of that expected cost to what the threatening party risks — for a buyer or their backers, the 0.5P funding the Guilty side; for a seller attempting to manipulate a contested market, their trading capital against real counter-traders (Section 6).

**Worked example:** take a genuinely ambiguous but contested dispute (blurry delivery photo, no signature) with epsilon = 0.2 — a materially higher error rate than the protocol would tolerate in steady state. Whoever is weighing whether to fund a claim faces expected value 0.2 x (recovery) minus the 0.5P risked on the 0.8 chance of losing it; a seller facing the claim, defending with sale proceeds at fair market prices, faces the same arithmetic in reverse. Neither side has a free option here — both are pricing a real bet against a real, if imperfect, evidentiary process.

### 8.3 Manipulation and Genuine Participation in Low-Value Disputes

This section states, in one place, the disclosed residual risk of this design and what does and does not mitigate it.

**The disclosed risk.** In a dispute where no independent capital ever trades — only the initial positions on each side — whichever party can afford to push further toward the resolution threshold profits from doing so, per the Boundary Theorem (2.6.9). The funding floor (Section 2.4) does not change this; it changes who has to risk something to attempt it, and now permits that risk to be shared or sourced from outside the buyer specifically.

**What actually changed, stated precisely.** Requiring 0.5P of real capital on the Guilty side — from any source — before the market opens, matched by the seller's 0.5P, removes the zero-capital class of frivolous or grief filings entirely — a party with no genuine conviction in their claim, and no one willing to fund it for them, now cannot open a contest at all. This is a floor on the *cost of attempting* manipulation. It is not a change to the *mathematics of succeeding* at it once someone is willing to pay that floor and more. Those are different properties, and this document does not conflate them: the funding floor raises the price of entry; only threshold-and-b calibration (Section 2.6.9's H(p)) raises the price of winning uncontested.

**Why this is comparable to, not worse than, existing markets and dispute systems.** Every market for real assets — equities, commodities, other prediction markets including Augur and Polymarket — carries manipulation risk in thin or illiquid conditions. This is universally disclosed, not universally solved, by any system ever deployed. Walendria is not an exception.

**Why the risk is a bounded, computable quantity.** The exact minimum capital required to force an uncontested resolution at a chosen threshold is a disclosed function of P and b (Section 2.6.9's H(p) formula) — unlike off-chain fraud, where the attacker's true cost and intent are opaque to the victim in advance. A prospective buyer can compute, before transacting, the capital a given seller's IB plus post-sale liquid proceeds would need to force an uncontested outcome, and factor that into their decision to transact, choose a higher-threshold deployment, or transact a smaller amount.

**Why a genuinely defrauded buyer has a structural advantage in attracting counter-capital — and why this cuts both ways.** A party correctly betting on the true outcome captures the highest returns available in the Spectral Market (Section 2.6.3), whether that party is a stranger or a friend personally informed. This applies to whichever side is actually telling the truth: a defrauded buyer publicizing evidence to their own network is offering real financial upside to anyone who verifies it and agrees — and so is an innocent seller doing the same against a fabricated claim. Neither is appealing to charity; both are offering a bet they believe is favorable. A false accuser or a guilty seller has no equivalent structural advantage, because recruiting genuine outside capital requires convincing people to bet against evidence the truthful party will present. This asymmetry does not make manipulation impossible — it is a probabilistic claim: genuine grievances, on either side, are structurally easier to defend and prosecute than fabricated ones, in expectation. As of Section 2.4, this is no longer only a general market dynamic layered on top of an already-open dispute — it is the literal mechanism by which a dispute opens at all: the ability to attract counter-capital is not just an advantage inside the market, it is the gate to the market.

**What this section does not resolve, and why.** This document does not add a quorum requirement, a juror panel, or a haircut mechanism to close this gap further. Doing so would compromise the permissionless, juror-free character that differentiates this protocol from the alternatives discussed below. That is a disclosed trade-off: Kleros, Augur's escalation game, and UMA's Optimistic Oracle each close this specific gap more completely, at the cost of reintroducing a form of the juror-panel dependency Section 1 argues against. A deployer requiring the closed-gap guarantee should evaluate those alternatives for that specific need.

### 8.4 The Completion Window's Minimum Floor

An unrestricted, fully seller-configurable completion window (Section 2.5) would let a seller set it short enough to structurally defeat the dispute-funding mechanism above — not by winning a contested case, but by outlasting a genuine buyer's ability to contest at all. This is not a hypothetical. Gathering evidence, publicizing a case, and recruiting 0.5P of independent conviction (Section 2.4) is a social process, realistically measured in hours to days for anyone without a pre-existing audience — an AMM trade is instant once someone decides to make it, but deciding takes time no contract can compress. A window set to minutes, or even a small number of hours, can deny that time categorically, regardless of how genuine or well-evidenced the underlying claim is.

Market self-selection — buyers declining to transact with sellers who offer unreasonably short windows — is not sufficient protection on its own, because the incentive to shorten the window is not symmetric between honest and dishonest sellers. An honest seller loses only capital-efficiency (Locked IB freed up later than it could be) from a longer window and has little reason to set it aggressively short. A dishonest seller gains something categorically more valuable from a short window: the specific ability to make it structurally impossible for even a genuinely defrauded buyer to respond in time. Because the population most motivated to set the shortest window is exactly the population a buyer most needs protection from, and because most buyers do not evaluate this specific parameter's real-world time cost at the moment of purchase — the same reason most buyers do not read warranty fine print before checkout — self-selection alone would systematically fail the buyers it is meant to protect.

The protocol therefore fixes a minimum completion window as a deployment-time constant (Section 2.9), below which no listing may go. Sellers remain free to offer longer windows suited to their goods or services — physical shipping and inspection plausibly warranting more time than instant digital delivery — but none may offer less than the floor. This closes the specific, engineered version of the timing attack described above. It does not, on its own, guarantee that every genuine buyer succeeds in recruiting 0.5P of conviction within even a generous window — that remains the disclosed friction of Section 8.1.

### 8.5 On Disputes That Never Cross the Resolution Threshold

Section 8.2 discloses that the Spectral Market can resolve *incorrectly* with small probability epsilon. A related but distinct case is a dispute that does not resolve at all: price trades actively, on both sides, with genuine participants, and never sustains a cumulative hour above 93% in either direction.

For most disputes, a price sitting below threshold despite active interest is not a stalemate — it is a signal that the case has not yet been fully investigated or publicized (Section 2.6.2, 8.3), and the correct, incentive-compatible response is more of exactly that: surfacing more evidence and recruiting more genuinely-convinced capital, which moves price toward the threshold precisely because it moves price toward the truth. This is the same mechanism Sections 6 and 7 already describe, not an exception to it, and it is available to whichever side is actually correct.

A narrower case remains: a dispute that is genuinely, irreducibly ambiguous — where full investigation still leaves real uncertainty, of the kind Section 8.2's own worked example describes (a blurry delivery photo, no signature) — may never organically clear the threshold, because there is no further truth left to surface that would move it there. Pushing price past what the evidence actually supports is not the same action as surfacing more evidence; it is a different, and differently-motivated, trade, and the party making it should not expect the market to reward it as if it were the former (Section 2.6.9).

This document does not add a stalemate-breaking mechanism — a timeout, a default verdict, or a haircut — for this narrower case. Doing so would reintroduce exactly the kind of discretionary, non-market-determined resolution Section 1 argues against, for cases the market has not actually resolved. An indefinitely open, permanently monitorable dispute is treated here as an accurate reflection of a genuinely unresolved case, not a failure of the mechanism to produce one. A deployer or frontend built on this protocol should treat an open, actively-traded, below-threshold dispute as a valid steady state, not an error condition.

---

## 9. Anticipated Criticisms & Clarifications

---

**"The bonding curve was unspecified — where is the formal proof?"**

Formally specified in Section 2.6.4 with the exact cost function and path-independence proof. The manipulation defense, scoped to contested markets, is that LMSR is path-independent and any mispricing creates profitable counter-trading opportunities when counter-trading capital is present. Section 2.6.9 states the boundary case where it is not.

---

**"What about coordinated multi-wallet attacks?"**

Formally disproven in Section 2.6.4. 1,000 wallets buying $1 each costs exactly the same as 1 wallet buying $1,000. Zero advantage, regardless of participation levels — this answers a different question than Section 2.6.9's boundary theorem, which concerns a single actor trading against zero opposition, not many wallets trading against each other.

---

**"What if price crosses the 93% threshold and nobody trades again — does the dispute hang forever?"**

No, per Section 2.6.8. LMSR price only changes on a trade, so elapsed time at any price is exactly computable. This lets the contract expose a permissionless poke function and a publicly computable resolution timestamp. This guarantees the case resolves at a knowable time — it does not, on its own, guarantee the price it resolves at reflects contested evidence rather than a single uncontested actor; that is the separate question Section 2.6.9 answers.

---

**"What if literally nobody trades in the Spectral Market except the two disputing parties?"**

Formally addressed in Section 2.6.9. If no independent capital participates, whichever party can afford to push price to the resolution threshold controls the outcome, and doing so is provably profitable — this follows from the mathematics of any bounded-price, fixed-payout prediction market, not a design flaw specific to Walendria. The practical mitigations: (a) real capital must already be at risk on the Guilty side before the market opens, from some source (Section 2.4), removing the zero-cost attempt; (b) threshold selection raises the capital required for an uncontested attack (2.6.9's H(p)); (c) a genuine victim, on either side, has a profit-based reason to publicize their case (2.6.3, 8.3). See 8.3 for what this document does not claim to have solved.

---

**"Isn't thin market depth for a small-P dispute too little to attract real traders, and won't gas fees eat the return?"**

This document imposes no minimum depth, on principle (Section 2.6.7) — depth is always exactly 1P, whatever a given transaction's own price is. For a small-P dispute, that is a real, disclosed trade-off: a smaller trade moves price further, which can deter a trader who wants to take a large position without excessive slippage. It does not change the Boundary Theorem's ratio (Section 2.6.9), which scales with P regardless — an uncontested attacker's required capital shrinks exactly as fast as their available capital does. On modern EVM L2s, transaction costs run near or below a cent, leaving the overwhelming majority of a trade's expected return intact even at small P. "Depth" and "genuine independent participation" remain different properties: depth is whatever the transaction's own price provides, at any scale; participation is Section 2.6.9's separate, disclosed concern.

---

**"How is off-chain evidence handled — who verifies photos or delivery records?"**

The protocol does not verify off-chain evidence — no dispute system does. Courts do not pre-verify evidence either. The difference is that every Spectral Market participant who chooses to weigh in has capital at risk, which directly incentivizes evidence investigation and fraud detection in venues that draw participants (Section 7, 8.3).

---

**"What about thin markets for small-value disputes?"**

This document imposes no minimum depth (Section 2.6.7) — a small-value dispute has a proportionally small, thinner market, by design, not by shortfall. *Depth* and *participation* remain different properties (Section 2.6.9): a thin market is easier for one trade to move, a real, disclosed trade-off for small-P disputes, but it does not change the Boundary Theorem's ratio, which is scale-invariant. A deployer targeting a small-value transaction distribution should read the calibration addendum in Section 2.9.

---

**"Is the contract upgradeable? Who holds the admin key?"**

No, and no one. Immutably deployed, no upgrade mechanism, no admin key (Section 2.8). Any protocol logic change requires new deployment at a new address. The only post-deployment developer action is updating the Developer Pool withdrawal address, affecting only fee routing.

---

**"The developer takes surplus and fees — conflict of interest?"**

The developer cannot influence verdicts — the Spectral Market is fully self-executing. Surplus comes from failed manipulations and slippage, not from which verdict wins. A developer who tampered with verdicts would collapse trader confidence, reduce volume, and destroy their own revenue.

---

**"Can a buyer just not dispute if they don't want to bother, or can't afford it?"**

Yes. Opening a dispute requires 0.5P of real conviction from some source, plus effort and awareness (Section 8.1) — a real, disclosed friction on the Nash-equilibrium claim in Section 4, not a guarantee that every defrauded buyer's case gets funded. A buyer without personal capital is not automatically excluded, unlike under a design that required the buyer specifically to post a bond — but they are not guaranteed an audience either.

---

**"Why does opening a dispute require funding at all — isn't filing supposed to be a free right, not a purchase?"**

Because a free right to open a dispute is a free right to freeze a seller's Locked IB for the duration of the completion window (Section 2.5) at zero cost to whoever exercises it — an unbounded, repeatable harassment surface limited only by gas fees. Requiring 0.5P of real capital, from any source, bounds this by the cost of capital rather than leaving it bounded by gas fees alone (Section 2.4). This is the same reasoning behind bond requirements for certain claims in traditional legal systems, generalized here to allow that stake to come from anyone the claimant convinces, not the claimant alone.

---

**"What stops a seller from setting a completion window too short for a genuine buyer to ever respond?"**

The protocol enforces a minimum completion window as a deployment constant, set to 72 hours for this deployment; no listing may go shorter, regardless of what the seller wants (Section 2.5, 8.4). Sellers may offer longer windows. The floor exists specifically because market self-selection on this parameter is not reliable — see Section 8.4 for why.

---

**"Why must payment go through the contract instead of straight to the seller's wallet?"**

Because a transfer the contract never observed is a transfer the contract cannot use to safely grant dispute-eligibility without trusting an unverifiable off-chain claim — which would let a dispute be opened against a transaction that was never actually paid for. Routing payment through a single atomic contract call (Section 2.3) gives the contract ground truth about settlement in the same step that it grants dispute-eligibility, closing that gap structurally rather than merely disclosing it.

---

**"Can a well-capitalized buyer just fund a dispute themselves instead of relying on backers?"**

Yes — nothing requires crowd-funding specifically. A buyer with spare capital may purchase the initiating 0.5P of Guilty shares personally, exactly as under a mandatory bond, and in that case captures the trading profit on that position themselves if correct (Section 2.6.3, 3.1). Allowing anyone to fund the position is a generalization, not a restriction — it adds an option for buyers without spare capital; it does not remove the option for buyers who have it.

---

**"Can the buyer and seller collude to cheat backers by mutually closing the case in their favor?"**

No. Mutual close (Section 2.6.10) is available only while no third party holds any shares in the dispute, and only for listings backed entirely by the seller's own direct IB rather than Shared IB — a seller backed by pool depositors cannot unilaterally consent to a slash on their behalf. The instant a backer's capital enters the market on either side, this path is permanently disabled for that dispute — only the market's normal resolution (Section 2.6.5) or the boundary condition it discloses (Section 2.6.9) applies from that point forward. There is no code path that lets the two original parties override a market, or a bond pool, a third party has capital in.

---

**"Can a seller deliberately target buyers who won't dispute?"**

Partially, and this document does not claim otherwise: a seller has no reliable way to identify in advance which buyers can or will attract 0.5P of Guilty-side funding from any source, but a rational seller cannot rule out that some buyers are less likely to. What remains true: serial fraud is wealth-destroying the moment any dispute does open and the case resolves correctly (Section 3.1), and this friction is shared with every dispute system that requires any capital or effort commitment, small-claims courts included.

---

**"Are market participants just incentivized to guess the majority?"**

In opinion polls, yes. In the Spectral Market, herding toward the wrong majority loses money for participants who show up; a correct contrarian earns the highest available returns where enough capital exists for correction to register (Section 7.4, 2.6.9).

---

**"Can a trader prove off-chain how they voted and extract a bribe?"**

There are no votes — only market positions aggregated into a price. No individual controls the outcome under adequate participation (Section 2.6.9). A trader who claims they can guarantee a specific verdict cannot credibly commit to doing so in a contested market.

---

**"What if a well-funded party colludes with external market participants to push the market to the wrong side?"**

In a contested market, they create the most profitable arbitrage opportunity for every honest participant watching, and Section 6 applies in full. In an uncontested market, Section 2.6.9 applies instead.

---

**"What about MEV or front-running of evidence submission?"**

No meaningful distinction between an MEV searcher and an honest trader here — both bet capital on which side is correct, and both are paid only if right, in a contested market.

---

**"Can a seller create a new wallet and commit fraud again after being slashed?"**

Yes — and they must fund a new Integrity Bond each time. Each fraud, resolved correctly, costs net -0.505P minimum (Section 3.1). Serial fraud is wealth-destroying whenever disputes are actually opened and resolve correctly; Section 8.1 discloses that a dispute opening at all is not guaranteed, since it now requires 0.5P of real capital from some source rather than being either free or fixed on the buyer alone.

---

**"Is 1.5P Integrity Bond a high barrier for small sellers?"**

Compare to real-world commerce: storefront costs, marketing, identity verification, age minimums, platform fees. Walendria requires only 1.5P locked, with no location, identity, marketing budget, or age minimum. IB locks per listing, scaled by how many simultaneous transaction slots it supports (1.5P per slot, Section 2.5) — a seller offering one item at a time locks exactly 1.5P, no more. Shared IB (Section 2.2) provides access for those without sufficient capital; a dispute that clears the 0.5P funding threshold draws a matching 0.5P from Locked IB, which depositors should price into their terms.

---

**"Can Shared IB depositors withdraw their stake mid-dispute to dodge a slash?"**

No. Locked capital backing an active listing or open dispute is non-withdrawable until resolution, under the identical rule that governs direct IB (Section 2.1). No partial-exit function, priority-withdrawal queue, or admin override exists in the deployed contract.

---

**"What if the IB is insufficient for a very large transaction?"**

The smart contract self-enforces: any listing where 1.5P x N exceeds the seller's available IB is rejected before the listing activates.

---

**"What if the settlement condition is never triggered?"**

Impossible from a timing standpoint (Section 2.6.8). The cumulative timer never resets, only pauses, and its checkpointing is exact because LMSR price cannot change without a trade. This guarantees resolution at a computable time — not that the price it resolves at reflects contested evidence (Section 2.6.9).

---

**"What if a dispute is genuinely, actively contested — real trading on both sides — but price never sustains a cumulative hour above 93% at all?"**

Addressed in Section 8.5. This differs from the timing question above: Section 2.6.8 guarantees that *once* a threshold is crossed, resolution timing is computable and can't hang. It does not guarantee a threshold gets crossed in the first place. Sustained publicizing and backer recruitment (Section 2.6.2, 8.3) is the correct response for the common case where the evidence simply hasn't been fully surfaced yet; for the narrower case of genuinely irreducible ambiguity, this document deliberately leaves the dispute open rather than adding a fallback that would reintroduce discretionary resolution (Section 1).

---

**"The developer chose parameter b, the threshold, and the minimum window at deployment — doesn't that require trust in the developer?"**

Every deployed protocol requires parameter choices at deployment. b, the resolution threshold, and the minimum completion window are set once, published in immutable bytecode, and verifiable by any participant before use. Section 2.6.9 gives any participant the exact formula to verify, before transacting, what capital a given b and threshold require to force an uncontested outcome — checkable, not merely trusted.

---

**"The contract is immutable — what if there's a bug?"**

Immutability eliminates post-deployment manipulation by any party, including the developer, at the acknowledged cost that bugs cannot be patched. This document does not answer that residual risk with a promise of audit — no audit can establish the absence of bugs, and treating one as if it could would be exactly the kind of unfalsifiable guarantee this document refuses to make everywhere else. It answers it instead by bounding what a latent bug can ever cost. This deployment carries an immutable **per-transaction value hardcap**, fixed in bytecode: the total value any single transaction — and therefore any single exploited code path — can place at risk is capped by construction, at a figure disclosed before anyone transacts. The hardcap is not an admin-adjustable dial. Like every other protocol parameter (Section 2.8), it can change only by deploying a fresh contract at a new address that participants consciously and independently adopt; a deployer may raise it over time only along that same public redeployment path, never silently. Paired with open, reproducible bytecode and an extended public-testnet period before any mainnet deployment, this converts "trust that the code is bug-free" into a disclosed, deliberately-chosen ceiling on worst-case exposure — the same move this document makes everywhere else: bound and disclose the residual risk rather than deny it.

---

**"What about gas fees? Small transactions might be uneconomical on Ethereum mainnet."**

Deploy on a sufficiently decentralized, low-gas EVM-compatible chain (Section 2.9). Gnosis Chain brings gas costs to a fraction of a cent, with audited fixed-point math libraries and live keeper networks (Chainlink Automation, Gelato) already available — without the single-operator sequencer risk of a company-run L2.

---

**"What about privacy — all transactions and evidence are public on-chain."**

By design. The Spectral Market functions because evidence is publicly visible to all participants. A transaction requiring confidential evidence is not suitable for this protocol.

---

## 10. What This Protocol Does Not Claim

**The protocol does not claim** that all evidence submitted to the Spectral Market is authentic. It claims that capital-backed assessment of publicly available evidence produces better truth-finding incentives than existing alternatives, among participants who choose to engage.

**The protocol does not claim** that every buyer will file a dispute even when defrauded. It claims that disputes which do open, and which draw adequate participation or a defending seller, are protected. Section 8.1 discloses the capital, effort, and awareness friction that remains.

**The protocol does not claim** that the Spectral Market never resolves incorrectly under adequate participation, nor that adequate participation is guaranteed for every dispute. It claims that incorrect resolution under adequate participation requires the market to fail at a rate that would itself be arbitraged away (Section 8.2), and separately states in Section 2.6.9 what happens when participation is absent rather than merely inadequate.

**The protocol does not claim** that a party who single-handedly controls a dispute's resolution cannot profit from that control. It claims that the capital required to do so is a disclosed, computable, deployment-tunable quantity (Section 2.6.9), not an unbounded or hidden one, and that the funding floor and a rationally defending seller both raise the practical cost of attempting it (Section 2.4, 8.3).

**The protocol does not claim** that generalizing dispute funding to any willing party removes the personal deterrent against a buyer who files falsely. It claims that the deterrent now scales with how much of the stake the buyer funds themselves, and that a false claim funded entirely by others still fails to profit anyone, including the buyer, when it resolves correctly (Section 3.2, 8.1).

**The protocol does not claim** that a minimum completion window eliminates all time pressure on a disputing party. It claims that a protocol-enforced floor prevents a seller from unilaterally engineering a window too short for any buyer to respond in principle — how much real margin a genuine buyer has above that floor depends on the specific window a deployer or seller chooses (Section 2.9, 8.4).

**The protocol does not claim** that every dispute eventually crosses a resolution threshold. It claims that a dispute which remains below threshold despite active, genuine participation is evidence of irreducible ambiguity rather than mechanism failure, and that this document deliberately declines to add a fallback that would resolve such a case by means other than the market itself (Section 8.5).

**The protocol does not claim** that mutual early resolution (Section 2.6.10) is available for every dispute. It claims this path exists only for disputes where no third-party capital has ever entered the market, and the seller's IB is 100% direct rather than Shared, and that it is permanently and irrevocably disabled the instant either condition stops holding.

**The protocol does not claim** that imposing no minimum transaction size or market depth (Section 2.6.7) guarantees genuine participation at every scale. It claims that depth and participation are different properties, that the Boundary Theorem's core ratio (Section 2.6.9) is unaffected by transaction size, and that a fixed-dollar depth floor was never the right tool for the participation question in the first place.

**The protocol does not claim** that participants' private information will be protected. All transactions and disputes are publicly on-chain by design.

**The protocol does not claim** compliance with any jurisdiction's legal or regulatory framework.

**The protocol does not claim** that the deployed smart contract contains no bugs, nor that any audit could establish their absence. It claims that immutability prevents post-deployment tampering by any party, and that the value any single latent bug can place at risk is bounded in advance by an immutable per-transaction hardcap fixed in bytecode (Section 9) — a disclosed, deliberately-chosen ceiling on worst-case exposure, raised only along the same public redeployment path any other protocol change requires, never a promise of correctness.

**The protocol does not claim** that any single deployment chain, threshold, b calibration, or minimum completion window is optimal for every deployer or transaction-size distribution. Section 2.9's calibration addendum states this as a deployment-time responsibility, not a protocol-level guarantee.

**The protocol does not claim** to be strictly superior to every alternative dispute-resolution design in every dimension. Section 8.3 names specific alternatives (Kleros, Augur, UMA's Optimistic Oracle) that close the uncontested-manipulation gap more completely, at a stated cost to this protocol's permissionless, juror-free character.

---

## 11. Philosophy

Walendria Protocol does not ask anyone to be good. It constructs an environment where being bad carries a computable, disclosed cost — calibratable to exceed what a rational actor can typically bring to bear, under the participation conditions the protocol is designed to attract. Section 2.6.9 and Section 8.3 state precisely the boundary condition under which that cost applies.

The Integrity Bond turns reputation into a financial asset: the larger the bond, the more you can transact, and the more you lose if you defect. Shared IB creates a market for delegated trust — no personal vouching required, only aligned incentives.

The Spectral Market turns truth into a commodity, for whoever shows up to trade it. Truth is priced; those who identify it earliest are paid the most; those who manufacture false truth are punished by slippage, counter-trading, and total loss of their position when the market corrects — wherever a market exists to do the correcting. The capital of failed manipulators flows to the protocol, a tax on dishonesty that funds its own defense in contested disputes. The checkpoint-and-poke mechanism (2.6.8) runs on the same principle: no one needs to be trusted to act, because acting is simply the most profitable available option for whoever is present to take it, at every transaction size this protocol supports. Opening a dispute runs on it too: no one needs to be trusted to fund a genuine claim, because doing so is simply the most profitable available option for whoever correctly recognizes it as genuine (Section 2.4).

The Developer Transaction Fee is not hidden: 0.5% for a system that removes discretionary escrow, structurally weakens (not eliminates) extortion, and resolves disputes without human bias whenever those disputes draw genuine participation, is cost-competitive commerce infrastructure — not a guarantee-in-a-box.

Nor is any transaction too small to matter. A protocol that quietly required a "meaningful" dollar amount before its full mechanism applied would only ever be honest about the part of the world for whom that amount is small change. Walendria makes no such requirement, anywhere in this document, at any layer of the mechanism (Section 2.6.7).

"Objective truth" is a philosophical limit, and "guaranteed outcome regardless of participation" is a mathematical impossibility for any market-based system — proved directly in Section 2.6.9, not asserted around. Every dispute system operates on procedural truth: the best available approximation under real-world constraints, including the constraint of who shows up. Walendria's Spectral Market produces procedural truth more resistant to corruption, more open to participation, more transparent, and more financially rewarding of correct assessment than any alternative that exists — in proportion to the participation it draws.

There is no trust in this system beyond the disclosed boundary. There is only interest, correctly incentivized where capital shows up to be incentivized — and more reliable than an unbounded claim of interest would be, once someone checks the math.

---

## 12. Conclusion

Walendria Protocol — The 28 — is a peer-to-peer transaction system that removes discretionary escrow and structurally weakens the economic basis for extortion and fraud, under disclosed and formally quantified conditions. Payment settles through a single atomic, non-discretionary contract call (Section 2.3) that also gates dispute-eligibility, closing the payment-sequencing question earlier drafts left implicit. It resolves disputes through the LMSR-powered Spectral Market — a capital-backed prediction market with formally proved multi-wallet manipulation resistance (2.6.4) and an arbitrage-driven self-correction mechanism that makes sustained manipulation economically impossible against a market that draws independent participants (Section 6). Section 2.6.9 formally states what happens when it does not: an uncontested actor's profit is bounded, computable, and deployment-tunable via the resolution threshold, not unbounded or hidden.

A dispute opens once 0.5P of real capital backs the Guilty side — from the buyer, from anyone their public case convinces, or both — matched by 0.5P from the seller's Locked IB. Every dispute is still capitalized by real, externally-verified conviction before the seller's bond is ever touched, but that conviction is no longer required to come from the buyer's own wallet alone. This closes the same zero-cost manipulation surface a mandatory bond closed, while removing a barrier that fell hardest on genuinely defrauded buyers without spare capital — Section 8.1 and 8.3 state this trade-off in full, including the corresponding change in personal deterrence for a buyer who recruits others into a false claim (Section 3.2).

The seller's Locked IB now commits per listing at creation, scaled to the number of simultaneous transaction slots a listing supports (Section 2.5), removing any race between buyers for a seller's limited capacity. An undisputed transaction finalizes at the close of its completion window — a seller-configurable duration bounded below by a protocol-enforced minimum, closing the specific, engineered failure mode in which a short window denies a genuine buyer the time a dispute's social funding process realistically requires (Section 8.4).

Market depth is always exactly 1P, with no minimum floor imposed at any transaction size (Section 2.6.7) — a deliberate choice to treat every transaction, at whatever value its own parties agreed to, as a first-class case, not one requiring a synthetic boost to look more legitimate; Section 2.6.9 and 8.3 make clear that depth and genuine participation are not the same property regardless, and that only the latter closes the manipulation-resistance gap. The `pokeSettlement` bounty (2.6.8) now scales with the transaction the same way depth does — 0.1% of P, paid from the resolved market's own settlement surplus (Section 2.6.6) rather than any pre-funded pool; where a quiet dispute leaves too little surplus to reward a third party, resolution still holds because the winning side is always incentivized to poke for its own payout. The checkpoint-and-poke mechanism (2.6.8) guarantees settlement resolves at a computable time — not that the price it resolves at reflects contested evidence, which remains a separate, disclosed question. Contract immutability ensures no party, including the developer, can alter protocol mechanics after deployment, which is precisely why Section 2.9's calibration addendum insists deployers set the resolution threshold, its cumulative duration, b, and the minimum completion window deliberately, before that immutability locks each trade-off in — this deployment sets the resolution threshold at 93%, with no instant-resolution path at any price (Section 2.6.5), so that H(p) exceeds the 0.995P a guilty seller holds unconditionally in sale proceeds, and so that no single transaction, regardless of size, can force a resolution without surviving a full hour of possible counter-trading.

Honesty in Walendria is the dominant rational strategy for sellers and buyers under the participation conditions this protocol is designed to attract — a conditional mathematical result, not an unconditional one, because the unconditional version of that claim is false. The system is complete within the bounds of what it claims. Those bounds are stated once, in the sections where they are proved. Everything inside them is proved. Everything outside them is disclosed, not denied.

---

*Walendria Protocol — The 28 — Public Draft*
