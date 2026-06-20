# Context Packet: Operator-Controlled Proposals And Speaker Distinction

## Goal

Let the meeting operator intentionally ask Standby for proposal cards during a
live call, then approve a card and watch the worker run, while making remote
speaker attribution explicit enough that a multi-person Teams call is not a wall
of undifferentiated `call audio`.

## Deliverables

- **Ticket A: Ask Standby proposal request.** Add an operator-authored prompt box
  and API route that combines the prompt with recent transcript context,
  generates evidence-cited proposal cards, and uses the existing approval/job
  path.
- **Ticket B: Speaker distinction v1.** Add a `SpeakerAttribution` seam and
  projection/UI support for stable remote speaker labels, with a first verified
  source of labels. Local diarization may output `Speaker 1`, `Speaker 2`, etc.;
  provider adapters may output names later.
- **Ticket C: Tool-capable model worker profile.** Shape, but do not make
  default, an OMP/GLM-style worker profile with MCP/tools/skills only after the
  network, secret, scratch, and permission boundaries are executable.

## Non-Goals

- No automatic execution from transcript text. Every task still needs explicit
  approval.
- No external sends, repo mutation, deploys, spending, or calendar/email actions
  in this slice.
- No default cloud-model worker until egress is scoped and sandbox proof passes.
- No promise of true human names from local audio alone. Local diarization gives
  stable speaker buckets; names need either manual aliases or provider/roster
  data.
- No raw meeting audio or raw transcript dumps committed to the repo.

## Constraints

- Transcript text remains untrusted evidence.
- Approval remains a deterministic server action and only enqueues work.
- Every proposal request, proposal, approval, job event, artifact, and failure is
  append-only in SQLite.
- Normal live capture must continue while this feature is used.
- `local-research` remains the default accepted worker profile until a stronger
  profile passes executable security gates.
- UI must make uncertainty visible: "Speaker 2" is acceptable; fake names are
  not.

## Repo Anchors

- `crates/standby-core/src/engine.rs` — current cue-based research proposal
  detector and evidence-cited prompt construction.
- `crates/standby-core/src/domain.rs` — `ProposalKind`, `WorkerKind`,
  `TranscriptSegment`, `AgentJobSpec`, and event type definitions.
- `crates/standby-core/src/transcript_source.rs` — local helper event
  normalization; current speaker labels come from helper JSONL.
- `crates/standby-core/src/event_log.rs` — projection contract for transcript,
  proposals, jobs, artifacts, and source state.
- `crates/standby-core/src/worker.rs` — approval-to-job spec, sandboxed worker
  execution, and current worker profiles.
- `crates/standbyd/src/main.rs` — current routes: projection, capture start/stop,
  approve, ignore.
- `ui/src/main.tsx` — proposal card, editable prompt, job panel, transcript rows,
  and nav panels.
- `README.md` and `AGENTS.md` — local-first safety, worker, and verification
  contracts.
- `docs/real-meeting-followups.md` — existing follow-ups for provider
  transcript adapters, proposal quality, and worker security.

## Current State

- Live Teams capture is working through local capture; the `teams-live`
  projection reached `source.status = transcribing`.
- The projection currently exposes only one remote speaker key in the Teams
  meeting: `system_audio`.
- Proposal creation is automatic and cue-based. The operator can approve or
  ignore a card, but cannot yet ask Standby to create cards on demand.
- Approval/job/report is wired and verified for `local-research`.
- `claude-research` and `pi-research` exist behind
  `STANDBY_ALLOW_NETWORK_WORKER=1`; OMP/GLM/MCP/harness/skills are not wired.

## Alternatives

| Option | Why it helps | Failure mode | Verdict |
| --- | --- | --- | --- |
| **Ask Standby route + cards, approval reuses current job path** | Gives the operator direct control without weakening the approval safety model. | Proposal generation can be low-quality if it is just a heuristic. | **Choose first.** |
| Hotkey/button that creates one generic research card from recent transcript | Very small implementation. | Still feels like magic; no operator prompt, weak task intent, poor for non-research work. | Reject as primary; useful fallback. |
| Freeform chat that directly runs an agent | Fastest UX. | Violates approval invariant; transcript/chat can become executable instruction. | Reject. |
| Local diarization of system audio | Preserves local-first promise; can distinguish speakers without Teams/Graph auth. | Buckets, not names; hard to grade without audio fixtures; may be inaccurate in crosstalk. | Choose for local speaker distinction v1 if a fixture can grade it. |
| Provider transcript adapter for Teams/Graph/Vexa/Recall | Best named speakers and roster mapping. | App-specific, auth/vendor/tenant issues; not the universal local capture path. | Defer behind `TranscriptSource`. |
| Manual speaker aliases only | Small UI/data change, useful once labels exist. | Does not distinguish speakers by itself. | Include as support, not the whole ticket. |
| OMP/GLM with full MCP/tool/skills as default worker | Matches the desired "real subagent" idea. | Network + tools + readable local files can exfiltrate secrets; MCP/tool surfaces can mutate unless scoped. | Shape now, gate later. |
| Keep `local-research` only | Safe and verified. | Not a real research/model worker; poor product demo for meaningful tasks. | Keep default, but add opt-in stronger profile only after security proof. |

## Recommended Design

### Ticket A: Ask Standby proposal request

Add an explicit operator request event and route:

- `POST /api/meetings/{meeting_id}/proposal-requests`
- Body: `{ "message": "...", "context_window": "recent" | "full", "max_proposals": 3 }`
- Emits `proposal_request.created` with the operator message and transcript span
  IDs used as context.
- Produces one to three `proposal.created` cards.
- Cards show:
  - operator message,
  - cited transcript evidence,
  - proposal kind,
  - suggested worker profile,
  - editable prompt,
  - approval/ignore controls.

