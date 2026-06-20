# Context Packet: AI-First Proposal Agent

## PRD Summary

- User: meeting operator using Standby during a real Google Meet or Teams call.
- Problem: Standby's current automatic proposal path only recognizes brittle
  research phrases, so the product behaves like a keyword demo instead of a live
  AI meeting command surface.
- Goal: replace heuristic-primary proposal detection with a model-native
  proposal agent that can proactively suggest cards and respond to operator
  nudges while preserving deterministic approval and worker policy.
- Why now: live meeting dogfood exposed missed proposals, opaque worker status,
  and multi-speaker ambiguity; external model surfaces now support realtime
  speech/voice reasoning and side-channel classification.
- UX enabled: the operator can let Standby listen, force proposal generation
  with a short prompt, approve grounded task cards, and see why no card was
  proposed when confidence is low.
- Deliverable type: working code plus model-quality verification harness.
- Success signal: a held-out transcript set and an API route replay both produce
  grounded proposal/no-proposal outcomes through the model-native boundary, not
  through `RESEARCH_CUES`.

## Product Requirements

- P0: automatic live proposals and Ask Standby requests must flow through a
  typed `ProposalAgent` boundary whose primary implementation is model-native.
- P0: deterministic Rust still owns schema validation, dedupe, event logging,
  user approval, worker dispatch, and sandbox policy.
- P0: no worker starts from transcript/model output without approval.
- P0: proposal cards cite transcript evidence and include a visible model
  confidence/reasoning summary suitable for the operator.
- P0: low-confidence or unsafe model output creates a visible no-proposal or
  rejection event, not a fake card.
- P0: CI has a deterministic proposal-quality gate using recorded model outputs
  or a fake provider, plus an opt-in live provider smoke for real credentials.
- P1: realtime OpenAI path uses out-of-band text responses for proposal judging
  so the agent does not speak into the meeting.
- P1: provider interface is compatible with Gemini Live or transcript-only
  speech providers without rewriting product core.
- Non-goals: default network worker execution, named speaker identity,
  autonomous external sends, repo mutation, or full UI redesign.

## Technical Design

### Chosen Architecture

Add a deep model boundary:

```text
TranscriptSource / optional audio context
  -> ProposalAgent::propose(window, state, optional operator nudge)
  -> ProposalCandidate JSON schema
  -> deterministic validation/policy/dedupe
  -> proposal.created or proposal_request.rejected/no_proposal event
  -> approval endpoint
  -> WorkerProfile dispatch
```

The first implementation has two provider modes behind the same boundary:

- `RecordedProposalAgent`: deterministic test provider backed by checked-in
  request/response fixtures for CI.
- `OpenAiResponsesProposalAgent`: opt-in live transcript-window provider behind
  `STANDBY_PROPOSAL_PROVIDER=openai`, `STANDBY_OPENAI_PROPOSAL_MODEL`, and
  `OPENAI_API_KEY`.

There is no primary heuristic fallback in source. Realtime remains the preferred
next provider for live audio reasoning, but it should use the same
`ProposalAgent` schema, validation, and event contract.

### Files / Systems Touched

- `crates/standby-core/src/engine.rs`: typed `ProposalAgent`, recorded model
  provider, OpenAI Responses provider, deterministic validation, and no-proposal
  decisions.
- `crates/standby-core/src/proposal_request.rs`: route manual Ask Standby
  through `ProposalAgent`.
- `crates/standby-core/src/domain.rs`: projection/domain fields for
  no-proposal decisions and model metadata.
- `crates/standby-core/src/event_log.rs`: project new proposal/no-proposal
  events.
- `crates/standbyd/src/main.rs`: own provider config, route replay, and
  proposal-agent invocation.
- `scripts/verify-model-proposals.sh`: fixture quality gate.
- `scripts/verify-live-model-proposal.sh`: opt-in live-provider smoke.
- `ui/src/main.tsx`: show confidence, source, model/no-proposal state, and
  existing approval/job status.

### Data / Control Flow

Automatic path:

1. final transcript segment is appended.
2. daemon builds a bounded transcript window and current meeting state.
3. `ProposalAgent` returns zero or more candidates.
4. Rust validates schema, evidence span IDs, policy, max card count, and dedupe.
5. accepted candidates append `proposal.created`; rejected/low-confidence output
   appends a visible no-proposal event.

Ask Standby path:

1. operator posts message plus context window.
2. event log records `proposal_request.created`.
3. same `ProposalAgent` evaluates the operator nudge plus transcript context.
4. approval remains unchanged and out-of-request.

### ADR Decision

ADR required if the implementation commits to Realtime WebSocket as the first
provider boundary. Not required for a transcript-window model adapter that keeps
the same `ProposalAgent` interface and leaves Realtime as a provider swap.

