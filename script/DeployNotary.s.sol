// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DocumentNotary} from "../src/DocumentNotary.sol";

/// @notice One-shot deployment of the DocumentNotary contract. Independent of the main protocol
///         (`script/Deploy.s.sol`) — the notary has no wiring to any other contract in this repo,
///         so mixing it into the main deploy would drag an unrelated concern into a script that
///         already carries a lot of ceremony (CREATE-nonce prediction, constructor argument
///         threading, etc.).
///
/// @dev    Broadcast with the same low-gas flags used elsewhere in the repo — see CLAUDE.md
///         "Deploying to Chiado" / "Mainnet deploy runbook" for the full explanation. The relevant
///         line for this script is:
///
///           forge script script/DeployNotary.s.sol:DeployNotary --rpc-url gnosis \
///             --account walendria-chiado --broadcast --slow \
///             --with-gas-price 1000000 --priority-gas-price 1000
///
///         Substitute `--rpc-url chiado` if you want to try it on Chiado first. The deploy is a
///         single CREATE, so `--slow` is technically redundant (nonce-scramble across pipelined
///         CREATEs is not a concern with only one tx) — kept for consistency with the main
///         deploy's conventions so a future maintainer copy-pasting from `Deploy.s.sol` doesn't
///         wonder why one script has it and the other doesn't.
contract DeployNotary is Script {
    function run() external returns (DocumentNotary notary) {
        vm.startBroadcast();
        notary = new DocumentNotary();
        vm.stopBroadcast();

        console.log("DocumentNotary deployed at:", address(notary));
    }
}
