// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";

/// @notice Drives ListingManager through arbitrary interleavings of createListing/confirmPayment/
///         finalizeExpiredSlot/markDisputed/resolveDispute/reduceSlots/closeListing across a fixed pool of
///         sellers, for Foundry's stateful invariant fuzzer.
contract ListingManagerHandler is Test {
    IntegrityBond public bond;
    ListingManager public lm;
    address public controller;
    address[] public sellers;
    uint256[] public listingIds;

    constructor(IntegrityBond _bond, ListingManager _lm, address _controller, address[] memory _sellers) {
        bond = _bond;
        lm = _lm;
        controller = _controller;
        sellers = _sellers;
        for (uint256 i = 0; i < _sellers.length; i++) {
            vm.deal(_sellers[i], 1_000_000 ether);
            vm.prank(_sellers[i]);
            bond.deposit{value: 1_000 ether}();
        }
    }

    function createListing(uint256 sellerSeed, uint256 price, uint256 totalSlots, uint256 windowExtra) external {
        address seller = _pickSeller(sellerSeed);
        price = bound(price, 1, 1 ether);
        totalSlots = bound(totalSlots, 1, 5); // small on purpose - keeps the invariant's per-slot scan cheap
        uint256 window = lm.MIN_COMPLETION_WINDOW() + bound(windowExtra, 0, 30 days);
        uint256 perSlot = (price * 3 + 1) / 2;
        uint256 required = perSlot * totalSlots;
        if (bond.freeIB(seller) < required) return;

        vm.prank(seller);
        uint256 listingId = lm.createListing(price, totalSlots, window);
        listingIds.push(listingId);
    }

    function confirmPayment(uint256 listingSeed, uint256 slotSeed) external {
        if (listingIds.length == 0) return;
        uint256 listingId = _pickListing(listingSeed);
        (,, uint256 totalSlots,,,, bool closed) = lm.listings(listingId);
        if (closed) return;
        uint256 slotIndex = slotSeed % totalSlots;
        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, slotIndex);
        if (status != ListingManager.SlotStatus.Empty) return;

        address buyer = makeAddr(string.concat("handlerBuyer", vm.toString(listingId), vm.toString(slotIndex)));
        vm.prank(controller);
        lm.confirmPayment(listingId, slotIndex, buyer);
    }

    function finalizeExpiredSlot(uint256 listingSeed, uint256 slotSeed) external {
        if (listingIds.length == 0) return;
        uint256 listingId = _pickListing(listingSeed);
        (,, uint256 totalSlots,,,,) = lm.listings(listingId);
        uint256 slotIndex = slotSeed % totalSlots;
        (ListingManager.SlotStatus status, uint256 deadline,,) = lm.slots(listingId, slotIndex);
        if (status != ListingManager.SlotStatus.PaymentConfirmed) return;
        if (block.timestamp < deadline) {
            vm.warp(deadline);
        }
        lm.finalizeExpiredSlot(listingId, slotIndex);
    }

    function markDisputed(uint256 listingSeed, uint256 slotSeed) external {
        if (listingIds.length == 0) return;
        uint256 listingId = _pickListing(listingSeed);
        (,, uint256 totalSlots,,,,) = lm.listings(listingId);
        uint256 slotIndex = slotSeed % totalSlots;
        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, slotIndex);
        if (status != ListingManager.SlotStatus.PaymentConfirmed) return;

        vm.prank(controller);
        lm.markDisputed(listingId, slotIndex);
    }

    function resolveDispute(uint256 listingSeed, uint256 slotSeed) external {
        if (listingIds.length == 0) return;
        uint256 listingId = _pickListing(listingSeed);
        (address seller,, uint256 totalSlots,,, uint256 perSlotLocked,) = lm.listings(listingId);
        uint256 slotIndex = slotSeed % totalSlots;
        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, slotIndex);
        if (status != ListingManager.SlotStatus.Disputed) return;

        // Stand in for DisputeManager (Phase 7): unlock the slot's remaining IB directly on the bond *before*
        // telling ListingManager the dispute resolved - resolveDispute() itself deliberately moves no funds. This
        // handler never simulates the 0.5P joint-injection draw that a real markDisputed-adjacent dispute-open
        // would have already slashed away, so the full perSlotLocked is still genuinely sitting in `locked` here
        // regardless of which verdict this stands in for - releasing all of it on resolution is the correct bond
        // movement for this simplified world. Whichever verdict it stands in for, resolveDispute() itself always
        // moves the slot to Removed (never back to Empty) - see ListingManager's own doc for why even an
        // Innocent-style resolution can't leave a slot resellable once it has ever been disputed.
        vm.prank(controller);
        bond.unlock(seller, perSlotLocked);

        vm.prank(controller);
        lm.resolveDispute(listingId, slotIndex);
    }

    function reduceSlots(uint256 listingSeed, uint256 count) external {
        if (listingIds.length == 0) return;
        uint256 listingId = _pickListing(listingSeed);
        (address seller,,, uint256 emptySlots,,, bool closed) = lm.listings(listingId);
        if (closed || emptySlots == 0) return;
        count = bound(count, 1, emptySlots);

        vm.prank(seller);
        lm.reduceSlots(listingId, count);
    }

    function closeListing(uint256 listingSeed) external {
        if (listingIds.length == 0) return;
        uint256 listingId = _pickListing(listingSeed);
        (address seller,,,,,, bool closed) = lm.listings(listingId);
        if (closed) return;

        vm.prank(seller);
        lm.closeListing(listingId);
    }

    function sellersCount() external view returns (uint256) {
        return sellers.length;
    }

    function sellerAt(uint256 i) external view returns (address) {
        return sellers[i];
    }

    function listingIdsCount() external view returns (uint256) {
        return listingIds.length;
    }

    function _pickSeller(uint256 seed) internal view returns (address) {
        return sellers[seed % sellers.length];
    }

    function _pickListing(uint256 seed) internal view returns (uint256) {
        return listingIds[seed % listingIds.length];
    }
}
