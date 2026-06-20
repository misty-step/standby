#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Rust unit + integration tests (includes the transcript-fixture replay and the
# worker-sandbox containment negative test).
cargo test --workspace
bash ./scripts/verify-model-proposals.sh

# The native capture helper compiles, and transcription is real and unstubbed:
# a deterministic on-device Apple Speech proof. (Live mic/system capture and the
# browser UI-state checks are separate, permission/operator-gated smokes.)
bash ./scripts/build-capture-helper.sh

# TCC-persistence guard: the daemon-spawned helper must carry a STABLE signature,
# never ad-hoc. Ad-hoc cdhash changes every build, so macOS forgets the Microphone
# and System-Audio grants on each rebuild — the dogfood trap. Fail loudly here.
SHIPPED_HELPER="native/standby-capture-helper/build/standby-capture-helper"
LAUNCHSERVICES_APP="native/StandbyCapture.app"
for artifact in "$SHIPPED_HELPER" "$LAUNCHSERVICES_APP"; do
  if codesign -dvv "$artifact" 2>&1 | grep -q "Signature=adhoc"; then
    echo "verify: helper artifact $artifact is ad-hoc signed; TCC grants would" >&2
    echo "  evaporate on rebuild. Build with a stable identity (see build-capture-helper.sh)." >&2
    exit 1
  fi
  codesign -dvv "$artifact" 2>&1 \
    | grep -E "Authority=|TeamIdentifier=|Identifier=" \
    | while IFS= read -r line; do
        printf '  signing (%s): %s\n' "$artifact" "$line"
      done || true
done

bash ./scripts/verify-real-transcriber-smoke.sh

npm --prefix ui run build
cargo build -p standbyd

# New proposal-request public API: operator message + transcript context creates
# an evented proposal card, then approval runs the existing out-of-request worker
# path. This is API-only, so it belongs in the default gate; browser UI smokes
# remain separate. Write transient evidence so the default gate does not dirty
# tracked docs evidence.
VERIFY_EVIDENCE="$(mktemp -d -t standby-verify-evidence.XXXXXX)"
STANDBY_EVIDENCE_DIR="$VERIFY_EVIDENCE/manual-proposal" bash ./scripts/verify-manual-proposal-request.sh
STANDBY_EVIDENCE_DIR="$VERIFY_EVIDENCE/ai-execution-security" bash ./scripts/verify-ai-execution-security.sh

STANDBY_DB="$(mktemp -t standby-smoke.XXXXXX.db)"
STANDBY_JOBS_DIR="$(mktemp -d -t standby-smoke-jobs.XXXXXX)"
export STANDBY_DB STANDBY_JOBS_DIR
export STANDBY_ADDR="127.0.0.1:4318"
export STANDBY_WORKER_PROFILE="local-research"
export STANDBY_OPERATOR_TOKEN="standby-verify-token"

cargo run -p standbyd > /tmp/standby-smoke.log 2>&1 &
PID="$!"
cleanup() {
  kill "$PID" >/dev/null 2>&1 || true
  rm -f "$STANDBY_DB" "$STANDBY_DB"-wal "$STANDBY_DB"-shm
  rm -rf "$STANDBY_JOBS_DIR"
}
trap cleanup EXIT

READY=0
for _ in $(seq 1 80); do
  if ! kill -0 "$PID" >/dev/null 2>&1; then
    cat /tmp/standby-smoke.log
    exit 1
  fi
  if curl -fsS "http://$STANDBY_ADDR/health" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.25
done

if [ "$READY" -ne 1 ]; then
  cat /tmp/standby-smoke.log
  exit 1
fi

curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" \
  -X POST "http://$STANDBY_ADDR/api/meetings/demo/demo" >/tmp/standby-demo.json
PROPOSAL_ID="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync("/tmp/standby-demo.json","utf8")); if (!p.proposals.length) process.exit(2); process.stdout.write(p.proposals[0].id);')"
# Approval is deterministic and out-of-request: it enqueues a job and returns
# before the worker runs.
curl -fsS -H 'content-type: application/json' \
  -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" \
  -d '{"approved_by":"verify"}' \
  -X POST "http://$STANDBY_ADDR/api/proposals/$PROPOSAL_ID/approve" >/tmp/standby-approved.json
node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync("/tmp/standby-approved.json","utf8")); if (!p.jobs.length) process.exit(3); if (p.jobs[0].status==="completed") { console.error("job completed inside approval request"); process.exit(4); }'

# The background worker then completes the job and persists a real artifact.
DONE=0
for _ in $(seq 1 160); do
  curl -fsS "http://$STANDBY_ADDR/api/meetings/demo" >/tmp/standby-poll.json
  if node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync("/tmp/standby-poll.json","utf8")); const j=p.jobs.find((x)=>x.status==="completed"); process.exit(j&&p.artifacts.length?0:1)'; then
    DONE=1
    break
  fi
  sleep 0.25
done
if [ "$DONE" -ne 1 ]; then
  echo "worker job did not complete with an artifact"
  cat /tmp/standby-poll.json
  cat /tmp/standby-smoke.log
  exit 5
fi

echo "standby verification passed"
