#!/usr/bin/env bash
# Deploy Glass Agent to a Freestyle VM with a public HTTPS *.style.dev domain.
# Re-run to ship a new version; jobs in /var/lib/glass-agent are kept.
#
# Needs FREESTYLE_API_KEY and ANTHROPIC_API_KEY in .env (gitignored) or the environment.
# Uses the Freestyle CLI via npx (downloads the pinned `freestyle` npm package on first run).
#
# Usage: scripts/deploy.sh [subdomain]     -> https://<subdomain>.style.dev (default: glass-agent-demo)
set -euo pipefail
cd "$(dirname "$0")/.."

VM=glass-agent
DOMAIN="${1:-glass-agent-demo}.style.dev"

# Read just the two keys we need from .env (no blanket export of everything in it).
envval() { [ -f .env ] && sed -n "s/^$1=//p" .env | tail -1 | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'; }
FREESTYLE_KEY="${FREESTYLE_API_KEY:-$(envval FREESTYLE_API_KEY)}"
ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-$(envval ANTHROPIC_API_KEY)}"
[ -n "$FREESTYLE_KEY" ] || { echo "Add FREESTYLE_API_KEY to .env" >&2; exit 1; }
[ -n "$ANTHROPIC_KEY" ] || { echo "Add ANTHROPIC_API_KEY to .env" >&2; exit 1; }

# The Freestyle CLI gets only its own key: Anthropic key removed from its environment, and it runs
# from a temp dir so it can't pick up this project's .env.
FS=(env -u ANTHROPIC_API_KEY FREESTYLE_API_KEY="$FREESTYLE_KEY" npx -y freestyle@0.2.20)

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "== building"
npm run -s build
tar -czf "$BUILD/app.tgz" dist public data/seed.json package.json package-lock.json
cd "$BUILD"
# Only the Anthropic key goes to the VM (not the Freestyle key).
umask 077
printf 'ANTHROPIC_API_KEY=%s\nPORT=3000\nDATA_DIR=/var/lib/glass-agent\nNODE_ENV=production\n' "$ANTHROPIC_KEY" > "$BUILD/glass-agent.env"

if ! "${FS[@]}" vm get "$VM" >/dev/null 2>&1; then
  echo "== creating VM '$VM' (Ubuntu, 2 vCPU / 4 GiB)"
  "${FS[@]}" vm create --snapshot-id freestyle/ubuntu-sm --slug "$VM" --no-ssh
fi
# Pause after 15 min without traffic to save free-plan hours; the next request wakes it.
"${FS[@]}" vm update "$VM" --idle-timeout-seconds 900 >/dev/null

echo "== uploading"
"${FS[@]}" vm fs write "$VM" /tmp/glass-agent.tgz "$BUILD/app.tgz"
"${FS[@]}" vm fs write "$VM" /etc/glass-agent.env "$BUILD/glass-agent.env"

echo "== installing and (re)starting service"
"${FS[@]}" vm exec "$VM" --linux-user root --timeout-ms 280000 -- bash -lc '
set -euo pipefail
export HOME=/root
chmod 600 /etc/glass-agent.env
mkdir -p /srv/glass-agent /var/lib/glass-agent
rm -rf /srv/glass-agent/dist /srv/glass-agent/public
tar -xzf /tmp/glass-agent.tgz -C /srv/glass-agent
cd /srv/glass-agent
npm ci --omit=dev --no-audit --no-fund
NODE=$(command -v node || echo /usr/local/bin/node)
echo "node: $NODE ($($NODE --version))"
cat > /etc/systemd/system/glass-agent.service <<EOF
[Unit]
Description=Glass Agent backend
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$NODE /srv/glass-agent/dist/server.js
WorkingDirectory=/srv/glass-agent
EnvironmentFile=/etc/glass-agent.env
Restart=always
RestartSec=2
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable glass-agent >/dev/null
systemctl restart glass-agent
for i in $(seq 1 30); do
  if curl -sf http://localhost:3000/health; then echo; exit 0; fi
  sleep 1
done
journalctl -u glass-agent -n 40 --no-pager
exit 1
'

echo "== routing https://$DOMAIN -> $VM:3000"
"${FS[@]}" tls create --domain "$DOMAIN" --from public --to "vm=$VM,port=3000" \
  || echo "   (rule not created; fine if it already exists from an earlier deploy)"

echo "== checking public URL"
for i in $(seq 1 20); do
  if curl -sf "https://$DOMAIN/health"; then
    echo
    echo "Deployed: https://$DOMAIN"
    exit 0
  fi
  sleep 2
done
echo "Public URL not answering yet: https://$DOMAIN/health (check: scripts/logs.sh)" >&2
exit 1
