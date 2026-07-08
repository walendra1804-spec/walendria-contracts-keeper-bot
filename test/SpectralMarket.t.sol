// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SD59x18, sd, ZERO} from "prb-math/SD59x18.sol";
import {LMSRMath} from "../src/LMSRMath.sol";
import {SpectralMarket} from "../src/SpectralMarket.sol";
import {ISettlementConditionsHook} from "../src/ISettlementConditionsHook.sol";

/// @dev Reenters `market` with an arbitrary, test-configured calldata payload during its own `receive()`,
///      mirroring the ReentrantAttacker/ReentrantBuyer pattern already established in prior phases' tests.
contract ReentrantTrader {
    SpectralMarket public market;
    bytes public reentryCalldata;
    bool public reentered;
    bool public reentrySucceeded;

    constructor(SpectralMarket _market) {
        market = _market;
    }

    function setReentryCalldata(bytes calldata data) external {
        reentryCalldata = data;
    }

    function attackBuy(uint256 marketId, SpectralMarket.Side side, uint256 shares, uint256 value) external {
        market.buy{value: value}(marketId, side, shares);
    }

    function attackRedeem(uint256 marketId) external {
        market.redeem(marketId);
    }

    receive() external payable {
        if (!reentered && reentryCalldata.length > 0) {
            reentered = true;
            (bool ok,) = address(market).call(reentryCalldata);
            reentrySucceeded = ok;
        }
    }
}

contract RevertingRecipient {
    receive() external payable {
        revert("RevertingRecipient: refuses ETH");
    }
}

