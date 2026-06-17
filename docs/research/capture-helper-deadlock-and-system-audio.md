# Research: Capture Helper Deadlock + Output-Independent System Audio

Date: 2026-06-17

Context: live dogfood on the operator's Mac exposed two failures the milestone
smokes missed. This documents the reproduction, root cause, and the correct
macOS primitives for the rewrite.

## Reproduction (feedback loop)

Fresh daemon (`STANDBY_DB`/`STANDBY_ADDR` temp), `POST .../capture/start?mode=mic`,
poll the projection every 1s:

```
t=1s..t=22s mic_level_events=0      # helper emits nothing
helper pid=… — SIGTERM → STILL ALIVE (only kill -9 works)
```

- Deadlocks in **mic-only** mode → not ScreenCaptureKit, not the watchdog.
- Deadlocks when spawned by the daemon, by a read pipe, and to a file → not
  stdout backpressure from accumulated events.
- **SIGTERM-immune** → the main GCD queue itself is wedged (the SIGTERM handler
  is a `DispatchSource` on `.main`).
- `--seconds N` smokes (4–12s) exited cleanly → the bound raced the wedge and
  won; short runs masked the bug. This is the verification gap: no test ran the
  full daemon → long-lived capture path.

## Root cause: `dispatchMain()` × Swift structured concurrency

`native/standby-capture-helper/main.swift` ends with
`Task { await runCapture(...) }` then `dispatchMain()`.

- `dispatchMain()` parks the one main OS thread servicing the GCD main queue. It
  does **not** pump Swift's main-actor executor. Any `await` resumption that hops
  through the main actor — AVFoundation/Speech completion routinely dispatch to
  main — is enqueued on the main-actor executor and **never runs**. The async
  graph stalls.
- The AVAudioEngine tap block (a real-time audio thread) spawns
  `Task { await micPipeline?.feed(buffer) }` per callback → an unbounded `Task`
  flood that saturates the cooperative pool, which can't drain because of the
  main-actor starvation.
- SIGTERM-immunity is the proof: the `.main` handler never fires because the main
  queue is wedged. Only `kill -9`.

### Secondary hazards (real)
- `LevelMeter.observe` does `queue.sync { … emit() }` on the **audio render
  thread**, and `emit()` does `stdoutQueue.sync { FileHandle.write }` — locks +
  blocking I/O on a realtime thread. If the parent pipe fills, the render thread
  blocks (a second, independent freeze path). Never lock or do I/O on the render
  thread.
- `nonisolated(unsafe) var systemStarted/systemCapture` written/read across
  threads with no barrier — data race.
- `feed` drops buffers until `start()`'s two `await`s complete — lossy.
- Early SIGINT/SIGTERM before the `DispatchSource`s arm are `SIG_IGN`'d, not
  handled — dropped.

### Correct concurrency architecture
1. `@main` with `async func main()` — delete `dispatchMain()`. Keep the process
   alive by `await`-ing a stop signal, not a GCD run loop.
2. Real-time threads do **zero** locks/I/O: hand each buffer to a per-lane
   **bounded `AsyncStream`** (`.bufferingNewest(n)`, drop-oldest) and return.
   A single consumer `Task` drains it → converts → feeds the `SpeechAnalyzer`
   actor → emits. No per-callback `Task` flood.
3. One dedicated **non-blocking stdout writer** (DispatchIO channel or
   `AsyncStream<Data>` + single consumer). Producers `yield`; never `.sync`,
   never write from a realtime thread. Telemetry (audio.level) uses bounded-drop;
   segment/source events use a reliable lane.
4. Lifecycle via a structured `TaskGroup`: capture task + a stop-signal task
   (SIGTERM/SIGINT/`--seconds` unified, handled off `.main`); first finisher
   cancels the rest and exits. Keep a hard `exit()` watchdog only for genuine
   non-cancellable framework hangs.

