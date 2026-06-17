#!/usr/bin/env bash
# Capture proof before product wiring. Runs the native helper on both lanes,
# plays a known phrase through system output, and verifies the microphone lane
# produces real frames. The system-audio lane (ScreenCaptureKit) additionally
# needs Screen-Recording permission for the host process; when that is granted it
# asserts a real streaming transcript, and when it is not it reports an honest
# CAPTURE-BLOCKED (never a hang — the helper has an 8s watchdog).
set -euo pipefail

cd "$(dirname "$0")/.."
EVIDENCE_DIR="docs/evidence/real-meeting"
mkdir -p "$EVIDENCE_DIR"

HELPER="${STANDBY_CAPTURE_HELPER:-native/standby-capture-helper/build/standby-capture-helper}"
[ -x "$HELPER" ] || ./scripts/build-capture-helper.sh

OUT_FILE="$EVIDENCE_DIR/local-capture-smoke.jsonl"
"$HELPER" capture --mode mic+system --seconds 12 > "$OUT_FILE" 2>/dev/null &
HPID=$!
say "testing standby local capture path"
say "the quick brown fox jumps over the lazy dog"
# Safety net: the helper self-terminates via --seconds or the watchdog; ensure it
# is gone so wait returns.
( for _ in $(seq 1 50); do kill -0 "$HPID" 2>/dev/null || break; sleep 0.3; done; kill "$HPID" 2>/dev/null || true ) >/dev/null 2>&1 || true
wait "$HPID" 2>/dev/null || true

node - "$OUT_FILE" <<'NODE'
const fs = require("fs");
const lines = fs.readFileSync(process.argv[2], "utf8").split("\n").filter(Boolean).map(JSON.parse);
const micFrames = lines.filter(o => o.type === "audio.level" && o.lane === "microphone").length;
const sysMax = Math.max(0, ...lines.filter(o => o.type === "audio.level" && o.lane === "system_audio").map(o => o.rms));
const finals = lines.filter(o => o.type === "segment.final").map(o => o.text);
const sysTranscript = finals.some(t => /lazy dog|quick brown/i.test(t));
const screenBlocked = lines.some(o => o.type === "source.failed" && o.reason === "screen_recording_permission_denied");
console.log(JSON.stringify({ micFrames, sysMax: Number(sysMax.toFixed(4)), finals, screenBlocked }));

if (micFrames < 1) { console.error("FAIL: microphone lane produced no frames"); process.exit(1); }
if (sysTranscript) { console.log("PASS: real mic frames + real system-audio streaming transcript"); process.exit(0); }
if (screenBlocked) {
  console.log("CAPTURE-BLOCKED: mic lane verified. System audio needs Screen-Recording permission");
  console.log("  for the host process — grant it in System Settings > Privacy & Security > Screen");
  console.log("  Recording and retry. (Helper failed honestly instead of hanging.)");
  process.exit(0);
}
console.error("FAIL: system-audio lane produced neither a transcript nor an honest permission failure");
process.exit(1);
NODE

echo "local-capture smoke done"
