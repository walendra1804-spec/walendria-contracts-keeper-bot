// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {ISettlementConditionsHook} from "../../src/ISettlementConditionsHook.sol";
import {DeveloperPool} from "../../src/DeveloperPool.sol";
import {DisputeManager} from "../../src/DisputeManager.sol";
import {DisputeManagerHandler} from "../handlers/DisputeManagerHandler.sol";

contract DisputeManagerInvariantTest is Test {
    IntegrityBond internal bond;
    ListingManager internal lm;
    SpectralMarket internal market;
    DisputeManager internal dm;
    DisputeManagerHandler internal handler;

    address internal settlementStandIn = makeAddr("invSettlementStandIn");
    address internal priceController = makeAddr("invPriceController");
    address[] internal sellers;
    address[] internal traders;

    function setUp() public {
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
        require(address(lm) == predictedLm, "CREATE nonce prediction drifted (lm)");

        address[] memory marketControllers = new address[](2);
        marketControllers[0] = priceController;
        marketControllers[1] = predictedDm;
        market = new SpectralMarket(marketControllers, ISettlementConditionsHook(address(0)), address(0));
        require(address(market) == predictedMarket, "CREATE nonce prediction drifted (market)");

        dm = new DisputeManager(lm, bond, market, DeveloperPool(payable(address(0))));
        require(address(dm) == predictedDm, "CREATE nonce prediction drifted (dm)");

        for (uint256 i = 0; i < 3; i++) {
            sellers.push(makeAddr(string.concat("invDmSeller", vm.toString(i))));
        }
        for (uint256 i = 0; i < 4; i++) {
            traders.push(makeAddr(string.concat("invDmTrader", vm.toString(i))));
        }

        handler = new DisputeManagerHandler(bond, lm, market, dm, settlementStandIn, priceController, sellers, traders);
        targetContract(address(handler));
    }

    /// @notice The corrected, full-lifecycle version of Phase 3's ListingManagerInvariant: a slot's fair share of
    ///         its seller's IntegrityBond.locked depends on its status. Empty and PaymentConfirmed slots still
    ///         hold the full perSlotLocked (nothing has been drawn yet). A Disputed slot holds only
    ///         perSlotLocked - price/2 (Section 2.6.1's matching draw already happened the instant it opened).
    ///         Removed holds nothing (released via window expiry, or slashed/unlocked at finalization). This must
    ///         hold across arbitrary interleavings of listing creation, funding, trading, resolution (via either
    ///         mutualClose or an external price-driven controller), and finalization.
    function invariant_IntegrityBondLockedMatchesFullLifecycleExpectation() public view {
        for (uint256 s = 0; s < handler.sellersCount(); s++) {
            address seller = handler.sellerAt(s);
            uint256 expectedLocked = 0;

            for (uint256 i = 0; i < handler.listingIdsCount(); i++) {
                uint256 listingId = handler.listingIds(i);
                (address listingSeller, uint256 price,,,, uint256 perSlotLocked,) = lm.listings(listingId);
                if (listingSeller != seller) continue;

                (ListingManager.SlotStatus status,,) = lm.slots(listingId, 0);
                if (status == ListingManager.SlotStatus.Empty || status == ListingManager.SlotStatus.PaymentConfirmed) {
                    expectedLocked += perSlotLocked;
                } else if (status == ListingManager.SlotStatus.Disputed) {
                    expectedLocked += perSlotLocked - price / 2;
                }
                // Removed contributes 0: either window-expiry-unlocked or slashed/unlocked at finalization.
            }

            (, uint256 actualLocked) = bond.bonds(seller);
            assertEq(actualLocked, expectedLocked, "IntegrityBond.locked must match the full dispute-lifecycle model");
        }
    }

    /// @notice DisputeManager must never strand funds: every wei accepted by {fundGuiltySide} either still sits
    ///         in this contract's own balance awaiting threshold-crossing (dispute not yet opened), or has
    ///         already been forwarded to SpectralMarket in the same transaction that crossed the threshold
    ///         (dispute opened) - there is no third state.
    function invariant_DisputeManagerBalanceMatchesUnopenedGuiltyFunding() public view {
        uint256 expected = 0;
        for (uint256 i = 0; i < handler.listingIdsCount(); i++) {
            uint256 listingId = handler.listingIds(i);
            uint256 marketId = dm.marketIdOf(listingId, 0);
            (bool opened,) = dm.disputes(marketId);
            if (!opened) {
                expected += dm.guiltyFundingTotal(marketId);
            }
        }
        assertEq(address(dm).balance, expected);
    }
}