Escalate before coding if the first slice would require raw audio persistence
or default network worker execution.

## Lead Repo Read

- `AGENTS.md`: local-first, approval, worker, and AI-first repo contract.
- `docs/vision.md`: product vision and non-goals.
- `docs/research/realtime-voice-model-substrates.md`: current provider facts.
- `crates/standby-core/src/engine.rs`: model-shaped proposal-agent path.
- `crates/standby-core/src/proposal_request.rs`: deterministic Ask Standby
  request/context event builder.
- `crates/standby-core/src/worker.rs`: worker profile and sandbox boundary.
- `crates/standbyd/src/main.rs`: proposal-request and approval endpoints.
- `scripts/verify-manual-proposal-request.sh`: current route replay oracle.
- `scripts/verify-live-teams-local.sh`: permission-gated live dogfood path.

## Alternatives

| Option | Why it helps | Failure mode | Verdict |
| --- | --- | --- | --- |
| Tune cue lists | Smallest diff. | Still misses paraphrases and overfits exact phrasing. | Reject as primary; fallback only. |
| Transcript-window model adapter first | Fastest model-native slice; easy CI fixtures. | Not full realtime audio reasoning. | Choose first if Realtime WebSocket would delay quality gate. |
| OpenAI Realtime first | Best product fit for live meeting agent and out-of-band classifier. | More moving parts: sessions, audio transport, provider auth, live smokes. | Choose once transcript-window schema/eval is green or if implementation proves small. |
| Gemini Live first | Strong voice/video agent surface and proactive audio. | Additional provider surface before OpenAI path is proven locally. | Comparator provider after first boundary. |
| External STT/diarization only | Improves transcript quality and speaker buckets. | Still does not solve proposal cognition. | Parallel epic, not replacement. |
| Direct model tools/workers | Feels agentic quickly. | Violates approval/security unless egress and tools are gated. | Defer behind secure execution epic. |

## Oracle

Automated commands:

- `./scripts/verify-model-proposals.sh` passes with fixtures covering positive
  asks, paraphrases, negations, market chatter false positives, operator nudges,
  malformed model JSON, and missing-evidence rejections.
- `./scripts/verify-manual-proposal-request.sh` still passes, but asserts the
  proposal source is model-native or recorded-provider, not heuristic-primary.
- `./scripts/verify.sh` remains green.

Opt-in live command:

- `STANDBY_LIVE_MODEL=1 ./scripts/verify-live-model-proposal.sh` starts a local
  daemon, sends a real provider request, records request/response redactions, and
  emits PASS/FAIL evidence without committing secrets or raw audio.

Observable QA:

- In a solo Google Meet, transcript comes in, Standby proposes at least one
  grounded task for a semantically phrased ask that does not contain the old
  exact trigger phrase, and the operator can approve it into a visible job.

## Verification System

- Claim: Standby proposal behavior is model-native, grounded, and approval-safe.
- Falsifier: a semantically clear ask fails unless it matches a cue phrase, a
  vague/negated prompt creates a card, a card cites nonexistent spans, malformed
  model output reaches the UI, or a worker starts before approval.
- Driver: fixture route replay, model-response fixture grader, full gate, and
  opt-in live-provider smoke.
- Grader: JSON schema assertions, evidence span matching, expected
  propose/no-propose labels, approval/job event assertions, and visible UI state.
- Evidence packet: `docs/evidence/ai-first-proposals/`.
- Cadence: fixture gate on every PR; live provider smoke during dogfood and
  before product-ready claims.
- Gaps / waiver: full realtime audio reasoning may be a second provider slice
  if the first model-native transcript adapter proves the same contract.

## Premise Source

Premise Source: sha256:b6d1895601258d68de0c63eb00a593cbffd36e2edf55aded84cf540f82dc99c5 `docs/premises/2026-06-20-ai-first-standby.md`

Supporting research: sha256:c2c712055c03e622345c87c61b26bbe4662da8cf0f0a73a512a744eae6b65adb `docs/research/realtime-voice-model-substrates.md`

## HTML Plan

`docs/shape/ai-first-proposal-agent.html`

## Risks + Rollout

- Model cost/latency can make live proposals noisy or slow. Keep bounded
  windows, low-card count, visible confidence, and no-proposal states.
- Provider failures can block dogfood. Keep recorded-provider fixtures in CI and
  live smokes opt-in.
- Privacy risk increases when sending transcript context to cloud models.
  Redact where possible, log provider use, and require explicit config for live
  provider calls.
- Security risk increases if proposal generation is coupled to worker tools.
  Keep proposal model output as suggestions only; do not add network workers in
  this slice.

Stop if implementation needs default cloud worker execution, raw audio checked
into the repo, or model output that bypasses deterministic approval.
