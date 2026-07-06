// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {EvidenceRegistry} from "../src/EvidenceRegistry.sol";

/// @notice Standalone deployment for EvidenceRegistry against an *already-live* deployment - unlike Deploy.s.sol
///         (which stands up the whole eight-contract graph from scratch), this only ever needs to exist once
///         per already-deployed ListingManager, so it takes that address as input rather than redeploying
///         anything else. Run this against the current Chiado deployment; Deploy.s.sol's own copy of this same
///         `new EvidenceRegistry(lm)` line covers any future from-scratch redeploy (e.g. mainnet).
contract DeployEvidenceRegistryScript is Script {
    function run() external {
        address listingManagerAddress = vm.envAddress("LISTING_MANAGER_ADDRESS");

        vm.startBroadcast();
        EvidenceRegistry registry = new EvidenceRegistry(ListingManager(listingManagerAddress));
        vm.stopBroadcast();

        console.log("ListingManager (existing):", listingManagerAddress);
        console.log("EvidenceRegistry (new):   ", address(registry));
    }
}
