// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {Settlement} from "../../src/Settlement.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {DisputeManager} from "../../src/DisputeManager.sol";

/// @notice Phase 11 exit-criteria pass (build strategy Section 6/4): live, on-chain proof — against the actual
///         deployed bytecode on Chiado, not a local Foundry simulation — of two adversarial properties:
///         (1) no single trade, however large, resolves a dispute in the same transaction it occurs in, and
///         (2) mutualClose succeeds once buyer and seller are the only two share-holders on either side and agree
///         on a verdict. Both are already exhaustively covered by local unit/fuzz tests; this script's only new
///         information is confirming the same behavior survives real gas accounting and real cross-contract call
///         ordering on the live network, per Section 6's explicit rationale for a live pass.
/// @dev Uses two disposable, deterministically-derived (via makeAddrAndKey) throwaway identities funded from the
///      broadcaster's own balance — never the broadcaster's own funds moving directly through the protocol, so a
///      revert partway through never risks losing track of what belongs to whom. All amounts are deliberately at
///      the same 1e6-wei price scale used by prior live testing on this deployment, keeping total value moved
///      negligible; only gas (already minimized via the low-gas-price flags) is the real cost here.
contract AdversarialLifecycleScript is Script {
    IntegrityBond internal constant integrityBond = IntegrityBond(0xF33870A17C1A613c18e5BD8c7a5d8cF75e3b19D1);
    ListingManager internal constant listingManager = ListingManager(0xeBCF83A08faD5d571E7Aa1c5E5864592E9fb532f);
    Settlement internal constant settlement = Settlement(0x9f906a4cC3c879e494de7161888624514d4471F3);
    SpectralMarket internal constant spectralMarket = SpectralMarket(0x9bf0C2E07Af4b8e5C857593867dA3a6b00062b7b);
    DisputeManager internal constant disputeManager =
        DisputeManager(payable(0x317DC0607f67378509961b1763179050Af48F0ba));

    uint256 internal constant P = 1_000_000; // wei — same tiny scale as prior live testing on this deployment
    uint256 internal constant COMPLETION_WINDOW = 72 hours; // the protocol minimum, exercised deliberately

    function run() external {
        (address seller, uint256 sellerKey) = makeAddrAndKey("adversarial-live-seller");
        (address buyer, uint256 buyerKey) = makeAddrAndKey("adversarial-live-buyer");
        console.log("seller:", seller);
        console.log("buyer: ", buyer);

        _fundActors(seller, buyer);

        uint256 listingId = _createListing(sellerKey);
        _payListing(buyerKey, listingId);
        uint256 marketId = disputeManager.marketIdOf(listingId, 0);
        _openDispute(buyerKey, listingId, marketId);
        _pushPriceAndVerifyNoInstantResolution(buyerKey, marketId);
        _mutualCloseAndVerify(sellerKey, buyerKey, listingId, marketId);
    }

    function _fundActors(address seller, address buyer) internal {
        vm.startBroadcast();
        (bool okSeller,) = seller.call{value: 5_000_000_000_000}(""); // 5e12 wei: deposit(1.5P) + gas headroom
        require(okSeller, "funding seller failed");
        (bool okBuyer,) = buyer.call{value: 30_000_000_000_000}(""); // 3e13 wei: pay+fund+trade + gas headroom
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

    function _payListing(uint256 buyerKey, uint256 listingId) internal {
        vm.startBroadcast(buyerKey);
        settlement.pay{value: P}(listingId, 0);
        vm.stopBroadcast();
        console.log("Payment confirmed for listing", listingId);
    }

    function _openDispute(uint256 buyerKey, uint256 listingId, uint256 marketId) internal {
        vm.startBroadcast(buyerKey);
        disputeManager.fundGuiltySide{value: P / 2}(listingId, 0);
        vm.stopBroadcast();

        (,,,, bool open,,) = spectralMarket.markets(marketId);
        require(open, "dispute did not open");
        (uint256 pGuilty, uint256 pInnocent) = spectralMarket.currentPrice(marketId);
        console.log("Dispute opened. pGuilty=%s pInnocent=%s (both should be 0.5e18)", pGuilty, pInnocent);
    }

    function _pushPriceAndVerifyNoInstantResolution(uint256 buyerKey, uint256 marketId) internal {
        vm.startBroadcast(buyerKey);
        // Overpay generously (msg.value ceiling, not exact cost) — SpectralMarket.buy refunds the unused portion,
        // and H(99%)~=3.912P (Section 2.6.9's own worked table) means the real cost here is only a few million wei.
        spectralMarket.buy{value: 20_000_000_000}(marketId, SpectralMarket.Side.Guilty, 50 * P);
        vm.stopBroadcast();

        (uint256 pGuiltyAfter,) = spectralMarket.currentPrice(marketId);
        (,,,,, bool resolvedRightAfter,) = spectralMarket.markets(marketId);
        console.log("pGuilty after single large trade: %s (wad)", pGuiltyAfter);
        require(pGuiltyAfter >= 0.93e18, "trade did not genuinely cross the 93% threshold - test would be meaningless");
        require(!resolvedRightAfter, "VIOLATION: a single trade resolved the market instantly");
        console.log("CONFIRMED LIVE: crossing 93%%+ in one transaction did not resolve the market.");
    }

    function _mutualCloseAndVerify(uint256 sellerKey, uint256 buyerKey, uint256 listingId, uint256 marketId)
        internal
    {
        vm.startBroadcast(buyerKey);
        disputeManager.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
        vm.stopBroadcast();

        vm.startBroadcast(sellerKey);
        disputeManager.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
        vm.stopBroadcast();

        (,,,,, bool resolved, SpectralMarket.Side winningSide) = spectralMarket.markets(marketId);
        require(resolved, "VIOLATION: mutualClose did not resolve with only buyer+seller as holders");
        require(uint256(winningSide) == uint256(SpectralMarket.Side.Innocent), "resolved to wrong side");
        console.log("CONFIRMED LIVE: mutualClose resolved correctly with buyer+seller as the only two holders.");
    }
}
