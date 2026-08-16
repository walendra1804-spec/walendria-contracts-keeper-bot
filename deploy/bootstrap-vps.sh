#!/usr/bin/env bash
#
# bootstrap-vps.sh - rebuild the whole Walendria serving stack on a blank Ubuntu box.
#
# Written 2026-08-16, after the VPS provider announced a malware wipe and a machine swap. The
# point is that a fresh box should take ~30 minutes and reproduce a KNOWN-GOOD layout, rather
# than an afternoon of half-remembered steps that quietly recreate the old footguns.
#
# Run as root on the NEW VPS:
#     bash bootstrap-vps.sh
#
# It is idempotent: re-running it is safe and will skip what is already in place.
#
# ---------------------------------------------------------------------------------------------
# WHAT THIS SCRIPT DELIBERATELY CHANGES FROM THE OLD BOX
# ---------------------------------------------------------------------------------------------
#
# 1. pm2 runs keeper-bot straight out of the git-tracked keeper-bot/src/, NOT a hand-copied
#    duplicate at the repo root. The old box had .js files manually copied into the repo root's
#    src/ next to the .sol files, so `git pull` updated keeper-bot/src/ while the running process
#    kept reading a stale root src/config.js. That produced the classic "redeploy's new addresses
#    silently don't take effect / the app shows a ghost listing" bug. Do not recreate it.
#
# 2. The app's build runs under systemd-run, so it survives the SSH session dying. A build killed
#    halfway leaves .next gutted and the site serving 500s until someone rebuilds - that has
#    happened here before.
#
# 3. INDEXER_URL points at 127.0.0.1:4000, not the public https://indexer.walendria.org. The old
#    box looped every server-side fetch out through Cloudflare and back to its own port 4000.
#
# ---------------------------------------------------------------------------------------------
# WHAT YOU MUST HAVE READY BEFORE RUNNING
# ---------------------------------------------------------------------------------------------
#
#   - The walendria-app source, already transferred to /root/walendria-app (see PHASE 4; the
#     laptop-side tar command is printed by this script if the directory is missing).
#   - A Cloudflare account with the walendria.org zone.
#   - Secrets you will paste when prompted: PINATA_JWT, the keeper's PRIVATE_KEY, and the
#     WalletConnect project id.
#
# Ports: 4000 = keeper-bot indexer, 4180 = walendria-app.
#
set -euo pipefail

APP_DIR=/root/walendria-app
KEEPER_DIR=/root/walendria-keeper-bot
KEEPER_REPO=https://github.com/walendra1804-spec/walendria-contracts-keeper-bot.git
NODE_MAJOR=20

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"

# =================================================================================================
# PHASE 1 - base system
# =================================================================================================
log "PHASE 1: base packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git tar ca-certificates gnupg ufw >/dev/null

if ! command -v node >/dev/null 2>&1; then
  log "installing Node ${NODE_MAJOR}.x"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
log "node $(node -v) / npm $(npm -v)"

command -v pm2 >/dev/null 2>&1 || { log "installing pm2"; npm install -g pm2 >/dev/null; }

if ! command -v cloudflared >/dev/null 2>&1; then
  log "installing cloudflared"
  curl -fsSL -o /tmp/cloudflared.deb \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i /tmp/cloudflared.deb >/dev/null
  rm -f /tmp/cloudflared.deb
fi
log "cloudflared $(cloudflared --version 2>&1 | head -1)"

# =================================================================================================
# PHASE 2 - firewall
# =================================================================================================
# 4000 and 4180 are NOT opened to the internet. Everything public reaches them through the
# cloudflared tunnel, which dials out. Exposing them directly would bypass Cloudflare entirely.
log "PHASE 2: firewall (SSH only; 4000/4180 stay loopback-only behind the tunnel)"

SSH_PORT="$(awk '/^[[:space:]]*Port[[:space:]]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
SSH_PORT="${SSH_PORT:-22}"
ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || warn "ufw enable failed, continuing"
log "SSH port allowed: ${SSH_PORT}"

# =================================================================================================
# PHASE 3 - keeper-bot
# =================================================================================================
log "PHASE 3: keeper-bot"

if [ -d "$KEEPER_DIR/.git" ]; then
  git -C "$KEEPER_DIR" fetch origin --quiet
  git -C "$KEEPER_DIR" reset --hard origin/master --quiet
else
  git clone --quiet "$KEEPER_REPO" "$KEEPER_DIR"
fi

cd "$KEEPER_DIR/keeper-bot"
npm install --no-audit --no-fund --silent

# The live DB. Deleting it forces a full rescan from DEPLOYMENT_BLOCK, which is exactly what a
# fresh box wants - the indexer rebuilds its whole view from chain state, so nothing is lost.
rm -f "$KEEPER_DIR/keeper-bot/data.json"