First implementation should be conservative:

- Support research/action proposal cards only.
- Use the operator message as the primary ask and recent finalized transcript
  spans as context.
- Reuse the current approval endpoint and job runner.
- If no good proposal can be generated, return a visible "no proposal generated"
  state rather than fake confidence.

### Ticket B: Speaker distinction v1

Add a speaker-attribution seam instead of embedding diarization directly in UI:

- Preserve raw helper speaker values, but normalize into a stable projected
  speaker key and label.
- UI renders distinct remote labels when projection has them.
- Add manual aliasing only after stable speaker keys exist.
- Add one verified source:
  - Preferred first source if feasible: local diarization buckets for system
    audio (`remote_1`, `remote_2`, label `Speaker 1`, `Speaker 2`).
  - Acceptable fallback first source: provider transcript adapter fixture that
    proves the data model/UI support arbitrary remote speakers, with local
    diarization kept as the next ticket.

Stop if the implementation cannot produce stable speaker keys from any source;
do not ship a UI rename layer over a single `system_audio` bucket and call it
speaker distinction.

### Ticket C: Model/tool worker profile

Do not wire OMP/GLM/MCP/skills as the default worker in the same slice as Ask
Standby. Shape it as a separate worker-profile milestone:

- Add `WorkerProfile::omp_research()` or equivalent only behind
  `STANDBY_ALLOW_NETWORK_WORKER=1`.
- Create a per-job harness home with only approved skills/tools/MCP config.
- Forward only the credentials required for that profile.
- Add an egress-scoped boundary before defaulting it: local proxy allowlist,
  network namespace, or equivalent host-level control.
- Extend the sandbox negative test to cover:
  - cannot read common secret stores,
  - cannot mutate repo,
  - cannot write outside scratch,
  - cannot call unapproved MCP tools,
  - cannot send external messages,
  - records failure receipts.

## Oracle

Commands that must exist and pass after implementation:

- `./scripts/verify.sh` — full existing gate remains green.
- `./scripts/verify-manual-proposal-request.sh` — starts a throwaway daemon with
  seed enabled, seeds finalized transcript spans, posts an Ask Standby message,
  asserts proposal cards cite both the operator message and transcript span IDs,
  approves one, and polls until the worker writes an artifact or failure receipt.
- `./scripts/verify-speaker-distinction-fixture.sh` — replays a fixture with at
  least two remote speakers and asserts the projection and UI render distinct
  stable speaker labels. If using local diarization, the fixture must be an audio
  or helper-event fixture that fails when all speakers collapse to `system_audio`.
- `./scripts/verify-worker-sandbox.sh` — remains green; if an OMP/GLM profile is
  added, it must be included as an opt-in profile test before being accepted.
- `STANDBY_LIVE_CAPTURE=1 ./scripts/verify-live-teams-local.sh` — still proves
  live capture can run while Ask Standby is used.

Observable QA:

- During a live Teams call, the operator can type "research X using this call as
  context," see proposal cards, approve one, and see job status plus receipt.
- In a multi-person call, transcript rows do not all appear as one anonymous
  `Call audio` speaker once the selected attribution source is enabled.

## Verification System

- **Claim:** Standby gives the operator intentional control over proposal
  generation and makes multi-person call attribution materially better than one
  undifferentiated system-audio speaker.
- **Falsifier:** pressing Ask Standby creates no card, creates a card without
  cited context, runs work without approval, hides worker status, or the speaker
  fixture collapses all remote speech to `system_audio`.
- **Driver:** route replay for proposal requests, transcript speaker fixture
  replay, full `./scripts/verify.sh`, and gated live Teams QA.
- **Grader:** JSON assertions over proposal/event/job projection, UI screenshot
  for card and speaker labels, worker artifact/receipt existence, and sandbox
  negative checks.
- **Evidence packet:** `docs/evidence/operator-action-control/` containing
  request/response JSON, UI screenshots, worker receipt paths, fixture output,
  and final verdict.
- **Cadence:** run focused scripts during implementation; full gate before
  merge; live Teams QA before claiming product-ready.
- **Gaps / waiver:** true human names require provider/roster data or manual
  aliases; local diarization can only promise stable buckets.

## Risks + Rollout

- Proposal quality can regress into noisy cards. Mitigate with an explicit
  operator request path, max proposal count, and visible no-proposal state.
- Worker profile expansion is the security risk. Keep `local-research` default
  until egress and tool scopes are enforced.
- Speaker diarization can be confidently wrong. Label buckets honestly and make
  aliases user-owned.
- Live meeting capture should not be restarted during implementation; develop
  against seed/fixture harnesses first, then run gated live QA.

Rollback:

- Disable the Ask Standby route/UI while leaving automatic cue-based proposals
  and approval intact.
- Disable speaker attribution source and fall back to current `Me` /
  `Call audio` labels.
- Leave OMP/GLM profile unset; `WorkerProfile::by_id` must fall back to
  `local-research` unless the opt-in env is present.

## Premise Source

Premise Source: sha256:37d5175c2f2d7976f48567ec78daef8351dd4505692a879cf3d01ad5b78c0da0 docs/premises/2026-06-19-standby-operator-action-control.md

The premise source is a sanitized operator note plus non-text API projection
metadata. It intentionally stores no raw meeting transcript and no raw audio
path; voice/raw-transcript metadata is waived because the packet does not cite
or retain raw voice transcript excerpts.

## HTML Plan

HTML plan: `docs/shape/operator-action-control-and-speaker-distinction.html`.

Rendered browser-open waiver: the packet was authored during a live Teams
meeting and the Standby browser-inspection tool had just timed out. Do not steal
focus from the active meeting for rendered review; open the HTML before
implementation when the operator is not in-call.
