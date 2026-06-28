# Standby Vision

Standby is a local-first, AI-first meeting command surface for macOS. While a
meeting is happening, it watches the real-time context, notices useful agentic
work, and helps get that work started without forcing the operator to leave the
conversation.

The motivating scene is concrete: the meeting takes two thirds of the monitor,
Standby lives in the remaining third, and it is constantly asking, "given what
is being discussed right now, what would be useful to know, write, build,
summarize, check, or dispatch?" Most often that first useful action is research:
the conversation raises a question, Standby proposes or starts an agent run, and
the report returns while it can still change the meeting.

The word that has to earn itself is *command*. Standby is not a notetaker. It is
not just a transcript with chat attached. It is the local command layer where
meeting context becomes useful, visible, interruptible agent work.

Date: 2026-06-28. Lifespan: long-lived product substrate, builder-dogfooded
first. Revise when live evidence contradicts the product bet; do not churn it
per backlog edit.

## Who It's For

The first user is the operator running meetings where useful work appears in the
middle of the conversation: a founder, consultant, engineer, product lead, or
builder who wants an agent working alongside the call instead of after it.

That user does not want another place to store notes. They want leverage inside
the meeting: quick research, a comparison, a prototype, a spec, a backlog edit,
a pull request review, a project-board update, a summary, or an implementation
run kicked off while the topic is still live.

## The Job

While a call is happening, Standby should:

- listen to local meeting context without pretending uncertain transcript data
  is ground truth;
- understand when a useful task exists;
- propose, refine, or eventually initiate the right agentic action;
- dispatch a local agent with the relevant context, tools, repo access, MCPs, and
  boundaries;
- show what the agent is doing in a visible sidecar;
- let the operator intervene, steer, add context, stop, approve, reject, or give
  feedback;
- bring results back into the meeting quickly enough to matter;
- remember what happened so future meetings and future suggestions get better.

The first strong wedge is meeting-contextual research. The broader product is a
real-time agent dispatcher for meeting-born work.

## Current Posture And Long-Term Direction

Today, Standby uses an ask-before-act model: transcript context produces
proposal cards, the operator approves a card, and deterministic server endpoints
dispatch a sandboxed OpenCode worker. That is the right current safety posture.
It makes the model boundary explicit, gives the operator control, and creates
receipts before the product has earned more autonomy.

That is not the final ideal. The product should become smart and context-rich
enough to take more action on the operator's behalf when the action is low risk,
well understood, visible, bounded, and interruptible. Autonomy should grow from
evidence: better context, better policy, better permission tiers, better stop
controls, better run visibility, better feedback loops, and better evals.

The future Standby is not a passive feed of cards. It is a meeting-side
orchestrator that knows the operator's projects, tools, repositories, boards,
backlogs, preferences, and prior commitments well enough to choose useful work
and run it under the right authority.

## Strategic Bets

- **Real-time context is the wedge.** The product is valuable because it acts
  while the conversation is still alive, not because it writes a better recap
  later.
- **Agentic actions beat notes.** Research reports, specs, prototypes, PRs,
  reviews, kanban updates, summaries, and analyses are the useful unit. Notes are
  supporting evidence.
- **Local authority matters.** The agents Standby dispatches run from the
  operator's machine, against the operator's repos, tools, MCPs, and project
  context. That power is the point, so policy and receipts are non-negotiable.
- **Visible autonomy beats hidden automation.** As the product becomes more
  autonomous, the operator must still see what is happening, steer it, stop it,
  and teach it.
- **Model-native cognition, not keyword heuristics.** Useful suggestions come
  from models interpreting meeting context behind typed boundaries. Deterministic
  code owns policy, persistence, approvals, permissions, redaction, sandboxing,
  and evals.
- **Memory compounds.** Standby should learn from accepted runs, rejected runs,
  operator feedback, stopped runs, reasons for stopping, meeting history, and
  project state. The sidecar should get more useful because it has been present
  for prior work.
- **Evidence over vibes.** Every claim that something works leaves a replayable
  command, transcript, screenshot, eval report, run receipt, or artifact.

## Standards

- **Honest state, never faked.** Capture, transcription, model, and worker
  failures name the exact cause and never hang behind fake "live" UI.
- **Policy is deterministic.** Transcript text is untrusted evidence. The server
  decides what authority a run has; the model does not grant itself permission.
- **Intervention is product surface.** Stop, steer, add context, approve, reject,
  and explain-why controls are not admin extras. They are how autonomy becomes
  usable.
- **The event log is the source of truth.** Proposals, approvals, autonomous
  dispatches, stops, steering messages, artifacts, failures, and feedback are
  events. UI state is a projection.
- **Quality is measured.** Suggestion usefulness, run timing, result quality,
  context selection, and autonomy decisions need evals or dogfood evidence, not
  anecdotes.

## What This Is Not

- Not a notetaker whose main job is transcript storage.
- Not a generic desktop automation daemon that happens to see meeting text.
- Not a hidden autonomous agent that silently mutates tools, repos, boards,
  calendars, or messages without visibility or recoverable evidence.
- Not a keyword-triggered action bot.
- Not a UI polish project detached from proposal quality, result usefulness,
  worker reliability, meeting privacy, or operator control.
- Not offline-first as a product constraint; remote models and OpenCode workers
  may be necessary, but failures must be honest and visible.

## What Excellent Looks Like

**Current foundation.** Local capture and transcription work honestly. Real
model-native proposal generation produces evidence-cited cards. Approval is
deterministic. OpenCode workers run out of request with receipts. The SQLite
ledger records the sequence. The UI shows actual state, not theater.

**Next.** During a real meeting, Standby notices a research-worthy question,
offers the run, dispatches it with the relevant meeting context, and returns a
concise report before the topic goes cold. The operator can ask for a task
directly, refine the prompt, approve it, stop it, or add context. The next
meeting remembers open commitments and useful prior results.

**Then.** Standby supports richer task classes: project-board and backlog
updates through MCPs, spec writing, app prototypes, feature implementation,
pull-request review, summaries, analyses, and project-specific work against
local repos. Permission tiers decide what needs approval and what may start
automatically.

**Ideal.** Standby becomes a trusted meeting-side agent orchestrator. It knows
enough context to act intelligently, takes bounded action when appropriate,
shows every run in progress, accepts steering as naturally as conversation, and
turns meetings into started, tracked, accountable work.
