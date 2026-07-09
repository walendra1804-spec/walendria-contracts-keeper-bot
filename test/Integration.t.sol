// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SD59x18, sd, UNIT} from "prb-math/SD59x18.sol";
import {IntegrityBond} from "../src/IntegrityBond.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {Settlement} from "../src/Settlement.sol";
import {SpectralMarket} from "../src/SpectralMarket.sol";
import {ISettlementConditionsHook} from "../src/ISettlementConditionsHook.sol";
import {SettlementConditions} from "../src/SettlementConditions.sol";
import {DisputeManager} from "../src/DisputeManager.sol";
import {DeveloperPool} from "../src/DeveloperPool.sol";

/// @notice Phase 8's "wire all modules into the full transaction -> dispute -> resolution -> payout lifecycle":
///         deploys the seven contracts that actually connect to one another (IntegrityBond, ListingManager,
///         Settlement, SpectralMarket, SettlementConditions, DisputeManager, DeveloperPool) with real
///         constructor wiring - no controller stand-ins, no disabled hooks - and drives realistic end-to-end
///         scenarios through them.
/// @dev SharedIB.sol is deliberately not part of this wiring: ListingManager's own Phase-3 scope decision means
///      it never calls SharedIB at all (direct-IB-only listings), so there is no live integration point to
///      exercise here - see DisputeManager.sol's own contract-level dev note for the full reasoning. SharedIB's
///      standalone mechanics already have their own dedicated test suite.
contract IntegrationTest is Test {
    IntegrityBond internal bond;
    ListingManager internal lm;
    Settlement internal settlement;
    SpectralMarket internal market;
    SettlementConditions internal conditions;
    DisputeManager internal dm;
    DeveloperPool internal devPool;

    address internal developer = makeAddr("developer");
    address internal withdrawalRecipient = makeAddr("withdrawalRecipient");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal backer = makeAddr("backer");

    uint256 internal constant WINDOW = 72 hours;
    uint256 internal constant POKE_BOUNTY_BPS = 10; // 0.1% of P (whitepaper Section 2.6.8 point 5)

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedLm = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedSpectralMarket = vm.computeCreateAddress(address(this), nonce + 4);
        address predictedSettlement = vm.computeCreateAddress(address(this), nonce + 5);
        address predictedDm = vm.computeCreateAddress(address(this), nonce + 6);

        address[] memory bondControllers = new address[](2);
        bondControllers[0] = predictedLm;
        bondControllers[1] = predictedDm;
        bond = new IntegrityBond(bondControllers);

        address[] memory lmControllers = new address[](2);
        lmControllers[0] = predictedSettlement;
        lmControllers[1] = predictedDm;
        lm = new ListingManager(bond, lmControllers, type(uint256).max);
        assertEq(address(lm), predictedLm, "CREATE nonce prediction drifted (lm)");

        devPool = new DeveloperPool(developer, withdrawalRecipient);

        conditions = new SettlementConditions(SpectralMarket(predictedSpectralMarket), POKE_BOUNTY_BPS);

        address[] memory marketControllers = new address[](2);
        marketControllers[0] = predictedDm;
        marketControllers[1] = address(conditions);
        market = new SpectralMarket(marketControllers, ISettlementConditionsHook(address(conditions)), address(devPool));
        assertEq(address(market), predictedSpectralMarket, "CREATE nonce prediction drifted (market)");

        settlement = new Settlement(lm, address(devPool));
        assertEq(address(settlement), predictedSettlement, "CREATE nonce prediction drifted (settlement)");

        dm = new DisputeManager(lm, bond, market);
        assertEq(address(dm), predictedDm, "CREATE nonce prediction drifted (dm)");

        vm.deal(seller, 10_000 ether);
        vm.deal(buyer, 10_000 ether);
        vm.deal(backer, 10_000 ether);
    }

    // ── Scenario: honest transaction, no dispute ──────────────────────────────────────────────────────────────

    function test_HonestTransactionNoDisputeFeeRoutesToDeveloperPoolAndCapitalFullyReturns() public {
        uint256 price = 2 ether;
        vm.prank(seller);
        bond.deposit{value: 3 ether}();
        vm.prank(seller);
        uint256 listingId = lm.createListing(price, 1, WINDOW);

        uint256 sellerBefore = seller.balance;
        vm.prank(buyer);
        settlement.pay{value: price}(listingId, 0);

        assertEq(seller.balance - sellerBefore, (price * 995) / 1000, "seller receives 0.995P proceeds");
        assertEq(address(devPool).balance, (price * 5) / 1000, "0.5% fee routed to DeveloperPool");

        vm.warp(block.timestamp + WINDOW);
        lm.finalizeExpiredSlot(listingId, 0);
        assertEq(bond.freeIB(seller), 0, "capital stays locked with no dispute - it still backs the slot's resale");

        vm.prank(seller);
        lm.reduceSlots(listingId, 1); // seller explicitly reclaims it instead of reselling
        assertEq(bond.freeIB(seller), 3 ether, "Locked IB fully released once the seller stops offering the slot");

        vm.prank(developer);
        devPool.withdraw(address(devPool).balance);
        assertEq(withdrawalRecipient.balance, (price * 5) / 1000);
    }

    // ── Scenario: disputed transaction, resolves Guilty via the cumulative price threshold ──────────────────

    function test_DisputedTransactionResolvesGuiltyViaPriceThresholdAndBuyerClaimsRestitution() public {
        uint256 price = 10 ether;
        uint256 listingId = _paidListing(price);
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: price / 2}(listingId, 0);
        (,,,, bool open,,) = market.markets(marketId);
        assertTrue(open, "threshold crossing must atomically open the market");

        // A separate trader (not buyer) pushes Guilty price past the 93% resolution threshold. This alone does
        // NOT resolve the market instantly, however far past 93% it goes (Section 2.6.5) - it only starts the
        // cumulative timer the checkpoint hook inside SpectralMarket.buy tracks. Deliberately not buyer
        // themselves: a single actor's own winning trade costs less than its eventual $1/share payout (Section
        // 2.6.9), and a large enough one can leave the pool under-collateralized for that same actor's redemption
        // - a real, documented LMSR bounded-loss property, not a bug, but not what this scenario is testing.
        // Keeping buyer's own redemption to just their original joint-injection share avoids exercising that
        // corner case here.
        address otherTrader = makeAddr("otherTrader");
        vm.deal(otherTrader, 100 ether);
        uint256 sharesToReach95 = _sharesToReachPrice(price, 0.95e18);
        vm.prank(otherTrader);
        market.buy{value: 100 ether}(marketId, SpectralMarket.Side.Guilty, sharesToReach95);

        (,,,,, bool resolvedInstantly,) = market.markets(marketId);
        assertFalse(resolvedInstantly, "no price, however high, resolves a case in the same transaction");

        // The cumulative 1-hour window (Section 2.6.5) must elapse, then a fresh checkpoint (any trade, or a
        // pokeSettlement call) observes it and resolves.
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(otherTrader);
        market.buy{value: 0.01 ether}(marketId, SpectralMarket.Side.Guilty, 1e9);

        (,,,,, bool resolved, SpectralMarket.Side winningSide) = market.markets(marketId);
        assertTrue(resolved, "the cumulative condition should have resolved the market");
        assertEq(uint8(winningSide), uint8(SpectralMarket.Side.Guilty));

        dm.finalizeDispute(listingId, 0);
        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Removed));

        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        bond.claim();
        // Restitution is the slot's *remaining* Locked IB (perSlotLocked - halfPrice = 1.5P - 0.5P = 1.0P),
        // not price - halfPrice's own (equal, but conceptually different) 0.5P value - both happen to be the
        // same number only because they're arithmetically identical for this even price.
        assertEq(buyer.balance - buyerBefore, price, "buyer receives the remaining 1.0P as restitution");

        vm.prank(buyer);
        uint256 payout = market.redeem(marketId);
        assertGt(payout, 0, "buyer's winning Guilty shares also redeem in full");
    }

    // ── Scenario: disputed transaction, resolves Innocent, seller's IB unlocks ────────────────────────────────

    function test_DisputedTransactionResolvesInnocentAndSellerIBUnlocks() public {
        uint256 price = 10 ether;
        uint256 listingId = _paidListing(price);
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(backer);
        dm.fundGuiltySide{value: price / 2}(listingId, 0);

        // Seller defends, pushing Innocent price past 93% (whether sale proceeds alone are *sufficient* for this
        // is a separate, already-covered adversarial property - see DisputeManager.t.sol's dedicated test). This
        // alone does not resolve instantly (Section 2.6.5); the cumulative 1-hour window must elapse first.
        uint256 sharesToReach95 = _sharesToReachPrice(price, 0.95e18);
        vm.prank(seller);
        market.buy{value: 100 ether}(marketId, SpectralMarket.Side.Innocent, sharesToReach95);

        (,,,,, bool resolvedInstantly,) = market.markets(marketId);
        assertFalse(resolvedInstantly, "no price, however high, resolves a case in the same transaction");

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(seller);
        market.buy{value: 0.01 ether}(marketId, SpectralMarket.Side.Innocent, 1e9);

        (,,,,, bool resolved, SpectralMarket.Side winningSide) = market.markets(marketId);
        assertTrue(resolved);
        assertEq(uint8(winningSide), uint8(SpectralMarket.Side.Innocent));

        uint256 sellerFreeBefore = bond.freeIB(seller);
        dm.finalizeDispute(listingId, 0);
        assertGt(bond.freeIB(seller), sellerFreeBefore, "the remaining 1.0P Locked IB unlocks back to Free IB");
        assertEq(bond.claimable(backer), 0, "no restitution on an Innocent verdict");
    }

    // ── Scenario: mutual close, no third party ever involved ─────────────────────────────────────────────────

    function test_DisputeResolvesViaMutualCloseWhenSolelyBuyerFunded() public {
        uint256 price = 10 ether;
        uint256 listingId = _paidListing(price);
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: price / 2}(listingId, 0);

        vm.prank(buyer);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
        vm.prank(seller);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);

        (,,,,, bool resolved,) = market.markets(marketId);
        assertTrue(resolved, "mutualClose should self-finalize inline");
        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Removed));
    }

    // ── Scenario: checkpoint-and-poke resolves a dispute with zero further trades ─────────────────────────────

    function test_DisputeResolvesViaPokeWithNoFurtherTradesAfterThresholdCrossed() public {
        uint256 price = 10 ether;
        uint256 listingId = _paidListing(price);
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: price / 2}(listingId, 0);
        uint256 sharesToReach94 = _sharesToReachPrice(price, 0.94e18); // crosses 93%
        vm.prank(buyer);
        market.buy{value: 100 ether}(marketId, SpectralMarket.Side.Guilty, sharesToReach94);

        vm.warp(block.timestamp + 1 hours + 1);

        // Guilty will win; the poke bounty is 0.1% of P, paid from the market surplus and capped at whatever
        // surplus exists. This scenario's only extra trade is the buyer's own winning-side buy, which by the
        // Boundary Theorem (Section 2.6.9) costs less than its eventual payout - so it adds no positive surplus,
        // and the bounty here is legitimately ~0. Resolution via poke must still succeed regardless (whitepaper
        // Section 2.6.8: liveness rests on the winner's own incentive, not on the bounty being payable).
        (, SD59x18 qGuiltyAtPoke,, uint256 pooledAtPoke,,,) = market.markets(marketId);
        uint256 obligation = uint256(SD59x18.unwrap(qGuiltyAtPoke));
        uint256 surplus = pooledAtPoke > obligation ? pooledAtPoke - obligation : 0;
        uint256 bounty = (price * POKE_BOUNTY_BPS) / 10_000;
        uint256 expectedPaid = bounty < surplus ? bounty : surplus;

        address poker = makeAddr("poker");
        uint256 pokerBefore = poker.balance;
        vm.prank(poker);
        conditions.pokeSettlement(marketId);

        (,,,,, bool resolved,) = market.markets(marketId);
        assertTrue(resolved, "the cumulative timer should resolve via the poke, with no further trades");
        assertEq(poker.balance - pokerBefore, expectedPaid, "poker earns min(0.1% of P, surplus) from the market");

        dm.finalizeDispute(listingId, 0);
    }

    // ── Scenario: resolution surplus sweeps to DeveloperPool ──────────────────────────────────────────────────

    /// @dev Deliberately does not push price to the 93% threshold via a winning-side trade: Section 2.6.9's
    ///      own theorem means any trade reaching that far always costs less than its eventual payout, which
    ///      *reduces* net surplus, not adds to it - reaching the security threshold is supposed to be expensive,
    ///      by design. Genuine positive surplus instead comes from a losing-side trade with no matching
    ///      winning-side cost - here, the seller themselves buying some Innocent shares "just in case" while
    ///      defending (Section 2.4), then the case turning out Guilty anyway via mutualClose. Seller buying their
    ///      own Innocent shares never disqualifies mutualClose (Section 2.6.10 only excludes third parties), so
    ///      this stays fully eligible throughout - and resolving via mutual agreement rather than a price
    ///      threshold means no second trade's discount ever gets stacked against the loss.
    function test_ResolutionSurplusSweepsToDeveloperPool() public {
        uint256 price = 10 ether;
        uint256 listingId = _paidListing(price);
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: price / 2}(listingId, 0);

        vm.prank(seller);
        uint256 sellerLosingCost = market.buy{value: 2 ether}(marketId, SpectralMarket.Side.Innocent, 1 ether);

        vm.prank(buyer);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Guilty);
        vm.prank(seller);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Guilty);

        (,,,,, bool resolved, SpectralMarket.Side winningSide) = market.markets(marketId);
        assertTrue(resolved);
        assertEq(uint8(winningSide), uint8(SpectralMarket.Side.Guilty));

        uint256 devBefore = address(devPool).balance;
        uint256 surplus = market.sweepSurplus(marketId);
        assertEq(surplus, sellerLosingCost, "the seller's own failed Innocent-side defense becomes pure surplus");
        assertEq(address(devPool).balance - devBefore, surplus);
    }

    /// @dev delta = b * ln(p / (1-p)): the share quantity that pushes one side's price from a symmetric 50/50
    ///      opening to `priceWad`, buying only that side - same derivation used in SettlementConditions.t.sol /
    ///      LMSRMathTest's H(p) table.
    function _sharesToReachPrice(uint256 bWad, uint256 priceWad) internal pure returns (uint256) {
        SD59x18 b = sd(int256(bWad));
        SD59x18 p = sd(int256(priceWad));
        SD59x18 delta = b * (p / (UNIT - p)).ln();
        return uint256(SD59x18.unwrap(delta));
    }

    function _marketId(uint256 listingId, uint256 slotIndex) internal view returns (uint256) {
        (,,, uint256 cycle) = lm.slots(listingId, slotIndex);
        return dm.marketIdOf(listingId, slotIndex, cycle);
    }

    function _paidListing(uint256 price) internal returns (uint256 listingId) {
        vm.prank(seller);
        bond.deposit{value: (price * 3 + 1)}();
        vm.prank(seller);
        listingId = lm.createListing(price, 1, WINDOW);
        vm.prank(buyer);
        settlement.pay{value: price}(listingId, 0);
    }
}
