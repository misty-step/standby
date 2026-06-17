# Context Packet: Real Meeting Standby

## PRD Summary

- User: Phaedrus, using Standby during live calls.
- Problem: Standby currently demonstrates the command-surface loop with seeded
  transcript spans and a mock research worker, so it cannot be trusted in an
  actual Teams meeting.
- Goal: Make Standby ingest a real Microsoft Teams meeting transcript and route
  an approved proposal to a real local worker agent with durable progress and
  artifact events.
- Why now: Without real capture and real worker dispatch, the product cannot be
  dogfooded in the next meeting and the UI overclaims production behavior.
- UX enabled: The user can connect a Teams meeting, see live transcript source
  status, approve an editable proposal, watch a real local agent job run, and
  inspect the resulting artifact or failure receipt.
- Deliverable type: Working code plus verification harness.
- Success signal: A live Teams/Vexa meeting produces `transcript.segment.final`
  events and an approved read-only research job produces an artifact generated
  by a local CLI agent, not `MockResearchWorker`.

## Product Requirements

- P0: Teams-first real capture through a provider adapter; use Vexa before
  building a Microsoft-native Windows/.NET media bot.
- P0: Approval must enqueue a worker job; it must not run long-lived worker CLI
  processes inside the HTTP approval request.
- P0: The first real worker is read-only research. Coding/repo mutation workers
  remain disabled until permission enforcement is executable.
- P0: Transcript text remains untrusted evidence. It may create proposal cards
  with quoted evidence; it may not directly mutate repos, send messages, deploy,
  or spend money.
- P0: UI must distinguish demo, connecting, live transcript, reconnecting,
  failed auth, job queued, worker running, worker failed, and completed states.
- P0: Every source event, proposal, approval, job transition, artifact, and
  failure is appended to SQLite.
- P1: Add fixture replay for Vexa WebSocket payloads so reconnect/dedupe logic
  can be tested without a live meeting.
- P1: Add a live Teams smoke script that runs only when `VEXA_API_KEY`,
  `VEXA_API_BASE`, `STANDBY_TEAMS_MEETING_ID`, and `STANDBY_TEAMS_PASSCODE` are
  present.
- P1: Preserve the current demo route as an explicit demo mode, not as the
  default live UI path.
- Non-goals: Native macOS any-app capture in this first slice; Microsoft Graph
  post-meeting transcript ingestion; writing a Teams app/media bot from scratch;
  mutation-capable Codex/Claude repo jobs; automatic Slack/email/client
  messages.

## Technical Design

Chosen architecture: add two deep modules behind narrow interfaces.

1. `TranscriptSource` adapter layer
   - First implementation: `VexaTranscriptSource`.
   - Inputs: meeting platform, native Teams meeting ID, passcode, API base, API
     key from environment or local config.
   - Flow: `POST /bots`, REST transcript bootstrap, WebSocket subscribe, normalize
     mutable transcript updates into Standby transcript events, dedupe by source
     segment identity and updated timestamp, append final segments to SQLite.
   - Emits: `transcript.source.started`, `transcript.source.connected`,
     `transcript.segment.partial`, `transcript.segment.final`,
     `transcript.source.reconnecting`, `transcript.source.failed`,
     `transcript.source.stopped`.

2. `WorkerRunner` adapter layer
   - First implementation: local subprocess research worker.
   - Approval endpoint writes `proposal.approved` and `agent_job.requested`, then
     returns immediately.
   - A Tokio background worker or separate `standby-worker` process claims queued
     jobs, launches the configured CLI, streams normalized `agent_job.started`,
     `agent_job.progress`, `artifact.created`, `agent_job.completed`, or
     `agent_job.failed` events.
   - First profile should be read-only and time-bounded. Prefer `codex` when
     available because local help confirms `exec`, `--json`,
     `--output-last-message`, `--sandbox`, `--ask-for-approval`, and `-C`.
     Claude, Pi, Opencode, Goose, and others are later profiles behind the same
     runner.

Data/control flow:

