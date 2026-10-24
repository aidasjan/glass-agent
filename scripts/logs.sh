#!/usr/bin/env bash
# Follow the deployed server's logs (one JSON line per request / tool call).
# Usage: scripts/logs.sh            (Ctrl-C to stop)
set -euo pipefail
cd "$(dirname "$0")/.."
KEY="${FREESTYLE_API_KEY:-$( [ -f .env ] && sed -n 's/^FREESTYLE_API_KEY=//p' .env | tail -1 | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//' )}"
[ -n "$KEY" ] || { echo "Add FREESTYLE_API_KEY to .env" >&2; exit 1; }
# Run from a temp dir with only the Freestyle key, so the CLI never sees the project's .env.
cd "$(mktemp -d)"
exec env -u ANTHROPIC_API_KEY FREESTYLE_API_KEY="$KEY" npx -y freestyle@0.2.20 \
  vm exec glass-agent --linux-user root --timeout-ms 280000 -- journalctl -u glass-agent -n 50 -f --no-pager
