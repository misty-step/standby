# Standby

Standby is a local-first meeting command surface: a quiet panel that listens to
the call playing on your Mac, drafts evidence-cited proposal cards, and routes
approved work to a sandboxed local worker agent — keeping a durable, append-only
event ledger of every step.

The realtime path is intentionally narrow. It can create proposal cards and
private meeting state from transcript evidence. It cannot mutate external
systems. Approved cards become worker jobs only through a deterministic,
server-owned approval endpoint.

## How it works

- **Local capture (default).** A tiny native helper (`native/standby-capture-helper`,
  Swift) captures microphone (AVAudioEngine) and system/app audio
  (ScreenCaptureKit) and transcribes on-device with the macOS 26 Apple Speech
  `SpeechAnalyzer`. It emits only JSONL — no SQLite, no workers, no credentials.
  Teams is the first dogfood app, but any call routed through the Mac is captured
  the same way. Provider adapters (Vexa/Recall/Graph) can be added later behind
  the same `TranscriptSource` seam.
- **Rust owns durable behavior.** `standby-core` normalizes capture events,
  projects honest source/transcript/job state, validates evidence-cited
  proposal-agent output, and runs workers. `standbyd` (axum) owns routes, the
  SQLite ledger, capture supervision, and an out-of-request worker queue.
- **AI-first proposals.** Automatic transcript windows and Ask Standby requests
  share a typed `ProposalAgent` path. CI uses recorded model responses; dogfood
  can opt into OpenAI Responses with `STANDBY_PROPOSAL_PROVIDER=openai`,
  `STANDBY_OPENAI_PROPOSAL_MODEL`, and `OPENAI_API_KEY`. Model output only
  suggests cards; Rust validates schema, evidence spans, dedupe, events, and
  approval policy.
- **Ask Standby.** The operator can post an explicit proposal request to
  `POST /api/meetings/{meeting_id}/proposal-requests`. Standby records
  `proposal_request.created`, combines the message with recent finalized
  transcript spans, and asks the proposal agent for a grounded card or a
  `proposal.not_created` decision. It still does not run work until a card is
  approved.
- **Sandboxed worker.** Approval writes `proposal.approved` + a queued
  `agent_job.requested` and returns immediately. A background worker runs the job
  inside a macOS `sandbox-exec` jail whose only writable target is the per-job
  scratch dir; the default profile denies network. Failures surface as
  `agent_job.failed` with a reason and an on-disk receipt.

## Run

```sh
./scripts/verify.sh                 # gate: tests, helper build, transcriber proof, UI build, worker smoke
./scripts/build-capture-helper.sh   # build the native capture helper
cargo run -p standbyd               # then open http://127.0.0.1:4317
```

The normal route does not auto-start anything. Click **Start capture** to listen
to the live call; macOS will ask for Microphone and Screen-Recording permission.
Append `?mode=demo&meeting=demo` for the seeded demo meeting.

## Permissions

Live system audio needs **Screen & System Audio Recording** permission for the
running process; the microphone lane needs **Microphone** permission. Without the
screen-recording grant, capture fails honestly (a visible card naming the exact
permission), never a hang. See `docs/evidence/real-meeting/EVIDENCE.md`.

## Workers

The default and only sandbox-accepted worker is `local-research` (a real
subprocess, no network/model — proves the runner + sandbox). Cloud-model
profiles (`claude-research`, `pi-research`) are opt-in only via
`STANDBY_ALLOW_NETWORK_WORKER=1`: a network-allowed worker can read local files,
so egress would need scoping that this slice does not yet provide. Mutation-capable
workers remain disabled pending executable permission enforcement.

## Verification

| Script | Proves |
| --- | --- |
| `scripts/verify.sh` | Rust tests, helper build, transcription, UI build, out-of-request worker |
| `scripts/verify-model-proposals.sh` | recorded model fixtures, model-output validation, no heuristic engine symbols |
| `scripts/verify-real-transcriber-smoke.sh` | unstubbed on-device transcription (deterministic) |
| `scripts/verify-local-transcript-fixture.sh` | transcript ordering, dedupe, evidence-cited proposals |
| `scripts/verify-manual-proposal-request.sh` | Ask Standby route, cited proposals, approval, worker result |
| `scripts/verify-speaker-distinction-fixture.sh` | distinct speaker tokens are preserved and rendered |
| `scripts/verify-local-capture-smoke.sh` | real mic frames; system-audio transcript when permitted |
| `scripts/verify-worker-runner.sh` | out-of-request job → sandboxed worker → real artifact |
| `scripts/verify-worker-sandbox.sh` | malicious worker cannot mutate repo, escape scratch, or exfiltrate |
| `scripts/verify-ui-states.sh` | honest UI states; normal route never auto-starts demo |
| `STANDBY_LIVE_MODEL=1 scripts/verify-live-model-proposal.sh` | gated live OpenAI proposal-provider smoke |
| `STANDBY_LIVE_CAPTURE=1 scripts/verify-live-teams-local.sh` | gated full dogfood path over local capture |

## Red lines

Transcript text is untrusted evidence: it may quote into proposal cards, never
execute. No realtime path mutates repos, sends messages, deploys, or spends
money. Approval is a deterministic server action. Every proposal, approval, job
transition, artifact, and failure is an event.
