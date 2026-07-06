// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ListingManager} from "./ListingManager.sol";

/// @title EvidenceRegistry
/// @notice On-chain content-hash commitments for Spectral Market evidence (Section 2.6.2): evidence itself lives
///         off-chain (IPFS), this contract only records the CID, who submitted it, and which transaction it
///         concerns - the "on-chain record is the hash, not the content" mechanism the whitepaper specifies,
///         verbatim. An IPFS CID *is* a content hash, so this is a direct implementation, not a workaround.
/// @dev Deliberately its own contract rather than new functions on DisputeManager: it never moves funds, so it
///      carries none of that contract's audit surface, and it depends on nothing but ListingManager's already-
///      public listing/slot getters - no redeploy of any existing, already-tested contract is needed to add it.
///      Storage is intentionally just an event, not a mapping/array - Section 2.6.2 only requires a durable,
///      tamper-evident hash record, and an event log already provides that at a fraction of the gas cost of a
///      storage write, mirroring this codebase's existing "checkpoint via event, replay off-chain" pattern
///      (SpectralMarket's Bought/Sold events, replayed by the indexer/app for price history rather than stored
///      on-chain).
contract EvidenceRegistry {
    /// @dev Gas-griefing sanity bound, not a protocol rule - a CID plus a reasonable filename/path comfortably
    ///      fits in a fraction of this. It exists only so a mistaken or malicious caller can't pay to log an
    ///      unbounded string, mirroring the gas-safety caps already used elsewhere (ListingManager.MAX_SLOTS,
    ///      DisputeManager.MAX_GUILTY_FUNDERS).
    uint256 public constant MAX_CID_LENGTH = 256;

    ListingManager public immutable listingManager;

    /// @param marketId Identical derivation to {DisputeManager-marketIdOf} - keccak256(listingId, slotIndex) -
    ///        so evidence, trades, and dispute state all join on the same key without a translation table.
    event EvidenceSubmitted(
        uint256 indexed marketId, address indexed submitter, uint256 listingId, uint256 slotIndex, string cid
    );

    error EmptyCid();
    error CidTooLong(uint256 length, uint256 maxLength);
    error NotBuyerOrSeller(uint256 listingId, uint256 slotIndex, address caller);

    constructor(ListingManager _listingManager) {
        listingManager = _listingManager;
    }

    /// @notice Commits an IPFS CID as evidence for a specific transaction (Section 2.6.2). Callable by that
    ///         slot's seller or its confirmed buyer, at any time - including before a dispute formally exists on
    ///         DisputeManager (Section 2.4: a buyer must be able to publicize a case *before* attracting the
    ///         0.5P of Guilty-side funding that creates the dispute object at all). Deliberately does not check
    ///         slot status: before payment confirmation, `buyer` reads as address(0), which msg.sender can never
    ///         equal, so only the seller can submit at that stage - exactly the outcome a status check would
    ///         have enforced explicitly, without adding a dependency on ListingManager's SlotStatus enum.
    function submitEvidence(uint256 listingId, uint256 slotIndex, string calldata cid) external {
        uint256 cidLength = bytes(cid).length;
        if (cidLength == 0) revert EmptyCid();
        if (cidLength > MAX_CID_LENGTH) revert CidTooLong(cidLength, MAX_CID_LENGTH);

        (address seller,,,,,,) = listingManager.listings(listingId);
        (,, address buyer) = listingManager.slots(listingId, slotIndex);
        if (msg.sender != seller && msg.sender != buyer) {
            revert NotBuyerOrSeller(listingId, slotIndex, msg.sender);
        }

        emit EvidenceSubmitted(marketIdOf(listingId, slotIndex), msg.sender, listingId, slotIndex, cid);
    }

    /// @notice Deterministic dispute/market identifier, identical to {DisputeManager-marketIdOf}. Kept as an
    ///         independent pure function - not a cross-contract call - so this registry has zero runtime
    ///         dependency on DisputeManager ever being deployed, upgraded, or even existing.
    function marketIdOf(uint256 listingId, uint256 slotIndex) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(listingId, slotIndex)));
    }
}
