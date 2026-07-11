// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {DisputeManager} from "../../src/DisputeManager.sol";

/// @notice Drives the full Settlement-less dispute lifecycle - createListing/confirmPayment (via a stand-in for
///         Settlement.sol) -> fundGuiltySide -> buy/sell -> resolve (via a stand-in for SettlementConditions, or
///         mutualClose) -> finalizeDispute - through arbitrary interleavings across a fixed pool of sellers and
///         traders, for Foundry's stateful invariant fuzzer. Each listing has exactly one slot, so `listingId` and
///         `marketId` (via {DisputeManager-marketIdOf}) are always in 1:1 correspondence.
contract DisputeManagerHandler is Test {
    IntegrityBond public bond;
    ListingManager public lm;
    SpectralMarket public market;
    DisputeManager public dm;
    address public settlementStandIn;
    address public priceController;
    address[] public sellers;
    address[] public traders;

    uint256[] public listingIds;

    constructor(
        IntegrityBond _bond,
        ListingManager _lm,
        SpectralMarket _market,
        DisputeManager _dm,
        address _settlementStandIn,
        address _priceController,
        address[] memory _sellers,
        address[] memory _traders
    ) {
        bond = _bond;
        lm = _lm;
        market = _market;
        dm = _dm;
        settlementStandIn = _settlementStandIn;
        priceController = _priceController;
        sellers = _sellers;
        traders = _traders;

        for (uint256 i = 0; i < _sellers.length; i++) {
            vm.deal(_sellers[i], 1_000_000 ether);
            vm.prank(_sellers[i]);
            bond.deposit{value: 1_000 ether}();
        }
        for (uint256 i = 0; i < _traders.length; i++) {
            vm.deal(_traders[i], 1_000_000 ether);
        }
    }

    function createAndConfirmListing(uint256 sellerSeed, uint256 priceSeed, uint256 buyerSeed) external {
        address seller = sellers[sellerSeed % sellers.length];
        uint256 price = bound(priceSeed, 0.02 ether, 1 ether);
        uint256 perSlotLocked = (price * 3 + 1) / 2;
        if (bond.freeIB(seller) < perSlotLocked) return;

        // MIN_COMPLETION_WINDOW() must be resolved into a local *before* vm.prank(seller): staticcalling it
        // inline as a call argument would otherwise be "the next call" that consumes the prank, leaving
        // createListing() itself to run as this handler rather than as seller (the exact gotcha already flagged
        // in ListingManager.t.sol's own test comments).
        uint256 window = lm.MIN_COMPLETION_WINDOW();
        vm.prank(seller);
        uint256 listingId = lm.createListing(price, 1, window, "", "");

        address buyer = traders[buyerSeed % traders.length];
        vm.prank(settlementStandIn);
        lm.confirmPayment(listingId, 0, buyer);

        listingIds.push(listingId);
    }

    function fundGuiltySide(uint256 listingSeed, uint256 funderSeed, uint256 amountSeed) external {
        uint256 listingId = _pickFundableListing(listingSeed);
        if (listingId == type(uint256).max) return;

        address funder = traders[funderSeed % traders.length];
        uint256 amount = bound(amountSeed, 1e12, 0.5 ether);

        vm.prank(funder);
        try dm.fundGuiltySide{value: amount}(listingId, 0) {} catch {}
    }

    function buy(uint256 marketSeed, uint256 traderSeed, uint256 sideSeed, uint256 sharesSeed) external {
        uint256 marketId = _pickOpenUnresolvedMarket(marketSeed);
        if (marketId == type(uint256).max) return;

        address trader = traders[traderSeed % traders.length];
        SpectralMarket.Side side = sideSeed % 2 == 0 ? SpectralMarket.Side.Guilty : SpectralMarket.Side.Innocent;
        uint256 shares = bound(sharesSeed, 1e9, 0.05 ether);

        vm.prank(trader);
        try market.buy{value: 100 ether}(marketId, side, shares) {} catch {}
    }

    function sell(uint256 marketSeed, uint256 traderSeed, uint256 sideSeed, uint256 sharesSeed) external {
        uint256 marketId = _pickOpenUnresolvedMarket(marketSeed);
        if (marketId == type(uint256).max) return;

        address trader = traders[traderSeed % traders.length];
        SpectralMarket.Side side = sideSeed % 2 == 0 ? SpectralMarket.Side.Guilty : SpectralMarket.Side.Innocent;
        uint256 held = market.sharesOf(marketId, side, trader);
        if (held == 0) return;
        uint256 shares = bound(sharesSeed, 1, held);

        vm.prank(trader);
        try market.sell(marketId, side, shares, 0) {} catch {}
    }

    function mutualClose(uint256 listingSeed, uint256 verdictSeed) external {
        uint256 listingId = _pickOpenUnresolvedListing(listingSeed);
        if (listingId == type(uint256).max) return;

        (address seller,,,,,,) = lm.listings(listingId);
        (,, address buyer,) = lm.slots(listingId, 0);
        SpectralMarket.Side verdict = verdictSeed % 2 == 0 ? SpectralMarket.Side.Guilty : SpectralMarket.Side.Innocent;

        vm.prank(buyer);
        try dm.mutualClose(listingId, 0, verdict) {} catch {}
        vm.prank(seller);
        try dm.mutualClose(listingId, 0, verdict) {} catch {}
    }

    function resolveViaPriceController(uint256 listingSeed, uint256 sideSeed) external {
        uint256 listingId = _pickOpenUnresolvedListing(listingSeed);
        if (listingId == type(uint256).max) return;

        uint256 marketId = _marketId(listingId);
        SpectralMarket.Side side = sideSeed % 2 == 0 ? SpectralMarket.Side.Guilty : SpectralMarket.Side.Innocent;
        vm.prank(priceController);
        try market.resolveMarket(marketId, side) {} catch {}
    }

    function finalizeDispute(uint256 listingSeed) external {
        if (listingIds.length == 0) return;
        uint256 listingId = listingIds[listingSeed % listingIds.length];
        uint256 marketId = _marketId(listingId);
        (bool opened, bool finalized) = dm.disputes(marketId);
        if (!opened || finalized) return;
        (,,,,, bool resolved,) = market.markets(marketId);
        if (!resolved) return;

        dm.finalizeDispute(listingId, 0);
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

    /// @dev Every listing this handler creates gets exactly one confirmPayment, ever (createAndConfirmListing
    ///      always mints a fresh listingId rather than reselling an existing one's slot 0), so its cycle is
    ///      always 1 - reading it live rather than hardcoding keeps this handler correct even if that ever
    ///      changes.
    function _marketId(uint256 listingId) internal view returns (uint256) {
        (,,, uint256 cycle) = lm.slots(listingId, 0);
        return dm.marketIdOf(listingId, 0, cycle);
    }

    /// @dev Returns the first listingId reachable from `seed` (wrapping) whose slot is PaymentConfirmed and whose
    ///      dispute has not yet opened, or type(uint256).max.
    function _pickFundableListing(uint256 seed) internal view returns (uint256) {
        uint256 len = listingIds.length;
        if (len == 0) return type(uint256).max;
        for (uint256 i = 0; i < len; i++) {
            uint256 candidate = listingIds[(seed + i) % len];
            (ListingManager.SlotStatus status,,,) = lm.slots(candidate, 0);
            if (status == ListingManager.SlotStatus.PaymentConfirmed) return candidate;
        }
        return type(uint256).max;
    }

    /// @dev Returns the first listingId reachable from `seed` (wrapping) whose market is open and not yet
    ///      resolved, or type(uint256).max.
    function _pickOpenUnresolvedListing(uint256 seed) internal view returns (uint256) {
        uint256 len = listingIds.length;
        if (len == 0) return type(uint256).max;
        for (uint256 i = 0; i < len; i++) {
            uint256 candidate = listingIds[(seed + i) % len];
            uint256 marketId = _marketId(candidate);
            (,,,, bool open, bool resolved,) = market.markets(marketId);
            if (open && !resolved) return candidate;
        }
        return type(uint256).max;
    }

    function _pickOpenUnresolvedMarket(uint256 seed) internal view returns (uint256) {
        uint256 listingId = _pickOpenUnresolvedListing(seed);
        if (listingId == type(uint256).max) return type(uint256).max;
        return _marketId(listingId);
    }
}
