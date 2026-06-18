# Live validation — current state + the one remaining operator step

Updated after the live validation session. Almost everything is proven on this
machine now; the single remaining gap for capturing *other participants* is one
permission toggle.

## Proven on this machine ✅
- **M1 deadlock fix** — `verify-capture-longrun.sh` GREEN (60s): 63 mic
  level_events, no plateau/stall, SIGTERM <3s, zero drops. RED on the pre-fix
  build (`deadlock-reproduction-before-fix.csv`).
- **M5 ≥10-min ship gate** — GREEN: 661 mic events over 600s, **0 mic drops**
  (was 1740 before the coalescing fix), system lane delivering 646 events, no
  stall, SIGTERM <3s (`shipgate-10min-coalescing-pass.csv`). The deadlock fix
  holds over a full meeting duration with zero degradation.
- **Core Audio tap setup** — IOProc fires, `coalescing to 4096 frames` active,
  frames flow output-independently. (HAL recovered from the debug-leak pollution.)
- **Lane independence** — a system-lane failure/hang never kills the mic lane
  (proven live against the wedged HAL + unit tests).
- **Mic lane** clean standalone (0 drops); shipped `.app` launches + transcribes
  (Developer ID signed); all audio-free gates green (`verify.sh`,
  `verify-ui-states.sh`, `cargo test`).

## The one remaining step — grant the tap permission 🎧
The tap delivers **silent** frames (`sysMaxRms: 0`) until macOS authorizes it.
Open **System Settings → Privacy & Security → System Audio Recording** and enable
**StandbyCapture** (tell me which entries appear — macOS attributes tap permission
to a "responsible process," so it may show as StandbyCapture, Ghostty, or
Terminal). Then:
```
./scripts/verify-system-audio-tap.sh
```
PASS = nonzero frames + the played phrase transcribed on the system lane, audible
while captured. (Set output to HDMI/Bluetooth first to prove output-independence.)

## Optional — a real spoken dogfood 🗣️
With the grant on, a real call (or `STANDBY_LIVE_CAPTURE=1 ./scripts/verify-live-teams-local.sh`)
exercises the full path: your voice + system audio → transcript → proposal →
worker artifact. The mic lane already captures your side today, permission or not.

## Note
Avoid `kill -9` on the capture helper — it skips Core Audio teardown and leaks
tap state in the HAL (cleared by `sudo killall coreaudiod`). SIGTERM tears down
cleanly; the helper also self-heals leaked aggregates on startup.