contract SpectralMarketTest is Test {
    SpectralMarket internal market;

    address internal controller = makeAddr("controller"); // stand-in for DisputeManager.sol / SettlementConditions.sol
    address internal guilty1 = makeAddr("guilty1");
    address internal guilty2 = makeAddr("guilty2");
    address internal seller = makeAddr("seller");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant P = 1 ether;
    uint256 internal constant B = 1 ether; // b = 1 * P, Section 2.6.9's worked example / locked parameter table
    uint256 internal constant HALF_P = 0.5 ether;

    function setUp() public {
        address[] memory controllers = new address[](1);
        controllers[0] = controller;
        market = new SpectralMarket(controllers, ISettlementConditionsHook(address(0)), address(0));
        vm.deal(controller, 1000 ether);
        vm.deal(guilty1, 1000 ether);
        vm.deal(guilty2, 1000 ether);
        vm.deal(seller, 1000 ether);
        vm.deal(stranger, 1000 ether);
    }

    function _openSimpleMarket(uint256 marketId) internal {
        address[] memory funders = new address[](1);
        funders[0] = guilty1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;

        vm.prank(controller);
        market.openMarket{value: P}(marketId, B, funders, amounts, _singleton(seller), _singletonAmt(HALF_P));
    }

    function _singleton(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _singletonAmt(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    // ── Constructor ────────────────────────────────────────────────────────────────────────────────────────────

    function test_ConstructorRevertsOnEmptyControllers() public {
        vm.expectRevert(SpectralMarket.NoControllers.selector);
        new SpectralMarket(new address[](0), ISettlementConditionsHook(address(0)), address(0));
    }

    // ── openMarket ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_OpenMarketCreditsSharesAtTwiceTheDollarContribution() public {
        _openSimpleMarket(1);
        assertEq(market.sharesOf(1, SpectralMarket.Side.Guilty, guilty1), P, "0.5P in at 50/50 buys P shares");
        assertEq(market.sharesOf(1, SpectralMarket.Side.Innocent, seller), P);
    }

    function test_OpenMarketSplitsGuiltyCreditProportionallyAcrossMultipleFunders() public {
        address[] memory funders = new address[](2);
        funders[0] = guilty1;
        funders[1] = guilty2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0.3 ether;
        amounts[1] = 0.2 ether; // sums to HALF_P

        vm.prank(controller);
        market.openMarket{value: P}(1, B, funders, amounts, _singleton(seller), _singletonAmt(HALF_P));

        assertEq(market.sharesOf(1, SpectralMarket.Side.Guilty, guilty1), 0.6 ether);
        assertEq(market.sharesOf(1, SpectralMarket.Side.Guilty, guilty2), 0.4 ether);
        assertEq(market.sharesOf(1, SpectralMarket.Side.Innocent, seller), P);
    }

    function test_OpenMarketOpensAtExactlyFiftyFifty() public {
        _openSimpleMarket(1);
        (uint256 pGuilty, uint256 pInnocent) = market.currentPrice(1);
        assertEq(pGuilty, 0.5e18);
        assertEq(pInnocent, 0.5e18);
    }

    function test_OpenMarketIsOrderIndependent() public {
        // Market 1: guilty1 funds first in the array, guilty2 second.
        address[] memory fundersA = new address[](2);
        fundersA[0] = guilty1;
        fundersA[1] = guilty2;
        uint256[] memory amountsA = new uint256[](2);
        amountsA[0] = 0.3 ether;
        amountsA[1] = 0.2 ether;
        vm.prank(controller);
        market.openMarket{value: P}(1, B, fundersA, amountsA, _singleton(seller), _singletonAmt(HALF_P));

        // Market 2: same funders/amounts, opposite array order.
        address[] memory fundersB = new address[](2);
        fundersB[0] = guilty2;
        fundersB[1] = guilty1;
        uint256[] memory amountsB = new uint256[](2);
        amountsB[0] = 0.2 ether;
        amountsB[1] = 0.3 ether;
        vm.prank(controller);
        market.openMarket{value: P}(2, B, fundersB, amountsB, _singleton(seller), _singletonAmt(HALF_P));

        assertEq(
            market.sharesOf(1, SpectralMarket.Side.Guilty, guilty1),
            market.sharesOf(2, SpectralMarket.Side.Guilty, guilty1)
        );
        assertEq(
            market.sharesOf(1, SpectralMarket.Side.Guilty, guilty2),
            market.sharesOf(2, SpectralMarket.Side.Guilty, guilty2)
        );

        (uint256 pG1, uint256 pI1) = market.currentPrice(1);
        (uint256 pG2, uint256 pI2) = market.currentPrice(2);
        assertEq(pG1, pG2);
        assertEq(pI1, pI2);
        assertEq(pG1, 0.5e18, "both must open at exactly 50/50 regardless of funding order");
    }

    /// @notice The closed-form joint-injection shortcut (shares = 2x dollars) is not trusted blindly - it is
    ///         cross-checked here directly against LMSRMath.cost(), for several (b, totalIn) pairs, proving
    ///         moving from (0,0) to (q,q) really does cost exactly q regardless of b (Section 2.6.4).
    function test_JointInjectionShortcutMatchesLMSRMathCostDirectly() public pure {
        uint256[3] memory bValues = [uint256(0.1 ether), 1 ether, 50 ether];
        uint256[3] memory totalInValues = [uint256(0.01 ether), 1 ether, 10 ether];

        for (uint256 i = 0; i < bValues.length; i++) {
            SD59x18 b = sd(int256(bValues[i]));
            SD59x18 q = sd(int256(totalInValues[i]));
            SD59x18 deltaC = LMSRMath.cost(q, q, b) - LMSRMath.cost(ZERO, ZERO, b);
            assertApproxEqAbs(
                SD59x18.unwrap(deltaC), int256(totalInValues[i]), 1e6, "cost(q,q)-cost(0,0) should equal q"
            );
        }
    }

    function test_OpenMarketRevertsWhenAlreadyOpen() public {
        _openSimpleMarket(1);
        address[] memory funders = new address[](1);
        funders[0] = guilty1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.MarketAlreadyOpen.selector, 1));
        market.openMarket{value: P}(1, B, funders, amounts, _singleton(seller), _singletonAmt(HALF_P));
    }

    function test_OpenMarketRevertsOnZeroLiquidityParameter() public {
        address[] memory funders = new address[](1);
        funders[0] = guilty1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;
        vm.prank(controller);
        vm.expectRevert(SpectralMarket.ZeroLiquidityParameter.selector);
        market.openMarket{value: P}(1, 0, funders, amounts, _singleton(seller), _singletonAmt(HALF_P));
    }

    function test_OpenMarketRevertsOnEmptyContributionList() public {
        vm.prank(controller);
        vm.expectRevert(SpectralMarket.EmptyContributionList.selector);
        market.openMarket{value: 0}(1, B, new address[](0), new uint256[](0), _singleton(seller), _singletonAmt(0));
    }

    function test_OpenMarketRevertsOnArrayLengthMismatch() public {
        address[] memory funders = new address[](2);
        funders[0] = guilty1;
        funders[1] = guilty2;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.ContributionArrayLengthMismatch.selector, 2, 1));
        market.openMarket{value: HALF_P}(1, B, funders, amounts, _singleton(seller), _singletonAmt(HALF_P));
    }

    function test_OpenMarketRevertsOnMismatchedContributions() public {
        address[] memory funders = new address[](1);
        funders[0] = guilty1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0.4 ether;
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(SpectralMarket.MismatchedInitialContributions.selector, 0.4 ether, HALF_P)
        );
        market.openMarket{value: 0.9 ether}(1, B, funders, amounts, _singleton(seller), _singletonAmt(HALF_P));
    }

    function test_OpenMarketRevertsOnIncorrectValueSent() public {
        address[] memory funders = new address[](1);
        funders[0] = guilty1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.IncorrectValueSent.selector, P + 1, P));
        market.openMarket{value: P + 1}(1, B, funders, amounts, _singleton(seller), _singletonAmt(HALF_P));
    }

    function test_OpenMarketRevertsForNonController() public {
        address[] memory funders = new address[](1);
        funders[0] = guilty1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.NotController.selector, stranger));
        market.openMarket{value: P}(1, B, funders, amounts, _singleton(seller), _singletonAmt(HALF_P));
    }

    // ── buy ────────────────────────────────────────────────────────────────────────────────────────────────────

    function test_BuyGuiltyMovesPriceUpAndMatchesLMSRMathPrediction() public {
        _openSimpleMarket(1);

        SD59x18 qG = sd(int256(P));
        SD59x18 qI = sd(int256(P));
        SD59x18 bFixed = sd(int256(B));
        SD59x18 expectedCostFixed = LMSRMath.costOfTrade(qG, qI, sd(int256(0.1 ether)), ZERO, bFixed);
        uint256 expectedCost = uint256(SD59x18.unwrap(expectedCostFixed));

        vm.prank(stranger);
        uint256 cost = market.buy{value: 1 ether}(1, SpectralMarket.Side.Guilty, 0.1 ether);

        assertEq(cost, expectedCost);
        assertEq(market.sharesOf(1, SpectralMarket.Side.Guilty, stranger), 0.1 ether);

        (uint256 pGuilty,) = market.currentPrice(1);
        assertGt(pGuilty, 0.5e18, "buying Guilty should push Guilty price above 50%");
    }

    function test_BuyRefundsExcessOverMaxCost() public {
        _openSimpleMarket(1);
        uint256 before = stranger.balance;

        vm.prank(stranger);
        uint256 cost = market.buy{value: 5 ether}(1, SpectralMarket.Side.Guilty, 0.1 ether);

        assertEq(before - stranger.balance, cost, "buyer should only be out the actual cost, rest refunded");
        assertEq(address(market).balance, P + cost);
    }

    function test_BuyRevertsOnZeroShares() public {
        _openSimpleMarket(1);
        vm.prank(stranger);
        vm.expectRevert(SpectralMarket.ZeroShares.selector);
        market.buy{value: 1 ether}(1, SpectralMarket.Side.Guilty, 0);
    }

    function test_BuyRevertsWhenMarketNotOpen() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.MarketNotOpen.selector, 1));
        market.buy{value: 1 ether}(1, SpectralMarket.Side.Guilty, 0.1 ether);
    }

    function test_BuyRevertsWhenMarketResolved() public {
        _openSimpleMarket(1);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.MarketAlreadyResolved.selector, 1));
        market.buy{value: 1 ether}(1, SpectralMarket.Side.Guilty, 0.1 ether);
    }

    function test_BuyRevertsOnSlippageExceeded() public {
        _openSimpleMarket(1);
        vm.prank(stranger);
        vm.expectRevert(); // BuySlippageExceeded(cost, maxCost) - cost computed dynamically, checked via selector below
        market.buy{value: 1}(1, SpectralMarket.Side.Guilty, 10 ether);
    }

    function test_BuyRevertsOnSlippageExceededWithExactSelector() public {
        _openSimpleMarket(1);
        SD59x18 qG = sd(int256(P));
        SD59x18 qI = sd(int256(P));
        SD59x18 bFixed = sd(int256(B));
        SD59x18 costFixed = LMSRMath.costOfTrade(qG, qI, sd(int256(0.1 ether)), ZERO, bFixed);
        uint256 cost = uint256(SD59x18.unwrap(costFixed));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.BuySlippageExceeded.selector, cost, cost - 1));
        market.buy{value: cost - 1}(1, SpectralMarket.Side.Guilty, 0.1 ether);
    }

    // ── sell ───────────────────────────────────────────────────────────────────────────────────────────────────

    function test_SellReturnsSharesAndDecreasesQ() public {
        _openSimpleMarket(1);
        vm.prank(stranger);
        market.buy{value: 1 ether}(1, SpectralMarket.Side.Guilty, 0.2 ether);

        vm.prank(stranger);
        uint256 proceeds = market.sell(1, SpectralMarket.Side.Guilty, 0.2 ether, 0);

        assertEq(market.sharesOf(1, SpectralMarket.Side.Guilty, stranger), 0);
        assertGt(proceeds, 0);
    }

    function test_BuyThenImmediatelySellRoundTripsExactly() public {
        _openSimpleMarket(1);
        uint256 before = stranger.balance;

        vm.prank(stranger);
        uint256 cost = market.buy{value: 1 ether}(1, SpectralMarket.Side.Innocent, 0.15 ether);
        vm.prank(stranger);
        uint256 proceeds = market.sell(1, SpectralMarket.Side.Innocent, 0.15 ether, 0);

        assertEq(proceeds, cost, "an immediate round trip with no intervening trades must be exactly a wash");
        assertEq(before - stranger.balance, 0);
    }

    function test_SellRevertsOnInsufficientShares() public {
        _openSimpleMarket(1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.InsufficientShares.selector, stranger, 1 ether, 0));
        market.sell(1, SpectralMarket.Side.Guilty, 1 ether, 0);
    }

    function test_SellRevertsOnZeroShares() public {
        _openSimpleMarket(1);
        vm.prank(guilty1);
        vm.expectRevert(SpectralMarket.ZeroShares.selector);
        market.sell(1, SpectralMarket.Side.Guilty, 0, 0);
    }

    function test_SellRevertsOnSlippageExceeded() public {
        _openSimpleMarket(1);
        vm.prank(guilty1);
        vm.expectRevert();
        market.sell(1, SpectralMarket.Side.Guilty, 0.1 ether, type(uint256).max);
    }

    function test_SellRevertsWhenMarketResolved() public {
        _openSimpleMarket(1);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        vm.prank(guilty1);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.MarketAlreadyResolved.selector, 1));
        market.sell(1, SpectralMarket.Side.Guilty, 0.1 ether, 0);
    }

    // ── resolveMarket ──────────────────────────────────────────────────────────────────────────────────────────

    function test_ResolveMarketSetsWinningSide() public {
        _openSimpleMarket(1);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Innocent);
        (,,,,, bool resolved, SpectralMarket.Side winningSide) = market.markets(1);
        assertTrue(resolved);
        assertEq(uint256(winningSide), uint256(SpectralMarket.Side.Innocent));
    }

    function test_ResolveMarketRevertsWhenNotOpen() public {
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.MarketNotOpen.selector, 1));
        market.resolveMarket(1, SpectralMarket.Side.Guilty);
    }

    function test_ResolveMarketRevertsWhenAlreadyResolved() public {
        _openSimpleMarket(1);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.MarketAlreadyResolved.selector, 1));
        market.resolveMarket(1, SpectralMarket.Side.Innocent);
    }

    function test_ResolveMarketRevertsForNonController() public {
        _openSimpleMarket(1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.NotController.selector, stranger));
        market.resolveMarket(1, SpectralMarket.Side.Guilty);
    }

    // ── redeem ─────────────────────────────────────────────────────────────────────────────────────────────────

    function test_RedeemPaysWinningShareHolderOneToOne() public {
        _openSimpleMarket(1);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        uint256 before = guilty1.balance;
        vm.prank(guilty1);
        uint256 payout = market.redeem(1);

        assertEq(payout, P, "guilty1 holds all P Guilty shares from the joint injection");
        assertEq(guilty1.balance - before, P);
        assertEq(market.sharesOf(1, SpectralMarket.Side.Guilty, guilty1), 0);
    }

    function test_RedeemWithNoFurtherTradingExactlyDrainsThePool() public {
        _openSimpleMarket(1);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Innocent);

        vm.prank(seller);
        market.redeem(1);

        assertEq(address(market).balance, 0, "uncontested resolution with no further trading exactly drains the pool");
    }

    function test_LosingSideHolderHasNothingToRedeem() public {
        _openSimpleMarket(1);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Innocent);

        vm.prank(guilty1);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.NothingToRedeem.selector, guilty1));
        market.redeem(1);
    }

    function test_RedeemRevertsWhenNotResolved() public {
        _openSimpleMarket(1);
        vm.prank(guilty1);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.MarketNotResolved.selector, 1));
        market.redeem(1);
    }

    function test_RedeemRevertsOnDoubleRedeem() public {
        _openSimpleMarket(1);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        vm.prank(guilty1);
        market.redeem(1);

        vm.prank(guilty1);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.NothingToRedeem.selector, guilty1));
        market.redeem(1);
    }

    function test_RedeemRevertsWholeCallWhenRecipientRejectsEth() public {
        _openSimpleMarket(1);
        RevertingRecipient bad = new RevertingRecipient();

        address[] memory funders = new address[](1);
        funders[0] = address(bad);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;
        vm.prank(controller);
        market.openMarket{value: P}(2, B, funders, amounts, _singleton(seller), _singletonAmt(HALF_P));
        vm.prank(controller);
        market.resolveMarket(2, SpectralMarket.Side.Guilty);

        vm.prank(address(bad));
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.TransferFailed.selector, address(bad), P));
        market.redeem(2);
    }

    // ── Adversarial ────────────────────────────────────────────────────────────────────────────────────────────

    function test_ReentrantTraderCannotDoubleRedeemDuringPayout() public {
        _openSimpleMarket(1);
        ReentrantTrader attacker = new ReentrantTrader(market);

        address[] memory funders = new address[](1);
        funders[0] = address(attacker);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;
        vm.prank(controller);
        market.openMarket{value: P}(2, B, funders, amounts, _singleton(seller), _singletonAmt(HALF_P));
        vm.prank(controller);
        market.resolveMarket(2, SpectralMarket.Side.Guilty);

        attacker.setReentryCalldata(abi.encodeWithSelector(SpectralMarket.redeem.selector, uint256(2)));
        attacker.attackRedeem(2);

        assertTrue(attacker.reentered());
        assertFalse(attacker.reentrySucceeded(), "reentrant redeem() should have been blocked");
        assertEq(market.sharesOf(2, SpectralMarket.Side.Guilty, address(attacker)), 0);
        assertEq(address(attacker).balance, P, "attacker should be paid exactly once, not twice");
    }

    function test_ReentrantTraderCannotBuyAgainDuringRefund() public {
        _openSimpleMarket(1);
        ReentrantTrader attacker = new ReentrantTrader(market);
        vm.deal(address(attacker), 10 ether);

        attacker.setReentryCalldata(
            abi.encodeWithSelector(
                SpectralMarket.buy.selector, uint256(1), SpectralMarket.Side.Innocent, uint256(0.05 ether)
            )
        );
        attacker.attackBuy(1, SpectralMarket.Side.Guilty, 0.1 ether, 5 ether);

        assertTrue(attacker.reentered());
        assertFalse(attacker.reentrySucceeded(), "reentrant buy() should have been blocked");
    }

    /// @notice Section 2.6.4's path-independence claim, tested against code: splitting a given trade volume
    ///         across many separate wallets and transactions costs exactly the same, in aggregate, as one wallet
    ///         buying the full amount in a single call.
    function test_SplitTradeAcrossManyWalletsCostsSameAsOneWallet() public {
        _openSimpleMarket(1);
        uint256 totalShares = 1 ether;
        uint256 chunks = 50;
        uint256 perChunk = totalShares / chunks;

        uint256 splitTotalCost;
        for (uint256 i = 0; i < chunks; i++) {
            address wallet = makeAddr(string.concat("splitWallet", vm.toString(i)));
            vm.deal(wallet, 10 ether);
            vm.prank(wallet);
            splitTotalCost += market.buy{value: 10 ether}(1, SpectralMarket.Side.Guilty, perChunk);
        }

        _openSimpleMarket(2);
        vm.prank(stranger);
        uint256 oneShotCost = market.buy{value: 100 ether}(2, SpectralMarket.Side.Guilty, perChunk * chunks);

        assertApproxEqAbs(
            splitTotalCost, oneShotCost, chunks, "1000-wallet-style split should cost the same as one wallet"
        );
    }

    // ── Fuzz ───────────────────────────────────────────────────────────────────────────────────────────────────

    function testFuzz_OpenMarketAlwaysOpensAtExactlyFiftyFifty(uint256 halfPSeed) public {
        uint256 halfP = bound(halfPSeed, 1, 1_000_000 ether);
        // b = 2 * halfP matches the protocol's actual calibration (b = 1*P, halfP = 0.5*P), keeping qG/b == 1
        // regardless of scale. b-independence of the 50/50 opening price itself (i.e. varying the *ratio*
        // between b and the injected total, not just their common scale) is proven separately and exactly in
        // {test_JointInjectionShortcutMatchesLMSRMathCostDirectly} across several deliberately mismatched ratios,
        // chosen to stay within PRBMath's exp() domain rather than fuzzed (an independently fuzzed b here can
        // otherwise land far enough from halfP's scale to push qG/b outside PRBMath's valid exp() input range).
        uint256 b = halfP * 2;

        address[] memory funders = new address[](1);
        funders[0] = guilty1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = halfP;

        vm.deal(controller, halfP * 2 + 1);
        vm.prank(controller);
        market.openMarket{value: halfP * 2}(1, b, funders, amounts, _singleton(seller), _singletonAmt(halfP));

        (uint256 pGuilty, uint256 pInnocent) = market.currentPrice(1);
        assertEq(pGuilty, 0.5e18);
        assertEq(pInnocent, 0.5e18);
    }

    function testFuzz_BuyThenSellRoundTripAlwaysNetsToZero(uint256 shareSeed) public {
        _openSimpleMarket(1);
        // Floor above 1e9 for the same fixed-point-precision reason as {testFuzz_BuyCostMatchesLMSRMathIndependently}.
        uint256 shares = bound(shareSeed, 1e9, 5 ether); // stay well within PRBMath's exp() domain for b=1 ether

        vm.deal(stranger, 1000 ether);
        uint256 before = stranger.balance;

        vm.prank(stranger);
        uint256 cost = market.buy{value: 1000 ether}(1, SpectralMarket.Side.Guilty, shares);
        vm.prank(stranger);
        uint256 proceeds = market.sell(1, SpectralMarket.Side.Guilty, shares, 0);

        assertEq(proceeds, cost);
        assertEq(before - stranger.balance, 0);
    }

    function testFuzz_BuyCostMatchesLMSRMathIndependently(uint256 shareSeed) public {
        _openSimpleMarket(1);
        // Floor above 1e9: below this, the LMSR cost of such a vanishingly small trade can round to fixed-point
        // zero (PRBMath's ln/exp lose precision on a perturbation this tiny relative to e^1), which is a known,
        // accepted precision limit (see {SpectralMarket-_positiveToUint256}), not a property this test targets.
        uint256 shares = bound(shareSeed, 1e9, 5 ether);

        SD59x18 expectedCostFixed =
            LMSRMath.costOfTrade(sd(int256(P)), sd(int256(P)), sd(int256(shares)), ZERO, sd(int256(B)));
        uint256 expectedCost = uint256(SD59x18.unwrap(expectedCostFixed));

        vm.deal(stranger, expectedCost + 1 ether);
        vm.prank(stranger);
        uint256 cost = market.buy{value: expectedCost + 1 ether}(1, SpectralMarket.Side.Guilty, shares);

        assertEq(cost, expectedCost);
    }
}

