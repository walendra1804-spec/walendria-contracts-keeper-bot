# CLAUDE.md — working in walendria-contracts

Operating guide for this repo. Read it before deploying, wiring addresses, or touching the keeper-bot.

## What this is

The Walendria Protocol ("The 28") — a trustless direct-transfer + dispute system on **Gnosis Chiado**
(testnet, chain id 10200). Nine Solidity contracts, an LMSR prediction market for dispute resolution, plus a
Node indexer that lives in `keeper-bot/`. The React/Next.js frontend is a **separate repo** at
`D:\walendria-app` (no git remote — local only).

There is no paid audit and there will not be one (user decision). The substitute is an **immutable
per-transaction hardcap** — `ListingManager.maxTransactionValue` (currently 100 xDAI) — that bounds the
blast radius of any single exploited path. Preserve it; don't propose audits or bug bounties.

## Three moving parts (and where the truth lives)

1. **Contracts** (`src/`, this repo) — deployed to Chiado. The deployment is immutable; "upgrading" means a
   fresh deploy at new addresses (Section 2.8), never an admin write.
2. **keeper-bot** (`keeper-bot/`, this repo) — indexes events + runs the poke/settlement loop. Runs on a VPS
   under pm2 as `walendria-keeper`. See "VPS sync" below — there's a critical gotcha.
3. **walendria-app** (`D:\walendria-app`, deployed to VPS at `https://walendria.org`) — Next.js frontend,
   reads **indexer-first** (INDEXER_URL = `https://indexer.walendria.org`, Cloudflare-fronted) with a
   direct-RPC fallback. Same VPS as keeper-bot, served through the same `walendria-web` cloudflared tunnel.
   Redeploy flow lives in the "walendria.org — deploying the app to the VPS" section below.

The **current live addresses + deploy block** live in exactly three places, which must always agree:
- `walendria-app/src/lib/contracts.ts` — all 9 `CONTRACT_ADDRESSES[gnosisChiado.id]` + `DEPLOYMENT_BLOCK`
- `keeper-bot/src/config.js` — `ADDRESSES` (5: listingManager, spectralMarket, settlementConditions,
  disputeManager, evidenceRegistry) + `DEPLOYMENT_BLOCK`
- `test/fork/LiveChiadoLifecycle.t.sol` — 6 constant addresses
- Canonical record of the latest deploy: `broadcast/Deploy.s.sol/10200/run-latest.json`

Never hardcode addresses in a doc or in memory — they change every redeploy; read them from the files above.

## Repo layout

- `src/*.sol` — IntegrityBond, SharedIB, ListingManager, Settlement, SpectralMarket, SettlementConditions,
  DisputeManager, DeveloperPool, EvidenceRegistry, LMSRMath (+ ISettlementConditionsHook).
- `test/*.t.sol` — per-contract unit/fuzz suites + `Integration.t.sol`. `test/invariant/` + `test/handlers/`
  are the invariant suites. `test/fork/LiveChiadoLifecycle.t.sol` pins the source to the **live on-chain
  addresses** via a fork, so a green run is direct evidence the deployed bytecode behaves as intended.
- `script/Deploy.s.sol` — the one deploy script. Wires everything via **constructor args using CREATE-nonce
  address prediction** (`_predictAddresses`): exactly 9 CREATE txs, **no post-deploy `setController` txs**.
- `PLANNED_FEATURES.md` — backlog with enough detail to implement directly; delete an entry once it ships.

## Everyday commands

```bash
forge build
forge test                 # full suite must stay green (currently 337 tests)
forge fmt src/X.sol test/X.t.sol
forge test --match-path test/fork/LiveChiadoLifecycle.t.sol -vv   # verify the LIVE deployment
```

Forge lints emit warnings (block.timestamp, unsafe-typecast) that are pre-existing and acceptable — don't
chase them unless they're in code you touched.

## Deploying to Chiado — the definitive flow

**The user runs the deploy** (interactive keystore password). Never ask for a private key or password in
chat, and never run the broadcast yourself. Hand them this command:

```bash
forge script script/Deploy.s.sol:DeployScript --rpc-url chiado --account walendria-chiado \
  --broadcast --slow --with-gas-price 1000000 --priority-gas-price 1000
```

Three hard-won rules:

1. **`--with-gas-price 1000000` = 0.001 gwei, not 0.01.** `insufficient funds for gas` is an *admission
   reservation* (`balance >= gasLimit * gasPrice` up front), not the real charge — Chiado base fee is ~0, so
   a full 9-contract deploy actually costs ~7e-9 xDAI. The deployer wallet sits near-empty; at 0.01 gwei one
   heavy contract's reservation already exceeds it. Fix is a lower gas price, **not** more funds.
2. **`--slow` is mandatory.** `rpc.chiadochain.net` is a flaky load-balanced pool; without `--slow` forge
   pipelines all 9 CREATEs, nonces desync, and it mines *the wrong contract's bytecode at the wrong address*
   (a silent scramble). `--slow` sends one tx at a time.
3. **`EvmError: CreateCollision` in simulation → `rm -rf ~/.foundry/cache/rpc/chiado`**, then retry (stale
   cached nonce).

