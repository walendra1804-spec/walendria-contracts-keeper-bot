// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {Settlement} from "../../src/Settlement.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {DisputeManager} from "../../src/DisputeManager.sol";

/// @notice Phase 11 live pass, fifth batch (build strategy Section 4), part 1 of 2: sets up a dispute and pushes
///         its price to >=93% Guilty in a single trade, which *activates* SettlementConditions' cumulative-time
///         tracking (Section 2.6.5/2.6.8) but does not itself resolve anything - cumulativeGuilty only starts
///         accruing from this checkpoint's timestamp forward. Deliberately does NOT touch the market again after
///         this: {AdversarialPokeVerify.s.sol} is run roughly 65+ real minutes later (a genuine wait - there is no
///         way to warp time on a live chain) to prove {pokeSettlement} alone, called by an arbitrary third party,
///         resolves the dispute with zero further trades in between (the whole point of Section 2.6.8 point 3 -
///         a case can never hang indefinitely even if nobody ever trades again after crossing the threshold).
/// @dev Logs the exact marketId - copy it into AdversarialPokeVerify.s.sol's MARKET_ID constant before running that
///      script later.
contract AdversarialPokeSetupScript is Script {
    IntegrityBond internal constant integrityBond = IntegrityBond(0xF33870A17C1A613c18e5BD8c7a5d8cF75e3b19D1);
    ListingManager internal constant listingManager = ListingManager(0xeBCF83A08faD5d571E7Aa1c5E5864592E9fb532f);
    Settlement internal constant settlement = Settlement(0x9f906a4cC3c879e494de7161888624514d4471F3);
    SpectralMarket internal constant spectralMarket = SpectralMarket(0x9bf0C2E07Af4b8e5C857593867dA3a6b00062b7b);
    DisputeManager internal constant disputeManager =
        DisputeManager(payable(0x317DC0607f67378509961b1763179050Af48F0ba));

    uint256 internal constant P = 1_000_000; // wei — same tiny scale as prior live testing on this deployment
    uint256 internal constant COMPLETION_WINDOW = 72 hours;

    function run() external {
        (address seller, uint256 sellerKey) = makeAddrAndKey("adversarial-live-seller-poke");
        (address buyer, uint256 buyerKey) = makeAddrAndKey("adversarial-live-buyer-poke");
        console.log("seller:", seller);
        console.log("buyer: ", buyer);

        _fundActors(seller, buyer);

        vm.startBroadcast(sellerKey);
        integrityBond.deposit{value: (P * 3) / 2}();
        uint256 listingId = listingManager.createListing(P, 1, COMPLETION_WINDOW, "", "");
        vm.stopBroadcast();
        console.log("Listing created:", listingId);

        vm.startBroadcast(buyerKey);
        settlement.pay{value: P}(listingId, 0);
        vm.stopBroadcast();

        uint256 marketId = disputeManager.marketIdOf(listingId, 0, 1);

        vm.startBroadcast(buyerKey);
        disputeManager.fundGuiltySide{value: P / 2}(listingId, 0);
        vm.stopBroadcast();

        (,,,, bool open,,) = spectralMarket.markets(marketId);
        require(open, "dispute did not open");

        vm.startBroadcast(buyerKey);
        // Overpay generously (msg.value ceiling, not exact cost) - SpectralMarket.buy refunds the unused portion.
        spectralMarket.buy{value: 20_000_000_000}(marketId, SpectralMarket.Side.Guilty, 50 * P);
        vm.stopBroadcast();

        (uint256 pGuiltyAfter,) = spectralMarket.currentPrice(marketId);
        require(pGuiltyAfter >= 0.93e18, "trade did not genuinely cross the 93% threshold - setup would be meaningless");

        console.log("marketId (copy into AdversarialPokeVerify.s.sol):", marketId);
        console.log("pGuilty after push: %s (wad)", pGuiltyAfter);
        console.log("Cumulative-time tracking is now active. Wait 65+ real minutes with ZERO further trades on");
        console.log("this market, then run AdversarialPokeVerify.s.sol.");
    }

    function _fundActors(address seller, address buyer) internal {
        vm.startBroadcast();
        (bool okSeller,) = seller.call{value: 5_000_000_000_000}("");
        require(okSeller, "funding seller failed");
        (bool okBuyer,) = buyer.call{value: 30_000_000_000_000}("");
        require(okBuyer, "funding buyer failed");
        vm.stopBroadcast();
        console.log("Funded seller and buyer from broadcaster balance.");
    }
}
