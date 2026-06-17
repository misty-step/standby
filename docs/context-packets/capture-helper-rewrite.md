# Context Packet: Deadlock-Free, Output-Independent Capture Helper

## PRD Summary

- User: Phaedrus, using Standby during live calls on a Mac.
- Problem: live dogfood exposed two failures the milestone smokes never caught.
  (1) The native capture helper **deadlocks within seconds** and becomes
  SIGTERM-immune (only `kill -9` stops it), so a real meeting never gets going.
  (2) ScreenCaptureKit system audio delivers **zero frames when the output
  device is HDMI** (or Bluetooth), so other participants are never captured. Mic
  works but freezes at the same deadlock.
- Goal: Standby captures microphone + all participants for the full duration of a
  real meeting on any output device, never deadlocks, stops cleanly on request,
  and names the exact macOS permission when one is missing.
- Why now: both causes are architectural, not patchable around. The deadlock is
  `dispatchMain()` starving Swift's main-actor executor plus an unbounded `Task`
  flood from the audio render thread; the no-audio is ScreenCaptureKit being
  output-device-coupled. Root-caused and reproduced — see
  `docs/research/capture-helper-deadlock-and-system-audio.md`.
- Deliverable type: working code plus verification harness.
- Success signal: a ≥10-minute daemon-driven capture against a real call on HDMI
  output streams continuous transcript from both lanes with zero deadlocks, and a
  played known phrase is transcribed regardless of output device.

## Goal

Rewrite the capture helper so live mic + system-audio capture is deadlock-free
and output-device-independent, proven by a long-running daemon-driven smoke that
would have caught the original hang.

## Non-Goals

- No Windows/Linux capture; macOS only.
- No speaker diarization beyond `me` / `system_audio` in this slice.
- No worker, proposal, or storage changes — this is the capture boundary only.
- Not bundling `standbyd` itself as a `.app` (separate follow-up); only the
  capture helper gets the signed-bundle treatment.
- Not removing ScreenCaptureKit — it stays as an optional fallback lane.
- Not surviving an output-device *change* mid-meeting (AirPods connect / HDMI
  hot-plug). Static "any output device at start" is in scope; a HAL
  default-output property listener that rebuilds the aggregate on change is a
  named follow-up, not this slice.

## Constraints (invariants that must survive)

- The helper still emits only JSONL on stdout and owns no SQLite/proposals/
  workers/credentials (`AGENTS.md` native-boundary rule).
- The `HelperEvent` JSONL contract consumed by
  `crates/standby-core/src/transcript_source.rs` stays backward-compatible
  (`source.started`, `audio.level`, `segment.partial|final`, `source.failed`,
  `source.stopped`). New fields are additive.
- Transcription stays on-device Apple Speech (`SpeechAnalyzer`); the deterministic
  `transcribe-file` subcommand and its smoke remain green.
- Rust owns all durable behavior; the helper remains a supervised subprocess.
- The gate `./scripts/verify.sh` stays green and is not weakened.
- **The system-audio tap must not mute meeting playback** (`CATapDescription.muteBehavior`
  = observe/unmuted) — the operator must keep hearing participants. The tap is
  non-destructive capture.
- **The transcriber-fed audio stream must not silently drop buffers in steady
  state.** Dropped audio = missing transcript; any drop is counted and surfaced
  (`audio.dropped{lane,count}`), never invisible. Telemetry (`audio.level`) may
  bounded-drop; transcriber-bound audio may not, silently.
- **The shipped helper is signed with a STABLE code-signing identity** (a
  persistent self-signed certificate or Developer ID), never ad-hoc (`codesign
  --sign -`). Ad-hoc signing changes the cdhash every build, so macOS TCC forgets
  the Microphone and System-Audio grants on each rebuild.
- Tap audio is explicitly converted (`AVAudioConverter`) from `kAudioTapPropertyFormat`
  to the transcriber's expected format.

## Repo Anchors

- `native/standby-capture-helper/main.swift` — the rewrite target (current
  `dispatchMain()` + actor + `.sync` emit model is the bug).
