# Follow-ups — after the local-capture real-meeting slice

Bigger moves surfaced while delivering this slice. Filed here rather than
smuggled into the branch.

## Security / workers
- **Egress-scoped sandbox for cloud-model workers.** `claude-research` /
  `pi-research` need network for the model API, but `sandbox-exec` can't scope
  egress to just that endpoint, so a network-allowed worker can exfiltrate any
  readable file. They are opt-in only today. To make them default-safe, run the
  worker behind a local egress proxy that allowlists the model API host, or use a
  network namespace / per-job VPN. Until then, mutation/cloud workers stay gated.
- **Per-meeting scoping of approve/ignore.** `new_id` is now collision-resistant,
  but `find_latest_proposal` is still a global by-id lookup. Thread `meeting_id`
  through the approve/ignore routes and scope the query for defense in depth.

## Capture / platform

- **Mic contention during a call (diagnosed 2026-06-18, live Google Meet).** While a
  meeting app (Chrome/Meet WebRTC) holds the microphone with voice-processing IO
  (AEC/AGC), macOS delivers SILENCE to Standby's second AVAudioEngine input client —
  the mic lane stays alive (level events flow) but RMS ~0 on every input device
  (built-in AND external). Standby's mic captures the operator's voice fine when no
  voice-processing call is active. The remote-participants path (system-audio tap /
  ScreenCaptureKit) is unaffected and works. Tried `setVoiceProcessingEnabled(true)`
  on our input (the documented call-coexistence path) — it froze capture because VPIO
  needs full-duplex setup (input wired to an active output as the echo reference);
  left opt-in behind `STANDBY_VOICE_PROCESSING=1` pending that wiring. Options to
  pursue: (a) finish the VPIO full-duplex graph; (b) per-process tap of the meeting
  app for ALL call audio incl. the operator (the app outputs the mixed call? — verify);
  (c) document mic-in-call as a known limitation and lead with remote-participant
  capture. Secondary bug found same session: the mic lane froze after ~9 min (engine
  stall on an idle/stalled input device, no auto-recovery) — add mic-stall detection
  + engine rebind, and a HAL default-input-change listener.


Much of this section was delivered by the capture-helper rewrite —
`docs/decisions/0001-core-audio-taps-and-dual-permission.md` (deadlock fix,
output-independent Core Audio taps, dual-permission model, stable-signed helper).
What remains:

- **Bundle `standbyd` itself as a signed `.app` + in-app grant flow.** The capture
  *helper* is now stably signed (its TCC grants persist across rebuilds), but the
  daemon is still launched bare. A signed `standbyd` host + an in-app "grant
  permission" button would complete the first-run UX. (Helper signing: DONE.)
- **Mic-only-continue when system audio is permission-blocked.** Today a denied
  System-Audio (or Screen-Recording) grant fails the whole capture via
  `failAndExit`; the mic lane should be able to keep running and surface the system
  lane as separately failed. Needs the projection to represent a per-lane failure
  without marking the whole source `Failed`.
- **Per-PID tap to limit mic-bleed.** The system lane uses a global output mixdown.
  The operator's own voice does not normally reach local output, but a per-PID tap
  on the meeting app (`kAudioHardwarePropertyTranslatePIDToProcessObject`) would be
  strictly safer when monitoring is on. Global mixdown is the correct default.
- **Survive a mid-meeting output-device change.** Static "any output device at
  start" is handled; a HAL default-output listener that rebuilds the aggregate when
  AirPods connect / HDMI hot-plugs is a follow-up.
- **Per-lane partial transcripts.** The projection holds a single `partial`; the
  matching-speaker clear mitigates cross-lane clobber, but a `partial` keyed by
  lane/speaker would render both lanes' in-flight utterances faithfully.

## Durability / scale
- **Operator-controlled proposals.** The Ask Standby request route, proposal
  request event, approval/job/report path, and source-provided speaker-token v1
  are delivered in this branch. The OMP/GLM/MCP worker-profile boundary remains
  gated in `backlog.d/004-tool-capable-worker-profile-boundary.md`.
- **Worker-queue recovery on restart.** The job queue is an in-memory mpsc; jobs
  queued at a crash/restart are lost. On startup, re-enqueue jobs that have
  `agent_job.requested` but no terminal event. Tracked in
  `backlog.d/006-recover-worker-queue-after-daemon-restart.md`.
- **Provider TranscriptSource adapters.** `VexaBotSource`, `RecallBotSource`,
  `TeamsGraphImportSource`, etc. for speaker diarization, bot capture, and
  post-meeting backfill — additive behind the existing `TranscriptSource` seam.
- **Proposal quality.** Automatic and Ask Standby proposal generation now uses
  the `ProposalAgent` boundary with recorded model fixtures and an opt-in live
  model provider. Next quality work should add broader held-out transcript evals
  and a realtime audio provider, not new keyword cue lists.
- **Live speaker diarization/provider attribution.** The delivered speaker v1
  preserves and renders distinct speaker tokens when a source provides them; it
  does not yet create stable remote speaker buckets from local audio. Tracked in
  `backlog.d/005-live-speaker-diarization-or-provider-attribution.md`.
