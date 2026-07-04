// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IntegrityBond} from "../src/IntegrityBond.sol";

contract RevertingReceiver {
    IntegrityBond public bond;

    constructor(IntegrityBond _bond) {
        bond = _bond;
    }

    function depositAndWithdraw(uint256 amount) external payable {
        bond.deposit{value: amount}();
        bond.withdraw(amount);
    }

    receive() external payable {
        revert("RevertingReceiver: refuses ETH");
    }
}

/// @dev Reenters `bond` with an arbitrary, test-configured calldata payload during its own `receive()`, so the
///      same attacker contract can probe reentrancy on any target function without special-casing each one. The
///      reentrant sub-call's success/failure is captured via a low-level call rather than try/catch so the
///      *original* outer call (attackWithdraw/attackClaim) is unaffected by whether the reentry was blocked -
///      this isolates "did the reentrant call get blocked" from "did the legitimate call still work."
contract ReentrantAttacker {
    IntegrityBond public bond;
    bytes public reentryCalldata;
    bool public reentered;
    bool public reentrySucceeded;

    constructor(IntegrityBond _bond) {
        bond = _bond;
    }

    function setReentryCalldata(bytes calldata data) external {
        reentryCalldata = data;
    }

    function attackWithdraw(uint256 amount) external payable {
        bond.deposit{value: amount}();
        bond.withdraw(amount);
    }

    function attackClaim() external {
        bond.claim();
    }

    receive() external payable {
        if (!reentered && reentryCalldata.length > 0) {
            reentered = true;
            (bool ok,) = address(bond).call(reentryCalldata);
            reentrySucceeded = ok;
        }
    }
}

