// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {ListingManager} from "../../src/ListingManager.sol";
import {ListingManagerHandler} from "../handlers/ListingManagerHandler.sol";

contract ListingManagerInvariantTest is Test {
    IntegrityBond internal bond;
    ListingManager internal lm;
    ListingManagerHandler internal handler;
    address internal controller = makeAddr("invController");
    address[] internal sellers;

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedLm = vm.computeCreateAddress(address(this), nonce + 1);
        // `controller` also needs direct bond access here, standing in for DisputeManager (Phase 7), which in
        // the real system calls IntegrityBond.unlock/slash directly *before* calling ListingManager.resolveDispute
        // - resolveDispute itself deliberately moves no funds (see ListingManager's dev notes).
        address[] memory bondControllers = new address[](2);
        bondControllers[0] = predictedLm;
        bondControllers[1] = controller;
        bond = new IntegrityBond(bondControllers);

        address[] memory lmControllers = new address[](1);
        lmControllers[0] = controller;
        lm = new ListingManager(bond, lmControllers);
        require(address(lm) == predictedLm, "CREATE nonce prediction drifted");

        for (uint256 i = 0; i < 3; i++) {
            sellers.push(makeAddr(string.concat("invSeller", vm.toString(i))));
        }

        handler = new ListingManagerHandler(bond, lm, controller, sellers);
        targetContract(address(handler));
    }

    /// @notice The core cross-contract invariant Phase 3 exists to guarantee: ListingManager's own view of "how
    ///         much of this seller's IB is currently spoken for" must always match what IntegrityBond actually
    ///         has locked for that seller - under arbitrary sequences of listing creation, payment confirmation,
    ///         window expiry, disputes, and reduction/closure.
    ///
    ///         Every slot is locked from the moment its listing is created until the slot is individually
    ///         Removed (via window-expiry finalization, dispute resolution, or reduce/close of a never-used
    ///         slot) - Empty, PaymentConfirmed, and Disputed all still hold their perSlotLocked share. Only
    ///         Removed means that share has actually been released.
    function invariant_ListingManagerLockedMatchesIntegrityBondLocked() public view {
        for (uint256 s = 0; s < handler.sellersCount(); s++) {
            address seller = handler.sellerAt(s);
            uint256 expectedLocked = 0;

            for (uint256 i = 0; i < handler.listingIdsCount(); i++) {
                uint256 listingId = handler.listingIds(i);
                (address listingSeller,, uint256 totalSlots,,, uint256 perSlotLocked,) = lm.listings(listingId);
                if (listingSeller != seller) continue;

                for (uint256 slotIdx = 0; slotIdx < totalSlots; slotIdx++) {
                    (ListingManager.SlotStatus status,,) = lm.slots(listingId, slotIdx);
                    if (status != ListingManager.SlotStatus.Removed) {
                        expectedLocked += perSlotLocked;
                    }
                }
            }

            (, uint256 actualLocked) = bond.bonds(seller);
            assertEq(actualLocked, expectedLocked);
        }
    }
}
