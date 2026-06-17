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
cleanup() { kill "$PID" 2>/dev/null || true; rm -f "$DB" "$DB"-wal "$DB"-shm; rm -rf "$JOBS"; }
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

seed uitest-failed '{"type":"source.started","mode":"mic+system"}' '{"type":"source.failed","reason":"screen_recording_permission_denied","lane":"system_audio","detail":"denied"}'
expect uitest-failed failed; shot uitest-failed failed

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

echo "verify-ui-states passed; screenshots in $EVIDENCE/"
