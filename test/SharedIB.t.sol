// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SharedIB} from "../src/SharedIB.sol";

contract RevertingReceiver {
    SharedIB public pool;

    constructor(SharedIB _pool) {
        pool = _pool;
    }

    function depositAndWithdraw(uint256 amount) external payable {
        uint256 shares = pool.deposit{value: amount}();
        pool.withdraw(shares);
    }

    receive() external payable {
        revert("RevertingReceiver: refuses ETH");
    }
}

/// @dev See IntegrityBond.t.sol's ReentrantAttacker for the same design rationale: an arbitrary, test-configured
///      reentry payload isolates "was the reentrant call blocked" from "did the legitimate call still succeed."
contract ReentrantAttacker {
    SharedIB public pool;
    bytes public reentryCalldata;
    bool public reentered;
    bool public reentrySucceeded;

    constructor(SharedIB _pool) {
        pool = _pool;
    }

    function setReentryCalldata(bytes calldata data) external {
        reentryCalldata = data;
    }

    function attackWithdraw(uint256 amount) external payable {
        uint256 shares = pool.deposit{value: amount}();
        pool.withdraw(shares);
    }

    function attackClaim() external {
        pool.claim();
    }

    receive() external payable {
        if (!reentered && reentryCalldata.length > 0) {
            reentered = true;
            (bool ok,) = address(pool).call(reentryCalldata);
            reentrySucceeded = ok;
        }
    }
}