```text
Teams meeting id/passcode
  -> VexaTranscriptSource
  -> normalized transcript events
  -> proposal detector
  -> proposal card
  -> deterministic approval endpoint
  -> queued AgentJobSpec
  -> WorkerRunner subprocess
  -> normalized job/artifact events
  -> React card projection
```

Build/check boundary:

- Build catches schema mismatches, route wiring, and TypeScript projection
  expectations.
- Fixture replay catches source dedupe, reconnect ordering, and projection
  stability.
- Live Teams smoke catches provider auth, bot join, WebSocket subscription, and
  real transcript flow.
- Worker smoke catches CLI availability, auth prompts, timeout behavior, and
  artifact persistence.

ADR decision: required after this slice, not before. This slice can live as a
context-packet-backed implementation. Create an ADR if a second capture provider
or a mutation-capable worker is added, because that commits the adapter and
permission model as product architecture.

ADR-style invariants:

- Invariant: approval is deterministic and server-owned. If violated, transcript
  text can become an LLM-controlled action path. Core refs:
  `AGENTS.md`, `crates/standbyd/src/main.rs`.
- Invariant: provider-specific capture stays behind transcript source adapters.
  If violated, Vexa/Teams details leak into proposal/UI/job modules. Core refs:
  `crates/standby-core/src/domain.rs`, `crates/standby-core/src/engine.rs`.
- Invariant: worker execution is out-of-request and event-sourced. If violated,
  the UI hangs and failures disappear. Core refs:
  `crates/standby-core/src/worker.rs`, `crates/standby-core/src/event_log.rs`.
- Invariant: first real worker cannot mutate repos or external systems. If
  violated, an approved meeting card can have a larger blast radius than the
  user saw in the card.

## Lead Repo Read

- `AGENTS.md`: local safety and gate contract.
- `README.md`: current demo/mock boundaries.
- `crates/standby-core/src/domain.rs`: transcript, proposal, job, artifact, and
  event schemas.
- `crates/standby-core/src/engine.rs`: current hard-coded proposal detector.
- `crates/standby-core/src/worker.rs`: `MockResearchWorker` and synchronous
  approval behavior.
- `crates/standby-core/src/event_log.rs`: SQLite event projection behavior.
- `crates/standbyd/src/main.rs`: current routes and approval endpoint.
- `ui/src/main.tsx`: current demo auto-start and overclaimed live UI states.
- `scripts/verify.sh`: existing proof loop for demo seeding and mock completion.
- `docs/research/real-meeting-capture-and-workers.md`: source-backed research
  for Teams, Vexa, macOS capture, and local CLI workers.

## Alternatives

| Option | Why it helps | Failure mode | Verdict |
| --- | --- | --- | --- |
| Vexa Teams adapter first | Fastest real Teams path; WebSocket transcript protocol exists; can later self-host. | Vendor dependency, bot participant, meeting ID/passcode and account limits. | Choose for first real slice. |
| Microsoft real-time media bot first | Platform-native raw media and Teams official support. | App-hosted media is Windows/.NET-shaped and Microsoft says raw media bots are not recommended for AI meeting-agent scenarios. | Reject for first slice; revisit for enterprise/native Teams path. |
| Microsoft Graph transcripts/AI insights first | Official Graph permissions and post-meeting artifacts. | Not live; insights can be delayed and require Copilot license. | Reject for live meeting command surface; useful later for post-meeting enrichment. |
| Native macOS capture first | Ultimately works with any call/app and keeps data local. | Higher platform-permission and transcription complexity; weaker speaker identity; slower to dogfood Teams tomorrow. | Defer to second slice. |
| Keep mock worker and only fix capture | Easier and narrows implementation. | Violates user requirement; approved cards still do not do real work. | Reject. |
| Launch CLI worker synchronously in approval request | Smallest diff. | Hangs UI, loses progress, auth prompts block HTTP, no durable retries. | Reject. |

Delete-first / Ponytail answer:

- Requirement questioned: do we need Teams-native raw media for the first usable
  product? No; the user outcome is live transcript cards in Teams, not raw media
  ownership.
