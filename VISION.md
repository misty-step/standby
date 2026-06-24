# Standby — Vision

Standby is a local-first, AI-first meeting command surface for macOS. While a
call plays on your Mac, it listens, proposes evidence-cited work when work is
worth proposing, lets you approve it, dispatches a sandboxed agent to do it, and
keeps an append-only receipt of every step. The word that has to earn itself is
*command*: Standby does not just remember the meeting, it acts inside it.

Date: 2026-06-24 · Lifespan: long-lived product substrate, builder-dogfooded
first. Revise when live evidence contradicts a bet; do not churn it per backlog
edit.

## Who it's for

A solo operator whose meetings generate work — a founder, consultant, eng lead,
or customer-facing PM — who needs useful work to *start during the call* without
surrendering local control of transcript data, approvals, worker authority, or
execution evidence. The first lovable user is the builder running Standby on
their own real Meet/Teams calls.

## The job

While a call is happening: listen, understand when work is worth proposing, let
the operator force or refine proposals, dispatch approved agent work, and report
back with visible status, receipts, and — the part that makes it a command
surface — a result the operator can act on before the call ends.

## What it is (and isn't)

Part meeting copilot, part agent-dispatch console, part append-only audit log.
It is **not** a notetaker (Granola/Otter/Fathom record; Standby acts), and it is
**not** a chat assistant bolted onto a transcript (ChatGPT has no meeting context
and cannot dispatch bounded work under local authority). The wedge is the
intersection: meeting context + during-the-call action + local control + a
receipt for everything.

## Strategic bets

- **Model-native cognition, not keyword heuristics.** Live suggestion quality
  comes from model APIs behind a typed boundary — currently an OpenRouter
  cascade over local transcript windows, with realtime/voice-native cognition
  only when it earns itself — and that quality is *measured against held-out
  evals*, not asserted.
- **Cards are an append-only suggestion feed.** The model may append a new,
  distinct card as the meeting shifts, but it does not mutate, retire, approve,
  or dispatch prior cards. Older suggestions stay inspectable like transcript
  lines.
- **Local-first authority.** Capture, transcription, the event ledger, approval,
  worker policy, and auditability stay local and deterministic.
- **Explicit control.** The model suggests; the operator approves; the server
  enforces. Untrusted transcript text never executes.
- **The loop closes.** Approved work re-enters the meeting — pasted, delivered,
  or filed — with a receipt. Output that dies in a side panel is just a fancier
  note.
- **Memory across meetings.** Standby owns the append-only ledger of every
  proposal, approval, and artifact, so it can remember commitments and whether
  they were kept — accountability no notetaker has.
- **Evidence over vibes.** Every claim that something "works" leaves a replayable
  command, transcript, screenshot, eval report, or worker receipt.

## Standards — the bar

- **Honest state, never faked.** Capture and worker failures name the exact cause
  (which permission, which provider) and never hang; nothing renders a fake
  "live."
- **The model boundary is explicit.** Deterministic Rust owns policy,
  persistence, approval, sandbox, redaction, provider selection, and evals; the
  model only suggests, and provider/key/config failures are visible cards or
  receipts, never silent fallback.
- **Deep modules, small surfaces.** The event log is the single source of truth;
  state is a projection of events, not a side-channel.
- **Quality is gated, not claimed.** Proposal usefulness and capture reliability
  ship with oracles (evals with confidence intervals, long-soak gates), not just
  "a card appeared" / "it didn't crash."

## Non-goals

- Fully autonomous live execution without approval.
- Hidden network or model dispatch from transcript text.
- Fabricated speaker names without provider identity or known-speaker evidence.
- UI-only polish that does not move proposal quality, worker reliability, or
  meeting privacy.
- Offline-capable operation as a first-class requirement — the OpenCode-only
  worker is an accepted single point of failure
  (`docs/decisions/0003-opencode-only-accepted-failure-mode.md`).

## What excellent looks like

**Shipped (the plumbing).** Local mic + system-audio capture with on-device
Apple Speech transcription; real OpenRouter proposal generation by default
behind a typed agent boundary; an append-only, newest-first suggestion feed with
debounced off-path reasoning; deterministic, server-bound approval; a sandboxed
OpenCode worker with receipts; an append-only SQLite ledger; honest UI states;
distinct speaker tokens without fake names.

**Next 6–12 months.** A solo operator joins a real Meet/Teams call → sees
speaker-aware transcript context for their own voice *and* remote participants →
asks for or receives proactive model-native cards *whose quality is measured
against held-out evals* → approves safe agent work → **the result re-enters the
meeting** (copy/deliver) with a receipt → and the *next* call surfaces what's
still open from the last one. Proven by replay fixtures, proposal-quality evals
with confidence intervals, capture-reliability gates, worker-sandbox tests, and
gated live dogfood — not by green unit tests alone.

**Beyond.** Voice-native cognition if it beats the transcript-window cascade on
measured quality, latency, and cost; provider diarization adapters behind the
normalized attribution seam; the surface that reliably turns a conversation into
started, tracked, and accountable work.
