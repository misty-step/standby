#!/usr/bin/env bash
# Visual QA for the operational meeting console. Drives seeded daemon state,
# captures desktop/mobile screenshots through Chrome DevTools Protocol, and
# fails on browser console or network errors.
set -euo pipefail

cd "$(dirname "$0")/.."

EVIDENCE="${STANDBY_EVIDENCE_DIR:-docs/evidence/ui-visual-qa}"
rm -rf "$EVIDENCE"
mkdir -p "$EVIDENCE"
export EVIDENCE

if [ -z "${CHROME:-}" ]; then
  for candidate in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    google-chrome \
    chromium \
    chromium-browser; do
    if [ -x "$candidate" ]; then
      CHROME="$candidate"
      break
    fi
    if command -v "$candidate" >/dev/null 2>&1; then
      CHROME="$(command -v "$candidate")"
      break
    fi
  done
fi
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$CHROME" ]; then
  echo "FAIL: Google Chrome not found at $CHROME; cannot run visual QA" >&2
  exit 2
fi
export CHROME

npm --prefix ui run build >/dev/null
cargo build -p standbyd >/dev/null

ADDR="127.0.0.1:4330"
DB="$(mktemp -t standby-ui-visual.XXXXXX).db"
JOBS="$(mktemp -d -t standby-ui-visual-jobs.XXXXXX)"
FAKE_BIN="$(mktemp -d -t standby-fake-opencode-bin.XXXXXX)"
ln -s "$PWD/scripts/fixtures/fake-opencode.sh" "$FAKE_BIN/opencode"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS"
export STANDBY_ENABLE_SEED=1
export STANDBY_OPERATOR_TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-verify-token}"
export PATH="$FAKE_BIN:$PATH"

cargo run -p standbyd >/tmp/standby-ui-visual.log 2>&1 &
PID=$!

cleanup() {
  for p in "$PID" "${PID2:-}"; do
    if [ -n "${p:-}" ]; then kill "$p" 2>/dev/null || true; fi
  done
  rm -f "$DB" "$DB"-wal "$DB"-shm
  rm -rf "$JOBS" "$FAKE_BIN"
  if [ -n "${DB2:-}" ]; then rm -f "$DB2" "$DB2"-wal "$DB2"-shm; fi
  if [ -n "${JOBS2:-}" ]; then rm -rf "$JOBS2"; fi
}
trap cleanup EXIT

wait_health() {
  local addr="$1"
  local log="$2"
  for _ in $(seq 1 100); do
    if curl -fsS "http://$addr/health" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  echo "FAIL: daemon never became healthy on $addr" >&2
  cat "$log" >&2
  exit 3
}

seed() {
  local addr="$1"
  local meeting="$2"
  shift 2
  local body
  body="$(node -e 'process.stdout.write(JSON.stringify({events:process.argv.slice(1)}))' "$@")"
  curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" \
    -H 'content-type: application/json' \
    -d "$body" \
    -X POST "http://$addr/api/meetings/$meeting/seed" >/dev/null
}

projection() {
  curl -fsS "http://$1/api/meetings/$2"
}

capture_pair() {
  local addr="$1"
  local meeting="$2"
  local section="$3"
  local label="$4"
  local query="?meeting=$meeting"
  if [ "$section" != "meeting" ]; then query="$query&section=$section"; fi
  local url="http://$addr/$query"
  node scripts/capture-ui-state.mjs "$url" "$EVIDENCE/$label-desktop.png" "$EVIDENCE/$label-desktop.html" "$EVIDENCE/$label-desktop-report.json" 1280 880 desktop
  node scripts/capture-ui-state.mjs "$url" "$EVIDENCE/$label-mobile.png" "$EVIDENCE/$label-mobile.html" "$EVIDENCE/$label-mobile-report.json" 390 920 mobile
}

wait_for_projection() {
  local addr="$1"
  local meeting="$2"
  local expression="$3"
  local label="$4"
  for _ in $(seq 1 120); do
    if projection "$addr" "$meeting" | node -e "const p=JSON.parse(require('fs').readFileSync(0,'utf8')); process.exit(($expression)?0:1)"; then
      return 0
    fi
    sleep 0.25
  done
  echo "FAIL: timed out waiting for $label" >&2
  projection "$addr" "$meeting" >&2 || true
  exit 4
}

wait_health "$ADDR" /tmp/standby-ui-visual.log

capture_pair "$ADDR" "qa-idle" "meeting" "idle"

seed "$ADDR" "qa-proposal" \
  '{"type":"source.started","mode":"mic+system"}' \
  '{"type":"diarization.segment.final","speaker":"SPEAKER_00","text":"Can someone compare the market for private meeting assistants?","start_ms":0,"end_ms":2100}' \
  '{"type":"diarization.segment.final","speaker":"SPEAKER_01","text":"Please include local-first and open-source options.","start_ms":2200,"end_ms":4200}'
wait_for_projection "$ADDR" "qa-proposal" "p.proposals.some((proposal)=>proposal.status==='proposed')" "proposal card"
capture_pair "$ADDR" "qa-proposal" "meeting" "proposal"
capture_pair "$ADDR" "qa-proposal" "notes" "notes"
capture_pair "$ADDR" "qa-proposal" "audio" "audio"

seed "$ADDR" "qa-running" \
  '{"type":"source.started","mode":"mic+system"}' \
  '{"type":"segment.final","lane":"system_audio","speaker":"remote_1","text":"We need a market sweep for local-first meeting agents."}'
curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"message":"WAIT_FOR_RELEASE_MARKER Research the local-first meeting assistant market from this call.","context_window":"recent","max_proposals":1}' \
  -X POST "http://$ADDR/api/meetings/qa-running/proposal-requests" >/dev/null
