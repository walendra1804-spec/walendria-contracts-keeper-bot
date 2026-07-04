// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";
import {IntegrityBondHandler} from "../handlers/IntegrityBondHandler.sol";

contract IntegrityBondInvariantTest is Test {
    IntegrityBond internal bond;
    IntegrityBondHandler internal handler;
    address internal controller = makeAddr("invController");
    address[] internal sellers;
    address[] internal recipients;

    function setUp() public {
        address[] memory controllers = new address[](1);
        controllers[0] = controller;
        bond = new IntegrityBond(controllers);

        for (uint256 i = 0; i < 4; i++) {
            sellers.push(makeAddr(string.concat("invSeller", vm.toString(i))));
        }
        for (uint256 i = 0; i < 3; i++) {
            recipients.push(makeAddr(string.concat("invRecipient", vm.toString(i))));
        }

        handler = new IntegrityBondHandler(bond, controller, sellers, recipients);
        targetContract(address(handler));
    }

    /// @notice Total Locked IB <= Total IB, per seller, under arbitrary call sequences - the canonical invariant
    ///         named explicitly in the build strategy's testing plan.
    function invariant_LockedNeverExceedsTotalPerSeller() public view {
        for (uint256 i = 0; i < sellers.length; i++) {
            (uint256 total, uint256 locked) = bond.bonds(sellers[i]);
            assertLe(locked, total);
        }
    }

    /// @notice Solvency: the contract must always hold exactly enough ETH to cover every seller's total bond
    ///         plus every recipient's unclaimed slash proceeds - no value is ever created or lost by any
    ///         sequence of deposit/withdraw/lock/unlock/slash/claim calls.
    function invariant_ContractBalanceMatchesAccounting() public view {
        uint256 sumTotal = 0;
        for (uint256 i = 0; i < sellers.length; i++) {
            (uint256 total,) = bond.bonds(sellers[i]);
            sumTotal += total;
        }
        uint256 sumClaimable = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            sumClaimable += bond.claimable(recipients[i]);
        }
        assertEq(address(bond).balance, sumTotal + sumClaimable);
    }
}
