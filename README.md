# Standby

Standby is a local-first meeting command surface: a quiet panel that listens to
the call playing on your Mac, drafts evidence-cited proposal cards, and routes
approved work to an OpenCode subagent worker - keeping a durable, append-only
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
  share a typed `ProposalAgent` path that runs a real model by **default** —
  OpenRouter chat completions (`OPENROUTER_API_KEY`,
  `STANDBY_OPENROUTER_PROPOSAL_MODEL`, default `deepseek/deepseek-v4-pro`), with
  `STANDBY_PROPOSAL_PROVIDER=openai` or `=recorded` as alternates. Tests and the
  deterministic gate pin the recorded fixture; the live model is proven by
  `STANDBY_LIVE_MODEL=1 scripts/verify-live-model-proposal.sh`. Model output only
  suggests cards; Rust validates schema, evidence spans, dedupe, events, and
  approval policy.
- **Append-only suggestion feed.** Automatic cards accrue like the transcript:
  a debounced reasoner (`STANDBY_PROPOSAL_DEBOUNCE_SEGMENTS`, default 3) appends
  at most one new card per cadence as the conversation shifts, and an open card
  no longer suppresses the next one. Cards never mutate or retire — older ones
  scroll down, newest on top. The reasoner sees recent card titles and declines
  near-duplicates (dedup-by-omission). Proven live by `STANDBY_LIVE_MODEL=1
  scripts/verify-live-append-feed.sh`.
- **Ask Standby.** The operator can post an explicit proposal request to
  `POST /api/meetings/{meeting_id}/proposal-requests`. Standby records
  `proposal_request.created`, combines the message with recent finalized
  transcript spans, and asks the proposal agent for a grounded card or a
  `proposal.not_created` decision. It still does not run work until a card is
  approved.
- **OpenCode subagent worker.** Approval writes `proposal.approved` + a queued
  `agent_job.requested` and returns immediately. The product path is a single
  OpenCode worker harness: no OMP fallback, no local-research fallback, no worker
  profile selector, and no harness settings. The server owns sandbox policy,
  redaction, event recording, and receipts; OpenCode owns unsupervised agentic
  execution.
- **Operator execution gate.** Read-only meeting projection stays open, but every
  local mutation route requires the server-minted operator token. The browser
  receives it through a same-origin operator session cookie; CLI smokes pass it
  with `x-standby-operator-token`. Approval identity is server-bound. Approving
  a card is the product execution gate; worker policy and prompt redaction are
  enforced by the server before launch.

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

The worker direction is intentionally opinionated: approved work dispatches to
OpenCode by default. There is no product fallback to OMP, no deterministic
local-research fallback, no `STANDBY_WORKER_PROFILE`, no
`STANDBY_ALLOW_NETWORK_WORKER`, and no UI/settings surface for harness choice.
The product model is pinned in code to `openrouter/z-ai/glm-5.2`; it is not a
runtime setting.
If OpenCode is missing or unauthenticated, the job fails visibly with an
`agent_job.failed` receipt instead of silently switching substrates. Verification
uses a fake `opencode` executable in `PATH`; product code still launches
`opencode`.

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
| `scripts/verify-ai-execution-security.sh` | auth, origin, server-bound actor, network consent, redaction |
| `scripts/verify-opencode-worker.sh` | default OpenCode dispatch, private file transport, no fallback, visible receipts |
| `scripts/verify-ui-states.sh` | honest UI states; normal route never auto-starts demo |
| `STANDBY_LIVE_MODEL=1 scripts/verify-live-model-proposal.sh` | gated live OpenRouter proposal-provider smoke |
| `STANDBY_LIVE_MODEL=1 scripts/verify-live-append-feed.sh` | gated live proof that cards accumulate on topic shift |
| `STANDBY_LIVE_CAPTURE=1 scripts/verify-live-teams-local.sh` | gated full dogfood path over local capture |

## Red lines

Transcript text is untrusted evidence: it may quote into proposal cards, never
execute. No realtime path mutates repos, sends messages, deploys, or spends
money. Approval is a deterministic server action. Every proposal, approval, job
transition, artifact, and failure is an event.
