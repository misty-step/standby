#!/usr/bin/env bash
# Fake capture helper for backlog 021 QA. It emits helper-shaped JSONL quickly
# enough that segments 3/4 should arrive while the proposal reasoner is still
# sleeping in STANDBY_PROPOSAL_TEST_DELAY_MS.
set -euo pipefail

if [ "${1:-}" != "capture" ]; then
  echo "fake-capture-helper: expected: capture --mode <mode>" >&2
  exit 64
fi

mode="mic+system"
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      mode="${2:-mic+system}"
      shift 2
      ;;
    --seconds)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

emit() {
  printf '%s\n' "$1"
  # Keep stdout line-buffered through pipes.
  sleep "${STANDBY_FAKE_HELPER_STEP_SECS:-0.20}"
}

emit "{\"type\":\"source.started\",\"mode\":\"$mode\",\"mic\":true,\"system\":true}"
emit '{"type":"segment.final","lane":"system_audio","speaker":"remote_1","start_ms":0,"end_ms":1000,"text":"We need someone to research private meeting assistant tools before Friday."}'
emit '{"type":"segment.final","lane":"system_audio","speaker":"remote_2","start_ms":1100,"end_ms":2100,"text":"Focus on local-first products and where Standby is different."}'
emit '{"type":"segment.final","lane":"system_audio","speaker":"remote_1","start_ms":2200,"end_ms":3200,"text":"Also compare the approval and audit trail story against other tools."}'
emit '{"type":"segment.final","lane":"system_audio","speaker":"remote_2","start_ms":3300,"end_ms":4300,"text":"End with a concise recommendation we can use in this meeting."}'
printf '%s\n' '{"type":"source.stopped"}'
