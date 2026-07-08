// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeveloperPool} from "../src/DeveloperPool.sol";

/// @dev Reenters `pool` with an arbitrary, test-configured calldata payload during its own `receive()`, mirroring
///      the ReentrantAttacker pattern already established throughout this codebase.
contract ReentrantParty {
    DeveloperPool public pool;
    bytes public reentryCalldata;
    bool public reentered;
    bool public reentrySucceeded;

    constructor(DeveloperPool _pool) {
        pool = _pool;
    }

    function setReentryCalldata(bytes calldata data) external {
        reentryCalldata = data;
    }

    receive() external payable {
        if (!reentered && reentryCalldata.length > 0) {
            reentered = true;
            (bool ok,) = address(pool).call(reentryCalldata);
            reentrySucceeded = ok;
        }
    }
}

contract DeveloperPoolTest is Test {
    DeveloperPool internal pool;

    address internal developer = makeAddr("developer");
    address internal withdrawalRecipient = makeAddr("withdrawalRecipient");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        pool = new DeveloperPool(developer, withdrawalRecipient);
    }

    // ── Constructor ────────────────────────────────────────────────────────────────────────────────────────────

    function test_ConstructorRevertsOnZeroDeveloper() public {
        vm.expectRevert(DeveloperPool.ZeroAddress.selector);
        new DeveloperPool(address(0), withdrawalRecipient);
    }

    function test_ConstructorRevertsOnZeroWithdrawalRecipient() public {
        vm.expectRevert(DeveloperPool.ZeroAddress.selector);
        new DeveloperPool(developer, address(0));
    }

    // ── receive ────────────────────────────────────────────────────────────────────────────────────────────────

    function test_ReceiveAcceptsPlainTransferAndEmits() public {
        vm.expectEmit(true, true, true, true, address(pool));
        emit DeveloperPool.Received(address(this), 1 ether);

        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(pool).balance, 1 ether);
    }

    // ── setWithdrawalRecipient ─────────────────────────────────────────────────────────────────────────────────

    function test_SetWithdrawalRecipientUpdatesAndEmits() public {
        address newRecipient = makeAddr("newRecipient");
        vm.expectEmit(true, true, true, true, address(pool));
        emit DeveloperPool.WithdrawalRecipientUpdated(newRecipient);

        vm.prank(developer);
        pool.setWithdrawalRecipient(newRecipient);

        assertEq(pool.withdrawalRecipient(), newRecipient);
    }

    function test_SetWithdrawalRecipientRevertsWhenNotDeveloper() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DeveloperPool.NotDeveloper.selector, stranger));
        pool.setWithdrawalRecipient(makeAddr("newRecipient"));
    }

    function test_SetWithdrawalRecipientRevertsOnZeroAddress() public {
        vm.prank(developer);
        vm.expectRevert(DeveloperPool.ZeroAddress.selector);
        pool.setWithdrawalRecipient(address(0));
    }

    function test_DeveloperAddressItselfIsNeverUpdatable() public view {
        // Section 2.8: the withdrawal *recipient* is the one mutable parameter in the whole protocol - the
        // developer role itself has no setter at all. This is a compile-time/API-surface guarantee (no such
        // function exists), asserted here only as a documentation anchor.
        assertEq(pool.developer(), developer);
    }

    // ── withdraw ───────────────────────────────────────────────────────────────────────────────────────────────

    function test_WithdrawSendsToRecipientNotCaller() public {
        vm.deal(address(pool), 10 ether);
        uint256 recipientBefore = withdrawalRecipient.balance;

        vm.prank(developer);
        pool.withdraw(3 ether);

        assertEq(withdrawalRecipient.balance - recipientBefore, 3 ether);
        assertEq(address(pool).balance, 7 ether);
    }

    function test_WithdrawSendsToUpdatedRecipientAfterChange() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(developer);
        pool.setWithdrawalRecipient(newRecipient);

        vm.deal(address(pool), 5 ether);
        vm.prank(developer);
        pool.withdraw(5 ether);

        assertEq(newRecipient.balance, 5 ether);
        assertEq(withdrawalRecipient.balance, 0);
    }

    function test_WithdrawRevertsWhenNotDeveloper() public {
        vm.deal(address(pool), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DeveloperPool.NotDeveloper.selector, stranger));
        pool.withdraw(1 ether);
    }

    function test_WithdrawRevertsWhenExceedingBalance() public {
        vm.deal(address(pool), 1 ether);
        vm.prank(developer);
        vm.expectRevert(abi.encodeWithSelector(DeveloperPool.InsufficientBalance.selector, 2 ether, 1 ether));
        pool.withdraw(2 ether);
    }

    // ── Adversarial ────────────────────────────────────────────────────────────────────────────────────────────

    function test_ReentrantWithdrawalRecipientCannotReenterWithdraw() public {
        ReentrantParty attacker = new ReentrantParty(pool);
        vm.prank(developer);
        pool.setWithdrawalRecipient(address(attacker));
        vm.deal(address(pool), 10 ether);

        attacker.setReentryCalldata(abi.encodeWithSelector(DeveloperPool.withdraw.selector, uint256(1 ether)));

        vm.prank(developer);
        pool.withdraw(2 ether);

        assertTrue(attacker.reentered());
        assertFalse(attacker.reentrySucceeded(), "reentrant withdraw should have been blocked");
        assertEq(address(pool).balance, 8 ether, "only the legitimate 2 ether withdrawal should have gone through");
    }
}