contract SharedIBTest is Test {
    SharedIB internal pool;
    address internal controller = makeAddr("controller");
    address internal depositorA = makeAddr("depositorA");
    address internal depositorB = makeAddr("depositorB");
    address internal sellerX = makeAddr("sellerX");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        address[] memory controllers = new address[](1);
        controllers[0] = controller;
        pool = new SharedIB(controllers, "Walendria Shared IB", "wSIB");
        vm.deal(depositorA, 1000 ether);
        vm.deal(depositorB, 1000 ether);
    }

    // ── Constructor ────────────────────────────────────────────────────────────────────────────────────────────

    function test_RevertsOnEmptyControllerList() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(SharedIB.NoControllers.selector);
        new SharedIB(empty, "x", "x");
    }

    // ── Deposit ────────────────────────────────────────────────────────────────────────────────────────────────

    function test_FirstDepositBelowMinimumReverts() public {
        vm.prank(depositorA);
        vm.expectRevert(abi.encodeWithSelector(SharedIB.BelowMinimumFirstDeposit.selector, 1, pool.MIN_FIRST_DEPOSIT()));
        pool.deposit{value: 1}();
    }

    function test_FirstDepositMintsSharesOneToOne() public {
        vm.prank(depositorA);
        uint256 shares = pool.deposit{value: 10 ether}();
        assertEq(shares, 10 ether);
        assertEq(pool.balanceOf(depositorA), 10 ether);
        assertEq(pool.totalPooled(), 10 ether);
    }

    function test_SecondDepositIsProportionalToPoolValue() public {
        vm.prank(depositorA);
        pool.deposit{value: 10 ether}(); // 10 shares, totalPooled = 10

        vm.prank(depositorB);
        uint256 shares = pool.deposit{value: 5 ether}(); // 5 * 10 / 10 = 5 shares
        assertEq(shares, 5 ether);
        assertEq(pool.totalPooled(), 15 ether);
        assertEq(pool.totalSupply(), 15 ether);
    }

    function test_FeePaymentAppreciatesExistingSharesWithoutDiluting() public {
        // Concrete worked example, hand-verified:
        //   A deposits 10 -> 10 shares (totalPooled=10, supply=10)
        //   fee of 5 paid in                -> totalPooled=15, supply=10 (share price now 1.5)
        //   B deposits 3 -> 3*10/15=2 shares -> totalPooled=18, supply=12
        //   A's claim = 10 * 18/12 = 15 (kept 100% of the fee upside; B's late entry didn't dilute A)
        //   B's claim =  2 * 18/12 =  3 (B gets back exactly what B put in; joined after the fee was priced in)
        vm.prank(depositorA);
        pool.deposit{value: 10 ether}();

        pool.payFee{value: 5 ether}(sellerX);
        assertEq(pool.totalPooled(), 15 ether);
        assertEq(pool.totalSupply(), 10 ether); // fee mints no new shares

        vm.prank(depositorB);
        uint256 sharesB = pool.deposit{value: 3 ether}();
        assertEq(sharesB, 2 ether);

        vm.prank(depositorA);
        uint256 amountA = pool.withdraw(10 ether);
        assertEq(amountA, 15 ether);

        vm.prank(depositorB);
        uint256 amountB = pool.withdraw(2 ether);
        assertEq(amountB, 3 ether);
    }

    function test_DepositRevertsOnZeroValue() public {
        vm.prank(depositorA);
        vm.expectRevert(SharedIB.ZeroAmount.selector);
        pool.deposit{value: 0}();
    }

    function test_DepositRevertsWhenPoolFullySlashedToZero() public {
        vm.prank(depositorA);
        pool.deposit{value: 10 ether}();
        vm.startPrank(controller);
        pool.lock(sellerX, 10 ether);
        pool.slash(sellerX, 10 ether, recipient); // wipes totalPooled to 0 while supply is still 10 ether
        vm.stopPrank();

        vm.prank(depositorB);
        vm.expectRevert(SharedIB.PoolInsolvent.selector);
        pool.deposit{value: 1 ether}();
    }

    // ── Withdraw ───────────────────────────────────────────────────────────────────────────────────────────────

    function test_WithdrawBurnsSharesAndPaysOutFreePortion() public {
        vm.startPrank(depositorA);
        pool.deposit{value: 10 ether}();
        uint256 balBefore = depositorA.balance;
        uint256 amount = pool.withdraw(4 ether);
        vm.stopPrank();
        assertEq(amount, 4 ether);
        assertEq(depositorA.balance, balBefore + 4 ether);
        assertEq(pool.balanceOf(depositorA), 6 ether);
    }

    /// @notice Direct regression test for the adversarial scenario named in the build strategy: a Shared IB
    ///         depositor must not be able to withdraw against capital that is currently locked backing a live
    ///         listing, even though slashing has not (yet) happened - the lock guarantee has no exception.
    function test_CannotWithdrawLockedCapitalToDodgeASlash() public {
        vm.prank(depositorA);
        pool.deposit{value: 10 ether}();
        vm.prank(controller);
        pool.lock(sellerX, 10 ether); // fully locked, e.g. backing a live Shared-IB-funded listing

        vm.prank(depositorA);
        vm.expectRevert(SharedIB.ZeroAmount.selector); // free pool is 0, so any positive-share withdrawal yields 0
        pool.withdraw(1 ether);
    }

    function test_ProportionalSlashHitsAllDepositorsBySamePercentage() public {
        // A owns 80% of the pool, B owns 20% (8 ETH vs 2 ETH). A 40% slash of the whole pool must cost each
        // depositor exactly 40% of their stake, regardless of how much they personally hold (Section 2.2:
        // "the pool is slashed proportionally").
        vm.prank(depositorA);
        pool.deposit{value: 8 ether}();
        vm.prank(depositorB);
        pool.deposit{value: 2 ether}();

        vm.startPrank(controller);
        pool.lock(sellerX, 10 ether);
        pool.slash(sellerX, 4 ether, recipient); // 4 / 10 = 40% of the whole pool
        pool.unlock(sellerX, 6 ether); // release what's left so it's withdrawable
        vm.stopPrank();

        vm.prank(depositorA);
        uint256 amountA = pool.withdraw(8 ether);
        vm.prank(depositorB);
        uint256 amountB = pool.withdraw(2 ether);

        assertEq(amountA, 4.8 ether); // 8 * 0.6
        assertEq(amountB, 1.2 ether); // 2 * 0.6
        assertEq(amountA + amountB, 6 ether);
        assertEq(pool.claimable(recipient), 4 ether);
    }

    function test_WithdrawRevertsOnTransferFailure() public {
        RevertingReceiver bad = new RevertingReceiver(pool);
        vm.deal(address(bad), 10 ether);
        vm.expectRevert(abi.encodeWithSelector(SharedIB.TransferFailed.selector, address(bad), 10 ether));
        bad.depositAndWithdraw(10 ether);
    }

    // ── Lock / Unlock ──────────────────────────────────────────────────────────────────────────────────────────

    function test_LockMovesFreeToLocked() public {
        vm.prank(depositorA);
        pool.deposit{value: 10 ether}();
        vm.prank(controller);
        pool.lock(sellerX, 6 ether);
        assertEq(pool.lockedBySeller(sellerX), 6 ether);
        assertEq(pool.totalLocked(), 6 ether);
        assertEq(pool.freePool(), 4 ether);
    }

    function test_LockRevertsWhenExceedsFreePool() public {
        vm.prank(depositorA);
        pool.deposit{value: 10 ether}();
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SharedIB.InsufficientFreePool.selector, 11 ether, 10 ether));
        pool.lock(sellerX, 11 ether);
    }

    function test_LockRevertsWhenNotController() public {
        vm.prank(depositorA);
        pool.deposit{value: 10 ether}();
        vm.prank(depositorA);
        vm.expectRevert(abi.encodeWithSelector(SharedIB.NotController.selector, depositorA));
        pool.lock(sellerX, 1 ether);
    }

    function test_UnlockRevertsWhenExceedsLocked() public {
        vm.prank(depositorA);
        pool.deposit{value: 10 ether}();
        vm.prank(controller);
        pool.lock(sellerX, 3 ether);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(SharedIB.InsufficientLockedForSeller.selector, sellerX, 5 ether, 3 ether)
        );
        pool.unlock(sellerX, 5 ether);
    }

    // ── Slash + Claim ──────────────────────────────────────────────────────────────────────────────────────────

    function test_SlashRevertsWhenExceedsLocked() public {
        vm.prank(depositorA);
        pool.deposit{value: 10 ether}();
        vm.prank(controller);
        pool.lock(sellerX, 4 ether);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(SharedIB.InsufficientLockedForSeller.selector, sellerX, 5 ether, 4 ether)
        );
        pool.slash(sellerX, 5 ether, recipient);
    }

    function test_SlashRevertsWhenNotController() public {
        vm.prank(depositorA);
        vm.expectRevert(abi.encodeWithSelector(SharedIB.NotController.selector, depositorA));
        pool.slash(sellerX, 1, recipient);
    }

    function test_ClaimPaysOutAndZeroesLedger() public {
        vm.prank(depositorA);
        pool.deposit{value: 10 ether}();
        vm.startPrank(controller);
        pool.lock(sellerX, 10 ether);
        pool.slash(sellerX, 10 ether, recipient);
        vm.stopPrank();

        uint256 balBefore = recipient.balance;
        vm.prank(recipient);
        pool.claim();
        assertEq(recipient.balance, balBefore + 10 ether);
        assertEq(pool.claimable(recipient), 0);
    }

    function test_ClaimRevertsWhenNothingToClaim() public {
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(SharedIB.NothingToClaim.selector, recipient));
        pool.claim();
    }

    // ── No stray-value acceptance ──────────────────────────────────────────────────────────────────────────────

    function test_PlainTransferIsRejected() public {
        vm.deal(depositorA, 1 ether);
        vm.prank(depositorA);
        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertFalse(ok, "pool must not silently accept untracked native currency");
    }

    // ── Fuzz ───────────────────────────────────────────────────────────────────────────────────────────────────

    function testFuzz_LockNeverExceedsPooledAfterDepositLockUnlock(uint256 dep, uint256 lockAmt, uint256 unlockAmt)
        public
    {
        dep = bound(dep, pool.MIN_FIRST_DEPOSIT(), 1000 ether);
        vm.deal(depositorA, dep);
        vm.prank(depositorA);
        pool.deposit{value: dep}();

        lockAmt = bound(lockAmt, 0, dep);
        if (lockAmt > 0) {
            vm.prank(controller);
            pool.lock(sellerX, lockAmt);
        }

        unlockAmt = bound(unlockAmt, 0, lockAmt);
        if (unlockAmt > 0) {
            vm.prank(controller);
            pool.unlock(sellerX, unlockAmt);
        }

        assertLe(pool.totalLocked(), pool.totalPooled());
        assertEq(pool.totalLocked(), lockAmt - unlockAmt);
    }

    // ── Adversarial: reentrancy ────────────────────────────────────────────────────────────────────────────────

    function test_ReentrantWithdrawCannotDoubleSpend() public {
        ReentrantAttacker attacker = new ReentrantAttacker(pool);
        attacker.setReentryCalldata(abi.encodeWithSignature("withdraw(uint256)", uint256(1)));
        vm.deal(address(attacker), 10 ether);

        attacker.attackWithdraw(10 ether);

        assertTrue(attacker.reentered());
        assertFalse(attacker.reentrySucceeded(), "reentrant withdraw() should have been blocked");
        assertEq(pool.balanceOf(address(attacker)), 0);
        assertEq(address(attacker).balance, 10 ether, "attacker should recover their deposit exactly once");
        assertEq(address(pool).balance, 0);
    }

    function test_ReentrantClaimCannotDoubleSpend() public {
        ReentrantAttacker attacker = new ReentrantAttacker(pool);
        attacker.setReentryCalldata(abi.encodeWithSignature("claim()"));

        vm.prank(depositorA);
        pool.deposit{value: 10 ether}();
        vm.startPrank(controller);
        pool.lock(sellerX, 10 ether);
        pool.slash(sellerX, 10 ether, address(attacker));
        vm.stopPrank();

        attacker.attackClaim();

        assertTrue(attacker.reentered());
        assertFalse(attacker.reentrySucceeded(), "reentrant claim() should have been blocked");
        assertEq(pool.claimable(address(attacker)), 0);
        assertEq(address(attacker).balance, 10 ether, "attacker should be paid exactly once, not twice");
    }
}
