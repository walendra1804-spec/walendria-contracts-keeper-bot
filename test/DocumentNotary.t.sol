// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DocumentNotary} from "../src/DocumentNotary.sol";

/// @notice DocumentNotary is a one-function stateless contract; the test surface is proportional.
///         What matters is that (a) every call emits exactly one event with the correct fields,
///         (b) permissionless calls from different submitters are independent priority chains,
///         (c) idempotent re-notarization appends rather than overwrites, and (d) edge-value
///         inputs (empty strings, bytes32(0)) don't revert.
contract DocumentNotaryTest is Test {
    DocumentNotary internal notary;

    address internal panca = makeAddr("panca-walendra-deployer");
    address internal someoneElse = makeAddr("someone-else");

    /// @dev Duplicated locally instead of imported so the test file has no coupling to the
    ///      contract's declared event beyond the abi signature — a rename in the contract would
    ///      still surface here as a mismatched-signature failure, which is what we want.
    event Notarized(bytes32 indexed contentHash, address indexed submitter, uint64 timestamp, string title, string uri);

    function setUp() public {
        notary = new DocumentNotary();
    }

    // ── happy path ──

    function test_Notarize_EmitsSingleEventWithCorrectFields() public {
        bytes32 hash = keccak256("the-apparatus-was-not-the-point.tsx@rev1");
        string memory title = "The Apparatus Was Not the Point";
        string memory uri = "https://walendria.org/articles/the-apparatus-was-not-the-point";
        vm.warp(1_752_672_000); // deterministic timestamp for the assertion

        vm.expectEmit(true, true, false, true, address(notary));
        emit Notarized(hash, panca, uint64(block.timestamp), title, uri);

        vm.prank(panca);
        notary.notarize(hash, title, uri);
    }

    function test_Notarize_TimestampMatchesBlockTimestamp() public {
        bytes32 hash = keccak256("doc-1");
        vm.warp(1_800_000_000);

        vm.recordLogs();
        vm.prank(panca);
        notary.notarize(hash, "doc-1", "ipfs://cid-1");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event per call");
        // event topics: [signature, contentHash, submitter]; data = (timestamp, title, uri)
        (uint64 emittedTs,,) = abi.decode(logs[0].data, (uint64, string, string));
        assertEq(uint256(emittedTs), block.timestamp, "emitted timestamp must equal block.timestamp");
    }

    // ── permissionless multi-submitter ──

    function test_Notarize_PermissionlessMultipleSubmittersSameHash() public {
        bytes32 hash = keccak256("shared-doc");
        vm.warp(1_000_000_000);

        vm.prank(panca);
        notary.notarize(hash, "shared", "ipfs://x");

        vm.warp(1_000_001_000); // one thousand seconds later
        vm.prank(someoneElse);
        notary.notarize(hash, "shared", "ipfs://x");

        // Both events exist; each submitter's earliest timestamp is their own priority record.
        // The test just proves nothing reverts and both go through — event enumeration is trivial
        // and belongs to the consumer (indexer / block explorer), not this contract.
        assertTrue(true);
    }

    function test_Notarize_SameSubmitterCanNotarizeSameHashTwice() public {
        bytes32 hash = keccak256("idempotent-doc");
        vm.warp(2_000_000_000);

        vm.prank(panca);
        notary.notarize(hash, "v1", "ipfs://x-v1");

        vm.warp(2_000_001_000);
        vm.prank(panca);
        notary.notarize(hash, "v2", "ipfs://x-v2");

        // No revert. The FIRST call at t=2_000_000_000 is the priority record; the second at
        // t=2_000_001_000 exists in the log but does not (and cannot) overwrite the first.
        assertTrue(true);
    }

    // ── edge-value inputs ──

    function test_Notarize_AcceptsZeroHash() public {
        // bytes32(0) is a valid (if useless) input — see the contract's NatSpec for the rationale
        // against adding a revert here. This test locks in that behavior so a well-meaning future
        // "let's add a require" refactor is caught by a red bar.
        vm.prank(panca);
        notary.notarize(bytes32(0), "empty", "");
        assertTrue(true);
    }

    function test_Notarize_AcceptsEmptyStrings() public {
        vm.prank(panca);
        notary.notarize(keccak256("x"), "", "");
        assertTrue(true);
    }

    function test_Notarize_AcceptsLongStrings() public {
        // Just verify no arbitrary length limit sneaks in via a future refactor.
        string memory longTitle = new string(1024);
        string memory longUri = new string(2048);
        vm.prank(panca);
        notary.notarize(keccak256("long"), longTitle, longUri);
        assertTrue(true);
    }

    // ── fuzz ──

    function testFuzz_Notarize_NeverReverts(bytes32 hash, address submitter, string calldata title, string calldata uri)
        public
    {
        vm.assume(submitter != address(0)); // vm.prank rejects address(0), unrelated to contract logic
        vm.prank(submitter);
        notary.notarize(hash, title, uri);
    }
}
