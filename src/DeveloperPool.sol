// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeveloperPool
/// @notice Fee and surplus routing for Walendria Protocol (Section 2.6.6, 2.7): collects the 0.5% Developer
///         Transaction Fee (forwarded automatically by Settlement.sol) and the Spectral Market's post-resolution
///         surplus (swept permissionlessly from SpectralMarket.sol, net of the 0.1% poke bounty SpectralMarket
///         pays the resolver first - see {SpectralMarket-payResolutionBounty}), and lets the developer withdraw
///         the accumulated balance to a recipient address they may update at any time.
/// @dev `receive()` accepts both revenue sources with no special-casing - a plain, calldata-less transfer is all
///      Settlement.pay (`developerFeeRecipient.call`) and SpectralMarket.sweepSurplus (`developerPool.call`) ever
///      do, and this contract needs no confirmation of *why* value arrived, only that it did.
///
///      Section 2.8: "The only parameter the developer may update post-deployment is the Developer Pool
///      withdrawal address." This is modeled precisely, and it is the single mutable value in the entire protocol:
///      `developer` (the privileged caller) is immutable, fixed forever at construction; `withdrawalRecipient`
///      (where {withdraw} sends funds) is updatable only by `developer`. Every other parameter across every
///      contract is fixed permanently at deployment.
///
///      This contract holds no share position and pulls from no other contract: the Protocol Liquidity Buffer
///      (a prior revision's $5 depth top-up, which was the only path by which this pool ever acquired Spectral
///      Market shares or lent capital out) has been retired, so the associated `pullLiquidityBuffer`/
///      `redeemFromMarket`/controller machinery is gone. It is now purely a revenue sink plus a withdrawal.
contract DeveloperPool is ReentrancyGuard {
    address public immutable developer;
    address public withdrawalRecipient;

    event Received(address indexed from, uint256 amount);
    event WithdrawalRecipientUpdated(address indexed newRecipient);
    event Withdrawn(address indexed recipient, uint256 amount);

    error ZeroAddress();
    error NotDeveloper(address caller);
    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed(address to, uint256 amount);

    /// @param _developer The immutable privileged address (Section 2.8) - never updatable, unlike its recipient.
    /// @param _withdrawalRecipient See {withdrawalRecipient}.
    constructor(address _developer, address _withdrawalRecipient) {
        if (_developer == address(0) || _withdrawalRecipient == address(0)) revert ZeroAddress();
        developer = _developer;
        withdrawalRecipient = _withdrawalRecipient;
    }

    modifier onlyDeveloper() {
        if (msg.sender != developer) revert NotDeveloper(msg.sender);
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

    /// @notice Accepts the Developer Fee (Settlement.sol) and resolution surplus (SpectralMarket.sol) - both
    ///         arrive as plain transfers with no calldata, so no dispatch logic is needed here.
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}
