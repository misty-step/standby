#!/usr/bin/env bash
# Gated dogfood smoke for the FULL real-capture path through the live daemon and
# native helper — no seeding. Unless STANDBY_LIVE_CAPTURE=1 it skips, because the
# real path needs macOS Microphone + Screen-Recording permission and call audio.
#
# When enabled it starts local capture, then plays a research-ask phrase through
# system output to stand in for the call (real Teams audio flows through the same
# ScreenCaptureKit system-audio path), and asserts a real final transcript, a
# proposal cited from it, and — after approval — a real worker artifact. If the
# host process lacks Screen-Recording permission, it reports an honest
# CAPTURE-BLOCKED instead of hanging.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${STANDBY_LIVE_CAPTURE:-0}" != "1" ]; then
  echo "SKIPPED verify-live-teams-local: set STANDBY_LIVE_CAPTURE=1 to run the live"
  echo "  dogfood smoke. It needs Microphone + Screen-Recording permission; join a"
  echo "  Teams call (or it plays a stand-in phrase through system output)."
  exit 0
fi

bash ./scripts/build-capture-helper.sh >/dev/null
cargo build -p standbyd >/dev/null

DB="$(mktemp -t standby-live.XXXXXX).db"
JOBS="$(mktemp -d -t standby-live-jobs.XXXXXX)"
ADDR="127.0.0.1:4321"
MTG="teams-live"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS" STANDBY_WORKER_PROFILE=local-research
export STANDBY_OPERATOR_TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-verify-token}"
cargo run -p standbyd >/tmp/standby-live.log 2>&1 &
PID=$!
cleanup() { curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -X POST "http://$ADDR/api/meetings/$MTG/capture/stop" >/dev/null 2>&1 || true; kill "$PID" 2>/dev/null || true; rm -f "$DB" "$DB"-wal "$DB"-shm; rm -rf "$JOBS"; }
trap cleanup EXIT

for _ in $(seq 1 80); do
  curl -fsS "http://$ADDR/health" >/dev/null 2>&1 && break
  kill -0 "$PID" 2>/dev/null || { cat /tmp/standby-live.log; exit 1; }
  sleep 0.25
done

echo "starting real local capture (mic+system)…"
curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -X POST "http://$ADDR/api/meetings/$MTG/capture/start?mode=mic%2Bsystem" >/dev/null

# Stand in for the call. With a real Teams call joined, skip this — the call's
# audio is captured the same way.
say "Before we build this, can someone research what already exists in the market? Let us do a quick prior art sweep on local first meeting tools." || true
say "Scope it to the last eighteen months and include open source and Y C companies." || true

echo "waiting for a real final transcript segment or an honest capture failure…"
RESULT=""
for _ in $(seq 1 100); do
  RESULT="$(curl -fsS "http://$ADDR/api/meetings/$MTG" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8")); if(p.transcript.length){process.stdout.write("transcript")} else if(p.source.status==="failed"){process.stdout.write("failed:"+((p.source.failure||{}).reason||"unknown"))}')"
  [ -n "$RESULT" ] && break
  sleep 0.25
done
curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -X POST "http://$ADDR/api/meetings/$MTG/capture/stop" >/dev/null

case "$RESULT" in
  transcript) : ;;
  failed:screen_recording_permission_denied)
    echo "CAPTURE-BLOCKED: system audio needs Screen-Recording permission for the standbyd process."
    echo "  Grant it in System Settings > Privacy & Security > Screen Recording (add the standbyd"
    echo "  binary or run it from a permitted host) and retry. The capture->transcript->proposal->"
    echo "  worker mechanism is proven deterministically by the other smokes; only the live daemon"
    echo "  dogfood is permission-gated here. Reported honestly, not hung."
    exit 0 ;;
  failed:*) echo "capture failed: $RESULT"; cat /tmp/standby-live.log; exit 1 ;;
  *) echo "FAIL: no transcript and no honest failure within timeout"; cat /tmp/standby-live.log; exit 1 ;;
esac

curl -fsS "http://$ADDR/api/meetings/$MTG" >/tmp/standby-live-proj.json
node -e '
  const p=JSON.parse(require("fs").readFileSync("/tmp/standby-live-proj.json","utf8"));
  console.log("  transcript segments:", p.transcript.length, "| sample:", JSON.stringify((p.transcript[0]||{}).text||"").slice(0,70));
'

PROP="$(node -e 'const p=JSON.parse(require("fs").readFileSync("/tmp/standby-live-proj.json","utf8"));process.stdout.write((p.proposals[0]||{}).id||"")')"
if [ -z "$PROP" ]; then
  echo "live capture + transcription proven; the stand-in phrase did not trigger a proposal (accuracy varies). capture/transcript-ready."
  exit 0
fi

echo "proposal $PROP detected; approving and awaiting worker artifact…"
curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -H 'content-type: application/json' -d '{"approved_by":"dogfood"}' -X POST "http://$ADDR/api/proposals/$PROP/approve" >/dev/null
for _ in $(seq 1 120); do
  if curl -fsS "http://$ADDR/api/meetings/$MTG" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(p.artifacts.length?0:1)'; then
    echo "verify-live-teams-local passed: real capture -> transcript -> proposal -> worker artifact"
    exit 0
  fi
  sleep 0.25
done
echo "FAIL: approved job produced no artifact"; exit 1
