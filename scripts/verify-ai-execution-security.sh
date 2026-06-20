#!/usr/bin/env bash
# Backlog 008 security proof: local mutation routes require an operator token,
# browser mutations must be same-origin, approval identity is server-bound, and
# network-capable worker dispatch requires per-job consent plus prompt redaction.
set -euo pipefail

cd "$(dirname "$0")/.."

EVIDENCE="${STANDBY_EVIDENCE_DIR:-docs/evidence/ai-execution-security}"
mkdir -p "$EVIDENCE"
export EVIDENCE

cargo build -p standbyd >/dev/null

TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-verify-token}"
ACTOR="${STANDBY_OPERATOR_ACTOR:-verified-operator}"

json_body() {
  node -e 'process.stdout.write(JSON.stringify(JSON.parse(process.argv[1])))' "$1"
}

expect_status() {
  local expected="$1"
  local output="$2"
  shift 2
  local status
  status="$(curl -sS -o "$output" -w "%{http_code}" "$@")"
  if [ "$status" != "$expected" ]; then
    echo "FAIL: expected HTTP $expected got $status for $*" >&2
    cat "$output" >&2 || true
    exit 1
  fi
}

expect_denied() {
  local output="$1"
  shift
  local status
  status="$(curl -sS -o "$output" -w "%{http_code}" "$@")"
  if [ "$status" != "401" ] && [ "$status" != "403" ]; then
    echo "FAIL: expected HTTP 401/403 got $status for $*" >&2
    cat "$output" >&2 || true
    exit 1
  fi
}

wait_ready() {
  local addr="$1" pid="$2" log="$3"
  for _ in $(seq 1 80); do
    if curl -fsS "http://$addr/health" >/dev/null 2>&1; then
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || { cat "$log"; return 1; }
    sleep 0.25
  done
  echo "daemon never became ready at $addr" >&2
  cat "$log" >&2
  return 1
}

seed_meeting() {
  local addr="$1" meeting="$2" cookie="$3"
  local body
  body="$(node -e 'process.stdout.write(JSON.stringify({events:process.argv.slice(1)}))' \
    '{"type":"source.started","mode":"mic+system"}' \
    '{"type":"segment.final","lane":"system_audio","speaker":"remote_1","text":"We need a short market map of local-first meeting agents and capture tools."}' \
    '{"type":"segment.final","lane":"microphone","speaker":"me","text":"Turn that into one approved research task with cited context."}')"
  curl -fsS -b "$cookie" -H "origin: http://$addr" -H 'content-type: application/json' \
    -d "$body" \
    -X POST "http://$addr/api/meetings/security/seed" >"$EVIDENCE/seed-response.json"
}

create_proposal() {
  local addr="$1" cookie="$2" output="$3"
  curl -fsS -b "$cookie" -H "origin: http://$addr" -H 'content-type: application/json' \
    -d '{"message":"Create a research proposal from this security test meeting","context_window":"recent","max_proposals":1}' \
    -X POST "http://$addr/api/meetings/security/proposal-requests" >"$output"
}

DB="$(mktemp -t standby-sec.XXXXXX).db"
JOBS="$(mktemp -d -t standby-sec-jobs.XXXXXX)"
ADDR="127.0.0.1:4330"
COOKIE="$(mktemp -t standby-sec-cookie.XXXXXX)"
LOG="/tmp/standby-ai-execution-security.log"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS"
export STANDBY_ENABLE_SEED=1 STANDBY_WORKER_PROFILE=local-research
export STANDBY_OPERATOR_TOKEN="$TOKEN" STANDBY_OPERATOR_ACTOR="$ACTOR"
export STANDBY_CAPTURE_HELPER=/nonexistent/standby-capture-helper

cargo run -p standbyd >"$LOG" 2>&1 &
PID=$!
cleanup() {
  kill "$PID" 2>/dev/null || true
  if [ -n "${PID2:-}" ]; then kill "$PID2" 2>/dev/null || true; fi
  rm -f "$DB" "$DB"-wal "$DB"-shm "$COOKIE"
  rm -rf "$JOBS"
  if [ -n "${DB2:-}" ]; then rm -f "$DB2" "$DB2"-wal "$DB2"-shm; fi
  if [ -n "${JOBS2:-}" ]; then rm -rf "$JOBS2"; fi
  if [ -n "${COOKIE2:-}" ]; then rm -f "$COOKIE2"; fi
}
trap cleanup EXIT

wait_ready "$ADDR" "$PID" "$LOG"

curl -fsS "http://$ADDR/api/meetings/security" >"$EVIDENCE/read-only-projection.json"

expect_denied "$EVIDENCE/unauth-capture-start.json" \
  -X POST "http://$ADDR/api/meetings/security/capture/start?mode=mic"
expect_denied "$EVIDENCE/unauth-capture-stop.json" \
  -X POST "http://$ADDR/api/meetings/security/capture/stop"
expect_denied "$EVIDENCE/unauth-proposal-request.json" \
  -H 'content-type: application/json' \
  -d '{"message":"unauthenticated proposal should fail","context_window":"recent","max_proposals":1}' \
  -X POST "http://$ADDR/api/meetings/security/proposal-requests"

curl -fsS -c "$COOKIE" "http://$ADDR/api/operator-session" >"$EVIDENCE/operator-session.json"
seed_meeting "$ADDR" "security" "$COOKIE"
create_proposal "$ADDR" "$COOKIE" "$EVIDENCE/proposal-response.json"
PROP="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if(!p.proposals.length) process.exit(2); process.stdout.write(p.proposals.at(-1).id)' "$EVIDENCE/proposal-response.json")"

