# Standby Vision

Date: 2026-06-20

## Audience

Standby is for operators in real meetings who need useful work to start during
the meeting without losing local control of transcript data, approvals, worker
authority, or execution evidence.

## Job To Be Done

While a call is happening, Standby listens, understands when useful work should
be proposed, lets the operator force or refine proposals, dispatches approved
agent work, and reports back with visible status and receipts.

## Category

Local-first meeting command surface: part meeting copilot, part agent dispatch
console, part append-only audit log.

## Strategic Bets

- AI-first proposal cognition: live suggestion quality comes from realtime,
  speech, and agent models, not keyword heuristics.
- Local-first authority: transcript ingestion, event logging, approval, worker
  policy, and auditability stay local and deterministic.
- Explicit control: the model can suggest; the operator approves; the server
  enforces.
- Provider-shaped speech: diarization, turn detection, and realtime voice
  understanding enter through adapters with normalized events and quality gates.
- Evidence over vibes: every claim about "works" leaves a replayable command,
  transcript, screenshot, eval report, or worker receipt.

## Non-Goals

- Fully autonomous live meeting execution without approval.
- Hidden network/model dispatch from transcript text.
- Fake speaker names without provider identity or known-speaker evidence.
- UI-only fixes that do not address proposal quality, worker reliability, or
  meeting privacy.

## Six To Twelve Month Target

A solo operator can join a real Google Meet or Teams call, see speaker-aware
transcript context, ask Standby for proposals when needed, receive proactive
model-native action cards, approve safe agent work, watch durable job status,
and inspect artifacts after the meeting. The same flow is covered by local
replay fixtures, model-quality evals, diarization smokes, worker sandbox tests,
and permission-gated live dogfood.
