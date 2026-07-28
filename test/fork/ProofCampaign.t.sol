// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {CampaignBase} from "../../script/live/ProofCampaign.s.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";

/// @notice End-to-end rehearsal of `script/live/ProofCampaign.s.sol` against the live Gnosis mainnet
///         deployment, by inheriting the script's own `_phase1`/`_phase2` so the code exercised here is
///         literally the code that will spend real money.
///
///         A `forge script` dry run covers phase 1 and nothing more: phase 2 cannot exist until phase 1 has
///         actually landed on-chain, and it additionally needs an hour of wall-clock time to pass. That is
///         precisely the half of the campaign where things can go wrong in ways money does not come back
///         from — an unresolvable market, a dispute that finalizes but leaves the restitution unclaimed — so
///         it is the half that most needs a test. `vm.warp` on a fork gives it to us for free.
///
/// @dev Skips itself when no `gnosis` fork is reachable, so a networkless `forge test` neither fails nor
///      pretends to have verified anything.
contract ProofCampaignForkTest is Test, CampaignBase {
    bool internal forked;

    function setUp() public {
        try vm.createSelectFork("gnosis") returns (uint256) {
            forked = true;
        } catch {
            forked = false;
        }
    }

    function test_Fork_FullCampaign() public {
        if (!forked) {
            console.log("SKIP: no gnosis fork available");
            return;
        }

        // This test contract IS the campaign operator — the same single-address arrangement the script uses,
        // so seller-equals-buyer is exercised rather than assumed to be allowed.
        uint256 P = 0.00005 ether;
        vm.deal(address(this), 50 * P);
        uint256 startBalance = address(this).balance;

        (uint256 listingId, uint256 marketId, uint256 cycle) = _phase1(P, 3, address(this));

        assertEq(cycle, 4, "three honest sales then the disputed fourth, all on one recycled slot");

        (uint256 pGuilty,) = spectralMarket.currentPrice(marketId);
        assertGe(pGuilty, THRESHOLD, "phase 1 must cross the 93% threshold");

        // One bond lock backed all four sales, and opening the dispute drew the Innocent side's 0.5P
        // injection out of that same bond rather than asking the seller for fresh cash — so 1.5P deposited
        // becomes 1.0P still locked once the market is live. Pinned here because it is the reason the
        // campaign's peak capital is what it is.
        {
            (uint256 total, uint256 locked) = integrityBond.bonds(address(this));
            assertEq(locked, P, "1.5P locked, less the 0.5P injected into the Innocent side");
            assertEq(total, P, "the injected 0.5P left the bond entirely");
        }

        // The wait the script cannot avoid: 93% must hold for a cumulative hour.
        vm.warp(block.timestamp + 1 hours + 1);

        _phase2(listingId, marketId, address(this));

        {
            (,,,,, bool resolved, SpectralMarket.Side winningSide) = spectralMarket.markets(marketId);
            assertTrue(resolved, "market must be resolved");
            assertEq(uint256(winningSide), uint256(SpectralMarket.Side.Guilty), "Guilty side must win");

            (, bool finalized) = disputeManager.disputes(marketId);
            assertTrue(finalized, "dispute must be finalized");
        }

        // Nothing left stranded: the slashed bond was claimed and the winning shares redeemed.
        assertEq(integrityBond.claimable(address(this)), 0, "restitution must not be left unclaimed");
        assertEq(spectralMarket.sharesOf(marketId, SpectralMarket.Side.Guilty, address(this)), 0, "shares redeemed");

        // Everything the operator put in is either back in the wallet or withdrawable from the bond, minus
        // only the developer fee on each sale — which, for a self-operated rehearsal, lands in the operator's
        // own Developer Pool. Asserted rather than described so a future change that quietly starts eating
        // capital shows up here.
        uint256 consumed = startBalance - address(this).balance - integrityBond.freeIB(address(this));
        console.log("start balance (wei)      :", startBalance);
        console.log("end balance   (wei)      :", address(this).balance);
        console.log("free IB recoverable (wei):", integrityBond.freeIB(address(this)));
        console.log("net consumed  (wei)      :", consumed);
        assertLt(consumed, P / 2, "a self-operated campaign must not consume meaningful capital");
    }

    receive() external payable {}
}
