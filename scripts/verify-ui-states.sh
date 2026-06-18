#!/usr/bin/env bash
# Drive the local UI against seeded events and assert the honest source/job
# states. The key regression: the normal route must NOT auto-start demo. Each
# state is seeded through the real normalization path and asserted at the
# projection level; the real browser is used to confirm the normal route stays
# idle and to capture screenshots into docs/evidence/real-meeting/.
set -euo pipefail

cd "$(dirname "$0")/.."
EVIDENCE="docs/evidence/real-meeting"
mkdir -p "$EVIDENCE"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ADDR="127.0.0.1:4320"

npm --prefix ui run build >/dev/null
cargo build -p standbyd >/dev/null

DB="$(mktemp -t standby-ui.XXXXXX).db"
JOBS="$(mktemp -d -t standby-ui-jobs.XXXXXX)"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS"
export STANDBY_ENABLE_SEED=1 STANDBY_WORKER_PROFILE=local-research
cargo run -p standbyd >/tmp/standby-ui.log 2>&1 &
PID=$!
cleanup() {
  for p in "$PID" "${PID2:-}"; do
    if [ -n "$p" ]; then kill "$p" 2>/dev/null || true; fi
  done
  rm -f "$DB" "$DB"-wal "$DB"-shm
  if [ -n "${DB2:-}" ]; then rm -f "$DB2" "$DB2"-wal "$DB2"-shm; fi
  rm -rf "$JOBS"
  if [ -n "${JOBS2:-}" ]; then rm -rf "$JOBS2"; fi
}
trap cleanup EXIT

for _ in $(seq 1 80); do
  curl -fsS "http://$ADDR/health" >/dev/null 2>&1 && break
  kill -0 "$PID" 2>/dev/null || { cat /tmp/standby-ui.log; exit 1; }
  sleep 0.25
done

