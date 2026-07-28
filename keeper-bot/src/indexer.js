import { getAbiItem } from "viem";
import {
  ADDRESSES,
  DEPLOYMENT_BLOCK,
  INDEX_CHUNK_SIZE,
  disputeManagerAbi,
  evidenceRegistryAbi,
  listingManagerAbi,
  settlementAbi,
  spectralMarketAbi,
} from "./config.js";
import {
  getMeta,
  setMeta,
  insertListings,
  insertDisputes,
  insertMarketEvents,
  insertEvidence,
  insertSettlements,
  insertCompletions,
  insertResolutions,
} from "./db.js";

const listingCreatedEvent = getAbiItem({ abi: listingManagerAbi, name: "ListingCreated" });
const disputeOpenedEvent = getAbiItem({ abi: disputeManagerAbi, name: "DisputeOpened" });
const marketOpenedEvent = getAbiItem({ abi: spectralMarketAbi, name: "MarketOpened" });
const boughtEvent = getAbiItem({ abi: spectralMarketAbi, name: "Bought" });
const soldEvent = getAbiItem({ abi: spectralMarketAbi, name: "Sold" });
const evidenceSubmittedEvent = getAbiItem({ abi: evidenceRegistryAbi, name: "EvidenceSubmitted" });
const settledEvent = getAbiItem({ abi: settlementAbi, name: "Settled" });
const slotCompletedEvent = getAbiItem({ abi: listingManagerAbi, name: "SlotCompleted" });
const slotFinalizedEvent = getAbiItem({ abi: listingManagerAbi, name: "SlotFinalized" });
const disputeFinalizedEvent = getAbiItem({ abi: disputeManagerAbi, name: "DisputeFinalized" });

function log(...args) {
  console.log(`[${new Date().toISOString()}] [indexer]`, ...args);
}

