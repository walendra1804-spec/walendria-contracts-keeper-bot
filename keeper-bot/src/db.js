import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DB_PATH = process.env.DB_PATH || path.join(__dirname, "..", "data.json");

/**
 * Plain JSON-file store rather than SQLite — this was tried first (better-sqlite3) but that requires a
 * native compile step (node-gyp + a C++ toolchain) that isn't guaranteed to succeed on every dev machine
 * or VPS/Node-version combination, and this data is small and simple enough (a handful of key-value maps,
 * no joins, no complex queries) that a native DB buys nothing at the current, testnet-early scale beyond
 * risk. Revisit if event volume ever grows enough that reading/rewriting the whole file each write becomes
 * the bottleneck — not expected for a long time at this deployment's actual usage.
 */
function emptyState() {
  return {
    meta: {},
    listings: {},
    disputes: {},
    marketEvents: {},
    evidence: {},
    settlements: {},
    completions: {},
    resolutions: {},
  };
}

function load() {
  if (!fs.existsSync(DB_PATH)) return emptyState();
  try {
    // Merge onto emptyState() so a data.json persisted before a new bucket (e.g. `evidence`) was
    // introduced still gets that key populated, instead of leaving it undefined for older files.
    return { ...emptyState(), ...JSON.parse(fs.readFileSync(DB_PATH, "utf8")) };
  } catch {
    return emptyState();
  }
}

const state = load();

function persist() {
  // Write to a temp file then rename (atomic on POSIX and NTFS) so a crash mid-write never corrupts the
  // real file — worst case on restart is redoing the last unpersisted batch, never a torn read.
  const tmpPath = `${DB_PATH}.tmp`;
  fs.writeFileSync(tmpPath, JSON.stringify(state));
  fs.renameSync(tmpPath, DB_PATH);
}

export function getMeta(key, fallback) {
  return key in state.meta ? state.meta[key] : fallback;
}

export function setMeta(key, value) {
  state.meta[key] = String(value);
  persist();
}

export function insertListings(records) {
  if (records.length === 0) return;
  for (const r of records) state.listings[r.listingId] = r;
  persist();
}

export function insertDisputes(records) {
  if (records.length === 0) return;
  for (const r of records) state.disputes[r.marketId] = r;
  persist();
}

export function insertMarketEvents(records) {
  if (records.length === 0) return;
  for (const r of records) {
    const key = `${r.marketId}:${r.blockNumber}:${r.logIndex}:${r.eventType}`;
    state.marketEvents[key] = r;
  }
  persist();
}

export function insertEvidence(records) {
  if (records.length === 0) return;
  for (const r of records) {
    const key = `${r.marketId}:${r.blockNumber}:${r.logIndex}`;
    state.evidence[key] = r;
  }
  persist();
}

/**
 * The three buckets below back the public track record (walendria-app /track-record). They are keyed by the
 * log's own identity (block + logIndex) rather than by listing/market id, because unlike `listings` — where a
 * later record for the same id is a legitimate overwrite — every one of these is a distinct historical fact
 * that must accumulate: one slot can be paid, completed, re-paid and disputed across several cycles, and
 * collapsing those onto one key would silently shrink the very record it exists to prove.
 */
export function insertSettlements(records) {
  if (records.length === 0) return;
  for (const r of records) state.settlements[`${r.blockNumber}:${r.logIndex}`] = r;
  persist();
}

export function insertCompletions(records) {
  if (records.length === 0) return;
  for (const r of records) state.completions[`${r.blockNumber}:${r.logIndex}`] = r;
  persist();
}

export function insertResolutions(records) {
  if (records.length === 0) return;
  for (const r of records) state.resolutions[`${r.blockNumber}:${r.logIndex}`] = r;
  persist();
}

function byBlockThenLogIndex(a, b) {
  const blockDiff = Number(BigInt(a.blockNumber) - BigInt(b.blockNumber));
  return blockDiff !== 0 ? blockDiff : a.logIndex - b.logIndex;
}

export function getSettlements() {
  return Object.values(state.settlements).sort(byBlockThenLogIndex);
}

export function getCompletions() {
  return Object.values(state.completions).sort(byBlockThenLogIndex);
}

export function getResolutions() {
  return Object.values(state.resolutions).sort(byBlockThenLogIndex);
}

export function getListings(seller) {
  const all = Object.values(state.listings);
  const filtered = seller ? all.filter((l) => l.seller.toLowerCase() === seller.toLowerCase()) : all;
  return filtered.sort((a, b) => Number(BigInt(a.listingId) - BigInt(b.listingId)));
}

export function getDisputes() {
  return Object.values(state.disputes).sort((a, b) => Number(BigInt(a.blockNumber) - BigInt(b.blockNumber)));
}

export function getMarketEvents(marketId) {
  return Object.values(state.marketEvents)
    .filter((e) => e.marketId === marketId)
    .sort((a, b) => {
      const blockDiff = Number(BigInt(a.blockNumber) - BigInt(b.blockNumber));
      return blockDiff !== 0 ? blockDiff : a.logIndex - b.logIndex;
    });
}

export function getEvidence(marketId) {
  return Object.values(state.evidence)
    .filter((e) => e.marketId === marketId)
    .sort((a, b) => {
      const blockDiff = Number(BigInt(a.blockNumber) - BigInt(b.blockNumber));
      return blockDiff !== 0 ? blockDiff : a.logIndex - b.logIndex;
    });
}