- `crates/standbyd/src/capture.rs` — the supervisor: spawn, stdout read loop,
  SIGTERM stop, bounded reap. May need a dedicated reader task so it can never
  stall the helper's pipe.
- `crates/standby-core/src/transcript_source.rs` — the `HelperEvent` enum +
  `LocalMacAudioSource::normalize`; defines the wire contract to preserve.
- `crates/standby-core/src/domain.rs` — `SourceFailureReason`, `AudioLane`,
  `SourceStatus`; add a permission-tier distinction here.
- `scripts/build-capture-helper.sh` — must produce + sign the `.app` bundle as
  the shipped helper (stable TCC identity).
- `docs/research/capture-helper-deadlock-and-system-audio.md` — root cause,
  reproduction, Core Audio tap flow, and the documented traps.

## Alternatives

### Deadlock fix

| Option | Why it helps | Failure mode | Verdict |
| --- | --- | --- | --- |
| **`@main async` + bounded AsyncStream handoff + single non-blocking writer + structured TaskGroup shutdown** | Removes the GCD-vs-Swift-executor fight at the root; realtime threads never block; SIGTERM handled off `.main`. | More rewrite surface. | **Choose.** |
| Minimal patch: make `emit()` async, keep `dispatchMain()` | Small diff. | Main-actor starvation remains — AVFoundation/Speech continuations still never resume. Doesn't fix the primary wedge. | Reject (insufficient). |
| Drop Apple Speech; pipe raw PCM to Rust + Whisper | Sidesteps Speech's main-actor hops. | No Whisper installed; loses the proven on-device transcriber; bigger surface. | Reject for this slice. |

### System audio

| Option | Why it helps | Failure mode | Verdict |
| --- | --- | --- | --- |
| **Core Audio Process Taps (`AudioHardwareCreateProcessTap` + aggregate device)** | Output-device-independent, audio-only, no screen-recording, no capture indicator. | New TCC tier (`kTCCServiceAudioCapture`), aggregate-device setup traps, must use `AudioDeviceCreateIOProcIDWithBlock`. | **Choose** (primary lane). |
| Keep ScreenCaptureKit, detect no-frames, tell user to switch output off HDMI | Tiny change. | Doesn't capture; pushes a platform bug onto the user mid-meeting. | Reject as primary; keep SCStream as fallback lane only. |
| Virtual loopback driver (BlackHole/Loopback) | Universally works. | Requires admin install + setup; fragile across OS updates; bad first-run UX. | Reject. |

Delete-first / Ponytail: the lazy path (patch `emit`, tell user to change output)
was evaluated and **fails the actual outcome** — the helper still wedges and HDMI
still yields nothing. The architectural rewrite is the minimum that satisfies
"works in a real meeting on any output device."

## Technical Design

Three deep modules behind the existing lane interface; the JSONL contract and the
Rust supervisor barely change.

1. **Process + concurrency model (kills the deadlock)**
   - `@main struct Helper { static func main() async }`; delete `dispatchMain()`.
   - Per lane, a **bounded `AsyncStream<AVAudioPCMBuffer>`** fed from the realtime
     callback (`continuation.yield`; the callback computes nothing blocking and
     returns immediately — **no per-callback `Task`**). A single consumer `Task`
     drains it → RMS + convert + feed the `SpeechAnalyzer` actor + enqueue emits.
     **This transcriber-feed stream is sized so steady state never drops**; on
     overflow the drop is **counted and emitted** (`audio.dropped{lane,count}`),
     never silent — dropped audio is lost transcript and must be a visible,
     gradeable event.
   - One **non-blocking stdout writer** (a `DispatchIO` channel or
     `AsyncStream<Data>` + single consumer) owns the file handle. `emit()` becomes
     a non-blocking enqueue. Only the `audio.level` telemetry lane bounded-drops
     (`.bufferingNewest(n)`); segment/source/dropped events use a reliable lane.
     No `.sync`, no writes from realtime threads.
   - Lifecycle: `withTaskGroup` runs the capture lanes + a stop-signal task
     (SIGTERM/SIGINT/`--seconds` unified, signal source on a dedicated queue, not
     `.main`). First finisher cancels the rest, finalizes the transcriber, exits.
     Keep a hard `exit()` watchdog only for genuinely non-cancellable framework
     acquisition hangs.