if [ ! -f "$KEEPER_DIR/keeper-bot/.env" ]; then
  warn "keeper-bot/.env missing - creating a template."
  cat > "$KEEPER_DIR/keeper-bot/.env" <<'KEEPEREOF'
# Keeper key. MUST be a fresh key generated for this role alone, funded with a small amount of
# xDAI for gas. Never the deployer key: this file sits on a rented box, and the deployer address
# controls DeveloperPool.setWithdrawalRecipient. A breach of this file should cost gas money and
# nothing else. Poking is permissionless, so a dead keeper delays resolution, it does not block it.
PRIVATE_KEY=
RPC_URL=https://rpc.gnosischain.com
PORT=4000
KEEPEREOF
  chmod 600 "$KEEPER_DIR/keeper-bot/.env"
  warn "Fill PRIVATE_KEY in $KEEPER_DIR/keeper-bot/.env before the keeper can poke."
fi

# Run the git-tracked entrypoint directly. See the header note - do NOT copy these .js files to
# the repo root, that is the stale-config bug.
pm2 delete walendria-keeper >/dev/null 2>&1 || true
pm2 start "$KEEPER_DIR/keeper-bot/src/index.js" \
  --name walendria-keeper \
  --cwd "$KEEPER_DIR/keeper-bot" \
  --update-env
log "keeper-bot started from $KEEPER_DIR/keeper-bot/src/index.js"

# =================================================================================================
# PHASE 4 - walendria-app
# =================================================================================================
log "PHASE 4: walendria-app"

if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/package.json" ]; then
  cat <<'TAREOF'

  walendria-app source is not on this box yet, and it has no git remote - it only exists on the
  laptop. Run this FROM THE LAPTOP (Git Bash), then re-run this script:

      KEY="$HOME/.ssh/id_walendria_vps"
      VPS=root@<NEW_IP>
      cd /d/walendria-app
      tar --exclude=node_modules --exclude=.next --exclude=.git --exclude=.env.local \
          --exclude=tsconfig.tsbuildinfo -czf - . \
        | ssh -i "$KEY" -p <SSH_PORT> "$VPS" "mkdir -p /root/walendria-app && tar -xzf - -C /root/walendria-app"

TAREOF
  die "transfer walendria-app first"
fi

if [ ! -f "$APP_DIR/.env.local" ]; then
  warn ".env.local missing - creating a template."
  cat > "$APP_DIR/.env.local" <<'ENVEOF'
# REQUIRED IN PRODUCTION. Without it, every mobile wallet fails SILENTLY: the wallet app opens
# to its home screen with nothing to sign and no error anywhere, while desktop extension wallets
# keep working because they never touch the WalletConnect relay. This exact omission made
# walendria.org unusable from phones for months.
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=9e633a545879646ff69692ded7ad5162

# Loopback, not the public hostname. The app and the indexer are on this same box; pointing at
# https://indexer.walendria.org would send every server-side fetch out through Cloudflare and
# straight back here.
INDEXER_URL=http://127.0.0.1:4000

# Pinata JWT for pinning evidence uploads. Regenerate at
# https://app.pinata.cloud/developers/api-keys (needs pinFileToIPFS). Treat any JWT that lived on
# the previous box as compromised.
PINATA_JWT=

# Outside the app directory on purpose: a redeploy replaces the whole app tree and would
# otherwise wipe every discussion post.
DISCUSSION_DB_PATH=/root/walendria-discussion.json
ENVEOF
  chmod 600 "$APP_DIR/.env.local"
  warn "Fill PINATA_JWT in $APP_DIR/.env.local (evidence upload stays disabled until you do)."
fi

if [ ! -f "$APP_DIR/ecosystem.config.js" ]; then
  cat > "$APP_DIR/ecosystem.config.js" <<'ECOEOF'
// Port 4180 is not arbitrary: the cloudflared ingress rules are scoped to it. Changing it here
// without changing the tunnel config takes the site offline.
module.exports = {
  apps: [
    {
      name: "walendria-app",
      cwd: "/root/walendria-app",
      script: "npm",
      args: "start",
      env: { PORT: 4180, NODE_ENV: "production" },
      max_memory_restart: "900M",
    },
  ],
};
ECOEOF
fi

cd "$APP_DIR"
# npm install, NOT npm ci. The lock file has drifted from the tree it resolves to, and npm ci's
# strict check errors out with an unhelpful help-text dump. npm install heals the lock in place.
log "npm install (this takes a few minutes)"
npm install --no-audit --no-fund --silent