async function indexChunk(publicClient, fromBlock, toBlock) {
  const [
    listingLogs,
    disputeLogs,
    openedLogs,
    boughtLogs,
    soldLogs,
    evidenceLogs,
    settledLogs,
    completedLogs,
    finalizedLogs,
    resolutionLogs,
  ] = await Promise.all([
    publicClient.getLogs({ address: ADDRESSES.listingManager, event: listingCreatedEvent, fromBlock, toBlock }),
    publicClient.getLogs({ address: ADDRESSES.disputeManager, event: disputeOpenedEvent, fromBlock, toBlock }),
    publicClient.getLogs({ address: ADDRESSES.spectralMarket, event: marketOpenedEvent, fromBlock, toBlock }),
    publicClient.getLogs({ address: ADDRESSES.spectralMarket, event: boughtEvent, fromBlock, toBlock }),
    publicClient.getLogs({ address: ADDRESSES.spectralMarket, event: soldEvent, fromBlock, toBlock }),
    publicClient.getLogs({
      address: ADDRESSES.evidenceRegistry,
      event: evidenceSubmittedEvent,
      fromBlock,
      toBlock,
    }),
    publicClient.getLogs({ address: ADDRESSES.settlement, event: settledEvent, fromBlock, toBlock }),
    publicClient.getLogs({ address: ADDRESSES.listingManager, event: slotCompletedEvent, fromBlock, toBlock }),
    publicClient.getLogs({ address: ADDRESSES.listingManager, event: slotFinalizedEvent, fromBlock, toBlock }),
    publicClient.getLogs({ address: ADDRESSES.disputeManager, event: disputeFinalizedEvent, fromBlock, toBlock }),
  ]);

  if (listingLogs.length > 0) {
    insertListings(
      listingLogs.map((l) => ({
        listingId: l.args.listingId.toString(),
        seller: l.args.seller,
        price: l.args.price.toString(),
        totalSlots: l.args.totalSlots.toString(),
        completionWindow: l.args.completionWindow.toString(),
        perSlotLocked: l.args.perSlotLocked.toString(),
        blockNumber: l.blockNumber.toString(),
      }))
    );
  }

  const marketLogs = [...openedLogs, ...boughtLogs, ...soldLogs];
  const trackRecordLogs = [...settledLogs, ...completedLogs, ...finalizedLogs, ...resolutionLogs];
  const blockTimestampLogs = [...marketLogs, ...evidenceLogs, ...trackRecordLogs, ...disputeLogs];
  let timestampByBlock = new Map();
  if (blockTimestampLogs.length > 0) {
    const uniqueBlocks = Array.from(new Set(blockTimestampLogs.map((l) => l.blockNumber.toString()))).map((s) =>
      BigInt(s)
    );
    const blocks = await Promise.all(uniqueBlocks.map((bn) => publicClient.getBlock({ blockNumber: bn })));
    timestampByBlock = new Map(uniqueBlocks.map((bn, i) => [bn.toString(), Number(blocks[i].timestamp)]));
  }

  // Inserted after the timestamp map is built (rather than alongside the listings above) so a dispute row
  // carries the same txHash + timestamp as every other track-record row — a dispute is the single most
  // load-bearing entry in the public record, and it would be the odd one out with no link to click.
  if (disputeLogs.length > 0) {
    insertDisputes(
      disputeLogs.map((l) => ({
        marketId: l.args.marketId.toString(),
        listingId: l.args.listingId.toString(),
        slotIndex: l.args.slotIndex.toString(),
        seller: l.args.seller,
        halfPrice: l.args.halfPrice.toString(),
        blockNumber: l.blockNumber.toString(),
        txHash: l.transactionHash,
        timestamp: timestampByBlock.get(l.blockNumber.toString()),
      }))
    );
  }

  if (marketLogs.length > 0) {
    const events = [
      ...openedLogs.map((l) => ({
        marketId: l.args.marketId.toString(),
        eventType: "opened",
        side: null,
        shares: null,
        totalPooled: l.args.totalPooled.toString(),
        blockNumber: l.blockNumber.toString(),
        logIndex: l.logIndex,
        timestamp: timestampByBlock.get(l.blockNumber.toString()),
      })),
      ...boughtLogs.map((l) => ({
        marketId: l.args.marketId.toString(),
        eventType: "bought",
        side: Number(l.args.side),
        shares: l.args.shares.toString(),
        totalPooled: null,
        blockNumber: l.blockNumber.toString(),
        logIndex: l.logIndex,
        timestamp: timestampByBlock.get(l.blockNumber.toString()),
      })),
      ...soldLogs.map((l) => ({
        marketId: l.args.marketId.toString(),
        eventType: "sold",
        side: Number(l.args.side),
        shares: l.args.shares.toString(),
        totalPooled: null,
        blockNumber: l.blockNumber.toString(),
        logIndex: l.logIndex,
        timestamp: timestampByBlock.get(l.blockNumber.toString()),
      })),
    ];
    insertMarketEvents(events);
  }

  if (evidenceLogs.length > 0) {
    insertEvidence(
      evidenceLogs.map((l) => ({
        marketId: l.args.marketId.toString(),
        submitter: l.args.submitter,
        listingId: l.args.listingId.toString(),
        slotIndex: l.args.slotIndex.toString(),
        cid: l.args.cid,
        blockNumber: l.blockNumber.toString(),
        logIndex: l.logIndex,
        timestamp: timestampByBlock.get(l.blockNumber.toString()),
      }))
    );
  }

  // Track-record events. Every record carries its own txHash: the whole point of the public record is that a
  // reader can click through to the block explorer and confirm the claim independently, so a row without a
  // verifiable transaction behind it would be exactly the kind of unfalsifiable assertion this replaces.
  if (settledLogs.length > 0) {
    insertSettlements(
      settledLogs.map((l) => ({
        listingId: l.args.listingId.toString(),
        slotIndex: l.args.slotIndex.toString(),
        buyer: l.args.buyer,
        price: l.args.price.toString(),
        fee: l.args.fee.toString(),
        blockNumber: l.blockNumber.toString(),
        logIndex: l.logIndex,
        txHash: l.transactionHash,
        timestamp: timestampByBlock.get(l.blockNumber.toString()),
      }))
    );
  }

  if (completedLogs.length > 0 || finalizedLogs.length > 0) {
    insertCompletions([
      ...completedLogs.map((l) => ({
        listingId: l.args.listingId.toString(),
        slotIndex: l.args.slotIndex.toString(),
        cycle: l.args.cycle.toString(),
        // "confirmed" = the buyer actively called confirmCompletion; "expired" = the completion window ran
        // out with no dispute. Distinct evidence, so the kind is carried rather than inferred later.
        kind: "confirmed",
        buyer: l.args.buyer,
        blockNumber: l.blockNumber.toString(),
        logIndex: l.logIndex,
        txHash: l.transactionHash,
        timestamp: timestampByBlock.get(l.blockNumber.toString()),
      })),
      ...finalizedLogs.map((l) => ({
        listingId: l.args.listingId.toString(),
        slotIndex: l.args.slotIndex.toString(),
        cycle: l.args.cycle.toString(),
        kind: "expired",
        buyer: null,
        blockNumber: l.blockNumber.toString(),
        logIndex: l.logIndex,
        txHash: l.transactionHash,
        timestamp: timestampByBlock.get(l.blockNumber.toString()),
      })),
    ]);
  }

  if (resolutionLogs.length > 0) {
    insertResolutions(
      resolutionLogs.map((l) => ({
        marketId: l.args.marketId.toString(),
        winningSide: Number(l.args.winningSide),
        remainingLocked: l.args.remainingLocked.toString(),
        blockNumber: l.blockNumber.toString(),
        logIndex: l.logIndex,
        txHash: l.transactionHash,
        timestamp: timestampByBlock.get(l.blockNumber.toString()),
      }))
    );
  }

  return {
    listings: listingLogs.length,
    disputes: disputeLogs.length,
    marketEvents: marketLogs.length,
    evidence: evidenceLogs.length,
    trackRecord: trackRecordLogs.length,
  };
}

/** Catches up from the last indexed block to the current chain head, in bounded chunks so no single
 *  eth_getLogs call risks exceeding a public RPC provider's max block-range limit. Safe to call repeatedly
 *  (idempotent — every insert is INSERT OR IGNORE keyed on the log's own identity). */
export async function runIndexer(publicClient) {
  const head = await publicClient.getBlockNumber();
  let from = BigInt(getMeta("lastIndexedBlock", (DEPLOYMENT_BLOCK - 1n).toString())) + 1n;

  if (from > head) return; // already caught up

  let totalListings = 0;
  let totalDisputes = 0;
  let totalMarketEvents = 0;
  let totalEvidence = 0;
  let totalTrackRecord = 0;

  while (from <= head) {
    const to = from + INDEX_CHUNK_SIZE - 1n > head ? head : from + INDEX_CHUNK_SIZE - 1n;
    const result = await indexChunk(publicClient, from, to);
    totalListings += result.listings;
    totalDisputes += result.disputes;
    totalMarketEvents += result.marketEvents;
    totalEvidence += result.evidence;
    totalTrackRecord += result.trackRecord;
    setMeta("lastIndexedBlock", to.toString());
    from = to + 1n;
  }

  if (totalListings || totalDisputes || totalMarketEvents || totalEvidence || totalTrackRecord) {
    log(
      `Indexed up to block ${head}: +${totalListings} listing(s), +${totalDisputes} dispute(s), +${totalMarketEvents} market event(s), +${totalEvidence} evidence submission(s), +${totalTrackRecord} track-record event(s).`
    );
  }
}
