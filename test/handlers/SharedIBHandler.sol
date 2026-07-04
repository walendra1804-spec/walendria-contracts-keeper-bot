// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SharedIB} from "../../src/SharedIB.sol";

/// @notice Drives SharedIB through arbitrary interleavings of deposit/withdraw/payFee/lock/unlock/slash/claim
///         across fixed pools of depositors, sellers, and recipients, for Foundry's stateful invariant fuzzer.
contract SharedIBHandler is Test {
    SharedIB public pool;
    address public controller;
    address[] public depositors;
    address[] public sellers;
    address[] public recipients;

    constructor(
        SharedIB _pool,
        address _controller,
        address[] memory _depositors,
        address[] memory _sellers,
        address[] memory _recipients
    ) {
        pool = _pool;
        controller = _controller;
        depositors = _depositors;
        sellers = _sellers;
        recipients = _recipients;
        for (uint256 i = 0; i < _depositors.length; i++) {
            vm.deal(_depositors[i], type(uint128).max);
        }
    }

    function deposit(uint256 depositorSeed, uint256 amount) external {
        address d = _pick(depositors, depositorSeed);
        // Keep first-deposit-vs-insolvent edge cases reachable but not dominant: floor above MIN_FIRST_DEPOSIT.
        amount = bound(amount, pool.MIN_FIRST_DEPOSIT(), 1_000_000 ether);
        if (pool.totalSupply() > 0 && pool.totalPooled() == 0) return; // pool insolvent; skip rather than revert
        vm.deal(d, d.balance + amount);
        vm.prank(d);
        pool.deposit{value: amount}();
    }

    function withdraw(uint256 depositorSeed, uint256 sharesSeed) external {
        address d = _pick(depositors, depositorSeed);
        uint256 bal = pool.balanceOf(d);
        if (bal == 0) return;
        uint256 shares = bound(sharesSeed, 1, bal);
        vm.prank(d);
        try pool.withdraw(shares) {} catch {}
    }

    function payFee(uint256 sellerSeed, uint256 amount) external {
        address s = _pick(sellers, sellerSeed);
        amount = bound(amount, 1, 1000 ether);
        vm.deal(address(this), amount);
        pool.payFee{value: amount}(s);
    }

    function lock(uint256 sellerSeed, uint256 amount) external {
        address s = _pick(sellers, sellerSeed);
        uint256 free = pool.freePool();
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(controller);
        pool.lock(s, amount);
    }

    function unlock(uint256 sellerSeed, uint256 amount) external {
        address s = _pick(sellers, sellerSeed);
        uint256 locked_ = pool.lockedBySeller(s);
        if (locked_ == 0) return;
        amount = bound(amount, 1, locked_);
        vm.prank(controller);
        pool.unlock(s, amount);
    }

    function slash(uint256 sellerSeed, uint256 recipientSeed, uint256 amount) external {
        address s = _pick(sellers, sellerSeed);
        uint256 locked_ = pool.lockedBySeller(s);
        if (locked_ == 0) return;
        amount = bound(amount, 1, locked_);
        address r = _pick(recipients, recipientSeed);
        vm.prank(controller);
        pool.slash(s, amount, r);
    }

    function claim(uint256 recipientSeed) external {
        address r = _pick(recipients, recipientSeed);
        if (pool.claimable(r) == 0) return;
        vm.prank(r);
        pool.claim();
    }

    function depositorsCount() external view returns (uint256) {
        return depositors.length;
    }

    function depositorAt(uint256 i) external view returns (address) {
        return depositors[i];
    }

    function _pick(address[] storage list, uint256 seed) internal view returns (address) {
        return list[seed % list.length];
    }
}
