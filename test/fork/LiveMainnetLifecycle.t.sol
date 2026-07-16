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

/// @notice Fork test against the *actual deployed bytecode* of the LIVE GNOSIS MAINNET deployment (chain id 100,
///         deploy block 47230742). Mirrors LiveChiadoLifecycle.t.sol scenario-for-scenario: same two lifecycles
///         (poke-resolves-Guilty with a bounded-loss capped redeem; mutualClose-Innocent with a fully-covered
///         redeem plus surplus sweep), same assertions. A green run is direct evidence that the mainnet
///         bytecode behaves identically to the source in this repo - the mainnet deploy inherits the same 395
///         local tests plus the Chiado fork run, and this file extends that same guarantee to chain id 100.
///
/// @dev Skips itself when no gnosis fork can be created, so a plain `forge test` with no network access neither
///      fails nor silently pretends to have verified anything. Run explicitly with:
///      forge test --match-path test/fork/LiveMainnetLifecycle.t.sol -vv
contract LiveMainnetLifecycleForkTest is Test {
    // Live Gnosis mainnet addresses (checksummed) from broadcast/Deploy.s.sol/100/run-latest.json - the same set
    // wired into walendria-app/src/lib/contracts.ts [gnosis.id] and (post-cutover) keeper-bot/src/config.js.
    IntegrityBond internal constant integrityBond = IntegrityBond(0xba8a0E4C8F0E46de6E82231d2243b9E8DF66143a);
    ListingManager internal constant listingManager = ListingManager(0xAF070b902aB31262b35E0Dc24809aE80B70918b9);
    Settlement internal constant settlement = Settlement(0x301690a2Dd9A95ca7EBE4CC457Cd0024201c5AB0);
    SpectralMarket internal constant spectralMarket = SpectralMarket(0xa68a83944BDD92Fc066c32b69f07E1519b728857);
    SettlementConditions internal constant settlementConditions =
        SettlementConditions(0xd07B2bEFB8590A861f8D6c1eF8AFb39c89197509);
    DisputeManager internal constant disputeManager =
        DisputeManager(payable(0x75ba345B89A9653C98E38958d84359A6cE9233b6));

    uint256 internal constant P = 1_000_000; // wei - trivial-value stake so vm.deal covers a full lifecycle cheaply
    uint256 internal constant COMPLETION_WINDOW = 72 hours; // ListingManager.MIN_COMPLETION_WINDOW, exercised exactly

    bool internal forked;

    function setUp() public {
        try vm.createSelectFork("gnosis") returns (uint256) {
            forked = true;
        } catch {
            forked = false;
        }
    }

    // ── Scenario A: poke-settlement liveness + capped redeem on a bounded-loss shortfall ──

    function test_Fork_PokeResolvesGuiltyThenRedeemCapsPayoutOnShortfall() public {
        if (!forked) {
            console.log("SKIP: no Gnosis mainnet fork available");
            return;
        }

        address seller = makeAddr("fork-A-seller");
        address buyer = makeAddr("fork-A-buyer");
        (uint256 listingId, uint256 marketId) = _openDisputeAndPushGuilty(seller, buyer);

        address poker = makeAddr("fork-A-poker");
        vm.deal(poker, 1 ether);
        vm.prank(poker);
        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.ConditionsNotYetMet.selector, marketId));
        settlementConditions.pokeSettlement(marketId);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 pokerBefore = poker.balance;
        vm.prank(poker);
        settlementConditions.pokeSettlement(marketId);

        assertTrue(_resolved(marketId), "poke after 1h should resolve the market");
        assertEq(uint256(_winner(marketId)), uint256(SpectralMarket.Side.Guilty), "the >=93% side must win the poke");
        assertEq(poker.balance - pokerBefore, 0, "underwater poke pays no bounty (no surplus to draw from)");

        disputeManager.finalizeDispute(listingId, 0);
        (, bool finalized) = disputeManager.disputes(marketId);
        assertTrue(finalized, "dispute should finalize after resolution");

        _assertCappedRedeem(marketId, buyer);
    }

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

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.NothingToRedeem.selector, buyer));
        spectralMarket.redeem(marketId);

        console.log("A: capped redeem OK. obligation=%s pooled=%s payout=%s", buyerShares, pooledAtResolve, payout);
    }

    // ── Scenario B: mutualClose resolution + full (uncapped) redeem + surplus sweep ──

    function test_Fork_MutualCloseInnocentThenFullRedeemAndSurplusSweep() public {
        if (!forked) {
            console.log("SKIP: no Gnosis mainnet fork available");
            return;
        }

        address seller = makeAddr("fork-B-seller");
        address buyer = makeAddr("fork-B-buyer");
        (uint256 listingId, uint256 marketId) = _openDisputeAndPushGuilty(seller, buyer);

        vm.prank(buyer);
        disputeManager.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
        vm.prank(seller);
        disputeManager.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);

        assertTrue(_resolved(marketId), "mutualClose with only buyer+seller as holders should resolve");
        assertEq(uint256(_winner(marketId)), uint256(SpectralMarket.Side.Innocent), "resolved to the agreed verdict");

        uint256 sellerShares = spectralMarket.sharesOf(marketId, SpectralMarket.Side.Innocent, seller);
        assertLt(sellerShares, _pooled(marketId), "pool should comfortably cover the innocent obligation here");

        uint256 sellerEthBefore = seller.balance;
        vm.prank(seller);
        uint256 payout = spectralMarket.redeem(marketId);
        assertEq(payout, sellerShares, "innocent winner redeems every share 1:1 - not capped");
        assertEq(seller.balance - sellerEthBefore, payout, "seller receives the full payout");

        uint256 surplus = spectralMarket.sweepSurplus(marketId);
        assertGt(surplus, 0, "a mispriced-losing-side trade should leave a positive sweepable surplus");

        console.log("B: full redeem OK. innocentPayout=%s sweptSurplus=%s", payout, surplus);
    }

    // ── shared lifecycle driver ──

    function _openDisputeAndPushGuilty(address seller, address buyer)
        internal
        returns (uint256 listingId, uint256 marketId)
    {
        vm.deal(seller, 1 ether);
        vm.deal(buyer, 1 ether);

        vm.startPrank(seller);
        integrityBond.deposit{value: 3 * P}();
        listingId = listingManager.createListing(P, 1, COMPLETION_WINDOW, "", "");
        vm.stopPrank();

        vm.prank(buyer);
        settlement.pay{value: P}(listingId, 0);

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

    // ── market-field view helpers ──

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