contract IntegrityBondTest is Test {
    IntegrityBond internal bond;
    address internal controller = makeAddr("controller");
    address internal seller = makeAddr("seller");
    address internal otherSeller = makeAddr("otherSeller");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        address[] memory controllers = new address[](1);
        controllers[0] = controller;
        bond = new IntegrityBond(controllers);
        vm.deal(seller, 1000 ether);
        vm.deal(otherSeller, 1000 ether);
    }

    // ── Constructor ────────────────────────────────────────────────────────────────────────────────────────────

    function test_RevertsOnEmptyControllerList() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(IntegrityBond.NoControllers.selector);
        new IntegrityBond(empty);
    }

    function test_SupportsMultipleControllers() public {
        address[] memory controllers = new address[](2);
        controllers[0] = controller;
        controllers[1] = makeAddr("secondController");
        IntegrityBond multi = new IntegrityBond(controllers);
        assertTrue(multi.isController(controller));
        assertTrue(multi.isController(controllers[1]));
    }

    // ── Deposit ────────────────────────────────────────────────────────────────────────────────────────────────

    function test_DepositIncreasesTotalAndFree() public {
        vm.prank(seller);
        bond.deposit{value: 1 ether}();
        (uint256 total, uint256 locked) = bond.bonds(seller);
        assertEq(total, 1 ether);
        assertEq(locked, 0);
        assertEq(bond.freeIB(seller), 1 ether);
    }

    function test_DepositRevertsOnZeroValue() public {
        vm.prank(seller);
        vm.expectRevert(IntegrityBond.ZeroAmount.selector);
        bond.deposit{value: 0}();
    }

    function test_DepositEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(bond));
        emit IntegrityBond.Deposited(seller, 1 ether);
        vm.prank(seller);
        bond.deposit{value: 1 ether}();
    }

    // ── Withdraw ───────────────────────────────────────────────────────────────────────────────────────────────

    function test_WithdrawReducesTotalAndPaysOut() public {
        vm.startPrank(seller);
        bond.deposit{value: 1 ether}();
        uint256 balBefore = seller.balance;
        bond.withdraw(0.4 ether);
        vm.stopPrank();
        (uint256 total,) = bond.bonds(seller);
        assertEq(total, 0.6 ether);
        assertEq(seller.balance, balBefore + 0.4 ether);
    }

    function test_WithdrawRevertsOnZeroAmount() public {
        vm.prank(seller);
        vm.expectRevert(IntegrityBond.ZeroAmount.selector);
        bond.withdraw(0);
    }

    function test_WithdrawRevertsWhenExceedsFree() public {
        vm.startPrank(seller);
        bond.deposit{value: 1 ether}();
        vm.stopPrank();
        vm.prank(controller);
        bond.lock(seller, 0.7 ether);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IntegrityBond.InsufficientFreeIB.selector, seller, 0.5 ether, 0.3 ether));
        bond.withdraw(0.5 ether);
    }

    /// @notice Direct regression test for the adversarial scenario named in the build strategy: a depositor must
    ///         not be able to withdraw capital that is locked backing an active listing/dispute, even though it
    ///         is nominally "their" money.
    function test_CannotWithdrawLockedCapitalToDodgeALock() public {
        vm.prank(seller);
        bond.deposit{value: 1.5 ether}();
        vm.prank(controller);
        bond.lock(seller, 1.5 ether); // fully locked, e.g. backing a live listing

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IntegrityBond.InsufficientFreeIB.selector, seller, 1, 0));
        bond.withdraw(1);
    }

    function test_WithdrawRevertsOnTransferFailure() public {
        RevertingReceiver bad = new RevertingReceiver(bond);
        vm.deal(address(bad), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IntegrityBond.TransferFailed.selector, address(bad), 1 ether));
        bad.depositAndWithdraw(1 ether);
    }

    // ── Lock ───────────────────────────────────────────────────────────────────────────────────────────────────

    function test_LockMovesFreeToLocked() public {
        vm.prank(seller);
        bond.deposit{value: 1 ether}();
        vm.prank(controller);
        bond.lock(seller, 0.6 ether);
        (uint256 total, uint256 locked) = bond.bonds(seller);
        assertEq(total, 1 ether);
        assertEq(locked, 0.6 ether);
        assertEq(bond.freeIB(seller), 0.4 ether);
    }

    function test_LockRevertsWhenNotController() public {
        vm.prank(seller);
        bond.deposit{value: 1 ether}();
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IntegrityBond.NotController.selector, seller));
        bond.lock(seller, 0.5 ether);
    }

    function test_LockRevertsWhenExceedsFree() public {
        vm.prank(seller);
        bond.deposit{value: 1 ether}();
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IntegrityBond.InsufficientFreeIB.selector, seller, 1.1 ether, 1 ether));
        bond.lock(seller, 1.1 ether);
    }

    function test_LockRevertsOnZeroAmount() public {
        vm.prank(controller);
        vm.expectRevert(IntegrityBond.ZeroAmount.selector);
        bond.lock(seller, 0);
    }

    // ── Unlock ─────────────────────────────────────────────────────────────────────────────────────────────────

    function test_UnlockMovesLockedBackToFree() public {
        vm.prank(seller);
        bond.deposit{value: 1 ether}();
        vm.startPrank(controller);
        bond.lock(seller, 0.6 ether);
        bond.unlock(seller, 0.6 ether);
        vm.stopPrank();
        assertEq(bond.freeIB(seller), 1 ether);
    }

    function test_UnlockRevertsWhenExceedsLocked() public {
        vm.prank(seller);
        bond.deposit{value: 1 ether}();
        vm.prank(controller);
        bond.lock(seller, 0.3 ether);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(IntegrityBond.InsufficientLockedIB.selector, seller, 0.5 ether, 0.3 ether)
        );
        bond.unlock(seller, 0.5 ether);
    }

    function test_UnlockRevertsWhenNotController() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IntegrityBond.NotController.selector, seller));
        bond.unlock(seller, 1);
    }

    // ── Slash + Claim ──────────────────────────────────────────────────────────────────────────────────────────

    function test_SlashMovesLockedToClaimable() public {
        vm.prank(seller);
        bond.deposit{value: 1.5 ether}();
        vm.startPrank(controller);
        bond.lock(seller, 1.5 ether);
        bond.slash(seller, 0.5 ether, recipient);
        vm.stopPrank();

        (uint256 total, uint256 locked) = bond.bonds(seller);
        assertEq(total, 1 ether);
        assertEq(locked, 1 ether);
        assertEq(bond.claimable(recipient), 0.5 ether);
    }

    function test_SlashRevertsWhenExceedsLocked() public {
        vm.prank(seller);
        bond.deposit{value: 1 ether}();
        vm.prank(controller);
        bond.lock(seller, 0.4 ether);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(IntegrityBond.InsufficientLockedIB.selector, seller, 0.5 ether, 0.4 ether)
        );
        bond.slash(seller, 0.5 ether, recipient);
    }

    function test_SlashRevertsWhenNotController() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IntegrityBond.NotController.selector, seller));
        bond.slash(seller, 1, recipient);
    }

    function test_TwoSequentialSlashesMatchTotalIBLossOf1_5P() public {
        // Mirrors Section 3.1's flow: 0.5P drawn to the market at dispute-open, then 1.0P restitution on a
        // Guilty verdict - two separate slash() calls against the same original 1.5P lock.
        vm.prank(seller);
        bond.deposit{value: 1.5 ether}();
        vm.startPrank(controller);
        bond.lock(seller, 1.5 ether);
        bond.slash(seller, 0.5 ether, recipient); // matching draw into Spectral Market
        bond.slash(seller, 1.0 ether, otherSeller); // restitution to buyer (reusing otherSeller as a stand-in)
        vm.stopPrank();

        (uint256 total, uint256 locked) = bond.bonds(seller);
        assertEq(total, 0);
        assertEq(locked, 0);
    }

    function test_ClaimPaysOutAndZeroesLedger() public {
        vm.prank(seller);
        bond.deposit{value: 1 ether}();
        vm.startPrank(controller);
        bond.lock(seller, 1 ether);
        bond.slash(seller, 1 ether, recipient);
        vm.stopPrank();

        uint256 balBefore = recipient.balance;
        vm.prank(recipient);
        bond.claim();
        assertEq(recipient.balance, balBefore + 1 ether);
        assertEq(bond.claimable(recipient), 0);
    }

    function test_ClaimRevertsWhenNothingToClaim() public {
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(IntegrityBond.NothingToClaim.selector, recipient));
        bond.claim();
    }

    // ── Fuzz ───────────────────────────────────────────────────────────────────────────────────────────────────

    function testFuzz_LockNeverExceedsTotalAfterDepositLockUnlock(uint256 dep, uint256 lockAmt, uint256 unlockAmt)
        public
    {
        dep = bound(dep, 1, 1000 ether);
        vm.deal(seller, dep);
        vm.prank(seller);
        bond.deposit{value: dep}();

        lockAmt = bound(lockAmt, 0, dep);
        if (lockAmt > 0) {
            vm.prank(controller);
            bond.lock(seller, lockAmt);
        }

        unlockAmt = bound(unlockAmt, 0, lockAmt);
        if (unlockAmt > 0) {
            vm.prank(controller);
            bond.unlock(seller, unlockAmt);
        }

        (uint256 total, uint256 locked) = bond.bonds(seller);
        assertLe(locked, total);
        assertEq(locked, lockAmt - unlockAmt);
    }

    function testFuzz_WithdrawNeverExceedsFree(uint256 dep, uint256 lockAmt, uint256 withdrawAmt) public {
        dep = bound(dep, 1, 1000 ether);
        vm.deal(seller, dep);
        vm.prank(seller);
        bond.deposit{value: dep}();

        lockAmt = bound(lockAmt, 0, dep);
        if (lockAmt > 0) {
            vm.prank(controller);
            bond.lock(seller, lockAmt);
        }

        uint256 free = dep - lockAmt;
        withdrawAmt = bound(withdrawAmt, 0, free == 0 ? 0 : free + 1); // occasionally 1 wei over the line
        if (withdrawAmt == 0) return;

        vm.prank(seller);
        if (withdrawAmt > free) {
            vm.expectRevert(
                abi.encodeWithSelector(IntegrityBond.InsufficientFreeIB.selector, seller, withdrawAmt, free)
            );
            bond.withdraw(withdrawAmt);
        } else {
            bond.withdraw(withdrawAmt);
            (uint256 total, uint256 locked) = bond.bonds(seller);
            assertGe(total, locked);
        }
    }

    // ── Adversarial: reentrancy ────────────────────────────────────────────────────────────────────────────────

    function test_ReentrantWithdrawCannotDoubleSpend() public {
        ReentrantAttacker attacker = new ReentrantAttacker(bond);
        attacker.setReentryCalldata(abi.encodeWithSelector(IntegrityBond.withdraw.selector, uint256(1)));
        vm.deal(address(attacker), 1 ether);

        attacker.attackWithdraw(1 ether); // succeeds - the reentrant inner withdraw() is what must fail

        assertTrue(attacker.reentered());
        assertFalse(attacker.reentrySucceeded(), "reentrant withdraw() should have been blocked");

        (uint256 total, uint256 locked) = bond.bonds(address(attacker));
        assertEq(total, 0);
        assertEq(locked, 0);
        assertEq(address(attacker).balance, 1 ether, "attacker should recover their deposit exactly once");
        assertEq(address(bond).balance, 0);
    }

    function test_ReentrantClaimCannotDoubleSpend() public {
        ReentrantAttacker attacker = new ReentrantAttacker(bond);
        attacker.setReentryCalldata(abi.encodeWithSelector(IntegrityBond.claim.selector));

        vm.prank(seller);
        bond.deposit{value: 1 ether}();
        vm.startPrank(controller);
        bond.lock(seller, 1 ether);
        bond.slash(seller, 1 ether, address(attacker));
        vm.stopPrank();

        attacker.attackClaim(); // succeeds once - the reentrant inner claim() is what must fail

        assertTrue(attacker.reentered());
        assertFalse(attacker.reentrySucceeded(), "reentrant claim() should have been blocked");
        assertEq(bond.claimable(address(attacker)), 0);
        assertEq(address(attacker).balance, 1 ether, "attacker should be paid exactly once, not twice");
        assertEq(address(bond).balance, 0);
    }
}
