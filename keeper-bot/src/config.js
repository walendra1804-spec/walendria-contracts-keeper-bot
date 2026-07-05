import { parseAbi } from "viem";
import { gnosisChiado } from "viem/chains";

/**
 * Mirrors walendria-app/src/lib/contracts.ts — same live Chiado deployment, duplicated here rather than
 * imported so this bot stays a standalone deployable unit with no dependency on the Next.js app's package
 * tree (app strategy doc Section 3: "can share a codebase... rather than being a fully separate project" is
 * an option, not a requirement — a single small file duplicated is simpler to deploy on its own to a VPS).
 */
export const CHAIN = gnosisChiado;

export const RPC_URL = process.env.RPC_URL || "https://rpc.chiadochain.net";

export const POLL_INTERVAL_MS = process.env.POLL_INTERVAL_MS
  ? Number(process.env.POLL_INTERVAL_MS)
  : 5 * 60 * 1000;

export const DEPLOYMENT_BLOCK = 21940864n;

export const ADDRESSES = {
  spectralMarket: "0xa68a83944bdd92fc066c32b69f07e1519b728857",
  settlementConditions: "0xd07b2befb8590a861f8d6c1ef8afb39c89197509",
  disputeManager: "0x75ba345b89a9653c98e38958d84359a6ce9233b6",
};

export const spectralMarketAbi = parseAbi([
  "function markets(uint256 marketId) view returns (int256 b, int256 qGuilty, int256 qInnocent, uint256 pooled, bool open, bool resolved, uint8 winningSide)",
]);

export const settlementConditionsAbi = parseAbi([
  "function tracking(uint256 marketId) view returns (uint256 cumulativeGuilty, uint256 cumulativeInnocent, uint256 lastCheckpointTime, bool trackedSideIsGuilty, bool trackedSideActive, bool initialized)",
  "function pokeSettlement(uint256 marketId)",
  "function CUMULATIVE_DURATION() view returns (uint256)",
  "function pokeBounty() view returns (uint256)",
]);

export const disputeManagerAbi = parseAbi([
  "event DisputeOpened(uint256 indexed marketId, uint256 indexed listingId, uint256 indexed slotIndex, address seller, uint256 halfPrice)",
]);

/** Same projection logic as walendria-app/src/lib/onchain.ts's projectCumulative. */
export function projectCumulative(tracking, nowSeconds) {
  const [cumulativeGuilty, cumulativeInnocent, lastCheckpointTime, trackedSideIsGuilty, trackedSideActive] =
    tracking;
  const elapsed = trackedSideActive ? Math.max(0, nowSeconds - Number(lastCheckpointTime)) : 0;
  const guiltySeconds = Number(cumulativeGuilty) + (trackedSideActive && trackedSideIsGuilty ? elapsed : 0);
  const innocentSeconds =
    Number(cumulativeInnocent) + (trackedSideActive && !trackedSideIsGuilty ? elapsed : 0);
  return Math.max(guiltySeconds, innocentSeconds);
}
