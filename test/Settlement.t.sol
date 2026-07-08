// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IntegrityBond} from "../src/IntegrityBond.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {Settlement} from "../src/Settlement.sol";

/// @dev A seller whose `receive()` always reverts, to test that a malicious/broken seller rolls back the whole
///      atomic settlement (Section 2.3) - including ListingManager's confirmPayment - rather than leaving funds
///      or slot state partially updated.
contract RevertingSeller {
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
        revert("RevertingSeller: refuses ETH");
    }
}

/// @dev Reenters `settlement` with an arbitrary, test-configured calldata payload during its own `receive()`
///      (fired when Settlement refunds excess payment), mirroring the ReentrantAttacker pattern already
///      established in IntegrityBond.t.sol / SharedIB.t.sol.
contract ReentrantBuyer {
    Settlement public settlement;
    bytes public reentryCalldata;
    bool public reentered;
    bool public reentrySucceeded;

    constructor(Settlement _settlement) {
        settlement = _settlement;
    }

    function setReentryCalldata(bytes calldata data) external {
        reentryCalldata = data;
    }

    function attackPay(uint256 listingId, uint256 slotIndex, uint256 value) external {
        settlement.pay{value: value}(listingId, slotIndex);
    }

    receive() external payable {
        if (!reentered && reentryCalldata.length > 0) {
            reentered = true;
            (bool ok,) = address(settlement).call(reentryCalldata);
            reentrySucceeded = ok;
        }
    }
}