2. **System-audio lane via Core Audio Process Taps** (normative reference:
   `insidegui/AudioCap`, macOS 14.4+; Apple's "Capturing system audio with Core
   Audio taps" sample is published 26.0+ and is illustrative only — do not target
   its newer initializers against the 14.4 floor).
   - `CATapDescription` → `AudioHardwareCreateProcessTap` → HAL **aggregate
     device** with the tap as a sub-tap, a real output device as the main
     sub-device, `kAudioAggregateDeviceTapAutoStartKey: true`, `IsPrivate: true`,
     and **drift correction enabled on every sub-device/sub-tap** (the field-known
     cause of dropouts at 20–40 min). Read `kAudioTapPropertyFormat`, build
     `AVAudioFormat`, `AudioDeviceCreateIOProcIDWithBlock` (it takes its own
     `dispatch_queue_t` — no CFRunLoop), wrap the buffer list no-copy as
     `AVAudioPCMBuffer`, **convert with `AVAudioConverter`** to the transcriber's
     format (the tap may return stereo/non-interleaved/padded), feed the per-lane
     stream. Clean teardown (`AudioDeviceStop` / destroy aggregate / destroy tap).
   - **Non-destructive**: `muteBehavior` = observe/unmuted so meeting playback
     stays audible to the operator. (The muting setting silences the call for the
     user — same class as the `isExclusive` semantic trap.)
   - **Mic-bleed labeling**: a global mixdown tap captures *all* output, so the
     operator's own voice can leak onto the system lane (double-transcribed,
     mislabeled). Prefer a **per-PID tap on the meeting app**
     (`kAudioHardwarePropertyTranslatePIDToProcessObject`) when the meeting PID is
     identifiable; fall back to global mixdown. Define the dedupe/labeling
     contract: the system lane stays `system_audio`; do not double-count the
     operator's voice.
   - **Permission detection is attempt-and-classify, not pre-check.** There is no
     public API to query/request `kTCCServiceAudioCapture` ("System Audio
     Recording Only") on the target OS (`AudioCap` uses private TCC API; we will
     not). Start the tap; map `kAudioHardwareNotPermittedError` (`'nope'`,
     `1852797029`) → `source.failed{reason: system_audio_permission_denied}` with
     the System-Audio-Recording Settings deep-link. The UI distinguishes
     mic-denied vs system-audio-denied from these failure events; it makes no
     pre-emptive permission-read claim.
   - **OS floor 14.4.** Below it, emit
     `source.failed{reason: system_audio_unsupported_os}` and fall back to
     ScreenCaptureKit — never a dyld/missing-symbol crash. ScreenCaptureKit stays
     behind the lane interface as the fallback (built-in output / older OS),
     auto-selected when the tap is unavailable; honest no-frames detection applies.

3. **Mic lane** — keep AVAudioEngine input tap, but move RMS + emit off the render
   thread into the consumer task (same stream pattern).

Wire/UI additions (additive): a `SourceFailureReason::SystemAudioPermissionDenied`
and a permission-tier field so the UI distinguishes "grant Microphone" from
"grant System Audio Recording," each naming its exact Settings pane.

Build: `scripts/build-capture-helper.sh` produces and signs the `.app` with a
**stable code-signing identity** — a persistent self-signed certificate
created/reused in the login keychain, or a Developer ID — **never ad-hoc**
(`codesign --sign -`), whose per-build cdhash makes TCC forget the grant on every
rebuild. It stamps both usage-description keys (`NSMicrophoneUsageDescription`,
`NSAudioCaptureUsageDescription`) and a 14.4 deployment floor. The daemon's
default `helper_path()` resolves the signed `.app` binary (no fragile env var);
`STANDBY_CAPTURE_HELPER` stays as an override.

ADR: required after this slice — it commits Core Audio taps + the dual-permission
model as product architecture.

## Oracle

