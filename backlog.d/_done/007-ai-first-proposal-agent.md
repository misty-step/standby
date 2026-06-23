# Replace heuristic proposal detection with a model-native proposal agent

Priority: P0 · Status: done · Estimate: L

## Goal
Standby proposes and force-generates useful meeting action cards through a model-native proposal agent, with deterministic approval and worker policy still owned by the server.

## PRD Summary
- User: meeting operator in a live Google Meet or Teams call.
- Problem: automatic proposals currently depend on phrase lists, so clear semantic asks are missed unless they match exact trigger language.
- Goal: route automatic and Ask Standby proposal generation through a typed model-native boundary with grounded proposal/no-proposal outcomes.
- Why now: live dogfood showed the proposal brain is the wrong abstraction; current provider surfaces support realtime/voice/semantic proposal judging.
- UX enabled: the operator sees proactive cards, can force proposals, sees low-confidence/no-proposal states, approves grounded work, and watches job status.
- Deliverable type: working code plus model-quality verification harness.
- Success signal: a held-out transcript fixture set proves paraphrased asks produce grounded cards and vague/negated chatter does not.

## Product Requirements
- P0: introduce a `ProposalAgent` boundary for automatic and operator-forced proposal generation.
- P0: add a recorded/fake provider for deterministic CI and an opt-in live model provider for dogfood.
- P0: delete `ProposalEngine` cue matching from source once the model-native path exists.
- P0: validate model output through typed schema, evidence-span checks, dedupe, policy gates, and event logging before any UI card appears.
- P0: never start a worker until the existing approval endpoint records approval and queues a job.
- P1: expose model source, confidence, rejection/no-proposal reason, and prompt lineage in projection/UI.

## Technical Design
- Chosen architecture: `TranscriptSource`/context window -> `ProposalAgent` -> `ProposalCandidate` schema -> deterministic validation -> `proposal.created` or no-proposal/rejection event -> approval -> `WorkerProfile`.
- Files/systems touched: `crates/standby-core/src/engine.rs`, `proposal_request.rs`, `domain.rs`, `event_log.rs`, `crates/standbyd/src/main.rs`, `ui/src/main.tsx`, proposal verification scripts.
- Data/control flow: automatic final segments and Ask Standby requests share the same proposal-agent path; operator nudge is input, transcript spans are evidence, model output is suggestion only.
- Build/check boundary: Rust tests prove schema/event behavior; fixture grader proves proposal quality; live smoke proves provider integration.
- ADR decision: required only if the first implementation commits to Realtime WebSocket/session ownership rather than a transcript-window model adapter.
- ADR-style invariants: transcript text remains untrusted; approval is deterministic; model output never executes work; every accepted/rejected proposal decision is an event.
- Design X vs Y: tune cue lists rejected as primary; transcript-window model adapter accepted as fastest first model-native slice if Realtime would delay the quality gate; OpenAI Realtime remains preferred live meeting target.

## Lead Repo Read
- `docs/context-packets/ai-first-proposal-agent.md`
- `docs/shape/ai-first-proposal-agent.html`
- `docs/vision.md`
- `docs/research/realtime-voice-model-substrates.md`
- `crates/standby-core/src/engine.rs`
- `crates/standby-core/src/proposal_request.rs`
- `crates/standby-core/src/worker.rs`
- `crates/standbyd/src/main.rs`
- `scripts/verify-manual-proposal-request.sh`
- `scripts/verify-live-teams-local.sh`

## Alignment Questions
- Recommended first provider: transcript-window OpenAI model adapter using the final `ProposalAgent` schema if it gets the quality gate green fastest; move to Realtime WebSocket as the next provider slice.
- Risk if wrong: starting with transcript-only may leave some voice prosody/turn-taking value on the table, but it prevents another unverified architecture jump.

## Deliverable
- Output: typed proposal-agent boundary, recorded CI provider, opt-in live model provider, model/no-proposal events, and UI display for model source/confidence.
- Acceptance oracle: commands below all pass.
- Evidence artifacts: `docs/evidence/ai-first-proposals/`, live provider redacted receipt, seeded UI projection receipts.
- Residual risk: realtime audio reasoning quality remains unproven until the Realtime provider slice lands.

## Oracle
- [x] `./scripts/verify-model-proposals.sh` passes fixtures for paraphrased asks, no-card decisions, malformed model output, missing evidence, and operator-forced requests.
- [x] `./scripts/verify-manual-proposal-request.sh` proves Ask Standby uses the model-native or recorded-provider path and still queues no job before approval.
- [x] `./scripts/verify.sh` remains green.
- [x] `STANDBY_LIVE_MODEL=1 ./scripts/verify-live-model-proposal.sh` produces a redacted PASS evidence packet when provider credentials are configured.

## Verification System
- Claim: Standby proposal behavior is model-native, grounded, and approval-safe.
- Falsifier: a clear paraphrased ask fails unless it matches a cue phrase, vague/negated text creates a card, model JSON bypasses validation, evidence span IDs are invented, or a worker starts before approval.
- Driver: proposal fixture grader, seeded route replay, full gate, and opt-in live-provider smoke.
- Grader: expected propose/no-propose labels, schema checks, evidence-span membership checks, event assertions, and approval/job assertions.
- Evidence packet: `docs/evidence/ai-first-proposals/`.
- Cadence: fixture gate on every PR; live provider smoke during dogfood and before product-ready claims.

## Children
1. Done: built `scripts/verify-model-proposals.sh` and checked-in model response fixtures.
2. Done: added `ProposalAgent` request/candidate/no-proposal structs and validation in Rust core.
3. Done: implemented recorded provider and routed automatic plus Ask Standby paths through it.
4. Done: added opt-in OpenAI Responses provider and redacted evidence capture.
5. Done: updated UI projection for model source, confidence, and no-proposal state.
6. Done: deleted primary cue-list detection from source.

## Implementation Receipt

- `crates/standby-core/src/engine.rs` now owns the typed `ProposalAgent` boundary,
  recorded provider, OpenAI Responses provider, schema/evidence validation, and
  no-proposal decisions.
- `proposal.created` cards carry `ProposalModelMetadata`; `proposal.not_created`
  events project into `MeetingProjection.no_proposals`.
- Automatic transcript proposals dedupe while an open proposal exists; explicit
  Ask Standby requests can still force a new model-agent proposal.
- Evidence:
  - `docs/evidence/ai-first-proposals/ui-render-state-receipt.json`
  - `docs/evidence/ai-first-proposals/live-model/redacted-pass.json`

## Notes
Premise Source: sha256:b6d1895601258d68de0c63eb00a593cbffd36e2edf55aded84cf540f82dc99c5 `docs/premises/2026-06-20-ai-first-standby.md`

Why: direct repo read plus architecture/product, verification, and harness lanes all found the same root cause: phrase heuristics are currently the proposal brain.
