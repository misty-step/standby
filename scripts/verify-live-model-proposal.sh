#!/usr/bin/env bash
# Opt-in live provider smoke for the proposal agent. It never runs in the
# default gate; set STANDBY_LIVE_MODEL=1 and OPENAI_API_KEY to spend a model call.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${STANDBY_LIVE_MODEL:-}" != "1" ]; then
  echo "verify-live-model-proposal: skipped (set STANDBY_LIVE_MODEL=1)"
  exit 0
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "verify-live-model-proposal: OPENAI_API_KEY is required when STANDBY_LIVE_MODEL=1" >&2
  exit 2
fi

EVIDENCE="${STANDBY_EVIDENCE_DIR:-docs/evidence/ai-first-proposals/live-model}"
mkdir -p "$EVIDENCE"
export EVIDENCE

cargo build -p standbyd >/dev/null

DB="$(mktemp -t standby-live-model.XXXXXX).db"
JOBS="$(mktemp -d -t standby-live-model-jobs.XXXXXX)"
ADDR="127.0.0.1:4328"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS"
export STANDBY_ENABLE_SEED=1 STANDBY_PROPOSAL_PROVIDER=openai
export STANDBY_OPENAI_PROPOSAL_MODEL="${STANDBY_OPENAI_PROPOSAL_MODEL:-gpt-5.5}"

cargo run -p standbyd >/tmp/standby-live-model-proposal.log 2>&1 &
PID=$!
cleanup() {
  kill "$PID" 2>/dev/null || true
  rm -f "$DB" "$DB"-wal "$DB"-shm
  rm -rf "$JOBS"
}
trap cleanup EXIT

READY=0
for _ in $(seq 1 80); do
  if curl -fsS "http://$ADDR/health" >/dev/null 2>&1; then READY=1; break; fi
  kill -0 "$PID" 2>/dev/null || { cat /tmp/standby-live-model-proposal.log; exit 1; }
  sleep 0.25
done
[ "$READY" = 1 ] || { echo "daemon never became ready"; cat /tmp/standby-live-model-proposal.log; exit 1; }

SEED="$(node -e 'process.stdout.write(JSON.stringify({events:process.argv.slice(1)}))' \
  '{"type":"source.started","mode":"mic+system","mic":true,"system":true}' \
  '{"type":"segment.final","lane":"system_audio","speaker":"remote_1","text":"Customers keep asking whether local-first meeting assistants already exist and what gaps remain."}')"

curl -fsS -H 'content-type: application/json' \
  -d "$SEED" \
  -X POST "http://$ADDR/api/meetings/live-model/seed" >"$EVIDENCE/seed-projection.json"

curl -fsS -H 'content-type: application/json' \
  -d '{"message":"Create a research task proposal from this context for the local-first meeting assistant market","context_window":"recent","max_proposals":1}' \
  -X POST "http://$ADDR/api/meetings/live-model/proposal-requests" >"$EVIDENCE/proposal-response.json"

node - <<'NODE'
const fs = require("fs");
const p = JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/proposal-response.json`, "utf8"));
const proposal = p.proposals.find((item) => item.status === "proposed");
if (!proposal) {
  console.error("FAIL: live model did not create a proposal");
  console.error(JSON.stringify({ no_proposals: p.no_proposals, events: p.events?.map((e) => e.event_type) }, null, 2));
  process.exit(3);
}
if (!proposal.model || proposal.model.provider !== "openai") {
  console.error("FAIL: proposal did not record openai model provenance");
  process.exit(4);
}
if (!proposal.evidence.length) {
  console.error("FAIL: live model proposal lacks transcript evidence");
  process.exit(5);
}
const redacted = {
  meeting_id: p.meeting_id,
  proposal: {
    id: proposal.id,
    title: proposal.title,
    confidence: proposal.confidence,
    model: proposal.model,
    evidence_count: proposal.evidence.length,
  },
  event_types: p.events.map((event) => event.event_type),
};
fs.writeFileSync(`${process.env.EVIDENCE}/redacted-pass.json`, JSON.stringify(redacted, null, 2));
NODE

echo "live model proposal smoke passed; redacted evidence in $EVIDENCE/"
