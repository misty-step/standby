# Live validation — current state + the operator-gated steps

Updated after a live validation session. What's proven on this machine, and the
exact steps left (all need your mic/speakers, a one-time permission, and — because
of debug-run HAL pollution — one daemon restart).

## Proven on this machine ✅
- **M1 deadlock fix** — `./scripts/verify-capture-longrun.sh` passed GREEN: 63 mic
  level_events/60s, no plateau/stall, SIGTERM honored <3s, zero drops. The same
  gate is RED on the pre-fix build (`deadlock-reproduction-before-fix.csv`). This
  was the showstopper; it's fixed.
- **Mic lane is clean standalone** — a 40s mic-only capture: 42 level_events, **0
  drops**. Confirms the ~25% drops seen in the 10-min gate came specifically from
  the system-tap's small-buffer load (now coalesced).
- **Shipped `.app`** launches + transcribes (Developer ID signed, not ad-hoc).
- All audio-free gates green (`verify.sh`, `verify-ui-states.sh`, `cargo test`).

## Step 0 — clear the HAL (one-time, my fault) 🔧
Debug runs that hung got `kill -9`'d, which skips Core Audio teardown and leaked
tap state in the HAL; new tap setup now hangs (the helper fails honestly at 8s via
its watchdog, but the tap won't run). Clear it:
```
sudo killall coreaudiod
```
(Briefly blips system audio ~1s. Caveat going forward: never `kill -9` the helper —
SIGTERM tears the tap down cleanly; the helper also self-heals leaked aggregates on
startup now.)

## Step 1 — Core Audio tap captures system audio on any output 🎧
```
./scripts/verify-system-audio-tap.sh
```
The tap was confirmed to deliver frames (447 in the 10-min gate) and the IOProc
fires; the remaining unknown is the **System Audio Recording** grant. First run
will likely print CAPTURE-BLOCKED **or** show `sysMaxRms: 0` (silent frames) until
granted. Grant it: **System Settings → Privacy & Security → System Audio Recording**
→ enable **StandbyCapture** (note which entry appears — it may attribute to the
terminal). Re-run; PASS = nonzero frames + the phrase on the system lane, audible
while captured. This also validates the **coalescing** drop-fix on the system lane.

## Step 2 — the ≥10-min ship gate (re-run) 📏
```
./scripts/verify-capture-meeting-duration.sh
```
Previously failed only on the mic-drop finding (now coalesced). Re-run confirms no
drops over the full window. Silent, mic-only — no permission needed.

## Step 3 — a real spoken dogfood 🗣️
With Step 0/1 done, the full path (your voice + system audio → transcript →
proposal → worker artifact) via `STANDBY_LIVE_CAPTURE=1 ./scripts/verify-live-teams-local.sh`,
or just talk during a real call. (A mic-only spoken run was wired and live but
captured silence — no one spoke; if you speak and it still reads silent, check your
input device isn't muted.)

## Bottom line
The deadlock that made Standby unusable is fixed and proven. The system-audio tap
is implemented and was delivering frames; it needs a clean HAL + the one permission
to finish proving. Ping me and I'll drive Steps 0–3 with you in ~5 minutes.
