// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SD59x18} from "prb-math/SD59x18.sol";
import {SpectralMarket} from "./SpectralMarket.sol";
import {ISettlementConditionsHook} from "./ISettlementConditionsHook.sol";

/// @title SettlementConditions
/// @notice The settlement condition and checkpoint-and-poke mechanism for Walendria Protocol "The 28" (Section
///         2.6.5, 2.6.8). One instance tracks every market opened on a single, fixed SpectralMarket.
///
///         A cumulative (stopwatch-style) timer tracks total time either side's price has spent at or above 93% -
///         it pauses (never resets) below 93%, and resolves the case once accumulated time reaches 1 hour
///         (Section 1's locked parameter table). There is no instant-resolution path at any price: a single trade
///         may move price arbitrarily far in one step - to 93%, to 99%, to anywhere below 100% - but it can never
///         resolve a case by itself. This closes a one-shot manipulation path a prior revision's separate instant
///         threshold left open: a single, sufficiently capitalized transaction that crossed that threshold
///         resolved the case in the same transaction, leaving zero reaction time for any other participant to
///         notice and counter-trade, regardless of how transient or narrow the crossing was.
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
        bool trackedSideActive; // true if either side was >=93% as of the last checkpoint
        bool initialized;
    }

    /// @notice Section 2.6.5: the price level whose cumulative time above it is tracked. This is the only
    ///         settlement condition - there is no separate instant-resolution threshold at any price.
    uint256 public constant CUMULATIVE_THRESHOLD = 0.93e18;
    /// @notice Section 2.6.5 (confirmed 2026-07-04): cumulative time above threshold required to resolve.
    uint256 public constant CUMULATIVE_DURATION = 1 hours;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    SpectralMarket public immutable spectralMarket;
    /// @notice Poke bounty as a fraction of the transaction price P, in basis points (whitepaper Section 2.6.8
    ///         point 5: 0.1% => 10). The bounty is paid from the resolved market's own settlement surplus by
    ///         {SpectralMarket-payResolutionBounty}, capped at whatever surplus exists - there is no pre-funded
    ///         pool. b == P at market open (Section 2.6.4), so the amount is `b * pokeBountyBps / 10_000`.
    uint256 public immutable pokeBountyBps;

    mapping(uint256 marketId => Tracking) public tracking;

    event Checkpointed(uint256 indexed marketId, uint256 cumulativeGuilty, uint256 cumulativeInnocent);
    event ResolutionMet(uint256 indexed marketId, bool guiltyWins, uint256 cumulativeTime);
    event Poked(uint256 indexed marketId, address indexed poker, uint256 bountyPaid);

    error NotSpectralMarket(address caller);
    error MarketNotOpen(uint256 marketId);
    error MarketAlreadyResolved(uint256 marketId);
    error ConditionsNotYetMet(uint256 marketId);
    error InvalidBountyBps(uint256 bps);

    /// @param _spectralMarket The single SpectralMarket this instance tracks conditions for. Immutable, like
    ///        every other cross-contract address in this codebase.
    /// @param _pokeBountyBps See {pokeBountyBps}. Bounded at or below 100% (10_000 bps) as a sanity guard; the
    ///        intended value is far smaller (10 = 0.1%), and the market surplus caps the actual payout regardless.
    constructor(SpectralMarket _spectralMarket, uint256 _pokeBountyBps) {
        if (_pokeBountyBps > BPS_DENOMINATOR) revert InvalidBountyBps(_pokeBountyBps);
        spectralMarket = _spectralMarket;
        pokeBountyBps = _pokeBountyBps;
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
    ///         after crossing 93%. On success, pays the caller a bounty of `pokeBountyBps` of the transaction
    ///         price P (b == P at open, Section 2.6.4), drawn from the resolved market's own settlement surplus
    ///         and capped at whatever that surplus holds (whitepaper Section 2.6.8 point 5). A quiet dispute
    ///         leaves ~no surplus, so the bounty there may be ~0 - resolution never depends on it, only on the
    ///         checkpoint threshold being met; the winner's own incentive to poke for their payout is what
    ///         guarantees liveness in that case.
    function pokeSettlement(uint256 marketId) external nonReentrant {
        (SD59x18 bFixed,,,, bool open, bool resolved,) = spectralMarket.markets(marketId);
        if (!open) revert MarketNotOpen(marketId);
        if (resolved) revert MarketAlreadyResolved(marketId);

        (uint256 priceGuilty, uint256 priceInnocent) = spectralMarket.currentPrice(marketId);
        (bool shouldResolve, bool guiltyWins) = _checkpoint(marketId, priceGuilty, priceInnocent);
        if (!shouldResolve) revert ConditionsNotYetMet(marketId);

        spectralMarket.resolveMarket(marketId, guiltyWins ? SpectralMarket.Side.Guilty : SpectralMarket.Side.Innocent);

        // b == P at market open (Section 2.6.4). Cast is safe: b is a positive wei-scale liquidity parameter,
        // set from a native-currency amount unreachably far below type(int256).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(SD59x18.unwrap(bFixed));
        uint256 bounty = (price * pokeBountyBps) / BPS_DENOMINATOR;
        uint256 paid = spectralMarket.payResolutionBounty(marketId, msg.sender, bounty);

        emit Poked(marketId, msg.sender, paid);
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

        // No price, however high (including 99% or effectively 100%, reached in a single trade), resolves the
        // case here. Only accumulated time above CUMULATIVE_THRESHOLD, tracked across checkpoints, can.
        if (t.cumulativeGuilty >= CUMULATIVE_DURATION) {
            emit ResolutionMet(marketId, true, t.cumulativeGuilty);
            return (true, true);
        }
        if (t.cumulativeInnocent >= CUMULATIVE_DURATION) {
            emit ResolutionMet(marketId, false, t.cumulativeInnocent);
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
