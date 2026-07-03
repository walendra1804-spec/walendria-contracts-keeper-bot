// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SD59x18, sd, UNIT, ZERO} from "prb-math/SD59x18.sol";
import {LMSRMath} from "../src/LMSRMath.sol";

/// @title LMSRMath H(p) Boundary Table Tests
/// @notice Validates LMSRMath.sol in total isolation against the whitepaper's own worked numbers (Section 2.6.9,
///         "The 27") before any other contract is allowed to depend on it — Phase 1 of the build strategy.
///
///         H(p) = b * [ln(1 + p/(1-p)) - ln(2)] is not hand-checked as a separate formula: it is derived here as
///         costOfTrade(0, 0, qG, 0, b), where qG = b * ln(p / (1-p)) is the exact Guilty-share quantity that
///         pushes price from the market's symmetric 50/50 opening (Section 2.6.1) to p, buying only on the
///         Guilty side — the single-actor, uncontested-manipulation scenario the boundary theorem describes.
///         That means every row below exercises the actual cost()/price() functions SpectralMarket.sol will
///         call later, not a reimplementation of the closed-form formula.
///
///         qG and the expected H(p) for each row were computed independently in Node.js (double-precision
///         Math.log — a different implementation from PRBMath's fixed-point log2-based algorithm), then
///         cross-checked by hand against the exactly-known constants ln(2) = 0.69314718055994530942 and
///         ln(10) = 2.30258509299404568402. This is a genuine external check, not a self-consistency check
///         against the library under test.
contract LMSRMathTest is Test {
    SD59x18 internal constant B = UNIT; // b = 1 * P, normalized to P = 1 (Section 2.6.9's worked example table)

    /// @dev Max allowed deviation between LMSRMath's fixed-point result and the independently-derived reference
    ///      value, as a fraction of 1e18 (1e9 raw = 1e-9 = 0.0000001%). PRBMath's own docs note that log2 (and
    ///      therefore ln) "results are not perfectly accurate to the last decimal" — this tolerance is far
    ///      tighter than the whitepaper table's own 3-decimal-place rounding (1e-3 relative), while still
    ///      comfortably covering PRBMath's actual fixed-point rounding error for inputs in this range.
    uint256 internal constant REL_TOL = 1e9;

    // ── Section 2.6.1 sanity: the market opens exactly 50/50 with no order-dependent bias ────────────────────

    function test_Price_SymmetricStateIsFiftyFifty() public pure {
        (SD59x18 pG, SD59x18 pI) = LMSRMath.price(ZERO, ZERO, B);
        assertEq(SD59x18.unwrap(pG), 0.5e18, "pG should be exactly 0.5 at qG=qI=0");
        assertEq(SD59x18.unwrap(pI), 0.5e18, "pI should be exactly 0.5 at qG=qI=0");
    }

    function test_Cost_SymmetricStateIsBLnTwo() public pure {
        // C(0,0) = b * ln(2) = 0.693147180559945309 * b
        SD59x18 c = LMSRMath.cost(ZERO, ZERO, B);
        assertApproxEqRel(SD59x18.unwrap(c), 693147180559945309, REL_TOL);
    }

    // ── Section 2.6.9 H(p) table — every published row, including both deployed thresholds ───────────────────

    function test_Hp_70pct() public pure {
        _assertHp(847297860387203456, 510825623765990611); // H = 0.511P
    }

    function test_Hp_75pct() public pure {
        _assertHp(1098612288668109568, 693147180559945286); // H = 0.693P
    }

    function test_Hp_80pct() public pure {
        _assertHp(1386294361119890688, 916290731874155218); // H = 0.916P
    }

    function test_Hp_85pct() public pure {
        _assertHp(1734601055388106240, 1203972804325935897); // H = 1.204P
    }

    /// @notice Condition B (cumulative), Section 2.6.5 — deployed value. This is the concrete regression test
    ///         the build strategy calls for: it must fail loudly if anyone ever lowers the threshold again
    ///         without re-deriving H(p) against the 0.995P sale-proceeds floor (Section 2.4, Section 2.6.9).
    function test_Hp_87pct_ConditionB_DeployedValue() public pure {
        _assertHp(1900958761193047040, 1347073647966609222); // H = 1.347P
    }

    /// @notice Condition A (instant), Section 2.6.5 — deployed value.
    function test_Hp_90pct_ConditionA_DeployedValue() public pure {
        _assertHp(2197224577336219648, 1609437912434100504); // H = 1.609P
    }

    function test_Hp_95pct() public pure {
        _assertHp(2944438979166439424, 2302585092994044569); // H = 2.303P
    }

    function test_Hp_99pct() public pure {
        _assertHp(4595119850134588928, 3912023005428145517); // H = 3.912P
    }

    /// @dev qG = b * ln(p / (1-p)) is the Guilty-only quantity that pushes price from 50/50 to p starting from
    ///      the empty market (Section 2.6.1's joint opening state). H(p) := costOfTrade(0, 0, qG, 0, b).
    function _assertHp(int256 qGRaw, int256 expectedHRaw) internal pure {
        SD59x18 qG = SD59x18.wrap(qGRaw);
        SD59x18 h = LMSRMath.costOfTrade(ZERO, ZERO, qG, ZERO, B);
        assertApproxEqRel(SD59x18.unwrap(h), expectedHRaw, REL_TOL);
    }

    // ── Cross-check: the same qG that produces H(p) also independently reproduces price ≈ p ──────────────────

    function test_Price_AtHp87_MatchesEightySevenPercent() public pure {
        SD59x18 qG = SD59x18.wrap(1900958761193047040);
        (SD59x18 pG,) = LMSRMath.price(qG, ZERO, B);
        assertApproxEqRel(SD59x18.unwrap(pG), 0.87e18, REL_TOL);
    }

    function test_Price_AtHp90_MatchesNinetyPercent() public pure {
        SD59x18 qG = SD59x18.wrap(2197224577336219648);
        (SD59x18 pG,) = LMSRMath.price(qG, ZERO, B);
        assertApproxEqRel(SD59x18.unwrap(pG), 0.9e18, REL_TOL);
    }

    // ── Both directions of buy/sell (Phase 1 scope) ───────────────────────────────────────────────────────────

    function test_CostOfTrade_BuyGuiltyCostsPositiveAmount() public pure {
        SD59x18 c = LMSRMath.costOfTrade(ZERO, ZERO, sd(0.5e18), ZERO, B);
        assertGt(SD59x18.unwrap(c), 0);
    }

    function test_CostOfTrade_BuyInnocentCostsPositiveAmount() public pure {
        SD59x18 c = LMSRMath.costOfTrade(ZERO, ZERO, ZERO, sd(0.5e18), B);
        assertGt(SD59x18.unwrap(c), 0);
    }

    function test_CostOfTrade_SellingExactlyUndoesABuy() public pure {
        // Buying dq, then selling dq from the resulting state, must exactly cancel (round-trip identity).
        // This exercises the "sell" direction against the state the "buy" direction actually produced, not a
        // sign-flip assumption.
        SD59x18 dq = sd(0.5e18);
        SD59x18 buyCost = LMSRMath.costOfTrade(ZERO, ZERO, dq, ZERO, B);
        SD59x18 sellProceeds = LMSRMath.costOfTrade(dq, ZERO, -dq, ZERO, B);
        assertEq(SD59x18.unwrap(buyCost), -SD59x18.unwrap(sellProceeds));
    }

    function test_CostOfTrade_MatchesRawCostDifference() public pure {
        SD59x18 qG0 = sd(0.2e18);
        SD59x18 qI0 = sd(0.1e18);
        SD59x18 dqG = sd(0.3e18);
        SD59x18 dqI = sd(-0.05e18); // selling Innocent while buying Guilty, in one joint trade
        SD59x18 viaHelper = LMSRMath.costOfTrade(qG0, qI0, dqG, dqI, B);
        SD59x18 viaManualDiff = LMSRMath.cost(qG0 + dqG, qI0 + dqI, B) - LMSRMath.cost(qG0, qI0, B);
        assertEq(SD59x18.unwrap(viaHelper), SD59x18.unwrap(viaManualDiff));
    }

    // ── Section 2.6.4 precondition: price stays bounded in [0,1] and sums to exactly 1 ────────────────────────

    function testFuzz_PriceSumsToExactlyOneEvenAtExtremeInputs(int256 qGRaw, int256 qIRaw) public pure {
        // Bounded to q >= 0 - the real, reachable domain for the Spectral Market, where q_G/q_I are cumulative
        // shares outstanding and never go negative (Section 2.6.1: both start at 0 and only grow from
        // purchases). Within this domain exp(q/b) >= 1 always, so the two sides can never simultaneously
        // underflow to zero - but one side alone can still be pushed so far past the other that its share of
        // the price underflows to fixed-point-exact 0 (PRBMath's documented exp() behavior below ~-41.44 of
        // *relative* separation, not a bug in LMSRMath). What must still hold unconditionally even then: no
        // probability mass silently vanishes - pG + pI == UNIT exactly, by construction (pI := UNIT - pG).
        // Capped at 100 (< PRBMath's ~133.08 exp() input ceiling, Constants.uEXP_MAX_INPUT) so the call itself
        // never reverts on that unrelated guard - this test is about the zero-underflow edge, not the overflow one.
        SD59x18 qG = SD59x18.wrap(bound(qGRaw, 0, 100e18));
        SD59x18 qI = SD59x18.wrap(bound(qIRaw, 0, 100e18));
        (SD59x18 pG, SD59x18 pI) = LMSRMath.price(qG, qI, B);
        assertGe(SD59x18.unwrap(pG), 0);
        assertLe(SD59x18.unwrap(pG), 1e18);
        assertEq(SD59x18.unwrap(pG) + SD59x18.unwrap(pI), 1e18);
    }

    function testFuzz_PriceStrictlyBoundedWithinRepresentableDomain(int256 qGRaw, int256 qIRaw) public pure {
        // Within a domain where |qG/b - qI/b| stays safely under PRBMath's exp() underflow threshold (~41.44,
        // Constants.uEXP_MIN_THRESHOLD), the true probability is always representable at 18-decimal precision,
        // so price is provably strictly inside (0,1) here - matching the continuous-math guarantee Section
        // 2.6.4 relies on for the Boundary Theorem (Section 2.6.9: "price(q) < 1 for every finite q").
        SD59x18 qG = SD59x18.wrap(bound(qGRaw, -15e18, 15e18));
        SD59x18 qI = SD59x18.wrap(bound(qIRaw, -15e18, 15e18));
        (SD59x18 pG, SD59x18 pI) = LMSRMath.price(qG, qI, B);
        assertGt(SD59x18.unwrap(pG), 0);
        assertLt(SD59x18.unwrap(pG), 1e18);
        assertEq(SD59x18.unwrap(pG) + SD59x18.unwrap(pI), 1e18);
    }

    // ── b (liquidity parameter) must be strictly positive ─────────────────────────────────────────────────────
    //
    // LMSRMath's functions are `internal`, so a direct call from this test is inlined into the same call frame
    // rather than executed as a sub-call - `vm.expectRevert` can only intercept a revert one frame below the
    // cheatcode itself. Routing through `this.<fn>()` forces an actual external CALL, giving the revert a frame
    // the cheatcode can see.

    function test_RevertsWhenBIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(LMSRMath.InvalidLiquidityParameter.selector, ZERO));
        this.wrapCost(ZERO, ZERO, ZERO);
    }

    function test_RevertsWhenBIsNegative() public {
        SD59x18 negB = sd(-1e18);
        vm.expectRevert(abi.encodeWithSelector(LMSRMath.InvalidLiquidityParameter.selector, negB));
        this.wrapPrice(ZERO, ZERO, negB);
    }

    /// @notice Regression test for a genuine edge case found by testFuzz_PriceStrictlyBoundedWithinRepresentableDomain's
    ///         precursor during Phase 1 hardening: if q_G and q_I are simultaneously far enough below the
    ///         opening state that exp() underflows to fixed-point-exact 0 on *both* sides, the true relative
    ///         price is undefined at this fixed-point precision. Unreachable in real Spectral Market usage
    ///         (q_G, q_I never go negative, Section 2.6.1), but LMSRMath is a general-purpose library and must
    ///         fail loudly with a named error here rather than let a raw "division by zero" EVM panic leak out.
    function test_RevertsWhenBothSidesUnderflowSimultaneously() public {
        SD59x18 qG = sd(-100e18);
        SD59x18 qI = sd(-100e18);
        vm.expectRevert(abi.encodeWithSelector(LMSRMath.PriceUndefined.selector, qG, qI, B));
        this.wrapPrice(qG, qI, B);
    }

    function wrapCost(SD59x18 qG, SD59x18 qI, SD59x18 b) external pure returns (SD59x18) {
        return LMSRMath.cost(qG, qI, b);
    }

    function wrapPrice(SD59x18 qG, SD59x18 qI, SD59x18 b) external pure returns (SD59x18, SD59x18) {
        return LMSRMath.price(qG, qI, b);
    }
}
