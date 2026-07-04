// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeveloperPool
/// @notice Fee and surplus routing for Walendria Protocol "The 27" (Section 2.6.6, 2.6.7, 2.7): collects the 0.5%
///         Developer Transaction Fee (forwarded automatically by Settlement.sol) and the Spectral Market's
///         resolution surplus (swept permissionlessly from SpectralMarket.sol), funds the Section 2.6.7 Protocol
///         Liquidity Buffer top-up on small-P disputes via a controller-gated pull, and lets the developer
///         withdraw accumulated balance to a recipient address they may update at any time.
/// @dev Phase 8 of the build strategy. `receive()` accepts both revenue sources with no special-casing - a plain,
///      calldata-less transfer is all Settlement.pay (`developerFeeRecipient.call`) and SpectralMarket.sweepSurplus
///      (`developerPool.call`) ever do, and this contract needs no confirmation of *why* value arrived, only that
///      it did.
///
///      Section 2.8: "The only parameter the developer may update post-deployment is the Developer Pool
///      withdrawal address." This is modeled precisely: `developer` (the privileged caller) is immutable, fixed
///      forever at construction; `withdrawalRecipient` (where {withdraw} sends funds) is the one mutable value in
///      the entire protocol, updatable only by `developer`.
///
///      `withdraw` imposes no reserve/partition between "fee revenue" and "buffer reserve" - the whitepaper
///      describes both as uses of the same pool, not an on-chain-enforced split, and `developer` is already a
///      fully trusted role throughout this codebase (the same trust model as every other controller/deployer
///      relationship here). A developer who drains funds needed for an imminent buffer top-up is a governance/
///      trust failure, not a contract invariant this code is asked to defend against.
contract DeveloperPool is ReentrancyGuard {
    address public immutable developer;
    address public withdrawalRecipient;
    mapping(address controller => bool) public isController;

    event Received(address indexed from, uint256 amount);
    event WithdrawalRecipientUpdated(address indexed newRecipient);
    event Withdrawn(address indexed recipient, uint256 amount);
    event LiquidityBufferPulled(address indexed controller, uint256 requested, uint256 sent);

    error ZeroAddress();
    error NotDeveloper(address caller);
    error NoControllers();
    error NotController(address caller);
    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed(address to, uint256 amount);

    /// @param _developer The immutable privileged address (Section 2.8) - never updatable, unlike its recipient.
    /// @param _withdrawalRecipient See {withdrawalRecipient}.
    /// @param controllers Addresses authorized to call {pullLiquidityBuffer} (e.g. DisputeManager.sol). Fixed for
    ///        the lifetime of this contract, like every other controller allowlist in this codebase.
    constructor(address _developer, address _withdrawalRecipient, address[] memory controllers) {
        if (_developer == address(0) || _withdrawalRecipient == address(0)) revert ZeroAddress();
        if (controllers.length == 0) revert NoControllers();
        developer = _developer;
        withdrawalRecipient = _withdrawalRecipient;
        for (uint256 i = 0; i < controllers.length; i++) {
            isController[controllers[i]] = true;
        }
    }

    modifier onlyDeveloper() {
        if (msg.sender != developer) revert NotDeveloper(msg.sender);
        _;
    }

    modifier onlyController() {
        if (!isController[msg.sender]) revert NotController(msg.sender);
        _;
    }

    /// @notice Updates where {withdraw} sends funds (Section 2.7, 2.8). Does not affect any active transaction,
    ///         open dispute, or Spectral Market - purely a routing change for future withdrawals.
    function setWithdrawalRecipient(address newRecipient) external onlyDeveloper {
        if (newRecipient == address(0)) revert ZeroAddress();
        withdrawalRecipient = newRecipient;
        emit WithdrawalRecipientUpdated(newRecipient);
    }

    /// @notice Sends `amount` of this contract's balance to {withdrawalRecipient}.
    function withdraw(uint256 amount) external onlyDeveloper nonReentrant {
        if (amount > address(this).balance) revert InsufficientBalance(amount, address(this).balance);
        emit Withdrawn(withdrawalRecipient, amount);
        (bool ok,) = withdrawalRecipient.call{value: amount}("");
        if (!ok) revert TransferFailed(withdrawalRecipient, amount);
    }

    /// @notice Funds the Section 2.6.7 Protocol Liquidity Buffer top-up: sends `min(amount, available balance)`
    ///         to the calling controller (DisputeManager.sol), returning the actual amount sent. Capping rather
    ///         than reverting on an underfunded pool mirrors SettlementConditions' poke-bounty degradation - an
    ///         insufficiently-funded buffer shrinks the top-up, it never blocks a dispute from opening.
    function pullLiquidityBuffer(uint256 amount) external onlyController nonReentrant returns (uint256 sent) {
        uint256 available = address(this).balance;
        sent = amount > available ? available : amount;
        emit LiquidityBufferPulled(msg.sender, amount, sent);
        if (sent == 0) return 0;
        (bool ok,) = msg.sender.call{value: sent}("");
        if (!ok) revert TransferFailed(msg.sender, sent);
    }

    /// @notice Accepts the Developer Fee (Settlement.sol) and resolution surplus (SpectralMarket.sol) - both
    ///         arrive as plain transfers with no calldata, so no dispatch logic is needed here.
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}
