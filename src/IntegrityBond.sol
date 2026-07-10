// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title IntegrityBond
/// @notice Direct Integrity Bond accounting for Walendria Protocol "The 28" (Section 2.1): sellers deposit native
///         currency as a fraud bond, a portion of which gets locked while backing an active listing or open
///         dispute (Section 2.5), and can only be removed from a seller's bond via an authorized slash.
/// @dev Phase 2 of the build strategy: this contract owns only the generic lock/unlock/slash accounting
///      primitives. It deliberately has no notion of "listing" or "dispute" — that orchestration belongs to
///      ListingManager.sol and DisputeManager.sol (later phases), which are the intended `controller`s. This
///      keeps IntegrityBond.sol buildable and testable in total isolation now, per the build strategy's explicit
///      Phase 2 scope ("no dependency on market logic").
///
///      Authorization: `controller`s are a fixed allowlist supplied once at construction and never mutable
///      afterward (no setter exists), matching Section 2.8's immutability principle — the only thing this
///      protocol permits changing post-deployment anywhere is the Developer Pool withdrawal address, and that
///      exception does not apply here.
///
///      Payment direction: deposits/withdrawals are pushed directly to/from the acting party (self-inflicted risk
///      only). A `slash`'s recipient is chosen by the controller, not by the recipient themselves, so slash
///      proceeds are credited to a pull-payment ledger (`claimable`) instead of pushed immediately — this
///      structurally prevents a recipient with a reverting/broken receive() from blocking dispute resolution,
///      which would otherwise be a real griefing vector given every party in a dispute is potentially adversarial.
contract IntegrityBond is ReentrancyGuard {
    struct Bond {
        uint256 total;
        uint256 locked;
    }

    mapping(address controller => bool) public isController;
    mapping(address seller => Bond) public bonds;
    mapping(address recipient => uint256) public claimable;

    event Deposited(address indexed seller, uint256 amount);
    event Withdrawn(address indexed seller, uint256 amount);
    event Locked(address indexed seller, uint256 amount);
    event Unlocked(address indexed seller, uint256 amount);
    event Slashed(address indexed seller, uint256 amount, address indexed recipient);
    event Claimed(address indexed recipient, uint256 amount);

    error NoControllers();
    error NotController(address caller);
    error ZeroAmount();
    error InsufficientFreeIB(address seller, uint256 requested, uint256 free);
    error InsufficientLockedIB(address seller, uint256 requested, uint256 locked);
    error NothingToClaim(address claimant);
    error TransferFailed(address to, uint256 amount);

    /// @param controllers Addresses authorized to call lock/unlock/slash (e.g. ListingManager, DisputeManager).
    ///        Fixed for the lifetime of this contract; there is no way to add or remove one later.
    constructor(address[] memory controllers) {
        if (controllers.length == 0) revert NoControllers();
        for (uint256 i = 0; i < controllers.length; i++) {
            isController[controllers[i]] = true;
        }
    }

    modifier onlyController() {
        if (!isController[msg.sender]) revert NotController(msg.sender);
        _;
    }

    /// @notice Deposits native currency into the caller's own bond (Section 2.1). Sellers are presumed honest by
    ///         default and may deposit at any time with no identity check.
    function deposit() external payable {
        if (msg.value == 0) revert ZeroAmount();
        bonds[msg.sender].total += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Withdraws up to the caller's Free IB (total minus locked). Locked capital is non-withdrawable
    ///         while backing any active listing or open transaction, with no exception (Section 2.1, 2.5).
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Bond storage b = bonds[msg.sender];
        uint256 free = b.total - b.locked;
        if (amount > free) revert InsufficientFreeIB(msg.sender, amount, free);
        b.total -= amount;
        emit Withdrawn(msg.sender, amount);
        _send(msg.sender, amount);
    }

    /// @notice Locks `amount` of `seller`'s Free IB. Called by ListingManager when a listing goes live (Section
    ///         2.5: 1.5 * P * N locked immediately, before any buyer appears).
    function lock(address seller, uint256 amount) external onlyController {
        if (amount == 0) revert ZeroAmount();
        Bond storage b = bonds[seller];
        uint256 free = b.total - b.locked;
        if (amount > free) revert InsufficientFreeIB(seller, amount, free);
        b.locked += amount;
        emit Locked(seller, amount);
    }

    /// @notice Releases `amount` of `seller`'s Locked IB back to Free IB. Called on undisputed completion-window
    ///         expiry (Section 2.5) or a correctly-resolved Seller Innocent verdict (Section 3.2).
    function unlock(address seller, uint256 amount) external onlyController {
        if (amount == 0) revert ZeroAmount();
        Bond storage b = bonds[seller];
        if (amount > b.locked) revert InsufficientLockedIB(seller, amount, b.locked);
        b.locked -= amount;
        emit Unlocked(seller, amount);
    }

    /// @notice Irreversibly removes `amount` from `seller`'s Locked IB and credits it to `recipient`, claimable
    ///         via {claim}. Used for both the 0.5P Guilty-side matching draw into the Spectral Market (Section
    ///         2.6.1) and the final 1.0P restitution slash on a Guilty verdict (Section 3.1) — both are
    ///         mechanically "move locked capital to a recipient chosen by the controller"; only the caller
    ///         (DisputeManager) knows which case it is and how much to draw.
    function slash(address seller, uint256 amount, address recipient) external onlyController {
        if (amount == 0) revert ZeroAmount();
        Bond storage b = bonds[seller];
        if (amount > b.locked) revert InsufficientLockedIB(seller, amount, b.locked);
        b.locked -= amount;
        b.total -= amount;
        claimable[recipient] += amount;
        emit Slashed(seller, amount, recipient);
    }

    /// @notice Pulls the caller's accumulated slash proceeds.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim(msg.sender);
        claimable[msg.sender] = 0;
        emit Claimed(msg.sender, amount);
        _send(msg.sender, amount);
    }

    function freeIB(address seller) external view returns (uint256) {
        Bond storage b = bonds[seller];
        return b.total - b.locked;
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed(to, amount);
    }
}