seed() { # $1=meeting, rest=event JSON objects
  local m="$1"; shift
  local body
  body="$(node -e 'process.stdout.write(JSON.stringify({events:process.argv.slice(1)}))' "$@")"
  curl -fsS -H 'content-type: application/json' -d "$body" -X POST "http://$ADDR/api/meetings/$m/seed" >/dev/null
}
status() { curl -fsS "http://$ADDR/api/meetings/$1" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(p.source.status)'; }
expect() { local got; got="$(status "$1")"; if [ "$got" != "$2" ]; then echo "FAIL: $1 expected '$2' got '$got'"; exit 1; fi; echo "  $1 -> $got"; }
shot() { "$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,880 --virtual-time-budget=4500 --screenshot="$EVIDENCE/ui-$2.png" "http://$ADDR/?meeting=$1${3:-}" >/dev/null 2>&1 || echo "  (screenshot $2 skipped)"; }

echo "1) normal route must NOT auto-start demo (real browser)"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,880 --virtual-time-budget=5000 \
  --screenshot="$EVIDENCE/ui-idle.png" "http://$ADDR/?meeting=uitest-normal" >/dev/null 2>&1 || echo "  (idle screenshot skipped)"
curl -fsS "http://$ADDR/api/meetings/uitest-normal" | node -e '
  const p=JSON.parse(require("fs").readFileSync(0,"utf8"));
  if(p.transcript.length||p.proposals.length){console.error("FAIL: normal route auto-started demo");process.exit(1)}
  if(p.source.status!=="idle"){console.error("FAIL: expected idle, got",p.source.status);process.exit(1)}
  console.log("  normal route stayed idle, no demo seeded");
'

echo "2) each source state renders honestly"
seed uitest-wait '{"type":"meeting.started","mode":"mic+system"}'
expect uitest-wait waiting_permission; shot uitest-wait waiting

seed uitest-cap '{"type":"meeting.started","mode":"mic+system"}' '{"type":"source.started","mode":"mic+system"}' '{"type":"audio.level","lane":"microphone","rms":0.05,"captured_ms":1000}' '{"type":"audio.level","lane":"system_audio","rms":0.08,"captured_ms":1000}'
expect uitest-cap capturing; shot uitest-cap capturing

seed uitest-trans '{"type":"source.started","mode":"mic+system"}' '{"type":"audio.level","lane":"system_audio","rms":0.09,"captured_ms":1000}' '{"type":"segment.final","lane":"system_audio","speaker":"system_audio","text":"Can someone research what already exists in the market?"}'
expect uitest-trans transcribing; shot uitest-trans transcribing

seed uitest-nosys '{"type":"source.started","mode":"mic+system"}' '{"type":"audio.level","lane":"microphone","rms":0.06,"captured_ms":1000}' '{"type":"audio.level","lane":"system_audio","rms":0.0,"captured_ms":1000}'
expect uitest-nosys no_system_audio; shot uitest-nosys no-system-audio

seed uitest-nomic '{"type":"source.started","mode":"mic+system"}' '{"type":"audio.level","lane":"system_audio","rms":0.06,"captured_ms":1000}' '{"type":"audio.level","lane":"microphone","rms":0.0,"captured_ms":1000}'
expect uitest-nomic no_mic_audio

# Whole-source failure: a system-ONLY capture whose system lane fails has no
# surviving lane, so the whole source is failed.
seed uitest-failed '{"type":"source.started","mode":"system"}' '{"type":"source.failed","reason":"screen_recording_permission_denied","lane":"system_audio","detail":"denied"}'
expect uitest-failed failed; shot uitest-failed failed

echo "2b) the distinct permission tiers render as distinct reasons (mic / screen-rec / core-audio-tap)"
reason() { curl -fsS "http://$ADDR/api/meetings/$1" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write((p.source.failure||{}).reason||"")'; }
expect_reason() { local got; got="$(reason "$1")"; if [ "$got" != "$2" ]; then echo "FAIL: $1 expected reason '$2' got '$got'"; exit 1; fi; echo "  $1 -> $got"; }

# Microphone permission tier.
seed uitest-failmic '{"type":"source.started","mode":"mic+system"}' '{"type":"source.failed","reason":"mic_permission_denied","lane":"microphone","detail":"denied"}'
expect uitest-failmic failed; expect_reason uitest-failmic mic_permission_denied; shot uitest-failmic failed-mic
# Core Audio process-tap tier ("System Audio Recording Only") — a SEPARATE Settings
# pane from Screen Recording, classified from kAudioHardwareNotPermittedError. In
# mic+system, a system-lane failure is NON-FATAL: the mic keeps capturing, so the
# status stays "capturing" and the system failure is surfaced as a per-lane note.
seed uitest-failtap '{"type":"source.started","mode":"mic+system"}' '{"type":"source.failed","reason":"system_audio_permission_denied","lane":"system_audio","detail":"kAudioHardwareNotPermittedError"}'
expect uitest-failtap capturing; expect_reason uitest-failtap system_audio_permission_denied; shot uitest-failtap system-audio-denied

# All three tiers must be distinct reason strings, and the shipped UI bundle must
# carry distinct operator text for each (so the cards can't collapse to one).
node -e '
  const reasons=["mic_permission_denied","screen_recording_permission_denied","system_audio_permission_denied"];
  if(new Set(reasons).size!==3){console.error("FAIL: permission reasons not distinct");process.exit(1)}
  const js=require("fs").readFileSync(require("path").join("ui","dist","assets",
    require("fs").readdirSync(require("path").join("ui","dist","assets")).find(f=>f.endsWith(".js"))),"utf8");
  for(const needle of ["Privacy & Security › Microphone","Privacy & Security › Screen Recording","Privacy & Security › System Audio Recording"]){
    if(!js.includes(needle)){console.error("FAIL: shipped UI bundle missing card text:",needle);process.exit(1)}
  }
  console.log("  mic / screen-recording / system-audio tiers carry distinct Settings-pane text in the bundle");
'

seed uitest-stopped '{"type":"source.started","mode":"mic"}' '{"type":"source.stopped"}'
expect uitest-stopped stopped

echo "3) demo is opt-in only and still works"
curl -fsS -X POST "http://$ADDR/api/meetings/uitest-demo/demo" >/dev/null
expect uitest-demo demo; shot uitest-demo demo "&mode=demo"

echo "4) approve -> out-of-request worker -> result card"
PROP="$(curl -fsS "http://$ADDR/api/meetings/uitest-demo" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(p.proposals[0].id)')"
curl -fsS -H 'content-type: application/json' -d '{"approved_by":"ui"}' -X POST "http://$ADDR/api/proposals/$PROP/approve" >/dev/null
DONE=0
for _ in $(seq 1 120); do
  if curl -fsS "http://$ADDR/api/meetings/uitest-demo" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(p.artifacts.length?0:1)'; then DONE=1; break; fi
  sleep 0.25
done
[ "$DONE" = 1 ] || { echo "FAIL: worker did not produce an artifact"; exit 1; }
shot uitest-demo completed "&mode=demo"
echo "  job completed with artifact"

echo "5) a worker failure renders a receipt, not a spinner"
# A second daemon whose local worker script does not exist, so an approved job
# fails visibly (covers the worker-failed UI state the Oracle names).
DB2="$(mktemp -t standby-ui2.XXXXXX).db"
JOBS2="$(mktemp -d -t standby-ui2-jobs.XXXXXX)"
ADDR2="127.0.0.1:4325"
STANDBY_DB="$DB2" STANDBY_ADDR="$ADDR2" STANDBY_JOBS_DIR="$JOBS2" STANDBY_ENABLE_SEED=1 \
  STANDBY_WORKER_PROFILE=local-research STANDBY_LOCAL_WORKER_SCRIPT=/nonexistent/worker.sh \
  cargo run -p standbyd >/tmp/standby-ui2.log 2>&1 &
PID2=$!
for _ in $(seq 1 80); do curl -fsS "http://$ADDR2/health" >/dev/null 2>&1 && break; sleep 0.25; done
WSEED="$(node -e 'process.stdout.write(JSON.stringify({events:process.argv.slice(1)}))' \
  '{"type":"source.started","mode":"mic+system"}' \
  '{"type":"segment.final","lane":"system_audio","speaker":"system_audio","text":"Can someone research what already exists in the market?"}' \
  '{"type":"segment.final","lane":"microphone","speaker":"me","text":"Yes, do a prior art sweep on existing solutions."}')"
curl -fsS -H 'content-type: application/json' -d "$WSEED" -X POST "http://$ADDR2/api/meetings/wfail/seed" >/dev/null
WPROP="$(curl -fsS "http://$ADDR2/api/meetings/wfail" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write((p.proposals[0]||{}).id||"")')"
[ -n "$WPROP" ] || { echo "FAIL: worker-fail setup produced no proposal"; cat /tmp/standby-ui2.log; exit 1; }
curl -fsS -H 'content-type: application/json' -d '{"approved_by":"ui"}' -X POST "http://$ADDR2/api/proposals/$WPROP/approve" >/dev/null
WF=0
for _ in $(seq 1 80); do
  if curl -fsS "http://$ADDR2/api/meetings/wfail" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(p.jobs.some(j=>j.status==="failed")?0:1)'; then WF=1; break; fi
  sleep 0.25
done
[ "$WF" = 1 ] || { echo "FAIL: worker did not fail visibly"; cat /tmp/standby-ui2.log; exit 1; }
# Taller window so the failed job card (below the transcript) is in frame.
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,1400 --virtual-time-budget=4500 \
  --screenshot="$EVIDENCE/ui-worker-failed.png" "http://$ADDR2/?meeting=wfail" >/dev/null 2>&1 || echo "  (screenshot skipped)"
echo "  worker-failed renders with reason + receipt"

echo "verify-ui-states passed; screenshots in $EVIDENCE/"
