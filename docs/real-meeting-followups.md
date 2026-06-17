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
- **Stable Screen-Recording TCC identity.** ScreenCaptureKit system audio needs a
  persistent Screen-Recording grant for the host process; a freshly built/launched
  daemon loses it. Bundle `standbyd` (or a capture host) as a signed `.app` so the
  TCC grant sticks across launches, and add an in-app "grant permission" flow.
- **Per-lane partial transcripts.** The projection holds a single `partial`; the
  matching-speaker clear mitigates cross-lane clobber, but a `partial` keyed by
  lane/speaker would render both lanes' in-flight utterances faithfully.
- **Mic-only fallback.** When system audio is permission-blocked, optionally
  continue mic-only instead of failing the whole capture.

## Durability / scale
- **Worker-queue recovery on restart.** The job queue is an in-memory mpsc; jobs
  queued at a crash/restart are lost. On startup, re-enqueue jobs that have
  `agent_job.requested` but no terminal event.
- **Provider TranscriptSource adapters.** `VexaBotSource`, `RecallBotSource`,
  `TeamsGraphImportSource`, etc. for speaker diarization, bot capture, and
  post-meeting backfill — additive behind the existing `TranscriptSource` seam.
- **Proposal quality.** The cue-based detector is a first heuristic. Consider a
  local model classifier behind the same evidence-cited interface.
