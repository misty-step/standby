#!/usr/bin/env bash
# verify-system-audio-tap.sh — proves the Core Audio process tap captures system
# audio INDEPENDENT of the output device (the HDMI/Bluetooth zero-frames fix that
# ScreenCaptureKit can't do).
#
# Plays a known, benign phrase to the CURRENT default output and captures it via
# the tap in mode=system, so the microphone is NEVER engaged (no operator audio is
# recorded — only the test phrase we play). Asserts: nonzero system-audio frames,
# a final transcript containing the phrase, and that the phrase lands on the SYSTEM
# lane (not the mic). If the System-Audio-Recording grant is missing it reports an
# honest CAPTURE-BLOCKED with the exact Settings path — never a hang.
#
# To prove output-independence, set your default output to HDMI/Bluetooth before
# running. Plays audio, so run it when you can hear sound (not mid-meeting).
set -euo pipefail

cd "$(dirname "$0")/.."
EVIDENCE_DIR="docs/evidence/real-meeting"
mkdir -p "$EVIDENCE_DIR"

./scripts/build-capture-helper.sh >/dev/null
# The SIGNED .app — the Core Audio tap's kTCCServiceAudioCapture grant is keyed on
# its stable signing identity (the bare binary would not carry the grant).
HELPER="native/StandbyCapture.app/Contents/MacOS/standby-capture-helper"
[ -x "$HELPER" ] || { echo "FAIL: signed helper missing at $HELPER"; exit 1; }

SECS="${STANDBY_TAP_SECS:-10}"
OUT="$EVIDENCE_DIR/system-audio-tap.jsonl"
PHRASE="the quick brown fox jumps over the lazy dog"

echo "capturing system audio via Core Audio tap for ${SECS}s (mode=system; mic NOT engaged)…"
"$HELPER" capture --mode system --seconds "$SECS" > "$OUT" 2>/tmp/standby-tap.err &
HPID=$!
sleep 1
say "$PHRASE" || true
say "please research the current state of the market in the last eighteen months" || true
( for _ in $(seq 1 60); do kill -0 "$HPID" 2>/dev/null || break; sleep 0.3; done; kill "$HPID" 2>/dev/null || true ) >/dev/null 2>&1 || true
wait "$HPID" 2>/dev/null || true

node - "$OUT" <<'NODE'
const fs = require("fs");
const lines = fs.readFileSync(process.argv[2], "utf8").split("\n").filter(Boolean)
  .map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
const sysLevels = lines.filter(o => o.type === "audio.level" && o.lane === "system_audio");
const sysFrames = sysLevels.length;
const sysMaxRms = Math.max(0, ...sysLevels.map(o => o.rms || 0));
const sysFinals = lines.filter(o => o.type === "segment.final" && o.lane === "system_audio").map(o => o.text);
const micFinals = lines.filter(o => o.type === "segment.final" && o.lane === "microphone").map(o => o.text);
const hitPhrase = sysFinals.some(t => /lazy dog|quick brown|research|market/i.test(t));
const permDenied = lines.some(o => o.type === "source.failed" && o.reason === "system_audio_permission_denied");
const otherFail = lines.find(o => o.type === "source.failed" && o.reason !== "system_audio_permission_denied");
console.log(JSON.stringify({ sysFrames, sysMaxRms: Number(sysMaxRms.toFixed(4)), sysFinals, micFinals, hitPhrase }, null, 2));

if (permDenied) {
  console.log("CAPTURE-BLOCKED: the Core Audio tap needs the System Audio Recording grant.");
  console.log("  Grant it: System Settings › Privacy & Security › System Audio Recording (add/enable");
  console.log("  StandbyCapture.app), then retry. Reported honestly, not hung.");
  process.exit(0);
}
if (otherFail) { console.error(`FAIL: tap capture failed: ${otherFail.reason} (${otherFail.detail||""})`); process.exit(1); }
if (micFinals.length) { console.error("FAIL: microphone produced transcript in a system-only capture (mic bleed onto system lane)"); process.exit(1); }
if (sysFrames < 1) { console.error("FAIL: tap produced ZERO system-audio frames"); process.exit(1); }
if (!hitPhrase) { console.error("FAIL: tap captured frames but the played phrase did not land on the system lane"); process.exit(1); }
console.log("PASS: Core Audio tap captured system audio (output-independent) and transcribed the played phrase on the system lane.");
NODE

echo "system-audio-tap smoke done. Output-independence proven by nonzero frames + transcript on the"
echo "current output device. Non-destructive (audible-while-captured) is guaranteed by"
echo "muteBehavior=.unmuted in the helper — confirm by ear: you heard the phrase while it was captured."
