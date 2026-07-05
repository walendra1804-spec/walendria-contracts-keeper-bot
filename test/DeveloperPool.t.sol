// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeveloperPool} from "../src/DeveloperPool.sol";
import {SpectralMarket} from "../src/SpectralMarket.sol";
import {ISettlementConditionsHook} from "../src/ISettlementConditionsHook.sol";

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

    function pullAsController() external returns (uint256) {
        return pool.pullLiquidityBuffer(1 ether);
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
    address internal controller = makeAddr("controller");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        address[] memory controllers = new address[](1);
        controllers[0] = controller;
        pool = new DeveloperPool(developer, withdrawalRecipient, controllers);
    }

    function _singleton(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    // ── Constructor ────────────────────────────────────────────────────────────────────────────────────────────

    function test_ConstructorRevertsOnZeroDeveloper() public {
        vm.expectRevert(DeveloperPool.ZeroAddress.selector);
        new DeveloperPool(address(0), withdrawalRecipient, _singleton(controller));
    }

    function test_ConstructorRevertsOnZeroWithdrawalRecipient() public {
        vm.expectRevert(DeveloperPool.ZeroAddress.selector);
        new DeveloperPool(developer, address(0), _singleton(controller));
    }

    function test_ConstructorRevertsOnEmptyControllers() public {
        vm.expectRevert(DeveloperPool.NoControllers.selector);
        new DeveloperPool(developer, withdrawalRecipient, new address[](0));
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

    // ── pullLiquidityBuffer ────────────────────────────────────────────────────────────────────────────────────

    function test_PullLiquidityBufferSendsFullAmountWhenSufficientlyFunded() public {
        vm.deal(address(pool), 10 ether);
        vm.prank(controller);
        uint256 sent = pool.pullLiquidityBuffer(3 ether);

        assertEq(sent, 3 ether);
        assertEq(controller.balance, 3 ether);
        assertEq(address(pool).balance, 7 ether);
    }

    /// @notice Direct regression test: an underfunded buffer shrinks the top-up, it never blocks/reverts.
    function test_PullLiquidityBufferCapsAtAvailableBalanceWithoutReverting() public {
        vm.deal(address(pool), 0.4 ether);
        vm.prank(controller);
        uint256 sent = pool.pullLiquidityBuffer(3 ether);

        assertEq(sent, 0.4 ether, "should cap at whatever is actually available");
        assertEq(address(pool).balance, 0);
    }

    function test_PullLiquidityBufferReturnsZeroWhenPoolIsEmpty() public {
        vm.prank(controller);
        uint256 sent = pool.pullLiquidityBuffer(1 ether);
        assertEq(sent, 0);
    }

    function test_PullLiquidityBufferRevertsWhenNotController() public {
        vm.deal(address(pool), 10 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DeveloperPool.NotController.selector, stranger));
        pool.pullLiquidityBuffer(1 ether);
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

    function test_ReentrantControllerCannotReenterPullLiquidityBuffer() public {
        // The controller registered on this pool must be the attacker's own address, so it needs a dedicated
        // pool deployed with the attacker pre-computed as the controller.
        uint256 nonce = vm.getNonce(address(this));
        address predictedPool = vm.computeCreateAddress(address(this), nonce + 1);
        ReentrantParty attacker = new ReentrantParty(DeveloperPool(payable(predictedPool)));

        address[] memory controllers = new address[](1);
        controllers[0] = address(attacker);
        DeveloperPool attackedPool = new DeveloperPool(developer, withdrawalRecipient, controllers);
        assertEq(address(attackedPool), predictedPool, "CREATE nonce prediction drifted");
        vm.deal(address(attackedPool), 10 ether);

        attacker.setReentryCalldata(
            abi.encodeWithSelector(DeveloperPool.pullLiquidityBuffer.selector, uint256(1 ether))
        );
        attacker.pullAsController();

        assertTrue(attacker.reentered());
        assertFalse(attacker.reentrySucceeded(), "reentrant pullLiquidityBuffer should have been blocked");
        assertEq(address(attackedPool).balance, 9 ether, "only the legitimate 1 ether pull should have gone through");
    }

    // ── Fuzz ───────────────────────────────────────────────────────────────────────────────────────────────────

    function testFuzz_PullLiquidityBufferNeverSendsMoreThanRequestedOrAvailable(
        uint256 balanceSeed,
        uint256 requestSeed
    ) public {
        uint256 balance = bound(balanceSeed, 0, 1_000_000 ether);
        uint256 request = bound(requestSeed, 0, 1_000_000 ether);
        vm.deal(address(pool), balance);

        vm.prank(controller);
        uint256 sent = pool.pullLiquidityBuffer(request);

        assertLe(sent, request);
        assertLe(sent, balance);
        assertEq(sent, request < balance ? request : balance);
        assertEq(address(pool).balance, balance - sent);
    }

    // ── redeemFromMarket ───────────────────────────────────────────────────────────────────────────────────────

    /// @notice Isolated proof that the try/catch actually swallows the revert: a market that was never opened
    ///         (so SpectralMarket.redeem reverts with MarketNotResolved) must produce a graceful zero payout, not
    ///         a bubbled-up revert. DisputeManager.t.sol covers the real end-to-end successful-redemption path.
    function test_RedeemFromMarketIsNoOpWhenMarketNotResolved() public {
        address[] memory marketControllers = new address[](1);
        marketControllers[0] = address(this);
        SpectralMarket market =
            new SpectralMarket(marketControllers, ISettlementConditionsHook(address(0)), address(pool));

        uint256 payout = pool.redeemFromMarket(market, 0);
        assertEq(payout, 0, "must gracefully no-op, not revert, when the market was never opened/resolved");
    }

    function test_RedeemFromMarketIsPermissionless() public {
        address[] memory marketControllers = new address[](1);
        marketControllers[0] = address(this);
        SpectralMarket market =
            new SpectralMarket(marketControllers, ISettlementConditionsHook(address(0)), address(pool));

        vm.prank(stranger);
        uint256 payout = pool.redeemFromMarket(market, 0);
        assertEq(payout, 0, "callable by anyone, same as SpectralMarket.sweepSurplus");
    }
}
