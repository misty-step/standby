#!/usr/bin/env bash
# Capture proof before product wiring: run the native helper on both lanes,
# play a known phrase through system output, and assert the microphone lane
# produces real frames and the system-audio lane produces nonzero levels plus a
# real streaming transcript. Writes sanitized evidence (levels + transcript
# text only, never audio).
#
# Honest by construction: if a macOS permission is missing, the helper emits a
# source.failed event and the relevant lane stays silent, so this fails loudly
# with the exact missing permission instead of pretending to be live-ready.
set -euo pipefail

cd "$(dirname "$0")/.."
EVIDENCE_DIR="docs/evidence/real-meeting"
mkdir -p "$EVIDENCE_DIR"

HELPER="${STANDBY_CAPTURE_HELPER:-native/standby-capture-helper/build/standby-capture-helper}"
[ -x "$HELPER" ] || ./scripts/build-capture-helper.sh

OUT_FILE="$EVIDENCE_DIR/local-capture-smoke.jsonl"
"$HELPER" capture --mode mic+system --seconds 12 > "$OUT_FILE" 2>/dev/null &
HPID=$!
# First utterance lets ScreenCaptureKit finish spinning up; second is asserted.
say "testing standby local capture path"
say "the quick brown fox jumps over the lazy dog"
wait "$HPID"

node - "$OUT_FILE" <<'NODE'
const fs = require("fs");
const lines = fs.readFileSync(process.argv[2], "utf8").split("\n").filter(Boolean).map(JSON.parse);
const started = lines.some(o => o.type === "source.started");
const stopped = lines.some(o => o.type === "source.stopped");
const failed = lines.filter(o => o.type === "source.failed");
const micFrames = lines.filter(o => o.type === "audio.level" && o.lane === "microphone").length;
const sysMax = Math.max(0, ...lines.filter(o => o.type === "audio.level" && o.lane === "system_audio").map(o => o.rms));
const finals = lines.filter(o => o.type === "segment.final").map(o => o.text);
const sawTranscript = finals.some(t => /lazy dog|quick brown/i.test(t));
console.log(JSON.stringify({ started, stopped, micFrames, sysMax: Number(sysMax.toFixed(4)), finals }));

let ok = true;
const fail = (m) => { console.error("FAIL: " + m); ok = false; };
if (failed.length) fail("source.failed: " + failed.map(f => f.reason).join(", "));
if (!started) fail("no source.started event");
if (micFrames < 1) fail("microphone lane produced no frames");
if (sysMax <= 0.01) fail("system-audio lane silent (rms <= 0.01); screen-recording permission or routing?");
if (!sawTranscript) fail("no system-audio transcript of the played phrase");
process.exit(ok ? 0 : 1);
NODE

echo "local-capture smoke passed (real mic frames + system-audio transcript)"
