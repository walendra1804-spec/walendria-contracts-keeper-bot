# Walendria Keeper Bot

Permissionless `pokeSettlement` caller for the Spectral Market (app strategy doc, Section 3). Polls every
`POLL_INTERVAL_MS` (default 5 min), checks every dispute this deployment has ever opened, and calls
`pokeSettlement` on any market that has spent the required cumulative time above threshold — collecting
the bounty. Currently hardcoded to the live Gnosis Chiado deployment.

## Deploy to a VPS

1. Copy this whole `keeper-bot/` folder to the VPS (from your own machine, in your own terminal):

   ```
   scp -P <ssh-port> -r keeper-bot root@<vps-ip>:/root/walendria-keeper-bot
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

4. Run it persistently with `pm2` (recommended — auto-restarts on crash, survives reboots):

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

## Notes

- The bot never assumes it's the only caller — every write is `simulateContract`'d first, so if another
  keeper (or a manual "Poke settlement" click in the app) already resolved a dispute, it just skips it
  instead of erroring loudly.
- `.env` is gitignored. Never commit it.