/// @dev A DeveloperPool stand-in whose `receive()` always reverts, to test that a broken developer pool cannot
///      corrupt {sweepSurplus}'s own state (the sweep must roll back entirely alongside the failed transfer).
contract RevertingDeveloperPool {
    receive() external payable {
        revert("RevertingDeveloperPool: refuses ETH");
    }
}

contract SpectralMarketSurplusTest is Test {
    SpectralMarket internal market;
    address internal controller = makeAddr("surplusController");
    address internal seller = makeAddr("surplusSeller");
    address internal guilty1 = makeAddr("surplusGuilty1");
    address internal loser = makeAddr("surplusLoser");
    address internal developerPool = makeAddr("developerPool");

    uint256 internal constant P = 1 ether;
    uint256 internal constant B = 1 ether;
    uint256 internal constant HALF_P = 0.5 ether;

    function setUp() public {
        address[] memory controllers = new address[](1);
        controllers[0] = controller;
        market = new SpectralMarket(controllers, ISettlementConditionsHook(address(0)), developerPool);

        vm.deal(controller, 1000 ether);
        vm.deal(loser, 1000 ether);

        address[] memory funders = new address[](1);
        funders[0] = guilty1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;
        address[] memory innocentRecipients = new address[](1);
        innocentRecipients[0] = seller;
        uint256[] memory innocentAmounts = new uint256[](1);
        innocentAmounts[0] = HALF_P;

        vm.prank(controller);
        market.openMarket{value: P}(1, B, funders, amounts, innocentRecipients, innocentAmounts);
    }

    /// @notice The entire cost of a losing-side trade becomes surplus once resolved: it adds to `pooled` but the
    ///         winning-side obligation (qGuilty here) never grows because of it.
    function test_SweepSurplusTransfersLosingTradeCostAsSurplus() public {
        vm.prank(loser);
        uint256 cost = market.buy{value: 1 ether}(1, SpectralMarket.Side.Innocent, 0.3 ether);

        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        uint256 devBefore = developerPool.balance;
        uint256 surplus = market.sweepSurplus(1);

        assertEq(surplus, cost, "the entire failed Innocent-side bet's cost becomes surplus when Guilty wins");
        assertEq(developerPool.balance - devBefore, surplus);

        vm.prank(guilty1);
        uint256 payout = market.redeem(1);
        assertEq(payout, 1 ether, "the winning side's redemption is unaffected by the surplus sweep");
    }

    // ── payResolutionBounty (the 0.1% poke bounty, drawn from the same surplus) ───────────────────────────────

    /// @notice A successful poke's bounty is paid from the same surplus a sweep would otherwise collect: the
    ///         recipient receives the requested amount when the surplus covers it, and the remainder still sweeps
    ///         to the Developer Pool. Winners are still made whole 1:1.
    function test_PayResolutionBountyPaysRequestedFromSurplusThenRestSweeps() public {
        vm.prank(loser);
        uint256 cost = market.buy{value: 1 ether}(1, SpectralMarket.Side.Innocent, 0.3 ether);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        address poker = makeAddr("surplusPoker");
        uint256 requested = cost / 4; // comfortably below the available surplus
        uint256 pokerBefore = poker.balance;

        vm.prank(controller);
        uint256 paid = market.payResolutionBounty(1, poker, requested);

        assertEq(paid, requested, "pays the full request when the surplus covers it");
        assertEq(poker.balance - pokerBefore, requested);

        uint256 devBefore = developerPool.balance;
        uint256 swept = market.sweepSurplus(1);
        assertEq(swept, cost - requested, "the remainder of the surplus still sweeps to the Developer Pool");
        assertEq(developerPool.balance - devBefore, swept);

        vm.prank(guilty1);
        assertEq(market.redeem(1), 1 ether, "the winning side is still made whole 1:1");
    }

    function test_PayResolutionBountyCapsAtAvailableSurplus() public {
        vm.prank(loser);
        uint256 cost = market.buy{value: 1 ether}(1, SpectralMarket.Side.Innocent, 0.3 ether);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        address poker = makeAddr("surplusPoker2");
        uint256 requested = cost + 1 ether; // far more than the surplus holds

        vm.prank(controller);
        uint256 paid = market.payResolutionBounty(1, poker, requested);

        assertEq(paid, cost, "capped at the whole available surplus, never more");
        assertEq(poker.balance, cost);

        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.NoSurplusToSweep.selector, 1));
        market.sweepSurplus(1); // nothing left after the bounty took the whole surplus
    }

    function test_PayResolutionBountyRevertsForNonController() public {
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        address notController = makeAddr("notController");
        vm.prank(notController);
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.NotController.selector, notController));
        market.payResolutionBounty(1, notController, 1);
    }

    function test_SweepSurplusEmitsEvent() public {
        vm.prank(loser);
        uint256 cost = market.buy{value: 1 ether}(1, SpectralMarket.Side.Innocent, 0.3 ether);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        vm.expectEmit(true, true, true, true, address(market));
        emit SpectralMarket.SurplusSwept(1, cost);
        market.sweepSurplus(1);
    }

    function test_SweepSurplusIsPermissionless() public {
        vm.prank(loser);
        market.buy{value: 1 ether}(1, SpectralMarket.Side.Innocent, 0.3 ether);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        vm.prank(makeAddr("anyRandomCaller"));
        market.sweepSurplus(1); // must not revert - no access control on this function
    }

    function test_SweepSurplusRevertsWhenDeveloperPoolNotSet() public {
        address[] memory controllers = new address[](1);
        controllers[0] = controller;
        SpectralMarket marketWithoutDevPool =
            new SpectralMarket(controllers, ISettlementConditionsHook(address(0)), address(0));

        address[] memory funders = new address[](1);
        funders[0] = guilty1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;
        address[] memory innocentRecipients = new address[](1);
        innocentRecipients[0] = seller;
        uint256[] memory innocentAmounts = new uint256[](1);
        innocentAmounts[0] = HALF_P;
        vm.prank(controller);
        marketWithoutDevPool.openMarket{value: P}(1, B, funders, amounts, innocentRecipients, innocentAmounts);
        vm.prank(controller);
        marketWithoutDevPool.resolveMarket(1, SpectralMarket.Side.Guilty);

        vm.expectRevert(SpectralMarket.DeveloperPoolNotSet.selector);
        marketWithoutDevPool.sweepSurplus(1);
    }

    function test_SweepSurplusRevertsWhenMarketNotResolved() public {
        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.MarketNotResolved.selector, 1));
        market.sweepSurplus(1);
    }

    function test_SweepSurplusRevertsWhenNoSurplusExists() public {
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.NoSurplusToSweep.selector, 1));
        market.sweepSurplus(1);
    }

    /// @notice Calling sweepSurplus again after it already collected everything must find nothing left - not
    ///         double-sweep the winning side's own redemption backing.
    function test_SweepSurplusIsNotDoubleCountedOnRepeatedCalls() public {
        vm.prank(loser);
        market.buy{value: 1 ether}(1, SpectralMarket.Side.Innocent, 0.3 ether);
        vm.prank(controller);
        market.resolveMarket(1, SpectralMarket.Side.Guilty);

        market.sweepSurplus(1);

        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.NoSurplusToSweep.selector, 1));
        market.sweepSurplus(1);
    }

    /// @notice The surplus is a constant quantity from resolution onward regardless of how many winners have
    ///         already redeemed - sweeping after a partial redemption must find the identical surplus, and the
    ///         remaining winner must still redeem in full afterward. Uses two Guilty funders credited at
    ///         *open* time (not a post-open buy) so both positions are exactly $1-per-share-backed from the
    ///         start, isolating this from Section 2.6.9's separate "a winning trade's own cost is below its
    ///         eventual payout" property (tested elsewhere).
    function test_SweepSurplusUnaffectedByPriorPartialRedemption() public {
        address[] memory funders = new address[](2);
        funders[0] = guilty1;
        funders[1] = makeAddr("surplusGuilty2");
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0.3 ether;
        amounts[1] = 0.2 ether;
        address[] memory innocentRecipients = new address[](1);
        innocentRecipients[0] = seller;
        uint256[] memory innocentAmounts = new uint256[](1);
        innocentAmounts[0] = HALF_P;

        vm.prank(controller);
        market.openMarket{value: P}(2, B, funders, amounts, innocentRecipients, innocentAmounts);

        vm.prank(loser);
        uint256 losingCost = market.buy{value: 1 ether}(2, SpectralMarket.Side.Innocent, 0.3 ether);

        vm.prank(controller);
        market.resolveMarket(2, SpectralMarket.Side.Guilty);

        address guilty2 = funders[1];
        vm.prank(guilty2);
        uint256 guilty2Payout = market.redeem(2);
        assertEq(guilty2Payout, 0.4 ether, "2x guilty2's own 0.2 ether contribution, per the unbiased-opening identity");

        uint256 surplus = market.sweepSurplus(2);
        assertEq(
            surplus,
            losingCost,
            "surplus must equal exactly the losing trade's cost, unaffected by the prior redemption"
        );

        vm.prank(guilty1);
        uint256 guilty1Payout = market.redeem(2);
        assertEq(guilty1Payout, 0.6 ether, "the remaining winner must still redeem in full after the sweep");
    }

    function test_SweepSurplusRevertsWhenTransferFails() public {
        RevertingDeveloperPool badPool = new RevertingDeveloperPool();
        address[] memory controllers = new address[](1);
        controllers[0] = controller;
        SpectralMarket marketWithBadPool =
            new SpectralMarket(controllers, ISettlementConditionsHook(address(0)), address(badPool));

        address[] memory funders = new address[](1);
        funders[0] = guilty1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = HALF_P;
        address[] memory innocentRecipients = new address[](1);
        innocentRecipients[0] = seller;
        uint256[] memory innocentAmounts = new uint256[](1);
        innocentAmounts[0] = HALF_P;
        vm.prank(controller);
        marketWithBadPool.openMarket{value: P}(1, B, funders, amounts, innocentRecipients, innocentAmounts);

        vm.prank(loser);
        uint256 cost = marketWithBadPool.buy{value: 1 ether}(1, SpectralMarket.Side.Innocent, 0.3 ether);
        vm.prank(controller);
        marketWithBadPool.resolveMarket(1, SpectralMarket.Side.Guilty);

        vm.expectRevert(abi.encodeWithSelector(SpectralMarket.TransferFailed.selector, address(badPool), cost));
        marketWithBadPool.sweepSurplus(1);
    }
}