Sources: avanderlee MainActor dispatch; Apple forums "MainActor.run failing to
run closure", AVAudioEngine thread-safety/hangs; swiftonserver structured
concurrency + shared state.

## System audio that works regardless of output device

The operator's default output was **HDMI**; ScreenCaptureKit's `capturesAudio`
delivered **zero frames** even with audio playing. ScreenCaptureKit audio is
screen/display-coupled and is widely reported to drop audio on HDMI/Bluetooth
and certain external/aggregate outputs.

### The right primitive: Core Audio Process Taps (macOS 14.2+)
`AudioHardwareCreateProcessTap(CATapDescription, &tapID)` + a HAL **aggregate
device** with the tap as a sub-tap. Audio-only, output-device-independent, no
screen-recording permission, no purple screen-capture indicator.

Flow (per Apple "Capturing system audio with Core Audio taps" + insidegui/AudioCap):
1. `CATapDescription` — global mixdown (`processes = []`, `isMixdown = true`,
   `isPrivate = true`); or per-PID via
   `kAudioHardwarePropertyTranslatePIDToProcessObject`.
2. `AudioHardwareCreateProcessTap` → tap `AudioObjectID`; keep `uuid`.
3. `AudioHardwareCreateAggregateDevice` with `kAudioAggregateDeviceTapListKey`
   referencing the sub-tap, `kAudioAggregateDeviceIsPrivateKey: true`,
   `kAudioAggregateDeviceTapAutoStartKey: true`, and a **real output device as
   the main sub-device** (tap-as-main with an empty sub-device list yields
   silence).
4. Read `kAudioTapPropertyFormat` → build `AVAudioFormat`.
5. `AudioDeviceCreateIOProcIDWithBlock` on the aggregate; in the IO block wrap the
   buffer list as an `AVAudioPCMBuffer` (no-copy) → RMS + feed transcription.
6. `AudioDeviceStart`; cleanup with `AudioDeviceStop` /
   `AudioHardwareDestroyAggregateDevice` / `AudioHardwareDestroyProcessTap`.

### Documented traps (must handle)
- **Different TCC tier**: taps need `kTCCServiceAudioCapture` = **"System Audio
  Recording Only"** (a separate Settings section — already visible in the
  operator's settings), NOT "Screen & System Audio Recording" (ScreenCaptureKit).
  Wrong tier → `OSStatus 1852797029` (`'nope'`, `kAudioHardwareNotPermittedError`).
- **Signed binary + `NSAudioCaptureUsageDescription`** required (our signed
  `.app` wrapper already satisfies the signing need); deployment target ≥ 14.4
  keeps the right TCC category.
- **`AVAudioEngine` cannot be retargeted to a tap aggregate** — setting the
  device returns `noErr` but silently keeps the default input. Use
  `AudioDeviceCreateIOProcIDWithBlock` directly.
- `CATapDescription` exclusive/process-list flags invert semantics if misused →
  silent silence.

### Keep ScreenCaptureKit as an optional fallback
SCStream system audio still works on built-in output and is simpler; keep it
behind the same lane interface as a fallback / for older OSes, with the honest
no-frames detection driving an automatic switch or a clear UI state.

Reference implementations (same Swift-CLI-over-stdio architecture as Standby):
insidegui/AudioCap (14.4+), useraven/Raven, Bonanzah/debrief; aitchdien and
dgrlabs writeups for the traps; sudara/directmusic gist for the C example.

## Mic capture
AVAudioEngine input tap is fine and output-independent — keep it, but move RMS +
emit **off** the render thread (per the concurrency rewrite).

## Bottom line
Two coupled rewrites: (1) the helper's concurrency/IPC model (kills the
deadlock), (2) Core Audio Process Taps for system audio (kills the HDMI/Bluetooth
no-frames). Plus a long-running daemon-driven capture smoke that would have
caught the deadlock, and the second TCC permission surfaced honestly in the UI.
