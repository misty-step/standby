#!/usr/bin/env bash
# Backlog 006 proof: a queued/running OpenCode job survives daemon restart and
# completed jobs are not re-run on a later restart.
set -euo pipefail

cd "$(dirname "$0")/.."

EVIDENCE="${STANDBY_EVIDENCE_DIR:-docs/evidence/operator-action-control/worker-recovery}"
mkdir -p "$EVIDENCE"
export EVIDENCE

cargo build -p standbyd >/dev/null

TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-verify-token}"
ORIGINAL_PATH="$PATH"
FAKE_BIN="$(mktemp -d -t standby-fake-opencode-recovery.XXXXXX)"
ln -s "$PWD/scripts/fixtures/fake-opencode.sh" "$FAKE_BIN/opencode"
DB="$(mktemp -t standby-worker-recovery.XXXXXX).db"
JOBS_RAW="$(mktemp -d -t standby-worker-recovery-jobs.XXXXXX)"
JOBS="$(cd "$JOBS_RAW" && pwd -P)"
ADDR="127.0.0.1:4336"
PID=""

cleanup() {
  if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi
  kill_fake_children || true
  rm -f "$DB" "$DB"-wal "$DB"-shm
  rm -rf "$JOBS" "$FAKE_BIN"
}
trap cleanup EXIT

kill_fake_children() {
  local pids
  pids="$(ps -axo pid=,command= | awk -v needle="$FAKE_BIN/opencode" 'index($0, needle) {print $1}' || true)"
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    sleep 0.2
    pids="$(ps -axo pid=,command= | awk -v needle="$FAKE_BIN/opencode" 'index($0, needle) {print $1}' || true)"
    [ -z "$pids" ] || kill -9 $pids 2>/dev/null || true
  fi
}

fake_child_count_for_job() {
  local job_dir="$1"
  ps -axo pid=,command= | awk -v fake="$FAKE_BIN/opencode" -v job="$job_dir" \
    'index($0, fake) && index($0, job) {count++} END {print count+0}'
}

wait_ready() {
  local log="$1"
  for _ in $(seq 1 80); do
    if curl -fsS "http://$ADDR/health" >/dev/null 2>&1; then return 0; fi
    kill -0 "$PID" 2>/dev/null || { cat "$log"; return 1; }
    sleep 0.25
  done
  echo "daemon never became ready" >&2
  cat "$log" >&2
  return 1
}

start_daemon() {
  local log="$1"
  PATH="$FAKE_BIN:$ORIGINAL_PATH" STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS" \
    STANDBY_OPERATOR_TOKEN="$TOKEN" target/debug/standbyd >"$log" 2>&1 &
  PID=$!
  wait_ready "$log"
}

stop_daemon_hard() {
  local reap_workers="${1:-reap-workers}"
  local signal="${2:--TERM}"
  if [ -n "$PID" ]; then
    kill "$signal" "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
  if [ "$reap_workers" = "reap-workers" ]; then
    kill_fake_children
  fi
}

wait_file() {
  local path="$1" label="$2"
  for _ in $(seq 1 120); do
    [ -f "$path" ] && return 0
    sleep 0.25
  done
  echo "timed out waiting for $label at $path" >&2
  return 1
}

poll_terminal() {
  local proposal="$1" output="$2"
  for _ in $(seq 1 180); do
    curl -fsS "http://$ADDR/api/meetings/recovery" >"$output"
    if PROP="$proposal" node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const j=p.jobs.find(x=>x.proposal_id===process.env.PROP&&["completed","failed"].includes(x.status)); process.exit(j?0:1)' "$output"; then
      return 0
    fi
    sleep 0.25
  done
  echo "recovered job did not reach terminal state" >&2
  cat "$output" >&2
  return 1
}

start_daemon "/tmp/standby-worker-recovery-1.log"

curl -fsS -H "x-standby-operator-token: $TOKEN" \
  -X POST "http://$ADDR/api/meetings/recovery/demo" >"$EVIDENCE/demo.json"
PROP="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if(!p.proposals.length)process.exit(2); process.stdout.write(p.proposals[0].id)' "$EVIDENCE/demo.json")"

curl -fsS -H "x-standby-operator-token: $TOKEN" -H 'content-type: application/json' \
  -d '{"prompt":"WAIT_FOR_RELEASE_MARKER prove worker recovery after daemon restart."}' \
  -X POST "http://$ADDR/api/proposals/$PROP/approve" >"$EVIDENCE/approval-before-crash.json"
JOB_ID="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const j=p.jobs.find(job=>job.proposal_id===process.argv[2]); if(!j)process.exit(3); process.stdout.write(j.id)' "$EVIDENCE/approval-before-crash.json" "$PROP")"
JOB_DIR="$JOBS/$JOB_ID"

wait_file "$JOB_DIR/started.marker" "first worker start"
curl -fsS "http://$ADDR/api/meetings/recovery" >"$EVIDENCE/before-crash-projection.json"
JOB_ID="$JOB_ID" node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const job=p.jobs.find(j=>j.id===process.env.JOB_ID);
  if(!job){console.error("FAIL: pre-crash job missing");process.exit(1)}
  if(job.status!=="running"){console.error("FAIL: pre-crash job should be running", job.status);process.exit(1)}
