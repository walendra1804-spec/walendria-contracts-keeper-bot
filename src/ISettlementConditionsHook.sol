// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISettlementConditionsHook
/// @notice Minimal hook SpectralMarket calls on every successful buy/sell (Section 2.6.8's "checkpoint on every
///         trade"). Deliberately free of any SpectralMarket-defined type (e.g. `Side`) so SpectralMarket does not
///         need to import SettlementConditions.sol, which itself depends on SpectralMarket for price reads and
///         to call {resolveMarket} - keeping the dependency one-way instead of circular.
interface ISettlementConditionsHook {
    /// @param marketId The market that was just traded.
    /// @param priceGuilty Current (post-trade) marginal Guilty price, SD59x18-scaled (1e18 = 100%).
    /// @param priceInnocent Current (post-trade) marginal Innocent price, SD59x18-scaled.
    /// @return shouldResolve True if Condition A or Condition B (Section 2.6.5) has just been met.
    /// @return guiltyWins Meaningful only when `shouldResolve` is true.
    function checkpoint(uint256 marketId, uint256 priceGuilty, uint256 priceInnocent)
        external
        returns (bool shouldResolve, bool guiltyWins);
}
