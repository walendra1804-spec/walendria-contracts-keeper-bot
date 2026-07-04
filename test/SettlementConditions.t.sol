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

    // ── Condition A: instant threshold ─────────────────────────────────────────────────────────────────────────

    function test_ConditionA_GuiltyCrossing90PercentResolvesInstantly() public {
        uint256 sharesToReach92 = _sharesToReachPrice(B, 0.92e18);

        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach92);

        assertEq(market.sharesOf(MARKET_ID, SpectralMarket.Side.Guilty, buyer), sharesToReach92, "trade still applied");

        (bool resolved, SpectralMarket.Side winningSide) = _isResolved(MARKET_ID);
        assertTrue(resolved);
        assertEq(uint256(winningSide), uint256(SpectralMarket.Side.Guilty));

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.MarketAlreadyResolved.selector, MARKET_ID));
        market.buy{value: 1 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e15);
    }

    function test_ConditionA_InnocentCrossing90PercentResolvesInstantly() public {
        // Sell down the seller's own Innocent-side price by buying enough Guilty first would flip Guilty, not
        // Innocent - instead buy Innocent directly to push its own price up.
        uint256 sharesToReach92 = _sharesToReachPrice(B, 0.92e18);

        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Innocent, sharesToReach92);

        (bool resolved, SpectralMarket.Side winningSide) = _isResolved(MARKET_ID);
        assertTrue(resolved);
        assertEq(uint256(winningSide), uint256(SpectralMarket.Side.Innocent));
    }

    function test_ConditionA_DoesNotResolveWhenPriceStaysBelow90Percent() public {
        uint256 sharesToReach70 = _sharesToReachPrice(B, 0.7e18);

        vm.prank(buyer);
        market.buy{value: 5 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach70);

        (bool resolved,) = _isResolved(MARKET_ID);
        assertFalse(resolved);
    }

    // ── Condition B: cumulative stability ──────────────────────────────────────────────────────────────────────

    function test_ConditionB_ResolvesAfterCumulativeThreeHoursAbove87Percent() public {
        uint256 sharesToReach88 = _sharesToReachPrice(B, 0.88e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach88);

        (bool resolvedBefore,) = _isResolved(MARKET_ID);
        assertFalse(resolvedBefore, "88% alone should not trigger Condition A, and no cumulative time has passed yet");

        vm.warp(block.timestamp + 3 hours + 1);
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9); // tiny trade just to checkpoint

        (bool resolvedAfter, SpectralMarket.Side winningSide) = _isResolved(MARKET_ID);
        assertTrue(resolvedAfter);
        assertEq(uint256(winningSide), uint256(SpectralMarket.Side.Guilty));
    }

    function test_ConditionB_DoesNotResolveBeforeThreeHoursElapsed() public {
        uint256 sharesToReach88 = _sharesToReachPrice(B, 0.88e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach88);

        vm.warp(block.timestamp + 2 hours + 59 minutes);
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9);

        (bool resolved,) = _isResolved(MARKET_ID);
        assertFalse(resolved);
    }

    /// @notice "The timer pauses below 87% - it does not reset" (Section 2.6.5). Accumulates 2h above 87%, dips
    ///         below for 2h (must not count), then resumes above 87% for just over 1h - total counted time
    ///         crosses 3h (2h + 1h+1s), even though only ~3h+1s of real time elapsed *above* the threshold out of
    ///         ~5h+1s total elapsed. A naive reset-on-dip implementation would never reach 3h counted this way.
    function test_ConditionB_PausesRatherThanResetsOnADipBelowThreshold() public {
        uint256 sharesToReach88 = _sharesToReachPrice(B, 0.88e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach88);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9); // checkpoint: +2h to cumulative

        // Dip: sell back down to well below 87% (e.g. 50%) by selling most of the Guilty position bought above.
        uint256 heldByBuyer = market.sharesOf(MARKET_ID, SpectralMarket.Side.Guilty, buyer);
        vm.prank(buyer);
        market.sell(MARKET_ID, SpectralMarket.Side.Guilty, heldByBuyer - 1e9, 0);
        (uint256 pGuiltyAfterDip,) = market.currentPrice(MARKET_ID);
        assertLt(pGuiltyAfterDip, 0.87e18, "must genuinely dip below 87% for this test to be meaningful");

        vm.warp(block.timestamp + 2 hours); // 2h while BELOW 87% - must not count
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9); // checkpoint: dip credited 0

        (uint256 cumulativeGuiltyMid,,,,,) = conditions.tracking(MARKET_ID);
        assertEq(cumulativeGuiltyMid, 2 hours, "the 2h spent below 87% must not have been credited");

        // Resume: buy back above 87%.
        uint256 sharesToReach88Again = _sharesToReachPrice(B, 0.88e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach88Again);

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9); // checkpoint: +1h+1s -> crosses 3h

        (bool resolved, SpectralMarket.Side winningSide) = _isResolved(MARKET_ID);
        assertTrue(resolved, "2h + 1h+1s of real (non-contiguous) time above 87% must still cross the 3h threshold");
        assertEq(uint256(winningSide), uint256(SpectralMarket.Side.Guilty));
    }

    // ── pokeSettlement ─────────────────────────────────────────────────────────────────────────────────────────

    function test_PokeSettlementResolvesWithZeroFurtherTradesAfterThresholdCrossing() public {
        uint256 sharesToReach88 = _sharesToReachPrice(B, 0.88e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach88);

        vm.warp(block.timestamp + 3 hours + 1);

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
        uint256 sharesToReach92 = _sharesToReachPrice(B, 0.92e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach92); // auto-resolves via A

        vm.expectRevert(abi.encodeWithSelector(SettlementConditions.MarketAlreadyResolved.selector, MARKET_ID));
        conditions.pokeSettlement(MARKET_ID);
    }

    function test_PokeSettlementPaysFullBountyToCaller() public {
        conditions.fundBounty{value: 1 ether}();

        uint256 sharesToReach88 = _sharesToReachPrice(B, 0.88e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach88);
        vm.warp(block.timestamp + 3 hours + 1);

        address poker = makeAddr("poker");
        uint256 before = poker.balance;
        vm.prank(poker);
        conditions.pokeSettlement(MARKET_ID);

        assertEq(poker.balance - before, POKE_BOUNTY);
        assertEq(conditions.bountyPool(), 1 ether - POKE_BOUNTY);
    }

    function test_PokeSettlementPaysPartialBountyWithoutBlockingResolution() public {
        conditions.fundBounty{value: POKE_BOUNTY / 2}();

        uint256 sharesToReach88 = _sharesToReachPrice(B, 0.88e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach88);
        vm.warp(block.timestamp + 3 hours + 1);

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
        uint256 sharesToReach88 = _sharesToReachPrice(B, 0.88e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach88);
        vm.warp(block.timestamp + 3 hours + 1);

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

        uint256 sharesToReach88 = _sharesToReachPrice(B, 0.88e18);
        vm.prank(buyer);
        market.buy{value: 10 ether}(MARKET_ID, SpectralMarket.Side.Guilty, sharesToReach88);
        vm.warp(block.timestamp + 3 hours + 1);
        vm.prank(buyer);
        market.buy{value: 0.01 ether}(MARKET_ID, SpectralMarket.Side.Guilty, 1e9); // resolves market 1 via B

        (bool resolved1,) = _isResolved(MARKET_ID);
        (bool resolved2,) = _isResolved(2);
        assertTrue(resolved1, "market 1 should have resolved");
        assertFalse(resolved2, "market 2's tracking must be untouched by market 1's activity");
    }
}
