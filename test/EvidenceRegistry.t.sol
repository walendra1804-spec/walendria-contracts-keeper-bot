// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IntegrityBond} from "../src/IntegrityBond.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {EvidenceRegistry} from "../src/EvidenceRegistry.sol";

contract EvidenceRegistryTest is Test {
    IntegrityBond internal bond;
    ListingManager internal lm;
    EvidenceRegistry internal registry;

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant PRICE = 1 ether;
    uint256 internal constant SLOTS = 3;
    uint256 internal constant WINDOW = 72 hours;

    uint256 internal listingId;

    function setUp() public {
        // bond must trust `lm`'s address before `lm` exists (createListing locks IB) - same CREATE-nonce
        // prediction pattern already used in Settlement.t.sol's setUp.
        uint256 nonce = vm.getNonce(address(this));
        address predictedLm = vm.computeCreateAddress(address(this), nonce + 1);

        address[] memory bondControllers = new address[](1);
        bondControllers[0] = predictedLm;
        bond = new IntegrityBond(bondControllers);

        // The test contract itself is ListingManager's only controller - EvidenceRegistry never calls
        // confirmPayment, so no real Settlement contract is needed; this test drives ListingManager's own state
        // directly to set up "a slot with a confirmed buyer" scenarios.
        address[] memory lmControllers = new address[](1);
        lmControllers[0] = address(this);
        lm = new ListingManager(bond, lmControllers, type(uint256).max);
        assertEq(address(lm), predictedLm, "CREATE nonce prediction drifted (lm)");

        registry = new EvidenceRegistry(lm);

        vm.deal(seller, 1000 ether);
        vm.prank(seller);
        bond.deposit{value: 100 ether}();

        vm.prank(seller);
        listingId = lm.createListing(PRICE, SLOTS, WINDOW, "", "");
    }

    function _confirmSlot0ForBuyer() internal {
        lm.confirmPayment(listingId, 0, buyer);
    }

    function _marketId(uint256 targetListingId, uint256 slotIndex) internal view returns (uint256) {
        (,,, uint256 cycle) = lm.slots(targetListingId, slotIndex);
        return registry.marketIdOf(targetListingId, slotIndex, cycle);
    }

    // ── Happy path ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_SellerCanSubmitEvidenceBeforePaymentConfirmed() public {
        // marketIdOf is an external view call on `registry` - computing it before vm.prank so it doesn't itself
        // consume the single-use prank meant for the real submitEvidence call below.
        uint256 marketId = _marketId(listingId, 0);

        vm.expectEmit(true, true, false, true, address(registry));
        emit EvidenceRegistry.EvidenceSubmitted(marketId, seller, listingId, 0, "ipfs://bafySellerEarlyEvidence");

        vm.prank(seller);
        registry.submitEvidence(listingId, 0, "ipfs://bafySellerEarlyEvidence");
    }

    function test_BuyerCanSubmitEvidenceAfterPaymentConfirmed() public {
        _confirmSlot0ForBuyer();
        uint256 marketId = _marketId(listingId, 0);

        vm.expectEmit(true, true, false, true, address(registry));
        emit EvidenceRegistry.EvidenceSubmitted(marketId, buyer, listingId, 0, "ipfs://bafyBuyerEvidence");

        vm.prank(buyer);
        registry.submitEvidence(listingId, 0, "ipfs://bafyBuyerEvidence");
    }

    function test_SellerCanStillSubmitAfterPaymentConfirmed() public {
        _confirmSlot0ForBuyer();

        vm.prank(seller);
        registry.submitEvidence(listingId, 0, "ipfs://bafySellerRebuttal");
    }

    function test_MultipleEvidenceSubmissionsAllowedForSameSlot() public {
        _confirmSlot0ForBuyer();

        vm.prank(buyer);
        registry.submitEvidence(listingId, 0, "ipfs://bafyFirst");

        vm.prank(seller);
        registry.submitEvidence(listingId, 0, "ipfs://bafySecond");

        vm.prank(buyer);
        registry.submitEvidence(listingId, 0, "ipfs://bafyThird");
        // No revert on repeated submissions - Section 2.6.2 sets no submission deadline or count limit while
        // the market remains open.
    }

    function test_MarketIdMatchesDisputeManagerDerivation() public view {
        // DisputeManager.marketIdOf uses the identical one-line formula (verified by inspection) - duplicated
        // here directly rather than via a deployed DisputeManager instance, since both are pure functions with
        // no shared state to wire up. Slot 0 has never been paid for in this test, so its cycle is still 0.
        uint256 expected = uint256(keccak256(abi.encode(listingId, uint256(0), uint256(0))));
        assertEq(registry.marketIdOf(listingId, 0, 0), expected);
    }

    // ── Reverts ────────────────────────────────────────────────────────────────────────────────────────────────

    function test_RevertsOnEmptyCid() public {
        vm.prank(seller);
        vm.expectRevert(EvidenceRegistry.EmptyCid.selector);
        registry.submitEvidence(listingId, 0, "");
    }

    function test_RevertsOnCidTooLong() public {
        bytes memory tooLong = new bytes(257);
        for (uint256 i = 0; i < tooLong.length; i++) {
            tooLong[i] = "a";
        }
        uint256 maxLength = registry.MAX_CID_LENGTH();

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.CidTooLong.selector, 257, maxLength));
        registry.submitEvidence(listingId, 0, string(tooLong));
    }

    function test_CidLengthBoundaryExactlyAtMax() public {
        bytes memory exact = new bytes(256);
        for (uint256 i = 0; i < exact.length; i++) {
            exact[i] = "a";
        }

        vm.prank(seller);
        registry.submitEvidence(listingId, 0, string(exact));
    }

    function test_RevertsWhenCallerIsNeitherBuyerNorSeller() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotBuyerOrSeller.selector, listingId, 0, stranger));
        registry.submitEvidence(listingId, 0, "ipfs://bafyStrangerAttempt");
    }

    function test_RevertsWhenCallerIsBuyerOfDifferentSlotOnlyBeforeConfirmation() public {
        _confirmSlot0ForBuyer(); // buyer is confirmed on slot 0 only

        // slot 1 has no confirmed buyer yet (address(0)) - buyer must not be able to submit there.
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotBuyerOrSeller.selector, listingId, 1, buyer));
        registry.submitEvidence(listingId, 1, "ipfs://bafyWrongSlot");
    }

    function test_RevertsForNonexistentListing() public {
        uint256 fakeListingId = listingId + 999;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotBuyerOrSeller.selector, fakeListingId, 0, stranger));
        registry.submitEvidence(fakeListingId, 0, "ipfs://bafyGhostListing");
    }

    // ── Adversarial ────────────────────────────────────────────────────────────────────────────────────────────

    function test_CannotImpersonateBuyerFromAnotherListing() public {
        _confirmSlot0ForBuyer(); // buyer is the confirmed buyer of listingId's slot 0

        address seller2 = makeAddr("seller2");
        vm.deal(seller2, 1000 ether);
        vm.prank(seller2);
        bond.deposit{value: 100 ether}();
        vm.prank(seller2);
        uint256 listingId2 = lm.createListing(PRICE, SLOTS, WINDOW, "", "");
        // listingId2's slot 0 has no confirmed buyer - `buyer` from the other listing must not be treated as a
        // party to this unrelated listing just because they hold that role elsewhere.

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotBuyerOrSeller.selector, listingId2, 0, buyer));
        registry.submitEvidence(listingId2, 0, "ipfs://bafyCrossListingAttempt");
    }

    function test_SellerOfOtherListingCannotSubmitForThisOne() public {
        address seller2 = makeAddr("seller2");
        vm.deal(seller2, 1000 ether);
        vm.prank(seller2);
        bond.deposit{value: 100 ether}();
        vm.prank(seller2);
        lm.createListing(PRICE, SLOTS, WINDOW, "", "");

        vm.prank(seller2);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotBuyerOrSeller.selector, listingId, 0, seller2));
        registry.submitEvidence(listingId, 0, "ipfs://bafyWrongSeller");
    }

    // ── Fuzz ───────────────────────────────────────────────────────────────────────────────────────────────────

    function testFuzz_AccessControlHoldsForArbitraryCaller(address caller) public {
        vm.assume(caller != seller && caller != buyer && caller != address(0));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotBuyerOrSeller.selector, listingId, 0, caller));
        registry.submitEvidence(listingId, 0, "ipfs://bafyFuzzAttempt");
    }

    function testFuzz_MarketIdDerivationMatchesFormula(uint256 listingIdSeed, uint256 slotIndexSeed, uint256 cycleSeed)
        public
        view
    {
        assertEq(
            registry.marketIdOf(listingIdSeed, slotIndexSeed, cycleSeed),
            uint256(keccak256(abi.encode(listingIdSeed, slotIndexSeed, cycleSeed)))
        );
    }

    function testFuzz_CidLengthValidation(uint16 lengthSeed) public {
        uint256 length = lengthSeed % 300; // 0..299, straddling MAX_CID_LENGTH (256) on both sides
        bytes memory cid = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            cid[i] = "a";
        }
        uint256 maxLength = registry.MAX_CID_LENGTH();

        vm.prank(seller);
        if (length == 0) {
            vm.expectRevert(EvidenceRegistry.EmptyCid.selector);
        } else if (length > maxLength) {
            vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.CidTooLong.selector, length, maxLength));
        }
        registry.submitEvidence(listingId, 0, string(cid));
    }
}
