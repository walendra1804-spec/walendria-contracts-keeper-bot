// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SharedIB} from "../../src/SharedIB.sol";
import {SharedIBHandler} from "../handlers/SharedIBHandler.sol";

contract SharedIBInvariantTest is Test {
    SharedIB internal pool;
    SharedIBHandler internal handler;
    address internal controller = makeAddr("invController");
    address[] internal depositors;
    address[] internal sellers;
    address[] internal recipients;

    function setUp() public {
        address[] memory controllers = new address[](1);
        controllers[0] = controller;
        pool = new SharedIB(controllers, "Walendria Shared IB", "wSIB");

        for (uint256 i = 0; i < 3; i++) {
            depositors.push(makeAddr(string.concat("invDepositor", vm.toString(i))));
        }
        for (uint256 i = 0; i < 3; i++) {
            sellers.push(makeAddr(string.concat("invSeller", vm.toString(i))));
        }
        for (uint256 i = 0; i < 3; i++) {
            recipients.push(makeAddr(string.concat("invRecipient", vm.toString(i))));
        }

        handler = new SharedIBHandler(pool, controller, depositors, sellers, recipients);
        targetContract(address(handler));
    }

    function invariant_LockedNeverExceedsPooled() public view {
        assertLe(pool.totalLocked(), pool.totalPooled());
    }

    function invariant_SumOfPerSellerLockedMatchesTotalLocked() public view {
        uint256 sum = 0;
        for (uint256 i = 0; i < sellers.length; i++) {
            sum += pool.lockedBySeller(sellers[i]);
        }
        assertEq(sum, pool.totalLocked());
    }

    /// @notice Solvency: the contract must always hold exactly enough ETH to cover the pooled value plus every
    ///         recipient's unclaimed slash proceeds - mirrors IntegrityBond's equivalent invariant.
    function invariant_ContractBalanceMatchesAccounting() public view {
        uint256 sumClaimable = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            sumClaimable += pool.claimable(recipients[i]);
        }
        assertEq(address(pool).balance, pool.totalPooled() + sumClaimable);
    }

    function invariant_SumOfShareBalancesMatchesTotalSupply() public view {
        uint256 sum = 0;
        for (uint256 i = 0; i < depositors.length; i++) {
            sum += pool.balanceOf(depositors[i]);
        }
        assertEq(sum, pool.totalSupply());
    }
}
