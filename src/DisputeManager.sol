// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SD59x18} from "prb-math/SD59x18.sol";
import {ListingManager} from "./ListingManager.sol";
import {IntegrityBond} from "./IntegrityBond.sol";
import {SpectralMarket} from "./SpectralMarket.sol";

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

    constructor(ListingManager _listingManager, IntegrityBond _integrityBond, SpectralMarket _spectralMarket) {
        listingManager = _listingManager;
        integrityBond = _integrityBond;
        spectralMarket = _spectralMarket;
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
    ///      ListingManager. Manually verified false-positive-in-practice: none of those three are attacker-
    ///      controlled or call back into this contract (spectralMarket.resolveMarket only mutates its own
    ///      storage; IntegrityBond's slash/unlock touch only mappings; ListingManager.resolveDispute is the
    ///      same), and this function is itself nonReentrant regardless - same trust model already accepted for
    ///      SpectralMarket's own call into SettlementConditions (Phase 6).
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
    ///      pull-payment ledger, pulled immediately since this contract is itself the recipient), then performs
    ///      the joint injection and freezes the slot, in that order - matching the whitepaper's framing that the
    ///      IB draw and the market opening are one atomic state transition (Section 2.6.1), never two.
    function _openDispute(
        uint256 listingId,
        uint256 slotIndex,
        uint256 marketId,
        address seller,
        uint256 price,
        uint256 halfPrice
    ) internal {
        disputes[marketId].opened = true;

        GuiltyFunding storage gf = _guiltyFunding[marketId];
        uint256[] memory amounts = new uint256[](gf.funders.length);
        for (uint256 i = 0; i < gf.funders.length; i++) {
            amounts[i] = gf.contributionOf[gf.funders[i]];
        }

        integrityBond.slash(seller, halfPrice, address(this));
        integrityBond.claim();

        listingManager.markDisputed(listingId, slotIndex);

        // b = 1 * P (Section 2.6.4's locked calibration, already documented at {SpectralMarket-openMarket}).
        spectralMarket.openMarket{value: halfPrice * 2}(marketId, price, gf.funders, amounts, seller, halfPrice);

        emit DisputeOpened(marketId, listingId, slotIndex, seller, halfPrice);
    }

    /// @dev The no-third-party-holder invariant (Section 2.6.10, "the entire safety property of the function" per
    ///      the build strategy): the buyer must currently hold every outstanding Guilty share, and the seller must
    ///      currently hold every outstanding Innocent share, AND each side must have had exactly one distinct
    ///      holder for its entire history - the second condition is what keeps this permanently disabled once
    ///      violated, even if the intervening third party later sells back down to zero (see
    ///      {SpectralMarket-distinctHolderCount}'s doc for why the first condition alone is insufficient for that).
    function _requireNoThirdParty(uint256 marketId, address buyer, address seller) internal view {
        // unwrap()->uint256 is safe because qGuilty/qInnocent are cumulative sums of non-negative share credits
        // (SpectralMarket's own invariant tests confirm they never go negative), mirroring the same safety
        // argument already documented at {SpectralMarket-currentPrice}.
        (, SD59x18 qGuilty, SD59x18 qInnocent,,,,) = spectralMarket.markets(marketId);
        uint256 totalGuilty = uint256(SD59x18.unwrap(qGuilty));
        uint256 totalInnocent = uint256(SD59x18.unwrap(qInnocent));

        if (
            spectralMarket.distinctHolderCount(marketId, SpectralMarket.Side.Guilty) != 1
                || spectralMarket.sharesOf(marketId, SpectralMarket.Side.Guilty, buyer) != totalGuilty
        ) {
            revert ThirdPartyParticipation(marketId, SpectralMarket.Side.Guilty);
        }
        if (
            spectralMarket.distinctHolderCount(marketId, SpectralMarket.Side.Innocent) != 1
                || spectralMarket.sharesOf(marketId, SpectralMarket.Side.Innocent, seller) != totalInnocent
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

        emit DisputeFinalized(marketId, winningSide, remainingLocked);
    }

    /// @notice Accepts the {IntegrityBond-claim} push from {_openDispute}'s slash-then-claim sequence. A bare
    ///         direct transfer from anyone else is also accepted but has no accounting effect - self-inflicted,
    ///         like sending native currency to any other contract in this codebase without calling its intended
    ///         entry point.
    receive() external payable {}
}
