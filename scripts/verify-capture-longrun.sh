#!/usr/bin/env bash
# verify-capture-longrun.sh — the deadlock gate the original smokes never had.
#
# Drives the FULL daemon -> native-helper capture path (the path that actually
# wedged in dogfood), not a short `--seconds` direct run. Captures mic+system for
# STANDBY_LONGRUN_SECS (default 60s) and asserts the liveness signature a deadlock
# destroys:
#   * the microphone lane's level_events keep climbing (no plateau) — mic emits a
#     level event ~1/sec of captured audio even in silence, so a frozen counter is
#     the deadlock fingerprint;
#   * no silent stall (bounded gap between increments);
#   * zero transcriber-lane audio.dropped (lost transcript must be visible, never
#     silent — asserted once the helper emits the counter; 0 before then);
#   * a single SIGTERM (via the daemon's capture/stop) stops the helper within 3s,
#     no kill -9.
#
# The system-audio lane is reported but not gated here: on HDMI/Bluetooth output
# the ScreenCaptureKit path legitimately yields zero frames (the SEPARATE bug that
# verify-system-audio-tap.sh covers). This gate is specifically about the deadlock,
# which the output-independent mic lane isolates cleanly.
#
# Against the UNFIXED helper this MUST fail (mic plateaus at 0, SIGTERM ignored) —
# that red is the proof the loop reproduces the bug. The concurrency rewrite turns
# it green.
set -euo pipefail

cd "$(dirname "$0")/.."

SECS="${STANDBY_LONGRUN_SECS:-60}"
STALL_MAX="${STANDBY_LONGRUN_STALL_MAX:-5}"     # max seconds the mic counter may sit still
EVIDENCE_DIR="docs/evidence/real-meeting"
mkdir -p "$EVIDENCE_DIR"

# Always use the freshly built default helper, never a stale STANDBY_CAPTURE_HELPER
# from the operator's shell (a paste-wrapped newline once broke spawn here).
unset STANDBY_CAPTURE_HELPER || true

bash ./scripts/build-capture-helper.sh >/dev/null
cargo build -p standbyd >/dev/null 2>&1

# Match by executable name so we find the helper whether the daemon spawned the
# signed standalone helper (the default) or another binary via STANDBY_CAPTURE_HELPER.
HELPER_BIN="standby-capture-helper"
DB="$(mktemp -t standby-longrun.XXXXXX).db"
JOBS="$(mktemp -d -t standby-longrun-jobs.XXXXXX)"
ADDR="127.0.0.1:4322"
MTG="longrun"
LOG="/tmp/standby-longrun.log"
PROJ="/tmp/standby-longrun-proj.json"
SAMPLES="$EVIDENCE_DIR/longrun-samples.csv"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS"
export STANDBY_OPERATOR_TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-verify-token}"

# Only ever touch the helper WE spawn: snapshot any pre-existing ones first.
# pgrep exits 1 when nothing matches; never let that kill the script.
before_pids=" $({ pgrep -f "$HELPER_BIN" 2>/dev/null || true; } | sort -u | tr '\n' ' ')"

cargo run -p standbyd >"$LOG" 2>&1 &
PID=$!
HELPER_PID=""
cleanup() {
  curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -X POST "http://$ADDR/api/meetings/$MTG/capture/stop" >/dev/null 2>&1 || true
  [ -n "$HELPER_PID" ] && kill -9 "$HELPER_PID" 2>/dev/null || true
  kill "$PID" 2>/dev/null || true
  rm -f "$DB" "$DB"-wal "$DB"-shm
  rm -rf "$JOBS"
}
trap cleanup EXIT

for _ in $(seq 1 80); do
  curl -fsS "http://$ADDR/health" >/dev/null 2>&1 && break
  kill -0 "$PID" 2>/dev/null || { echo "FAIL: daemon exited before ready"; cat "$LOG"; exit 1; }
  sleep 0.25
done

echo "starting daemon-driven mic+system capture for ${SECS}s…"
curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -X POST "http://$ADDR/api/meetings/$MTG/capture/start?mode=mic%2Bsystem" >/dev/null

# Identify the helper pid the daemon just spawned (the one not present before).
for _ in $(seq 1 24); do
  for p in $({ pgrep -f "$HELPER_BIN" 2>/dev/null || true; } | sort -u); do
    case "$before_pids" in *" $p "*) : ;; *) HELPER_PID="$p"; break ;; esac
  done
  [ -n "$HELPER_PID" ] && break
  sleep 0.25
done
[ -n "$HELPER_PID" ] && echo "  helper pid=$HELPER_PID" || echo "  WARN: could not identify helper pid (SIGTERM check will be inconclusive)"

: > "$SAMPLES"
echo "t,mic_level_events,sys_level_events,mic_dropped,sys_dropped,status" >> "$SAMPLES"

# SILENT BY DEFAULT. The deadlock gate asserts on the mic lane, which emits a
# level event ~1/sec of CAPTURED audio regardless of loudness — so no playback is
# needed and your output device is never touched. Set STANDBY_LONGRUN_PLAY=1 only
# when you also want a working system lane to have signal (e.g. paired with the
# tap smoke); never during a real meeting.
SAY_PID=""
if [ "${STANDBY_LONGRUN_PLAY:-0}" = "1" ]; then
  ( for _ in $(seq 1 "$((SECS / 8 + 1))"); do
      say "Standby long run capture verification, segment check in progress." >/dev/null 2>&1 || true
    done ) &
  SAY_PID=$!