Commands that must exist and exit 0 (in a permitted environment; honest
CAPTURE-BLOCKED otherwise, never a hang):

- `./scripts/verify.sh` — existing gate stays green (tests, transcriber proof, UI
  build, out-of-request worker). Adds a **preflight that fails if the shipped
  helper is ad-hoc-signed** (`codesign -dv` shows no stable identity) — the
  TCC-persistence guard.
- `./scripts/verify-capture-longrun.sh` — **fast deadlock gate (CI).** Daemon-driven
  mic+system capture for **≥ 60s**, asserting: per-lane `level_events` keep growing
  (no plateau — the deadlock signature), **bounded inter-event gap** (no silent
  stall > N ms), **zero transcriber-lane `audio.dropped`**, a single `SIGTERM`
  stops it within 3s (no `kill -9`), and `source.stopped` lands.
- `./scripts/verify-capture-meeting-duration.sh` — **the actual ship gate.** Same
  capture for **≥ 10 minutes** (matches the headline claim), asserting no plateau,
  no inter-event stall, and **zero transcriber drops or aggregate-device dropouts**
  across the full window — the regime where clock drift (20–40 min) and slow
  degradation live. The 60s gate alone is satisfiable by a build that dies at
  minute 12.
- `./scripts/verify-system-audio-tap.sh` — plays a known phrase to the default
  output (incl. HDMI), captures via the Core Audio tap, asserts: nonzero
  system-audio frames, a final transcript containing the phrase, **the phrase (not
  the mic) is what lands on the system lane**, and **the phrase stayed audible on
  the output device** (non-destructive `muteBehavior`).
