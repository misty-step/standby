#!/usr/bin/env bash
# Deterministic local research worker. A real subprocess (no model, no network)
# that proves the runner + sandbox + artifact persistence end to end. The real
# model worker is the claude/pi profile; this is the default for the gate.
#
# Args: $1 = scratch dir (only writable target), $2 = prompt file.
set -euo pipefail

SCRATCH="$1"
PROMPT_FILE="$2"
PROMPT="$(cat "$PROMPT_FILE" 2>/dev/null || true)"
ARTIFACT="$SCRATCH/artifact.md"

{
  echo "# Research briefing (local worker)"
  echo
  echo "## Request"
  printf '%s\n' "$PROMPT" | head -c 1200
  echo
  echo "## Notes"
  echo "- Produced by the deterministic local-research worker inside a sandboxed scratch."
  echo "- No network and no repo access: this proves the runner and sandbox, not model quality."
  echo "- Swap STANDBY_WORKER_PROFILE=claude-research for a real model worker."
} > "$ARTIFACT"

echo "local-research worker wrote $ARTIFACT"
