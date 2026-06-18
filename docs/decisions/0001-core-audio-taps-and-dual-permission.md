# ADR 0001 — Core Audio process taps + dual-permission capture, deadlock-free helper

- Status: Accepted
- Date: 2026-06-17
- Context packet: `docs/context-packets/capture-helper-rewrite.md`
- Research: `docs/research/capture-helper-deadlock-and-system-audio.md`

## Context

Live dogfood on macOS 26 exposed two failures the milestone smokes missed, both
architectural rather than patchable:

1. **The native capture helper deadlocked within seconds** and became
   SIGTERM-immune (only `kill -9` stopped it). Root cause: `dispatchMain()` parks
   the main thread on the GCD main queue but never services Swift's main-actor
   executor, so AVFoundation/Speech continuations that hop to the main actor never
   resume; an unbounded `Task { await … }` per realtime audio callback floods the
   cooperative pool; and `.sync` + blocking `FileHandle.write` ran on the realtime
   audio thread. The `--seconds N` smokes (4–12s) raced the wedge and exited
   before it bit — no test ran the full daemon → long-lived capture path.
2. **ScreenCaptureKit system audio delivered zero frames on HDMI/Bluetooth
   output** — its audio path is output-device-coupled. Other participants were
   never captured when the default output was anything but the built-in speakers.

## Decision

### 1. Concurrency model (kills the deadlock)
The helper is `main.swift` with **async top-level main** (the Swift runtime drives
an async main that services the main-actor executor) — never `dispatchMain()` with
main-actor dependencies. Realtime audio callbacks do **zero** blocking work: they
copy the buffer and `yield` it to a **per-lane bounded `AsyncStream`**
(`.bufferingNewest`), and a single consumer task drains each stream
(RMS + convert + feed the transcriber). stdout is owned by one **serial dispatch
queue**; `emit()` is a non-blocking `.async` enqueue; a `sync` barrier flushes only
before process exit. Lifecycle runs under a structured `TaskGroup`; the stop signal
(SIGTERM/SIGINT/`--seconds`) is observed on a **dedicated queue, never `.main`**.
Transcriber-bound audio that overflows the bounded stream is **counted and emitted**
(`audio.dropped{lane,count}`) — lost transcript is never silent.

### 2. System audio via Core Audio process taps (primary), ScreenCaptureKit (fallback)
System audio is captured with **Core Audio process taps**
(`AudioHardwareCreateProcessTap` + a private aggregate device with the tap as a
sub-tap and the real default output as the main sub-device, drift compensation on
every node, `AudioDeviceCreateIOProcIDWithBlock`). This is output-device-independent
and fixes the HDMI/Bluetooth zero-frames. The tap is **non-destructive**
(`muteBehavior = .unmuted`) so the call stays audible. ScreenCaptureKit is retained
behind the same lane interface as an automatic fallback for older OS or tap-setup
failure.

### 3. Dual TCC permission model
System audio has **two distinct permission tiers**, surfaced as distinct failure
reasons and UI cards, each naming its exact Settings pane:
- `system_audio_permission_denied` — the Core Audio tap tier
  (`kTCCServiceAudioCapture`, "System Audio Recording Only").
- `screen_recording_permission_denied` — the ScreenCaptureKit fallback tier
  ("Screen & System Audio Recording").
There is **no public API to pre-check** `kTCCServiceAudioCapture`; permission is
detected by **attempt-and-classify** (`kAudioHardwareNotPermittedError` /
`'nope'` / `1852797029` → the tap-tier failure), never a pre-emptive read.

### 4. Stable code-signing identity for the shipped helper
The shipped helper is a **signed standalone binary**, carrying a **stable identity**
(Developer ID on this machine; a persistent self-signed cert in a dedicated keychain
as the CI fallback) — **never ad-hoc**. Ad-hoc signing changes the cdhash every
build, so macOS TCC forgets the Microphone and System-Audio grants on each rebuild.
`build-capture-helper.sh` enforces this and `verify.sh` has a preflight that fails on
`Signature=adhoc`. The daemon's default `helper_path()` resolves the signed
standalone binary. A signed `.app` is still built for LaunchServices /
permission-grant experiments, but the daemon does not raw-exec the bundle
executable because that path can stall before Swift main on macOS 26.5.1.

## Consequences

- The helper **requires macOS 26** (SpeechAnalyzer); the documented Core Audio tap
  floor (14.4) is therefore always satisfied. The `SystemAudioUnsupportedOs` reason
  and `if #available(macOS 14.2)` guard remain as defensive code.
- New proof obligations: `verify-capture-longrun.sh` (≥60s daemon-driven deadlock
  gate — reproduces the original hang on the old build) and
  `verify-capture-meeting-duration.sh` (≥10-min ship gate — the clock-drift regime).
- The `HelperEvent` JSONL wire contract stays backward-compatible; all additions are
  additive.
- **Deferred follow-ups** (named, not done here): per-PID tap to limit mic-bleed;
  mic-only-continue when system audio is permission-blocked; rebuilding the aggregate
  on a mid-meeting output-device change (AirPods connect / HDMI hot-plug).

## Alternatives rejected

- **Minimal patch (make `emit()` async, keep `dispatchMain()`)** — main-actor
  starvation remains; the primary wedge is unfixed.
- **ScreenCaptureKit only, tell the user to switch off HDMI** — does not capture;
  pushes a platform bug onto the operator mid-meeting.
- **Virtual loopback driver (BlackHole/Loopback)** — admin install, fragile across
  OS updates, poor first-run UX.
- **Ad-hoc signing** — TCC grants evaporate on every rebuild (the dogfood trap).
