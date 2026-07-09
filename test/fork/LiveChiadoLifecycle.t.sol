// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {SD59x18} from "prb-math/SD59x18.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {Settlement} from "../../src/Settlement.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {SettlementConditions} from "../../src/SettlementConditions.sol";
import {DisputeManager} from "../../src/DisputeManager.sol";

/// @notice Fork test against the *actual deployed bytecode* of the current live Chiado deployment (the redeploy that
///         shipped this session's capped-`redeem`, surplus-sourced bounty, and per-tx hardcap). Unlike the local
///         unit/invariant suite - which tests the source in this repo - this pins those same source contracts to
///         their on-chain addresses via a fork, so a green run is direct evidence that the code running on Chiado
///         behaves as intended, not just the code sitting in the working tree. It reaches states impractical to
///         reach on the live network inside one session: the 1-hour cumulative poke-settlement gate (via vm.warp)
///         and a genuine LMSR bounded-loss shortfall driving {SpectralMarket-redeem}'s payout cap.
///
///         Two lifecycles, each on its own listing/slot:
///           A) create -> pay -> fund-guilty -> push Guilty >=93% -> (poke too early reverts) -> warp 1h -> poke
///              resolves Guilty -> finalizeDispute -> the winning holder redeems against a pool that is now short
///              of the full obligation (bounded loss), and gets the *capped* payout with no revert. This is the
///              exact live incident that bricked redeem before the fix; here it must succeed on the deployed code.
///           B) create -> pay -> fund-guilty -> push Guilty >=93% -> buyer+seller mutualClose(Innocent) -> the
///              Innocent winner redeems in full (pool amply covers the small innocent obligation) -> the leftover
///              surplus sweeps to the Developer Pool.
///
/// @dev Skips itself (no assertions, early return) when no Chiado fork can be created - so a plain `forge test`
///      with no network access neither fails nor silently pretends to have verified anything. Run explicitly with:
///      forge test --match-path test/fork/LiveChiadoLifecycle.t.sol -vv
contract LiveChiadoLifecycleForkTest is Test {
    // Live Chiado addresses (checksummed) from broadcast/Deploy.s.sol/10200/run-latest.json - the same set wired
    // into walendria-app/src/lib/contracts.ts and keeper-bot/src/config.js.
    IntegrityBond internal constant integrityBond = IntegrityBond(0x71fFAd99B5E5871F944f9525b44C8d4598F28e6D);
    ListingManager internal constant listingManager = ListingManager(0xEA53f63Ab55bF408783F20d8A0B50c89F23F5546);
    Settlement internal constant settlement = Settlement(0xa7Bd77A6D2D00C76d83Ff8D062e5072BBAdB008A);
    SpectralMarket internal constant spectralMarket = SpectralMarket(0x80B4bf7D5B9A638f11396Ba22c922d8C42Cc6f18);
    SettlementConditions internal constant settlementConditions =
        SettlementConditions(0xE71a192F22E30502BeAf7Ef9Aa33EB62F59cCef9);
    DisputeManager internal constant disputeManager =
        DisputeManager(payable(0x5CC6eB104c5967DB2DFCDcba9306D7075C56A7e4));

    uint256 internal constant P = 1_000_000; // wei - the same tiny scale prior live testing used on this deployment
    uint256 internal constant COMPLETION_WINDOW = 72 hours; // ListingManager.MIN_COMPLETION_WINDOW, exercised exactly

    bool internal forked;

    function setUp() public {
        // try/catch around the fork creation so a networkless environment skips rather than hard-fails.
        try vm.createSelectFork("chiado") returns (uint256) {
            forked = true;
        } catch {
            forked = false;
        }
    }

    // ── Scenario A: poke-settlement liveness + capped redeem on a bounded-loss shortfall ──

    function test_Fork_PokeResolvesGuiltyThenRedeemCapsPayoutOnShortfall() public {
        if (!forked) {
            console.log("SKIP: no Chiado fork available");
            return;
        }

        address seller = makeAddr("fork-A-seller");
        address buyer = makeAddr("fork-A-buyer");
        (uint256 listingId, uint256 marketId) = _openDisputeAndPushGuilty(seller, buyer);

        // Poking before the cumulative hour has elapsed must revert - the liveness gate, not an instant switch.
        address poker = makeAddr("fork-A-poker");
        vm.deal(poker, 1 ether);
        vm.prank(poker);
        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.ConditionsNotYetMet.selector, marketId));
        settlementConditions.pokeSettlement(marketId);

        // Let the full cumulative hour pass, then poke: resolves in favor of the >=93% (Guilty) side.
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 pokerBefore = poker.balance;
        vm.prank(poker);
        settlementConditions.pokeSettlement(marketId);

        assertTrue(_resolved(marketId), "poke after 1h should resolve the market");
        assertEq(uint256(_winner(marketId)), uint256(SpectralMarket.Side.Guilty), "the >=93% side must win the poke");
        // A quiet/underwater dispute leaves no surplus, so the poke bounty is ~0 - by design (Section 2.6.8).
        assertEq(poker.balance - pokerBefore, 0, "underwater poke pays no bounty (no surplus to draw from)");

        // finalizeDispute applies the post-resolution IB consequence (Guilty: 1P restitution slash to the buyer).
        disputeManager.finalizeDispute(listingId, 0);
        (, bool finalized) = disputeManager.disputes(marketId);
        assertTrue(finalized, "dispute should finalize after resolution");

        _assertCappedRedeem(marketId, buyer);
    }

    /// @dev The redeem that used to brick: the buyer holds more winning shares than the pool can cover, so the
    ///      fixed {SpectralMarket-redeem} must pay out exactly the pool balance (capped) and fully extinguish the
    ///      claim, rather than reverting on an arithmetic underflow and stranding the whole claim forever.
    function _assertCappedRedeem(uint256 marketId, address buyer) internal {
        uint256 pooledAtResolve = _pooled(marketId);
        uint256 buyerShares = spectralMarket.sharesOf(marketId, SpectralMarket.Side.Guilty, buyer);
        assertGt(buyerShares, pooledAtResolve, "buyer's claim exceeds the pool - the exact live shortfall condition");

        uint256 buyerEthBefore = buyer.balance;
        vm.prank(buyer);
        uint256 payout = spectralMarket.redeem(marketId);

        assertEq(payout, pooledAtResolve, "payout is capped at whatever the pool held, not reverted to zero");
        assertEq(buyer.balance - buyerEthBefore, payout, "buyer actually receives the capped payout");
        assertEq(spectralMarket.sharesOf(marketId, SpectralMarket.Side.Guilty, buyer), 0, "claim fully extinguished");
        assertEq(_pooled(marketId), 0, "pool fully drawn down by the capped redemption");

        // Second redeem finds nothing left - the claim is gone, not stuck behind a revert.
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.NothingToRedeem.selector, buyer));
        spectralMarket.redeem(marketId);

        console.log("A: capped redeem OK. obligation=%s pooled=%s payout=%s", buyerShares, pooledAtResolve, payout);
    }

    // ── Scenario B: mutualClose resolution + full (uncapped) redeem + surplus sweep ──

    function test_Fork_MutualCloseInnocentThenFullRedeemAndSurplusSweep() public {
        if (!forked) {
            console.log("SKIP: no Chiado fork available");
            return;
        }

        address seller = makeAddr("fork-B-seller");
        address buyer = makeAddr("fork-B-buyer");
        (uint256 listingId, uint256 marketId) = _openDisputeAndPushGuilty(seller, buyer);

        // Both parties agree the seller was Innocent -> instant resolution, no price threshold or wait needed.
        // Buyer is the sole Guilty holder and seller the sole Innocent holder, so the no-third-party gate passes.
        vm.prank(buyer);
        disputeManager.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
        vm.prank(seller);
        disputeManager.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);

        assertTrue(_resolved(marketId), "mutualClose with only buyer+seller as holders should resolve");
        assertEq(uint256(_winner(marketId)), uint256(SpectralMarket.Side.Innocent), "resolved to the agreed verdict");

        // Innocent obligation is small (only the seller's opening shares); the pool is large from the Guilty buy,
        // so this redeem is fully covered - no cap - and a real surplus remains to sweep.
        uint256 sellerShares = spectralMarket.sharesOf(marketId, SpectralMarket.Side.Innocent, seller);
        assertLt(sellerShares, _pooled(marketId), "pool should comfortably cover the innocent obligation here");

        uint256 sellerEthBefore = seller.balance;
        vm.prank(seller);
        uint256 payout = spectralMarket.redeem(marketId);
        assertEq(payout, sellerShares, "innocent winner redeems every share 1:1 - not capped");
        assertEq(seller.balance - sellerEthBefore, payout, "seller receives the full payout");

        // Surplus (pool minus the now-settled winning obligation) sweeps to the Developer Pool.
        uint256 surplus = spectralMarket.sweepSurplus(marketId);
        assertGt(surplus, 0, "a mispriced-losing-side trade should leave a positive sweepable surplus");

        console.log("B: full redeem OK. innocentPayout=%s sweptSurplus=%s", payout, surplus);
    }

    // ── shared lifecycle driver ──

    /// @dev create -> pay -> fund-to-open -> one large Guilty buy that crosses 93%. Leaves buyer as the sole Guilty
    ///      holder and seller as the sole Innocent holder. Because the pushed (Guilty) side is the one that later
    ///      wins in scenario A, this is exactly the LMSR bounded-loss setup (cost paid in < shares issued).
    function _openDisputeAndPushGuilty(address seller, address buyer)
        internal
        returns (uint256 listingId, uint256 marketId)
    {
        vm.deal(seller, 1 ether);
        vm.deal(buyer, 1 ether);

        vm.startPrank(seller);
        integrityBond.deposit{value: 3 * P}(); // free IB must cover createListing's 1.5P lock, with headroom
        listingId = listingManager.createListing(P, 1, COMPLETION_WINDOW);
        vm.stopPrank();

        vm.prank(buyer);
        settlement.pay{value: P}(listingId, 0);

        // Freshly created listing's slot 0 is on its first-ever sale, so cycle is 1 (ListingManager's per-slot
        // use counter, bumped on confirmPayment).
        marketId = disputeManager.marketIdOf(listingId, 0, 1);
        vm.prank(buyer);
        disputeManager.fundGuiltySide{value: P / 2}(listingId, 0);
        assertTrue(_open(marketId), "market should open when guilty funding hits 0.5P");

        vm.prank(buyer);
        spectralMarket.buy{value: 20 * P}(marketId, SpectralMarket.Side.Guilty, 10 * P);

        (uint256 pGuilty,) = spectralMarket.currentPrice(marketId);
        assertGe(pGuilty, 0.93e18, "single large buy should cross the 93% tracking threshold");
        assertFalse(_resolved(marketId), "no single trade may resolve the market instantly");
    }

    // ── market-field view helpers (kept separate to avoid stack-too-deep in the flows above) ──

    function _pooled(uint256 id) internal view returns (uint256 pooled) {
        (,,, pooled,,,) = spectralMarket.markets(id);
    }

    function _open(uint256 id) internal view returns (bool open) {
        (,,,, open,,) = spectralMarket.markets(id);
    }

    function _resolved(uint256 id) internal view returns (bool resolved) {
        (,,,,, resolved,) = spectralMarket.markets(id);
    }

    function _winner(uint256 id) internal view returns (SpectralMarket.Side winningSide) {
        (,,,,,, winningSide) = spectralMarket.markets(id);
    }
}
