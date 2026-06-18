#!/usr/bin/env bash
# verify-capture-meeting-duration.sh — the ACTUAL ship gate for the headline claim
# ("a full real meeting"). The 60s deadlock gate is satisfiable by a build that
# dies at minute 12: aggregate-device clock drift and slow degradation live in the
# 20–40 minute regime, invisible at 60s. This runs the SAME daemon-driven capture
# with the SAME grader (level-event monotonicity + bounded inter-event gap + zero
# transcriber drops + SIGTERM-stop) over a ≥10-minute window, where a drift-induced
# dropout shows up as a counter stall or a drop counter.
#
# Needs the microphone (and, for the system lane, the System-Audio grant). Silent
# by default — run it when you have a quiet ~10 minutes, not mid-meeting.
set -euo pipefail

cd "$(dirname "$0")/.."

# 10 minutes by default. STANDBY_MEETING_SECS overrides (e.g. 1800 for a 30-min
# soak that crosses the canonical 20–40 min drift window end to end).
export STANDBY_LONGRUN_SECS="${STANDBY_MEETING_SECS:-600}"
# Same stall budget as the fast gate; a drift dropout would exceed it.
export STANDBY_LONGRUN_STALL_MAX="${STANDBY_LONGRUN_STALL_MAX:-5}"

echo "ship gate: ${STANDBY_LONGRUN_SECS}s daemon-driven capture (clock-drift regime)…"
exec bash ./scripts/verify-capture-longrun.sh
