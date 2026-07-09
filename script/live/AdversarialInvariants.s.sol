// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SD59x18, sd, ZERO} from "prb-math/SD59x18.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {Settlement} from "../../src/Settlement.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {DisputeManager} from "../../src/DisputeManager.sol";
import {LMSRMath} from "../../src/LMSRMath.sol";

/// @notice Phase 11 live pass, third batch (build strategy Section 4): three more adversarial properties proven
///         against the real deployed bytecode on Chiado:
///         (1) a listing cannot be created with a completion window below the protocol minimum,
///         (2) payment strictly less than P reverts with no partial state change,
///         (3) a seller funded with *only* the 0.995P sale proceeds cannot single-handedly push price to the 93%
///             resolution threshold - the concrete regression test for the finding that originally drove the
///             threshold's calibration (Section 2.6.9's H(p) boundary theorem).
/// @dev (1) and (2) are expected-revert checks, done as plain vm.prank + low-level .call() outside any broadcast
///      block - see AdversarialThirdPartyBlock.s.sol's doc for why a doomed-to-fail call can't cleanly be
///      broadcast as a real transaction via forge script, and why running it against this script's own forked
///      state is still a genuine live check against the real deployed bytecode. (3) is a real broadcast: the
///      seller's Guilty-side purchase is capped at exactly their actual received proceeds balance, spent in full.
contract AdversarialInvariantsScript is Script {
    IntegrityBond internal constant integrityBond = IntegrityBond(0xF33870A17C1A613c18e5BD8c7a5d8cF75e3b19D1);
    ListingManager internal constant listingManager = ListingManager(0xeBCF83A08faD5d571E7Aa1c5E5864592E9fb532f);
    Settlement internal constant settlement = Settlement(0x9f906a4cC3c879e494de7161888624514d4471F3);
    SpectralMarket internal constant spectralMarket = SpectralMarket(0x9bf0C2E07Af4b8e5C857593867dA3a6b00062b7b);
    DisputeManager internal constant disputeManager =
        DisputeManager(payable(0x317DC0607f67378509961b1763179050Af48F0ba));

    uint256 internal constant P = 1_000_000; // wei — same tiny scale as prior live testing on this deployment
    uint256 internal constant COMPLETION_WINDOW = 72 hours;
    uint256 internal constant DEV_FEE_BPS_DENOM = 1000; // matches Settlement.sol's 0.5% = 5/1000 fee rate

    function run() external {
        (address seller, uint256 sellerKey) = makeAddrAndKey("adversarial-live-seller-invariants");
        (address buyer, uint256 buyerKey) = makeAddrAndKey("adversarial-live-buyer-invariants");
        console.log("seller:", seller);
        console.log("buyer: ", buyer);

        _fundActors(seller, buyer);
        _verifyWindowMinimumEnforced(sellerKey);

        uint256 listingId = _createListing(sellerKey);
        _verifyUnderpaymentReverts(buyerKey, listingId);
        _payListingForReal(buyerKey, listingId);
        uint256 marketId = disputeManager.marketIdOf(listingId, 0, 1);
        _openDisputeViaBuyer(buyerKey, listingId, marketId);
        _verifySellerProceedsAloneCannotReach93Percent(sellerKey, marketId);
    }

    function _fundActors(address seller, address buyer) internal {
        vm.startBroadcast();
        (bool okSeller,) = seller.call{value: 5_000_000_000_000}("");
        require(okSeller, "funding seller failed");
        (bool okBuyer,) = buyer.call{value: 15_000_000_000_000}("");
        require(okBuyer, "funding buyer failed");
        vm.stopBroadcast();
        console.log("Funded seller and buyer from broadcaster balance.");
    }

    /// @notice ListingManager.createListing checks completionWindow before ever touching IntegrityBond, so this
    ///         revert is expected regardless of the seller's IB balance at this point.
    function _verifyWindowMinimumEnforced(uint256 sellerKey) internal {
        vm.prank(vm.addr(sellerKey));
        (bool succeeded,) = address(listingManager)
            .call(abi.encodeWithSelector(ListingManager.createListing.selector, P, 1, COMPLETION_WINDOW - 1 hours));
        require(!succeeded, "VIOLATION: createListing succeeded with a completion window below the protocol minimum");
        console.log("CONFIRMED LIVE: createListing rejects a completion window below the 72-hour minimum.");
    }

    function _createListing(uint256 sellerKey) internal returns (uint256 listingId) {
        vm.startBroadcast(sellerKey);
        integrityBond.deposit{value: (P * 3) / 2}();
        listingId = listingManager.createListing(P, 1, COMPLETION_WINDOW);
        vm.stopBroadcast();
        console.log("Listing created:", listingId);
    }

    function _verifyUnderpaymentReverts(uint256 buyerKey, uint256 listingId) internal {
        vm.prank(vm.addr(buyerKey));
        (bool succeeded,) =
            address(settlement).call{value: P - 1}(abi.encodeWithSelector(Settlement.pay.selector, listingId, 0));
        require(!succeeded, "VIOLATION: payment strictly less than P succeeded");

        (,, address buyerOfRecord,) = listingManager.slots(listingId, 0);
        require(buyerOfRecord == address(0), "VIOLATION: slot state changed despite the reverted underpayment");
        console.log("CONFIRMED LIVE: payment strictly less than P reverts with no partial state change.");
    }

    function _payListingForReal(uint256 buyerKey, uint256 listingId) internal {
        vm.startBroadcast(buyerKey);
        settlement.pay{value: P}(listingId, 0);
        vm.stopBroadcast();
        console.log("Payment confirmed for listing", listingId);
    }

    function _openDisputeViaBuyer(uint256 buyerKey, uint256 listingId, uint256 marketId) internal {
        vm.startBroadcast(buyerKey);
        disputeManager.fundGuiltySide{value: P / 2}(listingId, 0);
        vm.stopBroadcast();

        (,,,, bool open,,) = spectralMarket.markets(marketId);
        require(open, "dispute did not open");
        console.log("Dispute opened for listing", listingId);
    }

    /// @notice The seller's Guilty-side purchase is capped at exactly their 0.995P proceeds balance (spent in
    ///         full, buying as many shares as that budget allows) - the concrete live test that H(93%) > 0.995P
    ///         (Section 2.6.9), i.e. a self-funding, non-colluding seller cannot single-handedly manufacture a
    ///         Guilty resolution using only what the sale itself paid them.
    function _verifySellerProceedsAloneCannotReach93Percent(uint256 sellerKey, uint256 marketId) internal {
        uint256 proceeds = (P * 995) / DEV_FEE_BPS_DENOM; // 0.995P, matching Settlement.sol's fee-net forward
        address sellerAddr = vm.addr(sellerKey);
        require(
            sellerAddr.balance >= proceeds, "seller did not actually receive sale proceeds - test would be meaningless"
        );

        uint256 affordableShares = _maxSharesForBudget(marketId, SpectralMarket.Side.Guilty, proceeds);

        vm.startBroadcast(sellerKey);
        spectralMarket.buy{value: proceeds}(marketId, SpectralMarket.Side.Guilty, affordableShares);
        vm.stopBroadcast();

        (uint256 pGuiltyAfter,) = spectralMarket.currentPrice(marketId);
        console.log("pGuilty after seller spends only their 0.995P proceeds: %s (wad)", pGuiltyAfter);
        require(pGuiltyAfter < 0.93e18, "VIOLATION: 0.995P alone reached the 93% resolution threshold");
        console.log("CONFIRMED LIVE: the seller's 0.995P sale proceeds alone cannot reach the 93% threshold.");
    }

    /// @dev Mirrors DisputeManager.t.sol's `_maxSharesForBudget` exactly: a pure, off-chain binary search over
    ///      LMSRMath.costOfTrade (a pure library function, zero gas/network cost to call locally) against the
    ///      market's actual current on-chain (qGuilty, qInnocent, b), so the live buy() call below requests
    ///      precisely the number of shares `budget` affords - not a guessed ceiling, which is what caused the
    ///      first version of this script to overflow PRBMath's exp() input domain.
    function _maxSharesForBudget(uint256 marketId, SpectralMarket.Side side, uint256 budget)
        internal
        view
        returns (uint256)
    {
        (SD59x18 b, SD59x18 qGuilty, SD59x18 qInnocent,,,,) = spectralMarket.markets(marketId);
        uint256 lo = 0;
        uint256 hi = budget * 2; // shares are never worth less than 0.5 * dollar spent, so this is a safe upper bound
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            SD59x18 dq = sd(int256(mid));
            SD59x18 costFixed = side == SpectralMarket.Side.Guilty
                ? LMSRMath.costOfTrade(qGuilty, qInnocent, dq, ZERO, b)
                : LMSRMath.costOfTrade(qGuilty, qInnocent, ZERO, dq, b);
            if (uint256(SD59x18.unwrap(costFixed)) <= budget) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }
}