fi

for i in $(seq 1 "$SECS"); do
  curl -fsS "http://$ADDR/api/meetings/$MTG" > "$PROJ" 2>/dev/null || true
  node -e '
    const fs=require("fs");
    let p; try { p=JSON.parse(fs.readFileSync(process.argv[3],"utf8")); } catch { process.exit(0); }
    const s=p.source||{}, mic=s.microphone||{}, sys=s.system_audio||{};
    fs.appendFileSync(process.argv[2],
      `${process.argv[1]},${mic.level_events||0},${sys.level_events||0},${mic.dropped||0},${sys.dropped||0},${s.status||""}\n`);
  ' "$i" "$SAMPLES" "$PROJ"
  sleep 1
done
[ -n "$SAY_PID" ] && kill "$SAY_PID" 2>/dev/null || true

echo "capture window done; sending SIGTERM via capture/stop and timing shutdown…"
curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -X POST "http://$ADDR/api/meetings/$MTG/capture/stop" >/dev/null 2>&1 || true
# Grade SIGTERM by the PROJECTION reaching "stopped" within 3s, not by polling the
# helper pid. The helper emits source.stopped only after a graceful shutdown
# (engine stop → finalize → flush), so the daemon ingesting it ⇒ SIGTERM honored. A
# wedged/deadlocked helper never emits it (status stays "capturing") → FAIL. This is
# robust to pid-reuse and to the case where we couldn't identify the helper pid.
STOPPED_OK=0
for _ in $(seq 1 12); do              # 12 * 0.25s = 3s budget
  st="$(curl -fsS "http://$ADDR/api/meetings/$MTG" 2>/dev/null \
    | node -e 'try{const p=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(p.source.status||"")}catch{process.stdout.write("")}' || true)"
  [ "$st" = "stopped" ] && { STOPPED_OK=1; break; }
  sleep 0.25
done

node - "$SAMPLES" "$STALL_MAX" "$SECS" "$STOPPED_OK" <<'NODE'
const fs = require("fs");
const [file, stallMaxArg, secsArg, stoppedArg] = process.argv.slice(2);
const stallMax = Number(stallMaxArg), secs = Number(secsArg), stopped = Number(stoppedArg);
const rows = fs.readFileSync(file, "utf8").trim().split("\n").slice(1)
  .map(l => l.split(",")).filter(r => r.length >= 6)
  .map(([t, mic, sys, micD, sysD, status]) => ({ t: +t, mic: +mic, sys: +sys, micD: +micD, sysD: +sysD, status }));

if (!rows.length) { console.error("FAIL: no projection samples collected"); process.exit(1); }

const micFinal = rows[rows.length - 1].mic;
const sysFinal = rows[rows.length - 1].sys;
const micDropped = Math.max(0, ...rows.map(r => r.micD));
const sysDropped = Math.max(0, ...rows.map(r => r.sysD));

// Longest stretch (in samples ~= seconds) where the mic counter did not advance,
// measured only after the first increment (startup grace).
let firstGrowth = rows.findIndex((r, i) => i > 0 && r.mic > rows[i - 1].mic);
let maxStall = 0, run = 0;
for (let i = Math.max(1, firstGrowth); i < rows.length; i++) {
  if (rows[i].mic > rows[i - 1].mic) run = 0; else { run++; maxStall = Math.max(maxStall, run); }
}
// Still climbing in the final 20% of the window? (catches a mid-run freeze.)
const tail = rows.slice(Math.floor(rows.length * 0.8));
const tailGrowth = tail.length >= 2 && tail[tail.length - 1].mic > tail[0].mic;
// Real rate is ~1 level event per second of captured audio. 0.7× tolerates
// startup grace + scheduling jitter while still catching a half-rate (batching /
// partially-stalled) consumer that the old ceil(secs/2) floor would have passed.
const livenessFloor = Math.floor(secs * 0.7);

console.log(JSON.stringify({
  samples: rows.length, micFinal, sysFinal, micDropped, sysDropped,
  maxStall, tailGrowth, livenessFloor,
  sigterm: stopped === 1 ? "stopped<3s" : "NOT-HONORED(no source.stopped in 3s)",
  statuses: [...new Set(rows.map(r => r.status))],
}, null, 2));

const fails = [];
if (micFinal < livenessFloor) fails.push(`mic lane produced ${micFinal} level_events in ${secs}s (deadlock signature; need >= ${livenessFloor})`);
if (!tailGrowth) fails.push("mic lane stopped advancing in the final 20% of the window (mid-run freeze)");
if (maxStall > stallMax) fails.push(`mic counter stalled ${maxStall}s with no increment (> ${stallMax}s budget)`);
if (micDropped > 0) fails.push(`microphone transcriber lane silently dropped ${micDropped} buffers (lost transcript)`);
if (sysDropped > 0) fails.push(`system transcriber lane silently dropped ${sysDropped} buffers (lost transcript)`);
if (stopped !== 1) fails.push("SIGTERM not honored: projection did not reach 'stopped' within 3s of capture/stop (helper wedged or ignoring SIGTERM)");

if (fails.length) { console.error("FAIL:\n  - " + fails.join("\n  - ")); process.exit(1); }
console.log(`PASS: no deadlock — mic lane live for ${secs}s, SIGTERM honored, zero silent drops.`);
NODE

echo "verify-capture-longrun done (${SECS}s)"
