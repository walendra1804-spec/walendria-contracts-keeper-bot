# Walendria Keeper Bot + Indexer

Two jobs, one process, sharing the same RPC connection (app strategy doc Sections 1, 3):

1. **Keeper.** Polls every `POLL_INTERVAL_MS` (default 5 min), checks every dispute this deployment has
   ever opened, and calls `pokeSettlement` on any market that has spent the required cumulative time above
   threshold — collecting the bounty.
2. **Indexer.** Every `INDEX_INTERVAL_MS` (default 30s), catches up on new `ListingCreated`/`DisputeOpened`/
   `MarketOpened`/`Bought`/`Sold` events into a local JSON file (`data.json`), and serves them over a small
   read-only HTTP API — replacing walendria-app's live `eth_getLogs` scan-on-every-request with a fast,
   pre-indexed read. See `src/server.js` for the routes.

Currently hardcoded to the live Gnosis Chiado deployment.

## Deploy to a VPS

1. Copy this whole `keeper-bot/` folder to the VPS (from your own machine, in your own terminal) —
   `node_modules` doesn't need to come along, `npm install` on the VPS is faster:

   ```
   rsync -avz -e "ssh -p <ssh-port>" --exclude node_modules --exclude .env --exclude data.json keeper-bot/ root@<vps-ip>:/root/walendria-keeper-bot/
   ```

2. SSH into the VPS yourself and install Node.js if it isn't already there (Node 18+):

   ```
   ssh -p <ssh-port> root@<vps-ip>
   node -v   # if this fails or shows < v18, install Node first, e.g.:
   curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
   apt-get install -y nodejs
   ```

3. Install dependencies and set up the private key:

   ```
   cd /root/walendria-keeper-bot
   npm install
   cp .env.example .env
   nano .env   # paste your bot wallet's private key after PRIVATE_KEY=, save, exit
   ```

   The wallet only needs a small amount of Chiado test xDAI for gas — get some from a Gnosis Chiado
   faucet and send it to this wallet's address (the bot prints its address on startup).

4. Run it persistently with `pm2` (recommended — auto-restarts on crash, survives reboots). If you already
   have this running from before the indexer was added, just re-copy the updated files and
   `pm2 restart walendria-keeper` — no new dependencies were added, no need to redeploy from scratch.

   ```
   npm install -g pm2
   pm2 start src/index.js --name walendria-keeper
   pm2 logs walendria-keeper       # watch it run
   pm2 save
   pm2 startup                     # follow the printed command to survive a VPS reboot
   ```

   Or without pm2, as a plain background process:

   ```
   nohup node src/index.js > keeper.log 2>&1 &
   ```

5. **If walendria-app runs somewhere else** (e.g. Vercel) and needs to reach this indexer's HTTP API, open
   `HTTP_PORT` (default 4000) in the VPS's firewall for inbound traffic, and set `INDEXER_URL` in
   walendria-app's environment to `http://<vps-ip>:4000` (or a domain/reverse proxy in front of it, if you
   set one up — a raw IP:port works fine for testnet). If `INDEXER_URL` is left unset, walendria-app falls
   back to its original direct-RPC scan automatically — nothing breaks either way.

## Notes

- The bot never assumes it's the only poke-caller — every `pokeSettlement` write is `simulateContract`'d
  first, so if another keeper (or a manual "Poke settlement" click in the app) already resolved a dispute,
  it just skips it instead of erroring loudly.
- The indexer is purely additive and read-only from the chain's perspective — it never sends a
  transaction, only reads logs and blocks. Re-indexing is idempotent (last-write-wins per event identity),
  so deleting `data.json` and letting it rebuild from `DEPLOYMENT_BLOCK` is always safe if it ever looks
  wrong.
- `.env` and `data.json` are gitignored. Never commit either.
