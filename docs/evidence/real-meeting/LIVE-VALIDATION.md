# Live validation — the audio-gated steps (run when you're free, not mid-meeting)

Everything that needs no audio is done and green (cargo test, `verify.sh`,
`verify-ui-states.sh`). These three steps need the microphone, the speakers, and a
one-time macOS permission grant. They are the only thing between "compiles + gates
green" and "proven working on this machine."

## Step 1 — deadlock fix is real (mic only, ~60s, SILENT)
Proves the concurrency rewrite actually fixes the hang. Reads your mic for 60s
(local, ephemeral, auto-deleted); plays nothing.

```sh
./scripts/verify-capture-longrun.sh
```
PASS = mic `level_events` climb ~1/sec for 60s, SIGTERM stops it < 3s, zero drops.
(The same gate is RED on the pre-fix build — see `deadlock-reproduction-before-fix.csv`.)

## Step 2 — Core Audio tap captures system audio on ANY output (plays a phrase)
Proves the HDMI/Bluetooth fix. Set your output device to **HDMI or AirPods** first
to make the point. mode=system, so your mic is NOT engaged — it only captures the
benign test phrase it plays.

```sh
./scripts/verify-system-audio-tap.sh
```
First run will likely print **CAPTURE-BLOCKED**: grant
**System Settings › Privacy & Security › System Audio Recording → StandbyCapture.app**,
then re-run. (Thanks to stable signing, you grant this once — it persists across
rebuilds.) PASS = nonzero system frames + the phrase transcribed on the system lane,
and you HEARD the phrase while it was captured (non-destructive tap).

## Step 3 — the ship gate (≥10 min) + a real meeting
The 60s gate can't see clock drift at 20–40 min; this is the headline-claim gate.
Needs a quiet ~10 min.

```sh
./scripts/verify-capture-meeting-duration.sh           # 10 min, SILENT (mic liveness)
# then a real end-to-end dogfood over the daemon + UI:
STANDBY_LIVE_CAPTURE=1 ./scripts/verify-live-teams-local.sh
```

## If anything fails
Capture the failing output and the relevant `docs/evidence/real-meeting/*.jsonl` /
`*.csv`; the gates are designed to fail honestly (CAPTURE-BLOCKED / explicit FAIL),
never hang. The fix is then a normal `/diagnose` loop, not a restart.
