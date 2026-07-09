// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SD59x18} from "prb-math/SD59x18.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";
import {ISettlementConditionsHook} from "../../src/ISettlementConditionsHook.sol";
import {SpectralMarketHandler} from "../handlers/SpectralMarketHandler.sol";

contract SpectralMarketInvariantTest is Test {
    SpectralMarket internal market;
    SpectralMarketHandler internal handler;
    address internal controller = makeAddr("invController");
    address internal seller = makeAddr("invSeller");
    address[] internal traders;

    function setUp() public {
        address[] memory controllers = new address[](1);
        controllers[0] = controller;
        market = new SpectralMarket(controllers, ISettlementConditionsHook(address(0)), address(0));

        for (uint256 i = 0; i < 4; i++) {
            traders.push(makeAddr(string.concat("invTrader", vm.toString(i))));
        }

        handler = new SpectralMarketHandler(market, controller, traders, seller);
        targetContract(address(handler));
    }

    /// @notice Before resolution, each market's total outstanding shares per side must equal the sum of every
    ///         individual participant's balance on that side - this is the accounting-integrity backbone {buy}/
    ///         {sell} depend on. After resolution, `qGuilty`/`qInnocent` freeze (Section 2.6.4 pricing has nothing
    ///         left to price once {buy}/{sell} refuse to run - see {SpectralMarket-redeem}'s dev note), so the
    ///         comparison instead accounts for what {redeem} has since paid out: the frozen winning-side total
    ///         must equal remaining individual balances plus everything already redeemed. Either way, no value
    ///         is created or destroyed relative to what the market opened and traded for.
    function invariant_OutstandingSharesMatchSumOfIndividualBalances() public view {
        uint256 marketCount = handler.marketIdsCount();
        for (uint256 m = 0; m < marketCount; m++) {
            uint256 marketId = handler.marketIds(m);
            (, SD59x18 qGuilty, SD59x18 qInnocent,,, bool resolved, SpectralMarket.Side winningSide) =
                market.markets(marketId);

            uint256 sumGuilty;
            uint256 sumInnocent;
            uint256 participantCount = handler.participantsCount(marketId);
            for (uint256 p = 0; p < participantCount; p++) {
                address participant = handler.participantsOf(marketId, p);
                sumGuilty += market.sharesOf(marketId, SpectralMarket.Side.Guilty, participant);
                sumInnocent += market.sharesOf(marketId, SpectralMarket.Side.Innocent, participant);
            }

            if (!resolved) {
                assertEq(uint256(SD59x18.unwrap(qGuilty)), sumGuilty, "qGuilty must match sum of individual balances");
                assertEq(
                    uint256(SD59x18.unwrap(qInnocent)), sumInnocent, "qInnocent must match sum of individual balances"
                );
            } else if (winningSide == SpectralMarket.Side.Guilty) {
                assertEq(uint256(SD59x18.unwrap(qGuilty)), sumGuilty + handler.redeemedGuilty(marketId));
            } else {
                assertEq(uint256(SD59x18.unwrap(qInnocent)), sumInnocent + handler.redeemedInnocent(marketId));
            }
        }
    }

    /// @notice The "liquidity locked" property (Section 2.6.1): the initial joint-injection positions can never
    ///         be sold, so before resolution every holder's balance stays at or above their locked floor, and
    ///         each side's total outstanding shares stay at or above the sum of all locked positions on that
    ///         side - the opening 1P-per-side depth is always still in the pool. Were {sell} ever to let an
    ///         opening funder dispose of even part of their forced position (the exploit this guards), one of
    ///         these would break. After resolution the lock stops mattering ({redeem} pays out locked and
    ///         unlocked winning shares alike), so this is only asserted while the market is live.
    function invariant_LockedInitialPositionsNeverLeaveThePool() public view {
        uint256 marketCount = handler.marketIdsCount();
        for (uint256 m = 0; m < marketCount; m++) {
            uint256 marketId = handler.marketIds(m);
            (, SD59x18 qGuilty, SD59x18 qInnocent,,, bool resolved,) = market.markets(marketId);
            if (resolved) continue;

            uint256 lockedGuilty;
            uint256 lockedInnocent;
            uint256 participantCount = handler.participantsCount(marketId);
            for (uint256 p = 0; p < participantCount; p++) {
                address participant = handler.participantsOf(marketId, p);
                uint256 heldGuilty = market.sharesOf(marketId, SpectralMarket.Side.Guilty, participant);
                uint256 lockG = market.lockedShares(marketId, SpectralMarket.Side.Guilty, participant);
                uint256 heldInnocent = market.sharesOf(marketId, SpectralMarket.Side.Innocent, participant);
                uint256 lockI = market.lockedShares(marketId, SpectralMarket.Side.Innocent, participant);
                assertGe(heldGuilty, lockG, "a holder can never sell below their locked Guilty floor");
                assertGe(heldInnocent, lockI, "a holder can never sell below their locked Innocent floor");
                lockedGuilty += lockG;
                lockedInnocent += lockI;
            }

            assertGe(uint256(SD59x18.unwrap(qGuilty)), lockedGuilty, "qGuilty must never drop below locked liquidity");
            assertGe(
                uint256(SD59x18.unwrap(qInnocent)), lockedInnocent, "qInnocent must never drop below locked liquidity"
            );
        }
    }

    /// @notice The contract must always hold at least as much native currency as it is tracked as owing across
    ///         every market's `pooled` accounting - the same solvency-register-vs-actual-balance property
    ///         SharedIB's `totalPooled` guards against, extended to a contract that pools funds per-market rather
    ///         than globally.
    function invariant_ContractBalanceCoversAggregatePooled() public view {
        uint256 marketCount = handler.marketIdsCount();
        uint256 totalPooled;
        for (uint256 m = 0; m < marketCount; m++) {
            uint256 marketId = handler.marketIds(m);
            (,,, uint256 pooled,,,) = market.markets(marketId);
            totalPooled += pooled;
        }
        assertGe(address(market).balance, totalPooled);
    }
}
