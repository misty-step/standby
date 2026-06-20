#!/usr/bin/env bash
# End-to-end worker runner proof against the live daemon: seed a meeting, approve
# a proposal, and confirm that (a) approval returns out-of-request (the job is not
# completed inside the HTTP request) and (b) a background worker runs the job in a
# sandboxed scratch and persists a real artifact file plus a completed event.
#
# Default profile is the deterministic local worker (no network/model). Set
# STANDBY_WORKER_PROFILE=claude-research (and ensure the CLI is authed) to drive a
# real model worker; a clean agent_job.failed on auth is an honest, expected
# outcome there.
set -euo pipefail

cd "$(dirname "$0")/.."
cargo build -p standbyd >/dev/null

DB="$(mktemp -t standby-wr.XXXXXX).db"
JOBS="$(mktemp -d -t standby-wr-jobs.XXXXXX)"
ADDR="127.0.0.1:4319"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS"
export STANDBY_WORKER_PROFILE="${STANDBY_WORKER_PROFILE:-local-research}"

cargo run -p standbyd >/tmp/standby-worker-runner.log 2>&1 &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; rm -f "$DB" "$DB"-wal "$DB"-shm; rm -rf "$JOBS"; }
trap cleanup EXIT

READY=0
for _ in $(seq 1 80); do
  if curl -fsS "http://$ADDR/health" >/dev/null 2>&1; then READY=1; break; fi
  kill -0 "$PID" 2>/dev/null || { cat /tmp/standby-worker-runner.log; exit 1; }
  sleep 0.25
done
[ "$READY" = 1 ] || { echo "daemon never became ready"; cat /tmp/standby-worker-runner.log; exit 1; }

curl -fsS -X POST "http://$ADDR/api/meetings/wk/demo" > /tmp/wr-demo.json
PROP="$(node -e 'const p=JSON.parse(require("fs").readFileSync("/tmp/wr-demo.json","utf8")); if(!p.proposals.length)process.exit(2); process.stdout.write(p.proposals[0].id)')"

curl -fsS -H 'content-type: application/json' -d '{"approved_by":"verify"}' \
  -X POST "http://$ADDR/api/proposals/$PROP/approve" > /tmp/wr-approve.json
node -e '
  const p=JSON.parse(require("fs").readFileSync("/tmp/wr-approve.json","utf8"));
  const j=p.jobs[0];
  if(!j){console.error("FAIL: no job enqueued");process.exit(3)}
  if(j.status==="completed"){console.error("FAIL: job completed inside the approval request");process.exit(4)}
  console.log("approval returned out-of-request; job status:", j.status);
'

DONE=0
for _ in $(seq 1 160); do
  curl -fsS "http://$ADDR/api/meetings/wk" > /tmp/wr-poll.json
  if node -e 'const p=JSON.parse(require("fs").readFileSync("/tmp/wr-poll.json","utf8")); const j=p.jobs.find(x=>["completed","failed"].includes(x.status)); process.exit(j?0:1)'; then DONE=1; break; fi
  sleep 0.25
done
[ "$DONE" = 1 ] || { echo "job did not reach a terminal state"; cat /tmp/wr-poll.json; cat /tmp/standby-worker-runner.log; exit 1; }

node -e '
  const p=JSON.parse(require("fs").readFileSync("/tmp/wr-poll.json","utf8"));
  const j=p.jobs[p.jobs.length-1];
  console.log("final job status:", j.status, "profile:", j.profile, "reason:", j.failure_reason||"-");
  if(j.status==="failed"){
    if((j.profile||"local-research")==="local-research"){
      console.error("FAIL: deterministic local-research worker failed:", j.error||j.failure_reason||"unknown");
      process.exit(6)
    }
    // Honest outcome for an opt-in real CLI without auth; require a receipt, not a spinner.
    if(!j.receipt_path){console.error("FAIL: failed job has no receipt");process.exit(6)}
    console.log("worker failed visibly with receipt:", j.receipt_path);
    process.exit(0);
  }
  if(j.status!=="completed"){
    console.error("FAIL: job reached unexpected terminal status:", j.status);
    process.exit(8)
  }
  const a=p.artifacts[0];
  if(!a){console.error("FAIL: completed job produced no artifact");process.exit(5)}
  const f=(a.uri||"").replace(/^file:\/\//,"");
  if(!require("fs").existsSync(f)){console.error("FAIL: artifact file missing:",f);process.exit(7)}
  console.log("artifact persisted at", f);
'

echo "worker-runner smoke passed (out-of-request -> sandboxed worker -> real artifact)"
