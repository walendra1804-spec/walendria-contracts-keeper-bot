// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {Settlement} from "../../src/Settlement.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {SettlementConditions} from "../../src/SettlementConditions.sol";
import {DisputeManager} from "../../src/DisputeManager.sol";

/// @notice Runs the proof campaign (PROOF_CAMPAIGN.md) against the live Gnosis mainnet deployment as two
///         unattended broadcasts instead of forty-odd manual clicks: N honest transactions settled end to
///         end, then one dispute opened, evidenced by the market itself, and driven to a verdict.
///
///         **Why two phases and not one.** The Spectral Market only resolves after one side has held ≥93%
///         for a cumulative hour. That is a protocol property, not a scripting limitation — no amount of
///         cleverness collapses it into a single transaction. So phase 1 does everything up to and including
///         crossing the threshold, you wait out the hour, and phase 2 resolves and collects. Two commands,
///         one keystore prompt each.
///
///         **Why one address plays both sides.** The campaign is a rehearsal; the buyer and the seller are
///         the same operator either way. Deriving throwaway identities (as the older adversarial scripts in
///         this directory do) would make the on-chain trail *look* like two strangers while changing nothing
///         about who is behind it, and it costs extra funding transfers and strands dust in addresses nobody
///         will ever sweep. Honest and cheap beats theatrical: the record discloses the arrangement in
///         `walendria-app/src/lib/trackRecordNotes.ts`, and each listing says so in its own on-chain
///         description, which is a stronger disclosure than a note on a web page anyone could edit later.
///
/// @dev Every amount is a multiple of `CAMPAIGN_PRICE`, which you choose. `test_Fork_SmallestViablePrice`
///      shows the protocol behaves identically from 0.000001 to 10 xDAI, so pick it by what you can put up.
abstract contract CampaignBase is Script {
    // Live Gnosis mainnet (chain id 100), matching CONTRACT_ADDRESSES[gnosis.id] in walendria-app.
    IntegrityBond internal constant integrityBond = IntegrityBond(0xba8a0E4C8F0E46de6E82231d2243b9E8DF66143a);
    ListingManager internal constant listingManager = ListingManager(0xAF070b902aB31262b35E0Dc24809aE80B70918b9);
    Settlement internal constant settlement = Settlement(0x301690a2Dd9A95ca7EBE4CC457Cd0024201c5AB0);
    SpectralMarket internal constant spectralMarket = SpectralMarket(0xa68a83944BDD92Fc066c32b69f07E1519b728857);
    SettlementConditions internal constant settlementConditions =
        SettlementConditions(0xd07B2bEFB8590A861f8D6c1eF8AFb39c89197509);
    DisputeManager internal constant disputeManager =
        DisputeManager(payable(0x75ba345B89A9653C98E38958d84359A6cE9233b6));

    uint256 internal constant COMPLETION_WINDOW = 72 hours; // ListingManager.MIN_COMPLETION_WINDOW
    uint256 internal constant THRESHOLD = 0.93e18; // SettlementConditions' tracking threshold

    /// Shares bought to cross 93%. The measured minimum is 2.5867 * P; 2.7 leaves headroom for the market
    /// having moved between measurement and execution without meaningfully raising the cost (the excess sent
    /// as `value` is refunded by {SpectralMarket-buy} in the same transaction).
    uint256 internal constant PUSH_SHARES_NUM = 27;
    uint256 internal constant PUSH_SHARES_DEN = 10;

    function _price() internal view returns (uint256) {
        return vm.envOr("CAMPAIGN_PRICE", uint256(0.00005 ether));
    }

    /// @dev The campaign itself, deliberately free of any broadcast plumbing so that
    ///      `test/fork/ProofCampaign.t.sol` can execute the *same* code against a mainnet fork — including the
    ///      one-hour wait, which no dry run against live state can cover. A script that spends real money
    ///      should not have an untested path, and the only way to get that here is to keep the logic callable
    ///      from a test rather than trapped inside `run()`.
    function _phase1(uint256 P, uint256 honestCount, address me)
        internal
        returns (uint256 listingId, uint256 marketId, uint256 cycle)
    {
        // The whole campaign runs on ONE listing with ONE slot, and therefore one 1.5P bond lock.
        //
        // The obvious structure — a fresh listing per transaction — does not work, and finding out why is
        // worth writing down: {ListingManager-confirmCompletion} recycles the slot to Empty but deliberately
        // leaves the bond locked, because the slot remains available for the next buyer. Locked IB is tied to
        // an open listing slot, not to an individual sale, and is only released by closeListing/reduceSlots.
        // So ten listings would demand ten simultaneous 1.5P locks.
        //
        // Reusing one slot is both cheaper and a more faithful demonstration: a real seller lists a thing
        // once and sells it repeatedly, which is exactly what the slot-recycling design is for. Each payment
        // bumps the slot's `cycle`, so every sale still gets its own distinct dispute market.
        uint256 free = integrityBond.freeIB(me);
        if (free < (3 * P) / 2) {
            integrityBond.deposit{value: (3 * P) / 2 - free}();
        }

        listingId = listingManager.createListing(
            P,
            1,
            COMPLETION_WINDOW,
            "Proof campaign - developer rehearsal",
            "Rehearsal run by the protocol developer to produce a public track record. Buyer and seller are the same operator; the last sale on this slot is deliberately disputed. See walendria.org/track-record."
        );
        console.log("listing id             :", listingId);

        for (uint256 i = 0; i < honestCount; i++) {
            settlement.pay{value: P}(listingId, 0);
            listingManager.confirmCompletion(listingId, 0);
            console.log("settled + confirmed, cycle:", i + 1);
        }

        // The final sale on the same slot is the one taken to a verdict.
        settlement.pay{value: P}(listingId, 0);
        disputeManager.fundGuiltySide{value: P / 2}(listingId, 0);

        (,,, cycle) = listingManager.slots(listingId, 0);
        marketId = disputeManager.marketIdOf(listingId, 0, cycle);
        spectralMarket.buy{value: 3 * P}(marketId, SpectralMarket.Side.Guilty, (P * PUSH_SHARES_NUM) / PUSH_SHARES_DEN);
    }

    function _phase2(uint256 listingId, uint256 marketId, address me) internal {
        // Poking is permissionless, so the keeper bot may already have done it; treat that as success.
        (,,,,, bool resolved,) = spectralMarket.markets(marketId);
        if (!resolved) {
            settlementConditions.pokeSettlement(marketId);
            console.log("poked settlement");
        } else {
            console.log("already resolved (the keeper bot got there first)");
        }

        (bool opened, bool finalized) = disputeManager.disputes(marketId);
        require(opened, "dispute not open - wrong listing id?");
        if (!finalized) {
            disputeManager.finalizeDispute(listingId, 0);
            console.log("finalized dispute");
        }

        // Bond slash proceeds are a pull payment (IntegrityBond credits `claimable` rather than pushing, so a
        // broken receive() can never block dispute resolution), so the restitution needs collecting.
        if (integrityBond.claimable(me) > 0) {
            integrityBond.claim();
            console.log("claimed slashed bond");
        }

        spectralMarket.redeem(marketId);
    }
}

