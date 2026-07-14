// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {Settlement} from "../../src/Settlement.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {DisputeManager} from "../../src/DisputeManager.sol";

/// @notice End-to-end verification against a running Anvil node using the addresses from Deploy.s.sol's
///         run-latest broadcast. Runs items I43 (late-shipment courtesy) and I44 (late-dispute after
///         original deadline) as real broadcast transactions, so every state transition is observable in
///         Anvil's tx receipts.
contract StressExtendWindowE2E is Script {
    IntegrityBond constant BOND = IntegrityBond(0x5FbDB2315678afecb367f032d93F642f64180aa3);
    ListingManager constant LM = ListingManager(0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512);
    Settlement constant SETTLEMENT = Settlement(payable(0x5FC8d32690cc91D4c39d9d3abcBD16989F875707));
    SpectralMarket constant MARKET = SpectralMarket(payable(0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9));
    DisputeManager constant DM = DisputeManager(payable(0x0165878A594ca255338adfa4d48449f69242Eb8F));

    // Anvil default accounts (well-known dev keys, safe to embed for a local testnet only)
    uint256 constant SELLER_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; // account 1
    uint256 constant BUYER_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a; // account 2

    function run() external {
        address seller = vm.addr(SELLER_PK);
        address buyer = vm.addr(BUYER_PK);
        console.log("Seller:", seller);
        console.log("Buyer: ", buyer);

        // Cache balances up front — DisputeManager uses .claim() which credits push/pull
        uint256 sellerStart = seller.balance;
        uint256 buyerStart = buyer.balance;

        // ── I43: seller extends courtesy → buyer confirms early ─────────────────────────────────────────
        vm.startBroadcast(SELLER_PK);
        BOND.deposit{value: 3 ether}();
        uint256 id43 = LM.createListing(1 ether, 1, 72 hours, "", "");
        vm.stopBroadcast();

        vm.startBroadcast(BUYER_PK);
        SETTLEMENT.pay{value: 1 ether}(id43, 0);
        vm.stopBroadcast();

        vm.startBroadcast(SELLER_PK);
        LM.extendWindow(id43, 0, 72 hours + 96 hours);
        vm.stopBroadcast();

        (, uint256 dl43,,) = LM.slots(id43, 0);
        console.log("I43 deadline (extended):", dl43);

        vm.startBroadcast(BUYER_PK);
        LM.confirmCompletion(id43, 0);
        vm.stopBroadcast();

        (ListingManager.SlotStatus s43,,,) = LM.slots(id43, 0);
        require(s43 == ListingManager.SlotStatus.Empty, "I43 slot must recycle to Empty");
        require(LM.slotWindowOverride(id43, 0) == 0, "I43 override must reset");
        console.log("I43 PASS: courtesy extension + early confirm, slot recycled");

        // ── I44: seller extends past original deadline → buyer disputes late, mutualClose Guilty ────────
        vm.startBroadcast(SELLER_PK);
        BOND.deposit{value: 3 ether}();
        uint256 id44 = LM.createListing(1 ether, 1, 72 hours, "", "");
        vm.stopBroadcast();

        vm.startBroadcast(BUYER_PK);
        SETTLEMENT.pay{value: 1 ether}(id44, 0);
        vm.stopBroadcast();

        (, uint256 originalDl,,) = LM.slots(id44, 0);
        console.log("I44 original deadline:", originalDl);

        vm.startBroadcast(SELLER_PK);
        LM.extendWindow(id44, 0, 72 hours + 168 hours);
        vm.stopBroadcast();

        (, uint256 extendedDl,,) = LM.slots(id44, 0);
        console.log("I44 extended deadline:", extendedDl);
        require(extendedDl > originalDl, "I44 deadline moved forward");

        // Skip past original deadline by warping Anvil's timestamp
        vm.rpc("anvil_setNextBlockTimestamp", string.concat("[", vm.toString(originalDl + 100 hours), "]"));

        vm.startBroadcast(BUYER_PK);
        DM.fundGuiltySide{value: 0.5 ether}(id44, 0);
        vm.stopBroadcast();

        (ListingManager.SlotStatus s44,,,) = LM.slots(id44, 0);
        require(s44 == ListingManager.SlotStatus.Disputed, "I44 dispute must open past original deadline");
        console.log("I44 dispute opened past original deadline via extendWindow: PASS");

        vm.startBroadcast(BUYER_PK);
        DM.mutualClose(id44, 0, SpectralMarket.Side.Guilty);
        vm.stopBroadcast();
        vm.startBroadcast(SELLER_PK);
        DM.mutualClose(id44, 0, SpectralMarket.Side.Guilty);
        vm.stopBroadcast();

        vm.startBroadcast(BUYER_PK);
        BOND.claim();
        vm.stopBroadcast();

        uint256 buyerNet = buyer.balance - buyerStart;
        uint256 sellerNet;
        if (seller.balance >= sellerStart) {
            sellerNet = seller.balance - sellerStart;
            console.log("Seller final delta (positive):", sellerNet);
        } else {
            sellerNet = sellerStart - seller.balance;
            console.log("Seller final delta (negative):", sellerNet);
        }
        // Buyer's net position over both listings: paid 2 ETH, got 0.995 back from I43 finalize? No — I43 buyer
        // doesn't get anything back (bond doesn't refund); paid 1 ETH for I44 and got 1 ETH restitution back →
        // net over both = -2 ETH (paid) - gas, offset by 1 ETH restitution. So expect approximately -1 ETH.
        console.log("Buyer final balance delta signed (buyerStart - buyer.balance ~ 1 ether + gas):");
        console.log("  buyerStart:", buyerStart);
        console.log("  buyer.balance:", buyer.balance);

        console.log("All E2E on live Anvil: PASS");
    }
}
