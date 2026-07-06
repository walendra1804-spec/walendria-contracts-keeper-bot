// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IntegrityBond} from "../src/IntegrityBond.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {Settlement} from "../src/Settlement.sol";
import {SpectralMarket} from "../src/SpectralMarket.sol";
import {ISettlementConditionsHook} from "../src/ISettlementConditionsHook.sol";
import {SettlementConditions} from "../src/SettlementConditions.sol";
import {DisputeManager} from "../src/DisputeManager.sol";
import {DeveloperPool} from "../src/DeveloperPool.sol";
import {SharedIB} from "../src/SharedIB.sol";
import {EvidenceRegistry} from "../src/EvidenceRegistry.sol";

/// @notice Phase 11 testnet deployment. Replicates Integration.t.sol's proven wiring order exactly - same
///         CREATE-nonce address prediction, same seven-contract dependency graph - so this script's correctness
///         inherits from that suite's 268 passing tests rather than being a fresh, unvalidated path.
/// @dev Deploys the current single-instance architecture, not a factory. The build strategy's confirmed factory
///      decision (Section 8 item 2) is a mainnet multi-deployment concern; Phase 11's actual goal (Section 6) is
///      running the adversarial scenario list live against a deployed contract to catch gas/call-ordering issues
///      local tests can't, which the single-instance deploy serves just as well. Revisit before Phase 13.
/// @dev DEPLOYER_ADDRESS must exactly match whichever account actually signs the broadcast (--account/
///      --private-key/--ledger). It is only used to pre-compute future CREATE addresses before any contract
///      exists; a mismatch is caught by the require() checks below rather than silently producing bad wiring.
/// @dev Split into many small internal functions deliberately - a single run() doing all eight deployments blew
///      the legacy codegen's stack depth (too many simultaneously-live locals), and bundling everything into one
///      giant struct instead would just move the problem into that struct's field count.
contract DeployScript is Script {
    struct DeployConfig {
        address deployer;
        address developer;
        address withdrawalRecipient;
        uint256 pokeBounty;
        uint256 initialBountyFunding;
    }

    struct Predicted {
        address lm;
        address spectralMarket;
        address settlement;
        address dm;
    }

    function run() external {
        DeployConfig memory cfg = _readConfig();
        Predicted memory predicted = _predictAddresses(cfg.deployer);

        vm.startBroadcast();

        (IntegrityBond bond, ListingManager lm) = _deployBondAndListing(predicted);
        DeveloperPool devPool = _deployDevPool(cfg, predicted);
        (SettlementConditions conditions, SpectralMarket market) = _deployMarket(cfg, predicted, devPool);
        (Settlement settlement, DisputeManager dm) = _deploySettlementAndDispute(predicted, lm, bond, market, devPool);
        SharedIB sharedIB = _deploySharedIB(cfg.deployer);
        EvidenceRegistry evidenceRegistry = new EvidenceRegistry(lm);

        vm.stopBroadcast();

        console.log("IntegrityBond:        ", address(bond));
        console.log("ListingManager:       ", address(lm));
        console.log("DeveloperPool:        ", address(devPool));
        console.log("SettlementConditions: ", address(conditions));
        console.log("SpectralMarket:       ", address(market));
        console.log("Settlement:           ", address(settlement));
        console.log("DisputeManager:       ", address(dm));
        console.log("SharedIB (standalone):", address(sharedIB));
        console.log("EvidenceRegistry:     ", address(evidenceRegistry));
    }

    function _readConfig() internal returns (DeployConfig memory cfg) {
        cfg.deployer = vm.envAddress("DEPLOYER_ADDRESS");
        cfg.developer = vm.envOr("DEVELOPER_ADDRESS", cfg.deployer);
        cfg.withdrawalRecipient = vm.envOr("WITHDRAWAL_RECIPIENT", cfg.deployer);
        cfg.pokeBounty = vm.envOr("POKE_BOUNTY", uint256(0.001 ether));
        cfg.initialBountyFunding = vm.envOr("INITIAL_BOUNTY_FUNDING", uint256(0.01 ether));
    }

    function _predictAddresses(address deployer) internal view returns (Predicted memory p) {
        uint256 nonce = vm.getNonce(deployer);
        p.lm = vm.computeCreateAddress(deployer, nonce + 1);
        p.spectralMarket = vm.computeCreateAddress(deployer, nonce + 4);
        p.settlement = vm.computeCreateAddress(deployer, nonce + 5);
        p.dm = vm.computeCreateAddress(deployer, nonce + 6);
    }

    function _deployBondAndListing(Predicted memory p) internal returns (IntegrityBond bond, ListingManager lm) {
        address[] memory bondControllers = new address[](2);
        bondControllers[0] = p.lm;
        bondControllers[1] = p.dm;
        bond = new IntegrityBond(bondControllers);

        address[] memory lmControllers = new address[](2);
        lmControllers[0] = p.settlement;
        lmControllers[1] = p.dm;
        lm = new ListingManager(bond, lmControllers);
        require(address(lm) == p.lm, "CREATE nonce prediction drifted (lm)");
    }

    function _deployDevPool(DeployConfig memory cfg, Predicted memory p) internal returns (DeveloperPool devPool) {
        address[] memory devPoolControllers = new address[](1);
        devPoolControllers[0] = p.dm;
        devPool = new DeveloperPool(cfg.developer, cfg.withdrawalRecipient, devPoolControllers);
    }

    function _deployMarket(DeployConfig memory cfg, Predicted memory p, DeveloperPool devPool)
        internal
        returns (SettlementConditions conditions, SpectralMarket market)
    {
        conditions = new SettlementConditions{value: cfg.initialBountyFunding}(
            SpectralMarket(p.spectralMarket), cfg.pokeBounty
        );

        address[] memory marketControllers = new address[](2);
        marketControllers[0] = p.dm;
        marketControllers[1] = address(conditions);
        market = new SpectralMarket(marketControllers, ISettlementConditionsHook(address(conditions)), address(devPool));
        require(address(market) == p.spectralMarket, "CREATE nonce prediction drifted (market)");
    }

    function _deploySettlementAndDispute(
        Predicted memory p,
        ListingManager lm,
        IntegrityBond bond,
        SpectralMarket market,
        DeveloperPool devPool
    ) internal returns (Settlement settlement, DisputeManager dm) {
        settlement = new Settlement(lm, address(devPool));
        require(address(settlement) == p.settlement, "CREATE nonce prediction drifted (settlement)");

        dm = new DisputeManager(lm, bond, market, devPool);
        require(address(dm) == p.dm, "CREATE nonce prediction drifted (dm)");
    }

    // SharedIB is deliberately standalone (see ListingManager.sol's Phase-3 scope note - no live contract calls
    // its lock/slash/unlock yet). The deployer is set as its controller purely so it can be exercised manually
    // on testnet.
    function _deploySharedIB(address deployer) internal returns (SharedIB sharedIB) {
        address[] memory sharedIBControllers = new address[](1);
        sharedIBControllers[0] = deployer;
        sharedIB = new SharedIB(sharedIBControllers, "Walendria Shared IB", "wSIB");
    }
}
