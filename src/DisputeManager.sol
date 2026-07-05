// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SD59x18} from "prb-math/SD59x18.sol";
import {ListingManager} from "./ListingManager.sol";
import {IntegrityBond} from "./IntegrityBond.sol";
import {SpectralMarket} from "./SpectralMarket.sol";
import {DeveloperPool} from "./DeveloperPool.sol";

/// @title DisputeManager
/// @notice Wires Settlement, IntegrityBond, and SpectralMarket together for Walendria Protocol "The 27" (Section
///         2.4, 2.6.1, 3.1, 3.2, 2.6.10): accepts pre-market "Seller Guilty" funding toward the 0.5P threshold from
///         any address, triggers the joint initial-position injection the instant that threshold is crossed
///         (drawing a matching 0.5P from the seller's Locked IB), and - once a market resolves, by whatever means
///         (price threshold via SettlementConditions, a poke, or mutual agreement) - applies the dispute's final
///         IB consequence (1.0P restitution slash on Guilty, or a 1.0P unlock on Innocent) and tells
///         ListingManager the slot is permanently spent.
/// @dev Phase 7 of the build strategy - the module the build strategy itself flags as where "most of the
///      project's real complexity concentrates." A dispute is identified by {marketIdOf}, a deterministic hash of
///      (listingId, slotIndex) - the same value doubles as the SpectralMarket `marketId`, so no separate ID
///      translation table is needed and the eventual resolution timestamp/market stays independently computable
///      by anyone off-chain, consistent with this codebase's existing checkpoint-and-poke design principle.
///
///      Scope decision worth flagging explicitly, mirroring ListingManager's own Phase-3 note: {mutualClose}'s
///      second scope restriction (Section 2.6.10 - unavailable if any portion of the seller's Locked IB is Shared
///      IB) requires no runtime check here, because it is structurally guaranteed by ListingManager's own Phase-3
///      scope decision to lock listings with direct IntegrityBond only - there is currently no code path that
///      produces a partially-Shared-IB-backed listing at all. This is not a workaround; it is an accurate
///      reflection of what the system as built can actually do. The whitepaper itself (Section 2.2) leaves *how* a
///      Shared IB pool selects which seller(s) it backs unspecified - a product/consent-design question, not a
///      protocol mechanic like the LMSR math or the locked thresholds are - so inventing that consent mechanism
///      now, only to exercise a currently-unreachable branch of this check, would be scope invention this phase
///      was never asked to do. If Shared-IB-backed listings are ever built, the missing runtime check belongs
///      exactly here, and this comment is the marker for where.
contract DisputeManager is ReentrancyGuard {
    /// @dev Gas-safety cap on the number of distinct Guilty-side funders a single dispute can have, mirroring
    ///      ListingManager's MAX_SLOTS rationale: this contract's own {_openDispute} and SpectralMarket's
    ///      {SpectralMarket-openMarket} both loop over the full funder list once, in the same transaction that
    ///      crosses the threshold.
    uint256 public constant MAX_GUILTY_FUNDERS = 200;

    /// @notice Protocol Liquidity Buffer floor (Section 2.6.7, locked parameter): $5.00 total initial market
    ///         depth, hardcoded as 5e18 wei on the assumption of a USD-pegged native currency - true for this
    ///         deployment's target, Gnosis Chain, whose native gas token (xDAI) is a USD stablecoin, so no price
    ///         oracle is needed to compare a wei amount against a dollar floor.
    uint256 public constant MIN_LIQUIDITY_DEPTH = 5e18;

    struct GuiltyFunding {
        uint256 total;
        address[] funders;
        mapping(address => bool) hasContributed;
        mapping(address => uint256) contributionOf;
    }

    struct Dispute {
        bool opened;
        bool finalized;
    }

    ListingManager public immutable listingManager;
    IntegrityBond public immutable integrityBond;
    SpectralMarket public immutable spectralMarket;
    /// @notice Funds the Section 2.6.7 liquidity buffer top-up. Address(0) is a valid, deliberate choice
    ///         disabling the top-up entirely - same rationale as SpectralMarket's settlementConditions/
    ///         developerPool address(0) states.
    DeveloperPool public immutable developerPool;

    mapping(uint256 marketId => GuiltyFunding) internal _guiltyFunding;
    mapping(uint256 marketId => Dispute) public disputes;
    mapping(uint256 marketId => mapping(address => bool)) public hasProposedVerdict;
    mapping(uint256 marketId => mapping(address => SpectralMarket.Side)) public proposedVerdict;

    event GuiltySideFunded(uint256 indexed marketId, address indexed funder, uint256 accepted, uint256 cumulativeTotal);
    event DisputeOpened(
        uint256 indexed marketId,
        uint256 indexed listingId,
        uint256 indexed slotIndex,
        address seller,
        uint256 halfPrice
    );
    event MutualCloseProposed(uint256 indexed marketId, address indexed proposer, SpectralMarket.Side verdict);
    event DisputeFinalized(uint256 indexed marketId, SpectralMarket.Side winningSide, uint256 remainingLocked);
    event LiquidityBufferToppedUp(uint256 indexed marketId, uint256 perSideAmount);

    error ZeroAmount();
    error ListingNotFound(uint256 listingId);
    error SlotIndexOutOfRange(uint256 slotIndex, uint256 totalSlots);
    error SlotNotDisputable(uint256 listingId, uint256 slotIndex);
    error WindowExpired(uint256 listingId, uint256 slotIndex, uint256 deadline);
    error PriceTooSmallToDispute(uint256 listingId, uint256 price);
    error TooManyGuiltyFunders(uint256 current, uint256 max);
    error RefundFailed(address to, uint256 amount);
    error DisputeNotOpen(uint256 marketId);
    error DisputeAlreadyFinalized(uint256 marketId);
    error DisputeAlreadyResolved(uint256 marketId);
    error MarketNotResolvedYet(uint256 marketId);
    error NotPartyToDispute(address caller, address buyer, address seller);
    error ThirdPartyParticipation(uint256 marketId, SpectralMarket.Side side);

    constructor(
        ListingManager _listingManager,
        IntegrityBond _integrityBond,
        SpectralMarket _spectralMarket,
        DeveloperPool _developerPool
    ) {
        listingManager = _listingManager;
        integrityBond = _integrityBond;
        spectralMarket = _spectralMarket;
        developerPool = _developerPool;
    }

    /// @notice Accepts native currency as a purchase of "Seller Guilty" shares against the transaction at
    ///         `(listingId, slotIndex)`, from any address (Section 2.4). Capped at exactly `price / 2` cumulative
    ///         across all funders - any amount beyond what is still needed to reach that cap is refunded to the
    ///         caller in the same call. The instant the cap is reached, this call atomically draws the matching
    ///         `price / 2` from the seller's Locked IB, performs the joint initial-position injection (Section
    ///         2.6.1) via {SpectralMarket-openMarket}, and freezes the slot against window-expiry finalization
    ///         (Section 2.5) via {ListingManager-markDisputed}. Reverts if the slot is not currently
    ///         PaymentConfirmed (already disputed, never paid, or already finalized) or if its completion window
    ///         has already elapsed - a dispute past the window must not open at all, matching the regression the
    ///         build strategy names for the opposite boundary (opening one block *before* expiry).
    function fundGuiltySide(uint256 listingId, uint256 slotIndex) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        (address seller, uint256 price, uint256 totalSlots,,,,) = listingManager.listings(listingId);
        if (seller == address(0)) revert ListingNotFound(listingId);
        if (slotIndex >= totalSlots) revert SlotIndexOutOfRange(slotIndex, totalSlots);

        (ListingManager.SlotStatus status, uint256 completionDeadline,) = listingManager.slots(listingId, slotIndex);
        if (status != ListingManager.SlotStatus.PaymentConfirmed) revert SlotNotDisputable(listingId, slotIndex);
        if (block.timestamp >= completionDeadline) revert WindowExpired(listingId, slotIndex, completionDeadline);

        uint256 halfPrice = price / 2;
        if (halfPrice == 0) revert PriceTooSmallToDispute(listingId, price);

        uint256 marketId = marketIdOf(listingId, slotIndex);
        GuiltyFunding storage gf = _guiltyFunding[marketId];

        uint256 remaining = halfPrice - gf.total;
        uint256 accepted = msg.value > remaining ? remaining : msg.value;
        uint256 refund = msg.value - accepted;

        if (!gf.hasContributed[msg.sender]) {
            if (gf.funders.length >= MAX_GUILTY_FUNDERS) {
                revert TooManyGuiltyFunders(gf.funders.length, MAX_GUILTY_FUNDERS);
            }
            gf.hasContributed[msg.sender] = true;
            gf.funders.push(msg.sender);
        }
        gf.contributionOf[msg.sender] += accepted;
        gf.total += accepted;

        emit GuiltySideFunded(marketId, msg.sender, accepted, gf.total);

        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed(msg.sender, refund);
        }

        if (gf.total == halfPrice) {
            _openDispute(listingId, slotIndex, marketId, seller, price, halfPrice);
        }
    }

    /// @notice Buyer and seller each call this specifying the same `verdict` to resolve their dispute immediately
    ///         (Section 2.6.10), without waiting on price discovery. A call from only one party, or two calls
    ///         specifying different verdicts, changes nothing beyond recording that party's current proposal - a
    ///         party may call again with a different verdict to change their mind before the other agrees.
    /// @dev The no-third-party-holder invariant is re-verified on *every* call, not just the one that would
    ///      resolve the market: state can change between the buyer's call and the seller's call, and Section
    ///      2.6.10 requires the path be "permanently and irrevocably disabled" the instant it is ever violated -
    ///      see {SpectralMarket-distinctHolderCount}'s own doc for why a current-balance check alone is not
    ///      sufficient for that permanence.
    ///
    ///      Slither flags `disputes[marketId].finalized = true` (set inside {_finalize}) as written after the
    ///      external calls to `spectralMarket.resolveMarket` and `_finalize`'s own calls into IntegrityBond/
    ///      ListingManager/DeveloperPool. Manually verified false-positive-in-practice: none of those four are
    ///      attacker-controlled or call back into this contract (spectralMarket.resolveMarket only mutates its
    ///      own storage; IntegrityBond's slash/unlock touch only mappings; ListingManager.resolveDispute is the
    ///      same; DeveloperPool.redeemFromMarket's own external call - SpectralMarket.redeem - sends value only
    ///      to DeveloperPool.sol's own `receive()`, which does nothing but emit an event), and this function is
    ///      itself nonReentrant regardless - same trust model already accepted for SpectralMarket's own call into
    ///      SettlementConditions (Phase 6).
    function mutualClose(uint256 listingId, uint256 slotIndex, SpectralMarket.Side verdict) external nonReentrant {
        uint256 marketId = marketIdOf(listingId, slotIndex);
        if (!disputes[marketId].opened) revert DisputeNotOpen(marketId);
        if (disputes[marketId].finalized) revert DisputeAlreadyFinalized(marketId);

        (address seller,,,,,,) = listingManager.listings(listingId);
        (,, address buyer) = listingManager.slots(listingId, slotIndex);
        if (msg.sender != buyer && msg.sender != seller) revert NotPartyToDispute(msg.sender, buyer, seller);

        (,,,,, bool resolved,) = spectralMarket.markets(marketId);
        if (resolved) revert DisputeAlreadyResolved(marketId);

        _requireNoThirdParty(marketId, buyer, seller);

        hasProposedVerdict[marketId][msg.sender] = true;
        proposedVerdict[marketId][msg.sender] = verdict;
        emit MutualCloseProposed(marketId, msg.sender, verdict);

        if (
            hasProposedVerdict[marketId][buyer] && hasProposedVerdict[marketId][seller]
                && proposedVerdict[marketId][buyer] == proposedVerdict[marketId][seller]
        ) {
            spectralMarket.resolveMarket(marketId, verdict);
            _finalize(listingId, slotIndex, marketId, seller, buyer, verdict);
        }
    }

    /// @notice Permissionlessly applies the post-resolution IB/listing consequences for a dispute that has already
    ///         resolved via price threshold (SettlementConditions' checkpoint hook) or a poke, neither of which
    ///         calls back into this contract. {mutualClose} already runs this step inline for its own resolution
    ///         path, so calling this afterward for a mutual-close-resolved dispute simply reverts
    ///         (DisputeAlreadyFinalized) rather than double-applying anything.
    function finalizeDispute(uint256 listingId, uint256 slotIndex) external nonReentrant {
        uint256 marketId = marketIdOf(listingId, slotIndex);
        if (!disputes[marketId].opened) revert DisputeNotOpen(marketId);
        if (disputes[marketId].finalized) revert DisputeAlreadyFinalized(marketId);

        (address seller,,,,,,) = listingManager.listings(listingId);
        (,, address buyer) = listingManager.slots(listingId, slotIndex);

        (,,,,, bool resolved, SpectralMarket.Side winningSide) = spectralMarket.markets(marketId);
        if (!resolved) revert MarketNotResolvedYet(marketId);

        _finalize(listingId, slotIndex, marketId, seller, buyer, winningSide);
    }

    /// @notice Deterministic (listingId, slotIndex) -> marketId mapping, independently computable by anyone -
    ///         there is exactly one SpectralMarket market per disputed slot, and a slot can only ever be disputed
    ///         once (ListingManager's slot lifecycle is one-directional).
    function marketIdOf(uint256 listingId, uint256 slotIndex) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(listingId, slotIndex)));
    }

    function guiltyFundingTotal(uint256 marketId) external view returns (uint256) {
        return _guiltyFunding[marketId].total;
    }

    function guiltyFunderCount(uint256 marketId) external view returns (uint256) {
        return _guiltyFunding[marketId].funders.length;
    }

    function guiltyFunderAt(uint256 marketId, uint256 index) external view returns (address) {
        return _guiltyFunding[marketId].funders[index];
    }

    function guiltyContributionOf(uint256 marketId, address funder) external view returns (uint256) {
        return _guiltyFunding[marketId].contributionOf[funder];
    }

    /// @dev Runs once, the instant cumulative Guilty-side funding reaches exactly `halfPrice` (Section 2.4). Draws
    ///      the matching `halfPrice` from the seller's Locked IB via slash-then-claim (IntegrityBond's existing
    ///      pull-payment ledger, pulled immediately since this contract is itself the recipient), tops up the
    ///      Section 2.6.7 liquidity buffer if this dispute's initial depth would otherwise fall short, then
    ///      performs the joint injection and freezes the slot, in that order - matching the whitepaper's framing
    ///      that the IB draw and the market opening are one atomic state transition (Section 2.6.1), never two.
    function _openDispute(
        uint256 listingId,
        uint256 slotIndex,
        uint256 marketId,
        address seller,
        uint256 price,
        uint256 halfPrice
    ) internal {
        disputes[marketId].opened = true;

        uint256 bufferPerSide = _pullLiquidityBufferIfNeeded(marketId, halfPrice);
        (address[] memory guiltyFunders, uint256[] memory guiltyAmounts) = _buildGuiltyArrays(marketId, bufferPerSide);
        (address[] memory innocentRecipients, uint256[] memory innocentAmounts) =
            _buildInnocentArrays(seller, halfPrice, bufferPerSide);

        integrityBond.slash(seller, halfPrice, address(this));
        integrityBond.claim();

        listingManager.markDisputed(listingId, slotIndex);

        // b = 1 * P (Section 2.6.4's locked calibration, already documented at {SpectralMarket-openMarket}).
        uint256 totalValue = (halfPrice + bufferPerSide) * 2;
        spectralMarket.openMarket{value: totalValue}(
            marketId, price, guiltyFunders, guiltyAmounts, innocentRecipients, innocentAmounts
        );

        emit DisputeOpened(marketId, listingId, slotIndex, seller, halfPrice);
    }

    /// @dev Section 2.6.7: if this dispute's initial 1P-total depth (`halfPrice * 2`) would fall short of the
    ///      $5-equivalent floor, pulls the shortfall's half from {developerPool} (capped at its available
    ///      balance - see {DeveloperPool-pullLiquidityBuffer}'s graceful-degradation doc) so {_openDispute} can
    ///      credit DeveloperPool.sol symmetrically on both sides in the same atomic joint injection. Returns 0 if
    ///      no top-up is needed or {developerPool} is unset (see its own doc for why that is a valid state).
    function _pullLiquidityBufferIfNeeded(uint256 marketId, uint256 halfPrice) internal returns (uint256 perSide) {
        if (address(developerPool) == address(0)) return 0;
        uint256 initialDepth = halfPrice * 2;
        if (initialDepth >= MIN_LIQUIDITY_DEPTH) return 0;

        uint256 desiredPerSide = (MIN_LIQUIDITY_DEPTH - initialDepth) / 2;
        if (desiredPerSide == 0) return 0;

        // Pulls *twice* the per-side amount: bufferPerSide is credited to DeveloperPool on both the Guilty and
        // Innocent side (Section 2.6.7's "split exactly 50/50"), so this contract must actually hold 2x perSide,
        // not just perSide, before forwarding it into {SpectralMarket-openMarket}.
        uint256 received = developerPool.pullLiquidityBuffer(desiredPerSide * 2);
        perSide = received / 2;
        if (perSide > 0) emit LiquidityBufferToppedUp(marketId, perSide);
    }

    /// @dev Builds {SpectralMarket-openMarket}'s Guilty-side arrays: every recorded funder, plus DeveloperPool.sol
    ///      as one more entry if a liquidity-buffer top-up applied. Split out of {_openDispute} to keep its own
    ///      stack depth within Solidity's limit.
    function _buildGuiltyArrays(uint256 marketId, uint256 bufferPerSide)
        internal
        view
        returns (address[] memory funders, uint256[] memory amounts)
    {
        GuiltyFunding storage gf = _guiltyFunding[marketId];
        uint256 baseCount = gf.funders.length;
        uint256 count = bufferPerSide > 0 ? baseCount + 1 : baseCount;
        funders = new address[](count);
        amounts = new uint256[](count);
        for (uint256 i = 0; i < baseCount; i++) {
            funders[i] = gf.funders[i];
            amounts[i] = gf.contributionOf[gf.funders[i]];
        }
        if (bufferPerSide > 0) {
            funders[baseCount] = address(developerPool);
            amounts[baseCount] = bufferPerSide;
        }
    }

    /// @dev Mirrors {_buildGuiltyArrays} for the Innocent side: the seller, plus DeveloperPool.sol if a top-up
    ///      applied - the "split exactly 50/50" of Section 2.6.7 realized as an identical `bufferPerSide` credited
    ///      on both sides of the same joint injection.
    function _buildInnocentArrays(address seller, uint256 halfPrice, uint256 bufferPerSide)
        internal
        view
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        uint256 count = bufferPerSide > 0 ? 2 : 1;
        recipients = new address[](count);
        amounts = new uint256[](count);
        recipients[0] = seller;
        amounts[0] = halfPrice;
        if (bufferPerSide > 0) {
            recipients[1] = address(developerPool);
            amounts[1] = bufferPerSide;
        }
    }

    /// @dev The no-third-party-holder invariant (Section 2.6.10, "the entire safety property of the function" per
    ///      the build strategy): the buyer and {developerPool} together must currently hold every outstanding
    ///      Guilty share, the seller and {developerPool} together must currently hold every outstanding Innocent
    ///      share, AND each side must have had exactly one distinct *counted* holder for its entire history - the
    ///      second condition is what keeps this permanently disabled once a genuine third party ever holds a
    ///      share, even after they later sell back down to zero (see {SpectralMarket-distinctHolderCount}'s doc
    ///      for why the first condition alone is insufficient for that).
    ///
    ///      {developerPool} is deliberately excluded from both the holder count (see
    ///      {SpectralMarket-_creditSide}'s doc) and, here, from the exact-match check: it can hold a share of
    ///      either side (Section 2.6.7's liquidity-buffer top-up for disputes too small to hit the depth floor on
    ///      their own) without that counting as third-party participation, because it always holds the identical
    ///      amount on both sides and never trades afterward - whichever verdict wins, it recovers exactly what it
    ///      put in. There is nothing for the buyer and seller to collude to take from it.
    function _requireNoThirdParty(uint256 marketId, address buyer, address seller) internal view {
        // unwrap()->uint256 is safe because qGuilty/qInnocent are cumulative sums of non-negative share credits
        // (SpectralMarket's own invariant tests confirm they never go negative), mirroring the same safety
        // argument already documented at {SpectralMarket-currentPrice}.
        (, SD59x18 qGuilty, SD59x18 qInnocent,,,,) = spectralMarket.markets(marketId);
        uint256 totalGuilty = uint256(SD59x18.unwrap(qGuilty));
        uint256 totalInnocent = uint256(SD59x18.unwrap(qInnocent));

        uint256 buyerGuilty = spectralMarket.sharesOf(marketId, SpectralMarket.Side.Guilty, buyer);
        uint256 devPoolGuilty = spectralMarket.sharesOf(marketId, SpectralMarket.Side.Guilty, address(developerPool));
        if (
            spectralMarket.distinctHolderCount(marketId, SpectralMarket.Side.Guilty) != 1
                || buyerGuilty + devPoolGuilty != totalGuilty
        ) {
            revert ThirdPartyParticipation(marketId, SpectralMarket.Side.Guilty);
        }

        uint256 sellerInnocent = spectralMarket.sharesOf(marketId, SpectralMarket.Side.Innocent, seller);
        uint256 devPoolInnocent =
            spectralMarket.sharesOf(marketId, SpectralMarket.Side.Innocent, address(developerPool));
        if (
            spectralMarket.distinctHolderCount(marketId, SpectralMarket.Side.Innocent) != 1
                || sellerInnocent + devPoolInnocent != totalInnocent
        ) {
            revert ThirdPartyParticipation(marketId, SpectralMarket.Side.Innocent);
        }
    }

    /// @dev Applies the dispute's final IB consequence and tells ListingManager the slot is permanently spent.
    ///      Recomputes `halfPrice` and the still-remaining locked amount fresh from ListingManager rather than
    ///      caching them at open-time: `price` is immutable per listing once created, so `price / 2` is identical
    ///      either way, and `perSlotLocked - halfPrice` is exactly "whatever this slot still has locked" regardless
    ///      of price's parity (Section 3.1's "remaining 1.0P" and Section 3.2's "remaining 1.0P, untouched" both
    ///      mean this same quantity, not a separately-computed constant).
    ///
    ///      Also triggers {DeveloperPool-redeemFromMarket} whenever {developerPool} is set (the same "unset is a
    ///      valid state" guard already used at {_pullLiquidityBufferIfNeeded}): if a Section 2.6.7 liquidity-
    ///      buffer top-up ever credited it a stake in this market, its winning-side shares are claimed
    ///      automatically in this same transaction rather than depending on a separate manual call nobody is
    ///      obligated to make. A genuine no-op (not a revert) for the common case where no top-up ever happened.
    function _finalize(
        uint256 listingId,
        uint256 slotIndex,
        uint256 marketId,
        address seller,
        address buyer,
        SpectralMarket.Side winningSide
    ) internal {
        disputes[marketId].finalized = true;

        (, uint256 price,,,, uint256 perSlotLocked,) = listingManager.listings(listingId);
        uint256 remainingLocked = perSlotLocked - price / 2;

        if (winningSide == SpectralMarket.Side.Guilty) {
            // Section 3.1: restitution goes to the defrauded buyer specifically, regardless of who funded the
            // winning Guilty-side shares - those traders are paid separately, by their own {SpectralMarket-redeem}.
            integrityBond.slash(seller, remainingLocked, buyer);
        } else {
            // Section 3.2: untouched, unlocks back to the seller's Free IB.
            integrityBond.unlock(seller, remainingLocked);
        }

        listingManager.resolveDispute(listingId, slotIndex);
        if (address(developerPool) != address(0)) {
            developerPool.redeemFromMarket(spectralMarket, marketId);
        }

        emit DisputeFinalized(marketId, winningSide, remainingLocked);
    }

    /// @notice Accepts the {IntegrityBond-claim} push from {_openDispute}'s slash-then-claim sequence. A bare
    ///         direct transfer from anyone else is also accepted but has no accounting effect - self-inflicted,
    ///         like sending native currency to any other contract in this codebase without calling its intended
    ///         entry point.
    receive() external payable {}
}
