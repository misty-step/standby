#!/usr/bin/env bash
# Verify first-class meeting objects through the public daemon API: create/list,
# rename, per-meeting proposal requests, worker outputs, and no cross-meeting
# state bleed.
set -euo pipefail

cd "$(dirname "$0")/.."

EVIDENCE="${STANDBY_EVIDENCE_DIR:-docs/evidence/first-class-meetings}"
rm -rf "$EVIDENCE"
mkdir -p "$EVIDENCE"
export EVIDENCE

cargo build -p standbyd >/dev/null

ADDR="127.0.0.1:4332"
DB="$(mktemp -t standby-meetings.XXXXXX).db"
JOBS="$(mktemp -d -t standby-meetings-jobs.XXXXXX)"
FAKE_BIN="$(mktemp -d -t standby-fake-opencode-bin.XXXXXX)"
ln -s "$PWD/scripts/fixtures/fake-opencode.sh" "$FAKE_BIN/opencode"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS"
export STANDBY_ENABLE_SEED=1
export STANDBY_PROPOSAL_PROVIDER=recorded
export STANDBY_OPERATOR_TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-meetings-token}"
export PATH="$FAKE_BIN:$PATH"

target/debug/standbyd >"$EVIDENCE/standbyd.log" 2>&1 &
PID=$!

cleanup() {
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  rm -f "$DB" "$DB"-wal "$DB"-shm
  rm -rf "$JOBS" "$FAKE_BIN"
}
trap cleanup EXIT

wait_health() {
  for _ in $(seq 1 100); do
    if curl -fsS "http://$ADDR/health" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  echo "FAIL: daemon never became healthy" >&2
  cat "$EVIDENCE/standbyd.log" >&2
  exit 2
}

operator_post() {
  local path="$1"
  local body="$2"
  curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" \
    -H 'content-type: application/json' \
    -d "$body" \
    -X POST "http://$ADDR$path"
}

seed() {
  local meeting="$1"
  shift
  local body
  body="$(node -e 'process.stdout.write(JSON.stringify({events:process.argv.slice(1)}))' "$@")"
  operator_post "/api/meetings/$meeting/seed" "$body" >/dev/null
}

projection() {
  curl -fsS "http://$ADDR/api/meetings/$1"
}

wait_for_projection() {
  local meeting="$1"
  local expression="$2"
  local label="$3"
  for _ in $(seq 1 160); do
    if projection "$meeting" | node -e "const p=JSON.parse(require('fs').readFileSync(0,'utf8')); process.exit(($expression)?0:1)"; then
      return 0
    fi
    sleep 0.25
  done
  echo "FAIL: timed out waiting for $label" >&2
  projection "$meeting" >&2 || true
  exit 3
}

wait_health

operator_post "/api/meetings" '{"title":"Discovery sync"}' >"$EVIDENCE/create-a.json"
MEETING_A="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write(p.meeting_id)' "$EVIDENCE/create-a.json")"
operator_post "/api/meetings" '{"title":"Launch review"}' >"$EVIDENCE/create-b.json"
MEETING_B="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write(p.meeting_id)' "$EVIDENCE/create-b.json")"
export MEETING_A MEETING_B

seed "$MEETING_A" \
  '{"type":"source.started","mode":"mic+system"}' \
  '{"type":"segment.final","lane":"system_audio","speaker":"remote_1","text":"We need a competitive brief for local-first meeting assistants."}'
operator_post "/api/meetings/$MEETING_A/proposal-requests" \
  '{"message":"Create a proposal for the competitive brief from this meeting.","context_window":"recent","max_proposals":1}' \
  >"$EVIDENCE/proposal-a.json"

seed "$MEETING_B" \
  '{"type":"source.started","mode":"mic+system"}' \
  '{"type":"segment.final","lane":"system_audio","speaker":"remote_1","text":"Please prepare launch review notes from this call."}'