Funds: gas is negligible, but pushing a live market past its 93% resolution threshold needs real xDAI
*stake*. The faucet that actually works is **https://drpc.org/faucet/gnosis** (most others are dead/gated).

## Post-deploy checklist (do all of this before telling the user it's done)

1. Read `broadcast/.../run-latest.json` → confirm the 9 addresses + take the **min block** as `DEPLOYMENT_BLOCK`.
2. **Bytecode check** (catches a scramble instantly): for each contract compare on-chain `cast code <addr>`
   byte length to compiled `out/<C>.sol/<C>.json` `deployedBytecode` length. All 9 must match.
3. **Spot-check** wiring + any new getter, with retries (RPC returns bogus transient `execution reverted`):
   `cast call <LM> "MIN_COMPLETION_WINDOW()(uint256)"`, `isController(...)`, `integrityBond()`, `maxTransactionValue()`,
   `DM.listingManager()`, `SM.isController(DM/SC)`. A brand-new getter returning sane values proves the new
   bytecode landed.
4. **Re-wire the three consumers** (contracts.ts, config.js, fork test) + `DEPLOYMENT_BLOCK`.
5. `forge test --match-path test/fork/LiveChiadoLifecycle.t.sol` → both scenarios pass against new bytecode.
6. App `npx tsc --noEmit` clean.
7. Commit + push this repo; commit the app repo (no remote).
8. **VPS sync** (below).

## VPS sync — the untracked-copy gotcha

pm2 does **not** run the git-tracked `keeper-bot/` subdir. `pm2 describe walendria-keeper` shows
`/root/walendria-keeper-bot/src/index.js` — the bot's `.js` files were manually copied (untracked) into the
repo root's `src/` alongside the `.sol` files. So **`git pull` alone updates `keeper-bot/src/` but the running
process keeps reading the stale root `src/config.js`** — the classic "redeploy's new addresses silently don't
take effect / app shows a ghost listing". The live DB is repo-root `data.json`, not `keeper-bot/data.json`.

Update flow (SSH details are user-supplied per session and kept out of this file):
```
cd /root/walendria-keeper-bot && git fetch origin && git reset --hard origin/master \
  && for f in config.js db.js indexer.js index.js server.js; do cp -f keeper-bot/src/$f src/$f; done \
  && rm -f data.json && pm2 restart walendria-keeper --update-env
```
Then verify **both** origin and edge: `curl localhost:4000/health` (lastIndexedBlock should climb past the
deploy block) + `curl localhost:4000/events/listings`, then `curl https://indexer.walendria.org/events/listings`.

## The app (D:\walendria-app)

- No git remote — local only, `npm run dev` for local dev. Production deploy lives on the VPS at
  `https://walendria.org` (see next section). After an address change in `contracts.ts`, tell the user to
  **restart the dev server** (`rm -rf .next && npm run dev`) — server-component module consts don't hot-swap.
- Verify app changes with `npx tsc --noEmit`, `npx eslint <files>`, and `npx next build`. Watch the
  `react-hooks/set-state-in-effect` rule: don't `setState` synchronously in a `useEffect`; effects may only
  call out to external systems / parent callbacks (the finalize-then-refetch pattern is the template).
- Most pages are `force-dynamic` server components doing on-chain/indexer reads — production must be
  `next start`, **not** a static export (would break every dynamic page).

## walendria.org — deploying the app to the VPS

Same VPS as keeper-bot (`ubuntu@ubuntu`, Ubuntu 22.04). App lives at `/root/walendria-app/`, runs under pm2
as `walendria-app` on port `4180`. Cloudflared classic tunnel `walendria-web` (id
`fd0fa331-ed8c-492b-a7b3-d4d06ecf469e`, config `/etc/cloudflared/config.yml`) routes `walendria.org` +
`www.walendria.org` → `127.0.0.1:4180`. **DNS and ingress rules are already correct — never touch the
tunnel config to swap the app version; just replace what listens on 4180.**

Port map on the VPS: `4000` = keeper-bot indexer, `4180` = walendria-app, `6080` = vnc.walendria.org.

### SSH access from the working machine

VPS provider is a Shopee reseller — **the public IP rotates roughly monthly** (seller re-issues via Shopee
chat when it changes; last known 2026-07: `38.253.224.22`). Port `22054`, user `root`. Password auth is
prohibited for Claude (Anthropic rule — no password/token entry in any field). Instead, an ed25519 key
`claude-walendria-setup` (fingerprint `SHA256:Q4zXGhunI/I7ATnEUEIIpdMZcKbeRouH5S/H+hMfszU`) is
installed in `/root/.ssh/authorized_keys` on the VPS and lives on the working machine at
`C:\Users\ASUS\.ssh\id_walendria_vps` (chmod 600).

Test with `ssh -i "$HOME/.ssh/id_walendria_vps" -p 22054 root@<current-ip> "hostname && pm2 list"`. If the
IP changed, ask the user for the new one. If the key was revoked, regenerate a new one, then re-install via
a one-shot Python + paramiko script that prompts for the VPS password locally (never on the SSH command
line, never logged) and writes the pubkey to `authorized_keys` — model the same shape as
`install_claude_key.py` from the 2026-07-14 setup: `getpass.getpass` for password, `paramiko.SSHClient` for
one-shot install, self-verify with key auth before exiting.

