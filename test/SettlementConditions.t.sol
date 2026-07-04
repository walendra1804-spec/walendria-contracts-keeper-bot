// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SD59x18, sd, UNIT} from "prb-math/SD59x18.sol";
import {SpectralMarket} from "../src/SpectralMarket.sol";
import {SettlementConditions} from "../src/SettlementConditions.sol";
import {ISettlementConditionsHook} from "../src/ISettlementConditionsHook.sol";

contract SettlementConditionsTest is Test {
    SpectralMarket internal market;
    SettlementConditions internal conditions;

    address internal controller = makeAddr("controller");
    address internal seller = makeAddr("seller");
    address internal guiltyFunder = makeAddr("guiltyFunder");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant P = 1 ether;
    uint256 internal constant B = 1 ether; // b = 1 * P, locked parameter
    uint256 internal constant HALF_P = 0.5 ether;
    uint256 internal constant POKE_BOUNTY = 0.01 ether;
    uint256 internal constant MARKET_ID = 1;

    function setUp() public {
        // SettlementConditions needs SpectralMarket's address (immutable) and SpectralMarket needs
        // SettlementConditions' address (immutable, as its checkpoint hook) - the same circular-constructor
        // pattern already resolved for IntegrityBond<->ListingManager (Phase 3) and ListingManager<->Settlement
        // (Phase 4), via CREATE nonce prediction.
        uint256 nonce = vm.getNonce(address(this));
        address predictedMarket = vm.computeCreateAddress(address(this), nonce + 1);
        conditions = new SettlementConditions(SpectralMarket(predictedMarket), POKE_BOUNTY);

        // SettlementConditions must itself be a registered controller: pokeSettlement calls
        // spectralMarket.resolveMarket(...) directly, which is onlyController-gated (Section 2.6.8's poke
        // mechanism is exactly this kind of controller action, alongside DisputeManager's future mutualClose).
        address[] memory controllers = new address[](2);
        controllers[0] = controller;
        controllers[1] = address(conditions);
        market = new SpectralMarket(controllers, ISettlementConditionsHook(address(conditions)), address(0));
        assertEq(address(market), predictedMarket, "CREATE nonce prediction drifted");

        vm.deal(controller, 1000 ether);
        vm.deal(guiltyFunder, 1000 ether);
        vm.deal(seller, 1000 ether);
        vm.deal(buyer, 1000 ether);

        address[] memory funders = new address[](1);
        funders[0] = guiltyFunder;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;
        vm.prank(controller);
        market.openMarket{value: P}(MARKET_ID, B, funders, amounts, _singleton(seller), _singletonAmt(HALF_P));
    }

    /// @dev delta = b * ln(p / (1-p)): the Guilty-share quantity that pushes price from the market's symmetric
    ///      50/50 opening (Section 2.6.1) to `priceWad`, buying only on the Guilty side - price depends only on
    ///      (qGuilty - qInnocent)/b (a sigmoid), so this holds starting from the post-injection qGuilty=qInnocent=P
    ///      state exactly as it would from (0,0) (same derivation LMSRMathTest uses for the H(p) table).
    function _sharesToReachPrice(uint256 bWad, uint256 priceWad) internal pure returns (uint256) {
        SD59x18 b = sd(int256(bWad));
        SD59x18 p = sd(int256(priceWad));
        SD59x18 delta = b * (p / (UNIT - p)).ln();
        return uint256(SD59x18.unwrap(delta));
    }

    function _isResolved(uint256 marketId) internal view returns (bool resolved, SpectralMarket.Side winningSide) {
        (,,,,, resolved, winningSide) = market.markets(marketId);
    }

    function _singleton(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _singletonAmt(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    // ── Constructor ────────────────────────────────────────────────────────────────────────────────────────────

    function test_ConstructorSetsImmutablesAndInitialBountyPool() public view {
        assertEq(address(conditions.spectralMarket()), address(market));
        assertEq(conditions.pokeBounty(), POKE_BOUNTY);
        assertEq(conditions.bountyPool(), 0);
    }

    // ── Access control ─────────────────────────────────────────────────────────────────────────────────────────

    function test_CheckpointRevertsForNonSpectralMarketCaller() public {
        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.NotSpectralMarket.selector, address(this)));
        conditions.checkpoint(MARKET_ID, 1e18, 0);
    }

    function test_AttackerCannotFakeResolutionViaDirectCheckpointCall() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.NotSpectralMarket.selector, attacker));
        conditions.checkpoint(MARKET_ID, 1e18, 0); // would claim 100% Guilty price if this succeeded

        (bool resolved,) = _isResolved(MARKET_ID);
        assertFalse(resolved, "market must remain untouched by the rejected fake checkpoint");
    }

    // ── No instant resolution at any price ─────────────────────────────────────────────────────────────────────
    // A prior revision resolved a case the instant either side's price touched 90% in a single transaction. This
    // let one sufficiently capitalized trade force an irreversible resolution with zero reaction time for anyone
    // else, no matter how transient the crossing was - the exact one-shot manipulation this revision closes.
    // There is no longer any price, however high, that resolves a case by itself; only accumulated time above
    // CUMULATIVE_THRESHOLD (tracked below) can.

    function test_GuiltyCrossing95PercentDoesNotResolveInstantly() public {
        uint256 sharesToReach95 = _sharesToReachPrice(B, 0.95e18);

        vm.prank(buyer);
        market.buy{value: 20 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach95);

        assertEq(market.sharesOf(MARKET_ID, SpectralMarket.Side.Guilty, buyer), sharesToReach95, "trade still applied");

        (bool resolved,) = _isResolved(MARKET_ID);
        assertFalse(resolved, "no price, however high, resolves a case in the same transaction it is reached");
    }

    function test_InnocentCrossing95PercentDoesNotResolveInstantly() public {
        uint256 sharesToReach95 = _sharesToReachPrice(B, 0.95e18);

        vm.prank(buyer);
        market.buy{value: 20 ether}(MARKET_ID, SpectralMarket.Side.Innocent, sharesToReach95);

        (bool resolved,) = _isResolved(MARKET_ID);
        assertFalse(resolved);
    }

    /// @notice Direct regression test for the explicit design requirement: even a single trade that pushes price
    ///         to 99% or effectively 100% must still wait out the full cumulative window - there is no price high
    ///         enough to force an instant resolution.
    function test_Crossing99PercentStillDoesNotResolveInstantly() public {
        uint256 sharesToReach99 = _sharesToReachPrice(B, 0.99e18);

        vm.prank(buyer);
        market.buy{value: 50 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach99);

        (uint256 pGuilty,) = market.currentPrice(MARKET_ID);
        // >= 0.98e18 rather than the nominal 0.99e18 target: PRBMath's ln/exp fixed-point rounding can land a
        // handful of wei under the exact target, which is irrelevant to what this test actually checks (a price
        // very close to 100% still does not resolve instantly).
        assertGe(pGuilty, 0.98e18, "trade must have genuinely reached ~99% for this test to be meaningful");

        (bool resolved,) = _isResolved(MARKET_ID);
        assertFalse(resolved, "99% must not resolve instantly - only the cumulative timer may resolve a case");
    }

    /// @notice The other half of the same guarantee: crossing 99% in one shot still only starts the same
    ///         cumulative clock every smaller crossing does - it resolves after 1 hour, not before and not
    ///         instantly.
    function test_Crossing99PercentEventuallyResolvesOnlyAfterCumulativeOneHour() public {
        uint256 sharesToReach99 = _sharesToReachPrice(B, 0.99e18);
        vm.prank(buyer);
        market.buy{value: 50 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach99);

        vm.warp(block.timestamp + 59 minutes);
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9);
        (bool resolvedEarly,) = _isResolved(MARKET_ID);
        assertFalse(resolvedEarly, "still short of the 1-hour cumulative requirement");

        vm.warp(block.timestamp + 2 minutes);
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9);
        (bool resolvedAfter, SpectralMarket.Side winningSide) = _isResolved(MARKET_ID);
        assertTrue(resolvedAfter, "1 hour cumulative above 93% must resolve, exactly as any smaller crossing would");
        assertEq(uint256(winningSide), uint256(SpectralMarket.Side.Guilty));
    }

    function test_PriceBelow93PercentNeverResolves() public {
        uint256 sharesToReach70 = _sharesToReachPrice(B, 0.7e18);

        vm.prank(buyer);
        market.buy{value: 5 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach70);

        (bool resolved,) = _isResolved(MARKET_ID);
        assertFalse(resolved);
    }

    // ── Cumulative stability (the sole resolution condition) ───────────────────────────────────────────────────

    function test_ResolvesAfterCumulativeOneHourAbove93Percent() public {
        uint256 sharesToReach94 = _sharesToReachPrice(B, 0.94e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach94);

        (bool resolvedBefore,) = _isResolved(MARKET_ID);
        assertFalse(resolvedBefore, "94% alone must not resolve instantly, and no cumulative time has passed yet");

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9); // tiny trade just to checkpoint

        (bool resolvedAfter, SpectralMarket.Side winningSide) = _isResolved(MARKET_ID);
        assertTrue(resolvedAfter);
        assertEq(uint256(winningSide), uint256(SpectralMarket.Side.Guilty));
    }

    function test_DoesNotResolveBeforeOneHourElapsed() public {
        uint256 sharesToReach94 = _sharesToReachPrice(B, 0.94e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach94);

        vm.warp(block.timestamp + 59 minutes);
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9);

        (bool resolved,) = _isResolved(MARKET_ID);
        assertFalse(resolved);
    }

    /// @notice "The timer pauses below 93% - it does not reset" (Section 2.6.5). Accumulates 40 minutes above
    ///         93%, dips below for 30 minutes (must not count), then resumes above 93% for just over 20 minutes -
    ///         total counted time crosses 1 hour (40min + 20min+1s), even though additional real time elapsed
    ///         below the threshold in between. A naive reset-on-dip implementation would never reach 1 hour
    ///         counted this way.
    function test_PausesRatherThanResetsOnADipBelowThreshold() public {
        uint256 sharesToReach94 = _sharesToReachPrice(B, 0.94e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach94);

        vm.warp(block.timestamp + 40 minutes);
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9); // checkpoint: +40min to cumulative

        // Dip: sell back down to well below 93% (e.g. 50%) by selling most of the Guilty position bought above.
        uint256 heldByBuyer = market.sharesOf(MARKET_ID, SpectralMarket.Side.Guilty, buyer);
        vm.prank(buyer);
        market.sell(MARKET_ID, SpectralMarket.Side.Guilty, heldByBuyer - 1e9, 0);
        (uint256 pGuiltyAfterDip,) = market.currentPrice(MARKET_ID);
        assertLt(pGuiltyAfterDip, 0.93e18, "must genuinely dip below 93% for this test to be meaningful");

        vm.warp(block.timestamp + 30 minutes); // 30min while BELOW 93% - must not count
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9); // checkpoint: dip credited 0

        (uint256 cumulativeGuiltyMid,,,,,) = conditions.tracking(MARKET_ID);
        assertEq(cumulativeGuiltyMid, 40 minutes, "the 30min spent below 93% must not have been credited");

        // Resume: buy back above 93%.
        uint256 sharesToReach94Again = _sharesToReachPrice(B, 0.94e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach94Again);

        vm.warp(block.timestamp + 20 minutes + 1);
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9); // checkpoint: +20min+1s -> crosses 1h

        (bool resolved, SpectralMarket.Side winningSide) = _isResolved(MARKET_ID);
        assertTrue(resolved, "40min + 20min+1s of real (non-contiguous) time above 93% must still cross 1 hour");
        assertEq(uint256(winningSide), uint256(SpectralMarket.Side.Guilty));
    }

    // ── pokeSettlement ─────────────────────────────────────────────────────────────────────────────────────────

    function test_PokeSettlementResolvesWithZeroFurtherTradesAfterThresholdCrossing() public {
        uint256 sharesToReach94 = _sharesToReachPrice(B, 0.94e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach94);

        vm.warp(block.timestamp + 1 hours + 1);

        address stranger = makeAddr("pokeStranger");
        vm.prank(stranger);
        conditions.pokeSettlement(MARKET_ID);

        (bool resolved, SpectralMarket.Side winningSide) = _isResolved(MARKET_ID);
        assertTrue(resolved);
        assertEq(uint256(winningSide), uint256(SpectralMarket.Side.Guilty));
    }

    function test_PokeSettlementRevertsWhenConditionsNotYetMet() public {
        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.ConditionsNotYetMet.selector, MARKET_ID));
        conditions.pokeSettlement(MARKET_ID);
    }

    function test_PokeSettlementRevertsForNeverOpenedMarket() public {
        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.MarketNotOpen.selector, 999));
        conditions.pokeSettlement(999);
    }

    function test_PokeSettlementRevertsForAlreadyResolvedMarket() public {
        uint256 sharesToReach95 = _sharesToReachPrice(B, 0.95e18);
        vm.prank(buyer);
        market.buy{value: 20 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach95);
        vm.warp(block.timestamp + 1 hours + 1);
        conditions.pokeSettlement(MARKET_ID); // resolves it

        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.MarketAlreadyResolved.selector, MARKET_ID));
        conditions.pokeSettlement(MARKET_ID);
    }

    function test_PokeSettlementPaysFullBountyToCaller() public {
        conditions.fundBounty{value: 1 ether}();

        uint256 sharesToReach94 = _sharesToReachPrice(B, 0.94e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach94);
        vm.warp(block.timestamp + 1 hours + 1);

        address poker = makeAddr("poker");
        uint256 before = poker.balance;
        vm.prank(poker);
        conditions.pokeSettlement(MARKET_ID);

        assertEq(poker.balance - before, POKE_BOUNTY);
        assertEq(conditions.bountyPool(), 1 ether - POKE_BOUNTY);
    }

    function test_PokeSettlementPaysPartialBountyWithoutBlockingResolution() public {
        conditions.fundBounty{value: POKE_BOUNTY / 2}();

        uint256 sharesToReach94 = _sharesToReachPrice(B, 0.94e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach94);
        vm.warp(block.timestamp + 1 hours + 1);

        address poker = makeAddr("poker2");
        uint256 before = poker.balance;
        vm.prank(poker);
        conditions.pokeSettlement(MARKET_ID);

        assertEq(poker.balance - before, POKE_BOUNTY / 2, "should pay whatever is available, not revert");
        assertEq(conditions.bountyPool(), 0);
        (bool resolved,) = _isResolved(MARKET_ID);
        assertTrue(resolved, "resolution must not be blocked by insufficient bounty funds");
    }

    function test_PokeSettlementResolvesWithZeroBountyWhenPoolEmpty() public {
        uint256 sharesToReach94 = _sharesToReachPrice(B, 0.94e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach94);
        vm.warp(block.timestamp + 1 hours + 1);

        conditions.pokeSettlement(MARKET_ID); // bountyPool is 0 (never funded) - must still succeed

        (bool resolved,) = _isResolved(MARKET_ID);
        assertTrue(resolved);
    }

    // ── fundBounty ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_FundBountyIsPermissionlessAndAccumulates() public {
        address anyone = makeAddr("anyone");
        vm.deal(anyone, 5 ether);

        vm.prank(anyone);
        conditions.fundBounty{value: 2 ether}();
        assertEq(conditions.bountyPool(), 2 ether);

        conditions.fundBounty{value: 1 ether}();
        assertEq(conditions.bountyPool(), 3 ether);
    }

    // ── Multi-market isolation ─────────────────────────────────────────────────────────────────────────────────

    function test_TrackingStateIsIsolatedPerMarket() public {
        // Open a second, independent market.
        address[] memory funders = new address[](1);
        funders[0] = guiltyFunder;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;
        vm.prank(controller);
        market.openMarket{value: P}(2, B, funders, amounts, _singleton(seller), _singletonAmt(HALF_P));

        uint256 sharesToReach94 = _sharesToReachPrice(B, 0.94e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach94);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9); // resolves market 1

        (bool resolved1,) = _isResolved(MARKET_ID);
        (bool resolved2,) = _isResolved(2);
        assertTrue(resolved1, "market 1 should have resolved");
        assertFalse(resolved2, "market 2's tracking must be untouched by market 1's activity");
    }
}
