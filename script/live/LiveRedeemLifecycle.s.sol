// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SD59x18} from "prb-math/SD59x18.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {Settlement} from "../../src/Settlement.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {DisputeManager} from "../../src/DisputeManager.sol";

/// @notice Live, on-chain proof - against the actual deployed bytecode on the current Chiado redeploy - that
///         {SpectralMarket-redeem} pays out (capped, not reverting) even when LMSR's bounded loss leaves the pool
///         short of the full winning obligation. This is a direct on-chain reproduction of the incident that
///         bricked redemption on the *previous* deployment: a winner whose claim exceeded the pool got an
///         arithmetic-underflow revert and could never redeem. Here the same shortfall condition must instead
///         yield a final, capped payout with no revert.
///
///         Flow (resolved via mutualClose so no 1-hour poke wait is needed - the poke-settlement path is covered
///         exhaustively by test/fork/LiveChiadoLifecycle.t.sol against this same deployment):
///         create -> pay -> fund-guilty (opens market) -> one large Guilty buy (crosses 93%, sets up the
///         bounded-loss shortfall) -> buyer+seller mutualClose(Guilty) -> buyer redeems the winning Guilty shares
///         against a pool now smaller than the obligation, and receives the capped remainder.
/// @dev Uses two disposable, deterministically-derived throwaway identities funded from the broadcaster's own
///      balance - the broadcaster's own funds never move through the protocol directly, so a mid-run revert never
///      confuses whose money is whose. All amounts are at the same 1e6-wei price scale prior live testing used;
///      total value moved is negligible, only (already-minimized) gas is a real cost.
contract LiveRedeemLifecycleScript is Script {
    IntegrityBond internal constant integrityBond = IntegrityBond(0xCe6d6c0911D4203Bb4842e72922c438B166f50b9);
    ListingManager internal constant listingManager = ListingManager(0xd7082ae2aBcE68a9DB5A22A6489afE1fbac50111);
    Settlement internal constant settlement = Settlement(0x28b3d7F41fCEB9FC290a3742cACd324aC4C86092);
    SpectralMarket internal constant spectralMarket = SpectralMarket(0xF2FAcf7443e506BDE3987395a87B9Dec8748027A);
    DisputeManager internal constant disputeManager =
        DisputeManager(payable(0x6c5A731167F1b44cd0822d07a002B492bfb57E07));

    uint256 internal constant P = 1_000_000; // wei
    uint256 internal constant COMPLETION_WINDOW = 72 hours;

    function run() external {
        (address seller, uint256 sellerKey) = makeAddrAndKey("live-redeem-cap-seller");
        (address buyer, uint256 buyerKey) = makeAddrAndKey("live-redeem-cap-buyer");
        console.log("seller:", seller);
        console.log("buyer: ", buyer);

        _fundActors(seller, buyer);

        uint256 listingId = _createListing(sellerKey);
        _pay(buyerKey, listingId);

        uint256 marketId = disputeManager.marketIdOf(listingId, 0, 1);
        _openDispute(buyerKey, listingId, marketId);
        _pushGuiltyPast93(buyerKey, marketId);
        _mutualCloseGuilty(sellerKey, buyerKey, listingId, marketId);
        _redeemAndVerifyCap(buyerKey, buyer, marketId);
    }

    function _fundActors(address seller, address buyer) internal {
        vm.startBroadcast();
        (bool okSeller,) = seller.call{value: 8_000_000_000_000}(""); // 8e12: deposit(1.5P) + gas headroom
        require(okSeller, "funding seller failed");
        (bool okBuyer,) = buyer.call{value: 35_000_000_000_000}(""); // 3.5e13: pay+fund+buy + gas headroom
        require(okBuyer, "funding buyer failed");
        vm.stopBroadcast();
        console.log("Funded seller and buyer from broadcaster balance.");
    }

    function _createListing(uint256 sellerKey) internal returns (uint256 listingId) {
        vm.startBroadcast(sellerKey);
        integrityBond.deposit{value: (P * 3) / 2}();
        listingId = listingManager.createListing(P, 1, COMPLETION_WINDOW);
        vm.stopBroadcast();
        console.log("Listing created:", listingId);
    }

    function _pay(uint256 buyerKey, uint256 listingId) internal {
        vm.startBroadcast(buyerKey);
        settlement.pay{value: P}(listingId, 0);
        vm.stopBroadcast();
        console.log("Payment confirmed.");
    }

    function _openDispute(uint256 buyerKey, uint256 listingId, uint256 marketId) internal {
        vm.startBroadcast(buyerKey);
        disputeManager.fundGuiltySide{value: P / 2}(listingId, 0);
        vm.stopBroadcast();

        (,,,, bool open,,) = spectralMarket.markets(marketId);
        require(open, "dispute did not open");
        console.log("Dispute opened (market %s).", marketId);
    }

    function _pushGuiltyPast93(uint256 buyerKey, uint256 marketId) internal {
        vm.startBroadcast(buyerKey);
        // Overpay ceiling (refunded down to real cost). 10*P Guilty shares pushes price well past 93% and, since
        // Guilty then wins, leaves the pool short of the obligation by up to b*ln(2) - the shortfall under test.
        spectralMarket.buy{value: 20 * P}(marketId, SpectralMarket.Side.Guilty, 10 * P);
        vm.stopBroadcast();

        (uint256 pGuilty,) = spectralMarket.currentPrice(marketId);
        (,,,,, bool resolved,) = spectralMarket.markets(marketId);
        require(pGuilty >= 0.93e18, "buy did not cross 93% - test would be meaningless");
        require(!resolved, "VIOLATION: a single trade resolved the market instantly");
        console.log("pGuilty after large buy: %s (wad). Not resolved by the trade alone.", pGuilty);
    }

    function _mutualCloseGuilty(uint256 sellerKey, uint256 buyerKey, uint256 listingId, uint256 marketId) internal {
        vm.startBroadcast(buyerKey);
        disputeManager.mutualClose(listingId, 0, SpectralMarket.Side.Guilty);
        vm.stopBroadcast();

        vm.startBroadcast(sellerKey);
        disputeManager.mutualClose(listingId, 0, SpectralMarket.Side.Guilty);
        vm.stopBroadcast();

        (,,, uint256 pooled,, bool resolved, SpectralMarket.Side winner) = spectralMarket.markets(marketId);
        require(resolved, "mutualClose did not resolve");
        require(uint256(winner) == uint256(SpectralMarket.Side.Guilty), "resolved to the wrong side");
        console.log("Resolved Guilty via mutualClose. pooled=%s", pooled);
    }

    function _redeemAndVerifyCap(uint256 buyerKey, address buyer, uint256 marketId) internal {
        uint256 shares = spectralMarket.sharesOf(marketId, SpectralMarket.Side.Guilty, buyer);
        (,,, uint256 pooledBefore,,,) = spectralMarket.markets(marketId);
        require(shares > pooledBefore, "not a shortfall case - test would not exercise the cap");
        console.log("Pre-redeem: winning shares=%s  pooled=%s (shortfall exists)", shares, pooledBefore);

        vm.startBroadcast(buyerKey);
        uint256 payout = spectralMarket.redeem(marketId);
        vm.stopBroadcast();

        require(payout == pooledBefore, "payout should be capped at the pool balance");
        uint256 remaining = spectralMarket.sharesOf(marketId, SpectralMarket.Side.Guilty, buyer);
        require(remaining == 0, "claim should be fully extinguished");
        console.log("CONFIRMED LIVE: capped redeem paid %s (no revert), claim fully extinguished.", payout);
    }
}