RUN_PROP="$(projection "$ADDR" "qa-running" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8")); process.stdout.write((p.proposals.find((proposal)=>proposal.status==="proposed")||{}).id||"")')"
[ -n "$RUN_PROP" ] || { echo "FAIL: no proposal for running job"; exit 5; }
curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"approved_by":"visual-qa"}' \
  -X POST "http://$ADDR/api/proposals/$RUN_PROP/approve" >/dev/null
wait_for_projection "$ADDR" "qa-running" "p.jobs.some((job)=>job.status==='running')" "running job"
capture_pair "$ADDR" "qa-running" "meeting" "running"

STARTED=""
for _ in $(seq 1 120); do
  STARTED="$(find "$JOBS" -name started.marker -print -quit)"
  [ -n "$STARTED" ] && break
  sleep 0.25
done
[ -n "$STARTED" ] || { echo "FAIL: fake opencode never reached wait marker"; exit 6; }
touch "$(dirname "$STARTED")/release.marker"
wait_for_projection "$ADDR" "qa-running" "p.jobs.some((job)=>job.status==='completed') && p.artifacts.length > 0" "completed job"
capture_pair "$ADDR" "qa-running" "meeting" "completed"
capture_pair "$ADDR" "qa-running" "jobs" "jobs"

DB2="$(mktemp -t standby-ui-visual-fail.XXXXXX).db"
JOBS2="$(mktemp -d -t standby-ui-visual-fail-jobs.XXXXXX)"
ADDR2="127.0.0.1:4331"
PATH="/usr/bin:/bin" STANDBY_DB="$DB2" STANDBY_ADDR="$ADDR2" STANDBY_JOBS_DIR="$JOBS2" STANDBY_ENABLE_SEED=1 \
  STANDBY_OPERATOR_TOKEN="$STANDBY_OPERATOR_TOKEN" \
  target/debug/standbyd >/tmp/standby-ui-visual-fail.log 2>&1 &
PID2=$!
wait_health "$ADDR2" /tmp/standby-ui-visual-fail.log

seed "$ADDR2" "qa-failed" \
  '{"type":"source.started","mode":"mic+system"}' \
  '{"type":"segment.final","lane":"system_audio","speaker":"remote_1","text":"Can someone research meeting assistant competitors?"}' \
  '{"type":"segment.final","lane":"microphone","speaker":"me","text":"Yes, turn that into a task."}'
FAIL_PROP="$(projection "$ADDR2" "qa-failed" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8")); process.stdout.write((p.proposals.find((proposal)=>proposal.status==="proposed")||{}).id||"")')"
[ -n "$FAIL_PROP" ] || { echo "FAIL: no proposal for failed worker state"; exit 7; }
curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"approved_by":"visual-qa"}' \
  -X POST "http://$ADDR2/api/proposals/$FAIL_PROP/approve" >/dev/null
wait_for_projection "$ADDR2" "qa-failed" "p.jobs.some((job)=>job.status==='failed')" "failed job"
capture_pair "$ADDR2" "qa-failed" "meeting" "failed"

grep -q "Speaker 1" "$EVIDENCE/proposal-desktop.html" || { echo "FAIL: proposal DOM missing Speaker 1"; exit 8; }
grep -q "Speaker 2" "$EVIDENCE/proposal-desktop.html" || { echo "FAIL: proposal DOM missing Speaker 2"; exit 9; }
grep -q "Running" "$EVIDENCE/running-desktop.html" || { echo "FAIL: running DOM missing worker state"; exit 10; }
grep -q "Completed" "$EVIDENCE/completed-desktop.html" || { echo "FAIL: completed DOM missing worker state"; exit 11; }
grep -Eq "(Meeting follow-up task|Operator-requested task) result" "$EVIDENCE/completed-desktop.html" || { echo "FAIL: completed DOM missing result"; exit 12; }
grep -q "Blocked by the sandbox" "$EVIDENCE/failed-desktop.html" || { echo "FAIL: failed DOM missing visible worker failure"; exit 13; }
grep -q "opencode" "$EVIDENCE/failed-desktop.html" || { echo "FAIL: failed DOM missing worker command detail"; exit 18; }
grep -q "mobile-section-tabs" "$EVIDENCE/proposal-mobile.html" || { echo "FAIL: mobile DOM missing section tabs"; exit 14; }
grep -q "Agent jobs" "$EVIDENCE/jobs-desktop.html" || { echo "FAIL: jobs panel not captured"; exit 15; }
grep -q "Capture lanes" "$EVIDENCE/audio-desktop.html" || { echo "FAIL: audio panel not captured"; exit 16; }

node -e '
  const fs = require("fs");
  const dir = process.env.EVIDENCE;
  const reports = fs.readdirSync(dir).filter((file) => file.endsWith("-report.json")).sort();
  const failed = reports.map((file) => [file, JSON.parse(fs.readFileSync(`${dir}/${file}`, "utf8"))]).filter(([, report]) => report.status !== "pass");
  if (failed.length) {
    console.error("FAIL: browser reports were not clean");
    for (const [file, report] of failed) console.error(file, JSON.stringify(report));
    process.exit(17);
  }
  fs.writeFileSync(`${dir}/verdict.json`, JSON.stringify({
    status: "pass",
    checked_at: new Date().toISOString(),
    claim: "Standby UI renders the main operational states across desktop and mobile without console or network errors.",
    states: ["idle", "proposal", "notes", "audio", "running", "completed", "jobs", "failed"],
    reports,
    receipts: fs.readdirSync(dir).sort()
  }, null, 2) + "\n");
'

echo "ui visual QA passed; evidence in $EVIDENCE/"
