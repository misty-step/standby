#!/usr/bin/env bash
# Proves backlog 021 through the daemon -> helper stdout path: a slow automatic
# proposal call must not stall capture ingest, so later finalized segments are
# appended before the proposal/no-proposal event lands.
set -euo pipefail

cd "$(dirname "$0")/.."

export PATH="$HOME/.cargo/bin:$PATH"

EVIDENCE="${STANDBY_EVIDENCE_DIR:-docs/evidence/qa-021-async-proposal-ingest}"
mkdir -p "$EVIDENCE"
export EVIDENCE

HELPER="$PWD/scripts/fixtures/fake-capture-helper-async-proposal.sh"
if [ ! -x "$HELPER" ]; then
  chmod +x "$HELPER"
fi

cargo build -p standbyd >/dev/null

DB="$(mktemp -t standby-async-proposal-ingest.XXXXXX).db"
JOBS="$(mktemp -d -t standby-async-proposal-ingest-jobs.XXXXXX)"
ADDR="${STANDBY_ASYNC_PROPOSAL_INGEST_ADDR:-127.0.0.1:4331}"
MTG="async-proposal-ingest"
TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-verify-token}"
export STANDBY_DB="$DB"
export STANDBY_ADDR="$ADDR"
export STANDBY_JOBS_DIR="$JOBS"
export STANDBY_CAPTURE_HELPER="$HELPER"
export STANDBY_OPERATOR_TOKEN="$TOKEN"
export STANDBY_PROPOSAL_PROVIDER=recorded
export STANDBY_PROPOSAL_DEBOUNCE_SEGMENTS=1
export STANDBY_PROPOSAL_TEST_DELAY_MS="${STANDBY_PROPOSAL_TEST_DELAY_MS:-2500}"
export STANDBY_FAKE_HELPER_STEP_SECS="${STANDBY_FAKE_HELPER_STEP_SECS:-0.20}"

cargo run -p standbyd >"$EVIDENCE/standbyd.log" 2>&1 &
PID=$!
cleanup() {
  curl -fsS -H "x-standby-operator-token: $TOKEN" \
    -X POST "http://$ADDR/api/meetings/$MTG/capture/stop" >/dev/null 2>&1 || true
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  rm -f "$DB" "$DB"-wal "$DB"-shm
  rm -rf "$JOBS"
}
trap cleanup EXIT

READY=0
for _ in $(seq 1 80); do
  if curl -fsS "http://$ADDR/health" >/dev/null 2>&1; then READY=1; break; fi
  kill -0 "$PID" 2>/dev/null || { cat "$EVIDENCE/standbyd.log"; exit 1; }
  sleep 0.25
done
[ "$READY" = 1 ] || { echo "daemon never became ready"; cat "$EVIDENCE/standbyd.log"; exit 1; }

curl -fsS -H "x-standby-operator-token: $TOKEN" \
  -X POST "http://$ADDR/api/meetings/$MTG/capture/start?mode=mic%2Bsystem" \
  >"$EVIDENCE/capture-start.json"

COMPLETE=0
for _ in $(seq 1 80); do
  curl -fsS "http://$ADDR/api/meetings/$MTG" >"$EVIDENCE/projection.json"
  if python3 - "$EVIDENCE/projection.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    projection = json.load(handle)
terminal = len(projection.get("proposals") or []) + len(projection.get("no_proposals") or [])
sys.exit(0 if len(projection.get("transcript") or []) >= 4 and terminal >= 1 else 1)
PY
  then
    COMPLETE=1
    break
  fi
  sleep 0.25
done

[ "$COMPLETE" = 1 ] || {
  echo "FAIL: projection never reached 4 segments plus a proposal decision" >&2
  cat "$EVIDENCE/projection.json" >&2
  cat "$EVIDENCE/standbyd.log" >&2
  exit 1
}

python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

evidence = Path(os.environ["EVIDENCE"])
projection_path = evidence / "projection.json"
projection = json.loads(projection_path.read_text(encoding="utf-8"))
events = projection.get("events") or []
transcript = projection.get("transcript") or []
decisions = [
    event
    for event in events
    if event.get("event_type") in {"proposal.created", "proposal.not_created"}
]
segments = [
    event
    for event in events
    if event.get("event_type") == "transcript.segment.final"
]

def fail(code, message, **extra):
    (evidence / "verdict.json").write_text(
        json.dumps({"status": "fail", "message": message, **extra}, indent=2),
        encoding="utf-8",
    )
    print(f"FAIL: {message}", file=sys.stderr)
    if extra:
        print(json.dumps(extra, indent=2), file=sys.stderr)
    sys.exit(code)

if len(transcript) < 4:
    fail(
        2,
        f"expected 4 finalized transcript segments, got {len(transcript)}",
        transcript=[segment.get("text") for segment in transcript],
    )
if not decisions:
    fail(3, "expected a proposal decision event")
if len(segments) < 4:
    fail(4, f"expected 4 segment events, got {len(segments)}")

first_decision_index = next(
    (
        index
        for index, event in enumerate(events)
        if event.get("event_type") in {"proposal.created", "proposal.not_created"}
    ),
    -1,
)
seen_segments = 0
fourth_segment_index = -1
for index, event in enumerate(events):
    if event.get("event_type") == "transcript.segment.final":
        seen_segments += 1
        if seen_segments == 4:
            fourth_segment_index = index
            break

if fourth_segment_index == -1 or first_decision_index == -1 or fourth_segment_index > first_decision_index:
    fail(
        5,
        "final transcript segment did not append before the proposal decision",
        timeline=[event.get("event_type") for event in events],
    )

def timestamp_seconds(event):
    return float(str(event["created_at"]).removesuffix("Z"))

second_segment_time = timestamp_seconds(segments[1])
fourth_segment_time = timestamp_seconds(segments[3])
first_decision_time = timestamp_seconds(events[first_decision_index])
delay_ms = int(os.environ.get("STANDBY_PROPOSAL_TEST_DELAY_MS", "2500"))
segment_window_ms = round((fourth_segment_time - second_segment_time) * 1000)
decision_lag_ms = round((first_decision_time - second_segment_time) * 1000)

if segment_window_ms >= delay_ms - 500:
    fail(
        7,
        "later segments arrived only after the slow proposal window",
        segment_window_ms=segment_window_ms,
        forced_delay_ms=delay_ms,
    )
if decision_lag_ms < delay_ms - 500:
    fail(
        8,
        "proposal decision did not observe the forced slow provider delay",
        decision_lag_ms=decision_lag_ms,
        forced_delay_ms=delay_ms,
    )

timeline = [
    {
        "index": index,
        "event_type": event.get("event_type"),
        "created_at": event.get("created_at"),
        "text": (event.get("payload_json") or {}).get("text"),
    }
    for index, event in enumerate(events)
]
verdict = {
    "status": "pass",
    "claim": "helper stdout ingest continued while the automatic proposal reasoner was sleeping",
    "meeting_id": projection.get("meeting_id"),
    "transcript_segments": len(transcript),
    "proposal_decisions": len(decisions),
    "forced_delay_ms": delay_ms,
    "segment_2_to_4_ms": segment_window_ms,
    "segment_2_to_first_decision_ms": decision_lag_ms,
    "first_decision_type": events[first_decision_index].get("event_type"),
}

(evidence / "event-timeline.json").write_text(json.dumps(timeline, indent=2), encoding="utf-8")
(evidence / "verdict.json").write_text(json.dumps(verdict, indent=2), encoding="utf-8")
print(json.dumps(verdict, indent=2))
PY

echo "async proposal ingest proof passed; evidence in $EVIDENCE/"
