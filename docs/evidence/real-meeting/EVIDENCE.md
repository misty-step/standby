# Evidence Packet — Local-Capture Real Meeting Standby

Generated on macOS 26.5.1 (this Mac), Swift 6.3.2, Rust 1.94, Node 22.

This slice replaces the demo-only loop with a real local-capture path: native
macOS audio capture, unstubbed on-device transcription, evidence-cited
proposals, and a real out-of-request worker that runs inside an OS sandbox.

## What is reproducibly green here (no special permission)

| Proof | Command | Result |
| --- | --- | --- |
| Rust unit + integration tests | `cargo test --workspace` | 18 unit + 3 fixture-replay + 1 sandbox = green |
| Canonical gate | `./scripts/verify.sh` | green (tests + helper build + transcriber smoke + UI build + out-of-request worker demo) |
| Deterministic transcription (unstubbed) | `./scripts/verify-real-transcriber-smoke.sh` | `say`-synthesized phrase → Apple Speech `SpeechAnalyzer` → `"The quick brown fox jumps over the lazy dog."` (exact), audio sample deleted |
| Transcript pipeline replay | `./scripts/verify-local-transcript-fixture.sh` | partial/final ordering, dedupe, evidence-cited proposal, projection stability |
| Worker out-of-request + artifact | `./scripts/verify-worker-runner.sh` | approval returns `queued`; background worker completes; real artifact file persisted under `.standby/jobs/<id>/` |
| Worker sandbox containment | `./scripts/verify-worker-sandbox.sh` | malicious worker fixture: repo mutation, scratch escape, and external send (incl. planted-secret exfil) all denied; visible job event still emitted |
| UI honest states | `./scripts/verify-ui-states.sh` | normal route does **not** auto-start demo (verified via real browser); waiting/capturing/transcribing/no-mic/no-system/failed/stopped/demo render; approve → worker → result; screenshots below |
| Microphone capture | `standby-capture-helper capture --mode mic` | real frames, `source.started`/`audio.source.level`/`source.stopped`, no failure |

### UI screenshots (`docs/evidence/real-meeting/ui-*.png`)

- `ui-idle.png` — normal route, no demo auto-started
- `ui-waiting.png` — waiting for permission
- `ui-capturing.png`, `ui-transcribing.png` — active lanes (mic/system meters), live transcript
- `ui-no-system-audio.png` — silent lane surfaced honestly
- `ui-failed.png` — exact missing macOS permission named
- `ui-demo.png`, `ui-completed.png` — opt-in demo + completed worker result
- `ui-worker-failed.png` — a meeting whose approved job failed. `verify-ui-states.sh`
  drives a real failure (a worker whose script is missing) and asserts
  `job.status == "failed"` at the projection level before the shot; the `JobCard`
  renders the reason + receipt path. (The failed card sits below the
  transcript-dominant fold in a static screenshot; the state is data-asserted.)
  Worker-`running` is transient (the local worker completes in milliseconds) and
  is likewise asserted via the projection + the `JobCard` running branch.

## What is permission-gated (macOS Screen-Recording TCC)

Live **system-audio** capture uses ScreenCaptureKit, which needs Screen &
System Audio Recording permission for the host process. During development this
was granted and the full path was captured end to end:

```
# real system-audio capture of a played phrase (captured when permission was granted)
{"started":true,"stopped":true,"micFrames":12,"sysMax":0.1084,
 "finals":["The quick brown fox jumps over the lazy dog."]}
# streaming partials observed: "The" -> "The quick" -> ... -> final
```

When the grant is absent (e.g. a fresh daemon process without it), the helper
now **fails honestly within an 8s watchdog** instead of hanging:

```
# ./scripts/verify-local-capture-smoke.sh
{"micFrames":2,"sysMax":0,"finals":[],"screenBlocked":true}
CAPTURE-BLOCKED: mic lane verified. System audio needs Screen-Recording permission…
```

The gated dogfood smoke behaves the same:

```
# STANDBY_LIVE_CAPTURE=1 ./scripts/verify-live-teams-local.sh
CAPTURE-BLOCKED: system audio needs Screen-Recording permission for the standbyd process…
Reported honestly, not hung.
```

## Honest status

- **Capture mechanism: proven.** Real ScreenCaptureKit system-audio capture +
  streaming SpeechAnalyzer transcription produced an exact transcript during
  development. Teams call audio flows through the identical system-audio path.
- **Dogfood readiness: operator-permission-gated.** A persistent Screen-Recording
  grant for the running `standbyd` process is required for live system audio.
  Without it, Standby is capture-smoke-ready (mic) and fixture/transcript-ready,
  not full-dogfood-ready — exactly the context packet's stated waiver.
- **Worker safety: OS-enforced** and proven by an automated negative test; the
  network-allowed cloud-model worker profiles are opt-in only
  (`STANDBY_ALLOW_NETWORK_WORKER=1`) because egress cannot be safely scoped in
  this slice. The default and accepted worker is the network-denied local one.
