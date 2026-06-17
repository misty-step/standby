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
- **Worker-queue recovery on restart.** The job queue is an in-memory mpsc; jobs
  queued at a crash/restart are lost. On startup, re-enqueue jobs that have
  `agent_job.requested` but no terminal event.
- **Provider TranscriptSource adapters.** `VexaBotSource`, `RecallBotSource`,
  `TeamsGraphImportSource`, etc. for speaker diarization, bot capture, and
  post-meeting backfill — additive behind the existing `TranscriptSource` seam.
- **Proposal quality.** The cue-based detector is a first heuristic. Consider a
  local model classifier behind the same evidence-cited interface.
