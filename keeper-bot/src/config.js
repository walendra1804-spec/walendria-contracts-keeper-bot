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

/** How often the indexer catches up on new blocks — independent of, and normally much shorter than,
 *  the poke-check interval above, since indexing new events cheaply is not tied to the 1-hour settlement
 *  timescale the poke loop watches. */
export const INDEX_INTERVAL_MS = process.env.INDEX_INTERVAL_MS ? Number(process.env.INDEX_INTERVAL_MS) : 30 * 1000;

/** Max block range per eth_getLogs call. Public RPC providers commonly cap this (exact limit for Chiado's
 *  public endpoint unverified) — scanning in bounded chunks instead of one deployment-block-to-latest call
 *  keeps every individual request safely inside whatever that cap turns out to be. */
export const INDEX_CHUNK_SIZE = process.env.INDEX_CHUNK_SIZE ? BigInt(process.env.INDEX_CHUNK_SIZE) : 5000n;

export const HTTP_PORT = process.env.HTTP_PORT ? Number(process.env.HTTP_PORT) : 4000;

export const DEPLOYMENT_BLOCK = 22005158n;

export const ADDRESSES = {
  listingManager: "0xFC8057F684490A6152B22f291e8e7e2dC3BD2fbC",
  spectralMarket: "0x3Fb203c81EC6E1956Cfa926DC228991fcCAE7B5A",
  settlementConditions: "0x129a6A8ed5744886ec706e58B3407993dF9f5eB7",
  disputeManager: "0xf74425787Fc44984aBBd50935BadB3AB9ce4819c",
  evidenceRegistry: "0x5290fAFf0db23f46Ad6784844b4B325bAa255e57",
};

export const listingManagerAbi = parseAbi([
  "event ListingCreated(uint256 indexed listingId, address indexed seller, uint256 price, uint256 totalSlots, uint256 completionWindow, uint256 perSlotLocked)",
]);

export const spectralMarketAbi = parseAbi([
  "function markets(uint256 marketId) view returns (int256 b, int256 qGuilty, int256 qInnocent, uint256 pooled, bool open, bool resolved, uint8 winningSide)",
  "event MarketOpened(uint256 indexed marketId, uint256 b, uint256 sharesPerSide, uint256 totalPooled)",
  "event Bought(uint256 indexed marketId, uint8 indexed side, address indexed trader, uint256 shares, uint256 cost)",
  "event Sold(uint256 indexed marketId, uint8 indexed side, address indexed trader, uint256 shares, uint256 proceeds)",
]);

export const settlementConditionsAbi = parseAbi([
  "function tracking(uint256 marketId) view returns (uint256 cumulativeGuilty, uint256 cumulativeInnocent, uint256 lastCheckpointTime, bool trackedSideIsGuilty, bool trackedSideActive, bool initialized)",
  "function pokeSettlement(uint256 marketId)",
  "function CUMULATIVE_DURATION() view returns (uint256)",
  "function pokeBountyBps() view returns (uint256)",
]);

export const disputeManagerAbi = parseAbi([
  "event DisputeOpened(uint256 indexed marketId, uint256 indexed listingId, uint256 indexed slotIndex, address seller, uint256 halfPrice)",
]);

export const evidenceRegistryAbi = parseAbi([
  "event EvidenceSubmitted(uint256 indexed marketId, address indexed submitter, uint256 listingId, uint256 slotIndex, string cid)",
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
