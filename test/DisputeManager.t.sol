// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SD59x18, sd, ZERO} from "prb-math/SD59x18.sol";
import {IntegrityBond} from "../src/IntegrityBond.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {SpectralMarket} from "../src/SpectralMarket.sol";
import {ISettlementConditionsHook} from "../src/ISettlementConditionsHook.sol";
import {LMSRMath} from "../src/LMSRMath.sol";
import {DeveloperPool} from "../src/DeveloperPool.sol";
import {DisputeManager} from "../src/DisputeManager.sol";

/// @dev Reenters `dm` with an arbitrary, test-configured calldata payload during its own `receive()`, mirroring
///      the ReentrantAttacker pattern already established in IntegrityBond.t.sol / SharedIB.t.sol / Settlement.t.sol.
contract ReentrantFunder {
    DisputeManager public dm;
    bytes public reentryCalldata;
    bool public reentered;
    bool public reentrySucceeded;

    constructor(DisputeManager _dm) {
        dm = _dm;
    }

    function setReentryCalldata(bytes calldata data) external {
        reentryCalldata = data;
    }

    function attackFund(uint256 listingId, uint256 slotIndex, uint256 value) external {
        dm.fundGuiltySide{value: value}(listingId, slotIndex);
    }

    receive() external payable {
        if (!reentered && reentryCalldata.length > 0) {
            reentered = true;
            (bool ok,) = address(dm).call(reentryCalldata);
            reentrySucceeded = ok;
        }
    }
}

/// @dev A party (seller or buyer) whose `receive()` always reverts, to test that neither role can weaponize an
///      uncooperative wallet to block dispute finalization - IntegrityBond's slash/unlock never push funds
///      directly to either party (slash credits a pull-payment ledger; unlock moves no funds at all), so
///      finalization must succeed regardless of whether either party can even accept a transfer.
contract RevertingReceiver {
    IntegrityBond public bond;
    ListingManager public lm;

    constructor(IntegrityBond _bond, ListingManager _lm) {
        bond = _bond;
        lm = _lm;
    }

    function depositAndCreateListing(uint256 price, uint256 totalSlots, uint256 window)
        external
        payable
        returns (uint256)
    {
        bond.deposit{value: msg.value}();
        return lm.createListing(price, totalSlots, window);
    }

    receive() external payable {
        revert("RevertingReceiver: refuses ETH");
    }
}