# next build wipes .next in place. On a fresh box nothing is serving yet so there is no outage
# risk, but the build still must not die with the SSH session - nohup inside ssh is not enough,
# it gets killed when the connection is torn down. systemd-run is owned by init and survives.
log "building (systemd-run, survives disconnect) - poll below"
systemctl reset-failed wapp-build >/dev/null 2>&1 || true
systemd-run --unit=wapp-build --collect --property=Type=oneshot \
  /bin/bash -c "cd $APP_DIR && npm run build > /root/wapp-build.log 2>&1"

# ActiveState, not `is-active --quiet`: the latter returns non-zero while a Type=oneshot unit is
# still 'activating', which reads as a failure when the build is merely still running.
while :; do
  state="$(systemctl show wapp-build -p ActiveState --value 2>/dev/null || echo inactive)"
  case "$state" in
    activating|active) printf '.'; sleep 15 ;;
    *) echo; break ;;
  esac
done

[ -f "$APP_DIR/.next/required-server-files.json" ] \
  || { tail -30 /root/wapp-build.log; die "build failed - see /root/wapp-build.log"; }
log "build OK"

pm2 delete walendria-app >/dev/null 2>&1 || true
pm2 start "$APP_DIR/ecosystem.config.js" --update-env

# =================================================================================================
# PHASE 5 - persist pm2
# =================================================================================================
log "PHASE 5: pm2 boot persistence"
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true
systemctl enable --now pm2-root >/dev/null 2>&1 || true
pm2 save
log "pm2 saved - both apps will come back on reboot"

# =================================================================================================
# PHASE 6 - verify the origin before touching the tunnel
# =================================================================================================
log "PHASE 6: origin checks"

sleep 5
app_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://127.0.0.1:4180 || echo 000)"
idx_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://127.0.0.1:4000/health || echo 000)"
echo "  app  http://127.0.0.1:4180        -> $app_code  (want 200)"
echo "  idx  http://127.0.0.1:4000/health -> $idx_code  (want 200)"
[ "$app_code" = "200" ] || warn "app not answering yet: pm2 logs walendria-app --lines 50"
[ "$idx_code" = "200" ] || warn "indexer not answering yet: pm2 logs walendria-keeper --lines 50"

# =================================================================================================
# PHASE 7 - cloudflared tunnel (manual, needs a browser login)
# =================================================================================================
cat <<'TUNNELEOF'

===================================================================================================
PHASE 7 - the tunnel. Not automated: it needs an interactive browser login to your Cloudflare
account, which cannot happen from a script.

  1. cloudflared tunnel login
       Prints a URL. Open it on the laptop, pick the walendria.org zone. Writes
       /root/.cloudflared/cert.pem.

  2. cloudflared tunnel create walendria-web
       Prints a tunnel UUID and writes /root/.cloudflared/<UUID>.json. Note the UUID.

  3. Write /etc/cloudflared/config.yml (substitute the UUID):

         tunnel: <UUID>
         credentials-file: /root/.cloudflared/<UUID>.json
         ingress:
           - hostname: walendria.org
             service: http://127.0.0.1:4180
           - hostname: www.walendria.org
             service: http://127.0.0.1:4180
           - hostname: indexer.walendria.org
             service: http://127.0.0.1:4000
           - service: http_status:404

  4. Point DNS at the new tunnel (replaces the old CNAMEs automatically):

         cloudflared tunnel route dns walendria-web walendria.org
         cloudflared tunnel route dns walendria-web www.walendria.org
         cloudflared tunnel route dns walendria-web indexer.walendria.org

  5. cloudflared service install && systemctl enable --now cloudflared

  6. Verify from OUTSIDE, not just locally. pm2 will happily report "online" while every public
     request 530s, because a 530 is Cloudflare failing to reach the origin, not the app failing.

         curl -sI https://walendria.org
         curl -s  https://indexer.walendria.org/health

===================================================================================================
POST-RESTORE CHECKLIST
===================================================================================================

  [ ] Update the SSH IP in D:\vps-access-for-ai.md and CLAUDE.md - the new box has a new address.
  [ ] Re-add the laptop's public key to /root/.ssh/authorized_keys (id_walendria_vps.pub).
  [ ] Treat every secret that lived on the OLD box as compromised and rotate it:
        - PINATA_JWT              -> app.pinata.cloud
        - TELEGRAM_BOT_TOKEN      -> @BotFather, /revoke
        - CLAUDE_CODE_OAUTH_TOKEN -> claude.ai Settings > Claude Code > delete the token
        - keeper PRIVATE_KEY      -> generate a fresh one, move any balance off the old address
  [ ] Google Search Console -> resubmit sitemap.xml, then Request indexing for /id.
  [ ] Confirm https://walendria.org/id returns 200 and the sitemap now lists it.

TUNNELEOF

log "bootstrap complete through phase 6. Phase 7 is manual - see above."
