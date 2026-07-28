import { createServer } from "node:http";
import { HTTP_PORT } from "./config.js";
import {
  getListings,
  getDisputes,
  getMarketEvents,
  getEvidence,
  getMeta,
  getSettlements,
  getCompletions,
  getResolutions,
} from "./db.js";

function log(...args) {
  console.log(`[${new Date().toISOString()}] [server]`, ...args);
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) });
  res.end(payload);
}

/**
 * Minimal read-only HTTP API over the indexed SQLite data — no framework, since this only needs a
 * handful of GET routes. All data here is already public on-chain state, just served pre-indexed instead
 * of live-scanned, so no auth: nothing here can be written to, only read. Called server-to-server from
 * walendria-app's server components (lib/onchain.ts), never directly from a browser, so no CORS needed.
 */
export function startServer() {
  const server = createServer((req, res) => {
    try {
      const url = new URL(req.url, `http://localhost:${HTTP_PORT}`);

      if (req.method !== "GET") {
        return sendJson(res, 405, { error: "Method not allowed" });
      }

      if (url.pathname === "/health") {
        return sendJson(res, 200, { ok: true, lastIndexedBlock: getMeta("lastIndexedBlock", null) });
      }

      if (url.pathname === "/events/listings") {
        const seller = url.searchParams.get("seller") || undefined;
        return sendJson(res, 200, getListings(seller));
      }

      if (url.pathname === "/events/disputes") {
        return sendJson(res, 200, getDisputes());
      }

      // Single aggregate route rather than three thin ones: the public track record renders all of these
      // together on one page, and three sequential server-side fetches would triple the latency of the one
      // page whose whole job is to load fast enough that a sceptic actually reads it. `lastIndexedBlock`
      // rides along so the page can state how current the record is instead of implying it is live.
      if (url.pathname === "/events/track-record") {
        return sendJson(res, 200, {
          settlements: getSettlements(),
          completions: getCompletions(),
          resolutions: getResolutions(),
          disputes: getDisputes(),
          lastIndexedBlock: getMeta("lastIndexedBlock", null),
        });
      }

      const marketTradesMatch = url.pathname.match(/^\/events\/market\/(\d+)\/trades$/);
      if (marketTradesMatch) {
        return sendJson(res, 200, getMarketEvents(marketTradesMatch[1]));
      }

      const marketEvidenceMatch = url.pathname.match(/^\/events\/market\/(\d+)\/evidence$/);
      if (marketEvidenceMatch) {
        return sendJson(res, 200, getEvidence(marketEvidenceMatch[1]));
      }

      sendJson(res, 404, { error: "Not found" });
    } catch (err) {
      log(`Request error: ${err.message}`);
      sendJson(res, 500, { error: "Internal error" });
    }
  });

  server.listen(HTTP_PORT, () => {
    log(`Listening on port ${HTTP_PORT}`);
  });

  return server;
}
