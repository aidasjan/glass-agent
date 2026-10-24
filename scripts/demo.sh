#!/usr/bin/env bash
# End-to-end demo flow: start a job for the venue, ask about the sample photo, wrap up.
# Usage: scripts/demo.sh [base_url]
set -euo pipefail
BASE=${1:-http://localhost:3000}
PHOTO=$(dirname "$0")/../samples/coffee-machine.jpg
pretty() { node -pe 'JSON.stringify(JSON.parse(require("fs").readFileSync(0)), null, 2)'; }

JOB=$(curl -sf -X POST "$BASE/jobs" -H 'content-type: application/json' -d '{"customer_id":"cust_venue"}' | node -pe 'JSON.parse(require("fs").readFileSync(0)).job.id')
echo "== job $JOB"
echo "== ask"
time curl -sf -X POST "$BASE/ask" -F "job_id=$JOB" -F "text=Coffee's coming out slow and lukewarm, what's going on?" -F "photo=@$PHOTO" | pretty
echo "== wrap up"
time curl -sf -X POST "$BASE/jobs/$JOB/wrapup" -H 'content-type: application/json' \
  -d '{"text":"Wrap it up: descaling kit, new water filter, half an hour of labor"}' | pretty