- `./scripts/verify-real-transcriber-smoke.sh`, `verify-local-capture-smoke.sh`,
  `verify-local-transcript-fixture.sh` remain green. `verify-ui-states.sh` adds the
  two-permission distinction (mic-denied vs system-audio-denied render distinctly),
  driven by **injected `source.failed` events** (not a live denied grant, which
  can't be set headlessly).
- `STANDBY_LIVE_CAPTURE=1 ./scripts/verify-live-teams-local.sh` — gated dogfood over
  the new path; must run minutes without wedging.

Observable outcomes:
- A ≥10-minute capture never plateaus, never stalls, never silently drops
  transcriber audio, and never needs `kill -9`.
- System audio is captured on HDMI/Bluetooth output (Core Audio tap) while the call
  stays audible to the operator.
- A missing System-Audio-Recording grant shows a distinct card from a missing
  Microphone grant, each with its exact Settings path, classified from the actual
  capture-attempt error (no public pre-check API).

## Verification System

- Claim: Standby captures mic + all participants for a full real meeting on any
  output device without deadlocking.
- Falsifier: a short smoke passes while the helper wedges after ~8s; OR a 60s gate
  passes while the build dies at minute 12 (aggregate clock drift); OR transcriber
  audio is silently dropped (lost words, no error); OR the tap mutes the call; OR
  the grant evaporates on rebuild (ad-hoc signing); OR system audio yields zero
  frames on HDMI; OR the helper ignores SIGTERM; OR the wrong TCC tier is requested.
- Driver: `verify-capture-longrun.sh` (≥60s fast deadlock gate),
  `verify-capture-meeting-duration.sh` (**≥10-min ship gate**),
  `verify-system-audio-tap.sh` (HDMI + audible + phrase-not-mic), the deterministic
  smokes, and the gated live Teams smoke.
- Grader: level-event monotonicity AND bounded inter-event gap over ≥10 min; zero
  transcriber-lane `audio.dropped`; SIGTERM-to-stop < 3s; nonzero system frames +
  non-empty transcript on HDMI with the call still audible; `codesign -dv` shows a
  stable (non-ad-hoc) identity; distinct UI permission states from injected events.
- Evidence packet: `docs/evidence/real-meeting/` — the ≥10-min level-event +
  inter-gap timeline, drop counters, tap-capture transcript, audible-while-captured
  note, SIGTERM-latency log, HDMI-output sample, signing-identity output, UI
  screenshots for both permission states.
- Cadence: build the 60s long-run smoke FIRST (it reproduces the deadlock), keep it
  red until the concurrency rewrite lands; then the ≥10-min gate; then the tap smoke
  (HDMI + audible); then live.
- Gaps / waiver: Core Audio taps need `kTCCServiceAudioCapture` + a stable-signed
  binary; without the grant the tap smoke reports CAPTURE-BLOCKED (not hang). The
  ≥10-min gate needs a quiet capture window. A real multi-party call still needs an
  operator; the played-phrase stand-in proves the mechanism.

## Premise Source

Premise Source: sha256:dc8ed4c9f80eca1d3137bec87654c3fe651a01601dcb2733482d6dd9a39210ef docs/research/capture-helper-deadlock-and-system-audio.md

Origin waiver: this packet was shaped from a live debugging/dogfood session
(reproduced deadlock + HDMI no-frames), not a separate written premise; the
research doc is the load-bearing artifact and is digest-pinned above. No raw
audio, transcripts, credentials, or meeting URLs are included.

## Shape Review

Hardened by a fresh-context macOS-audio critic (artifact-only). It confirmed the
concurrency core is sound (`AudioDeviceCreateIOProcIDWithBlock` and HAL listeners
take dispatch queues — no CFRunLoop survives `@main async`) and surfaced 9
amendments, all folded in above. The three that were production-embarrassing:
the 60s gate couldn't prove the ≥10-min headline (clock drift) → added the
meeting-duration ship gate; ad-hoc signing evaporates the TCC grant on rebuild →
required a stable signing identity + preflight; and `kTCCServiceAudioCapture` has
no public pre-check → permission is detected by attempt-and-classify, not a
pre-emptive read.

## HTML Plan

`docs/shape/capture-helper-rewrite.html`

## Risks + Rollout

- **TCC grant evaporates on rebuild** (a real trap, found in dogfood): ad-hoc
  signing changes the cdhash each build, so macOS forgets the System-Audio + Mic
  grants. Mitigation: a **stable signing identity** (persistent self-signed cert /
  Developer ID) in `build-capture-helper.sh`; `verify.sh` preflight fails on
  ad-hoc. The new tier is detected via attempt-and-classify (no public pre-check),
  with a distinct failure card + ScreenCaptureKit fallback for built-in output.
- **Aggregate-device clock drift / dropouts at 20–40 min**: field-reported
  crackling/silence without drift correction — squarely in the meeting regime.
  Mitigation: drift correction on every sub-device/sub-tap; the **≥10-min ship
  gate** asserts no dropouts (the 60s gate can't see this).
- **Muting the call**: a wrong `muteBehavior`/`isExclusive` silences playback for
  the operator. Mitigation: observe/unmuted invariant; the tap smoke asserts the
  phrase stays audible on the output.
- **Aggregate-device config traps**: tap-as-main with empty sub-device → silence;
  inverted process/exclusive flags → silence. Mitigation: follow
  `insidegui/AudioCap` (14.4+) as the normative impl; the tap smoke asserts nonzero
  frames + a non-empty transcript so a silent misconfig fails the gate.
- **`@main async` + framework run loops**: some AVFoundation/CoreAudio callbacks
  historically want a CFRunLoop. Mitigation: Core Audio IO procs and SpeechAnalyzer
  are dispatch/async-driven; verify the long-run smoke before claiming done. Stop
  condition: if a framework genuinely requires a main CFRunLoop, document it and
  choose a run-loop-compatible structure rather than reintroducing `dispatchMain()`
  with main-actor dependencies.
- **Rollout**: land behind the lane interface; keep ScreenCaptureKit selectable so
  a tap regression can fall back. The signed `.app` becomes the default helper;
  `STANDBY_CAPTURE_HELPER` stays as an override.

Stop conditions:
- The long-run smoke still plateaus after the concurrency rewrite → the deadlock
  model is wrong; re-investigate before adding the tap.
- The Core Audio tap can't get `kTCCServiceAudioCapture` in the target
  environment → report tap-blocked; ship the concurrency fix + ScreenCaptureKit
  (built-in output) and gate the tap as operator-permission-dependent.