- Deleted or simplified: no Windows/.NET Teams bot, no native Mac capture in
  slice one, no mutation-capable coding agents, no generic worker marketplace.
- Only then optimized/automated because: Vexa plus a local subprocess runner is
  the shortest path that satisfies real meeting input and real approved work.

## Oracle

Commands that must exist and exit 0 after implementation:

- `./scripts/verify.sh` - existing Rust, frontend, build, and API smoke remain
  green.
- `./scripts/verify-vexa-fixture.sh` - replays recorded/sanitized Vexa WebSocket
  payloads, proves dedupe/reconnect handling, and verifies final transcript
  projection.
- `./scripts/verify-worker-runner.sh` - enqueues a read-only research job,
  launches a real installed CLI in a bounded sandbox/profile, records stdout or
  final response to an artifact file, and appends completed/failed events.
- `STANDBY_LIVE_TEAMS=1 ./scripts/verify-live-teams.sh` - when Vexa and Teams
  credentials are present, starts a bot for a real Teams meeting, receives at
  least one transcript segment, creates a proposal, approves it, and observes a
  real local worker artifact.

Observable outcomes:

- The UI no longer auto-starts demo mode on the normal meeting route.
- Source status is explicit: demo, connecting, live, reconnecting, failed, or
  stopped.
- A failed Vexa auth or bot join produces a visible failure card and
  `transcript.source.failed` event.
- A failed CLI auth or timeout produces a visible `agent_job.failed` card with a
  receipt path, not a spinner.
- Approved jobs show live status from event projection, not hard-coded progress.

## Verification System

- Claim: Standby can be used in a real Teams meeting to detect a useful proposal
  and run approved read-only research through a local agent.
- Falsifier: a demo fixture can pass while a live Teams/Vexa bot never connects,
  transcript reconnects duplicate segments, or worker CLI auth hangs the
  approval request.
- Driver: fixture replay scripts, real Teams smoke script, local worker smoke,
  browser inspection of the UI, and `./scripts/verify.sh`.
- Grader: event log contains expected source/job/artifact event types; projection
  has ordered transcript segments; worker artifact file exists; HTTP approval
  returns before worker completion; UI shows correct source/job states.
- Evidence packet: `docs/evidence/real-meeting/` should contain sanitized Vexa
  replay payloads, command logs, worker artifact, browser screenshots, and final
  event projection JSON.
- Cadence: run fixture and worker scripts before each milestone; run live Teams
  smoke before claiming dogfood readiness; run browser check before closeout.
- Gaps / waiver: live Teams smoke requires external credentials and a meeting
  where a bot may join. If unavailable, implementation is not dogfood-ready; it
  is fixture-ready only.

## Premise Source

Premise Source: sha256:0c05cb137e5f9e87a67a5a3c7bd230e7388a0b81bb3d0284327da85fd9d753fa docs/premises/2026-06-17-standby-real-meeting.md

## HTML Plan

`docs/shape/real-meeting-standby.html`

## Risks + Rollout

- Provider dependency: Vexa may fail on account limits, bot admission, or Teams
  settings. Mitigation: fixture replay plus explicit live-smoke waiver.
- Consent/compliance: bot-based and local capture both require meeting-consent
  behavior outside the model. Mitigation: visible source state and no stealth
  capture language.
- CLI auth prompts: local worker commands can block. Mitigation: process
  timeout, stderr capture, and `agent_job.failed`.
- Proposal quality: current detector is demo-specific. Mitigation: first slice
  adds real transcript fixtures and requires evidence-cited proposal tests.
- Permission drift: future coding workers can mutate files. Mitigation: keep
  first worker read-only and require an ADR plus executable permission tests
  before enabling mutation-capable profiles.

Stop conditions:

- No Vexa API key or test meeting is available and the user expects live
  dogfooding; report fixture-ready only.
- The worker runner cannot launch any installed CLI without interactive auth;
  report capture-ready only.
- The UI cannot show source/job failures distinctly; do not claim usable live
  meeting behavior.
