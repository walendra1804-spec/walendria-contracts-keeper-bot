// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SD59x18, sd, ZERO} from "prb-math/SD59x18.sol";
import {IntegrityBond} from "../src/IntegrityBond.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {SpectralMarket} from "../src/SpectralMarket.sol";
import {ISettlementConditionsHook} from "../src/ISettlementConditionsHook.sol";
import {LMSRMath} from "../src/LMSRMath.sol";
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

    function attackReclaim(uint256 listingId, uint256 slotIndex, uint256 cycle) external {
        dm.reclaimGuiltyFunding(listingId, slotIndex, cycle);
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
        lm = new ListingManager(bond, lmControllers, type(uint256).max);
        assertEq(address(lm), predictedLm, "CREATE nonce prediction drifted (lm)");

        address[] memory marketControllers = new address[](2);
        marketControllers[0] = priceController;
        marketControllers[1] = predictedDm;
        market = new SpectralMarket(marketControllers, ISettlementConditionsHook(address(0)), address(0));
        assertEq(address(market), predictedMarket, "CREATE nonce prediction drifted (market)");

        dm = new DisputeManager(lm, bond, market);
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
        (,,, uint256 cycle) = lm.slots(listingId, slotIndex);
        return dm.marketIdOf(listingId, slotIndex, cycle);
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

        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Disputed));
    }

    /// Regression for the live-testnet exploit: the buyer funds the Guilty side to open the dispute, then
    /// immediately tries to sell the forced opening position straight back into the liquidity it just created,
    /// pocketing a risk-free profit. Both sides' opening positions are locked until the case resolves (Section
    /// 2.6.1), so every attempt reverts and nothing is extracted - reproduced here through the real
    /// fundGuiltySide -> joint-injection -> SpectralMarket path, not a hand-opened market.
    function test_ExploitRegression_OpeningFunderCannotDumpForcedPositionMidDispute() public {
        uint256 listingId = _openConfirmedListing();
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE}(listingId, 0);

        uint256 opening = HALF_PRICE * 2; // credited at 2x the 0.5P stake
        assertEq(market.sharesOf(marketId, SpectralMarket.Side.Guilty, buyer), opening);
        assertEq(
            market.sellableSharesOf(marketId, SpectralMarket.Side.Guilty, buyer),
            0,
            "the whole opening position is locked liquidity"
        );

        uint256 balBefore = buyer.balance;

        // Dump the whole position - reverts.
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.SharesLocked.selector, buyer, opening, 0, opening));
        market.sell(marketId, SpectralMarket.Side.Guilty, opening, 0);

        // Shave even 1 wei off it - still reverts.
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.SharesLocked.selector, buyer, 1, 0, opening));
        market.sell(marketId, SpectralMarket.Side.Guilty, 1, 0);

        assertEq(buyer.balance, balBefore, "no ez money: the funder extracted nothing from its own opening stake");

        // The seller's forced Innocent position is locked identically (whitepaper 2.6.1: "Both positions").
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.SharesLocked.selector, seller, opening, 0, opening));
        market.sell(marketId, SpectralMarket.Side.Innocent, opening, 0);
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
        (, uint256 deadline,,) = lm.slots(listingId, 0);

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
        (, uint256 deadline,,) = lm.slots(listingId, 0);

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

    // ── reclaimGuiltyFunding: below-threshold funding is locked, then reclaimable, never lost ─────────────────────

    function _cycleOf(uint256 listingId, uint256 slotIndex) internal view returns (uint256 cycle) {
        (,,, cycle) = lm.slots(listingId, slotIndex);
    }

    /// @dev The exact scenario from the live bug report: a buyer funds part of the 0.5P threshold, the window
    ///      passes without anyone reaching it, and the contribution must come back in full rather than being
    ///      stranded. Here the slot is still PaymentConfirmed (nobody finalized it), reclaimable purely because
    ///      the deadline elapsed.
    function test_ReclaimAfterWindowExpiryRefundsPartialContribution() public {
        uint256 listingId = _openConfirmedListing();
        uint256 marketId = _marketId(listingId, 0);
        uint256 cycle = _cycleOf(listingId, 0);
        uint256 contribution = (HALF_PRICE * 3) / 10; // 0.3P, below the 0.5P threshold

        vm.prank(buyer);
        dm.fundGuiltySide{value: contribution}(listingId, 0);
        assertEq(address(dm).balance, contribution, "dm holds the accepted contribution before reclaim");

        vm.warp(block.timestamp + WINDOW + 1);
        assertEq(dm.guiltyFundingReclaimable(listingId, 0, cycle, buyer), contribution);

        uint256 buyerBefore = buyer.balance;
        vm.expectEmit(true, true, false, true, address(dm));
        emit DisputeManager.GuiltyFundingReclaimed(marketId, buyer, contribution);
        vm.prank(buyer);
        dm.reclaimGuiltyFunding(listingId, 0, cycle);

        assertEq(buyer.balance - buyerBefore, contribution, "buyer gets back exactly what they funded");
        assertEq(dm.guiltyContributionOf(marketId, buyer), 0, "contribution zeroed");
        assertEq(dm.guiltyFundingTotal(marketId), 0, "total drained");
        assertEq(address(dm).balance, 0, "no funder money left stranded in the contract");
    }

    /// @dev After the window expires and someone permissionlessly recycles the slot to Empty, the cycle is
    ///      unchanged, so the funder reclaims against that same cycle.
    function test_ReclaimAfterFinalizeExpiredSlotRecycled() public {
        uint256 listingId = _openConfirmedListing();
        uint256 cycle = _cycleOf(listingId, 0);
        uint256 contribution = HALF_PRICE / 5;

        vm.prank(backer1);
        dm.fundGuiltySide{value: contribution}(listingId, 0);

        vm.warp(block.timestamp + WINDOW + 1);
        lm.finalizeExpiredSlot(listingId, 0);

        (ListingManager.SlotStatus status,,, uint256 liveCycle) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Empty));
        assertEq(liveCycle, cycle, "finalizeExpiredSlot does not bump the cycle");

        uint256 before = backer1.balance;
        vm.prank(backer1);
        dm.reclaimGuiltyFunding(listingId, 0, cycle);
        assertEq(backer1.balance - before, contribution);
    }

    /// @dev The buyer confirming completion early (before threshold) also closes the funding window: the slot
    ///      leaves PaymentConfirmed, so any partial backer can reclaim.
    function test_ReclaimAfterConfirmCompletionRecycled() public {
        uint256 listingId = _openConfirmedListing();
        uint256 cycle = _cycleOf(listingId, 0);
        uint256 contribution = HALF_PRICE / 3;

        vm.prank(backer1);
        dm.fundGuiltySide{value: contribution}(listingId, 0);

        vm.prank(buyer);
        lm.confirmCompletion(listingId, 0); // slot -> Empty before the threshold was ever reached

        uint256 before = backer1.balance;
        vm.prank(backer1);
        dm.reclaimGuiltyFunding(listingId, 0, cycle);
        assertEq(backer1.balance - before, contribution);
    }

    /// @dev The hardest case: the slot recycles AND is resold, so the live cycle advances past the one the
    ///      funding was recorded under. Passing the explicit original cycle still reclaims it, and the new
    ///      cycle's funding pot is completely independent.
    function test_ReclaimSurvivesResaleUnderNewCycle() public {
        uint256 listingId = _openConfirmedListing();
        uint256 firstCycle = _cycleOf(listingId, 0);
        uint256 contribution = HALF_PRICE / 4;

        vm.prank(backer1);
        dm.fundGuiltySide{value: contribution}(listingId, 0);

        vm.warp(block.timestamp + WINDOW + 1);
        lm.finalizeExpiredSlot(listingId, 0);
        vm.prank(settlementStandIn);
        lm.confirmPayment(listingId, 0, buyer); // resale bumps the cycle
        uint256 secondCycle = _cycleOf(listingId, 0);
        assertEq(secondCycle, firstCycle + 1, "resale bumps the cycle");

        assertEq(dm.guiltyFundingReclaimable(listingId, 0, firstCycle, backer1), contribution);
        uint256 before = backer1.balance;
        vm.prank(backer1);
        dm.reclaimGuiltyFunding(listingId, 0, firstCycle);
        assertEq(backer1.balance - before, contribution);

        assertEq(dm.guiltyFundingReclaimable(listingId, 0, secondCycle, backer1), 0, "new cycle is a separate pot");
    }

    /// @dev While the funding window is still genuinely open (threshold could still be reached), reclaim must be
    ///      refused - otherwise a funder could pull out mid-race and desync a threshold crossing.
    function test_ReclaimRevertsWhileFundingWindowStillOpen() public {
        uint256 listingId = _openConfirmedListing();
        uint256 cycle = _cycleOf(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE / 4}(listingId, 0);

        assertEq(dm.guiltyFundingReclaimable(listingId, 0, cycle, buyer), 0, "not reclaimable while window open");
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.FundingWindowStillOpen.selector, listingId, 0));
        vm.prank(buyer);
        dm.reclaimGuiltyFunding(listingId, 0, cycle);
    }

    /// @dev Once the dispute opens, the funding became locked initial Guilty shares (Section 2.6.1) redeemed at
    ///      resolution - it is not native currency to hand back here.
    function test_ReclaimRevertsAfterDisputeOpened() public {
        (uint256 listingId, uint256 marketId) = _openSoleBuyerFundedDispute();
        uint256 cycle = _cycleOf(listingId, 0);

        assertEq(dm.guiltyFundingReclaimable(listingId, 0, cycle, buyer), 0);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.DisputeAlreadyOpened.selector, marketId));
        vm.prank(buyer);
        dm.reclaimGuiltyFunding(listingId, 0, cycle);
    }

    function test_ReclaimRevertsForNonContributorAndOnDoubleReclaim() public {
        uint256 listingId = _openConfirmedListing();
        uint256 cycle = _cycleOf(listingId, 0);
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(buyer);
        dm.fundGuiltySide{value: HALF_PRICE / 4}(listingId, 0);
        vm.warp(block.timestamp + WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(DisputeManager.NothingToReclaim.selector, marketId, stranger));
        vm.prank(stranger);
        dm.reclaimGuiltyFunding(listingId, 0, cycle);

        vm.prank(buyer);
        dm.reclaimGuiltyFunding(listingId, 0, cycle);
        vm.expectRevert(abi.encodeWithSelector(DisputeManager.NothingToReclaim.selector, marketId, buyer));
        vm.prank(buyer);
        dm.reclaimGuiltyFunding(listingId, 0, cycle);
    }

    /// @dev Two backers, each below-threshold together (0.3P + 0.1P = 0.4P), reclaim independently: one reclaim
    ///      drains only that funder's share and never touches the other's.
    function test_ReclaimMultiFunderIndependence() public {
        uint256 listingId = _openConfirmedListing();
        uint256 cycle = _cycleOf(listingId, 0);
        uint256 marketId = _marketId(listingId, 0);
        uint256 c1 = (HALF_PRICE * 3) / 10; // 0.3P
        uint256 c2 = HALF_PRICE / 10; // 0.1P (total 0.4P < 0.5P: never opens)

        vm.prank(backer1);
        dm.fundGuiltySide{value: c1}(listingId, 0);
        vm.prank(backer2);
        dm.fundGuiltySide{value: c2}(listingId, 0);
        assertEq(dm.guiltyFundingTotal(marketId), c1 + c2);

        vm.warp(block.timestamp + WINDOW + 1);

        uint256 b1 = backer1.balance;
        vm.prank(backer1);
        dm.reclaimGuiltyFunding(listingId, 0, cycle);
        assertEq(backer1.balance - b1, c1);
        assertEq(dm.guiltyFundingTotal(marketId), c2, "only backer1's share drained; backer2 untouched");
        assertEq(dm.guiltyFundingReclaimable(listingId, 0, cycle, backer2), c2);

        uint256 b2 = backer2.balance;
        vm.prank(backer2);
        dm.reclaimGuiltyFunding(listingId, 0, cycle);
        assertEq(backer2.balance - b2, c2);
        assertEq(dm.guiltyFundingTotal(marketId), 0);
        assertEq(address(dm).balance, 0);
    }

    /// @dev Reentering reclaim from the refund callback is blocked by nonReentrant; the outer reclaim still
    ///      succeeds exactly once and strands nothing.
    function test_ReentrantFunderCannotReenterReclaimDuringRefund() public {
        uint256 listingId = _openConfirmedListing();
        ReentrantFunder attacker = new ReentrantFunder(dm);
        vm.deal(address(attacker), 10 ether);
        uint256 cycle = _cycleOf(listingId, 0);

        attacker.attackFund(listingId, 0, HALF_PRICE / 4); // partial fund, no refund callback yet
        vm.warp(block.timestamp + WINDOW + 1);

        attacker.setReentryCalldata(
            abi.encodeWithSelector(DisputeManager.reclaimGuiltyFunding.selector, listingId, uint256(0), cycle)
        );
        attacker.attackReclaim(listingId, 0, cycle);

        assertTrue(attacker.reentered());
        assertFalse(attacker.reentrySucceeded(), "reentrant reclaim should have been blocked");
        assertEq(address(dm).balance, 0, "outer reclaim still paid out exactly once");
        assertEq(dm.guiltyContributionOf(dm.marketIdOf(listingId, 0, cycle), address(attacker)), 0);
    }

    function test_ReclaimableViewIsSafeToPollForNonexistentListing() public view {
        assertEq(dm.guiltyFundingReclaimable(999, 0, 1, buyer), 0);
    }

    /// @dev At any below-threshold scale, a reclaim returns exactly the contribution and conserves ETH end-to-end.
    function testFuzz_ReclaimReturnsExactlyContributedAndConservesEth(uint256 contribution) public {
        contribution = bound(contribution, 1, HALF_PRICE - 1); // strictly below threshold: never opens
        uint256 listingId = _openConfirmedListing();
        uint256 cycle = _cycleOf(listingId, 0);
        uint256 marketId = _marketId(listingId, 0);

        vm.prank(backer1);
        dm.fundGuiltySide{value: contribution}(listingId, 0);
        assertEq(address(dm).balance, contribution);

        vm.warp(block.timestamp + WINDOW + 1);

        uint256 before = backer1.balance;
        vm.prank(backer1);
        dm.reclaimGuiltyFunding(listingId, 0, cycle);
        assertEq(backer1.balance - before, contribution, "exact refund at any scale below threshold");
        assertEq(dm.guiltyFundingTotal(marketId), 0);
        assertEq(address(dm).balance, 0);
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

        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, 0);
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

        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Removed), "Guilty verdict permanently spends it");

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

        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, 0);
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

        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, 0);
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
        (ListingManager.SlotStatus status,,,) = lm.slots(listingId, 0);
        assertEq(uint8(status), uint8(ListingManager.SlotStatus.Removed), "Guilty verdict permanently spends it");
    }

    // ── Slot reuse: marketId must never collide across cycles ────────────────────────────────────────────────

    /// @notice A slot's first sale can complete perfectly cleanly (no dispute ever opens) and recycle back to
    ///         Empty for resale (ListingManager's slot-reuse design). If that slot's *second* sale is the one
    ///         that ends up disputed, its marketId must be entirely distinct from whatever marketId a dispute
    ///         against the first sale would have used - even though no such dispute ever actually existed. This
    ///         is the concrete regression for why {DisputeManager-marketIdOf} folds in ListingManager's per-slot
    ///         `cycle` counter rather than just (listingId, slotIndex).
    function test_DisputeOnResoldSlotUsesDistinctMarketIdFromItsUndisputedFirstSale() public {
        uint256 listingId = _openConfirmedListing(); // cycle 1, buyer as the recorded buyer
        uint256 hypotheticalFirstCycleMarketId = dm.marketIdOf(listingId, 0, 1);

        vm.prank(buyer);
        lm.confirmCompletion(listingId, 0); // cycle 1 completes clean, no dispute ever opened; slot recycles

        address secondBuyer = makeAddr("secondBuyer");
        vm.deal(secondBuyer, 1000 ether);
        vm.prank(settlementStandIn);
        lm.confirmPayment(listingId, 0, secondBuyer); // cycle 2

        uint256 secondCycleMarketId = _marketId(listingId, 0);
        assertEq(dm.marketIdOf(listingId, 0, 2), secondCycleMarketId);
        assertTrue(
            secondCycleMarketId != hypotheticalFirstCycleMarketId,
            "the second sale's dispute must never collide with the first sale's (never-opened) marketId"
        );

        vm.prank(secondBuyer);
        dm.fundGuiltySide{value: HALF_PRICE}(listingId, 0);

        (bool secondOpened,) = dm.disputes(secondCycleMarketId);
        assertTrue(secondOpened, "the second sale's dispute opens on its own cycle-2 marketId");

        // Nothing was ever written at the hash a cycle-1 dispute would have used - it was never opened.
        (bool firstOpened,) = dm.disputes(hypotheticalFirstCycleMarketId);
        assertFalse(firstOpened);
        assertEq(dm.guiltyFundingTotal(hypotheticalFirstCycleMarketId), 0);
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
