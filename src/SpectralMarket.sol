// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SD59x18, sd, ZERO} from "prb-math/SD59x18.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LMSRMath} from "./LMSRMath.sol";
import {ISettlementConditionsHook} from "./ISettlementConditionsHook.sol";

/// @title SpectralMarket
/// @notice The Spectral Market for Walendria Protocol "The 27" (Section 2.6): a purpose-built LMSR prediction
///         market, one instance per dispute, keyed by `marketId`. Each market is opened with a joint initial
///         position injection (Section 2.6.1), then trades freely (Section 2.6.3) until an authorized controller
///         resolves it, after which winning-side shares redeem for up to $1 each (Section 2.6.3), capped at
///         whatever the market's pool still holds - see {redeem}'s own doc for why a cap rather than a revert.
/// @dev Phase 5 of the build strategy. Depends only on LMSRMath (Phase 1). Deliberately does not decide *when* a
///      market resolves (Section 2.6.5/2.6.8, condition tracking and checkpoint-and-poke) or *when* a dispute's
///      cumulative Guilty-side funding has crossed 0.5P (Section 2.4) - those are SettlementConditions.sol (Phase
///      6) and DisputeManager.sol (Phase 7). This contract exposes the mechanism those phases wire into
///      (`resolveMarket`, controller-gated), exactly like ListingManager's `markDisputed`/`resolveDispute` stood
///      in for DisputeManager before it existed (Phase 3).
///
///      Shares are plain internal accounting (`sharesOf`), not ERC20 tokens: nothing in the spec requires
///      peer-to-peer transferability, only buy/sell against this AMM, so a mapping is the minimal implementation.
///
///      A market's `pooled` native currency is tracked explicitly (mirroring SharedIB's `totalPooled`), not
///      derived from `address(this).balance`, both to avoid the ERC4626-style inflation/force-send hazard and
///      because one contract instance holds many markets' funds at once - `address(this).balance` is meaningless
///      per-market. LMSR's own well-known bounded-loss property (a market maker can owe up to `b * ln(2)` more in
///      redemptions than it collected) means `pooled` is not guaranteed sufficient to cover every redemption in
///      every adversarial trading sequence; the whitepaper discloses this as an inherent, computable property of
///      the curve (Section 2.6.9's Boundary Theorem, scale-invariant in P) rather than subsidizing it away. A
///      prior revision topped small disputes up to a fixed depth floor from the Developer Pool; that Protocol
///      Liquidity Buffer has been retired (whitepaper Section 2.6.7), so initial depth is always exactly the 1P
///      the two sides fund, at any transaction size, with no address credited that did not itself contribute.
///
///      {openMarket}'s Guilty and Innocent sides are both arrays: the Guilty side genuinely needs it (a dispute
///      may be funded by many backers, Section 2.4), and the Innocent side is kept symmetric for a uniform
///      injection path even though it now always carries exactly one recipient (the seller). {sweepSurplus}
///      (Section 2.6.6) sends a resolved market's surplus - pooled funds minus the remaining winning-side
///      obligation - to the Developer Pool; {payResolutionBounty} draws the 0.1% poke bounty from that same
///      surplus first (whitepaper Section 2.6.8 point 5). Both are safe to call any time after resolution,
///      because the surplus is constant from that moment onward (both `pooled` and the obligation shrink by
///      exactly the redeemed amount per {redeem}).
contract SpectralMarket is ReentrancyGuard {
    enum Side {
        Guilty,
        Innocent
    }

    struct Market {
        SD59x18 b;
        SD59x18 qGuilty;
        SD59x18 qInnocent;
        uint256 pooled;
        bool open;
        bool resolved;
        Side winningSide;
    }

    mapping(uint256 marketId => Market) public markets;
    mapping(uint256 marketId => mapping(Side => mapping(address trader => uint256))) public sharesOf;
    mapping(address controller => bool) public isController;

    /// @notice Count of distinct addresses that have EVER held a nonzero balance of `Side` in `marketId`, credited
    ///         once per address the first time it acquires a nonzero position and never decremented - selling
    ///         back to zero does not undo it. Together with a current-balance check, this is what lets
    ///         DisputeManager.sol (Phase 7) implement Section 2.6.10's mutual-early-resolution eligibility
    ///         correctly: a current-balance check alone would wrongly re-permit the path once a third party who
    ///         bought in fully exits, since LMSR round-trips a buy-then-sell back to the exact same q. The
    ///         invariant that matters ("does not reopen even if that address later exits their position") needs
    ///         this monotonic count, which only this contract can track - it alone sees every trade unconditionally.
    mapping(uint256 marketId => mapping(Side => uint256)) public distinctHolderCount;
    mapping(uint256 marketId => mapping(Side => mapping(address trader => bool))) public everHeldShares;

    /// @notice Cumulative amount paid out via {redeem} for `marketId`, tracked so {sweepSurplus} can compute the
    ///         still-outstanding winning obligation at any time after resolution, not just at the instant of
    ///         resolution itself.
    mapping(uint256 marketId => uint256) public totalRedeemed;

    /// @notice Called after every successful {buy}/{sell} (Section 2.6.8's checkpoint-on-trade). Address(0) is a
    ///         valid, deliberate choice meaning "no condition tracking wired in" - useful for isolating pure
    ///         market-mechanics tests from Phase 6's resolution-condition concerns; a real deployment must wire
    ///         in a genuine SettlementConditions.sol, or price-based auto-resolution simply never triggers
    ///         (direct controller-gated {resolveMarket} calls, e.g. DisputeManager's mutualClose, still work).
    ISettlementConditionsHook public immutable settlementConditions;

    /// @notice Destination for {sweepSurplus} (Section 2.6.6). Address(0) is a valid, deliberate choice disabling
    ///         sweeping - same rationale as {settlementConditions}'s address(0) state.
    address public immutable developerPool;

    event MarketOpened(uint256 indexed marketId, uint256 b, uint256 sharesPerSide, uint256 totalPooled);
    event Bought(uint256 indexed marketId, Side indexed side, address indexed trader, uint256 shares, uint256 cost);
    event Sold(uint256 indexed marketId, Side indexed side, address indexed trader, uint256 shares, uint256 proceeds);
    event MarketResolved(uint256 indexed marketId, Side winningSide);
    event Redeemed(uint256 indexed marketId, address indexed trader, uint256 shares, uint256 payout);
    event SurplusSwept(uint256 indexed marketId, uint256 amount);
    event ResolutionBountyPaid(uint256 indexed marketId, address indexed recipient, uint256 amount);

    error NoControllers();
    error NotController(address caller);
    error ZeroLiquidityParameter();
    error MarketAlreadyOpen(uint256 marketId);
    error MarketNotOpen(uint256 marketId);
    error MarketAlreadyResolved(uint256 marketId);
    error MarketNotResolved(uint256 marketId);
    error EmptyContributionList();
    error ContributionArrayLengthMismatch(uint256 fundersLength, uint256 amountsLength);
    error MismatchedInitialContributions(uint256 guiltyTotal, uint256 innocentTotal);
    error IncorrectValueSent(uint256 sent, uint256 required);
    error ZeroShares();
    error BuySlippageExceeded(uint256 cost, uint256 maxCost);
    error SellSlippageExceeded(uint256 proceeds, uint256 minProceeds);
    error InsufficientShares(address trader, uint256 requested, uint256 held);
    error NothingToRedeem(address trader);
    error TransferFailed(address to, uint256 amount);
    error DeveloperPoolNotSet();
    error NoSurplusToSweep(uint256 marketId);

    /// @param controllers Addresses authorized to call {openMarket}/{resolveMarket} (e.g. DisputeManager.sol,
    ///        SettlementConditions.sol). Fixed for the lifetime of this contract.
    /// @param _settlementConditions See {settlementConditions}. Immutable, like every other cross-contract
    ///        address in this codebase - address(0) disables the hook (see {settlementConditions}'s doc).
    /// @param _developerPool See {developerPool}. Immutable - address(0) disables {sweepSurplus}.
    constructor(address[] memory controllers, ISettlementConditionsHook _settlementConditions, address _developerPool) {
        if (controllers.length == 0) revert NoControllers();
        for (uint256 i = 0; i < controllers.length; i++) {
            isController[controllers[i]] = true;
        }
        settlementConditions = _settlementConditions;
        developerPool = _developerPool;
    }

    modifier onlyController() {
        if (!isController[msg.sender]) revert NotController(msg.sender);
        _;
    }

    /// @notice Opens `marketId` with liquidity parameter `b` (Section 2.6.4; locked parameter: b = 1 * P per
    ///         disputed transaction) and performs the joint initial-position injection (Section 2.6.1):
    ///         `guiltyFunders`/`guiltyAmounts` are credited Guilty shares in proportion to their contribution,
    ///         `innocentRecipients`/`innocentAmounts` are credited Innocent shares the same way - ordinarily just
    ///         the seller (the matching 0.5P IB draw), but Phase 8 also lets DeveloperPool.sol appear on *both*
    ///         arrays simultaneously when Section 2.6.7's liquidity buffer tops up a small-P dispute. All
    ///         contributions are resolved as a single simultaneous state transition from (0, 0), so the market
    ///         opens at an unbiased 50/50 price regardless of the order the underlying contributions landed in
    ///         (Section 2.6.4's path independence).
    ///
    ///         Requires `sum(guiltyAmounts) == sum(innocentAmounts)` (Section 2.4: the seller's match is always
    ///         equal to the Guilty-side funding that triggered it; a buffer top-up preserves this by contributing
    ///         the identical amount to both arrays). Given that precondition, moving symmetrically from (0, 0) to
    ///         (q, q) costs exactly `q` regardless of `b` - see {LMSRMath-cost}: C(q,q) - C(0,0) =
    ///         b*ln(2*e^(q/b)) - b*ln(2) = q. So every contributor's shares are simply twice their dollar
    ///         contribution (the unbiased opening price is exactly 0.5): no LMSRMath call is needed to *solve*
    ///         for shares here, only to verify the identity (done in SpectralMarketTest, cross-checked against
    ///         {LMSRMath-cost} directly - the shortcut is a proven identity, not an unverified assumption).
    /// @dev `msg.value` must equal the combined contribution exactly - this is an internal call from a trusted
    ///      controller forwarding funds it already collected/drew, not a user-facing entry point, so a mismatch
    ///      indicates a caller bug and reverts loudly rather than refunding.
    function openMarket(
        uint256 marketId,
        uint256 b,
        address[] calldata guiltyFunders,
        uint256[] calldata guiltyAmounts,
        address[] calldata innocentRecipients,
        uint256[] calldata innocentAmounts
    ) external payable onlyController {
        Market storage m = markets[marketId];
        if (m.open) revert MarketAlreadyOpen(marketId);
        if (b == 0) revert ZeroLiquidityParameter();
        if (guiltyFunders.length == 0 || innocentRecipients.length == 0) revert EmptyContributionList();
        if (guiltyFunders.length != guiltyAmounts.length) {
            revert ContributionArrayLengthMismatch(guiltyFunders.length, guiltyAmounts.length);
        }
        if (innocentRecipients.length != innocentAmounts.length) {
            revert ContributionArrayLengthMismatch(innocentRecipients.length, innocentAmounts.length);
        }

        uint256 guiltyTotal = _sumAmounts(guiltyAmounts);
        uint256 innocentTotal = _sumAmounts(innocentAmounts);
        if (guiltyTotal != innocentTotal) revert MismatchedInitialContributions(guiltyTotal, innocentTotal);

        uint256 totalIn = guiltyTotal + innocentTotal;
        if (msg.value != totalIn) revert IncorrectValueSent(msg.value, totalIn);

        // casting to 'int256' is safe because totalIn is a native-currency wei amount, unreachably far below
        // type(int256).max (~5.79e76) for any realistic transaction price - total ETH supply is ~1.2e26 wei.
        // forge-lint: disable-next-line(unsafe-typecast)
        SD59x18 q = sd(int256(totalIn));
        // casting to 'int256' is safe for the same reason: b is a liquidity parameter on the same wei scale.
        // forge-lint: disable-next-line(unsafe-typecast)
        m.b = sd(int256(b));
        m.qGuilty = q;
        m.qInnocent = q;
        m.pooled = totalIn;
        m.open = true;

        _creditSide(marketId, Side.Guilty, guiltyFunders, guiltyAmounts);
        _creditSide(marketId, Side.Innocent, innocentRecipients, innocentAmounts);

        emit MarketOpened(marketId, b, totalIn, totalIn);
    }

    /// @notice Buys `shares` of `side` in `marketId`. `msg.value` is the caller's maximum acceptable payment
    ///         (slippage protection); the actual cost is computed via {LMSRMath-costOfTrade} and any excess is
    ///         refunded in the same call.
    function buy(uint256 marketId, Side side, uint256 shares) external payable nonReentrant returns (uint256 cost) {
        Market storage m = markets[marketId];
        if (!m.open) revert MarketNotOpen(marketId);
        if (m.resolved) revert MarketAlreadyResolved(marketId);
        if (shares == 0) revert ZeroShares();

        // casting to 'int256' is safe because shares is a wei-scale share quantity, unreachably far below
        // type(int256).max for any realistic trade size.
        // forge-lint: disable-next-line(unsafe-typecast)
        SD59x18 dq = sd(int256(shares));
        SD59x18 costFixed = side == Side.Guilty
            ? LMSRMath.costOfTrade(m.qGuilty, m.qInnocent, dq, ZERO, m.b)
            : LMSRMath.costOfTrade(m.qGuilty, m.qInnocent, ZERO, dq, m.b);
        cost = _positiveToUint256(costFixed);

        if (cost > msg.value) revert BuySlippageExceeded(cost, msg.value);

        if (side == Side.Guilty) {
            m.qGuilty = m.qGuilty + dq;
        } else {
            m.qInnocent = m.qInnocent + dq;
        }
        m.pooled += cost;
        _markHolder(marketId, side, msg.sender);
        sharesOf[marketId][side][msg.sender] += shares;

        emit Bought(marketId, side, msg.sender, shares, cost);
        _checkpointAndMaybeResolve(marketId, m);

        uint256 refund = msg.value - cost;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert TransferFailed(msg.sender, refund);
        }
    }

    /// @notice Sells `shares` of `side` in `marketId`, held by the caller. `minProceeds` is the caller's minimum
    ///         acceptable payment (slippage protection); actual proceeds are computed via
    ///         {LMSRMath-costOfTrade} with a negative share delta.
    function sell(uint256 marketId, Side side, uint256 shares, uint256 minProceeds)
        external
        nonReentrant
        returns (uint256 proceeds)
    {
        Market storage m = markets[marketId];
        if (!m.open) revert MarketNotOpen(marketId);
        if (m.resolved) revert MarketAlreadyResolved(marketId);
        if (shares == 0) revert ZeroShares();

        uint256 held = sharesOf[marketId][side][msg.sender];
        if (shares > held) revert InsufficientShares(msg.sender, shares, held);

        // casting to 'int256' is safe for the same reason as in {buy}: shares is bounded by `held`, itself a
        // wei-scale quantity.
        // forge-lint: disable-next-line(unsafe-typecast)
        SD59x18 dq = sd(int256(shares));
        SD59x18 costFixed = side == Side.Guilty
            ? LMSRMath.costOfTrade(m.qGuilty, m.qInnocent, -dq, ZERO, m.b)
            : LMSRMath.costOfTrade(m.qGuilty, m.qInnocent, ZERO, -dq, m.b);
        proceeds = _negativeToUint256(costFixed);

        if (proceeds < minProceeds) revert SellSlippageExceeded(proceeds, minProceeds);

        if (side == Side.Guilty) {
            m.qGuilty = m.qGuilty - dq;
        } else {
            m.qInnocent = m.qInnocent - dq;
        }
        sharesOf[marketId][side][msg.sender] = held - shares;
        m.pooled -= proceeds;

        emit Sold(marketId, side, msg.sender, shares, proceeds);
        _checkpointAndMaybeResolve(marketId, m);

        (bool ok,) = msg.sender.call{value: proceeds}("");
        if (!ok) revert TransferFailed(msg.sender, proceeds);
    }

    /// @notice Resolves `marketId` in favor of `winningSide`, enabling {redeem}. The condition under which this
    ///         should be called (Condition A/B, Section 2.6.5) is not this contract's concern - see the
    ///         contract-level dev note.
    function resolveMarket(uint256 marketId, Side winningSide) external onlyController {
        Market storage m = markets[marketId];
        if (!m.open) revert MarketNotOpen(marketId);
        if (m.resolved) revert MarketAlreadyResolved(marketId);
        m.resolved = true;
        m.winningSide = winningSide;
        emit MarketResolved(marketId, winningSide);
    }

    /// @notice Redeems the caller's entire winning-side balance in `marketId` for native currency, up to $1 per
    ///         share (Section 2.6.3), capped at whatever `pooled` currently holds. LMSR's bounded-loss property
    ///         (Section 2.6.9) means a heavily-traded market can leave `pooled` short of the full winning-side
    ///         obligation - the trader who redeems after the pool runs dry receives whatever remains, however
    ///         little, rather than a hard revert that would leave their entire claim permanently unredeemable
    ///         (an arithmetic-underflow revert on `m.pooled -= payout` gives that trader literally nothing, in
    ///         a contract with no mechanism to ever top the pool back up after resolution). A partial, final
    ///         payout is strictly better for that trader than a claim stuck behind a revert forever.
    /// @dev Deliberately does not touch `m.qGuilty`/`m.qInnocent`: those exist to price trades (Section 2.6.4),
    ///      and {buy}/{sell} already refuse to run once `m.resolved` is true, so they have nothing left to price
    ///      - they are frozen historical state as of resolution, not a live pool that redemptions draw down. The
    ///      quantity a redemption actually draws down is `sharesOf` (the individual's claim) and `m.pooled` (the
    ///      market's native-currency backing); an invariant comparing `qGuilty`/`qInnocent` against the *current*
    ///      sum of individual balances is therefore only meaningful before resolution, not after.
    function redeem(uint256 marketId) external nonReentrant returns (uint256 payout) {
        Market storage m = markets[marketId];
        if (!m.resolved) revert MarketNotResolved(marketId);

        uint256 shares = sharesOf[marketId][m.winningSide][msg.sender];
        if (shares == 0) revert NothingToRedeem(msg.sender);

        sharesOf[marketId][m.winningSide][msg.sender] = 0;
        payout = shares < m.pooled ? shares : m.pooled;
        m.pooled -= payout;
        totalRedeemed[marketId] += payout;

        emit Redeemed(marketId, msg.sender, shares, payout);

        if (payout > 0) {
            (bool ok,) = msg.sender.call{value: payout}("");
            if (!ok) revert TransferFailed(msg.sender, payout);
        }
    }

    /// @notice Pays up to `requested` of `marketId`'s current surplus (Section 2.6.6) to `recipient` as the 0.1%
    ///         poke bounty (whitepaper Section 2.6.8 point 5), capped at whatever the surplus actually holds.
    ///         Controller-gated so only SettlementConditions.sol - which knows who called {pokeSettlement} and
    ///         computes the 0.1%-of-P amount - can trigger it, in the same transaction it resolves the market.
    /// @dev Sourced from the same surplus {sweepSurplus} would otherwise send to {developerPool}, drawn first: a
    ///      quiet dispute (the winner holds ~all of the ~1P pool, whitepaper Section 3.2) leaves almost no
    ///      surplus, so `paid` is capped near zero - by design (whitepaper Section 2.6.8: resolution there rests
    ///      on the winner's own incentive to poke for their payout, not on this bounty). Never touches winning-
    ///      share obligations: the cap is exactly `pooled - remainingObligation`, so every winner is still made
    ///      whole 1:1. nonReentrant, and effects precede the transfer to `recipient` (an arbitrary poke caller).
    function payResolutionBounty(uint256 marketId, address recipient, uint256 requested)
        external
        onlyController
        nonReentrant
        returns (uint256 paid)
    {
        Market storage m = markets[marketId];
        if (!m.resolved) revert MarketNotResolved(marketId);

        uint256 surplus = _currentSurplus(m, marketId);
        paid = requested < surplus ? requested : surplus;
        if (paid == 0) return 0;

        m.pooled -= paid;
        emit ResolutionBountyPaid(marketId, recipient, paid);

        (bool ok,) = recipient.call{value: paid}("");
        if (!ok) revert TransferFailed(recipient, paid);
    }

    /// @notice Sweeps `marketId`'s surplus (Section 2.6.6) to {developerPool}: the difference between pooled
    ///         funds and the still-outstanding winning-side obligation, net of any 0.1% poke bounty already drawn
    ///         from it by {payResolutionBounty}. This quantity is constant from the moment of resolution onward -
    ///         both `pooled` and the remaining obligation shrink by exactly the same amount on every {redeem}
    ///         call - so it is safe to call at any time after resolution, by anyone, repeatedly (later calls
    ///         simply find zero surplus once a prior sweep already collected it, or once trading losses fully
    ///         absorbed by winners leave nothing left over).
    function sweepSurplus(uint256 marketId) external nonReentrant returns (uint256 surplus) {
        if (developerPool == address(0)) revert DeveloperPoolNotSet();
        Market storage m = markets[marketId];
        if (!m.resolved) revert MarketNotResolved(marketId);

        surplus = _currentSurplus(m, marketId);
        if (surplus == 0) revert NoSurplusToSweep(marketId);

        m.pooled -= surplus;
        emit SurplusSwept(marketId, surplus);

        (bool ok,) = developerPool.call{value: surplus}("");
        if (!ok) revert TransferFailed(developerPool, surplus);
    }

    /// @dev The surplus available for `marketId` right now: pooled funds minus the still-outstanding winning-side
    ///      obligation (winning shares issued, less what has already been redeemed). Zero when the winners' claim
    ///      still meets or exceeds the pool - the common case for a quiet dispute. Shared by {sweepSurplus} and
    ///      {payResolutionBounty} so both compute the surplus identically.
    function _currentSurplus(Market storage m, uint256 marketId) internal view returns (uint256) {
        SD59x18 winningQtyFixed = m.winningSide == Side.Guilty ? m.qGuilty : m.qInnocent;
        // casting to 'uint256' is safe because share quantities never go negative (they only ever accumulate
        // non-negative credits - see {SpectralMarket-distinctHolderCount}'s neighboring invariants).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 winningQty = uint256(SD59x18.unwrap(winningQtyFixed));
        uint256 remainingObligation = winningQty - totalRedeemed[marketId];
        return m.pooled > remainingObligation ? m.pooled - remainingObligation : 0;
    }

    /// @notice Current marginal Guilty/Innocent price for `marketId` (Section 2.6.4), exposed for
    ///         SettlementConditions.sol (Phase 6) to check against the 87%/90% thresholds (Section 2.6.5).
    function currentPrice(uint256 marketId) external view returns (uint256 pGuilty, uint256 pInnocent) {
        Market storage m = markets[marketId];
        if (!m.open) revert MarketNotOpen(marketId);
        (SD59x18 pG, SD59x18 pI) = LMSRMath.price(m.qGuilty, m.qInnocent, m.b);
        pGuilty = uint256(SD59x18.unwrap(pG));
        pInnocent = uint256(SD59x18.unwrap(pI));
    }

    /// @notice Runs the checkpoint-on-trade hook (Section 2.6.8 point 1) after {buy}/{sell} have already applied
    ///         their own state changes, using the now-current (post-trade) price - this is also what lets
    ///         {ISettlementConditionsHook-checkpoint} see the trade's own resulting price immediately rather than
    ///         a stale pre-trade snapshot, even though no single trade ever resolves a case by itself (Section
    ///         2.6.5: only accumulated time above the resolution threshold can). A no-op when
    ///         {settlementConditions} is unset (see its own doc for why that is a deliberate, valid state).
    function _checkpointAndMaybeResolve(uint256 marketId, Market storage m) internal {
        if (address(settlementConditions) == address(0)) return;

        (SD59x18 pG, SD59x18 pI) = LMSRMath.price(m.qGuilty, m.qInnocent, m.b);
        // casting to 'uint256' is safe because LMSRMath.price() guarantees both results lie in [0, UNIT].
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 priceGuilty = uint256(SD59x18.unwrap(pG));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 priceInnocent = uint256(SD59x18.unwrap(pI));

        (bool shouldResolve, bool guiltyWins) = settlementConditions.checkpoint(marketId, priceGuilty, priceInnocent);
        if (shouldResolve) {
            m.resolved = true;
            m.winningSide = guiltyWins ? Side.Guilty : Side.Innocent;
            emit MarketResolved(marketId, m.winningSide);
        }
    }

    /// @dev Extracted out of {openMarket} to keep its own stack depth within Solidity's limit now that both
    ///      sides are arrays - this and {_creditSide} carry the per-array loop variables instead.
    function _sumAmounts(uint256[] calldata amounts) private pure returns (uint256 total) {
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
    }

    /// @dev Credits `side` shares to each of `recipients` in proportion to `amounts` (2x, per {openMarket}'s
    ///      unbiased-50/50-opening identity), marking each as a holder for {distinctHolderCount}. Every recipient
    ///      of an initial joint injection is a genuine funder (the Guilty-side backers, or the seller on the
    ///      Innocent side) - the Protocol Liquidity Buffer that once credited {developerPool} symmetrically on
    ///      both sides has been retired (whitepaper Section 2.6.7), so there is no longer any address to exempt
    ///      from the holder count here. A genuine third-party trader still reaches this contract only through
    ///      {buy}, which calls {_markHolder} directly.
    function _creditSide(uint256 marketId, Side side, address[] calldata recipients, uint256[] calldata amounts)
        private
    {
        for (uint256 i = 0; i < recipients.length; i++) {
            _markHolder(marketId, side, recipients[i]);
            sharesOf[marketId][side][recipients[i]] += amounts[i] * 2;
        }
    }

    /// @dev Records `trader` as a `side` holder of `marketId` the first time they ever acquire a nonzero balance,
    ///      guarding against double-counting the same address twice (defensive: a well-formed caller's
    ///      `guiltyFunders` never contains a duplicate, but this keeps the count correct even if one ever did).
    function _markHolder(uint256 marketId, Side side, address trader) private {
        if (!everHeldShares[marketId][side][trader]) {
            everHeldShares[marketId][side][trader] = true;
            distinctHolderCount[marketId][side] += 1;
        }
    }

    /// @dev A buy's cost is strictly positive for any dq > 0 from a valid state (C is strictly increasing in
    ///      each argument) - this is a mathematical property of {LMSRMath-cost}, not a runtime condition, but is
    ///      guarded explicitly rather than trusted blindly, since a silent wraparound on the int256->uint256
    ///      cast would otherwise turn a violated assumption into a wrong-not-loud number instead of a revert.
    function _positiveToUint256(SD59x18 x) private pure returns (uint256) {
        int256 raw = SD59x18.unwrap(x);
        assert(raw > 0);
        // casting to 'uint256' is safe because the assert above just proved raw > 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(raw);
    }

    /// @dev Mirrors {_positiveToUint256} for the sell direction, where {LMSRMath-costOfTrade} returns a
    ///      strictly negative value for any dq < 0 from a valid state.
    function _negativeToUint256(SD59x18 x) private pure returns (uint256) {
        int256 raw = SD59x18.unwrap(x);
        assert(raw < 0);
        // casting to 'uint256' is safe because the assert above just proved -raw > 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(-raw);
    }
}
