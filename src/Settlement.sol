// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ListingManager} from "./ListingManager.sol";

/// @title Settlement
/// @notice Atomic buyer payment for Walendria Protocol "The 27" (Section 2.3): a buyer pays into this contract,
///         not directly to the seller, and in one call the contract verifies the amount received is at least
///         the listing's price, refunds any excess, deducts the 0.5% Developer Fee, forwards the remainder to
///         the seller, and confirms the slot with ListingManager - which starts its completion window and makes
///         the transaction dispute-eligible (Section 2.5). All five effects happen together or none do.
/// @dev Phase 4 of the build strategy. Payment direction is push, not pull, deliberately unlike IntegrityBond's
///      slash proceeds: Section 2.3 specifies "no holding period between confirmation and payout", which a
///      pull-payment ledger would itself introduce. A recipient (buyer, seller, or the fee recipient) that
///      cannot receive native currency simply reverts its own `pay` call - self-inflicted for the buyer/seller
///      involved, not a griefing vector against any other party's listings or slots.
///
///      `developerFeeRecipient` stands in for DeveloperPool.sol (Section 2.6.6, 2.7), which Phase 8 wires in;
///      it is deployer-set and immutable here rather than updatable, matching every other cross-contract address
///      in this codebase so far.
contract Settlement is ReentrancyGuard {
    /// @notice 0.5% Developer Fee (Section 2.3 effect 3, Section 2.7), expressed in basis points.
    uint256 public constant DEVELOPER_FEE_BPS = 50;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    ListingManager public immutable listingManager;
    address public immutable developerFeeRecipient;

    event Settled(
        uint256 indexed listingId,
        uint256 indexed slotIndex,
        address indexed buyer,
        uint256 price,
        uint256 fee,
        uint256 excessRefunded
    );

    error ZeroAddress();
    error InsufficientPayment(uint256 sent, uint256 required);
    error PriceExceedsCap(uint256 price, uint256 cap);
    error RefundFailed(address buyer, uint256 amount);
    error FeeTransferFailed(address recipient, uint256 amount);
    error ProceedsTransferFailed(address seller, uint256 amount);

    /// @param _listingManager The ListingManager this Settlement confirms payments against. This Settlement must
    ///        separately be registered as a controller on that contract (for {ListingManager-confirmPayment}).
    /// @param _developerFeeRecipient Destination for the 0.5% Developer Fee on every sale. Immutable: unlike a
    ///        permission check, a zero address here would silently burn fee proceeds forever rather than revert,
    ///        so it is rejected up front instead of left to the same "trust the deployer" convention as elsewhere.
    constructor(ListingManager _listingManager, address _developerFeeRecipient) {
        if (_developerFeeRecipient == address(0)) revert ZeroAddress();
        listingManager = _listingManager;
        developerFeeRecipient = _developerFeeRecipient;
    }

    /// @notice Pays for `slotIndex` of `listingId`. Reverts the entire call if `msg.value` is less than the
    ///         listing's price (effect 1) - otherwise refunds any excess to the caller (effect 2), deducts the
    ///         0.5% Developer Fee (effect 3), forwards the remainder to the seller (effect 4), and confirms the
    ///         slot with ListingManager, starting its completion window (effect 5). Fee and proceeds are split
    ///         from `price` directly (`price - fee`), so the two always sum to exactly `price` regardless of
    ///         rounding - no wei is ever stranded in this contract.
    ///
    ///         Slot/listing validity (existence, not closed, index in range, status == Empty) is enforced by
    ///         {ListingManager-confirmPayment} itself, which this call reaches before any value leaves the
    ///         contract - an invalid target reverts here with zero funds transferred, same as any other failure.
    function pay(uint256 listingId, uint256 slotIndex) external payable nonReentrant {
        (address seller, uint256 price,,,,,) = listingManager.listings(listingId);
        if (msg.value < price) revert InsufficientPayment(msg.value, price);

        // Defensive re-check of the immutable per-transaction hardcap (whitepaper Section 9). ListingManager
        // already rejects any listing whose price exceeds the cap at creation, so this can only ever fire if
        // that invariant were violated upstream - a belt-and-suspenders bound in the payment path itself, failing
        // closed before any value moves.
        uint256 cap = listingManager.maxTransactionValue();
        if (price > cap) revert PriceExceedsCap(price, cap);

        uint256 fee = (price * DEVELOPER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 proceeds = price - fee;
        uint256 excess = msg.value - price;

        listingManager.confirmPayment(listingId, slotIndex, msg.sender);

        if (excess > 0) {
            (bool refundOk,) = msg.sender.call{value: excess}("");
            if (!refundOk) revert RefundFailed(msg.sender, excess);
        }

        (bool feeOk,) = developerFeeRecipient.call{value: fee}("");
        if (!feeOk) revert FeeTransferFailed(developerFeeRecipient, fee);

        (bool proceedsOk,) = seller.call{value: proceeds}("");
        if (!proceedsOk) revert ProceedsTransferFailed(seller, proceeds);

        emit Settled(listingId, slotIndex, msg.sender, price, fee, excess);
    }
}
