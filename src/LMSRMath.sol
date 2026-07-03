// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SD59x18, UNIT} from "prb-math/SD59x18.sol";

/// @title LMSRMath
/// @notice Fixed-point cost and price functions for the Logarithmic Market Scoring Rule bonding curve that powers
///         the Spectral Market (Walendria Protocol "The 27", Section 2.6.4).
/// @dev All exponentiation and logarithm evaluation is delegated to PRBMath's audited SD59x18 `exp`/`ln`
///      (see lib/prb-math). This library performs no hand-rolled exp/ln of its own, per the build strategy's
///      highest-priority risk-reduction decision for this project.
///
///      q_G and q_I (outstanding Guilty/Innocent shares) and b (the liquidity parameter) are all SD59x18 values
///      expressed in the same unit as the transaction price P — e.g. b = 1 * P per Section 2.6.9's worked
///      example table. q_G/q_I are accepted as general (possibly negative) SD59x18 values: C(q) is mathematically
///      well-defined for any real q_G, q_I because exp() is strictly positive everywhere, so ln of the sum never
///      sees a non-positive argument. Enforcing that *outstanding shares* never actually go negative is a business
///      invariant of the caller (SpectralMarket.sol), not a precondition of the math itself.
library LMSRMath {
    /// @notice Thrown when the liquidity parameter b is not strictly positive.
    error InvalidLiquidityParameter(SD59x18 b);

    /// @notice Thrown when q_G/b and q_I/b are both far enough below zero that `exp()` underflows to
    ///         fixed-point-exact 0 on both sides at once (PRBMath's own documented behavior below its
    ///         ~-41.44 threshold), leaving the relative price undefined (0/0) at this fixed-point precision.
    ///         Unreachable for the Spectral Market's actual state space, where q_G and q_I never go negative
    ///         (Section 2.6.1) — this guards the general-purpose math function against the one genuine
    ///         mathematical singularity in `price()`, rather than letting it surface as a raw EVM panic.
    error PriceUndefined(SD59x18 qG, SD59x18 qI, SD59x18 b);

    /// @notice LMSR cost function (Section 2.6.4):
    ///
    ///         C(q_G, q_I) = b * ln(exp(q_G / b) + exp(q_I / b))
    ///
    /// @param qG Total Guilty shares outstanding.
    /// @param qI Total Innocent shares outstanding.
    /// @param b Liquidity parameter. Must be strictly positive.
    /// @return The market's total cost/liability at this state.
    function cost(SD59x18 qG, SD59x18 qI, SD59x18 b) internal pure returns (SD59x18) {
        _requirePositiveB(b);
        SD59x18 expG = (qG / b).exp();
        SD59x18 expI = (qI / b).exp();
        return b * (expG + expI).ln();
    }

    /// @notice LMSR marginal price function (Section 2.6.4):
    ///
    ///         p_G = exp(q_G / b) / (exp(q_G / b) + exp(q_I / b)),   p_I = 1 - p_G
    ///
    ///         Prices always sum to exactly 1 (UNIT) and are strictly bounded in (0, 1).
    /// @param qG Total Guilty shares outstanding.
    /// @param qI Total Innocent shares outstanding.
    /// @param b Liquidity parameter. Must be strictly positive.
    /// @return pG Marginal price of a Guilty share.
    /// @return pI Marginal price of an Innocent share.
    function price(SD59x18 qG, SD59x18 qI, SD59x18 b) internal pure returns (SD59x18 pG, SD59x18 pI) {
        _requirePositiveB(b);
        SD59x18 expG = (qG / b).exp();
        SD59x18 expI = (qI / b).exp();
        SD59x18 denom = expG + expI;
        if (SD59x18.unwrap(denom) == 0) revert PriceUndefined(qG, qI, b);
        pG = expG / denom;
        pI = UNIT - pG;
    }

    /// @notice Cost of moving the market from (qG0, qI0) to (qG0 + dqG, qI0 + dqI) in a single joint step
    ///         (Section 2.6.4: `dC = C(q_G_1, q_I_1) - C(q_G_0, q_I_0)`, path-independent — depends only on the
    ///         start and end state, never on how many transactions or wallets it took to get there).
    ///
    ///         Covers both directions of buy/sell on either side via the sign of dqG/dqI:
    ///           - buy dq Guilty:  dqG = +dq, dqI = 0   -> returns the (positive) cost to pay
    ///           - sell dq Guilty: dqG = -dq, dqI = 0   -> returns a negative value; proceeds = -result
    ///           - buy dq Innocent:  dqG = 0, dqI = +dq -> returns the (positive) cost to pay
    ///           - sell dq Innocent: dqG = 0, dqI = -dq -> returns a negative value; proceeds = -result
    /// @param qG0 Guilty shares outstanding before the trade.
    /// @param qI0 Innocent shares outstanding before the trade.
    /// @param dqG Signed change in Guilty shares (positive = buy, negative = sell).
    /// @param dqI Signed change in Innocent shares (positive = buy, negative = sell).
    /// @param b Liquidity parameter. Must be strictly positive.
    /// @return Signed cost of the trade: positive means the trader pays this amount, negative means the trader
    ///         receives (-result).
    function costOfTrade(SD59x18 qG0, SD59x18 qI0, SD59x18 dqG, SD59x18 dqI, SD59x18 b)
        internal
        pure
        returns (SD59x18)
    {
        return cost(qG0 + dqG, qI0 + dqI, b) - cost(qG0, qI0, b);
    }

    function _requirePositiveB(SD59x18 b) private pure {
        if (SD59x18.unwrap(b) <= 0) revert InvalidLiquidityParameter(b);
    }
}
