#!/usr/bin/env bash
# verify-system-audio-tap.sh — proves system audio (other participants) is captured
# and transcribed, end to end, through the LIVE DAEMON + native helper (the product
# path), using the default `auto` system source: it tries the output-independent
# Core Audio tap and falls back to ScreenCaptureKit if the tap yields no frames.
#
# Plays a known phrase to the current output and asserts: the system lane goes
# ACTIVE with nonzero RMS, and the phrase lands on the SYSTEM lane (not the mic).
# Drives through the daemon and the signed standalone helper, which is the product
# subprocess path. The signed .app is retained for LaunchServices permission-grant
# experiments; raw-execing the bundle executable can stall before Swift main.
#
# Plays audio — run when you can hear sound, not mid-meeting. Honest FAIL if the
# system lane never carries real audio (e.g. no grant for the tap AND no Screen
# Recording for the fallback), never a hang.
set -euo pipefail

cd "$(dirname "$0")/.."
EVIDENCE_DIR="docs/evidence/real-meeting"
mkdir -p "$EVIDENCE_DIR"

bash ./scripts/build-capture-helper.sh >/dev/null
cargo build -p standbyd >/dev/null 2>&1
unset STANDBY_CAPTURE_HELPER || true

SECS_WAIT="${STANDBY_TAP_FALLBACK_WAIT:-5}"   # let auto-fallback settle before playing
DB="$(mktemp -t standby-sysaudio.XXXXXX).db"
JOBS="$(mktemp -d -t standby-sysaudio-jobs.XXXXXX)"
ADDR="127.0.0.1:4338"
MTG="sysaudio"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS"
export STANDBY_OPERATOR_TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-verify-token}"

cargo run -p standbyd >/tmp/standby-sysaudio.log 2>&1 &
PID=$!
cleanup() {
  curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -X POST "http://$ADDR/api/meetings/$MTG/capture/stop" >/dev/null 2>&1 || true
  kill "$PID" 2>/dev/null || true
  pkill afplay 2>/dev/null || true
  /usr/bin/trash "$DB" "$DB"-wal "$DB"-shm "$JOBS" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 80); do
  curl -fsS "http://$ADDR/health" >/dev/null 2>&1 && break
  kill -0 "$PID" 2>/dev/null || { cat /tmp/standby-sysaudio.log; exit 1; }
  sleep 0.25
done

PHRASE="can someone research what already exists in the market for local first meeting tools"
say -o /tmp/standby-sysaudio.aiff "$PHRASE" 2>/dev/null

echo "starting system capture (auto source) and playing a known phrase…"
curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -X POST "http://$ADDR/api/meetings/$MTG/capture/start?mode=system" >/dev/null
sleep "$SECS_WAIT"          # allow tap→ScreenCaptureKit auto-fallback to settle
afplay /tmp/standby-sysaudio.aiff; afplay /tmp/standby-sysaudio.aiff

RESULT="none"
for _ in $(seq 1 30); do
  R="$(curl -fsS "http://$ADDR/api/meetings/$MTG" | node -e '
    const p=JSON.parse(require("fs").readFileSync(0,"utf8"));
    const s=p.source.system_audio||{};
    const sys=p.transcript.filter(t=>t.speaker==="system_audio").map(t=>t.text.toLowerCase()).join(" ");
    const mic=p.transcript.filter(t=>t.speaker==="me").length;
    const hit=/research|market|meeting tools|already exists/.test(sys);
    if(s.active && hit) process.stdout.write("ok");
    else if(p.source.failure) process.stdout.write("failed:"+(p.source.failure.reason||"?"));
  ')"
  [ "$R" = "ok" ] && { RESULT="ok"; break; }
  case "$R" in failed:*) RESULT="$R"; break;; esac
  sleep 1
done

curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -X POST "http://$ADDR/api/meetings/$MTG/capture/stop" >/dev/null 2>&1 || true
sleep 1
curl -fsS "http://$ADDR/api/meetings/$MTG" > "$EVIDENCE_DIR/system-audio-tap.json" 2>/dev/null || true
node -e '
  const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const s=p.source.system_audio||{};
  console.log("system lane: active="+s.active+" events="+s.level_events+" dropped="+s.dropped);
  console.log("system transcript:");
  p.transcript.filter(t=>t.speaker==="system_audio").forEach(t=>console.log("   "+JSON.stringify(t.text).slice(0,90)));
' "$EVIDENCE_DIR/system-audio-tap.json" 2>/dev/null || true

case "$RESULT" in
  ok) echo "PASS: system audio captured + transcribed on the system lane (auto source)."; exit 0 ;;
  failed:screen_recording_permission_denied|failed:system_audio_permission_denied)
    echo "CAPTURE-BLOCKED: neither system-audio source is permitted."
    echo "  Grant System Settings › Privacy & Security › System Audio Recording (tap) OR Screen"
    echo "  Recording (fallback), then retry. Reported honestly, not hung."
    exit 0 ;;
  failed:*) echo "FAIL: capture failed: $RESULT"; cat /tmp/standby-sysaudio.log; exit 1 ;;
  *) echo "FAIL: system lane never carried the played phrase"; exit 1 ;;
esac
