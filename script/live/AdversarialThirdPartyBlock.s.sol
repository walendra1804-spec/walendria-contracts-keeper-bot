// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {Settlement} from "../../src/Settlement.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {DisputeManager} from "../../src/DisputeManager.sol";

/// @notice Phase 11 live pass, second scenario (build strategy Section 4): mutualClose (Section 2.6.10) must stay
///         permanently and irrevocably disabled the instant any third address ever holds even a single share on
///         either side - including after that address fully exits the position. Proves this against the live,
///         redeployed contract graph (the same mechanism whose live bytecode was found stale and fixed earlier
///         this session), not just the local fuzz/unit suite.
/// @dev Same disposable-identity pattern as AdversarialLifecycle.s.sol. The third party buys a tiny Innocent
///      position, fully exits it, then both buyer and seller attempt mutualClose - both attempts are expected to
///      revert, caught here via try/catch so the broadcast itself completes as an ordinary successful transaction
///      that happens to have exercised and confirmed a revert path, rather than sending a transaction expected to
///      fail outright.
contract AdversarialThirdPartyBlockScript is Script {
    IntegrityBond internal constant integrityBond = IntegrityBond(0xF33870A17C1A613c18e5BD8c7a5d8cF75e3b19D1);
    ListingManager internal constant listingManager = ListingManager(0xeBCF83A08faD5d571E7Aa1c5E5864592E9fb532f);
    Settlement internal constant settlement = Settlement(0x9f906a4cC3c879e494de7161888624514d4471F3);
    SpectralMarket internal constant spectralMarket = SpectralMarket(0x9bf0C2E07Af4b8e5C857593867dA3a6b00062b7b);
    DisputeManager internal constant disputeManager =
        DisputeManager(payable(0x317DC0607f67378509961b1763179050Af48F0ba));

    uint256 internal constant P = 1_000_000; // wei — same tiny scale as prior live testing on this deployment
    uint256 internal constant COMPLETION_WINDOW = 72 hours;

    function run() external {
        (address seller, uint256 sellerKey) = makeAddrAndKey("adversarial-live-seller-tpblock");
        (address buyer, uint256 buyerKey) = makeAddrAndKey("adversarial-live-buyer-tpblock");
        (address thirdParty, uint256 thirdPartyKey) = makeAddrAndKey("adversarial-live-thirdparty");
        console.log("seller:     ", seller);
        console.log("buyer:      ", buyer);
        console.log("thirdParty: ", thirdParty);

        _fundActors(seller, buyer, thirdParty);

        uint256 listingId = _createListing(sellerKey);
        _payListing(buyerKey, listingId);
        uint256 marketId = disputeManager.marketIdOf(listingId, 0);
        _openDispute(buyerKey, listingId, marketId);
        _thirdPartyBuysAndFullyExits(thirdPartyKey, marketId);
        _attemptMutualCloseAndVerifyBlocked(sellerKey, buyerKey, listingId, marketId);
    }

    function _fundActors(address seller, address buyer, address thirdParty) internal {
        vm.startBroadcast();
        (bool okSeller,) = seller.call{value: 5_000_000_000_000}("");
        require(okSeller, "funding seller failed");
        (bool okBuyer,) = buyer.call{value: 15_000_000_000_000}("");
        require(okBuyer, "funding buyer failed");
        (bool okThird,) = thirdParty.call{value: 5_000_000_000_000}("");
        require(okThird, "funding thirdParty failed");
        vm.stopBroadcast();
        console.log("Funded seller, buyer, and thirdParty from broadcaster balance.");
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
    }

    function _openDispute(uint256 buyerKey, uint256 listingId, uint256 marketId) internal {
        vm.startBroadcast(buyerKey);
        disputeManager.fundGuiltySide{value: P / 2}(listingId, 0);
        vm.stopBroadcast();

        (,,,, bool open,,) = spectralMarket.markets(marketId);
        require(open, "dispute did not open");
        console.log("Dispute opened for listing", listingId);
    }

    function _thirdPartyBuysAndFullyExits(uint256 thirdPartyKey, uint256 marketId) internal {
        vm.startBroadcast(thirdPartyKey);
        spectralMarket.buy{value: 2_000_000_000}(marketId, SpectralMarket.Side.Innocent, P / 100);
        uint256 held = spectralMarket.sharesOf(marketId, SpectralMarket.Side.Innocent, vm.addr(thirdPartyKey));
        spectralMarket.sell(marketId, SpectralMarket.Side.Innocent, held, 0);
        vm.stopBroadcast();

        uint256 heldAfter = spectralMarket.sharesOf(marketId, SpectralMarket.Side.Innocent, vm.addr(thirdPartyKey));
        require(heldAfter == 0, "third party did not genuinely fully exit - test would be meaningless");
        uint256 distinctInnocent = spectralMarket.distinctHolderCount(marketId, SpectralMarket.Side.Innocent);
        require(distinctInnocent >= 2, "third party's touch was not recorded - test would be meaningless");
        console.log("Third party bought in and fully exited. distinctInnocentHolders now:", distinctInnocent);
    }

    function _attemptMutualCloseAndVerifyBlocked(
        uint256 sellerKey,
        uint256 buyerKey,
        uint256 listingId,
        uint256 marketId
    ) internal {
        // Deliberately NOT wrapped in vm.startBroadcast/stopBroadcast: forge script records every call made
        // while broadcasting as a real transaction to send, and by default treats one that reverts on-chain as
        // a fatal simulation error (regardless of try/catch or a low-level .call()'s success flag) - there is no
        // supported way to broadcast a transaction expected to revert without disabling on-chain simulation
        // entirely, which turned out to also skip forking real account balances. Calling it outside a broadcast
        // block instead runs it as plain script-local execution against the same forked state every read in
        // this script already uses - it is still the real, currently-deployed DisputeManager bytecode being
        // executed, against the real dispute this script's own prior broadcasts just opened; it just never gets
        // relayed as a doomed-to-fail transaction, since the property being proven belongs to the contract logic
        // itself and needs no additional confirmation from having actually paid gas to fail.
        vm.prank(vm.addr(buyerKey));
        (bool buyerSucceeded,) = address(disputeManager).call(
            abi.encodeWithSelector(DisputeManager.mutualClose.selector, listingId, 0, SpectralMarket.Side.Innocent)
        );
        require(!buyerSucceeded, "VIOLATION: buyer's mutualClose succeeded despite a third party having touched the market");

        vm.prank(vm.addr(sellerKey));
        (bool sellerSucceeded,) = address(disputeManager).call(
            abi.encodeWithSelector(DisputeManager.mutualClose.selector, listingId, 0, SpectralMarket.Side.Innocent)
        );
        require(!sellerSucceeded, "VIOLATION: seller's mutualClose succeeded despite a third party having touched the market");

        (,,,,, bool resolved,) = spectralMarket.markets(marketId);
        require(!resolved, "VIOLATION: market resolved via mutualClose despite third-party participation");
        console.log("CONFIRMED LIVE: mutualClose stayed permanently blocked after a third party fully exited its position.");
    }
}
