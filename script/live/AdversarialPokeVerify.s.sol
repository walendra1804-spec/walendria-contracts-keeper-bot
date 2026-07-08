// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {SettlementConditions} from "../../src/SettlementConditions.sol";

/// @notice Phase 11 live pass, fifth batch (build strategy Section 4), part 2 of 2: proves {pokeSettlement}
///         (Section 2.6.8 point 3) resolves a dispute using only accumulated real time - zero further trades
///         occurred on this market since {AdversarialPokeSetup.s.sol} pushed it to ~99.9999% Guilty roughly 65+
///         real minutes ago. Called by an unrelated, freshly-derived third-party wallet (never buyer, seller, or
///         a funder of this dispute) to also prove the call is genuinely permissionless, not just theoretically so.
/// @dev MARKET_ID must be copied from AdversarialPokeSetup.s.sol's console output before running this script.
contract AdversarialPokeVerifyScript is Script {
    SpectralMarket internal constant spectralMarket = SpectralMarket(0x9bf0C2E07Af4b8e5C857593867dA3a6b00062b7b);
    SettlementConditions internal constant settlementConditions =
        SettlementConditions(0x3a1da6BD7a8fa38B0b6b798eA25d25f7C6475f18);

    uint256 internal constant MARKET_ID = 22756765779589845761170775236260874230900367805402455632653690919156678150133;

    function run() external {
        (address poker, uint256 pokerKey) = makeAddrAndKey("adversarial-live-poker");
        console.log("poker:", poker);

        vm.startBroadcast();
        (bool ok,) = poker.call{value: 5_000_000_000_000}("");
        require(ok, "funding poker failed");
        vm.stopBroadcast();

        (,,,, bool openBefore, bool resolvedBefore,) = spectralMarket.markets(MARKET_ID);
        require(openBefore, "market not open - wrong MARKET_ID?");
        require(!resolvedBefore, "market already resolved - wrong MARKET_ID, or someone else already poked it");

        vm.startBroadcast(pokerKey);
        settlementConditions.pokeSettlement(MARKET_ID);
        vm.stopBroadcast();

        (,,,,, bool resolvedAfter, SpectralMarket.Side winningSide) = spectralMarket.markets(MARKET_ID);
        require(resolvedAfter, "VIOLATION: pokeSettlement did not resolve the market");
        require(uint256(winningSide) == uint256(SpectralMarket.Side.Guilty), "resolved to the wrong side");
        console.log("CONFIRMED LIVE: an arbitrary third party's pokeSettlement call resolved the dispute to Guilty");
        console.log("using only accumulated real time above 93%, with zero further trades in between.");
    }
}
