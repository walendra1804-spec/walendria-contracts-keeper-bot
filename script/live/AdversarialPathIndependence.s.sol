// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SD59x18} from "prb-math/SD59x18.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {Settlement} from "../../src/Settlement.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {DisputeManager} from "../../src/DisputeManager.sol";

/// @notice Phase 11 live pass, fourth batch (build strategy Section 4): proves two more path-independence
///         properties against the real deployed bytecode:
///         (1) funding the Guilty side in reverse order across two otherwise-identical listings produces an
///             identical opening state (Section 2.6.1) - mirrors test_FundGuiltySideOrderIndependence.
///         (2) splitting a fixed funding volume across several wallets produces the identical opening state as
///             one wallet funding the same total (Section 2.6.4) - mirrors
///             test_FundGuiltySideNWalletSplitMatchesSingleWallet, scaled to 5 wallets for live-gas practicality
///             (the local test already covers 20; the identity being verified does not depend on wallet count).
/// @dev fundGuiltySide's accumulation phase performs no AMM pricing at all - order/wallet-count can only ever
///      affect the recorded funders' array order, never the final (qGuilty, qInnocent) the joint injection opens
///      with. Four separate listings (A/B for the order test, Single/Split for the split test) are created by the
///      same seller/buyer pair, since only the funding-side amounts and ordering matter for either property.
///      Comparisons subtract out developerPool's own credited shares (DeveloperPool.pullLiquidityBuffer caps its
///      Section 2.6.7 top-up at whatever balance happens to remain in the shared, testnet-scale pool at the
///      moment each market opens - a real, order-of-market-creation-dependent effect this deployment's pool has
///      after many prior live test runs, but an orthogonal mechanism from the backer-funding-order property this
///      script is actually testing, not a violation of it).
contract AdversarialPathIndependenceScript is Script {
    IntegrityBond internal constant integrityBond = IntegrityBond(0xF33870A17C1A613c18e5BD8c7a5d8cF75e3b19D1);
    ListingManager internal constant listingManager = ListingManager(0xeBCF83A08faD5d571E7Aa1c5E5864592E9fb532f);
    Settlement internal constant settlement = Settlement(0x9f906a4cC3c879e494de7161888624514d4471F3);
    SpectralMarket internal constant spectralMarket = SpectralMarket(0x9bf0C2E07Af4b8e5C857593867dA3a6b00062b7b);
    DisputeManager internal constant disputeManager =
        DisputeManager(payable(0x317DC0607f67378509961b1763179050Af48F0ba));
    address internal constant developerPool = 0xa516f548dC0d21834a49C2a06710489a5921b403;

    uint256 internal constant P = 1_000_000; // wei — same tiny scale as prior live testing on this deployment
    uint256 internal constant HALF_PRICE = P / 2;
    uint256 internal constant COMPLETION_WINDOW = 72 hours;
    uint256 internal constant SPLIT_N = 5;

    function run() external {
        (address seller, uint256 sellerKey) = makeAddrAndKey("adversarial-live-seller-pathindep");
        (address buyer, uint256 buyerKey) = makeAddrAndKey("adversarial-live-buyer-pathindep");
        (address backer1, uint256 backer1Key) = makeAddrAndKey("adversarial-live-backer1-pathindep");
        (address backer2, uint256 backer2Key) = makeAddrAndKey("adversarial-live-backer2-pathindep");

        address[] memory splitWallets = new address[](SPLIT_N);
        uint256[] memory splitKeys = new uint256[](SPLIT_N);
        for (uint256 i = 0; i < SPLIT_N; i++) {
            (splitWallets[i], splitKeys[i]) =
                makeAddrAndKey(string.concat("adversarial-live-split-pathindep-", vm.toString(i)));
        }

        console.log("seller: ", seller);
        console.log("buyer:  ", buyer);
        console.log("backer1:", backer1);
        console.log("backer2:", backer2);

        _fundActors(seller, buyer, backer1, backer2, splitWallets);
        _runOrderIndependence(sellerKey, buyerKey, backer1Key, backer2Key);
        _runSplitIndependence(sellerKey, buyerKey, splitKeys);
    }

    function _fundActors(
        address seller,
        address buyer,
        address backer1,
        address backer2,
        address[] memory splitWallets
    ) internal {
        // Each of backer1/backer2/split wallets makes exactly one "threshold-crossing" fundGuiltySide call across
        // the two listings it participates in, which triggers the expensive joint-injection path (_openDispute) -
        // seen to need ~8e12 wei of gas headroom against the pre-flight balance check at this deployment's
        // gas-price flags (the first real-broadcast attempt failed here with backer2 underfunded at 5e12).
        vm.startBroadcast();
        (bool okSeller,) = seller.call{value: 20_000_000_000_000}("");
        require(okSeller, "funding seller failed");
        (bool okBuyer,) = buyer.call{value: 40_000_000_000_000}("");
        require(okBuyer, "funding buyer failed");
        (bool okBacker1,) = backer1.call{value: 15_000_000_000_000}("");
        require(okBacker1, "funding backer1 failed");
        (bool okBacker2,) = backer2.call{value: 15_000_000_000_000}("");
        require(okBacker2, "funding backer2 failed");
        for (uint256 i = 0; i < splitWallets.length; i++) {
            (bool ok,) = splitWallets[i].call{value: 15_000_000_000_000}("");
            require(ok, "funding split wallet failed");
        }
        vm.stopBroadcast();
        console.log("Funded all actors from broadcaster balance.");
    }

    function _createAndPayListing(uint256 sellerKey, uint256 buyerKey)
        internal
        returns (uint256 listingId, uint256 marketId)
    {
        vm.startBroadcast(sellerKey);
        integrityBond.deposit{value: (P * 3) / 2}();
        listingId = listingManager.createListing(P, 1, COMPLETION_WINDOW);
        vm.stopBroadcast();

        vm.startBroadcast(buyerKey);
        settlement.pay{value: P}(listingId, 0);
        vm.stopBroadcast();

        marketId = disputeManager.marketIdOf(listingId, 0);
    }

    function _runOrderIndependence(uint256 sellerKey, uint256 buyerKey, uint256 backer1Key, uint256 backer2Key)
        internal
    {
        (uint256 listingIdA, uint256 marketIdA) = _createAndPayListing(sellerKey, buyerKey);
        vm.startBroadcast(backer1Key);
        disputeManager.fundGuiltySide{value: (HALF_PRICE * 3) / 10}(listingIdA, 0); // 0.3 * HALF_PRICE, first
        vm.stopBroadcast();
        vm.startBroadcast(backer2Key);
        disputeManager.fundGuiltySide{value: (HALF_PRICE * 7) / 10}(listingIdA, 0); // 0.7 * HALF_PRICE, second
        vm.stopBroadcast();

        (uint256 listingIdB, uint256 marketIdB) = _createAndPayListing(sellerKey, buyerKey);
        vm.startBroadcast(backer2Key);
        disputeManager.fundGuiltySide{value: (HALF_PRICE * 7) / 10}(listingIdB, 0); // 0.7 * HALF_PRICE, first now
        vm.stopBroadcast();
        vm.startBroadcast(backer1Key);
        disputeManager.fundGuiltySide{value: (HALF_PRICE * 3) / 10}(listingIdB, 0); // 0.3 * HALF_PRICE, second now
        vm.stopBroadcast();

        int256 guiltyA = _fundersOnlyGuilty(marketIdA);
        int256 guiltyB = _fundersOnlyGuilty(marketIdB);
        int256 innocentA = _fundersOnlyInnocent(marketIdA);
        int256 innocentB = _fundersOnlyInnocent(marketIdB);
        require(guiltyA == guiltyB, "VIOLATION: order changed the backers' own qGuilty");
        require(innocentA == innocentB, "VIOLATION: order changed the seller's own qInnocent");
        console.log("CONFIRMED LIVE: funding Guilty side in reverse order produced an identical opening state.");
    }

    function _runSplitIndependence(uint256 sellerKey, uint256 buyerKey, uint256[] memory splitKeys) internal {
        (uint256 listingIdSingle, uint256 marketIdSingle) = _createAndPayListing(sellerKey, buyerKey);
        vm.startBroadcast(buyerKey);
        disputeManager.fundGuiltySide{value: HALF_PRICE}(listingIdSingle, 0);
        vm.stopBroadcast();

        (uint256 listingIdSplit, uint256 marketIdSplit) = _createAndPayListing(sellerKey, buyerKey);
        uint256 perWallet = HALF_PRICE / SPLIT_N;
        for (uint256 i = 0; i < splitKeys.length; i++) {
            vm.startBroadcast(splitKeys[i]);
            disputeManager.fundGuiltySide{value: perWallet}(listingIdSplit, 0);
            vm.stopBroadcast();
        }

        int256 guiltySingle = _fundersOnlyGuilty(marketIdSingle);
        int256 guiltySplit = _fundersOnlyGuilty(marketIdSplit);
        int256 innocentSingle = _fundersOnlyInnocent(marketIdSingle);
        int256 innocentSplit = _fundersOnlyInnocent(marketIdSplit);
        require(guiltySingle == guiltySplit, "VIOLATION: split changed the backers' own qGuilty");
        require(innocentSingle == innocentSplit, "VIOLATION: split changed the seller's own qInnocent");
        console.log("CONFIRMED LIVE: a 5-wallet split of the funding volume matched a single wallet.");
    }

    /// @notice qGuilty minus developerPool's own credited shares on the Guilty side - see the contract-level @dev
    ///         for why the raw qGuilty isn't directly comparable across markets opened moments apart against the
    ///         same finite, capped liquidity buffer.
    function _fundersOnlyGuilty(uint256 marketId) internal view returns (int256) {
        (, SD59x18 qGuilty,,,,,) = spectralMarket.markets(marketId);
        uint256 devShares = spectralMarket.sharesOf(marketId, SpectralMarket.Side.Guilty, developerPool);
        return SD59x18.unwrap(qGuilty) - int256(devShares);
    }

    /// @notice The Innocent-side counterpart of {_fundersOnlyGuilty}.
    function _fundersOnlyInnocent(uint256 marketId) internal view returns (int256) {
        (,, SD59x18 qInnocent,,,,) = spectralMarket.markets(marketId);
        uint256 devShares = spectralMarket.sharesOf(marketId, SpectralMarket.Side.Innocent, developerPool);
        return SD59x18.unwrap(qInnocent) - int256(devShares);
    }
}