contract SettlementTest is Test {
    IntegrityBond internal bond;
    ListingManager internal lm;
    Settlement internal settlement;

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal devPool = makeAddr("devPool");

    uint256 internal constant PRICE = 1 ether;
    uint256 internal constant SLOTS = 3;
    uint256 internal constant WINDOW = 72 hours;
    uint256 internal constant FEE = 0.005 ether; // 0.5% of PRICE
    uint256 internal constant PROCEEDS = 0.995 ether;

    uint256 internal listingId;

    function setUp() public {
        // Settlement needs ListingManager's address (immutable) and ListingManager needs Settlement's address
        // (as its controller, for confirmPayment) - the same circular-constructor pattern already resolved for
        // IntegrityBond<->ListingManager in Phase 3, extended one level further via CREATE nonce prediction.
        uint256 nonce = vm.getNonce(address(this));
        address predictedLm = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedSettlement = vm.computeCreateAddress(address(this), nonce + 2);

        address[] memory bondControllers = new address[](1);
        bondControllers[0] = predictedLm;
        bond = new IntegrityBond(bondControllers);

        address[] memory lmControllers = new address[](1);
        lmControllers[0] = predictedSettlement;
        lm = new ListingManager(bond, lmControllers, type(uint256).max);
        assertEq(address(lm), predictedLm, "CREATE nonce prediction drifted (lm)");

        settlement = new Settlement(lm, devPool);
        assertEq(address(settlement), predictedSettlement, "CREATE nonce prediction drifted (settlement)");

        vm.deal(seller, 1000 ether);
        vm.prank(seller);
        bond.deposit{value: 100 ether}();

        vm.prank(seller);
        listingId = lm.createListing(PRICE, SLOTS, WINDOW);

        vm.deal(buyer, 1000 ether);
    }

    // ── Happy path ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_PaySucceedsWithExactAmount() public {
        uint256 buyerBefore = buyer.balance;

        vm.prank(buyer);
        settlement.pay{value: PRICE}(listingId, 0);

        assertEq(buyerBefore - buyer.balance, PRICE, "buyer should pay exactly PRICE, no refund due");
        assertEq(address(settlement).balance, 0);

        (ListingManager.SlotStatus status, uint256 deadline,) = lm.slots(listingId, 0);
        assertEq(uint256(status), uint256(ListingManager.SlotStatus.PaymentConfirmed));
        assertEq(deadline, block.timestamp + WINDOW);

        (,,, uint256 emptySlots,,,) = lm.listings(listingId);
        assertEq(emptySlots, SLOTS - 1);
    }

    function test_PayForwardsExactFeeAndProceedsSplit() public {
        uint256 devBefore = devPool.balance;
        uint256 sellerBefore = seller.balance;

        vm.prank(buyer);
        settlement.pay{value: PRICE}(listingId, 0);

        assertEq(devPool.balance - devBefore, FEE);
        assertEq(seller.balance - sellerBefore, PROCEEDS);
        assertEq(FEE + PROCEEDS, PRICE, "fee and proceeds must sum to exactly PRICE");
    }

    function test_PayRefundsExcessAmount() public {
        uint256 overpay = 0.3 ether;
        uint256 buyerBefore = buyer.balance;
        uint256 devBefore = devPool.balance;
        uint256 sellerBefore = seller.balance;

        vm.prank(buyer);
        settlement.pay{value: PRICE + overpay}(listingId, 0);

        assertEq(buyerBefore - buyer.balance, PRICE, "buyer's net cost should still be exactly PRICE");
        assertEq(devPool.balance - devBefore, FEE, "fee is computed off PRICE, not the overpaid amount");
        assertEq(seller.balance - sellerBefore, PROCEEDS, "proceeds are computed off PRICE, not the overpaid amount");
        assertEq(address(settlement).balance, 0);
    }

    function test_PayDecrementsEmptySlotsAndAllowsIndependentSlotsToBothSettle() public {
        vm.prank(buyer);
        settlement.pay{value: PRICE}(listingId, 0);
        vm.prank(buyer);
        settlement.pay{value: PRICE}(listingId, 1);

        (,,, uint256 emptySlots,,,) = lm.listings(listingId);
        assertEq(emptySlots, SLOTS - 2);

        (ListingManager.SlotStatus status0,,) = lm.slots(listingId, 0);
        (ListingManager.SlotStatus status1,,) = lm.slots(listingId, 1);
        assertEq(uint256(status0), uint256(ListingManager.SlotStatus.PaymentConfirmed));
        assertEq(uint256(status1), uint256(ListingManager.SlotStatus.PaymentConfirmed));
    }

    function test_PayEmitsSettledEventWithCorrectArgs() public {
        vm.expectEmit(true, true, true, true, address(settlement));
        emit Settlement.Settled(listingId, 0, buyer, PRICE, FEE, 0);

        vm.prank(buyer);
        settlement.pay{value: PRICE}(listingId, 0);
    }

    function test_PayEmitsSettledEventWithExcessRefunded() public {
        vm.expectEmit(true, true, true, true, address(settlement));
        emit Settlement.Settled(listingId, 0, buyer, PRICE, FEE, 0.1 ether);

        vm.prank(buyer);
        settlement.pay{value: PRICE + 0.1 ether}(listingId, 0);
    }

    // ── Reverts ────────────────────────────────────────────────────────────────────────────────────────────────

    function test_ConstructorRevertsOnZeroFeeRecipient() public {
        vm.expectRevert(Settlement.ZeroAddress.selector);
        new Settlement(lm, address(0));
    }

    function test_PayRevertsWhenUnderpaid() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Settlement.InsufficientPayment.selector, PRICE - 1, PRICE));
        settlement.pay{value: PRICE - 1}(listingId, 0);
    }

    function test_PayRevertsWhenSlotAlreadyConfirmed() public {
        vm.prank(buyer);
        settlement.pay{value: PRICE}(listingId, 0);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotNotEmpty.selector, listingId, 0));
        settlement.pay{value: PRICE}(listingId, 0);
    }

    function test_PayRevertsForNonexistentListing() public {
        uint256 missingListingId = 999;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.ListingNotFound.selector, missingListingId));
        settlement.pay{value: PRICE}(missingListingId, 0);
    }

    function test_PayRevertsForOutOfRangeSlotIndex() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ListingManager.SlotIndexOutOfRange.selector, SLOTS, SLOTS));
        settlement.pay{value: PRICE}(listingId, SLOTS);
    }

    function test_PayRevertsWholeCallWhenSellerRejectsProceeds() public {
        RevertingSeller badSeller = new RevertingSeller(bond, lm);
        vm.deal(address(badSeller), 100 ether);
        uint256 badListingId = badSeller.depositAndCreateListing{value: 100 ether}(PRICE, 1, WINDOW);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(Settlement.ProceedsTransferFailed.selector, address(badSeller), PROCEEDS)
        );
        settlement.pay{value: PRICE}(badListingId, 0);

        // Whole call rolled back: the slot must still be Empty, not stuck PaymentConfirmed with no payout.
        (ListingManager.SlotStatus status,,) = lm.slots(badListingId, 0);
        assertEq(uint256(status), uint256(ListingManager.SlotStatus.Empty));
    }

    // ── Adversarial ────────────────────────────────────────────────────────────────────────────────────────────

    function test_ReentrantBuyerCannotPayAnotherSlotDuringRefund() public {
        ReentrantBuyer attacker = new ReentrantBuyer(settlement);
        // Slot 1 is a different, still-Empty slot in the same listing - reachable on its own merits - so if the
        // reentrant call fails, it can only be the ReentrancyGuard blocking it, not SlotNotEmpty or a price check.
        attacker.setReentryCalldata(abi.encodeWithSelector(Settlement.pay.selector, listingId, uint256(1)));
        vm.deal(address(attacker), 10 ether);

        attacker.attackPay(listingId, 0, PRICE + 1 ether); // overpay so the refund step triggers the reentry

        assertTrue(attacker.reentered());
        assertFalse(attacker.reentrySucceeded(), "reentrant pay() should have been blocked");

        (ListingManager.SlotStatus status0,,) = lm.slots(listingId, 0);
        assertEq(uint256(status0), uint256(ListingManager.SlotStatus.PaymentConfirmed), "legitimate call succeeded");

        (ListingManager.SlotStatus status1,,) = lm.slots(listingId, 1);
        assertEq(uint256(status1), uint256(ListingManager.SlotStatus.Empty), "blocked reentry touched nothing");
    }

    // ── Fuzz ───────────────────────────────────────────────────────────────────────────────────────────────────

    function testFuzz_FeeAndProceedsAlwaysSumToPriceWithNoStrandedWei(uint256 priceSeed, uint256 overpaySeed) public {
        uint256 price = bound(priceSeed, 1, 1_000_000 ether);
        uint256 overpay = bound(overpaySeed, 0, 1_000_000 ether);

        uint256 required = Math.ceilDiv(price * 3, 2);
        vm.deal(seller, seller.balance + required);
        vm.prank(seller);
        bond.deposit{value: required}();
        vm.prank(seller);
        uint256 freshListingId = lm.createListing(price, 1, WINDOW);

        address fuzzBuyer = makeAddr(string.concat("fuzzBuyer", vm.toString(priceSeed), vm.toString(overpaySeed)));
        vm.deal(fuzzBuyer, price + overpay);

        uint256 sellerBefore = seller.balance;
        uint256 devBefore = devPool.balance;

        vm.prank(fuzzBuyer);
        settlement.pay{value: price + overpay}(freshListingId, 0);

        uint256 fee = (price * 50) / 10_000;
        uint256 proceeds = price - fee;

        assertEq(devPool.balance - devBefore, fee);
        assertEq(seller.balance - sellerBefore, proceeds);
        assertEq(fuzzBuyer.balance, overpay, "buyer should be refunded exactly the excess");
        assertEq(address(settlement).balance, 0, "Settlement must never retain a balance");
    }

    struct UnderpayState {
        uint256 buyerBalance;
        uint256 sellerBalance;
        uint256 devBalance;
        uint256 settlementBalance;
        uint256 emptySlots;
        ListingManager.SlotStatus slotStatus;
        address slotBuyer;
    }

    function _captureUnderpayState(uint256 targetListingId, address fuzzBuyer)
        internal
        view
        returns (UnderpayState memory s)
    {
        s.buyerBalance = fuzzBuyer.balance;
        s.sellerBalance = seller.balance;
        s.devBalance = devPool.balance;
        s.settlementBalance = address(settlement).balance;
        (,,, s.emptySlots,,,) = lm.listings(targetListingId);
        (s.slotStatus,, s.slotBuyer) = lm.slots(targetListingId, 0);
    }

    function testFuzz_RevertsWheneverUnderpaid(uint256 priceSeed, uint256 shortfallSeed) public {
        uint256 price = bound(priceSeed, 1, 1_000_000 ether);
        uint256 shortfall = bound(shortfallSeed, 1, price);

        uint256 required = Math.ceilDiv(price * 3, 2);
        vm.deal(seller, seller.balance + required);
        vm.prank(seller);
        bond.deposit{value: required}();
        vm.prank(seller);
        uint256 freshListingId = lm.createListing(price, 1, WINDOW);

        uint256 sent = price - shortfall;
        address fuzzBuyer = makeAddr(string.concat("fuzzUnderpay", vm.toString(priceSeed), vm.toString(shortfallSeed)));
        vm.deal(fuzzBuyer, sent);

        UnderpayState memory before = _captureUnderpayState(freshListingId, fuzzBuyer);

        vm.prank(fuzzBuyer);
        vm.expectRevert(abi.encodeWithSelector(Settlement.InsufficientPayment.selector, sent, price));
        settlement.pay{value: sent}(freshListingId, 0);

        // Prove the revert left genuinely zero partial state change, not just that it reverted.
        UnderpayState memory afterRevert = _captureUnderpayState(freshListingId, fuzzBuyer);
        assertEq(afterRevert.buyerBalance, before.buyerBalance, "buyer's ETH must be fully rolled back");
        assertEq(afterRevert.sellerBalance, before.sellerBalance, "seller must not receive any proceeds");
        assertEq(afterRevert.devBalance, before.devBalance, "dev pool must not receive any fee");
        assertEq(afterRevert.settlementBalance, before.settlementBalance, "Settlement must not retain any balance");
        assertEq(afterRevert.emptySlots, before.emptySlots, "emptySlots must be unchanged");
        assertEq(uint256(afterRevert.slotStatus), uint256(before.slotStatus), "slot status must be unchanged");
        assertEq(uint256(afterRevert.slotStatus), uint256(ListingManager.SlotStatus.Empty), "slot must still be Empty");
        assertEq(afterRevert.slotBuyer, before.slotBuyer, "slot buyer must be unchanged");
    }
}