Ban gotcha: **repeated failed SSH attempts trigger fail2ban** on the VPS — pattern is TCP accepted then
immediate `kex_exchange_identification: Connection closed`. Cure: change the client's public IP (router
reboot / mobile hotspot) or wait for the ban window (~10-60 min), never retry-loop.

### Redeploying the app (source-only sync + rebuild)

The app has no git remote and D:\walendria-app is not on the VPS. Sync source via tar-over-ssh (rsync isn't
on Windows). The `.env.local` on the VPS contains `PINATA_JWT` — never overwrite it blindly; transfer
separately only when it actually changed.

```bash
KEY="$HOME/.ssh/id_walendria_vps"
VPS=root@<current-ip>          # ask user or verify last-known IP still connects
cd /d/walendria-app
tar --exclude=node_modules --exclude=.next --exclude=.git --exclude=.env.local \
    --exclude=tsconfig.tsbuildinfo -czf - . \
  | ssh -i "$KEY" -p 22054 "$VPS" "mkdir -p /root/walendria-app && tar -xzf - -C /root/walendria-app"
# then on VPS:
ssh -i "$KEY" -p 22054 "$VPS" "cd /root/walendria-app && \
    npm install --no-audit --no-fund && \
    npm run build && \
    pm2 restart walendria-app --update-env && \
    pm2 save"
```

Two hard-earned rules:

1. **`npm install`, not `npm ci`.** The lock file has drifted (`zod` currently missing at the version the
   tree resolves to), so `npm ci`'s strict lock check errors out with a bizarre help-text dump. `npm install`
   heals the lock in place. If the lock is ever fully re-synced from local, `npm ci` becomes usable again.
2. **Never re-enable `wp-landing.service`** while walendria-app runs. It's the old python static server that
   used to serve walendria.org from `/root/reaworks-landing/` on port 4180 — was `systemctl stop && disable`
   during the 2026-07-14 swap. Backup lives at `/root/backups/reaworks-landing-*.tar.gz`. Starting it again
   grabs port 4180 first at boot and locks pm2 out.

Verify a redeploy: `curl -sI http://127.0.0.1:4180` from VPS (must be 200 with `X-Powered-By: Next.js`), then
`curl -sI https://walendria.org` externally. Cross-check `curl https://indexer.walendria.org/health` didn't
regress (keeper-bot is on the same box; a bad app deploy shouldn't touch it, but you're one `pm2 restart all`
away from breaking both).

pm2 is configured to boot-persist: `pm2-root.service` is enabled and `pm2 save` writes both apps to
`/root/.pm2/dump.pm2`. Always `pm2 save` after any process add/remove or the resurrection on next boot
will forget the change.

Ecosystem file at `/root/walendria-app/ecosystem.config.js` sets `PORT=4180`, `NODE_ENV=production`, and
`max_memory_restart=900M`. Don't move the app to another port — the tunnel config is scoped to 4180.

### Perf tune to consider once (not urgent)

`INDEXER_URL` on the VPS `.env.local` currently points at `https://indexer.walendria.org`, which means every
server-side fetch from the app loops out through Cloudflare and back to the same box's port 4000. Setting
`INDEXER_URL=http://127.0.0.1:4000` on the VPS `.env.local` (leave the local `.env.local` alone) and `pm2
restart walendria-app` cuts that hop entirely. Not blocking — noted here so future sessions don't need to
re-derive it.

## Conventions

- **Auto-commit is pre-authorized** for both walendria-contracts and walendria-app — commit without asking.
  End every commit message with:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
  Push this repo (remote exists); the app has no remote.
- Commit **source only** — never stage the `broadcast/*.json` noise except the tracked `run-latest.json` when
  it records the deploy you're documenting.
- **No dollar-anchoring**: never call a xDAI amount "small"/"reasonable" as if universal — the protocol is
  built for the whole world.
- Match the surrounding code: this repo has dense, reasoning-heavy NatSpec/comments. New code should explain
  *why*, not just *what*.

## Adding a feature — the pattern that works here

Contract change → tests (unit + monotonic/edge + fuzz) → `forge test` full green → `forge fmt` → app UI +
ABI in `contracts.ts` → wallet History/Notifications if it emits a user-facing event → docs (`PLANNED_FEATURES.md`
entry retired, `/rules` page bullet) → app tsc/eslint/build → commit both → hand off the redeploy command →
on new addresses, run the post-deploy checklist + VPS sync.

Storage-layout tip learned the hard way: **adding a field to the `Slot` struct changes the public `slots`
getter's arity and breaks ~40 test destructurings.** If you need per-slot state, prefer a **standalone
mapping** (e.g. `slotWindowOverride`) so the getter shape is untouched. The whitepaper
`walendria-app/public/walendria-protocol-the28.md` is the **verbatim canonical** doc — don't edit it for
incremental features; update `/rules` and NatSpec instead.
