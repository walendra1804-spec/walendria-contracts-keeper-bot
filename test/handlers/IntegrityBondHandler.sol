// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IntegrityBond} from "../../src/IntegrityBond.sol";

/// @notice Drives IntegrityBond through arbitrary interleavings of deposit/withdraw/lock/unlock/slash across a
///         fixed pool of sellers and recipients, for Foundry's stateful invariant fuzzer (Section: build
///         strategy's testing tier 3 - "must hold across arbitrary sequences of calls, not just the happy path").
contract IntegrityBondHandler is Test {
    IntegrityBond public bond;
    address public controller;
    address[] public sellers;
    address[] public recipients;

    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalSlashed;
    uint256 public ghost_totalClaimed;

    constructor(IntegrityBond _bond, address _controller, address[] memory _sellers, address[] memory _recipients) {
        bond = _bond;
        controller = _controller;
        sellers = _sellers;
        recipients = _recipients;
        for (uint256 i = 0; i < _sellers.length; i++) {
            vm.deal(_sellers[i], type(uint128).max);
        }
    }

    function deposit(uint256 sellerSeed, uint256 amount) external {
        address s = _pickSeller(sellerSeed);
        amount = bound(amount, 1, 1_000_000 ether);
        vm.deal(s, s.balance + amount);
        vm.prank(s);
        bond.deposit{value: amount}();
        ghost_totalDeposited += amount;
    }

    function withdraw(uint256 sellerSeed, uint256 amount) external {
        address s = _pickSeller(sellerSeed);
        uint256 free = bond.freeIB(s);
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(s);
        bond.withdraw(amount);
        ghost_totalWithdrawn += amount;
    }

    function lock(uint256 sellerSeed, uint256 amount) external {
        address s = _pickSeller(sellerSeed);
        uint256 free = bond.freeIB(s);
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(controller);
        bond.lock(s, amount);
    }

    function unlock(uint256 sellerSeed, uint256 amount) external {
        address s = _pickSeller(sellerSeed);
        (, uint256 locked) = bond.bonds(s);
        if (locked == 0) return;
        amount = bound(amount, 1, locked);
        vm.prank(controller);
        bond.unlock(s, amount);
    }

    function slash(uint256 sellerSeed, uint256 recipientSeed, uint256 amount) external {
        address s = _pickSeller(sellerSeed);
        (, uint256 locked) = bond.bonds(s);
        if (locked == 0) return;
        amount = bound(amount, 1, locked);
        address r = _pickRecipient(recipientSeed);
        vm.prank(controller);
        bond.slash(s, amount, r);
        ghost_totalSlashed += amount;
    }

    function claim(uint256 recipientSeed) external {
        address r = _pickRecipient(recipientSeed);
        uint256 amount = bond.claimable(r);
        if (amount == 0) return;
        vm.prank(r);
        bond.claim();
        ghost_totalClaimed += amount;
    }

    function sellersCount() external view returns (uint256) {
        return sellers.length;
    }

    function sellerAt(uint256 i) external view returns (address) {
        return sellers[i];
    }

    function _pickSeller(uint256 seed) internal view returns (address) {
        return sellers[seed % sellers.length];
    }

    function _pickRecipient(uint256 seed) internal view returns (address) {
        return recipients[seed % recipients.length];
    }
}
