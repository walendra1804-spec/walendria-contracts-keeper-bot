// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IntegrityBond} from "./IntegrityBond.sol";

/// @title ListingManager
/// @notice Listing lifecycle for Walendria Protocol "The 27" (Section 2.5): a seller creates a listing for a
///         transaction of price P supporting N simultaneous slots, locking 1.5*P*N of Integrity Bond immediately
///         - before any buyer appears. Each slot independently tracks payment confirmation and its completion
///         window (a seller-configurable duration, floored at a 72-hour protocol minimum), after which it
///         finalizes and releases its share of Locked IB if no dispute ever opened against it.
/// @dev Each slot is single-use: once payment confirms, that slot moves forward (PaymentConfirmed -> Disputed ->
///      Removed, or PaymentConfirmed -> Removed via window expiry) and never returns to Empty. A slot's Locked
///      IB is only ever genuinely backed while the *listing* holds it from creation onward; recycling a "spent"
///      slot back to Empty without re-locking would let a future buyer transact against a slot with nothing
///      actually bonded behind it. A seller wanting more concurrent capacity after slots are spent creates a
///      new listing. Only never-yet-used (Empty) slots can be reclaimed early, via {reduceSlots}/{closeListing}.
///
/// @dev Phase 3 of the build strategy. Scope decision worth flagging explicitly: this contract locks listings
///      with **direct Integrity Bond only** (IntegrityBond.sol). Section 2.6.10 anticipates a listing's Locked
///      IB eventually being split between direct and Shared IB, but SharedIB.sol (Phase 2) has no mechanism yet
///      by which a pool consents to backing a *specific* seller - its `lock()` trusts its controller completely.
///      Wiring ListingManager to call `SharedIB.lock()` on a seller's behalf today would let any seller draw
///      against any pool ListingManager is a controller of, with no actual agreement from that pool. Rather than
///      build that consent mechanism as an undocumented side effect of this phase, direct-IB-only listings ship
///      now; Shared-IB-backed listings are deferred until that consent mechanism is designed on its own terms
///      (naturally alongside DisputeManager.sol, Phase 7, which is where Section 2.6.10's backing-composition
///      check actually gets used).
///
///      Like IntegrityBond.sol/SharedIB.sol, `controller`s (intended: Settlement.sol for {confirmPayment},
///      DisputeManager.sol for {markDisputed}/{resolveDispute}) are a fixed allowlist set once at construction.
///
///      Dispute-driven fund movement (the 0.5P matching draw, the 1.0P restitution slash, or an Innocent-verdict
///      unlock) is not this contract's job - DisputeManager will call IntegrityBond directly for that, since it
///      already needs direct access for the Spectral Market side. {markDisputed}/{resolveDispute} here are pure
///      slot-status bookkeeping: freezing a slot against window-expiry finalization while disputed, and marking
///      it permanently spent once DisputeManager has already settled the bond side.
contract ListingManager {
    enum SlotStatus {
        Empty,
        PaymentConfirmed,
        Disputed,
        Removed
    }

    struct Listing {
        address seller;
        uint256 price;
        uint256 totalSlots; // high-water mark of ever-allocated slot indices; never decremented
        uint256 emptySlots; // slots currently Empty and eligible for reduce/close release
        uint256 completionWindow;
        uint256 perSlotLocked; // 1.5 * price, locked per slot via IntegrityBond
        bool closed;
    }

    struct Slot {
        SlotStatus status;
        uint256 completionDeadline; // meaningful only while status == PaymentConfirmed
        address buyer; // meaningful only once status has passed Empty; set once, at confirmPayment, never reset
    }

    /// @notice Protocol-enforced floor (Section 2.5, 2.9): no listing may offer a shorter completion window.
    uint256 public constant MIN_COMPLETION_WINDOW = 72 hours;

    /// @dev Sanity cap on N so a seller's own {reduceSlots}/{closeListing} scan can never approach a block gas
    ///      limit - self-inflicted only, but bounding it keeps worst-case gas analyzable for audit.
    uint256 public constant MAX_SLOTS = 1000;

    IntegrityBond public immutable integrityBond;

    /// @notice Immutable per-transaction value hardcap (whitepaper Section 9): no listing may set a price above
    ///         this ceiling, which bounds the total value any single transaction - and therefore any single
    ///         exploited code path - can place at risk. Fixed at deployment; raising it requires a fresh
    ///         deployment at a new address (Section 2.8), never an admin write. It is not a claim about what a
    ///         "reasonable" transaction size is - only a blast-radius bound on a bug.
    uint256 public immutable maxTransactionValue;

    mapping(address controller => bool) public isController;
    mapping(uint256 listingId => Listing) public listings;
    mapping(uint256 listingId => mapping(uint256 slotIndex => Slot)) public slots;
    uint256 public nextListingId;

    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        uint256 price,
        uint256 totalSlots,
        uint256 completionWindow,
        uint256 perSlotLocked
    );
    event SlotPaymentConfirmed(
        uint256 indexed listingId, uint256 indexed slotIndex, address indexed buyer, uint256 completionDeadline
    );
    event SlotFinalized(uint256 indexed listingId, uint256 indexed slotIndex);
    event SlotDisputed(uint256 indexed listingId, uint256 indexed slotIndex);
    event SlotResolved(uint256 indexed listingId, uint256 indexed slotIndex);
    event SlotsReduced(uint256 indexed listingId, uint256 count);
    event ListingClosed(uint256 indexed listingId);

    error NoControllers();
    error NotController(address caller);
    error NotSeller(address caller, address seller);
    error ListingNotFound(uint256 listingId);
    error ListingAlreadyClosed(uint256 listingId);
    error ZeroPrice();
    error ZeroCap();
    error PriceExceedsCap(uint256 price, uint256 cap);
    error ZeroSlots();
    error TooManySlots(uint256 requested, uint256 max);
    error CompletionWindowTooShort(uint256 requested, uint256 minimum);
    error SlotIndexOutOfRange(uint256 slotIndex, uint256 totalSlots);
    error SlotNotEmpty(uint256 listingId, uint256 slotIndex);
    error SlotNotPaymentConfirmed(uint256 listingId, uint256 slotIndex);
    error SlotNotDisputed(uint256 listingId, uint256 slotIndex);
    error WindowNotYetExpired(uint256 listingId, uint256 slotIndex, uint256 deadline);
    error InsufficientEmptySlots(uint256 listingId, uint256 requested, uint256 available);

    /// @param _integrityBond The direct Integrity Bond contract this ListingManager locks/unlocks against. This
    ///        ListingManager must separately be registered as a controller on that contract.
    /// @param controllers Addresses authorized to call {confirmPayment}/{markDisputed}/{resolveDispute} (e.g.
    ///        Settlement.sol, DisputeManager.sol). Fixed for the lifetime of this contract.
    /// @param _maxTransactionValue See {maxTransactionValue}. Must be nonzero (a zero cap would reject every
    ///        listing); it is a deployment-time blast-radius ceiling, re-derived per deployment (Section 2.9).
    constructor(IntegrityBond _integrityBond, address[] memory controllers, uint256 _maxTransactionValue) {
        if (controllers.length == 0) revert NoControllers();
        if (_maxTransactionValue == 0) revert ZeroCap();
        integrityBond = _integrityBond;
        maxTransactionValue = _maxTransactionValue;
        for (uint256 i = 0; i < controllers.length; i++) {
            isController[controllers[i]] = true;
        }
    }

    modifier onlyController() {
        if (!isController[msg.sender]) revert NotController(msg.sender);
        _;
    }

    /// @notice Creates a listing for a transaction of `price`, supporting `totalSlots` simultaneous slots, each
    ///         requiring a completion window of at least `MIN_COMPLETION_WINDOW`. Locks `1.5 * price * totalSlots`
    ///         of the caller's direct Integrity Bond immediately (Section 2.5) - before any buyer appears.
    function createListing(uint256 price, uint256 totalSlots, uint256 completionWindow)
        external
        returns (uint256 listingId)
    {
        if (price == 0) revert ZeroPrice();
        if (price > maxTransactionValue) revert PriceExceedsCap(price, maxTransactionValue);
        if (totalSlots == 0) revert ZeroSlots();
        if (totalSlots > MAX_SLOTS) revert TooManySlots(totalSlots, MAX_SLOTS);
        if (completionWindow < MIN_COMPLETION_WINDOW) {
            revert CompletionWindowTooShort(completionWindow, MIN_COMPLETION_WINDOW);
        }

        uint256 perSlotLocked = Math.ceilDiv(price * 3, 2);
        integrityBond.lock(msg.sender, perSlotLocked * totalSlots);

        listingId = nextListingId++;
        listings[listingId] = Listing({
            seller: msg.sender,
            price: price,
            totalSlots: totalSlots,
            emptySlots: totalSlots,
            completionWindow: completionWindow,
            perSlotLocked: perSlotLocked,
            closed: false
        });

        emit ListingCreated(listingId, msg.sender, price, totalSlots, completionWindow, perSlotLocked);
    }

    /// @notice Marks `slotIndex` as paid, starting its completion-window clock, and records `buyer` as the slot's
    ///         permanent buyer of record. Called by Settlement.sol in the same atomic step that verifies payment
    ///         (Section 2.3), passing through its own `msg.sender`.
    /// @dev `buyer` is stored (not just emitted) because DisputeManager.sol (Phase 7) needs it later: Section 3.1
    ///      restitution is paid to the defrauded buyer specifically, "regardless of who funded the Guilty-side
    ///      position" - which can be a mix of the buyer and outside backers (Section 2.4). Without persisting the
    ///      buyer here, nothing on-chain would know who that is by the time a dispute resolves.
    function confirmPayment(uint256 listingId, uint256 slotIndex, address buyer) external onlyController {
        Listing storage listing = _requireListing(listingId);
        if (listing.closed) revert ListingAlreadyClosed(listingId);
        if (slotIndex >= listing.totalSlots) revert SlotIndexOutOfRange(slotIndex, listing.totalSlots);

        Slot storage slot = slots[listingId][slotIndex];
        if (slot.status != SlotStatus.Empty) revert SlotNotEmpty(listingId, slotIndex);

        slot.status = SlotStatus.PaymentConfirmed;
        slot.completionDeadline = block.timestamp + listing.completionWindow;
        slot.buyer = buyer;
        listing.emptySlots -= 1;

        emit SlotPaymentConfirmed(listingId, slotIndex, buyer, slot.completionDeadline);
    }

    /// @notice Permissionlessly finalizes a slot whose completion window has elapsed with no dispute ever
    ///         opened (Section 2.5), releasing its full Locked IB back to the seller's Free IB. No bounty exists
    ///         for calling this - the seller already has the direct incentive, since it frees their own capital.
    ///
    ///         The slot is permanently spent, not recycled to Empty: once its capital has been released, nothing
    ///         backs it any more, and silently reusing it for a new buyer without re-locking would let a
    ///         transaction proceed with no real Integrity Bond behind it - exactly the failure mode this whole
    ///         mechanism exists to prevent. A seller who wants more concurrent capacity after a slot finalizes
    ///         creates a new listing (or a future listing-topup primitive, not built here).
    function finalizeExpiredSlot(uint256 listingId, uint256 slotIndex) external {
        Listing storage listing = _requireListing(listingId);
        if (slotIndex >= listing.totalSlots) revert SlotIndexOutOfRange(slotIndex, listing.totalSlots);

        Slot storage slot = slots[listingId][slotIndex];
        if (slot.status != SlotStatus.PaymentConfirmed) revert SlotNotPaymentConfirmed(listingId, slotIndex);
        if (block.timestamp < slot.completionDeadline) {
            revert WindowNotYetExpired(listingId, slotIndex, slot.completionDeadline);
        }

        slot.status = SlotStatus.Removed;
        slot.completionDeadline = 0;
        integrityBond.unlock(listing.seller, listing.perSlotLocked);

        emit SlotFinalized(listingId, slotIndex);
    }

    /// @notice Freezes `slotIndex` against window-expiry finalization once a dispute has opened against it
    ///         (Section 2.4: crossing the 0.5P Guilty-side threshold). "An open dispute is never subject to the
    ///         window's expiry" (Section 2.5) is enforced structurally here: {finalizeExpiredSlot} requires
    ///         status == PaymentConfirmed, and Disputed is a different status entirely.
    function markDisputed(uint256 listingId, uint256 slotIndex) external onlyController {
        _requireListing(listingId);
        Slot storage slot = slots[listingId][slotIndex];
        if (slot.status != SlotStatus.PaymentConfirmed) revert SlotNotPaymentConfirmed(listingId, slotIndex);
        slot.status = SlotStatus.Disputed;
        emit SlotDisputed(listingId, slotIndex);
    }

    /// @notice Marks a disputed slot permanently spent once its dispute has resolved. The controller
    ///         (DisputeManager) is responsible for having already called `unlock`/`slash` on {integrityBond}
    ///         directly for whatever the verdict requires (Section 3.1, 3.2) - this function only updates slot
    ///         status/bookkeeping, it moves no funds itself. Like {finalizeExpiredSlot}, the slot goes to
    ///         Removed rather than back to Empty, for the same reason: whatever IB backed it has already been
    ///         disposed of (unlocked or slashed) by the time this is called, so there is nothing left to reuse.
    function resolveDispute(uint256 listingId, uint256 slotIndex) external onlyController {
        _requireListing(listingId);
        Slot storage slot = slots[listingId][slotIndex];
        if (slot.status != SlotStatus.Disputed) revert SlotNotDisputed(listingId, slotIndex);
        slot.status = SlotStatus.Removed;
        slot.completionDeadline = 0;
        emit SlotResolved(listingId, slotIndex);
    }

    /// @notice Releases `count` currently-empty slots' Locked IB back to Free IB, permanently removing that much
    ///         capacity from the listing. Slots with confirmed payment are never touched (Section 2.5).
    function reduceSlots(uint256 listingId, uint256 count) external {
        Listing storage listing = _requireListing(listingId);
        if (msg.sender != listing.seller) revert NotSeller(msg.sender, listing.seller);
        if (listing.closed) revert ListingAlreadyClosed(listingId);
        _reduceEmptySlots(listingId, listing, count);
    }

    /// @notice Stops the listing from accepting any further payments and releases every currently-empty slot's
    ///         Locked IB. Slots with confirmed payment or an open dispute keep running their normal lifecycle
    ///         unaffected by this call (Section 2.5: payment confirmation and cancellation are mutually
    ///         exclusive outcomes for a given slot) - they release their own IB independently once they finalize
    ///         or their dispute resolves, exactly as they would have if the listing were still open.
    function closeListing(uint256 listingId) external {
        Listing storage listing = _requireListing(listingId);
        if (msg.sender != listing.seller) revert NotSeller(msg.sender, listing.seller);
        if (listing.closed) revert ListingAlreadyClosed(listingId);
        _reduceEmptySlots(listingId, listing, listing.emptySlots);
        listing.closed = true;
        emit ListingClosed(listingId);
    }

    function _requireListing(uint256 listingId) internal view returns (Listing storage listing) {
        listing = listings[listingId];
        if (listing.seller == address(0)) revert ListingNotFound(listingId);
    }

    function _reduceEmptySlots(uint256 listingId, Listing storage listing, uint256 count) internal {
        if (count == 0) return;
        if (count > listing.emptySlots) revert InsufficientEmptySlots(listingId, count, listing.emptySlots);

        uint256 removed = 0;
        for (uint256 i = 0; i < listing.totalSlots && removed < count; i++) {
            Slot storage slot = slots[listingId][i];
            if (slot.status == SlotStatus.Empty) {
                slot.status = SlotStatus.Removed;
                removed++;
            }
        }

        listing.emptySlots -= count;
        integrityBond.unlock(listing.seller, listing.perSlotLocked * count);
        emit SlotsReduced(listingId, count);
    }
}