' "$EVIDENCE/before-crash-projection.json"
stop_daemon_hard leave-workers -9
ORPHAN_CHILDREN="$(fake_child_count_for_job "$JOB_DIR")"
if [ "$ORPHAN_CHILDREN" -lt 1 ]; then
  echo "expected daemon crash to leave a fake OpenCode child for recovery cleanup" >&2
  exit 1
fi
UNRELATED_DIR="$JOBS/unrelated-worker"
mkdir -p "$UNRELATED_DIR"
printf 'WAIT_FOR_RELEASE_MARKER unrelated worker should survive target recovery.\n' > "$UNRELATED_DIR/prompt.txt"
(cd "$UNRELATED_DIR" && "$FAKE_BIN/opencode" run --dir "$UNRELATED_DIR" --file "$UNRELATED_DIR/prompt.txt") \
  >/tmp/standby-worker-recovery-unrelated.log 2>&1 &
wait_file "$UNRELATED_DIR/started.marker" "unrelated worker start"
rm -f "$JOB_DIR/started.marker" "$JOB_DIR/release.marker"

start_daemon "/tmp/standby-worker-recovery-2.log"
wait_file "$JOB_DIR/started.marker" "recovered worker start"
CHILDREN_AFTER_RECOVERY="$(fake_child_count_for_job "$JOB_DIR")"
if [ "$CHILDREN_AFTER_RECOVERY" != "1" ]; then
  echo "expected exactly one fake OpenCode child after recovery, got $CHILDREN_AFTER_RECOVERY" >&2
  exit 1
fi
UNRELATED_AFTER_RECOVERY="$(fake_child_count_for_job "$UNRELATED_DIR")"
if [ "$UNRELATED_AFTER_RECOVERY" != "1" ]; then
  echo "unrelated fake OpenCode child should survive target recovery, got $UNRELATED_AFTER_RECOVERY" >&2
  exit 1
fi
printf 'release\n' > "$JOB_DIR/release.marker"
poll_terminal "$PROP" "$EVIDENCE/after-restart-projection.json"

RUN_COUNT="$(cat "$JOB_DIR/run-count.txt")"
if [ "$RUN_COUNT" != "2" ]; then
  echo "expected worker to run exactly twice before completion, got $RUN_COUNT" >&2
  exit 1
fi

stop_daemon_hard
rm -f "$JOB_DIR/started.marker" "$JOB_DIR/release.marker"
start_daemon "/tmp/standby-worker-recovery-3.log"
for _ in $(seq 1 120); do
  RUN_COUNT_AFTER="$(cat "$JOB_DIR/run-count.txt")"
  if [ "$RUN_COUNT_AFTER" != "2" ] || [ -f "$JOB_DIR/started.marker" ]; then
    echo "completed job was re-run on restart; run-count=$RUN_COUNT_AFTER" >&2
    exit 1
  fi
  sleep 0.25
done
curl -fsS "http://$ADDR/api/meetings/recovery" >"$EVIDENCE/after-completed-restart-projection.json"
RUN_COUNT_AFTER="$(cat "$JOB_DIR/run-count.txt")"
if [ "$RUN_COUNT_AFTER" != "2" ]; then
  echo "completed job was re-run on restart; run-count=$RUN_COUNT_AFTER" >&2
  exit 1
fi

PROP="$PROP" JOB_ID="$JOB_ID" RUN_COUNT="$RUN_COUNT_AFTER" node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/after-completed-restart-projection.json`,"utf8"));
  const job=p.jobs.find(j=>j.id===process.env.JOB_ID);
  if(!job){console.error("FAIL: recovered job missing");process.exit(1)}
  if(job.status!=="completed"){console.error("FAIL: recovered job should be completed", job);process.exit(1)}
  if(job.profile!=="opencode"){console.error("FAIL: recovered job should use opencode", job.profile);process.exit(1)}
  if(!p.artifacts.find(a=>a.job_id===job.id)){console.error("FAIL: recovered job has no artifact");process.exit(1)}
  const recoveryEvent=p.events.find(e =>
    e.event_type==="agent_job.progress" &&
    e.payload_json &&
    e.payload_json.id===job.id &&
    e.payload_json.progress_note &&
    e.payload_json.progress_note.includes("recovered after daemon restart") &&
    e.payload_json.progress_note.includes("terminated 1 stale worker")
  );
  if(!recoveryEvent){console.error("FAIL: recovered job has no recovery progress event");process.exit(1)}
  fs.writeFileSync(`${process.env.EVIDENCE}/verdict.json`, JSON.stringify({
    status: "pass",
    checked_at: new Date().toISOString(),
    claim: "queued/running OpenCode jobs are recovered after daemon restart and completed jobs are not re-run",
    proposal_id: process.env.PROP,
    job_id: process.env.JOB_ID,
    run_count: Number(process.env.RUN_COUNT),
    recovery_event_id: recoveryEvent.id,
    receipts: fs.readdirSync(process.env.EVIDENCE).sort()
  }, null, 2) + "\n");
'

echo "worker recovery verification passed; evidence in $EVIDENCE/"
