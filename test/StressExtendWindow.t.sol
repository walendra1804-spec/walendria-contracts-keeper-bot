// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
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

/// @notice Stress test suite for the seller-initiated `extendWindow` feature (commit 2e45a94), covering the 50
///         items enumerated in the design session: input validation, state transitions & recycling, dispute
///         lifecycle interactions, race conditions, whitepaper consistency, overflow boundaries, isolation,
///         invariants, and end-to-end scenarios. Deploys the full seven-contract stack in setUp mirroring
///         Deploy.s.sol's CREATE-nonce prediction.
contract StressExtendWindow is Test {
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
    address internal otherSeller = makeAddr("otherSeller");
    address internal buyer = makeAddr("buyer");
    address internal buyer2 = makeAddr("buyer2");
    address internal funder1 = makeAddr("funder1");
    address internal funder2 = makeAddr("funder2");
    address internal randomEOA = makeAddr("random");

    uint256 internal constant PRICE = 1 ether;
    uint256 internal constant DEFAULT_WINDOW = 72 hours;
    uint256 internal constant HARDCAP = 100 ether;
    uint256 internal constant POKE_BOUNTY_BPS = 10;

    // Re-declared errors so expectRevert can reference them by selector.
    // (Foundry's `expectRevert(bytes4)` needs the selector value; using the type is cleanest.)
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
        require(address(lm) == predictedLm, "lm addr mismatch");

        devPool = new DeveloperPool(developer, withdrawalRecipient);
        conditions = new SettlementConditions(SpectralMarket(predictedMarket), POKE_BOUNTY_BPS);

        address[] memory mkCtrl = new address[](2);
        mkCtrl[0] = predictedDm;
        mkCtrl[1] = address(conditions);
        market = new SpectralMarket(mkCtrl, ISettlementConditionsHook(address(conditions)), address(devPool));
        require(address(market) == predictedMarket, "market addr mismatch");

        settlement = new Settlement(lm, address(devPool));
        require(address(settlement) == predictedSettlement, "settlement addr mismatch");

        dm = new DisputeManager(lm, bond, market);
        require(address(dm) == predictedDm, "dm addr mismatch");

        evidence = new EvidenceRegistry(lm);

        vm.deal(seller, 10_000 ether);
        vm.deal(otherSeller, 10_000 ether);
        vm.deal(buyer, 10_000 ether);
        vm.deal(buyer2, 10_000 ether);
        vm.deal(funder1, 10_000 ether);
        vm.deal(funder2, 10_000 ether);
        vm.deal(randomEOA, 10_000 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function _bondUp(address who, uint256 amt) internal {
        vm.prank(who);
        bond.deposit{value: amt}();
    }

    function _createListingAs(address who, uint256 price, uint256 slots, uint256 window) internal returns (uint256 id) {
        _bondUp(who, (price * 3 * slots) / 2 + 1);
        vm.prank(who);
        id = lm.createListing(price, slots, window, "", "");
    }

    function _pay(address who, uint256 listingId, uint256 slotIndex, uint256 price) internal {
        vm.prank(who);
        settlement.pay{value: price}(listingId, slotIndex);
    }

    function _slotStatus(uint256 listingId, uint256 slotIndex) internal view returns (ListingManager.SlotStatus s) {
        (s,,,) = lm.slots(listingId, slotIndex);
    }

    function _slotDeadline(uint256 listingId, uint256 slotIndex) internal view returns (uint256 d) {
        (, d,,) = lm.slots(listingId, slotIndex);
    }

    function _slotCycle(uint256 listingId, uint256 slotIndex) internal view returns (uint256 c) {
        (,,, c) = lm.slots(listingId, slotIndex);
    }

    function _slotBuyer(uint256 listingId, uint256 slotIndex) internal view returns (address b) {
        (,, b,) = lm.slots(listingId, slotIndex);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Section A — Core input validation (items 1–9)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_A1_nonSellerReverts() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        address[4] memory attackers = [buyer, funder1, randomEOA, otherSeller];
        for (uint256 i = 0; i < attackers.length; i++) {
            vm.prank(attackers[i]);
            vm.expectRevert(abi.encodeWithSelector(ListingManager.NotSeller.selector, attackers[i], seller));
            lm.extendWindow(id, 0, DEFAULT_WINDOW + 1);
        }
    }

    function test_A2_listingNotFound() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.ListingNotFound.selector, 999));
        lm.extendWindow(999, 0, DEFAULT_WINDOW + 1);
    }

    function test_A3_slotIndexOutOfRange() public {
        uint256 id = _createListingAs(seller, PRICE, 3, DEFAULT_WINDOW);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotIndexOutOfRange.selector, 3, 3));
        lm.extendWindow(id, 3, DEFAULT_WINDOW + 1);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotIndexOutOfRange.selector, 99, 3));
        lm.extendWindow(id, 99, DEFAULT_WINDOW + 1);
    }

    function test_A4_disputedRevertsSlotNotExtendable() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotExtendable.selector, id, 0));
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 100);
    }

    function test_A5_removedRevertsSlotNotExtendable() public {
        // via reduceSlots
        uint256 id = _createListingAs(seller, PRICE, 2, DEFAULT_WINDOW);
        vm.prank(seller);
        lm.reduceSlots(id, 1); // first empty slot goes Removed
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotExtendable.selector, id, 0));
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 1);

        // via resolveDispute path — pay slot 1, dispute, resolve
        _pay(buyer, id, 1, PRICE);
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 1);
        // Resolve via mutualClose (buyer + seller agree Innocent to make the market winner Innocent)
        vm.prank(buyer);
        dm.mutualClose(id, 1, SpectralMarket.Side.Innocent);
        vm.prank(seller);
        dm.mutualClose(id, 1, SpectralMarket.Side.Innocent);
        assertEq(uint256(_slotStatus(id, 1)), uint256(ListingManager.SlotStatus.Removed));
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotExtendable.selector, id, 1));
        lm.extendWindow(id, 1, DEFAULT_WINDOW + 1);
    }

    function test_A6_equalToCurrentReverts() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(ListingManager.WindowNotExtended.selector, DEFAULT_WINDOW, DEFAULT_WINDOW)
        );
        lm.extendWindow(id, 0, DEFAULT_WINDOW);
    }

    function test_A7_smallerThanCurrentReverts() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW * 2);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(ListingManager.WindowNotExtended.selector, DEFAULT_WINDOW + 1, DEFAULT_WINDOW * 2)
        );
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 1);
    }

    function test_A8_belowMinFloorReverts() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW * 2);
        // Try newWindow < MIN_COMPLETION_WINDOW (72h). WindowNotExtended vs CompletionWindowTooShort — 72h-1 is
        // below MIN so CompletionWindowTooShort fires first, matching the explicit floor check order.
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(ListingManager.CompletionWindowTooShort.selector, DEFAULT_WINDOW - 1, DEFAULT_WINDOW)
        );
        lm.extendWindow(id, 0, DEFAULT_WINDOW - 1);
    }

    function test_A9_eventEmittedCorrectlyBothStates() public {
        uint256 id = _createListingAs(seller, PRICE, 2, DEFAULT_WINDOW);

        // Empty slot: expected deadline = 0
        vm.expectEmit(true, true, false, true, address(lm));
        emit ListingManager.SlotWindowExtended(id, 0, DEFAULT_WINDOW + 100, 0, 0);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 100);

        // PaymentConfirmed slot
        _pay(buyer, id, 1, PRICE);
        uint256 paidAt = block.timestamp;
        uint256 newWin = DEFAULT_WINDOW + 500;
        vm.expectEmit(true, true, false, true, address(lm));
        emit ListingManager.SlotWindowExtended(id, 1, newWin, paidAt + newWin, 1);
        vm.prank(seller);
        lm.extendWindow(id, 1, newWin);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Section B — State transition & recycling (items 10–14)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_B10_emptyExtendThenPayDeadlineUsesOverride() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        uint256 newWin = DEFAULT_WINDOW + 5 hours;
        vm.prank(seller);
        lm.extendWindow(id, 0, newWin);

        uint256 paidAt = block.timestamp;
        _pay(buyer, id, 0, PRICE);
        assertEq(_slotDeadline(id, 0), paidAt + newWin, "deadline uses override, not listing default");
    }

    function test_B11_confirmCompletionResetsOverride() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 1 hours);
        assertEq(lm.slotWindowOverride(id, 0), DEFAULT_WINDOW + 1 hours, "override set");

        vm.prank(buyer);
        lm.confirmCompletion(id, 0);
        assertEq(lm.slotWindowOverride(id, 0), 0, "override reset on early completion");

        // Next buyer pays same slot; deadline uses listing default
        uint256 paidAt2 = block.timestamp;
        _pay(buyer2, id, 0, PRICE);
        assertEq(_slotDeadline(id, 0), paidAt2 + DEFAULT_WINDOW, "cycle 2 uses listing default");
        assertEq(_slotCycle(id, 0), 2, "cycle bumped to 2");
    }

    function test_B12_finalizeExpiredResetsOverride() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 3 hours);
        uint256 deadline = _slotDeadline(id, 0);
        vm.warp(deadline + 1);
        lm.finalizeExpiredSlot(id, 0);
        assertEq(lm.slotWindowOverride(id, 0), 0, "override reset on window-expiry finalize");

        uint256 paidAt2 = block.timestamp;
        _pay(buyer2, id, 0, PRICE);
        assertEq(_slotDeadline(id, 0), paidAt2 + DEFAULT_WINDOW, "next cycle uses listing default");
    }

    function test_B13_preExtendThenReduceRemoved() public {
        uint256 id = _createListingAs(seller, PRICE, 2, DEFAULT_WINDOW);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 1 hours);
        // override lingers in mapping but slot Removed by reduceSlots
        vm.prank(seller);
        lm.reduceSlots(id, 1);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Removed));

        // extendWindow reverts SlotNotExtendable, override value is now inert / harmless
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotExtendable.selector, id, 0));
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 5 hours);
    }

    function test_B14_extendAfterCloseListingOnConfirmedSlot() public {
        uint256 id = _createListingAs(seller, PRICE, 2, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(seller);
        lm.closeListing(id); // slot 0 stays PaymentConfirmed; slot 1 goes Removed

        // Confirmed slot still extendable — closeListing does not affect existing sales
        uint256 paidAt = block.timestamp;
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 100);
        assertEq(_slotDeadline(id, 0), paidAt + DEFAULT_WINDOW + 100, "extended even on closed listing");

        // Removed slot rejects extend
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotExtendable.selector, id, 1));
        lm.extendWindow(id, 1, DEFAULT_WINDOW + 100);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Section C — Dispute lifecycle interaction (items 15–21)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_C15_fundGuiltyPastOriginalDeadlineWithinExtension() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        uint256 originalDeadline = _slotDeadline(id, 0);

        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 48 hours);
        uint256 newDeadline = _slotDeadline(id, 0);
        assertGt(newDeadline, originalDeadline, "deadline moved out");

        // Warp past original deadline but within extended
        vm.warp(originalDeadline + 30 minutes);
        assertLt(block.timestamp, newDeadline);
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));
    }

    function test_C16_fundGuiltyExactlyAtNewDeadlineMinusOne() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 10);
        uint256 dl = _slotDeadline(id, 0);

        // At `dl - 1`, block.timestamp < dl → allowed
        vm.warp(dl - 1);
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));
    }

    function test_C17_fundGuiltyExactlyAtNewDeadlineReverts() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 10);
        uint256 dl = _slotDeadline(id, 0);

        vm.warp(dl); // `block.timestamp >= completionDeadline` in DisputeManager
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.WindowExpired.selector, id, 0, dl));
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
    }

    function test_C18_extendWithPartialFundingIntact() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(funder1);
        dm.fundGuiltySide{value: PRICE / 4}(id, 0);
        uint256 cycle = _slotCycle(id, 0);
        uint256 mid = dm.marketIdOf(id, 0, cycle);
        assertEq(dm.guiltyFundingTotal(mid), PRICE / 4, "partial funding recorded");

        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 1 hours);
        assertEq(dm.guiltyFundingTotal(mid), PRICE / 4, "partial funding untouched by extend");
        assertEq(dm.guiltyContributionOf(mid, funder1), PRICE / 4, "individual contribution untouched");
    }

    function test_C19_extendWithFundingCrossingThenExtendAgainDisputedReverts() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 100);
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotExtendable.selector, id, 0));
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 1000);
    }

    function test_C20_extendAfterResolveDisputeGuiltyReverts() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        vm.prank(buyer);
        dm.mutualClose(id, 0, SpectralMarket.Side.Guilty);
        vm.prank(seller);
        dm.mutualClose(id, 0, SpectralMarket.Side.Guilty);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Removed));

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotExtendable.selector, id, 0));
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 1 hours);
    }

    function test_C21_extendOnDisputedDoesNotAffectSpectralState() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        uint256 mid = dm.marketIdOf(id, 0, _slotCycle(id, 0));
        (, SD59x18 qG, SD59x18 qI, uint256 pooled,,,) = market.markets(mid);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotExtendable.selector, id, 0));
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 100);

        (, SD59x18 qG2, SD59x18 qI2, uint256 pooled2,,,) = market.markets(mid);
        assertEq(SD59x18.unwrap(qG), SD59x18.unwrap(qG2), "qGuilty unchanged");
        assertEq(SD59x18.unwrap(qI), SD59x18.unwrap(qI2), "qInnocent unchanged");
        assertEq(pooled, pooled2, "pooled unchanged");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Section D — Race conditions (items 22–26)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_D22a_extendBeforeFinalizeWinsBuyerFavorable() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        uint256 originalDl = _slotDeadline(id, 0);
        vm.warp(originalDl + 1);
        // Ordering 1: extend runs first
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 24 hours);
        // Now finalize would revert since deadline moved past current timestamp
        vm.expectRevert(
            abi.encodeWithSelector(ListingManager.WindowNotYetExpired.selector, id, 0, _slotDeadline(id, 0))
        );
        lm.finalizeExpiredSlot(id, 0);
    }

    function test_D22b_finalizeBeforeExtendWinsSellerLoses() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        uint256 dl = _slotDeadline(id, 0);
        vm.warp(dl + 1);
        // Ordering 2: finalize runs first, slot goes Empty
        lm.finalizeExpiredSlot(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Empty));
        // extend on now-Empty slot succeeds (pre-arranging for next buyer) — still valid
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 24 hours);
        assertEq(lm.slotWindowOverride(id, 0), DEFAULT_WINDOW + 24 hours);
    }

    function test_D23_extendThenFundGuiltyInSameBlock() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        uint256 dl = _slotDeadline(id, 0);
        vm.warp(dl - 1); // exactly at the last moment of the original window
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 10);
        // Same block, funding lands using extended deadline
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));
    }

    function test_D24_fundGuiltyExpiredThenExtendMustRetry() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        uint256 dl = _slotDeadline(id, 0);
        vm.warp(dl + 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.WindowExpired.selector, id, 0, dl));
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        // Extend after failure
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 10);
        // Retry succeeds
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));
    }

    function test_D25_extendVsBuyerConfirmCompletion() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        // Both possible orderings
        // 25a: extend then confirmCompletion → override cleared
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 5 hours);
        vm.prank(buyer);
        lm.confirmCompletion(id, 0);
        assertEq(lm.slotWindowOverride(id, 0), 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Empty));

        // 25b: same slot, buyer 2 pays, buyer confirms without extend
        _pay(buyer2, id, 0, PRICE);
        vm.prank(buyer2);
        lm.confirmCompletion(id, 0);
        assertEq(_slotCycle(id, 0), 2);
    }

    function test_D26_multipleExtendsInSameBlockLatestWins() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        uint256 paidAt = block.timestamp;
        vm.startPrank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 100);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 500);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 1000);
        vm.stopPrank();
        assertEq(lm.slotWindowOverride(id, 0), DEFAULT_WINDOW + 1000);
        assertEq(_slotDeadline(id, 0), paidAt + DEFAULT_WINDOW + 1000);
        // Now a smaller-than-current extend reverts
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ListingManager.WindowNotExtended.selector, DEFAULT_WINDOW + 500, DEFAULT_WINDOW + 1000
            )
        );
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 500);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Section E — Whitepaper & bond consistency (items 27–31)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_E27_ibAccountingUnchangedByExtend() public {
        uint256 id = _createListingAs(seller, PRICE, 3, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        (uint256 total0, uint256 locked0) = bond.bonds(seller);

        vm.startPrank(seller);
        for (uint256 i = 0; i < 5; i++) {
            lm.extendWindow(id, 0, DEFAULT_WINDOW + (i + 1) * 1 hours);
        }
        lm.extendWindow(id, 1, DEFAULT_WINDOW + 30 days); // pre-extend empty
        lm.extendWindow(id, 2, DEFAULT_WINDOW * 10); // pre-extend empty
        vm.stopPrank();

        (uint256 total1, uint256 locked1) = bond.bonds(seller);
        assertEq(total0, total1, "IB total unchanged");
        assertEq(locked0, locked1, "IB locked unchanged");
    }

    function test_E28_totalLockedNeverExceedsTotalIB() public {
        _bondUp(seller, 100 ether);
        vm.prank(seller);
        uint256 id = lm.createListing(PRICE, 5, DEFAULT_WINDOW, "", "");
        // Ratchet extends across all slots — total locked should stay = 5 * 1.5P = 7.5 ETH
        vm.startPrank(seller);
        for (uint256 s = 0; s < 5; s++) {
            lm.extendWindow(id, s, DEFAULT_WINDOW + 1 days);
            lm.extendWindow(id, s, DEFAULT_WINDOW + 2 days);
            lm.extendWindow(id, s, DEFAULT_WINDOW + 3 days);
        }
        vm.stopPrank();
        (uint256 total, uint256 locked) = bond.bonds(seller);
        assertEq(locked, (PRICE * 3 * 5) / 2);
        assertLe(locked, total);
    }

    function test_E29_disputeIbDrawUnaffectedByExtension() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 24 hours);

        (, uint256 lockedBefore) = bond.bonds(seller);
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        (, uint256 lockedAfter) = bond.bonds(seller);
        assertEq(lockedBefore - lockedAfter, PRICE / 2, "exactly 0.5P drawn by dispute open");

        // remaining locked = 1.5P - 0.5P = 1.0P
        assertEq(lockedAfter, PRICE);
    }

    function test_E30_noUpperCapOnExtensionMagnitude() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.startPrank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 7 days);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 30 days);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 365 days);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 100 * 365 days);
        vm.stopPrank();
        assertEq(lm.slotWindowOverride(id, 0), DEFAULT_WINDOW + 100 * 365 days);
    }

    function test_E31_minCompletionWindowIsConstant() public view {
        assertEq(lm.MIN_COMPLETION_WINDOW(), 72 hours);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Section F — Overflow / boundary (items 32–35)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_F32_maxUintOnPaymentConfirmedOverflows() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        // completionDeadline += (type(uint256).max - DEFAULT_WINDOW) overflows uint256 → panic 0x11
        vm.prank(seller);
        vm.expectRevert(); // arithmetic panic (0x11)
        lm.extendWindow(id, 0, type(uint256).max);
    }

    function test_F33_maxUintOnEmptySucceedsButPaymentOverflows() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        vm.prank(seller);
        lm.extendWindow(id, 0, type(uint256).max);
        assertEq(lm.slotWindowOverride(id, 0), type(uint256).max);
        // Payment attempts `block.timestamp + type(uint256).max` → overflow → revert
        vm.prank(buyer);
        vm.expectRevert();
        settlement.pay{value: PRICE}(id, 0);
    }

    function test_F34_smallestValidDelta() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        uint256 paidAt = block.timestamp;
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 1);
        assertEq(_slotDeadline(id, 0), paidAt + DEFAULT_WINDOW + 1);
    }

    function test_F35_repeatedExtendsGasConstant() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.startPrank(seller);
        uint256 g0 = gasleft();
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 1);
        uint256 firstCost = g0 - gasleft();
        uint256 g1 = gasleft();
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 500);
        uint256 secondCost = g1 - gasleft();
        vm.stopPrank();
        // Second call reuses hot storage → cheaper, never more expensive
        assertLe(secondCost, firstCost + 5000, "gas roughly constant (allowing warm-vs-cold margin)");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Section G — Isolation (items 36–38)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_G36_multiSlotOverridesAreIndependent() public {
        uint256 id = _createListingAs(seller, PRICE, 3, DEFAULT_WINDOW);
        vm.startPrank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 100);
        lm.extendWindow(id, 2, DEFAULT_WINDOW + 500);
        vm.stopPrank();
        assertEq(lm.slotWindowOverride(id, 0), DEFAULT_WINDOW + 100);
        assertEq(lm.slotWindowOverride(id, 1), 0);
        assertEq(lm.slotWindowOverride(id, 2), DEFAULT_WINDOW + 500);

        // Pay slot 1, deadline uses listing default
        uint256 paidAt = block.timestamp;
        _pay(buyer, id, 1, PRICE);
        assertEq(_slotDeadline(id, 1), paidAt + DEFAULT_WINDOW);
    }

    function test_G37_multiListingSlotIndexIsolation() public {
        uint256 idA = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        uint256 idB = _createListingAs(otherSeller, PRICE, 1, DEFAULT_WINDOW);
        assertTrue(idA != idB);

        vm.prank(seller);
        lm.extendWindow(idA, 0, DEFAULT_WINDOW + 999);
        assertEq(lm.slotWindowOverride(idA, 0), DEFAULT_WINDOW + 999);
        assertEq(lm.slotWindowOverride(idB, 0), 0, "no bleed to other listing");

        // Pay listing B slot 0, uses B's listing default (unchanged)
        uint256 paidAt = block.timestamp;
        _pay(buyer, idB, 0, PRICE);
        assertEq(_slotDeadline(idB, 0), paidAt + DEFAULT_WINDOW);
    }

    function test_G38_nextListingIdAlwaysMonotonic() public {
        uint256 a = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        uint256 b = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        uint256 c = _createListingAs(otherSeller, PRICE, 1, DEFAULT_WINDOW);
        assertEq(b, a + 1);
        assertEq(c, b + 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Section H — Simple invariant asserts (items 39–41; full fuzz added separately)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_H39_deadlineEqualsPaymentTimePlusEffectiveWindow() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        uint256 paidAt = block.timestamp;
        _pay(buyer, id, 0, PRICE);
        assertEq(_slotDeadline(id, 0), paidAt + DEFAULT_WINDOW);

        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 42);
        assertEq(_slotDeadline(id, 0), paidAt + DEFAULT_WINDOW + 42);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 100);
        // paymentTime unchanged; deadline reflects latest override
        assertEq(_slotDeadline(id, 0), paidAt + DEFAULT_WINDOW + 100);
    }

    function test_H40_overrideEitherZeroOrGeqMin() public {
        uint256 id = _createListingAs(seller, PRICE, 3, DEFAULT_WINDOW);
        // Slot 0 never extended
        assertEq(lm.slotWindowOverride(id, 0), 0);
        // Slot 1 extended
        vm.prank(seller);
        lm.extendWindow(id, 1, DEFAULT_WINDOW + 1);
        uint256 o1 = lm.slotWindowOverride(id, 1);
        assertTrue(o1 == 0 || o1 >= lm.MIN_COMPLETION_WINDOW());
        // Slot 2 pay + extend + finalize → override should reset to 0
        _pay(buyer, id, 2, PRICE);
        vm.prank(seller);
        lm.extendWindow(id, 2, DEFAULT_WINDOW + 100);
        vm.warp(_slotDeadline(id, 2) + 1);
        lm.finalizeExpiredSlot(id, 2);
        assertEq(lm.slotWindowOverride(id, 2), 0);
    }

    function test_H41_overrideZeroAfterAllRecyclePaths() public {
        uint256 id = _createListingAs(seller, PRICE, 2, DEFAULT_WINDOW);
        // Path 1: confirmCompletion
        _pay(buyer, id, 0, PRICE);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 10);
        vm.prank(buyer);
        lm.confirmCompletion(id, 0);
        assertEq(lm.slotWindowOverride(id, 0), 0);
        // Path 2: finalizeExpiredSlot
        _pay(buyer2, id, 1, PRICE);
        vm.prank(seller);
        lm.extendWindow(id, 1, DEFAULT_WINDOW + 20);
        vm.warp(_slotDeadline(id, 1) + 1);
        lm.finalizeExpiredSlot(id, 1);
        assertEq(lm.slotWindowOverride(id, 1), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Section I — End-to-end scenarios (items 43–47)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_I43_lateShipmentCourtesyExtension() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.warp(block.timestamp + 40 hours);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 96 hours);
        vm.warp(block.timestamp + 80 hours);
        vm.prank(buyer);
        lm.confirmCompletion(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Empty));

        // Bond still fully locked — slot ready for resale
        (uint256 total, uint256 locked) = bond.bonds(seller);
        assertEq(locked, (PRICE * 3) / 2, "IB still backs the recycled slot");
        assertEq(total, locked + bond.freeIB(seller));
    }

    function test_I44_lastMinuteDisputeAfterOriginalDeadline() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        uint256 originalDl = _slotDeadline(id, 0);
        vm.warp(originalDl - 2 hours);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 168 hours);
        vm.warp(originalDl + 100 hours);
        assertLt(block.timestamp, _slotDeadline(id, 0));
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        // mutual close Guilty
        vm.prank(buyer);
        dm.mutualClose(id, 0, SpectralMarket.Side.Guilty);
        vm.prank(seller);
        dm.mutualClose(id, 0, SpectralMarket.Side.Guilty);
        // Buyer claims restitution (1.0P)
        uint256 balBefore = buyer.balance;
        vm.prank(buyer);
        bond.claim();
        assertEq(buyer.balance - balBefore, PRICE, "restitution 1.0P paid to buyer");
    }

    function test_I45_sellerCannotShortenViaExtend() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 240 hours);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ListingManager.WindowNotExtended.selector, DEFAULT_WINDOW, DEFAULT_WINDOW + 240 hours
            )
        );
        lm.extendWindow(id, 0, DEFAULT_WINDOW);
    }

    function test_I46_griefFinalizeRaceStillDeterministic() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        uint256 dl = _slotDeadline(id, 0);
        // Anyone tries to finalize before deadline: reverts
        vm.warp(dl - 1);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.WindowNotYetExpired.selector, id, 0, dl));
        vm.prank(randomEOA);
        lm.finalizeExpiredSlot(id, 0);
        // Buyer disputes just before deadline
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));
        // Now attacker's finalize reverts SlotNotPaymentConfirmed
        vm.warp(dl + 100);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotPaymentConfirmed.selector, id, 0));
        lm.finalizeExpiredSlot(id, 0);
    }

    function test_I47_threeCycleLifecycle() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);

        // Cycle 1: pay + extend + confirmCompletion
        _pay(buyer, id, 0, PRICE);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 3 hours);
        vm.prank(buyer);
        lm.confirmCompletion(id, 0);
        assertEq(_slotCycle(id, 0), 1);
        assertEq(lm.slotWindowOverride(id, 0), 0, "override cleared after cycle 1");

        // Cycle 2: pay + no extend + finalize
        uint256 paidAt2 = block.timestamp;
        _pay(buyer2, id, 0, PRICE);
        assertEq(_slotDeadline(id, 0), paidAt2 + DEFAULT_WINDOW, "cycle 2 uses default");
        vm.warp(block.timestamp + DEFAULT_WINDOW + 1);
        lm.finalizeExpiredSlot(id, 0);
        assertEq(_slotCycle(id, 0), 2);

        // Cycle 3: pay + dispute (opens with default window)
        _pay(buyer, id, 0, PRICE);
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));
        assertEq(_slotCycle(id, 0), 3);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // Section J — Cross-contract read consistency (items 48–49)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_J48_disputeManagerSeesUpdatedDeadline() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        uint256 originalDl = _slotDeadline(id, 0);
        vm.warp(originalDl + 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.WindowExpired.selector, id, 0, originalDl));
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        // Extend, retry — DisputeManager reads live slots so must see new deadline
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 24 hours);
        vm.prank(buyer);
        dm.fundGuiltySide{value: PRICE / 2}(id, 0);
        assertEq(uint256(_slotStatus(id, 0)), uint256(ListingManager.SlotStatus.Disputed));
    }

    function test_J49_evidenceRegistryUnaffectedByExtend() public {
        uint256 id = _createListingAs(seller, PRICE, 1, DEFAULT_WINDOW);
        _pay(buyer, id, 0, PRICE);
        vm.prank(seller);
        lm.extendWindow(id, 0, DEFAULT_WINDOW + 24 hours);
        // Buyer submits evidence — should work regardless of deadline
        vm.prank(buyer);
        evidence.submitEvidence(id, 0, "QmSomeCID");
        // Even past original deadline
        vm.warp(_slotDeadline(id, 0) - 1 hours);
        vm.prank(seller);
        evidence.submitEvidence(id, 0, "QmAnotherCID");
        // Non-buyer/seller reverts
        vm.prank(randomEOA);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotBuyerOrSeller.selector, id, 0, randomEOA));
        evidence.submitEvidence(id, 0, "QmBad");
    }
}
