// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SharedIB
/// @notice Shared Integrity Bond pool for Walendria Protocol "The 27" (Section 2.2): external depositors stake
///         native currency into a common pool and receive ERC20 pool shares representing their proportional
///         claim; sellers who cannot afford a full direct bond rent locked-capital backing from the pool instead.
/// @dev Phase 2 of the build strategy, built and tested standalone like IntegrityBond.sol - no notion of
///      "listing" or "dispute" lives here, only the pool/lock/slash accounting primitives that ListingManager.sol
///      and DisputeManager.sol (later phases) will orchestrate as authorized `controller`s.
///
///      Design choices carried over from IntegrityBond.sol for consistency: `controller`s are a fixed allowlist
///      set once at construction (Section 2.8 immutability), and `slash` credits a pull-payment ledger rather
///      than pushing funds directly, since the recipient is chosen by the controller rather than by themselves.
///
///      Per-seller accounting is intentionally a single `locked` figure against the shared pool, not a separate
///      pre-reserved "rental allocation" layer - a seller's rented capacity *is* whatever the controller
///      currently has locked for them. Whether a given lock() call is allowed to succeed at all (i.e. whether a
///      seller is in good standing / has paid their rental fee) is a decision for the calling contract, not this
///      one; this contract only guarantees that no lock can ever exceed the pool's actual free capital.
///
///      Withdrawals draw only against `totalPooled - totalLocked` - depositor capital backing any seller's
///      active listing is non-withdrawable until that listing closes or its dispute resolves, under the exact
///      same rule as direct IB (Section 2.1), with no exception and no priority-withdrawal path (Section 2.2).
///
///      `totalPooled` is explicit internal state, incremented only by {deposit} and {payFee} and decremented
///      only by {withdraw} and {slash} - it is never derived from `address(this).balance`. This structurally
///      closes the classic ERC4626 "donate directly to the vault to manipulate share price" inflation attack:
///      sending native currency to this contract other than through {deposit}/{payFee} cannot happen at all,
///      since no `receive`/`fallback` is defined.
contract SharedIB is ERC20, ReentrancyGuard {
    /// @dev Dust guard: the first deposit sets the pool's share:asset ratio, so requiring a non-trivial minimum
    ///      avoids degenerate rounding at genesis. Does not by itself defend against the donation-based
    ///      inflation attack - that is structurally closed by tracking `totalPooled` as explicit state (see
    ///      contract-level dev note), not by this constant.
    uint256 public constant MIN_FIRST_DEPOSIT = 1e6;

    mapping(address controller => bool) public isController;

    uint256 public totalPooled;
    uint256 public totalLocked;
    mapping(address seller => uint256) public lockedBySeller;
    mapping(address recipient => uint256) public claimable;

    event Deposited(address indexed depositor, uint256 amount, uint256 shares);
    event Withdrawn(address indexed depositor, uint256 amount, uint256 shares);
    event FeePaid(address indexed payer, address indexed seller, uint256 amount);
    event Locked(address indexed seller, uint256 amount);
    event Unlocked(address indexed seller, uint256 amount);
    event Slashed(address indexed seller, uint256 amount, address indexed recipient);
    event Claimed(address indexed recipient, uint256 amount);

    error NoControllers();
    error NotController(address caller);
    error ZeroAmount();
    error ZeroShares();
    error BelowMinimumFirstDeposit(uint256 sent, uint256 minimum);
    error PoolInsolvent();
    error InsufficientFreePool(uint256 requested, uint256 free);
    error InsufficientLockedForSeller(address seller, uint256 requested, uint256 locked);
    error NothingToClaim(address claimant);
    error TransferFailed(address to, uint256 amount);

    /// @param controllers Addresses authorized to call lock/unlock/slash (e.g. ListingManager, DisputeManager).
    ///        Fixed for the lifetime of this contract; there is no way to add or remove one later.
    constructor(address[] memory controllers, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        if (controllers.length == 0) revert NoControllers();
        for (uint256 i = 0; i < controllers.length; i++) {
            isController[controllers[i]] = true;
        }
    }

    modifier onlyController() {
        if (!isController[msg.sender]) revert NotController(msg.sender);
        _;
    }

    /// @notice Deposits native currency into the pool, minting shares proportional to the pool's current value
    ///         (Section 2.2: "Depositors receive pool tokens representing their proportional share").
    function deposit() external payable nonReentrant returns (uint256 shares) {
        if (msg.value == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        if (supply == 0) {
            if (msg.value < MIN_FIRST_DEPOSIT) revert BelowMinimumFirstDeposit(msg.value, MIN_FIRST_DEPOSIT);
            shares = msg.value;
        } else {
            if (totalPooled == 0) revert PoolInsolvent();
            shares = Math.mulDiv(msg.value, supply, totalPooled);
            if (shares == 0) revert ZeroShares();
        }
        totalPooled += msg.value;
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, msg.value, shares);
    }

    /// @notice Burns `shares` for a proportional cut of the pool's *free* (unlocked) capital only. Locked
    ///         capital backing an active listing is non-withdrawable with no exception (Section 2.2's lock
    ///         guarantee) - there is no path for a depositor to exit a locked share early to dodge a slash.
    function withdraw(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        uint256 free = totalPooled - totalLocked;
        amount = Math.mulDiv(shares, free, supply);
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, shares);
        totalPooled -= amount;
        emit Withdrawn(msg.sender, amount, shares);
        _send(msg.sender, amount);
    }

    /// @notice Pays a fee into the pool on behalf of `seller` (Section 2.2: "Sellers rent bond capacity from the
    ///         pool by paying a recurring fee to depositors"). Distribution is implicit: the fee raises
    ///         `totalPooled` without minting new shares, so every existing depositor's shares become worth
    ///         proportionally more - the same mechanism standard yield-bearing vaults use, requiring no
    ///         per-depositor claim bookkeeping. `seller` is recorded for off-chain/event traceability only; it
    ///         has no on-chain accounting effect. Cadence/enforcement of "recurring" is a business-logic concern
    ///         for a higher layer (e.g. ListingManager), not this contract - this is the payment primitive only.
    function payFee(address seller) external payable {
        if (msg.value == 0) revert ZeroAmount();
        totalPooled += msg.value;
        emit FeePaid(msg.sender, seller, msg.value);
    }

    /// @notice Locks `amount` of the pool's free capital against `seller`. Called by ListingManager when a
    ///         Shared-IB-backed listing goes live (Section 2.5).
    function lock(address seller, uint256 amount) external onlyController {
        if (amount == 0) revert ZeroAmount();
        uint256 free = totalPooled - totalLocked;
        if (amount > free) revert InsufficientFreePool(amount, free);
        lockedBySeller[seller] += amount;
        totalLocked += amount;
        emit Locked(seller, amount);
    }

    /// @notice Releases `amount` of `seller`'s locked pool capital back to the free pool.
    function unlock(address seller, uint256 amount) external onlyController {
        if (amount == 0) revert ZeroAmount();
        uint256 locked_ = lockedBySeller[seller];
        if (amount > locked_) revert InsufficientLockedForSeller(seller, amount, locked_);
        lockedBySeller[seller] = locked_ - amount;
        totalLocked -= amount;
        emit Unlocked(seller, amount);
    }

    /// @notice Irreversibly removes `amount` from `seller`'s locked pool capital and credits it to `recipient`,
    ///         claimable via {claim}. Reducing `totalPooled` here is what makes the loss proportional across
    ///         every depositor (Section 2.2: "the pool is slashed proportionally") - it drops every share's
    ///         underlying value uniformly, with no need to touch individual balances.
    function slash(address seller, uint256 amount, address recipient) external onlyController {
        if (amount == 0) revert ZeroAmount();
        uint256 locked_ = lockedBySeller[seller];
        if (amount > locked_) revert InsufficientLockedForSeller(seller, amount, locked_);
        lockedBySeller[seller] = locked_ - amount;
        totalLocked -= amount;
        totalPooled -= amount;
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

    function freePool() external view returns (uint256) {
        return totalPooled - totalLocked;
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed(to, amount);
    }
}
