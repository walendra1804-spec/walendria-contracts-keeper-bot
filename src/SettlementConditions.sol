// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SpectralMarket} from "./SpectralMarket.sol";
import {ISettlementConditionsHook} from "./ISettlementConditionsHook.sol";

/// @title SettlementConditions
/// @notice Condition A/B tracking and the checkpoint-and-poke mechanism for Walendria Protocol "The 27" (Section
///         2.6.5, 2.6.8). One instance tracks every market opened on a single, fixed SpectralMarket.
///
///         Condition A (instant): either side's price touching 90% resolves the case immediately.
///         Condition B (cumulative): a stopwatch-style timer tracks total time either side's price has spent at
///         or above 87% - it pauses (never resets) below 87%, and resolves the case once accumulated time
///         reaches 3 hours (Section 1's locked parameter table).
/// @dev Phase 6 of the build strategy. Depends on Phase 5 (SpectralMarket.sol), which now calls {checkpoint} on
///      every successful buy/sell (see SpectralMarket's `_checkpointAndMaybeResolve`). No oracle, off-chain
///      timer, or designated keeper is required (Section 2.6.8): elapsed time at a given price is exactly
///      computable from on-chain checkpoint timestamps, because price cannot change without a trade, and any
///      trade re-checkpoints before it can move price further. {pokeSettlement} closes the one remaining gap -
///      a case whose cumulative threshold is crossed by elapsed real time alone, with no further trade ever
///      occurring to trigger a fresh checkpoint - by letting anyone, at any time, force a checkpoint against the
///      current block timestamp and resolve if warranted, earning a small bounty for doing so.
///
///      Deployment requirement: this contract's own address must be included in `spectralMarket`'s `controllers`
///      array at construction time (alongside Settlement.sol/DisputeManager.sol), since {pokeSettlement} calls
///      `spectralMarket.resolveMarket` directly, which is onlyController-gated. Omitting it compiles and deploys
///      fine but makes every {pokeSettlement} call revert with `NotController` - there is no way to add it after
///      the fact, matching this codebase's immutable-controller-allowlist convention everywhere else.
contract SettlementConditions is ISettlementConditionsHook, ReentrancyGuard {
    struct Tracking {
        uint256 cumulativeGuilty;
        uint256 cumulativeInnocent;
        uint256 lastCheckpointTime;
        bool trackedSideIsGuilty; // meaningful only if trackedSideActive
        bool trackedSideActive; // true if either side was >=87% as of the last checkpoint
        bool initialized;
    }

    /// @notice Condition A (Section 2.6.5): instant resolution the moment either side's price touches this.
    uint256 public constant INSTANT_THRESHOLD = 0.9e18;
    /// @notice Condition B (Section 2.6.5): the price level whose cumulative time above it is tracked.
    uint256 public constant CUMULATIVE_THRESHOLD = 0.87e18;
    /// @notice Condition B (Section 2.6.5, confirmed 2026-07-03): cumulative time above threshold to resolve.
    uint256 public constant CUMULATIVE_DURATION = 3 hours;

    SpectralMarket public immutable spectralMarket;
    /// @notice Fixed bounty paid to a successful {pokeSettlement} caller. Not a locked protocol parameter (the
    ///         spec only says "a small, fixed bounty" without a number, unlike 90%/87%/3-hours), so this is a
    ///         deployer-configurable immutable rather than a hardcoded constant.
    uint256 public immutable pokeBounty;

    mapping(uint256 marketId => Tracking) public tracking;
    uint256 public bountyPool;

    event Checkpointed(uint256 indexed marketId, uint256 cumulativeGuilty, uint256 cumulativeInnocent);
    event ConditionAMet(uint256 indexed marketId, bool guiltyWins, uint256 price);
    event ConditionBMet(uint256 indexed marketId, bool guiltyWins, uint256 cumulativeTime);
    event Poked(uint256 indexed marketId, address indexed poker, uint256 bountyPaid);
    event BountyFunded(address indexed funder, uint256 amount);

    error NotSpectralMarket(address caller);
    error MarketNotOpen(uint256 marketId);
    error MarketAlreadyResolved(uint256 marketId);
    error ConditionsNotYetMet(uint256 marketId);
    error BountyTransferFailed(address to, uint256 amount);

    /// @param _spectralMarket The single SpectralMarket this instance tracks conditions for. Immutable, like
    ///        every other cross-contract address in this codebase.
    /// @param _pokeBounty See {pokeBounty}.
    constructor(SpectralMarket _spectralMarket, uint256 _pokeBounty) payable {
        spectralMarket = _spectralMarket;
        pokeBounty = _pokeBounty;
        bountyPool = msg.value;
    }

    modifier onlySpectralMarket() {
        if (msg.sender != address(spectralMarket)) revert NotSpectralMarket(msg.sender);
        _;
    }

    /// @notice Called by `spectralMarket` after every successful buy/sell (Section 2.6.8 point 1: "checkpoint on
    ///         every trade... paid for by the trader's own gas"). Restricted to the one registered SpectralMarket
    ///         so nobody else can inject fabricated prices to manipulate cumulative tracking or force a fake
    ///         resolution.
    function checkpoint(uint256 marketId, uint256 priceGuilty, uint256 priceInnocent)
        external
        onlySpectralMarket
        returns (bool shouldResolve, bool guiltyWins)
    {
        return _checkpoint(marketId, priceGuilty, priceInnocent);
    }

    /// @notice Permissionlessly re-runs the checkpoint against the current block timestamp and resolves
    ///         `marketId` if the accumulated-time threshold has been reached (Section 2.6.8 point 3) - the
    ///         mechanism that guarantees a case can never hang indefinitely even if no further trade ever occurs
    ///         after crossing 87%. Pays whichever is smaller of {pokeBounty} or the remaining {bountyPool} to the
    ///         caller; an underfunded bounty pool never blocks the resolution itself, only shrinks the reward.
    function pokeSettlement(uint256 marketId) external nonReentrant {
        (,,,, bool open, bool resolved,) = spectralMarket.markets(marketId);
        if (!open) revert MarketNotOpen(marketId);
        if (resolved) revert MarketAlreadyResolved(marketId);

        (uint256 priceGuilty, uint256 priceInnocent) = spectralMarket.currentPrice(marketId);
        (bool shouldResolve, bool guiltyWins) = _checkpoint(marketId, priceGuilty, priceInnocent);
        if (!shouldResolve) revert ConditionsNotYetMet(marketId);

        spectralMarket.resolveMarket(marketId, guiltyWins ? SpectralMarket.Side.Guilty : SpectralMarket.Side.Innocent);

        uint256 payout = bountyPool < pokeBounty ? bountyPool : pokeBounty;
        if (payout > 0) {
            bountyPool -= payout;
            (bool ok,) = msg.sender.call{value: payout}("");
            if (!ok) revert BountyTransferFailed(msg.sender, payout);
        }

        emit Poked(marketId, msg.sender, payout);
    }

    /// @notice Permissionlessly tops up the bounty pool (Section 2.6.8 point 5: "from the Developer Pool" -
    ///         Phase 8 wires DeveloperPool.sol as one caller of this; nothing restricts it to that caller).
    function fundBounty() external payable {
        bountyPool += msg.value;
        emit BountyFunded(msg.sender, msg.value);
    }

    function _checkpoint(uint256 marketId, uint256 priceGuilty, uint256 priceInnocent)
        internal
        returns (bool shouldResolve, bool guiltyWins)
    {
        Tracking storage t = tracking[marketId];
        if (!t.initialized) {
            t.lastCheckpointTime = block.timestamp;
            t.initialized = true;
        } else {
            uint256 elapsed = block.timestamp - t.lastCheckpointTime;
            if (t.trackedSideActive) {
                if (t.trackedSideIsGuilty) {
                    t.cumulativeGuilty += elapsed;
                } else {
                    t.cumulativeInnocent += elapsed;
                }
            }
            t.lastCheckpointTime = block.timestamp;
        }

        emit Checkpointed(marketId, t.cumulativeGuilty, t.cumulativeInnocent);

        if (priceGuilty >= INSTANT_THRESHOLD) {
            emit ConditionAMet(marketId, true, priceGuilty);
            return (true, true);
        }
        if (priceInnocent >= INSTANT_THRESHOLD) {
            emit ConditionAMet(marketId, false, priceInnocent);
            return (true, false);
        }

        if (t.cumulativeGuilty >= CUMULATIVE_DURATION) {
            emit ConditionBMet(marketId, true, t.cumulativeGuilty);
            return (true, true);
        }
        if (t.cumulativeInnocent >= CUMULATIVE_DURATION) {
            emit ConditionBMet(marketId, false, t.cumulativeInnocent);
            return (true, false);
        }

        if (priceGuilty >= CUMULATIVE_THRESHOLD) {
            t.trackedSideActive = true;
            t.trackedSideIsGuilty = true;
        } else if (priceInnocent >= CUMULATIVE_THRESHOLD) {
            t.trackedSideActive = true;
            t.trackedSideIsGuilty = false;
        } else {
            t.trackedSideActive = false;
        }

        return (false, false);
    }
}