operator_post "/api/meetings/$MEETING_B/proposal-requests" \
  '{"message":"Prepare launch review notes from this meeting.","context_window":"recent","max_proposals":1}' \
  >"$EVIDENCE/proposal-b.json"
PROP_B="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const prop=p.proposals.find((item)=>item.status==="proposed"); if(!prop) process.exit(1); process.stdout.write(prop.id)' "$EVIDENCE/proposal-b.json")"
operator_post "/api/proposals/$PROP_B/approve" '{"prompt":"Prepare launch review notes from this meeting."}' >"$EVIDENCE/approval-b.json"
wait_for_projection "$MEETING_B" "p.jobs.some((job)=>job.status==='completed') && p.artifacts.length === 1" "meeting B completed worker output"

operator_post "/api/meetings/$MEETING_A/rename" '{"title":"Customer discovery sync"}' >"$EVIDENCE/rename-a.json"

curl -fsS "http://$ADDR/api/meetings" >"$EVIDENCE/meetings.json"
projection "$MEETING_A" >"$EVIDENCE/projection-a.json"
projection "$MEETING_B" >"$EVIDENCE/projection-b.json"

node <<'NODE'
const fs = require("fs");
const dir = process.env.EVIDENCE;
const meetings = JSON.parse(fs.readFileSync(`${dir}/meetings.json`, "utf8"));
const a = JSON.parse(fs.readFileSync(`${dir}/projection-a.json`, "utf8"));
const b = JSON.parse(fs.readFileSync(`${dir}/projection-b.json`, "utf8"));
const aSummary = meetings.find((meeting) => meeting.id === process.env.MEETING_A);
const bSummary = meetings.find((meeting) => meeting.id === process.env.MEETING_B);
function assert(condition, message) {
  if (!condition) {
    console.error(`FAIL: ${message}`);
    process.exit(1);
  }
}
assert(aSummary, "meeting A missing from catalog");
assert(bSummary, "meeting B missing from catalog");
assert(aSummary.title === "Customer discovery sync", "renamed meeting title missing from catalog");
assert(bSummary.title === "Launch review", "meeting B title missing from catalog");
assert(meetings[0].id === process.env.MEETING_A, "rename did not update meeting recency ordering");
assert(aSummary.transcript_count === 1, "meeting A transcript count wrong");
assert(aSummary.question_count === 1, "meeting A question count wrong");
assert(aSummary.open_suggestion_count === 1, "meeting A open suggestion count wrong");
assert(aSummary.output_count === 0, "meeting A output count leaked");
assert(bSummary.transcript_count === 1, "meeting B transcript count wrong");
assert(bSummary.question_count === 1, "meeting B question count wrong");
assert(bSummary.output_count === 1, "meeting B output count wrong");
assert(a.transcript.some((segment) => segment.text.includes("competitive brief")), "meeting A transcript missing");
assert(!a.transcript.some((segment) => segment.text.includes("launch review")), "meeting B transcript leaked into A");
assert(b.transcript.some((segment) => segment.text.includes("launch review")), "meeting B transcript missing");
assert(!b.transcript.some((segment) => segment.text.includes("competitive brief")), "meeting A transcript leaked into B");
assert(a.jobs.length === 0 && a.artifacts.length === 0, "meeting B job/output leaked into A");
assert(b.jobs.length === 1 && b.artifacts.length === 1, "meeting B job/output missing");
fs.writeFileSync(`${dir}/verdict.json`, JSON.stringify({
  status: "pass",
  claim: "Meetings are first-class API objects with scoped transcript, questions, proposals, jobs, and outputs.",
  meetings: meetings.map((meeting) => ({
    id: meeting.id,
    title: meeting.title,
    transcript_count: meeting.transcript_count,
    question_count: meeting.question_count,
    open_suggestion_count: meeting.open_suggestion_count,
    output_count: meeting.output_count,
  })),
}, null, 2) + "\n");
NODE

echo "meeting catalog verification passed; evidence in $EVIDENCE/"
