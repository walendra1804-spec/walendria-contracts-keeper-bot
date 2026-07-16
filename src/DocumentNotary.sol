// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title DocumentNotary — permissionless on-chain proof-of-existence for arbitrary documents
/// @author Panca Walendra (Walendria Protocol — "The 28")
/// @notice A single-function, stateless-except-for-events contract that anchors a document's
///         SHA-256 (or any 32-byte) hash to a block timestamp on Gnosis Chain. Anyone can call
///         `notarize`; the FIRST emitted event for a given `(contentHash, submitter)` pair is
///         the priority-claim proof, because `block.timestamp` on that transaction cannot be
///         backdated by anyone including the submitter.
///
/// @dev Design rationale (kept short so the contract stays trivially auditable — the whole point
///      of a notary is that its behavior fits in one screen):
///
///        1. No storage. All information lives in the `Notarized` event log. Explorers and
///           indexers already query events efficiently, and skipping storage keeps gas negligible
///           (~24k per notarization, of which ~21k is the base transaction cost). A mapping keyed
///           by (hash, submitter) would duplicate what the event log already holds and would
///           create the false impression that on-chain storage is "more permanent" than event
///           logs — it isn't; both are equally persistent parts of the chain history.
///
///        2. Permissionless. Anyone can notarize any hash. That is a *feature*: the value of a
///           priority claim is not "only I can put this hash on-chain," it is "the earliest
///           timestamp for this hash under this submitter address is provable and unmovable."
///           Someone else notarizing the same hash later is fine — the earlier record still wins.
///
///        3. No hash-equals-zero guard. A bytes32(0) content hash is a valid (if useless) input,
///           and adding a revert path for it costs gas on every legitimate call without preventing
///           any real footgun. Callers who accidentally submit an empty hash pay their gas and
///           get a useless event; nothing else breaks.
///
///        4. Title and URI are calldata strings emitted verbatim into the event. They exist to
///           make the event log self-describing (a reader can tell what document a hash points to
///           without needing an out-of-band lookup table) without storing anything on-chain.
///
/// @dev Verification workflow, for anyone auditing a priority claim:
///        1. Read the referenced document off IPFS / the /priority page / a Zenodo DOI.
///        2. Compute `sha256(document)` locally.
///        3. Query `Notarized` events on this contract, filter by `contentHash` = that SHA-256.
///        4. The earliest matching event's `submitter` and `timestamp` fields are the proof.
///
///      No trust in Walendria, no trust in Panca Walendra as author, no trust in any indexer or
///      block explorer is required — the chain itself is the notary.
contract DocumentNotary {
    /// @notice Emitted every time a document is notarized. Indexed on `contentHash` so anyone can
    ///         query all timestamps for a given document, and on `submitter` so anyone can query
    ///         everything a given address has ever notarized. Timestamp is emitted explicitly (in
    ///         addition to being derivable from `block.timestamp` on the tx) so a consumer reading
    ///         only the decoded event doesn't need to make a second RPC call for the block header.
    /// @param  contentHash The 32-byte hash of the document (SHA-256 recommended, but any 32-byte
    ///                     identifier is accepted — the contract does not interpret the hash's
    ///                     structure or provenance).
    /// @param  submitter   `msg.sender` at notarization time. Priority attribution is scoped per
    ///                     submitter; the earliest event for (hash, submitter) is that submitter's
    ///                     priority claim.
    /// @param  timestamp   `uint64(block.timestamp)`. Packed into 64 bits because the protocol will
    ///                     be long gone before uint64 seconds overflows (year ~584 billion).
    /// @param  title       Human-readable document name, emitted verbatim (e.g. "The Apparatus
    ///                     Was Not the Point"). Empty string is allowed.
    /// @param  uri         Where the document is available for verification — an IPFS URI (ipfs://…),
    ///                     an HTTPS URL, an arXiv/Zenodo/SSRN identifier, or any other locator.
    ///                     Emitted verbatim; the contract does not fetch, validate, or interpret it.
    event Notarized(bytes32 indexed contentHash, address indexed submitter, uint64 timestamp, string title, string uri);

    /// @notice Anchor a document's hash to this transaction's block timestamp under `msg.sender`.
    /// @dev    Emits exactly one `Notarized` event; performs no writes, no reads, no external calls.
    ///         Callable from any address. Reverts only if the transaction runs out of gas or if the
    ///         caller passes malformed calldata (which would revert at the ABI-decode layer, not
    ///         here). Idempotency is intentional: calling with the same arguments twice produces two
    ///         events with two different (later) timestamps, and the earlier of the two is the
    ///         priority record — a second notarization can never overwrite or invalidate an earlier
    ///         one, only append another log entry.
    /// @param  contentHash The 32-byte hash to anchor.
    /// @param  title       Human-readable document name; may be empty.
    /// @param  uri         Off-chain locator for the document; may be empty.
    function notarize(bytes32 contentHash, string calldata title, string calldata uri) external {
        emit Notarized(contentHash, msg.sender, uint64(block.timestamp), title, uri);
    }
}
