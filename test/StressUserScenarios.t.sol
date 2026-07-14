// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SD59x18} from "prb-math/SD59x18.sol";
import {IntegrityBond} from "../src/IntegrityBond.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {Settlement} from "../src/Settlement.sol";
import {SpectralMarket} from "../src/SpectralMarket.sol";
import {ISettlementConditionsHook} from "../src/ISettlementConditionsHook.sol";
import {SettlementConditions} from "../src/SettlementConditions.sol";
import {DisputeManager} from "../src/DisputeManager.sol";
import {DeveloperPool} from "../src/DeveloperPool.sol";
import {EvidenceRegistry} from "../src/EvidenceRegistry.sol";

/// @notice User-supplied stress scenarios covering:
///           1. Happy path — slot recycles across buyers, marketId differs per cycle
///           2. Dispute Guilty via natural cumulative-time resolution
///           3. Dispute Innocent via natural cumulative-time resolution
///           4. WTF path — seller tries to close/reduce listing while a dispute is live
///           5. WTF path — attempts to force-resolve a market before conditions are met
contract StressUserScenarios is Test {
    IntegrityBond internal bond;
    ListingManager internal lm;
    Settlement internal settlement;
    SpectralMarket internal market;
    SettlementConditions internal conditions;
    DisputeManager internal dm;
    DeveloperPool internal devPool;
    EvidenceRegistry internal evidence;

    address internal developer = makeAddr("developer");
    address internal withdrawalRecipient = makeAddr("withdrawalRecipient");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal buyer2 = makeAddr("buyer2");
    address internal funder1 = makeAddr("funder1");
    address internal funder2 = makeAddr("funder2");
    address internal poker = makeAddr("poker");
    address internal randomEOA = makeAddr("random");

    uint256 internal constant P = 1 ether;
    uint256 internal constant WINDOW = 72 hours;
    uint256 internal constant HARDCAP = 100 ether;
    uint256 internal constant POKE_BOUNTY_BPS = 10;
    uint256 internal constant FEE_BPS = 50; // 0.5%

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedLm = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedMarket = vm.computeCreateAddress(address(this), nonce + 4);
        address predictedSettlement = vm.computeCreateAddress(address(this), nonce + 5);
        address predictedDm = vm.computeCreateAddress(address(this), nonce + 6);

        address[] memory bondControllers = new address[](2);
        bondControllers[0] = predictedLm;
        bondControllers[1] = predictedDm;
        bond = new IntegrityBond(bondControllers);

        address[] memory lmControllers = new address[](2);
        lmControllers[0] = predictedSettlement;
        lmControllers[1] = predictedDm;
        lm = new ListingManager(bond, lmControllers, HARDCAP);
        require(address(lm) == predictedLm, "lm mismatch");

        devPool = new DeveloperPool(developer, withdrawalRecipient);
        conditions = new SettlementConditions(SpectralMarket(predictedMarket), POKE_BOUNTY_BPS);

        address[] memory mkCtrl = new address[](2);
        mkCtrl[0] = predictedDm;
        mkCtrl[1] = address(conditions);
        market = new SpectralMarket(mkCtrl, ISettlementConditionsHook(address(conditions)), address(devPool));
        require(address(market) == predictedMarket, "market mismatch");

        settlement = new Settlement(lm, address(devPool));
        require(address(settlement) == predictedSettlement, "settlement mismatch");

        dm = new DisputeManager(lm, bond, market);
        require(address(dm) == predictedDm, "dm mismatch");

        evidence = new EvidenceRegistry(lm);

        vm.deal(seller, 100 ether);
        vm.deal(buyer, 100 ether);
        vm.deal(buyer2, 100 ether);
        vm.deal(funder1, 100 ether);
        vm.deal(funder2, 100 ether);
        vm.deal(poker, 1 ether);
        vm.deal(randomEOA, 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Test 1 — Happy path: slot recycles across buyers, dispute id differs per cycle
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_1_happyPath_slotRecyclesMarketIdDiffersPerCycle() public {
        // seller creates 1-slot listing, exact 1.5P bond
        vm.startPrank(seller);
        bond.deposit{value: (3 * P) / 2}();
        uint256 id = lm.createListing(P, 1, WINDOW, "", "");
        vm.stopPrank();

        // ── Sale #1 ──
        vm.prank(buyer);
        settlement.pay{value: P}(id, 0);
        uint256 cycle1 = _slotCycle(id, 0);
        uint256 marketId1 = dm.marketIdOf(id, 0, cycle1);
        assertEq(cycle1, 1, "cycle 1 after first pay");
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.PaymentConfirmed));
        assertEq(_slotBuyerOf(id, 0), buyer);

        // buyer confirms early → slot recycles
        vm.prank(buyer);
        lm.confirmCompletion(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Empty), "slot back to Empty");
        assertEq(_slotBuyerOf(id, 0), address(0), "buyer field cleared");

        // Listing state — slot still there, empty count restored, IB still fully locked
        (,, uint256 totalSlots, uint256 emptySlots,, uint256 perSlotLocked,) = lm.listings(id);
        assertEq(totalSlots, 1);
        assertEq(emptySlots, 1);
        (, uint256 locked1) = bond.bonds(seller);
        assertEq(locked1, perSlotLocked, "IB still locked for recycled slot");

        // ── Sale #2 (SAME slot index, DIFFERENT buyer) ──
        vm.prank(buyer2);
        settlement.pay{value: P}(id, 0);
        uint256 cycle2 = _slotCycle(id, 0);
        uint256 marketId2 = dm.marketIdOf(id, 0, cycle2);
        assertEq(cycle2, 2, "cycle bumped to 2");
        assertEq(_slotBuyerOf(id, 0), buyer2, "new buyer recorded");
        assertTrue(marketId1 != marketId2, "marketId differs between cycles for same slotIndex");

        vm.prank(buyer2);
        lm.confirmCompletion(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Empty));

        // IB locked accounting still identical
        (, uint256 locked2) = bond.bonds(seller);
        assertEq(locked2, locked1, "no bond movement across cycles");

        // The two cycles both were on the same slotIndex 0 of the same listingId — only cycle differs
        assertEq(cycle2, cycle1 + 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Test 2 — Dispute Guilty via natural cumulative-time resolution
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_2_disputeGuiltyCumulativeTimeResolution() public {
        vm.startPrank(seller);
        bond.deposit{value: (3 * P) / 2}();
        uint256 id = lm.createListing(P, 1, WINDOW, "", "");
        vm.stopPrank();

        uint256 buyerStart = buyer.balance;
        uint256 sellerBaseline = seller.balance; // AFTER bond deposit, BEFORE payment

        // buyer pays 1P → seller wallet +0.995P, devPool +0.005P
        vm.prank(buyer);
        settlement.pay{value: P}(id, 0);
        assertEq(seller.balance, sellerBaseline + (P * (10_000 - FEE_BPS)) / 10_000, "0.995P forwarded to seller");
        uint256 sellerPostSale = seller.balance;
        assertEq(bond.freeIB(seller), 0, "seller free IB is 0 (all locked)");
        uint256 sellerFreeIbPostSale = bond.freeIB(seller);

        // buyer funds 0.5P Guilty → dispute opens
        uint256 marketId = dm.marketIdOf(id, 0, _slotCycle(id, 0));
        vm.prank(buyer);
        dm.fundGuiltySide{value: P / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));
        assertEq(buyer.balance, buyerStart - P - P / 2, "buyer paid 1P + 0.5P Guilty funding");

        // funder1 pushes Guilty price >= 93% (buys 3 ether more Guilty shares)
        vm.prank(funder1);
        market.buy{value: 5 ether}(marketId, SpectralMarket.Side.Guilty, 3 ether);
        (uint256 pG,) = market.currentPrice(marketId);
        assertGe(pG, 0.93e18, "Guilty price >= 93%");

        // Cumulative time doesn't reach 1h yet — poking now must fail
        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.ConditionsNotYetMet.selector, marketId));
        vm.prank(poker);
        conditions.pokeSettlement(marketId);

        // Warp 1 hour + 1 second → poke succeeds
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(poker);
        conditions.pokeSettlement(marketId);

        (,,,,, bool resolved, SpectralMarket.Side winningSide) = market.markets(marketId);
        assertTrue(resolved, "market resolved");
        assertEq(uint8(winningSide), uint8(SpectralMarket.Side.Guilty), "Guilty verdict");

        // finalizeDispute: 1P remaining IB → buyer restitution
        dm.finalizeDispute(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Removed), "slot Removed post-dispute");

        // Buyer claims restitution (1P) then redeems Guilty shares (1P — initial 0.5P at 0.5 avg → 1P shares)
        vm.prank(buyer);
        bond.claim();
        vm.prank(buyer);
        uint256 buyerRedeem = market.redeem(marketId);
        assertEq(buyerRedeem, P, "buyer redeems full 1P from initial Guilty position");

        // ═══ USER-SPECIFIED ASSERTIONS ═══
        // "wallet buyer nambah 0,5P net" — check buyer balance delta from start
        assertEq(buyer.balance, buyerStart + P / 2, "buyer NET +0.5P (whitepaper matches)");

        // "wallet seller ga berubah" — measured from post-sale state, seller wallet unchanged during dispute
        assertEq(seller.balance, sellerPostSale, "seller wallet unchanged from post-sale (no dispute inflow)");

        // "free ib seller ga berubah" — free IB was 0 (all locked), still 0 (all slashed)
        assertEq(bond.freeIB(seller), sellerFreeIbPostSale, "seller free IB unchanged (was 0, still 0)");

        // Full ecosystem accounting — matches whitepaper §3.1:
        // Seller net = -0.505P (deposit 1.5P, receive 0.995P sale, lose 1.5P IB → all gone)
        (uint256 total, uint256 locked) = bond.bonds(seller);
        assertEq(total, 0, "seller IB total = 0 (fully slashed)");
        assertEq(locked, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Test 3 — Dispute Innocent via natural cumulative-time resolution
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_3_disputeInnocentCumulativeTimeResolution() public {
        // Record seller's balance BEFORE any test action so we can measure profit over honest baseline
        uint256 sellerAbsoluteStart = seller.balance;

        vm.startPrank(seller);
        bond.deposit{value: (3 * P) / 2}();
        uint256 id = lm.createListing(P, 1, WINDOW, "", "");
        vm.stopPrank();

        uint256 buyerStart = buyer.balance;
        uint256 sellerBaseline = seller.balance;

        vm.prank(buyer);
        settlement.pay{value: P}(id, 0);
        uint256 sellerPostSale = seller.balance;

        // buyer funds 0.5P Guilty (false claim)
        uint256 marketId = dm.marketIdOf(id, 0, _slotCycle(id, 0));
        vm.prank(buyer);
        dm.fundGuiltySide{value: P / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));

        // funder1 defends the seller by pushing Innocent price >= 93%
        vm.prank(funder1);
        market.buy{value: 5 ether}(marketId, SpectralMarket.Side.Innocent, 3 ether);
        (, uint256 pI) = market.currentPrice(marketId);
        assertGe(pI, 0.93e18, "Innocent price >= 93%");

        // Warp 1 hour + 1 second, poke → Innocent verdict
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(poker);
        conditions.pokeSettlement(marketId);
        (,,,,, bool resolved, SpectralMarket.Side winningSide) = market.markets(marketId);
        assertTrue(resolved);
        assertEq(uint8(winningSide), uint8(SpectralMarket.Side.Innocent), "Innocent verdict");

        // finalizeDispute: 1P remaining IB unlocks back to seller's free IB
        dm.finalizeDispute(id, 0);

        // Seller redeems their locked Innocent position (1P shares → 1P from pool)
        vm.prank(seller);
        uint256 sellerRedeem = market.redeem(marketId);
        assertEq(sellerRedeem, P, "seller redeems full 1P from initial Innocent position");

        // ═══ USER-SPECIFIED ASSERTIONS ═══
        // "verify bahwa free ib seller nambah 1,5P" — ACTUAL is +1P from unlock (0.5P was already slashed at
        // dispute open and cannot come back to IB directly). Documenting the mismatch:
        assertEq(bond.freeIB(seller), P, "free IB increased by 1P (0.5P slashed cannot return to IB)");

        // "serta win 0,5P dari shares nya guilty si buyer" — seller's Innocent shares redeem 1P, which is
        // composed of their initial 0.5P plus 0.5P of buyer's forfeit → +0.5P net win from market side
        // Verified by comparing to honest baseline below.

        // "wallet buyer ga nambah" — buyer lost 1.5P total (paid 1P + funded 0.5P forfeited)
        assertEq(buyer.balance, buyerStart - P - P / 2, "buyer lost 1.5P total (no gain)");

        // Seller wallet: +0.995P (sale) + 1P (Innocent redeem) = +1.995P from post-deposit baseline
        assertEq(seller.balance, sellerPostSale + P, "seller wallet gained additional 1P from redemption");
        uint256 sellerWalletTotalDelta = seller.balance - sellerBaseline;
        assertEq(sellerWalletTotalDelta, P + (P * (10_000 - FEE_BPS)) / 10_000, "wallet delta = 1P + 0.995P");

        // "seller untung net profit 0,5P" — measured beyond the honest-sale baseline:
        //   Honest: seller ends with wallet+IB = sellerAbsoluteStart + 0.995P (sale) + 0 (bond fully returned)
        //   Innocent verdict: seller ends with wallet+IB = sellerAbsoluteStart + 0.995P + 0.5P (buyer forfeit)
        //   Difference = +0.5P profit over honest baseline
        (uint256 total,) = bond.bonds(seller);
        assertEq(total, P, "seller IB total = 1P remaining (started 1.5P, lost 0.5P at dispute open)");
        uint256 sellerCapitalEnd = seller.balance + total; // wallet + IB
        uint256 saleReceipt = P - (P * FEE_BPS) / 10_000; // 0.995P (fee = 0.005P)
        assertEq(
            sellerCapitalEnd - sellerAbsoluteStart,
            saleReceipt + P / 2,
            "seller net capital delta = 0.995P sale + 0.5P dispute profit"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Test 4 — WTF: seller tries to close/reduce a listing while its slot is Disputed
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_4_disputeContinuesAfterListingClosed() public {
        vm.startPrank(seller);
        bond.deposit{value: (3 * P) / 2}();
        uint256 id = lm.createListing(P, 1, WINDOW, "", "");
        vm.stopPrank();

        vm.prank(buyer);
        settlement.pay{value: P}(id, 0);
        uint256 marketId = dm.marketIdOf(id, 0, _slotCycle(id, 0));

        vm.prank(buyer);
        dm.fundGuiltySide{value: P / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));

        // Seller attempts to reduce the disputed slot's capacity: reverts, no empty slots to reduce
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.InsufficientEmptySlots.selector, id, 1, 0));
        lm.reduceSlots(id, 1);

        // Seller closes listing — succeeds (no empty slots to release, just flips closed flag)
        vm.prank(seller);
        lm.closeListing(id);
        (,,,,,, bool closed) = lm.listings(id);
        assertTrue(closed, "listing closed");
        // Slot is still Disputed, untouched by closeListing
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));

        // The dispute market is fully independent of listing.closed. Others buy Guilty freely.
        vm.prank(funder1);
        market.buy{value: 5 ether}(marketId, SpectralMarket.Side.Guilty, 2 ether);
        vm.prank(funder2);
        market.buy{value: 5 ether}(marketId, SpectralMarket.Side.Guilty, 1 ether);
        (uint256 pG,) = market.currentPrice(marketId);
        assertGe(pG, 0.93e18, "market keeps trading despite closed listing");

        // Warp + poke → verdict lands normally
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(poker);
        conditions.pokeSettlement(marketId);
        (,,,,, bool resolved, SpectralMarket.Side winningSide) = market.markets(marketId);
        assertTrue(resolved);
        assertEq(uint8(winningSide), uint8(SpectralMarket.Side.Guilty));

        // finalizeDispute lands even though listing is closed — closed only affects new payments
        dm.finalizeDispute(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Removed));

        // Buyer restitution + redemption still work
        vm.prank(buyer);
        bond.claim();
        vm.prank(buyer);
        market.redeem(marketId);

        // Funder1/funder2 can redeem their Guilty positions (subject to LMSR pool cap)
        vm.prank(funder1);
        market.redeem(marketId);
        vm.prank(funder2);
        market.redeem(marketId);

        // Seller cannot resurrect this slot — creating new listing is required
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.ListingAlreadyClosed.selector, id));
        lm.reduceSlots(id, 0); // even count=0 reduce reverts on closed listing since closed check is early
    }

    function test_4b_reduceSlotsCannotTouchDisputedSlot() public {
        // Multi-slot listing: slot 0 disputed, slot 1 empty. reduceSlots(1) must only touch the empty one.
        vm.startPrank(seller);
        bond.deposit{value: 3 * P}();
        uint256 id = lm.createListing(P, 2, WINDOW, "", "");
        vm.stopPrank();

        vm.prank(buyer);
        settlement.pay{value: P}(id, 0);
        vm.prank(buyer);
        dm.fundGuiltySide{value: P / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));

        // Reduce 1: must touch slot 1 (Empty), not slot 0 (Disputed)
        vm.prank(seller);
        lm.reduceSlots(id, 1);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed), "slot 0 untouched");
        assertEq(uint256(_slotStatus(id, 1)), uint256(ListingManager.SlotStatus.Removed), "slot 1 released");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Test 5 — WTF: attempts to force-resolve a market before conditions are met
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_5_marketCannotResolveEarly() public {
        vm.startPrank(seller);
        bond.deposit{value: (3 * P) / 2}();
        uint256 id = lm.createListing(P, 1, WINDOW, "", "");
        vm.stopPrank();

        vm.prank(buyer);
        settlement.pay{value: P}(id, 0);
        uint256 marketId = dm.marketIdOf(id, 0, _slotCycle(id, 0));
        vm.prank(buyer);
        dm.fundGuiltySide{value: P / 2}(id, 0);

        // ── Attempt 1: finalizeDispute BEFORE market resolves → reverts MarketNotResolvedYet ──
        vm.prank(randomEOA);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.MarketNotResolvedYet.selector, marketId));
        dm.finalizeDispute(id, 0);

        // ── Attempt 2: pokeSettlement at 50/50 → nothing above 93%, ConditionsNotYetMet ──
        vm.prank(poker);
        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.ConditionsNotYetMet.selector, marketId));
        conditions.pokeSettlement(marketId);

        // ── Attempt 3: single large trade pushes price to 99% but does NOT resolve in the same tx ──
        vm.prank(funder1);
        market.buy{value: 50 ether}(marketId, SpectralMarket.Side.Guilty, 10 ether);
        (uint256 pG,) = market.currentPrice(marketId);
        assertGe(pG, 0.99e18, "price above 99% after single big trade");
        (,,,,, bool resolvedAfterBigTrade,) = market.markets(marketId);
        assertFalse(resolvedAfterBigTrade, "market NOT resolved by single trade regardless of price");

        // Poking immediately still fails — cumulative time is still ~0
        vm.prank(poker);
        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.ConditionsNotYetMet.selector, marketId));
        conditions.pokeSettlement(marketId);

        // ── Attempt 4: warp only 30 minutes above 93% — still not enough (needs 1 hour cumulative) ──
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(poker);
        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.ConditionsNotYetMet.selector, marketId));
        conditions.pokeSettlement(marketId);

        // ── Attempt 5: warp another 30 min + 1 second so total is 1h + 1s above 93% — NOW poke succeeds ──
        vm.warp(block.timestamp + 30 minutes + 1);
        vm.prank(poker);
        conditions.pokeSettlement(marketId);
        (,,,,, bool resolved,) = market.markets(marketId);
        assertTrue(resolved, "poke resolves market only after cumulative 1h above 93%");
    }

    function test_5b_priceDipsBelowThresholdPauses() public {
        // Verifies the "pauses, never resets" property: 30 min above → drop to NEUTRAL zone (both sides <93%)
        // → warp arbitrary time (no accumulation because trackedSideActive=false) → push Guilty back above →
        // only 30 more min needed to cross the 1-hour cumulative threshold
        vm.startPrank(seller);
        bond.deposit{value: (3 * P) / 2}();
        uint256 id = lm.createListing(P, 1, WINDOW, "", "");
        vm.stopPrank();

        vm.prank(buyer);
        settlement.pay{value: P}(id, 0);
        uint256 marketId = dm.marketIdOf(id, 0, _slotCycle(id, 0));
        vm.prank(buyer);
        dm.fundGuiltySide{value: P / 2}(id, 0);

        // Push Guilty above 93% — qG=4, qI=1 → pG≈0.953
        vm.prank(funder1);
        market.buy{value: 10 ether}(marketId, SpectralMarket.Side.Guilty, 3 ether);
        (uint256 pG,) = market.currentPrice(marketId);
        assertGe(pG, 0.93e18);

        // Accumulate 30 minutes above threshold
        vm.warp(block.timestamp + 30 minutes);

        // Drop to NEUTRAL zone (both sides <93%): 1 ether Innocent buy takes qI 1→2, giving pG≈0.881, pI≈0.119
        // This trade's checkpoint records the 30min elapsed (still tracking Guilty), then flips trackedSideActive
        // to false because neither post-trade price crosses 93%.
        vm.prank(funder2);
        market.buy{value: 5 ether}(marketId, SpectralMarket.Side.Innocent, 1 ether);
        (uint256 pG2, uint256 pI2) = market.currentPrice(marketId);
        assertLt(pG2, 0.93e18, "Guilty dropped below 93%");
        assertLt(pI2, 0.93e18, "Innocent stayed below 93% (neutral zone)");

        // Warp 1 hour in neutral zone — timer paused, nothing accumulates
        vm.warp(block.timestamp + 1 hours);
        vm.prank(poker);
        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.ConditionsNotYetMet.selector, marketId));
        conditions.pokeSettlement(marketId);

        // Push Guilty above 93% again — qG=7, qI=2 → pG≈0.993
        vm.prank(funder1);
        market.buy{value: 15 ether}(marketId, SpectralMarket.Side.Guilty, 3 ether);
        (uint256 pG3,) = market.currentPrice(marketId);
        assertGe(pG3, 0.93e18);

        // Only 30 min + 1s more needed — the earlier 30 min is preserved (pause = no reset)
        vm.warp(block.timestamp + 30 minutes + 1);
        vm.prank(poker);
        conditions.pokeSettlement(marketId);
        (,,,,, bool resolved,) = market.markets(marketId);
        assertTrue(resolved, "timer paused not reset - 30min + 30min = 1 hour resolves");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function _slotStatus(uint256 listingId, uint256 slotIndex) internal view returns (ListingManager.SlotStatus s) {
        (s,,,) = lm.slots(listingId, slotIndex);
    }

    function _slotCycle(uint256 listingId, uint256 slotIndex) internal view returns (uint256 c) {
        (,,, c) = lm.slots(listingId, slotIndex);
    }

    function _slotBuyerOf(uint256 listingId, uint256 slotIndex) internal view returns (address b) {
        (,, b,) = lm.slots(listingId, slotIndex);
    }
}
