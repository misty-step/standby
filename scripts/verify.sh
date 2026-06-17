#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

cargo test --workspace
npm --prefix ui run build
cargo build -p tacetd

TACET_DB="$(mktemp -t tacet-smoke.XXXXXX.db)"
export TACET_DB
export TACET_ADDR="127.0.0.1:4318"

cargo run -p tacetd > /tmp/tacet-smoke.log 2>&1 &
PID="$!"
cleanup() {
  kill "$PID" >/dev/null 2>&1 || true
  rm -f "$TACET_DB"
}
trap cleanup EXIT

READY=0
for _ in $(seq 1 80); do
  if ! kill -0 "$PID" >/dev/null 2>&1; then
    cat /tmp/tacet-smoke.log
    exit 1
  fi
  if curl -fsS "http://$TACET_ADDR/health" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.25
done

if [ "$READY" -ne 1 ]; then
  cat /tmp/tacet-smoke.log
  exit 1
fi

curl -fsS -X POST "http://$TACET_ADDR/api/meetings/demo/demo" >/tmp/tacet-demo.json
PROPOSAL_ID="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync("/tmp/tacet-demo.json","utf8")); if (!p.proposals.length) process.exit(2); process.stdout.write(p.proposals[0].id);')"
curl -fsS -H 'content-type: application/json' \
  -d '{"approved_by":"verify","prompt":"Research prior art for local-first realtime meeting agents."}' \
  -X POST "http://$TACET_ADDR/api/proposals/$PROPOSAL_ID/approve" >/tmp/tacet-approved.json
node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync("/tmp/tacet-approved.json","utf8")); if (!p.jobs.some((j)=>j.status==="completed")) { process.exit(3); } if (!p.artifacts.length) { process.exit(4); }'

echo "tacet verification passed"
