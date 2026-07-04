// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SD59x18, sd, ZERO} from "prb-math/SD59x18.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LMSRMath} from "./LMSRMath.sol";

/// @title SpectralMarket
/// @notice The Spectral Market for Walendria Protocol "The 27" (Section 2.6): a purpose-built LMSR prediction
///         market, one instance per dispute, keyed by `marketId`. Each market is opened with a joint initial
///         position injection (Section 2.6.1), then trades freely (Section 2.6.3) until an authorized controller
///         resolves it, after which winning-side shares redeem 1:1 for native currency (Section 2.6.3: "every
///         winning share pays exactly $1.00").
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
///      every adversarial trading sequence; the spec's own backstop for this (Section 2.6.7's Protocol Liquidity
///      Buffer, funded from the Developer Pool) is out of scope here - Phase 8 wires DeveloperPool.sol.
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

    event MarketOpened(uint256 indexed marketId, uint256 b, uint256 sharesPerSide, uint256 totalPooled);
    event Bought(uint256 indexed marketId, Side indexed side, address indexed trader, uint256 shares, uint256 cost);
    event Sold(uint256 indexed marketId, Side indexed side, address indexed trader, uint256 shares, uint256 proceeds);
    event MarketResolved(uint256 indexed marketId, Side winningSide);
    event Redeemed(uint256 indexed marketId, address indexed trader, uint256 shares, uint256 payout);

    error NoControllers();
    error NotController(address caller);
    error ZeroLiquidityParameter();
    error MarketAlreadyOpen(uint256 marketId);
    error MarketNotOpen(uint256 marketId);
    error MarketAlreadyResolved(uint256 marketId);
    error MarketNotResolved(uint256 marketId);
    error EmptyContributionList();
    error ContributionArrayLengthMismatch(uint256 fundersLength, uint256 amountsLength);
    error MismatchedInitialContributions(uint256 guiltyTotal, uint256 innocentAmount);
    error IncorrectValueSent(uint256 sent, uint256 required);
    error ZeroShares();
    error BuySlippageExceeded(uint256 cost, uint256 maxCost);
    error SellSlippageExceeded(uint256 proceeds, uint256 minProceeds);
    error InsufficientShares(address trader, uint256 requested, uint256 held);
    error NothingToRedeem(address trader);
    error TransferFailed(address to, uint256 amount);

    /// @param controllers Addresses authorized to call {openMarket}/{resolveMarket} (e.g. DisputeManager.sol,
    ///        SettlementConditions.sol). Fixed for the lifetime of this contract.
    constructor(address[] memory controllers) {
        if (controllers.length == 0) revert NoControllers();
        for (uint256 i = 0; i < controllers.length; i++) {
            isController[controllers[i]] = true;
        }
    }

    modifier onlyController() {
        if (!isController[msg.sender]) revert NotController(msg.sender);
        _;
    }

    /// @notice Opens `marketId` with liquidity parameter `b` (Section 2.6.4; locked parameter: b = 1 * P per
    ///         disputed transaction) and performs the joint initial-position injection (Section 2.6.1):
    ///         `guiltyFunders`/`guiltyAmounts` are credited Guilty shares in proportion to their contribution,
    ///         `innocentRecipient` (the seller) is credited Innocent shares for `innocentAmount` (the matching
    ///         0.5P IB draw). Both sides are resolved as a single simultaneous state transition from (0, 0), so
    ///         the market opens at an unbiased 50/50 price regardless of the order the underlying contributions
    ///         landed in (Section 2.6.4's path independence).
    ///
    ///         Requires `sum(guiltyAmounts) == innocentAmount` (Section 2.4: the seller's match is always equal
    ///         to the Guilty-side funding that triggered it). Given that precondition, moving symmetrically from
    ///         (0, 0) to (q, q) costs exactly `q` regardless of `b` - see {LMSRMath-cost}: C(q,q) - C(0,0) =
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
        address innocentRecipient,
        uint256 innocentAmount
    ) external payable onlyController {
        Market storage m = markets[marketId];
        if (m.open) revert MarketAlreadyOpen(marketId);
        if (b == 0) revert ZeroLiquidityParameter();
        if (guiltyFunders.length == 0) revert EmptyContributionList();
        if (guiltyFunders.length != guiltyAmounts.length) {
            revert ContributionArrayLengthMismatch(guiltyFunders.length, guiltyAmounts.length);
        }

        uint256 guiltyTotal;
        for (uint256 i = 0; i < guiltyAmounts.length; i++) {
            guiltyTotal += guiltyAmounts[i];
        }
        if (guiltyTotal != innocentAmount) revert MismatchedInitialContributions(guiltyTotal, innocentAmount);

        uint256 totalIn = guiltyTotal + innocentAmount;
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

        for (uint256 i = 0; i < guiltyFunders.length; i++) {
            sharesOf[marketId][Side.Guilty][guiltyFunders[i]] += guiltyAmounts[i] * 2;
        }
        sharesOf[marketId][Side.Innocent][innocentRecipient] += innocentAmount * 2;

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
        sharesOf[marketId][side][msg.sender] += shares;

        emit Bought(marketId, side, msg.sender, shares, cost);

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

    /// @notice Redeems the caller's entire winning-side balance in `marketId` for native currency, 1:1 (Section
    ///         2.6.3: "every winning share pays exactly $1.00").
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
        payout = shares;
        m.pooled -= payout;

        emit Redeemed(marketId, msg.sender, shares, payout);

        (bool ok,) = msg.sender.call{value: payout}("");
        if (!ok) revert TransferFailed(msg.sender, payout);
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