contract DisputeManagerTest is Test {
    IntegrityBond internal bond;
    ListingManager internal lm;
    SpectralMarket internal market;
    DisputeManager internal dm;

    /// @dev Stands in for Settlement.sol - only {ListingManager-confirmPayment} is needed for these tests, not a
    ///      full Settlement.pay() flow (already covered by Phase 4's own tests).
    address internal settlementStandIn = makeAddr("settlementStandIn");
    /// @dev Stands in for SettlementConditions.sol / a poke - lets tests simulate a price-threshold resolution
    ///      directly, without wiring in the full SettlementConditions contract.
    address internal priceController = makeAddr("priceController");

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal backer1 = makeAddr("backer1");
    address internal backer2 = makeAddr("backer2");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant PRICE = 2 ether;
    uint256 internal constant WINDOW = 72 hours;
    uint256 internal constant PER_SLOT_LOCKED = 3 ether; // ceilDiv(3 * PRICE, 2)
    uint256 internal constant HALF_PRICE = 1 ether; // PRICE / 2
    uint256 internal constant REMAINING_LOCKED = 2 ether; // PER_SLOT_LOCKED - HALF_PRICE

    function setUp() public {
        // Four-way circular wiring, resolved via CREATE nonce prediction exactly as in Settlement.t.sol /
        // SpectralMarket.t.sol / SettlementConditions.t.sol: IntegrityBond and ListingManager both need
        // DisputeManager's address before it exists, and DisputeManager needs all three others' addresses, which
        // *do* already exist by the time it deploys.
        uint256 nonce = vm.getNonce(address(this));
        address predictedLm = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedMarket = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedDm = vm.computeCreateAddress(address(this), nonce + 3);

        address[] memory bondControllers = new address[](2);
        bondControllers[0] = predictedLm;
        bondControllers[1] = predictedDm;
        bond = new IntegrityBond(bondControllers);

        address[] memory lmControllers = new address[](2);
        lmControllers[0] = settlementStandIn;
        lmControllers[1] = predictedDm;
        lm = new ListingManager(bond, lmControllers);
        assertEq(address(lm), predictedLm, "CREATE nonce prediction drifted (lm)");

        address[] memory marketControllers = new address[](2);
        marketControllers[0] = priceController;
        marketControllers[1] = predictedDm;
        market = new SpectralMarket(marketControllers, ISettlementConditionsHook(address(0)), address(0));
        assertEq(address(market), predictedMarket, "CREATE nonce prediction drifted (market)");

        dm = new DisputeManager(lm, bond, market, DeveloperPool(payable(address(0))));
        assertEq(address(dm), predictedDm, "CREATE nonce prediction drifted (dm)");

        vm.deal(seller, 1000 ether);
        vm.prank(seller);
        bond.deposit{value: 100 ether}();

        vm.deal(buyer, 1000 ether);
        vm.deal(backer1, 1000 ether);
        vm.deal(backer2, 1000 ether);
        vm.deal(stranger, 1000 ether);
    }

    /// @dev Creates a fresh listing (price PRICE, 1 slot, window WINDOW) and confirms payment for slot 0 with
    ///      `buyer` as the buyer of record, returning the listingId. slotIndex is always 0.
    function _openConfirmedListing() internal returns (uint256 listingId) {
        vm.prank(seller);
        listingId = lm.createListing(PRICE, 1, WINDOW);

        vm.prank(settlementStandIn);
        lm.confirmPayment(listingId, 0, buyer);
    }

    function _marketId(uint256 listingId, uint256 slotIndex) internal view returns (uint256) {
        return dm.marketIdOf(listingId, slotIndex);
    }

    /// @dev Binary-searches the largest `shares` of `side` in `marketId` whose LMSRMath cost does not exceed
    ///      `budget`, so a test can spend a fixed dollar budget without needing an analytic cost inverse.
    function _maxSharesForBudget(uint256 marketId, SpectralMarket.Side side, uint256 budget)
        internal
        view
        returns (uint256)
    {
        (SD59x18 b, SD59x18 qGuilty, SD59x18 qInnocent,,,,) = market.markets(marketId);
        uint256 lo = 0;
        uint256 hi = budget * 2; // shares are never worth less than 0.5 * dollar spent, so this is a safe upper bound
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            SD59x18 dq = sd(int256(mid));
            SD59x18 costFixed = side == SpectralMarket.Side.Guilty
                ? LMSRMath.costOfTrade(qGuilty, qInnocent, dq, ZERO, b)
                : LMSRMath.costOfTrade(qGuilty, qInnocent, ZERO, dq, b);
            if (uint256(SD59x18.unwrap(costFixed)) <= budget) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }

    // ── fundGuiltySide: unit ───────────────────────────────────────────────────────────────────────────────────

    function test_FundGuiltySidePartialContributionDoesNotOpenMarket() public {
        uint256 listingId = _openConfirmedListing();
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE / 4}(listingId, 0);

        assertEq(dm.guiltyFundingTotal(marketId), HALF_PRICE / 4);
        (bool opened,) = dm.disputes(marketId);
        assertFalse(opened);
        (,,,, bool open,,) = market.markets(marketId);
        assertFalse(open);
    }

    function test_FundGuiltySideOvershootRefundsExcess() public {
        uint256 listingId = _openConfirmedListing();
        uint256 marketId = _marketId(listingId, 0);
        uint256 overshoot = 0.4 ether;
        uint256 buyerBefore = buyer.balance;

        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE + overshoot}(listingId, 0);

        assertEq(buyerBefore - buyer.balance, HALF_PRICE, "only the exact remaining amount should be spent");
        assertEq(dm.guiltyFundingTotal(marketId), HALF_PRICE);
        (,,,, bool open,,) = market.markets(marketId);
        assertTrue(open, "threshold reached, market should open despite the overshoot");
    }

    function test_FundGuiltySideExactThresholdOpensMarketAndDrawsMatchingIB() public {
        uint256 listingId = _openConfirmedListing();
        uint256 marketId = _marketId(listingId, 0);

        vm.expectEmit(true, true, true, true, address(dm));
        emit DisputeManager.DisputeOpened(marketId, listingId, 0, seller, HALF_PRICE);

        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE}(listingId, 0);

        (, SD59x18 qGuilty, SD59x18 qInnocent,, bool open,,) = market.markets(marketId);
        assertTrue(open);
        assertEq(uint256(SD59x18.unwrap(qGuilty)), HALF_PRICE * 2);
        assertEq(uint256(SD59x18.unwrap(qInnocent)), HALF_PRICE * 2);
        assertEq(market.sharesOf(marketId, SpectralMarket.Side.Guilty, buyer), HALF_PRICE * 2);
        assertEq(market.sharesOf(marketId, SpectralMarket.Side.Innocent, seller), HALF_PRICE * 2);

        (uint256 total, uint256 locked) = bond.bonds(seller);
        assertEq(total, 100 ether - HALF_PRICE);
        assertEq(locked, PER_SLOT_LOCKED - HALF_PRICE, "only the drawn half should be released from locked");

        (ListingManager.SlotStatus status,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Disputed));
    }

    function test_FundGuiltySideMultipleFundersCreditProportionally() public {
        uint256 listingId = _openConfirmedListing();
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(backer1);
        dm.fundGuiltySide{value: 0.3 ether}(listingId, 0);
        vm.prank(backer2);
        dm.fundGuiltySide{value: 0.7 ether}(listingId, 0);

        assertEq(market.sharesOf(marketId, SpectralMarket.Side.Guilty, backer1), 0.6 ether);
        assertEq(market.sharesOf(marketId, SpectralMarket.Side.Guilty, backer2), 1.4 ether);
        assertEq(dm.guiltyFunderCount(marketId), 2);
        assertEq(dm.guiltyFunderAt(marketId, 0), backer1);
        assertEq(dm.guiltyFunderAt(marketId, 1), backer2);
    }

    function test_FundGuiltySideRepeatedContributionsFromSameFunderAccumulate() public {
        uint256 listingId = _openConfirmedListing();
        uint256 marketId = _marketId(listingId, 0);

        vm.startPrank(buyer);
        dm.fundGuiltySide{value: 0.2 ether}(listingId, 0);
        dm.fundGuiltySide{value: 0.3 ether}(listingId, 0);
        vm.stopPrank();

        assertEq(dm.guiltyFunderCount(marketId), 1, "same funder twice should not duplicate the funders array");
        assertEq(dm.guiltyContributionOf(marketId, buyer), 0.5 ether);
    }

    // ── fundGuiltySide: reverts ────────────────────────────────────────────────────────────────────────────────

    function test_FundGuiltySideRevertsOnZeroValue() public {
        uint256 listingId = _openConfirmedListing();
        vm.prank(buyer);
        vm.expectRevert(DisputeManager.ZeroAmount.selector);
        dm.fundGuiltySide{value: 0}(listingId, 0);
    }

    function test_FundGuiltySideRevertsOnNonexistentListing() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.ListingNotFound.selector, 999));
        dm.fundGuiltySide{value: 1 ether}(999, 0);
    }

    function test_FundGuiltySideRevertsOnOutOfRangeSlot() public {
        uint256 listingId = _openConfirmedListing();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.SlotIndexOutOfRange.selector, 1, 1));
        dm.fundGuiltySide{value: 1 ether}(listingId, 1);
    }

    function test_FundGuiltySideRevertsWhenSlotNeverPaid() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.SlotNotDisputable.selector, listingId, 0));
        dm.fundGuiltySide{value: 1 ether}(listingId, 0);
    }

    function test_FundGuiltySideRevertsAfterWindowExpired() public {
        uint256 listingId = _openConfirmedListing();
        (, uint256 deadline,) = lm.slots(listingId, 0);

        vm.warp(deadline);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.WindowExpired.selector, listingId, 0, deadline));
        dm.fundGuiltySide{value: 1 ether}(listingId, 0);
    }

    /// @notice Direct regression test named in the build strategy: a dispute opened one block before window
    ///         expiry keeps the slot locked regardless of remaining window time - the mirror image is that
    ///         funding must still succeed right up to (but not at) the deadline.
    function test_FundGuiltySideOneSecondBeforeExpiryStillSucceeds() public {
        uint256 listingId = _openConfirmedListing();
        uint256 marketId = _marketId(listingId, 0);
        (, uint256 deadline,) = lm.slots(listingId, 0);

        vm.warp(deadline - 1);
        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE}(listingId, 0);

        (,,,, bool open,,) = market.markets(marketId);
        assertTrue(open);
    }

    function test_FundGuiltySideRevertsAfterDisputeAlreadyOpen() public {
        uint256 listingId = _openConfirmedListing();
        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE}(listingId, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.SlotNotDisputable.selector, listingId, 0));
        dm.fundGuiltySide{value: 1}(listingId, 0);
    }

    function test_FundGuiltySideRevertsWhenPriceTooSmallToDispute() public {
        vm.prank(seller);
        uint256 listingId = lm.createListing(1, 1, WINDOW); // price = 1 wei -> halfPrice = 0
        vm.prank(settlementStandIn);
        lm.confirmPayment(listingId, 0, buyer);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.PriceTooSmallToDispute.selector, listingId, 1));
        dm.fundGuiltySide{value: 1}(listingId, 0);
    }

    // ── fundGuiltySide: path independence ──────────────────────────────────────────────────────────────────────

    /// @notice Direct regression test named in the build strategy: funding the Guilty side in different orders
    ///         still produces an unbiased, identical opening state (Section 2.6.1) - the pre-market accumulation
    ///         phase performs no AMM pricing at all, so order can only ever affect the recorded funders' array
    ///         order, never the final quantities.
    function test_FundGuiltySideOrderIndependence() public {
        uint256 listingIdA = _openConfirmedListing();
        uint256 marketIdA = _marketId(listingIdA, 0);
        vm.prank(backer1);
        dm.fundGuiltySide{value: 0.3 ether}(listingIdA, 0);
        vm.prank(backer2);
        dm.fundGuiltySide{value: 0.7 ether}(listingIdA, 0);

        uint256 listingIdB = _openConfirmedListing();
        uint256 marketIdB = _marketId(listingIdB, 0);
        vm.prank(backer2);
        dm.fundGuiltySide{value: 0.7 ether}(listingIdB, 0);
        vm.prank(backer1);
        dm.fundGuiltySide{value: 0.3 ether}(listingIdB, 0);

        (, SD59x18 qGuiltyA, SD59x18 qInnocentA,,,,) = market.markets(marketIdA);
        (, SD59x18 qGuiltyB, SD59x18 qInnocentB,,,,) = market.markets(marketIdB);
        assertEq(SD59x18.unwrap(qGuiltyA), SD59x18.unwrap(qGuiltyB));
        assertEq(SD59x18.unwrap(qInnocentA), SD59x18.unwrap(qInnocentB));
        assertEq(
            market.sharesOf(marketIdA, SpectralMarket.Side.Guilty, backer1),
            market.sharesOf(marketIdB, SpectralMarket.Side.Guilty, backer1)
        );
    }

    /// @notice Direct regression test named in the build strategy: a 1,000-wallet split of a given trade volume
    ///         costs the same as one wallet (Section 2.6.4's path-independence claim). Uses 20 wallets here for
    ///         test speed; the identity being verified does not depend on the wallet count.
    function test_FundGuiltySideNWalletSplitMatchesSingleWallet() public {
        uint256 listingIdSingle = _openConfirmedListing();
        uint256 marketIdSingle = _marketId(listingIdSingle, 0);
        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE}(listingIdSingle, 0);

        uint256 listingIdSplit = _openConfirmedListing();
        uint256 marketIdSplit = _marketId(listingIdSplit, 0);
        uint256 n = 20;
        uint256 perWallet = HALF_PRICE / n;
        for (uint256 i = 0; i < n; i++) {
            address wallet = makeAddr(string.concat("splitWallet", vm.toString(i)));
            vm.deal(wallet, perWallet);
            vm.prank(wallet);
            dm.fundGuiltySide{value: perWallet}(listingIdSplit, 0);
        }

        (, SD59x18 qGuiltySingle, SD59x18 qInnocentSingle,,,,) = market.markets(marketIdSingle);
        (, SD59x18 qGuiltySplit, SD59x18 qInnocentSplit,,,,) = market.markets(marketIdSplit);
        assertEq(SD59x18.unwrap(qGuiltySingle), SD59x18.unwrap(qGuiltySplit));
        assertEq(SD59x18.unwrap(qInnocentSingle), SD59x18.unwrap(qInnocentSplit));
    }

    // ── fundGuiltySide: adversarial ────────────────────────────────────────────────────────────────────────────

    /// @notice Direct regression test named in the build strategy: a seller funded with *only* the 0.995P sale
    ///         proceeds cannot force resolution at the 93% resolution threshold - the concrete regression for the
    ///         finding that originally drove the threshold change from 70%/75%, still true after the later
    ///         unification onto a single 93%/1-hour cumulative condition (no more separate instant threshold).
    ///         Simulates having received sale proceeds via vm.deal rather than a real Settlement.pay() call, since
    ///         Settlement's own correctness is already covered in Phase 4.
    function test_SellerDefendingWithOnlySaleProceedsCannotReachNinetyThreePercent() public {
        uint256 listingId = _openConfirmedListing();
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE}(listingId, 0);

        uint256 saleProceeds = (PRICE * 995) / 1000; // 0.995 * P
        vm.deal(seller, saleProceeds);

        uint256 affordableShares = _maxSharesForBudget(marketId, SpectralMarket.Side.Innocent, saleProceeds);
        vm.prank(seller);
        market.buy{value: saleProceeds}(marketId, SpectralMarket.Side.Innocent, affordableShares);

        (uint256 pGuilty, uint256 pInnocent) = market.currentPrice(marketId);
        assertLt(pInnocent, 0.93e18, "0.995P alone must not be enough to reach the 93% resolution threshold");
        assertGt(pGuilty, 0.07e18);
    }

    function test_ReentrantFunderCannotReenterFundGuiltySideDuringRefund() public {
        uint256 listingId = _openConfirmedListing();
        ReentrantFunder attacker = new ReentrantFunder(dm);
        vm.deal(address(attacker), 10 ether);

        attacker.setReentryCalldata(
            abi.encodeWithSelector(DisputeManager.fundGuiltySide.selector, listingId, uint256(0))
        );
        attacker.attackFund(listingId, 0, HALF_PRICE + 1 ether); // overshoot triggers the refund callback

        assertTrue(attacker.reentered());
        assertFalse(attacker.reentrySucceeded(), "reentrant fundGuiltySide should have been blocked");
    }

    // ── mutualClose ────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Opens a confirmed listing's dispute funded solely by `buyer` (no backers) - the only configuration
    ///      under which Section 2.6.10 mutual close can ever be eligible.
    function _openSoleBuyerFundedDispute() internal returns (uint256 listingId, uint256 marketId) {
        listingId = _openConfirmedListing();
        marketId = _marketId(listingId, 0);
        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE}(listingId, 0);
    }

    function test_MutualCloseResolvesWhenBothPartiesAgree() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();

        vm.prank(buyer);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
        (,,,, bool open, bool resolved,) = market.markets(marketId);
        assertTrue(open);
        assertFalse(resolved, "must not resolve on only one party's proposal");

        vm.prank(seller);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
        SpectralMarket.Side winningSide;
        (,,,,, resolved, winningSide) = market.markets(marketId);
        assertTrue(resolved);
        assertEq(uint8(winningSide), uint8(SpectralMarket.Side.Innocent));

        (ListingManager.SlotStatus status,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Removed), "should self-finalize in the same call");
        (uint256 total, uint256 locked) = bond.bonds(seller);
        assertEq(total, 100 ether - HALF_PRICE, "Innocent verdict: only the earlier draw is gone, rest unlocked");
        assertEq(locked, 0);
    }

    function test_MutualCloseNoOpWhenOnlyOnePartyProposes() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();

        vm.prank(buyer);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Guilty);

        (,,,,, bool resolved,) = market.markets(marketId);
        assertFalse(resolved);
    }

    function test_MutualCloseNoOpWhenPartiesDisagree() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();

        vm.prank(buyer);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Guilty);
        vm.prank(seller);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);

        (,,,,, bool resolved,) = market.markets(marketId);
        assertFalse(resolved, "disagreeing verdicts must not resolve anything");
    }

    function test_MutualCloseAllowsChangingProposalBeforeAgreement() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();

        vm.prank(buyer);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Guilty);
        vm.prank(buyer);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent); // buyer changes their mind

        vm.prank(seller);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);

        (,,,,, bool resolved, SpectralMarket.Side winningSide) = market.markets(marketId);
        assertTrue(resolved);
        assertEq(uint8(winningSide), uint8(SpectralMarket.Side.Innocent));
    }

    function test_MutualCloseRevertsWhenCallerNotPartyToDispute() public {
        (uint256 listingId,) = _openSoleBuyerFundedDispute();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.NotPartyToDispute.selector, stranger, buyer, seller));
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
    }

    function test_MutualCloseRevertsWhenDisputeNotOpen() public {
        uint256 listingId = _openConfirmedListing(); // funded partially, threshold never crossed
        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE / 2}(listingId, 0);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.DisputeNotOpen.selector, _marketId(listingId, 0)));
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
    }

    function test_MutualCloseRevertsWhenMarketAlreadyResolvedByOtherMeans() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();

        vm.prank(priceController);
        market.resolveMarket(marketId, SpectralMarket.Side.Guilty);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.DisputeAlreadyResolved.selector, marketId));
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Guilty);
    }

    function test_MutualCloseRevertsWhenAlreadyFinalized() public {
        (uint256 listingId,) = _openSoleBuyerFundedDispute();
        vm.prank(buyer);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
        vm.prank(seller);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(DisputeManager.DisputeAlreadyFinalized.selector, _marketId(listingId, 0))
        );
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
    }

    /// @notice Direct regression test named in the build strategy: mutualClose fails the instant a third party
    ///         holds even a single share on either side.
    function test_MutualCloseRevertsOnceThirdPartyBuysGuiltyShares() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();

        vm.prank(backer1);
        market.buy{value: 0.1 ether}(marketId, SpectralMarket.Side.Guilty, 0.05 ether);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                DisputeManager.ThirdPartyParticipation.selector, marketId, SpectralMarket.Side.Guilty
            )
        );
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
    }

    /// @notice Direct regression test named in the build strategy: mutualClose stays permanently disabled even
    ///         once that third party later fully exits their position - the path must not reopen.
    function test_MutualCloseStaysDisabledEvenAfterThirdPartyFullyExits() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();

        vm.prank(backer1);
        uint256 cost = market.buy{value: 0.1 ether}(marketId, SpectralMarket.Side.Guilty, 0.05 ether);
        uint256 heldByBacker = market.sharesOf(marketId, SpectralMarket.Side.Guilty, backer1);

        vm.prank(backer1);
        market.sell(marketId, SpectralMarket.Side.Guilty, heldByBacker, 0);

        // sanity: the round trip really did return the buyer's current balance to the full outstanding total
        (, SD59x18 qGuilty,,,,,) = market.markets(marketId);
        assertEq(market.sharesOf(marketId, SpectralMarket.Side.Guilty, buyer), uint256(SD59x18.unwrap(qGuilty)));
        assertEq(market.sharesOf(marketId, SpectralMarket.Side.Guilty, backer1), 0);
        assertGt(cost, 0);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                DisputeManager.ThirdPartyParticipation.selector, marketId, SpectralMarket.Side.Guilty
            )
        );
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
    }

    function test_MutualCloseRevertsOnceThirdPartyBuysInnocentShares() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();

        vm.prank(backer1);
        market.buy{value: 0.1 ether}(marketId, SpectralMarket.Side.Innocent, 0.05 ether);

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                DisputeManager.ThirdPartyParticipation.selector, marketId, SpectralMarket.Side.Innocent
            )
        );
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
    }

    function test_MutualCloseStaysEligibleWhenBuyerAloneBuysMoreGuiltyShares() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();

        vm.prank(buyer);
        market.buy{value: 0.1 ether}(marketId, SpectralMarket.Side.Guilty, 0.05 ether);

        vm.prank(buyer);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
        vm.prank(seller);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);

        (,,,,, bool resolved,) = market.markets(marketId);
        assertTrue(resolved, "buyer trading more on their own side must not disable mutual close");
    }

    function test_MutualCloseStaysEligibleWhenSellerAloneBuysMoreInnocentShares() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();

        vm.deal(seller, seller.balance + 0.1 ether);
        vm.prank(seller);
        market.buy{value: 0.1 ether}(marketId, SpectralMarket.Side.Innocent, 0.05 ether);

        vm.prank(buyer);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Guilty);
        vm.prank(seller);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Guilty);

        (,,,,, bool resolved,) = market.markets(marketId);
        assertTrue(resolved, "seller defending with sale proceeds on their own side must not disable mutual close");
    }

    /// @notice If more than the buyer alone funded the initial 0.5P threshold, mutual close must be ineligible
    ///         from the moment the market opens - Section 2.6.10 requires the buyer, not backers, funded 100%.
    function test_MutualCloseIneligibleWhenBackersFundedTheInitialThreshold() public {
        uint256 listingId = _openConfirmedListing();
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(backer1);
        dm.fundGuiltySide{value: HALF_PRICE / 2}(listingId, 0);
        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE / 2}(listingId, 0);

        (,,,, bool open,,) = market.markets(marketId);
        assertTrue(open);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                DisputeManager.ThirdPartyParticipation.selector, marketId, SpectralMarket.Side.Guilty
            )
        );
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
    }

    // ── finalizeDispute ────────────────────────────────────────────────────────────────────────────────────────

    function test_FinalizeDisputeGuiltyVerdictSlashesRemainingLockedToBuyer() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();

        vm.prank(priceController);
        market.resolveMarket(marketId, SpectralMarket.Side.Guilty);

        vm.expectEmit(true, true, true, true, address(dm));
        emit DisputeManager.DisputeFinalized(marketId, SpectralMarket.Side.Guilty, REMAINING_LOCKED);

        vm.prank(stranger); // permissionless
        dm.finalizeDispute(listingId, 0);

        (uint256 total, uint256 locked) = bond.bonds(seller);
        assertEq(total, 100 ether - HALF_PRICE - REMAINING_LOCKED, "seller loses 1.5P total across both draws");
        assertEq(locked, 0);
        assertEq(bond.claimable(buyer), REMAINING_LOCKED, "restitution goes to the buyer of record, not the poker");

        (ListingManager.SlotStatus status,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Removed));

        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        bond.claim();
        assertEq(buyer.balance - buyerBefore, REMAINING_LOCKED);
    }

    function test_FinalizeDisputeInnocentVerdictUnlocksRemainingToSeller() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();

        vm.prank(priceController);
        market.resolveMarket(marketId, SpectralMarket.Side.Innocent);

        dm.finalizeDispute(listingId, 0); // permissionless - no prank needed

        (uint256 total, uint256 locked) = bond.bonds(seller);
        assertEq(total, 100 ether - HALF_PRICE, "only the earlier draw is gone; nothing slashed on Innocent");
        assertEq(locked, 0);
        assertEq(bond.freeIB(seller), 100 ether - HALF_PRICE);
        assertEq(bond.claimable(buyer), 0);

        (ListingManager.SlotStatus status,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Removed));
    }

    function test_FinalizeDisputeRevertsWhenDisputeNotOpen() public {
        uint256 listingId = _openConfirmedListing();
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.DisputeNotOpen.selector, _marketId(listingId, 0)));
        dm.finalizeDispute(listingId, 0);
    }

    function test_FinalizeDisputeRevertsWhenMarketNotResolvedYet() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.MarketNotResolvedYet.selector, marketId));
        dm.finalizeDispute(listingId, 0);
    }

    function test_FinalizeDisputeRevertsWhenAlreadyFinalized() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();
        vm.prank(priceController);
        market.resolveMarket(marketId, SpectralMarket.Side.Innocent);
        dm.finalizeDispute(listingId, 0);

        vm.expectRevert(abi.encodeWithSelector(DisputeManager.DisputeAlreadyFinalized.selector, marketId));
        dm.finalizeDispute(listingId, 0);
    }

    /// @notice finalizeDispute must never be called for a mutualClose-resolved dispute (it already self-finalizes
    ///         inline), but if someone redundantly tries anyway, it must fail loudly rather than double-apply.
    function test_FinalizeDisputeAfterMutualCloseAlreadyFinalizedReverts() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();
        vm.prank(buyer);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
        vm.prank(seller);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);

        vm.expectRevert(abi.encodeWithSelector(DisputeManager.DisputeAlreadyFinalized.selector, marketId));
        dm.finalizeDispute(listingId, 0);
    }

    /// @notice Odd-price rounding: the half-draw floors and the per-slot lock ceils, so the two together must
    ///         still drain the slot's Locked IB to exactly zero with no dust stranded, regardless of parity.
    function testFuzz_FinalizeDisputeNeverStrandsDustRegardlessOfPriceParity(uint256 priceSeed) public {
        uint256 price = bound(priceSeed, 2, 1_000_000 ether);
        uint256 perSlotLocked = (price * 3 + 1) / 2; // ceilDiv mirrored
        uint256 halfPrice = price / 2;
        vm.assume(halfPrice > 0);

        address freshSeller = makeAddr(string.concat("oddSeller", vm.toString(priceSeed)));
        vm.deal(freshSeller, perSlotLocked);
        vm.prank(freshSeller);
        bond.deposit{value: perSlotLocked}();

        vm.prank(freshSeller);
        uint256 listingId = lm.createListing(price, 1, WINDOW);
        vm.prank(settlementStandIn);
        lm.confirmPayment(listingId, 0, buyer);

        address funder = makeAddr(string.concat("oddFunder", vm.toString(priceSeed)));
        vm.deal(funder, halfPrice);
        vm.prank(funder);
        dm.fundGuiltySide{value: halfPrice}(listingId, 0);

        uint256 marketId = _marketId(listingId, 0);
        vm.prank(priceController);
        market.resolveMarket(marketId, SpectralMarket.Side.Guilty);
        dm.finalizeDispute(listingId, 0);

        (uint256 total, uint256 locked) = bond.bonds(freshSeller);
        assertEq(total, 0, "seller's entire deposit must be drained across both draws, no dust left behind");
        assertEq(locked, 0);
    }

    // ── Adversarial: uncooperative parties cannot block finalization ──────────────────────────────────────────

    function test_FinalizeDisputeSucceedsEvenWhenSellerRefusesEth() public {
        RevertingReceiver badSeller = new RevertingReceiver(bond, lm);
        vm.deal(address(badSeller), 100 ether);
        uint256 listingId = badSeller.depositAndCreateListing{value: 100 ether}(PRICE, 1, WINDOW);
        vm.prank(settlementStandIn);
        lm.confirmPayment(listingId, 0, buyer);

        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE}(listingId, 0);
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(priceController);
        market.resolveMarket(marketId, SpectralMarket.Side.Innocent);
        dm.finalizeDispute(listingId, 0); // must not revert despite the seller's reverting receive()

        (ListingManager.SlotStatus status,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Removed));
    }

    function test_FinalizeDisputeSucceedsEvenWhenBuyerRefusesEth() public {
        RevertingReceiver badBuyer = new RevertingReceiver(bond, lm);
        vm.prank(seller);
        uint256 listingId = lm.createListing(PRICE, 1, WINDOW);
        vm.prank(settlementStandIn);
        lm.confirmPayment(listingId, 0, address(badBuyer));

        vm.prank(backer1);
        dm.fundGuiltySide{value: HALF_PRICE}(listingId, 0);
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(priceController);
        market.resolveMarket(marketId, SpectralMarket.Side.Guilty);
        dm.finalizeDispute(listingId, 0); // must not revert despite the buyer's reverting receive() - slash is a
        // pull-payment credit, not a push

        assertEq(bond.claimable(address(badBuyer)), REMAINING_LOCKED);
        (ListingManager.SlotStatus status,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Removed));
    }

    // ── Adversarial: gas-safety cap on distinct Guilty-side funders ───────────────────────────────────────────

    function test_FundGuiltySideRevertsWhenExceedingMaxFunders() public {
        uint256 listingId = _openConfirmedListing();
        uint256 max = dm.MAX_GUILTY_FUNDERS();

        // Each of the first `max` funders contributes a tiny, non-threshold-crossing amount, leaving plenty of
        // "remaining" room so the market does not open early and lock out further funders before the cap is hit.
        for (uint256 i = 0; i < max; i++) {
            address funder = makeAddr(string.concat("capFunder", vm.toString(i)));
            vm.deal(funder, 1);
            vm.prank(funder);
            dm.fundGuiltySide{value: 1}(listingId, 0);
        }
        assertEq(dm.guiltyFunderCount(_marketId(listingId, 0)), max);

        address oneTooMany = makeAddr("oneTooManyFunder");
        vm.deal(oneTooMany, 1);
        vm.prank(oneTooMany);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.TooManyGuiltyFunders.selector, max, max));
        dm.fundGuiltySide{value: 1}(listingId, 0);
    }
}

