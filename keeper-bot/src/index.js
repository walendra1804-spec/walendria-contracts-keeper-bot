import "dotenv/config";
import { createPublicClient, createWalletClient, formatEther, getAbiItem, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  ADDRESSES,
  CHAIN,
  DEPLOYMENT_BLOCK,
  INDEX_INTERVAL_MS,
  POLL_INTERVAL_MS,
  RPC_URL,
  disputeManagerAbi,
  projectCumulative,
  settlementConditionsAbi,
  spectralMarketAbi,
} from "./config.js";
import { runIndexer } from "./indexer.js";
import { startServer } from "./server.js";

if (!process.env.PRIVATE_KEY) {
  console.error("Missing PRIVATE_KEY in .env — see .env.example. Refusing to start.");
  process.exit(1);
}

const account = privateKeyToAccount(process.env.PRIVATE_KEY);

const publicClient = createPublicClient({ chain: CHAIN, transport: http(RPC_URL) });
const walletClient = createWalletClient({ account, chain: CHAIN, transport: http(RPC_URL) });

const disputeOpenedEvent = getAbiItem({ abi: disputeManagerAbi, name: "DisputeOpened" });

function log(...args) {
  console.log(`[${new Date().toISOString()}]`, ...args);
}

async function findOpenMarketIds() {
  const logs = await publicClient.getLogs({
    address: ADDRESSES.disputeManager,
    event: disputeOpenedEvent,
    fromBlock: DEPLOYMENT_BLOCK,
    toBlock: "latest",
  });
  return logs.map((l) => l.args.marketId);
}

async function checkAndPoke(marketId, cumulativeDuration) {
  const market = await publicClient.readContract({
    address: ADDRESSES.spectralMarket,
    abi: spectralMarketAbi,
    functionName: "markets",
    args: [marketId],
  });
  const resolved = market[5];
  if (resolved) return;

  const tracking = await publicClient.readContract({
    address: ADDRESSES.settlementConditions,
    abi: settlementConditionsAbi,
    functionName: "tracking",
    args: [marketId],
  });

  const nowSeconds = Math.floor(Date.now() / 1000);
  const cumulativeSeconds = projectCumulative(tracking, nowSeconds);
  if (cumulativeSeconds < Number(cumulativeDuration)) return;

  log(`Market ${marketId} looks pokeable (${cumulativeSeconds}s >= ${cumulativeDuration}s) — simulating...`);

  try {
    const { request } = await publicClient.simulateContract({
      account,
      address: ADDRESSES.settlementConditions,
      abi: settlementConditionsAbi,
      functionName: "pokeSettlement",
      args: [marketId],
    });
    const hash = await walletClient.writeContract(request);
    log(`Sent pokeSettlement(${marketId}) — tx ${hash}, waiting for confirmation...`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    log(`Confirmed in block ${receipt.blockNumber}, status: ${receipt.status}`);
  } catch (err) {
    // Most common cause: someone else (another keeper, or a manual "Poke settlement" click in the app)
    // already resolved it between our read and our simulate — not an error worth crashing over.
    log(`Skipped market ${marketId}: ${err.shortMessage || err.message}`);
  }
}

async function tick() {
  const cumulativeDuration = await publicClient.readContract({
    address: ADDRESSES.settlementConditions,
    abi: settlementConditionsAbi,
    functionName: "CUMULATIVE_DURATION",
  });

  const marketIds = await findOpenMarketIds();
  log(`Checking ${marketIds.length} known dispute(s)...`);

  for (const marketId of marketIds) {
    try {
      await checkAndPoke(marketId, cumulativeDuration);
    } catch (err) {
      log(`Error checking market ${marketId}: ${err.message}`);
    }
  }
}

async function pokeLoop() {
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      await tick();
    } catch (err) {
      log(`Poke tick failed: ${err.message}`);
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
  }
}

async function indexLoop() {
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      await runIndexer(publicClient);
    } catch (err) {
      log(`Index tick failed: ${err.message}`);
    }
    await new Promise((resolve) => setTimeout(resolve, INDEX_INTERVAL_MS));
  }
}

async function main() {
  const balance = await publicClient.getBalance({ address: account.address });
  log(`Walendria keeper bot starting.`);
  log(`Wallet: ${account.address} (balance: ${formatEther(balance)} xDAI)`);
  log(`Chain: ${CHAIN.name} via ${RPC_URL}`);
  log(`Poke check interval: ${POLL_INTERVAL_MS / 1000}s, index interval: ${INDEX_INTERVAL_MS / 1000}s`);
  if (balance === 0n) {
    log(`WARNING: wallet balance is 0 — pokeSettlement calls will fail until it's funded with test xDAI.`);
  }

  try {
    startServer();
  } catch (err) {
    log(`HTTP server failed to start: ${err.message} — indexed data will still be written, just not servable.`);
  }

  // Both loops run concurrently and independently — a stall or crash in one (e.g. the poke loop hitting a
  // bad RPC response) never blocks the other.
  await Promise.all([pokeLoop(), indexLoop()]);
}

main();
