// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpectralMarket} from "../../src/SpectralMarket.sol";

/// @notice Drives SpectralMarket through arbitrary interleavings of openMarket/buy/sell/resolveMarket/redeem
///         across a fixed pool of traders and markets, for Foundry's stateful invariant fuzzer.
contract SpectralMarketHandler is Test {
    SpectralMarket public market;
    address public controller;
    address public seller;
    address[] public traders;

    uint256[] public marketIds;
    mapping(uint256 marketId => address[]) public participantsOf;
    mapping(uint256 marketId => uint256) public redeemedGuilty;
    mapping(uint256 marketId => uint256) public redeemedInnocent;
    uint256 internal nextMarketId;

    constructor(SpectralMarket _market, address _controller, address[] memory _traders, address _seller) {
        market = _market;
        controller = _controller;
        traders = _traders;
        seller = _seller;
        vm.deal(controller, 1_000_000 ether);
        for (uint256 i = 0; i < _traders.length; i++) {
            vm.deal(_traders[i], 1_000_000 ether);
        }
    }

    function openMarket(uint256 halfPSeed, uint256 funderSeed) external {
        uint256 halfP = bound(halfPSeed, 0.01 ether, 100 ether);
        uint256 b = halfP * 2; // matches the protocol's actual calibration (b = 1*P = 2*halfP)
        uint256 marketId = nextMarketId++;

        uint256 funderCount = (funderSeed % 2) + 1;
        address[] memory funders = new address[](funderCount);
        uint256[] memory amounts = new uint256[](funderCount);
        uint256 remaining = halfP;
        for (uint256 i = 0; i < funderCount; i++) {
            funders[i] = traders[(funderSeed + i) % traders.length];
            amounts[i] = i == funderCount - 1 ? remaining : remaining / 2;
            remaining -= amounts[i];
        }

        address[] memory innocentRecipients = new address[](1);
        innocentRecipients[0] = seller;
        uint256[] memory innocentAmounts = new uint256[](1);
        innocentAmounts[0] = halfP;

        vm.prank(controller);
        market.openMarket{value: halfP * 2}(marketId, b, funders, amounts, innocentRecipients, innocentAmounts);

        marketIds.push(marketId);
        for (uint256 i = 0; i < funderCount; i++) {
            _addParticipant(marketId, funders[i]);
        }
        _addParticipant(marketId, seller);
    }

    function buy(uint256 marketSeed, uint256 traderSeed, uint256 sideSeed, uint256 sharesSeed) external {
        uint256 marketId = _pickOpenMarket(marketSeed);
        if (marketId == type(uint256).max) return;

        address trader = traders[traderSeed % traders.length];
        SpectralMarket.Side side = sideSeed % 2 == 0 ? SpectralMarket.Side.Guilty : SpectralMarket.Side.Innocent;
        uint256 shares = bound(sharesSeed, 1e12, 0.1 ether);

        vm.prank(trader);
        // Large trades accumulated over a long invariant run can push q/b outside PRBMath's exp() domain - not a
        // contract bug (see SpectralMarket's dev notes), just outside what a single dispute-scale market would
        // realistically see. Tolerated here so the invariant keeps testing "accounting stays correct when calls
        // succeed", not "every random call sequence stays within the math library's domain".
        try market.buy{value: 1000 ether}(marketId, side, shares) {
            _addParticipant(marketId, trader);
        } catch {}
    }

    function sell(uint256 marketSeed, uint256 traderSeed, uint256 sideSeed, uint256 sharesSeed) external {
        uint256 marketId = _pickOpenMarket(marketSeed);
        if (marketId == type(uint256).max) return;

        address trader = traders[traderSeed % traders.length];
        SpectralMarket.Side side = sideSeed % 2 == 0 ? SpectralMarket.Side.Guilty : SpectralMarket.Side.Innocent;
        uint256 held = market.sharesOf(marketId, side, trader);
        if (held == 0) return;
        uint256 shares = bound(sharesSeed, 1, held);

        vm.prank(trader);
        try market.sell(marketId, side, shares, 0) {} catch {}
    }

    function resolveMarket(uint256 marketSeed, uint256 sideSeed) external {
        uint256 marketId = _pickOpenMarket(marketSeed);
        if (marketId == type(uint256).max) return;

        SpectralMarket.Side winningSide = sideSeed % 2 == 0 ? SpectralMarket.Side.Guilty : SpectralMarket.Side.Innocent;
        vm.prank(controller);
        market.resolveMarket(marketId, winningSide);
    }

    function redeem(uint256 marketSeed, uint256 traderSeed) external {
        if (marketIds.length == 0) return;
        uint256 marketId = marketIds[marketSeed % marketIds.length];
        (,,,,, bool resolved, SpectralMarket.Side winningSide) = market.markets(marketId);
        if (!resolved) return;

        address trader = traders[traderSeed % traders.length];
        // Captured *before* calling redeem(): the invariant tracks share conservation (every share is either
        // still held or has been extinguished via redeem), which is unaffected by {SpectralMarket-redeem}'s
        // payout being capped at the pool's balance - that capping is a money-ledger concern (`pooled`), not a
        // share-ledger one. Using the actual `payout` return value here would under-count redeemedGuilty/
        // redeemedInnocent by exactly any shortfall, since a capped redemption still fully extinguishes the
        // trader's shares regardless of how much native currency it actually paid out.
        uint256 shares = market.sharesOf(marketId, winningSide, trader);
        if (shares == 0) return;

        vm.prank(trader);
        try market.redeem(marketId) {
            if (winningSide == SpectralMarket.Side.Guilty) {
                redeemedGuilty[marketId] += shares;
            } else {
                redeemedInnocent[marketId] += shares;
            }
        } catch {}
    }

    function marketIdsCount() external view returns (uint256) {
        return marketIds.length;
    }

    function participantsCount(uint256 marketId) external view returns (uint256) {
        return participantsOf[marketId].length;
    }

    function _addParticipant(uint256 marketId, address participant) internal {
        address[] storage list = participantsOf[marketId];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == participant) return;
        }
        list.push(participant);
    }

    /// @dev Returns the first not-yet-resolved marketId reachable from `seed` (wrapping), or type(uint256).max.
    function _pickOpenMarket(uint256 seed) internal view returns (uint256) {
        uint256 len = marketIds.length;
        if (len == 0) return type(uint256).max;
        for (uint256 i = 0; i < len; i++) {
            uint256 candidate = marketIds[(seed + i) % len];
            (,,,,, bool resolved,) = market.markets(candidate);
            if (!resolved) return candidate;
        }
        return type(uint256).max;
    }
}