expect_denied "$EVIDENCE/unauth-approve.json" \
  -H 'content-type: application/json' \
  -d '{"approved_by":"mallory"}' \
  -X POST "http://$ADDR/api/proposals/$PROP/approve"
expect_denied "$EVIDENCE/unauth-ignore.json" \
  -X POST "http://$ADDR/api/proposals/$PROP/ignore"
expect_status 403 "$EVIDENCE/hostile-origin-approve.json" \
  -b "$COOKIE" -H 'origin: http://evil.localhost' -H 'content-type: application/json' \
  -d '{"approved_by":"mallory"}' \
  -X POST "http://$ADDR/api/proposals/$PROP/approve"

curl -fsS -b "$COOKIE" -H "origin: http://$ADDR" -H 'content-type: application/json' \
  -d '{"approved_by":"mallory","prompt":"Run the approved local research task."}' \
  -X POST "http://$ADDR/api/proposals/$PROP/approve" >"$EVIDENCE/approval-response.json"

ACTOR="$ACTOR" PROP="$PROP" node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/approval-response.json`,"utf8"));
  const job=p.jobs.find(j=>j.proposal_id===process.env.PROP);
  if(!job){console.error("FAIL: approval did not enqueue a job");process.exit(1)}
  if(job.context.approved_by!==process.env.ACTOR){
    console.error("FAIL: approval actor spoofable", job.context.approved_by);
    process.exit(1)
  }
  if(job.status!=="queued"){console.error("FAIL: approval response should be queued, got", job.status);process.exit(1)}
'

DONE=0
for _ in $(seq 1 160); do
  curl -fsS "http://$ADDR/api/meetings/security" >"$EVIDENCE/final-local-projection.json"
  if PROP="$PROP" node -e 'const p=JSON.parse(require("fs").readFileSync(`${process.env.EVIDENCE}/final-local-projection.json`,"utf8")); const j=p.jobs.find(x=>x.proposal_id===process.env.PROP&&["completed","failed"].includes(x.status)); process.exit(j?0:1)'; then
    DONE=1
    break
  fi
  sleep 0.25
done
[ "$DONE" = 1 ] || { echo "local worker did not reach a terminal state"; cat "$EVIDENCE/final-local-projection.json"; exit 1; }

DB2="$(mktemp -t standby-sec-net.XXXXXX).db"
JOBS2="$(mktemp -d -t standby-sec-net-jobs.XXXXXX)"
ADDR2="127.0.0.1:4331"
COOKIE2="$(mktemp -t standby-sec-net-cookie.XXXXXX)"
LOG2="/tmp/standby-ai-execution-security-network.log"
STANDBY_DB="$DB2" STANDBY_ADDR="$ADDR2" STANDBY_JOBS_DIR="$JOBS2" \
  STANDBY_ENABLE_SEED=1 STANDBY_WORKER_PROFILE=claude-research \
  STANDBY_ALLOW_NETWORK_WORKER=1 STANDBY_OPERATOR_TOKEN="$TOKEN" \
  STANDBY_OPERATOR_ACTOR="$ACTOR" cargo run -p standbyd >"$LOG2" 2>&1 &
PID2=$!
wait_ready "$ADDR2" "$PID2" "$LOG2"

curl -fsS -c "$COOKIE2" "http://$ADDR2/api/operator-session" >"$EVIDENCE/network-operator-session.json"
seed_meeting "$ADDR2" "security" "$COOKIE2"
create_proposal "$ADDR2" "$COOKIE2" "$EVIDENCE/network-proposal-response.json"
NPROP="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if(!p.proposals.length) process.exit(2); process.stdout.write(p.proposals.at(-1).id)' "$EVIDENCE/network-proposal-response.json")"

curl -fsS -b "$COOKIE2" -H "origin: http://$ADDR2" -H 'content-type: application/json' \
  -d '{"approved_by":"mallory","prompt":"This network worker must not start without consent."}' \
  -X POST "http://$ADDR2/api/proposals/$NPROP/approve" >"$EVIDENCE/network-no-consent-approval.json"

NPROP="$NPROP" node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/network-no-consent-approval.json`,"utf8"));
  const job=p.jobs.find(j=>j.proposal_id===process.env.NPROP);
  if(!job){console.error("FAIL: network approval did not record a job");process.exit(1)}
  if(job.status!=="failed"){console.error("FAIL: network job without consent should fail before dispatch, got", job.status);process.exit(1)}
  if(job.failure_reason!=="consent_required"){console.error("FAIL: expected consent_required, got", job.failure_reason);process.exit(1)}
  if(p.events.some(e=>e.event_type==="agent_job.started" && e.payload_json.id===job.id)){
    console.error("FAIL: network job started without consent");process.exit(1)
  }
  if(p.events.some(e=>e.event_type==="agent_job.network_consent_granted" && e.payload_json.job_id===job.id)){
    console.error("FAIL: consent event should not exist for denied job");process.exit(1)
  }
'

cargo test -p standby-core network_worker_prompt_is_redacted_after_consent -- --nocapture \
  >"$EVIDENCE/redaction-test.txt"

node -e '
  const fs=require("fs");
  fs.writeFileSync(`${process.env.EVIDENCE}/verdict.json`, JSON.stringify({
    status: "pass",
    checked_at: new Date().toISOString(),
    claim: "AI execution is operator-authorized, origin-safe, consent-gated, and redacted before network dispatch.",
    receipts: fs.readdirSync(process.env.EVIDENCE).sort()
  }, null, 2) + "\n");
'

echo "ai-execution-security verification passed; evidence in $EVIDENCE/"
