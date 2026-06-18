#!/usr/bin/env bash
# Deterministic proof that transcription is real and unstubbed: synthesize a
# known phrase, transcribe it through the same native helper the live path uses,
# assert the words come back, and delete the audio sample.
#
# Uses on-device Apple Speech (SpeechAnalyzer). No network, no Dictation toggle.
set -euo pipefail

cd "$(dirname "$0")/.."
EVIDENCE_DIR="docs/evidence/real-meeting"
mkdir -p "$EVIDENCE_DIR"

HELPER="${STANDBY_CAPTURE_HELPER:-native/standby-capture-helper/build/standby-capture-helper}"
[ -x "$HELPER" ] || bash ./scripts/build-capture-helper.sh

PHRASE="the quick brown fox jumps over the lazy dog"
SAMPLE="$(mktemp -t standby-transcriber.XXXXXX).aiff"
cleanup() { rm -f "$SAMPLE"; }
trap cleanup EXIT

say -o "$SAMPLE" "$PHRASE"
OUT="$("$HELPER" transcribe-file "$SAMPLE" 2>/dev/null)"
printf '%s\n' "$OUT" > "$EVIDENCE_DIR/real-transcriber-smoke.jsonl"

TEXT="$(printf '%s\n' "$OUT" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  for(const l of s.split("\n")){ if(!l.trim()) continue;
    try{ const o=JSON.parse(l); if(o.type==="transcribe.done") process.stdout.write(o.text||""); }catch{} }
});')"

echo "transcript: $TEXT"
LOWER="$(printf '%s' "$TEXT" | tr '[:upper:]' '[:lower:]')"
for word in quick brown fox lazy dog; do
  case "$LOWER" in
    *"$word"*) ;;
    *) echo "FAIL: expected word '$word' missing from transcript" >&2; exit 1 ;;
  esac
done

echo "real-transcriber smoke passed (deterministic offline Apple Speech)"
