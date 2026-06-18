# Live validation — PROVEN working on this machine

Standby captures a real meeting end-to-end on this Mac: the operator's voice AND
other participants' system audio, transcribed, labeled, and driving the full
proposal → worker pipeline. Validated 2026-06-18.

## What's proven (with the verification system that proves it)
- **Deadlock fix** — `verify-capture-longrun.sh` GREEN (60s) and
  `verify-capture-meeting-duration.sh` GREEN (10 min): 661 mic level_events, 0
  drops, SIGTERM <3s. RED on the pre-fix build. The original showstopper is fixed.
- **System audio (other participants)** — `verify-system-audio-tap.sh` GREEN:
  system lane active, real RMS, the played phrase transcribed on the `system_audio`
  lane. Default `auto` source (Core Audio tap → ScreenCaptureKit fallback).
- **Full meeting, both lanes** — `final-end-to-end.json`: mic lane `[me]` + system
  lane `[system_audio]`, both 0 drops, proposal "Research request" auto-created,
  approved → worker → real artifact "Research request result".
- All audio-free gates green: `verify.sh`, `verify-ui-states.sh`, `cargo test` (27).

## How system audio works (auto source)
The default is output-INDEPENDENT first: it tries a **Core Audio process tap**
(`kTCCServiceAudioCapture` / "System Audio Recording" grant; works on any output
incl. HDMI/Bluetooth). If the tap yields no frames within 4s (HAL state, missing
grant, or hardware that won't clock it), it **auto-falls-back to ScreenCaptureKit**
(`Screen Recording` grant; works on built-in output). No operator tuning. Force one
with `--system-source tap|sck` or `STANDBY_SYSTEM_SOURCE`.

On THIS machine (built-in speaker output), the ScreenCaptureKit fallback carries the
audio; the granted System-Audio-Recording permission lets the tap path work too on
output-independent setups.

## Reproduce
```sh
./scripts/verify.sh                      # full gate (no audio): tests, signing, UI, smoke
./scripts/verify-capture-longrun.sh      # deadlock gate, 60s, silent (mic liveness)
./scripts/verify-system-audio-tap.sh     # system-audio capture + transcript (plays a phrase)
./scripts/verify-capture-meeting-duration.sh   # 10-min ship gate, silent
```

## Operational notes
- Never `kill -9` the capture helper — it skips Core Audio teardown and can degrade
  `coreaudiod` until `sudo killall coreaudiod`. SIGTERM (the daemon's stop path)
  tears down cleanly; the helper also self-heals leaked aggregates on startup.
- The helper is signed with a stable Developer ID, so the TCC grants persist across
  rebuilds.

## Known follow-ups (not blocking)
- The signed `.app`, launched DIRECTLY via `open`, can stall on some HAL states; the
  product path (daemon-spawned) is unaffected. Worth hardening the tap setup so the
  direct path is equally robust.
- Per-PID tap on the meeting app to further limit mic-bleed onto the system lane
  (infrastructure landed: `--tap-pid` / `STANDBY_TAP_PID`).
