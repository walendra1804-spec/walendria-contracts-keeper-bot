// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {Settlement} from "../../src/Settlement.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {SettlementConditions} from "../../src/SettlementConditions.sol";
import {DisputeManager} from "../../src/DisputeManager.sol";

/// @notice Measurement harness, not a pass/fail correctness test. Answers one operational question before any
///         real money is committed: **how much xDAI does it actually take to run a staged-but-real dispute to
///         resolution on the live Gnosis mainnet deployment, and how much of it comes back?**
///
///         This exists because the honest-lifecycle fork test pushes the market past 93% by buying `10 * P`
///         shares — a deliberate overshoot chosen to make the assertion robust, not a cost estimate. Reading
///         that number as "a dispute costs 10x the transaction price" would badly overstate the capital
///         needed and could talk the project out of a campaign it can easily afford. So rather than reason
///         about LMSR algebra on paper, this binary-searches the *minimum* share purchase that crosses the
///         93% tracking threshold and reports what it actually cost, against the deployed mainnet bytecode.
///
///         Two numbers matter and they are very different:
///           • PEAK CAPITAL  — the most xDAI that must be liquid at one moment across all roles. This is the
///                             real gate on whether a campaign can start.
///           • NET COST      — what is actually consumed once positions unwind. When one operator controls
///                             every role (the honest description of a staged rehearsal), most of the outlay
///                             returns, and value routed to the Developer Pool returns to the same operator.
///
/// @dev Read-only with respect to mainnet: everything runs against a local fork, so nothing here can spend
///      real funds. Skips itself when no `gnosis` fork is reachable, so a networkless `forge test` neither
///      fails nor pretends to have measured anything. Run explicitly with:
///      forge test --match-path test/fork/MainnetCampaignCost.t.sol -vv
contract MainnetCampaignCostForkTest is Test {
    // Live Gnosis mainnet addresses (chain id 100) — the set wired into walendria-app/src/lib/contracts.ts
    // under CONTRACT_ADDRESSES[gnosis.id], from broadcast/Deploy.s.sol/100/run-latest.json.
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

    bool internal forked;

    function setUp() public {
        try vm.createSelectFork("gnosis") returns (uint256) {
            forked = true;
        } catch {
            forked = false;
        }
    }

    function test_Fork_MeasureStagedDisputeCost() public {
        if (!forked) {
            console.log("SKIP: no gnosis fork available (set the `gnosis` RPC endpoint to measure)");
            return;
        }

        // Three transaction sizes spanning the usable band: 0.1, 1 and 10 xDAI against the 100 xDAI hardcap.
        _measure(0.1 ether);
        _measure(1 ether);
        _measure(10 ether);
    }

    /// @notice Answers the follow-up question the first measurement provokes: **how small can P go before the
    ///         protocol stops behaving?** The peak-capital figure is a multiple of P, so the campaign budget is
    ///         whatever the operator picks P to be — but only if the ratios survive at small sizes. LMSR works
    ///         in fixed point over integer wei, so shrinking P shrinks the numbers every rounding step acts on,
    ///         and there is no reason to assume the behaviour is scale-free without checking.
    ///
    ///         The contracts impose almost no floor of their own: ListingManager rejects only `price == 0`, and
    ///         DisputeManager rejects only `price / 2 == 0` (i.e. 1 wei). So if the ratios hold down here, the
    ///         real floor is a judgement about what a transaction size means, not a technical limit.
    function test_Fork_SmallestViablePrice() public {
        if (!forked) {
            console.log("SKIP: no gnosis fork available (set the `gnosis` RPC endpoint to measure)");
            return;
        }

        uint256[5] memory sizes = [uint256(0.000001 ether), 0.00001 ether, 0.0001 ether, 0.001 ether, 0.01 ether];
        for (uint256 i = 0; i < sizes.length; i++) {
            _measure(sizes[i]);
        }
    }

    /// @notice Measures the **gas** each campaign operation actually burns against the deployed bytecode, and
    ///         totals it for the whole campaign. This matters far more than it first appears: capital in this
    ///         campaign is a loop — it is put up, then it comes back — whereas gas is the only part that is
    ///         genuinely spent and never returns. Once P is pushed small enough, gas stops being a rounding
    ///         error and becomes the entire budget, and the operator needs to know where that crossover sits
    ///         before choosing P rather than after running out mid-campaign.
    function test_Fork_MeasureCampaignGas() public {
        if (!forked) {
            console.log("SKIP: no gnosis fork available (set the `gnosis` RPC endpoint to measure)");
            return;
        }

        // Indices into `g`. Held as an array rather than named locals purely because nine separate uint256s
        // plus the ids overflows the EVM's 16-slot stack window ("stack too deep") in this test.
        uint256[9] memory g;
        _runCampaignForGas(0.001 ether, g);

        uint256 perHonest = g[G_CREATE] + g[G_PAY] + g[G_CONFIRM];
        uint256 dispute = g[G_CREATE] + g[G_PAY] + g[G_FUND] + (3 * g[G_BUY]) + g[G_POKE] + g[G_FINALIZE] + g[G_REDEEM];
        uint256 campaign = g[G_DEPOSIT] + (10 * perHonest) + dispute;

        console.log("");
        console.log("=== GAS PER OPERATION (live mainnet bytecode) ===");
        console.log("  integrityBond.deposit      : %s", g[G_DEPOSIT]);
        console.log("  createListing              : %s", g[G_CREATE]);
        console.log("  settlement.pay             : %s", g[G_PAY]);
        console.log("  confirmCompletion          : %s", g[G_CONFIRM]);
        console.log("  fundGuiltySide (opens mkt) : %s", g[G_FUND]);
        console.log("  spectralMarket.buy         : %s", g[G_BUY]);
        console.log("  pokeSettlement             : %s", g[G_POKE]);
        console.log("  finalizeDispute            : %s", g[G_FINALIZE]);
        console.log("  redeem                     : %s", g[G_REDEEM]);
        console.log("");
        console.log("  gas per honest transaction : %s", perHonest);
        console.log("  gas for the full dispute   : %s", dispute);
        console.log("  GAS FOR WHOLE CAMPAIGN     : %s", campaign);
        console.log("");
        console.log("  wei @ 0.001 gwei           : %s", campaign * 1_000_000);
        console.log("  wei @ 0.1   gwei           : %s", campaign * 100_000_000);
        console.log("  wei @ 1     gwei           : %s", campaign * 1_000_000_000);
    }

    uint256 internal constant G_DEPOSIT = 0;
    uint256 internal constant G_CREATE = 1;
    uint256 internal constant G_PAY = 2;
    uint256 internal constant G_CONFIRM = 3;
    uint256 internal constant G_FUND = 4;
    uint256 internal constant G_BUY = 5;
    uint256 internal constant G_POKE = 6;
    uint256 internal constant G_FINALIZE = 7;
    uint256 internal constant G_REDEEM = 8;

    /// @dev Walks one full lifecycle at price `P`, recording gas for each step into `g`.
    function _runCampaignForGas(uint256 P, uint256[9] memory g) internal {
        address seller = makeAddr("gas-seller");
        address buyer = makeAddr("gas-buyer");
        vm.deal(seller, 50 * P);
        vm.deal(buyer, 50 * P);

        uint256 t;

        vm.startPrank(seller);
        t = gasleft();
        integrityBond.deposit{value: (3 * P) / 2}();
        g[G_DEPOSIT] = t - gasleft();

        t = gasleft();
        uint256 listingId = listingManager.createListing(P, 1, COMPLETION_WINDOW, "Campaign", "Proof run");
        g[G_CREATE] = t - gasleft();
        vm.stopPrank();

        vm.prank(buyer);
        t = gasleft();
        settlement.pay{value: P}(listingId, 0);
        g[G_PAY] = t - gasleft();

        // Branch the state: time the honest ending, then rewind and time the dispute ending, so both are
        // measured from the same starting point rather than one of them from a state the other mutated.
        uint256 snap = vm.snapshotState();
        vm.prank(buyer);
        t = gasleft();
        listingManager.confirmCompletion(listingId, 0);
        g[G_CONFIRM] = t - gasleft();
        vm.revertToState(snap);

        uint256 marketId = disputeManager.marketIdOf(listingId, 0, 1);

        vm.prank(buyer);
        t = gasleft();
        disputeManager.fundGuiltySide{value: P / 2}(listingId, 0);
        g[G_FUND] = t - gasleft();

        // 3P of shares, not 2P: the sweep above measured the 93% threshold at ~2.587P of shares, and a buy
        // that stops short leaves pokeSettlement reverting with ConditionsNotYetMet.
        vm.prank(buyer);
        t = gasleft();
        spectralMarket.buy{value: 10 * P}(marketId, SpectralMarket.Side.Guilty, 3 * P);
        g[G_BUY] = t - gasleft();

        (uint256 pGuilty,) = spectralMarket.currentPrice(marketId);
        assertGe(pGuilty, THRESHOLD, "gas run must actually cross the threshold");

        vm.warp(block.timestamp + 1 hours + 1);
        t = gasleft();
        settlementConditions.pokeSettlement(marketId);
        g[G_POKE] = t - gasleft();

        t = gasleft();
        disputeManager.finalizeDispute(listingId, 0);
        g[G_FINALIZE] = t - gasleft();

        vm.prank(buyer);
        t = gasleft();
        spectralMarket.redeem(marketId);
        g[G_REDEEM] = t - gasleft();
    }

    /// @dev Runs one full staged dispute at price `P` and prints the capital profile. Every actor is funded
    ///      generously and the *balance deltas* are what get reported, so the numbers reflect what the
    ///      contracts actually charged rather than what was sent.
    function _measure(uint256 P) internal {
        address seller = makeAddr(string(abi.encodePacked("cost-seller-", vm.toString(P))));
        address buyer = makeAddr(string(abi.encodePacked("cost-buyer-", vm.toString(P))));
        // Fund proportionally to P — a flat allowance silently starves the largest size and reads as a
        // protocol revert rather than a harness limit.
        vm.deal(seller, 50 * P);
        vm.deal(buyer, 50 * P);

        // ── Honest-path capital: the seller's bond and the buyer's payment ──
        vm.startPrank(seller);
        integrityBond.deposit{value: (3 * P) / 2}(); // exactly createListing's 1.5P lock — the true minimum
        uint256 listingId = listingManager.createListing(P, 1, COMPLETION_WINDOW, "", "");
        vm.stopPrank();

        vm.prank(buyer);
        settlement.pay{value: P}(listingId, 0);

        uint256 marketId = disputeManager.marketIdOf(listingId, 0, 1);

        // ── Dispute path: 0.5P opens the market, then the minimum buy that crosses 93% ──
        vm.prank(buyer);
        disputeManager.fundGuiltySide{value: P / 2}(listingId, 0);

        uint256 pushShares = _minSharesToCrossThreshold(marketId, buyer, P);
        uint256 buyerBeforePush = buyer.balance;
        vm.prank(buyer);
        spectralMarket.buy{value: 10 * P}(marketId, SpectralMarket.Side.Guilty, pushShares);
        uint256 pushCost = buyerBeforePush - buyer.balance;

        (uint256 pGuilty,) = spectralMarket.currentPrice(marketId);
        assertGe(pGuilty, THRESHOLD, "measured push must actually cross the threshold");

        // ── Resolve, finalize, redeem — measure what comes back ──
        vm.warp(block.timestamp + 1 hours + 1);
        settlementConditions.pokeSettlement(marketId);
        disputeManager.finalizeDispute(listingId, 0);

        uint256 buyerBeforeRedeem = buyer.balance;
        vm.prank(buyer);
        spectralMarket.redeem(marketId);
        uint256 redeemed = buyer.balance - buyerBeforeRedeem;

        // Peak capital is what has to be liquid at once across every role, before anything unwinds.
        uint256 peak = ((3 * P) / 2) + P + (P / 2) + pushCost;

        // Guards against a silent precision collapse at small P. Without these the sweep would happily print a
        // quietly-wrong ratio for a size where rounding had eaten the position, and the campaign budget would
        // be derived from a number that no longer described the protocol. 4.966 is the ratio measured at
        // P = 0.1/1/10 xDAI; a 2% band is far tighter than any real drift and far looser than LMSR noise.
        assertGt(redeemed, 0, "winner must redeem something");
        assertApproxEqRel((peak * 1e18) / P, 4.966e18, 0.02e18, "peak/P must stay scale-free");

        console.log("");
        console.log("=== P = %s wei ===", P);
        console.log("  seller IB deposit (1.5P, fully locked)        : %s", (3 * P) / 2);
        console.log("  buyer payment                                 : %s", P);
        console.log("  guilty-side funding (0.5P)                    : %s", P / 2);
        console.log("  push to 93%% - shares bought                  : %s", pushShares);
        console.log("  push to 93%% - ACTUAL COST                    : %s", pushCost);
        console.log("  -> push cost as a multiple of P (x1e18)       : %s", (pushCost * 1e18) / P);
        console.log("  PEAK CAPITAL NEEDED AT ONCE                   : %s", peak);
        console.log("  -> peak as a multiple of P (x1e18)            : %s", (peak * 1e18) / P);
        console.log("  winner redeemed back                          : %s", redeemed);
    }

    /// @dev Binary-searches the smallest share quantity whose purchase leaves the Guilty price at or above the
    ///      93% threshold, reverting the fork between probes so each trial starts from the same market state.
    ///      Upper bound of 10P mirrors the honest-lifecycle test's known-sufficient overshoot.
    function _minSharesToCrossThreshold(uint256 marketId, address buyer, uint256 P) internal returns (uint256 shares) {
        uint256 lo = 0;
        uint256 hi = 10 * P;
        while (hi - lo > P / 10_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(buyer);
            spectralMarket.buy{value: 10 * P}(marketId, SpectralMarket.Side.Guilty, mid);
            (uint256 pGuilty,) = spectralMarket.currentPrice(marketId);
            vm.revertToState(snap);
            if (pGuilty >= THRESHOLD) hi = mid;
            else lo = mid;
        }
        return hi;
    }
}
