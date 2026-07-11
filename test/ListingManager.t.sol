// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IntegrityBond} from "../src/IntegrityBond.sol";
import {ListingManager} from "../src/ListingManager.sol";

contract ListingManagerTest is Test {
    IntegrityBond internal bond;
    ListingManager internal lm;
    address internal controller = makeAddr("controller"); // stand-in for Settlement.sol / DisputeManager.sol
    address internal seller = makeAddr("seller");
    address internal stranger = makeAddr("stranger");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant PRICE = 1 ether;
    uint256 internal constant PER_SLOT_LOCKED = 1.5 ether;
    uint256 internal constant WINDOW = 72 hours;

    event ListingDescribed(uint256 indexed listingId, string title, string description);

    function setUp() public {
        // IntegrityBond needs ListingManager's address (as its controller) and ListingManager needs
        // IntegrityBond's address (immutable) - a real deployment resolves this circular reference via CREATE2
        // address prediction (the Factory pattern from the build strategy's open items). Here, plain CREATE
        // nonces from this same test contract are just as predictable, so we predict ListingManager's
        // soon-to-exist address before deploying IntegrityBond, then deploy ListingManager into it.
        uint256 nonce = vm.getNonce(address(this));
        address predictedLm = vm.computeCreateAddress(address(this), nonce + 1);
        bond = new IntegrityBond(_singleton(predictedLm));

        address[] memory lmControllers = new address[](1);
        lmControllers[0] = controller;
        lm = new ListingManager(bond, lmControllers, type(uint256).max);
        assertEq(address(lm), predictedLm, "CREATE nonce prediction drifted");

        vm.deal(seller, 1000 ether);
        vm.prank(seller);
        bond.deposit{value: 100 ether}();
    }

    function _singleton(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    /// @dev Deploys a fresh IntegrityBond + ListingManager pair with a finite per-transaction hardcap, wired via
    ///      CREATE nonce prediction exactly like {setUp}, so the cap can be exercised in isolation.
    function _deployCappedPair(uint256 cap) internal returns (IntegrityBond cappedBond, ListingManager capped) {
        uint256 nonce = vm.getNonce(address(this));
        address predictedLm = vm.computeCreateAddress(address(this), nonce + 1);
        cappedBond = new IntegrityBond(_singleton(predictedLm));
        capped = new ListingManager(cappedBond, _singleton(controller), cap);
        assertEq(address(capped), predictedLm, "capped-pair CREATE nonce prediction drifted");
    }

    // ── Per-transaction hardcap (whitepaper Section 9) ───────────────────────────────────────────────────────────

    function test_ConstructorRevertsOnZeroCap() public {
        vm.expectRevert(ListingManager.ZeroCap.selector);
        new ListingManager(bond, _singleton(controller), 0);
    }

    function test_MaxTransactionValueGetterReturnsConfiguredCap() public {
        (, ListingManager capped) = _deployCappedPair(5 ether);
        assertEq(capped.maxTransactionValue(), 5 ether);
    }

    function test_CreateListingRevertsWhenPriceExceedsHardcap() public {
        uint256 cap = 5 ether;
        (, ListingManager capped) = _deployCappedPair(cap);

        // The cap check fires before any IB is locked, so no funded bond is needed to observe the revert.
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.PriceExceedsCap.selector, cap + 1, cap));
        capped.createListing(cap + 1, 1, WINDOW, "", "");
    }

    function test_CreateListingSucceedsAtExactlyTheHardcap() public {
        uint256 cap = 5 ether;
        (IntegrityBond cappedBond, ListingManager capped) = _deployCappedPair(cap);

        vm.deal(seller, 100 ether);
        vm.prank(seller);
        cappedBond.deposit{value: 20 ether}(); // covers 1.5 * cap
        vm.prank(seller);
        uint256 listingId = capped.createListing(cap, 1, WINDOW, "", ""); // exactly at the cap is allowed

        (, uint256 price,,,,,) = capped.listings(listingId);
        assertEq(price, cap, "a listing priced exactly at the cap must be accepted");
    }

    // ── createListing ──────────────────────────────────────────────────────────────────────────────────────────

    function test_CreateListingLocksOnePointFiveTimesPriceTimesSlots() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 3, WINDOW, "", "");

        (
            address s,
            uint256 price,
            uint256 totalSlots,
            uint256 emptySlots,
            uint256 completionWindow,
            uint256 perSlotLocked,
            bool closed
        ) = lm.listings(listingId);
        assertEq(s, seller);
        assertEq(price, PRICE);
        assertEq(totalSlots, 3);
        assertEq(emptySlots, 3);
        assertEq(completionWindow, WINDOW);
        assertEq(perSlotLocked, PER_SLOT_LOCKED);
        assertFalse(closed);

        assertEq(bond.freeIB(seller), 100 ether - PER_SLOT_LOCKED * 3);
    }

    function test_CreateListingRoundsLockRequirementUp() public {
        // price = 1 wei -> 1.5 wei is not representable; must round UP to 2 wei so the bond is never under
        // the true 1.5P requirement (rounding down would silently under-collateralize the seller).
        vm.prank(seller);
        uint256 listingId = lm.createListing(1, 1, WINDOW, "", "");
        (,,,,, uint256 perSlotLocked,) = lm.listings(listingId);
        assertEq(perSlotLocked, 2);
    }

    // ── Optional on-chain listing metadata: title + description (Section 2.6.2-style permanent record) ────────────

    function test_CreateListingStoresTitleAndDescriptionOnChain() public {
        string memory title = "Handmade oak desk";
        string memory desc = "Solid oak, 120x60cm, dispatched within 3 days of payment confirmation.";

        vm.expectEmit(true, false, false, true, address(lm));
        emit ListingDescribed(0, title, desc);

        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, title, desc);

        (string memory storedTitle, string memory storedDesc) = lm.listingMetadata(listingId);
        assertEq(storedTitle, title, "title must be persisted verbatim on-chain");
        assertEq(storedDesc, desc, "description must be persisted verbatim on-chain");
    }

    function test_CreateListingWithEmptyMetadataStoresNothingAndEmitsNoDescribeEvent() public {
        vm.recordLogs();
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");

        (string memory storedTitle, string memory storedDesc) = lm.listingMetadata(listingId);
        assertEq(bytes(storedTitle).length, 0, "no title stored on the empty path");
        assertEq(bytes(storedDesc).length, 0, "no description stored on the empty path");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 describedTopic = keccak256("ListingDescribed(uint256,string,string)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != describedTopic, "empty metadata must emit no ListingDescribed event");
        }
    }

    function test_CreateListingAllowsTitleOrDescriptionAlone() public {
        vm.prank(seller);
        uint256 idTitleOnly = lm.createListing(PRICE, 1, WINDOW, "Just a title", "");
        (string memory t1, string memory d1) = lm.listingMetadata(idTitleOnly);
        assertEq(t1, "Just a title");
        assertEq(bytes(d1).length, 0);

        vm.prank(seller);
        uint256 idDescOnly = lm.createListing(PRICE, 1, WINDOW, "", "Only a description");
        (string memory t2, string memory d2) = lm.listingMetadata(idDescOnly);
        assertEq(bytes(t2).length, 0);
        assertEq(d2, "Only a description");
    }

    function test_CreateListingAcceptsMetadataAtExactlyMaxLength() public {
        string memory maxTitle = string(new bytes(lm.MAX_LISTING_TITLE_BYTES()));
        string memory maxDesc = string(new bytes(lm.MAX_LISTING_DESCRIPTION_BYTES()));

        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, maxTitle, maxDesc);

        (string memory t, string memory d) = lm.listingMetadata(listingId);
        assertEq(bytes(t).length, lm.MAX_LISTING_TITLE_BYTES(), "title at exactly the cap must be accepted");
        assertEq(bytes(d).length, lm.MAX_LISTING_DESCRIPTION_BYTES(), "description at exactly the cap must be accepted");
    }

    function test_CreateListingRevertsWhenTitleExceedsMax() public {
        uint256 max = lm.MAX_LISTING_TITLE_BYTES();
        string memory tooLong = string(new bytes(max + 1));
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.ListingTitleTooLong.selector, max + 1, max));
        lm.createListing(PRICE, 1, WINDOW, tooLong, "");
    }

    function test_CreateListingRevertsWhenDescriptionExceedsMax() public {
        uint256 max = lm.MAX_LISTING_DESCRIPTION_BYTES();
        string memory tooLong = string(new bytes(max + 1));
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.ListingDescriptionTooLong.selector, max + 1, max));
        lm.createListing(PRICE, 1, WINDOW, "", tooLong);
    }

    function test_ListingMetadataIsIndependentAcrossListings() public {
        vm.startPrank(seller);
        uint256 a = lm.createListing(PRICE, 1, WINDOW, "Listing A", "desc A");
        uint256 b = lm.createListing(PRICE, 1, WINDOW, "Listing B", "desc B");
        vm.stopPrank();

        (string memory ta, string memory da) = lm.listingMetadata(a);
        (string memory tb, string memory db) = lm.listingMetadata(b);
        assertEq(ta, "Listing A");
        assertEq(da, "desc A");
        assertEq(tb, "Listing B");
        assertEq(db, "desc B");
    }

    function test_CreateListingRevertsOnZeroPrice() public {
        vm.prank(seller);
        vm.expectRevert(ListingManager.ZeroPrice.selector);
        lm.createListing(0, 1, WINDOW, "", "");
    }

    function test_CreateListingRevertsOnZeroSlots() public {
        vm.prank(seller);
        vm.expectRevert(ListingManager.ZeroSlots.selector);
        lm.createListing(PRICE, 0, WINDOW, "", "");
    }

    function test_CreateListingRevertsWhenExceedingMaxSlots() public {
        // Resolve MAX_SLOTS into locals *before* arming expectRevert - vm.expectRevert() fires on the very next
        // external call, and lm.MAX_SLOTS() staticcalls evaluated inline as call arguments would otherwise be
        // "the next call" instead of createListing() itself.
        uint256 max = lm.MAX_SLOTS();
        uint256 tooMany = max + 1;
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.TooManySlots.selector, tooMany, max));
        lm.createListing(PRICE, tooMany, WINDOW, "", "");
    }

    /// @notice Direct regression test named in the build strategy: a listing cannot be created with a
    ///         completion window below the protocol minimum.
    function testFuzz_CreateListingRevertsWhenWindowBelowMinimum(uint256 windowSeed) public {
        uint256 window = bound(windowSeed, 0, WINDOW - 1);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.CompletionWindowTooShort.selector, window, WINDOW));
        lm.createListing(PRICE, 1, window, "", "");
    }

    function test_CreateListingRevertsWhenInsufficientFreeIB() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IntegrityBond.InsufficientFreeIB.selector, seller, 150 ether, 100 ether));
        lm.createListing(PRICE, 100, WINDOW, "", ""); // 1.5 * 1 ether * 100 = 150 ether > 100 ether free
    }

    // ── confirmPayment ─────────────────────────────────────────────────────────────────────────────────────────

    function test_ConfirmPaymentStartsCompletionWindow() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 2, WINDOW, "", "");

        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);

        (ListingManager.SlotStatus status, uint256 deadline, address recordedBuyer, uint256 cycle) =
            lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.PaymentConfirmed));
        assertEq(deadline, block.timestamp + WINDOW);
        assertEq(recordedBuyer, buyer, "buyer of record must be stored for later restitution routing");
        assertEq(cycle, 1, "first-ever sale of this slot is cycle 1");

        (,,, uint256 emptySlots,,,) = lm.listings(listingId);
        assertEq(emptySlots, 1);
    }

    function test_ConfirmPaymentRevertsWhenNotController() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.NotController.selector, stranger));
        lm.confirmPayment(listingId, 0, buyer);
    }

    function test_ConfirmPaymentRevertsWhenSlotNotEmpty() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotEmpty.selector, listingId, 0));
        lm.confirmPayment(listingId, 0, buyer);
    }

    function test_ConfirmPaymentRevertsOnOutOfRangeSlot() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotIndexOutOfRange.selector, 1, 1));
        lm.confirmPayment(listingId, 1, buyer);
    }

    function test_ConfirmPaymentRevertsOnClosedListing() public {
        vm.startPrank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        lm.closeListing(listingId);
        vm.stopPrank();

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.ListingAlreadyClosed.selector, listingId));
        lm.confirmPayment(listingId, 0, buyer);
    }

    // ── finalizeExpiredSlot ────────────────────────────────────────────────────────────────────────────────────

    function test_FinalizeExpiredSlotRevertsBeforeDeadline() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);

        vm.expectRevert(
            abi.encodeWithSelector(ListingManager.WindowNotYetExpired.selector, listingId, 0, block.timestamp + WINDOW)
        );
        lm.finalizeExpiredSlot(listingId, 0);
    }

    function test_FinalizeExpiredSlotRecyclesToEmptyWithoutUnlockingIB() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);

        vm.warp(block.timestamp + WINDOW);
        vm.prank(stranger); // anyone may call this - no controller check
        lm.finalizeExpiredSlot(listingId, 0);

        (ListingManager.SlotStatus status, uint256 deadline, address recordedBuyer, uint256 cycle) =
            lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Empty)); // recycled, ready for the next buyer
        assertEq(deadline, 0);
        assertEq(recordedBuyer, address(0), "buyer of record is cleared on recycle");
        assertEq(cycle, 1, "cycle is a permanent counter, untouched by recycling");
        assertEq(bond.freeIB(seller), 100 ether - PER_SLOT_LOCKED); // stays locked - still backs this slot's next sale

        (,,, uint256 emptySlots,,,) = lm.listings(listingId);
        assertEq(emptySlots, 1, "slot becomes reusable capacity again");
    }

    function test_FinalizeExpiredSlotRevertsOnEmptySlot() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotPaymentConfirmed.selector, listingId, 0));
        lm.finalizeExpiredSlot(listingId, 0);
    }

    /// @notice Direct regression test named in the build strategy and Section 2.5: an open dispute is never
    ///         subject to the window's expiry, even long after the window would otherwise have elapsed.
    function test_DisputedSlotCannotBeFinalizedByWindowExpiryEvenLongAfterDeadline() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);

        vm.prank(controller);
        lm.markDisputed(listingId, 0);

        vm.warp(block.timestamp + WINDOW * 10); // far past any reasonable expiry
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotPaymentConfirmed.selector, listingId, 0));
        lm.finalizeExpiredSlot(listingId, 0);

        // capital stays locked, untouched, the whole time
        assertEq(bond.freeIB(seller), 100 ether - PER_SLOT_LOCKED);
    }

    /// @notice Direct regression test named in the build strategy: a dispute opened one block before window
    ///         expiry keeps the slot locked regardless of remaining window time.
    function test_DisputeOpenedOneBlockBeforeExpiryStillBlocksFinalization() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);

        vm.warp(block.timestamp + WINDOW - 1);
        vm.prank(controller);
        lm.markDisputed(listingId, 0);

        vm.warp(block.timestamp + 2); // now past the original deadline
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotPaymentConfirmed.selector, listingId, 0));
        lm.finalizeExpiredSlot(listingId, 0);
    }

    // ── confirmCompletion (buyer early release) ──────────────────────────────────────────────────────────────────

    event SlotCompleted(uint256 indexed listingId, uint256 indexed slotIndex, address indexed buyer, uint256 cycle);

    function test_ConfirmCompletionRecyclesSlotToEmptyWithoutUnlockingIB() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);
        assertEq(bond.freeIB(seller), 100 ether - PER_SLOT_LOCKED); // locked while confirmed

        // Well before the completion window would ever expire, the buyer confirms receipt.
        vm.expectEmit(true, true, true, true);
        emit SlotCompleted(listingId, 0, buyer, 1);
        vm.prank(buyer);
        lm.confirmCompletion(listingId, 0);

        (ListingManager.SlotStatus status, uint256 deadline, address recordedBuyer, uint256 cycle) =
            lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Empty)); // recycled, not permanently spent
        assertEq(deadline, 0);
        assertEq(recordedBuyer, address(0), "buyer of record is cleared on recycle");
        assertEq(cycle, 1);
        assertEq(bond.freeIB(seller), 100 ether - PER_SLOT_LOCKED); // stays locked - still backs this slot's next sale

        (,,, uint256 emptySlots,,,) = lm.listings(listingId);
        assertEq(emptySlots, 1);
    }

    function test_ConfirmCompletionRevertsWhenCallerIsNotTheBuyer() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);

        // Neither the seller nor a stranger can release on the buyer's behalf - the window is the buyer's to waive.
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.NotBuyer.selector, seller, buyer));
        lm.confirmCompletion(listingId, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.NotBuyer.selector, stranger, buyer));
        lm.confirmCompletion(listingId, 0);

        assertEq(bond.freeIB(seller), 100 ether - PER_SLOT_LOCKED); // still locked; nothing moved
    }

    function test_ConfirmCompletionRevertsOnEmptySlot() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        // An unpaid slot has no buyer of record; wrong-status is reported before the buyer check.
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotPaymentConfirmed.selector, listingId, 0));
        lm.confirmCompletion(listingId, 0);
    }

    function test_ConfirmCompletionRevertsOnDisputedSlot() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.startPrank(controller);
        lm.confirmPayment(listingId, 0, buyer);
        lm.markDisputed(listingId, 0);
        vm.stopPrank();

        // Once a dispute is open the outcome is the market's, not the buyer's to unilaterally close.
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotPaymentConfirmed.selector, listingId, 0));
        lm.confirmCompletion(listingId, 0);
    }

    function test_ConfirmCompletionIsIdempotentlyRejectedAfterItSucceeds() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);

        vm.prank(buyer);
        lm.confirmCompletion(listingId, 0);

        // Slot is Empty now (recycled); a second confirm (or a window-expiry finalize) must revert - it is no
        // longer PaymentConfirmed, regardless of how much locked capital still backs it.
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotPaymentConfirmed.selector, listingId, 0));
        lm.confirmCompletion(listingId, 0);

        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotPaymentConfirmed.selector, listingId, 0));
        lm.finalizeExpiredSlot(listingId, 0);
    }

    function test_ConfirmedThenCompletedSlotCanNoLongerBeDisputed() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);

        vm.prank(buyer);
        lm.confirmCompletion(listingId, 0);

        // A controller (DisputeManager) can no longer open a dispute on a slot the buyer already signed off.
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotPaymentConfirmed.selector, listingId, 0));
        lm.markDisputed(listingId, 0);
    }

    function test_ConfirmCompletionRevertsOnOutOfRangeSlot() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotIndexOutOfRange.selector, 1, 1));
        lm.confirmCompletion(listingId, 1);
    }

    function test_ConfirmCompletionRevertsOnUnknownListing() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.ListingNotFound.selector, 42));
        lm.confirmCompletion(42, 0);
    }

    /// @notice Completion is per-slot and per-buyer: one buyer confirming their own slot must never release,
    ///         touch, or expose any other slot on the same listing (including another buyer's).
    function testFuzz_ConfirmCompletionRecyclesExactlyOneSlotAndOnlyTheCallersOwn(
        uint256 totalSlots,
        uint256 confirmCount,
        uint256 completeIndex
    ) public {
        totalSlots = bound(totalSlots, 2, 50);
        confirmCount = bound(confirmCount, 2, totalSlots);
        completeIndex = bound(completeIndex, 0, confirmCount - 1);

        address otherBuyer = makeAddr("otherBuyer");

        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, totalSlots, WINDOW, "", "");
        vm.startPrank(controller);
        for (uint256 i = 0; i < confirmCount; i++) {
            // Give the target slot to `buyer`; every other confirmed slot to a different buyer.
            lm.confirmPayment(listingId, i, i == completeIndex ? buyer : otherBuyer);
        }
        vm.stopPrank();

        uint256 freeBefore = bond.freeIB(seller);

        // A stranger still cannot complete the target slot, even amid many confirmed slots.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.NotBuyer.selector, stranger, buyer));
        lm.confirmCompletion(listingId, completeIndex);

        vm.prank(buyer);
        lm.confirmCompletion(listingId, completeIndex);

        assertEq(bond.freeIB(seller), freeBefore, "IB stays locked - completing a slot never unlocks any capital");

        (ListingManager.SlotStatus target,,,) = lm.slots(listingId, completeIndex);
        assertEq(uint8(target), uint8(ListingManager.SlotStatus.Empty));

        // Every other confirmed slot is untouched - still PaymentConfirmed, still locked.
        for (uint256 i = 0; i < confirmCount; i++) {
            if (i == completeIndex) continue;
            (ListingManager.SlotStatus s,,,) = lm.slots(listingId, i);
            assertEq(uint8(s), uint8(ListingManager.SlotStatus.PaymentConfirmed));
        }
    }

    // ── markDisputed / resolveDispute ──────────────────────────────────────────────────────────────────────────

    function test_MarkDisputedRevertsWhenNotController() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.NotController.selector, stranger));
        lm.markDisputed(listingId, 0);
    }

    /// @notice A resolved slot is always permanently spent (Removed), never recycled back to Empty, regardless of
    ///         which way the dispute went - the 0.5P joint-injection draw at dispute-open already irreversibly
    ///         removed half its collateral before any verdict existed, so nothing left locked could satisfy a
    ///         fresh sale's requirement even on an Innocent verdict. This holds regardless of whether the listing
    ///         is still open. See {ListingManager-resolveDispute}'s own doc for the full reasoning.
    function test_ResolveDisputeAlwaysMarksSlotRemovedNeverEmpty() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.startPrank(controller);
        lm.confirmPayment(listingId, 0, buyer);
        lm.markDisputed(listingId, 0);
        lm.resolveDispute(listingId, 0);
        vm.stopPrank();

        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Removed));
        (,,, uint256 emptySlots,,,) = lm.listings(listingId);
        assertEq(emptySlots, 0); // Removed does not count as reusable capacity

        // Never sellable again through this slot index - a seller who wants this capacity back creates a new
        // listing.
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotEmpty.selector, listingId, 0));
        lm.confirmPayment(listingId, 0, buyer);
    }

    function test_ResolveDisputeOnClosedListingAlsoMarksRemoved() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);
        vm.prank(seller);
        lm.closeListing(listingId); // no empty slots to release yet, but blocks future reuse

        vm.startPrank(controller);
        lm.markDisputed(listingId, 0);
        lm.resolveDispute(listingId, 0);
        vm.stopPrank();

        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Removed));
        (,,, uint256 emptySlots,,,) = lm.listings(listingId);
        assertEq(emptySlots, 0);
    }

    function test_ResolveDisputeRevertsWhenNotDisputed() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotDisputed.selector, listingId, 0));
        lm.resolveDispute(listingId, 0);
    }

    // ── Slot reuse (recycling) ─────────────────────────────────────────────────────────────────────────────────

    function test_RecycledSlotCanBeSoldToADifferentBuyerWithBondStillLocked() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");

        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer);
        vm.prank(buyer);
        lm.confirmCompletion(listingId, 0);

        address secondBuyer = makeAddr("secondBuyer");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, secondBuyer);

        (ListingManager.SlotStatus status, uint256 deadline, address recordedBuyer, uint256 cycle) =
            lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.PaymentConfirmed));
        assertEq(recordedBuyer, secondBuyer);
        assertEq(cycle, 2, "second sale bumps the cycle counter");
        assertEq(deadline, block.timestamp + WINDOW);
        assertEq(bond.freeIB(seller), 100 ether - PER_SLOT_LOCKED, "same capital keeps backing every sale");

        vm.prank(secondBuyer);
        lm.confirmCompletion(listingId, 0);
        assertEq(bond.freeIB(seller), 100 ether - PER_SLOT_LOCKED, "still locked after the second sale completes");
    }

    /// @notice A seller can resell the same slot indefinitely without ever creating a new listing, and its
    ///         Locked IB never moves an inch until the seller explicitly reclaims it - satisfying exactly the
    ///         "seller shouldn't have to keep re-adding slots at the same price" requirement this design exists
    ///         for.
    function testFuzz_SlotSurvivesManySequentialSalesWithBondNeverMovingUntilExplicitlyReduced(uint8 salesSeed) public {
        uint256 sales = bound(salesSeed, 1, 20);

        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");

        for (uint256 i = 0; i < sales; i++) {
            address cycleBuyer = address(uint160(uint256(keccak256(abi.encode("cycleBuyer", i)))));
            vm.prank(controller);
            lm.confirmPayment(listingId, 0, cycleBuyer);

            (,,, uint256 cycle) = lm.slots(listingId, 0);
            assertEq(cycle, i + 1);

            vm.prank(cycleBuyer);
            lm.confirmCompletion(listingId, 0);
            assertEq(bond.freeIB(seller), 100 ether - PER_SLOT_LOCKED);
        }

        // The seller can still reclaim the slot's capital any time it's sitting Empty, even after many resales.
        vm.prank(seller);
        lm.reduceSlots(listingId, 1);
        assertEq(bond.freeIB(seller), 100 ether);
    }

    // ── reduceSlots / closeListing ─────────────────────────────────────────────────────────────────────────────

    function test_ReduceSlotsReleasesOnlyEmptySlots() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 3, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer); // slot 0 now occupied; slots 1,2 still empty

        vm.prank(seller);
        lm.reduceSlots(listingId, 2);

        (,,, uint256 emptySlots,,,) = lm.listings(listingId);
        assertEq(emptySlots, 0);
        assertEq(bond.freeIB(seller), 100 ether - PER_SLOT_LOCKED * 3 + PER_SLOT_LOCKED * 2);

        (ListingManager.SlotStatus s1,,,) = lm.slots(listingId, 1);
        (ListingManager.SlotStatus s2,,,) = lm.slots(listingId, 2);
        assertEq(uint8(s1), uint8(ListingManager.SlotStatus.Removed));
        assertEq(uint8(s2), uint8(ListingManager.SlotStatus.Removed));
    }

    /// @notice Direct regression test for the adversarial scenario the build strategy calls out: a slot whose
    ///         payment is confirmed can never be reclaimed by reduce/close, regardless of how the seller asks.
    function test_ReduceSlotsCannotTouchAConfirmedSlotEvenIfRequestedCountWouldReachIt() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 2, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer); // 1 empty slot remains (index 1)

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.InsufficientEmptySlots.selector, listingId, 2, 1));
        lm.reduceSlots(listingId, 2); // asking for both is impossible - slot 0 is confirmed, not empty

        (ListingManager.SlotStatus s0,,,) = lm.slots(listingId, 0);
        assertEq(uint8(s0), uint8(ListingManager.SlotStatus.PaymentConfirmed)); // untouched
    }

    function test_ReduceSlotsRevertsWhenNotSeller() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.NotSeller.selector, stranger, seller));
        lm.reduceSlots(listingId, 1);
    }

    function test_CloseListingReleasesEmptySlotsAndBlocksFutureConfirm() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 2, WINDOW, "", "");
        vm.prank(controller);
        lm.confirmPayment(listingId, 0, buyer); // 1 confirmed, 1 empty

        vm.prank(seller);
        lm.closeListing(listingId);

        (,,,,,, bool closed) = lm.listings(listingId);
        assertTrue(closed);
        assertEq(bond.freeIB(seller), 100 ether - PER_SLOT_LOCKED * 2 + PER_SLOT_LOCKED); // slot 1 released

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.ListingAlreadyClosed.selector, listingId));
        lm.confirmPayment(listingId, 1, buyer);

        // the still-confirmed slot 0 continues its normal lifecycle untouched
        vm.warp(block.timestamp + WINDOW);
        lm.finalizeExpiredSlot(listingId, 0);
        assertEq(bond.freeIB(seller), 100 ether - PER_SLOT_LOCKED); // slot 0 recycles, its own IB stays locked
        (ListingManager.SlotStatus s0,,,) = lm.slots(listingId, 0);
        assertEq(uint8(s0), uint8(ListingManager.SlotStatus.Empty)); // recycled, not permanently spent
    }

    function test_CloseListingRevertsWhenAlreadyClosed() public {
        vm.startPrank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW, "", "");
        lm.closeListing(listingId);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.ListingAlreadyClosed.selector, listingId));
        lm.closeListing(listingId);
        vm.stopPrank();
    }

    // ── Fuzz ───────────────────────────────────────────────────────────────────────────────────────────────────

    function testFuzz_CreateThenFullyReduceRoundTripsExactly(uint256 price, uint256 totalSlots) public {
        // A fresh, unfunded seller - `seller` from setUp() already carries a 100 ether deposit, which would
        // otherwise contaminate the "fully recovered, exactly" assertions below.
        address freshSeller = makeAddr("freshSeller");
        price = bound(price, 1, 1_000_000 ether);
        totalSlots = bound(totalSlots, 1, lm.MAX_SLOTS());
        uint256 perSlot = (price * 3 + 1) / 2; // ceilDiv mirrored for the assertion
        uint256 required = perSlot * totalSlots;

        vm.deal(freshSeller, required);
        vm.prank(freshSeller);
        bond.deposit{value: required}();

        vm.prank(freshSeller);
        uint256 listingId = lm.createListing(price, totalSlots, WINDOW, "", "");
        assertEq(bond.freeIB(freshSeller), 0);

        vm.prank(freshSeller);
        lm.closeListing(listingId);
        assertEq(bond.freeIB(freshSeller), required); // fully recovered, no dust left behind
    }

    function testFuzz_ConfirmedSlotSurvivesArbitraryReduceRequests(uint256 totalSlots, uint256 confirmCount) public {
        totalSlots = bound(totalSlots, 1, 50);
        confirmCount = bound(confirmCount, 1, totalSlots);

        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, totalSlots, WINDOW, "", "");
        vm.startPrank(controller);
        for (uint256 i = 0; i < confirmCount; i++) {
            lm.confirmPayment(listingId, i, buyer);
        }
        vm.stopPrank();

        (,,, uint256 emptySlots,,,) = lm.listings(listingId);
        assertEq(emptySlots, totalSlots - confirmCount);

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ListingManager.InsufficientEmptySlots.selector, listingId, totalSlots, totalSlots - confirmCount
            )
        );
        lm.reduceSlots(listingId, totalSlots); // requesting all N must fail whenever any slot is confirmed

        for (uint256 i = 0; i < confirmCount; i++) {
            (ListingManager.SlotStatus s,,,) = lm.slots(listingId, i);
            assertEq(uint8(s), uint8(ListingManager.SlotStatus.PaymentConfirmed));
        }
    }
}