/// @notice Phase 1 — bond, honest transactions, dispute opened and pushed past 93%.
///
/// ```bash
/// CAMPAIGN_PRICE=50000000000000 CAMPAIGN_HONEST_COUNT=3 \
/// forge script script/live/ProofCampaign.s.sol:ProofCampaignPhase1 \
///   --rpc-url gnosis --account walendria-chiado --broadcast --slow
/// ```
///
/// From Windows cmd.exe the `VAR=value` prefix is not valid syntax; use (quotes required, or the trailing
/// space before `&&` becomes part of the value and `vm.envOr` cannot parse it):
///
/// ```cmd
/// set "CAMPAIGN_PRICE=50000000000000" && set "CAMPAIGN_HONEST_COUNT=3" && forge script ... --broadcast --slow
/// ```
contract ProofCampaignPhase1 is CampaignBase {
    function run() external {
        uint256 P = _price();
        uint256 honestCount = vm.envOr("CAMPAIGN_HONEST_COUNT", uint256(3));
        address me = msg.sender;

        // Peak requirement, checked before anything is spent so an underfunded run fails costing nothing
        // rather than halfway through, leaving a half-open dispute nobody can finish. Payments round-trip
        // (this address is both sides) so they do not accumulate; the bond, the guilty funding and the
        // value forwarded to the buy do.
        uint256 required = (3 * P) / 2 + P / 2 + 3 * P;
        console.log("price P (wei)          :", P);
        console.log("honest transactions    :", honestCount);
        console.log("balance (wei)          :", me.balance);
        console.log("required for capital   :", required);
        require(me.balance > required, "insufficient balance: lower CAMPAIGN_PRICE or top up");

        vm.startBroadcast();
        (uint256 listingId, uint256 marketId, uint256 cycle) = _phase1(P, honestCount, me);
        vm.stopBroadcast();

        (uint256 pGuilty,) = spectralMarket.currentPrice(marketId);
        console.log("");
        console.log("=== PHASE 1 DONE ===");
        console.log("listing id             :", listingId);
        console.log("disputed cycle         :", cycle);
        console.log("market id              :", marketId);
        console.log("guilty price (1e18)    :", pGuilty);
        // Fails loudly here rather than leaving you to discover it an hour later when phase 2 reverts.
        require(pGuilty >= THRESHOLD, "market did not cross 93% - raise PUSH_SHARES_NUM and re-run");
        console.log("");
        console.log("Threshold crossed. Wait ~1 hour of no counter-betting, then run phase 2 with:");
        console.log("  CAMPAIGN_LISTING_ID=", listingId);
    }
}

/// @notice Phase 2 — resolve the dispute and collect. Run at least one hour after phase 1.
///
/// ```bash
/// CAMPAIGN_LISTING_ID=<id from phase 1> \
/// forge script script/live/ProofCampaign.s.sol:ProofCampaignPhase2 \
///   --rpc-url gnosis --account walendria-chiado --broadcast --slow
/// ```
contract ProofCampaignPhase2 is CampaignBase {
    function run() external {
        uint256 listingId = vm.envUint("CAMPAIGN_LISTING_ID");
        // The disputed sale is whatever cycle the slot is currently on — read it rather than assuming, since
        // the number of honest transactions before it is a runtime choice.
        (,,, uint256 cycle) = listingManager.slots(listingId, 0);
        uint256 marketId = disputeManager.marketIdOf(listingId, 0, cycle);
        address me = msg.sender;
        uint256 before = me.balance;

        console.log("listing id             :", listingId);
        console.log("disputed cycle         :", cycle);
        console.log("market id              :", marketId);

        vm.startBroadcast();
        _phase2(listingId, marketId, me);
        vm.stopBroadcast();

        (,,,,,, SpectralMarket.Side winningSide) = spectralMarket.markets(marketId);
        console.log("");
        console.log("=== PHASE 2 DONE ===");
        console.log("winning side (0=Guilty):", uint256(winningSide));
        console.log("balance before (wei)   :", before);
        console.log("balance after  (wei)   :", me.balance);
        console.log("");
        console.log("Free IB left in the bond (withdrawable):", integrityBond.freeIB(me));
    }
}