/// @notice Section 2.6.7's Protocol Liquidity Buffer, exercised through a real DeveloperPool wired into
///         DisputeManager - the main DisputeManagerTest above deliberately disables this (developerPool =
///         address(0)) to isolate the rest of the contract's behavior from it.
contract DisputeManagerLiquidityBufferTest is Test {
    IntegrityBond internal bond;
    ListingManager internal lm;
    SpectralMarket internal market;
    DeveloperPool internal devPool;
    DisputeManager internal dm;

    address internal settlementStandIn = makeAddr("bufferSettlementStandIn");
    address internal priceController = makeAddr("bufferPriceController");
    address internal developer = makeAddr("bufferDeveloper");
    address internal withdrawalRecipient = makeAddr("bufferWithdrawalRecipient");
    address internal seller = makeAddr("bufferSeller");
    address internal buyer = makeAddr("bufferBuyer");

    uint256 internal constant WINDOW = 72 hours;

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedLm = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedDm = vm.computeCreateAddress(address(this), nonce + 4);

        address[] memory bondControllers = new address[](2);
        bondControllers[0] = predictedLm;
        bondControllers[1] = predictedDm;
        bond = new IntegrityBond(bondControllers);

        address[] memory lmControllers = new address[](2);
        lmControllers[0] = settlementStandIn;
        lmControllers[1] = predictedDm;
        lm = new ListingManager(bond, lmControllers);
        assertEq(address(lm), predictedLm, "CREATE nonce prediction drifted (lm)");

        address[] memory devPoolControllers = new address[](1);
        devPoolControllers[0] = predictedDm;
        devPool = new DeveloperPool(developer, withdrawalRecipient, devPoolControllers);

        address[] memory marketControllers = new address[](2);
        marketControllers[0] = priceController;
        marketControllers[1] = predictedDm;
        market = new SpectralMarket(marketControllers, ISettlementConditionsHook(address(0)), address(devPool));

        dm = new DisputeManager(lm, bond, market, devPool);
        assertEq(address(dm), predictedDm, "CREATE nonce prediction drifted (dm)");

        vm.deal(seller, 1000 ether);
        vm.prank(seller);
        bond.deposit{value: 100 ether}();
        vm.deal(buyer, 1000 ether);
    }

    function _openConfirmedListing(uint256 price) internal returns (uint256 listingId) {
        vm.prank(seller);
        listingId = lm.createListing(price, 1, WINDOW);
        vm.prank(settlementStandIn);
        lm.confirmPayment(listingId, 0, buyer);
    }

    /// @notice A dispute whose 1P-total initial depth is below the $5-equivalent floor gets topped up to exactly
    ///         that floor, split symmetrically, with DeveloperPool.sol credited on both sides.
    function test_SmallPriceDisputeGetsToppedUpToMinLiquidityDepth() public {
        vm.deal(address(devPool), 10 ether);
        uint256 price = 1 ether; // 1P total = 1 ether, below the 5e18 floor
        uint256 listingId = _openConfirmedListing(price);
        uint256 marketId = dm.marketIdOf(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: price / 2}(listingId, 0);

        (, SD59x18 qGuilty, SD59x18 qInnocent,, bool open,,) = market.markets(marketId);
        assertTrue(open);
        assertEq(
            uint256(SD59x18.unwrap(qGuilty)),
            dm.MIN_LIQUIDITY_DEPTH(),
            "depth must be topped up to exactly $5-equivalent"
        );
        assertEq(uint256(SD59x18.unwrap(qInnocent)), dm.MIN_LIQUIDITY_DEPTH());

        uint256 expectedPerSide = (dm.MIN_LIQUIDITY_DEPTH() - price) / 2;
        assertEq(market.sharesOf(marketId, SpectralMarket.Side.Guilty, address(devPool)), expectedPerSide * 2);
        assertEq(market.sharesOf(marketId, SpectralMarket.Side.Innocent, address(devPool)), expectedPerSide * 2);
    }

    function test_LargePriceDisputeGetsNoTopUp() public {
        vm.deal(address(devPool), 10 ether);
        uint256 price = 10 ether; // 1P total = 10 ether, already above the 5e18 floor
        uint256 listingId = _openConfirmedListing(price);
        uint256 marketId = dm.marketIdOf(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: price / 2}(listingId, 0);

        (, SD59x18 qGuilty,,,,,) = market.markets(marketId);
        assertEq(uint256(SD59x18.unwrap(qGuilty)), price, "no top-up expected; depth already clears the floor");
        assertEq(market.sharesOf(marketId, SpectralMarket.Side.Guilty, address(devPool)), 0);
    }

    /// @notice An underfunded DeveloperPool degrades the top-up gracefully rather than blocking the dispute from
    ///         opening at all - mirroring SettlementConditions' poke-bounty degradation and DeveloperPool's own
    ///         pullLiquidityBuffer capping.
    function test_UnderfundedDeveloperPoolGivesPartialTopUpAndStillOpens() public {
        uint256 price = 1 ether;
        uint256 desiredPerSide = (5 ether - price) / 2;
        uint256 availableInPool = desiredPerSide / 2; // deliberately less than what's desired
        vm.deal(address(devPool), availableInPool);

        uint256 listingId = _openConfirmedListing(price);
        uint256 marketId = dm.marketIdOf(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: price / 2}(listingId, 0);

        (,,,, bool open,,) = market.markets(marketId);
        assertTrue(open, "an underfunded buffer must never block the dispute from opening");
        // DisputeManager requests 2x desiredPerSide (since the top-up is credited on both sides), DevPool sends
        // only its full available balance (`availableInPool`), and that gets split back in half per side - so
        // the shares credited on one side are exactly `availableInPool` (perSide * 2 = (availableInPool/2) * 2).
        assertEq(
            market.sharesOf(marketId, SpectralMarket.Side.Guilty, address(devPool)),
            availableInPool,
            "top-up shrinks to whatever DeveloperPool actually had, split across both sides"
        );
        assertEq(address(devPool).balance, 0);
    }

    function test_EmptyDeveloperPoolGivesNoTopUpAndStillOpens() public {
        uint256 price = 1 ether; // devPool starts at zero balance - never funded in this test
        uint256 listingId = _openConfirmedListing(price);
        uint256 marketId = dm.marketIdOf(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: price / 2}(listingId, 0);

        (, SD59x18 qGuilty,,, bool open,,) = market.markets(marketId);
        assertTrue(open);
        assertEq(uint256(SD59x18.unwrap(qGuilty)), price);
        assertEq(market.sharesOf(marketId, SpectralMarket.Side.Guilty, address(devPool)), 0);
    }

    /// @notice DeveloperPool's liquidity-buffer stake is credited identically on both sides and can never be
    ///         actively traded (DeveloperPool.sol exposes no function that calls buy/sell) - whichever verdict
    ///         wins, it recovers exactly what it put in. The buyer and seller have nothing to gain by colluding
    ///         on a verdict at its expense, so unlike a genuine third-party backer, its presence must not block
    ///         mutualClose.
    function test_MutualCloseSucceedsDespiteLiquidityBufferTopUp() public {
        vm.deal(address(devPool), 10 ether);
        uint256 price = 1 ether;
        uint256 listingId = _openConfirmedListing(price);
        uint256 marketId = dm.marketIdOf(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: price / 2}(listingId, 0);

        uint256 devPoolGuiltyBefore = market.sharesOf(marketId, SpectralMarket.Side.Guilty, address(devPool));
        assertGt(devPoolGuiltyBefore, 0, "this test only proves what it claims if the top-up actually happened");
        uint256 devPoolBalanceBefore = address(devPool).balance;

        vm.prank(buyer);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
        vm.prank(seller);
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);

        (,,,,, bool resolved, SpectralMarket.Side winningSide) = market.markets(marketId);
        assertTrue(resolved, "mutualClose must succeed despite DeveloperPool holding a neutral stake on both sides");
        assertEq(uint8(winningSide), uint8(SpectralMarket.Side.Innocent));

        // _finalize auto-triggers DeveloperPool.redeemFromMarket in the same transaction - its winning-side
        // (Innocent) shares are claimed automatically, landing back in its own balance with no separate call.
        assertEq(
            market.sharesOf(marketId, SpectralMarket.Side.Innocent, address(devPool)),
            0,
            "DeveloperPool's winning-side shares must be auto-redeemed, not left outstanding"
        );
        assertEq(
            address(devPool).balance,
            devPoolBalanceBefore + devPoolGuiltyBefore,
            "DeveloperPool must recover exactly what it contributed, automatically"
        );
    }

    /// @notice The same auto-redeem must fire on the other resolution path too - finalizeDispute, reached after
    ///         price-threshold/poke resolution rather than mutualClose. _finalize is the shared helper, but both
    ///         call sites are worth proving independently rather than assuming the shared helper is enough.
    function test_FinalizeDisputeAutoRedeemsDeveloperPoolAfterLiquidityBufferTopUp() public {
        vm.deal(address(devPool), 10 ether);
        uint256 price = 1 ether;
        uint256 listingId = _openConfirmedListing(price);
        uint256 marketId = dm.marketIdOf(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: price / 2}(listingId, 0);

        uint256 devPoolGuiltyBefore = market.sharesOf(marketId, SpectralMarket.Side.Guilty, address(devPool));
        assertGt(devPoolGuiltyBefore, 0, "this test only proves what it claims if the top-up actually happened");
        uint256 devPoolBalanceBefore = address(devPool).balance;

        vm.prank(priceController);
        market.resolveMarket(marketId, SpectralMarket.Side.Guilty);

        vm.prank(buyer); // permissionless in practice, but any caller works
        dm.finalizeDispute(listingId, 0);

        assertEq(
            market.sharesOf(marketId, SpectralMarket.Side.Guilty, address(devPool)),
            0,
            "DeveloperPool's winning-side shares must be auto-redeemed via finalizeDispute too"
        );
        assertEq(
            address(devPool).balance,
            devPoolBalanceBefore + devPoolGuiltyBefore,
            "DeveloperPool must recover exactly what it contributed, automatically, via this path as well"
        );
    }

    /// @notice Belt-and-suspenders regression: DeveloperPool's exemption must not let a genuine third party hide
    ///         behind it. A real backer trading on top of a buffer-topped-up market still permanently blocks
    ///         mutualClose, identical to Phase 7's original third-party protection.
    function test_GenuineThirdPartyStillBlocksMutualCloseEvenWithLiquidityBufferPresent() public {
        vm.deal(address(devPool), 10 ether);
        uint256 price = 1 ether;
        uint256 listingId = _openConfirmedListing(price);
        uint256 marketId = dm.marketIdOf(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: price / 2}(listingId, 0);

        address backer = makeAddr("bufferTestBacker");
        vm.deal(backer, 10 ether);
        vm.prank(backer);
        market.buy{value: 0.1 ether}(marketId, SpectralMarket.Side.Guilty, 0.05 ether);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                DisputeManager.ThirdPartyParticipation.selector, marketId, SpectralMarket.Side.Guilty
            )
        );
        dm.mutualClose(listingId, 0, SpectralMarket.Side.Innocent);
    }
}
