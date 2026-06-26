# Context Packet: First-Class Meeting Objects

## PRD Summary

- **User:** solo operator using Standby across multiple calls.
- **Problem:** Standby has meeting-scoped events under the hood, but the app shell
  still behaves like one active meeting with section navigation. Prior
  transcripts, Ask Standby requests, suggestions, approvals, worker runs, and
  outputs are not presented as belonging to distinct meeting objects.
- **Goal:** Make meetings the top-level organizing bucket so the operator can
  create, name, switch, and review separate meetings, each with its own Action
  Stream, questions, transcript source, agent work, and outputs.
- **Why now:** Action Stream is locked as the selected in-meeting experience; the
  next UX layer must decide what owns that stream.
- **UX enabled:** the sidebar becomes a meeting list, the header identifies the
  selected meeting with title/timestamps/status, and all meeting work remains
  visibly scoped to that selected object.
- **Deliverable type:** working code plus updated design/oracle evidence.
- **Success signal:** a seeded app with two meetings shows both named meetings in
  the sidebar, selecting either meeting swaps the full Action Stream and source
  counts without cross-contaminating transcript, proposals, jobs, or outputs.

## Product Requirements

- **P0: meeting catalog.** Add a first-class meeting list API and UI rail. Each
  meeting row shows name, start/update timestamp, capture status, and compact
  counts for suggestions, running work, and outputs.
- **P0: selected meeting shell.** The main header is about the selected meeting:
  editable name or rename affordance, timestamp, status, capture controls, and
  subtle indicators for Action Stream, outputs, source transcript, and audio.
- **P0: scoped content.** Transcript segments, operator questions
  (`proposal_request.created`), proposed/approved/ignored actions, agent jobs,
  failures, and artifacts are visible only inside their meeting object.
- **P0: preserve Action Stream.** The chosen Action Stream remains the default
  detail view inside a meeting.
- **P0: append-only ledger.** Meeting identity, rename, proposal, job, artifact,
  and failure state stay event-derived; no mutable side-channel owns product
  truth.
- **P1: inline rename.** A generated timestamp title is acceptable at creation,
  but the header should allow a user-owned meeting name via append-only rename
  event.
- **P1: empty state.** Opening the app with no meetings shows a focused "Start
  meeting" state rather than silently creating fake data.
- **Non-goals:** calendar import, attendee roster import, cross-meeting global
  search, bulk delete/archive, meeting folders, or a relational meetings table
  unless the event-derived catalog cannot satisfy the oracle.

## Goal

Make meetings first-class objects in the product shell without changing the
approved-work safety model or replacing the Action Stream detail surface.

## Non-Goals

- Do not add provider/calendar meeting sync.
- Do not add global jobs, transcript, or output dashboards in this slice.
- Do not move approvals out of the deterministic server path.
- Do not create fake historical meetings or auto-start demo data on the normal
  route.
- Do not introduce a new worker harness, fallback, or model-provider setting.

## Constraints

- Event log remains the single source of truth.
- Transcript text remains untrusted evidence.
- Approval remains deterministic and server-owned.
- Existing deep links such as `/?meeting=qa-proposal` keep working for tests and
  QA scripts.
- Capture, proposal, worker, and artifact data must never bleed across
  `meeting_id` boundaries.
- The normal route must not auto-start demo mode.

## Repo Anchors

- `VISION.md` - Standby is a meeting command surface with memory across
  meetings and receipts for every step.
- `DESIGN.md` and `design-contract.md` - Action Stream is the locked in-meeting
  default; transcript detail stays tucked away.
- `crates/standby-core/src/domain.rs` - `Meeting`, `MeetingEvent`,
  `MeetingProjection`, event type constants, and event timestamps.
- `crates/standby-core/src/event_log.rs` - `projection`, `meeting_ids`,
  migration, and event replay behavior.
- `crates/standbyd/src/main.rs` - meeting-scoped routes and operator auth.
- `crates/standbyd/src/capture.rs` - local capture start currently emits
  `meeting.started` with title/mode.
- `ui/src/main.tsx` - current global `meetingId`, sidebar, topbar, Action
  Stream, Ask Standby, transcript, jobs, and audio panels.
- `scripts/verify-ui-visual-qa.sh` - browser evidence harness for operational UI
  states across desktop/mobile.

## Lead Repo Read

- Read `VISION.md`, `DESIGN.md`, `design-contract.md`,
  `docs/decisions/0003-opencode-only-accepted-failure-mode.md`.
- Read `crates/standby-core/src/domain.rs`,
  `crates/standby-core/src/event_log.rs`, `crates/standbyd/src/main.rs`,
  `crates/standbyd/src/capture.rs`, `ui/src/main.tsx`, and
  `scripts/verify-ui-visual-qa.sh`.
- Checked existing context packet conventions in
  `docs/context-packets/operator-action-control-and-speaker-distinction.md` and
  HTML plan conventions in `docs/shape/operator-action-control-and-speaker-distinction.html`.

## Delete-First / Ponytail Pass

- **Requirement questioned:** do we need a new durable meetings table?
- **Deleted or simplified:** no table in the first slice. Derive the meeting
  catalog from `meeting_events`, because every load-bearing object already has
  `meeting_id` and `created_at`.
- **Only then optimized/automated because:** add a table or materialized index
  only if the derived catalog becomes too slow, needs non-evented metadata, or
  cannot support rename/history without fragile scans.

## Alternatives

| Option | Why it helps | Failure mode | Verdict |
| --- | --- | --- | --- |
| Keep URL `meeting` param and redesign current sidebar sections | Smallest UI diff. | Meetings still are not first-class; user must know hidden URLs. | Reject. |
| Add a mutable `meetings` table as the source of truth | Fast list queries and familiar CRUD. | Splits truth from append-only ledger; introduces sync/migration failure. | Reject for first slice. |
| Event-derived meeting catalog plus sidebar meeting switcher | Fits ledger model, smallest durable surface, preserves current routes. | Requires careful summary derivation and timestamp formatting. | Choose. |
| Calendar/provider meeting import | Real names and scheduled timestamps. | Auth/vendor work before local product model is correct. | Defer. |
| Global outputs/jobs dashboard first | Useful later for accountability across calls. | Recreates the noisy dashboard problem and weakens meeting ownership. | Reject for default; revisit after meeting catalog. |

## Technical Design

### Chosen Architecture

Add a first-class meeting catalog derived from the append-only event log.

Core shape:

- Add `MeetingSummary` in `standby-core` with:
  - `id`
  - `title`
  - `started_at`
  - `updated_at`
  - `source_status`
  - `transcript_count`
  - `question_count`
  - `open_suggestion_count`
  - `running_job_count`
  - `output_count`
  - `latest_activity`
- Add `EventStore::meeting_summaries()` that groups known meeting IDs, replays
  each projection, and derives the summary from event metadata.
- Add `GET /api/meetings` returning summaries sorted by `updated_at` descending.
- Add `POST /api/meetings` for creating a named meeting bucket. It should append
  a meeting lifecycle event with title and no fake transcript/capture state.
- Add `POST /api/meetings/{meeting_id}/rename` for inline rename. Implement as
  append-only event, not an UPDATE.
- Keep existing `GET /api/meetings/{meeting_id}` as the detail projection for
  the selected meeting.
- Keep proposal approve/ignore routes by proposal ID for compatibility, but
  detail responses continue returning the owning meeting projection.

Timestamp rule:

- The UI needs displayable start/update timestamps.
- Do not require a new table just to store timestamps. Use first/last event
  times for the first slice.
- If implementation changes timestamp generation, it must preserve parsing for
  existing `created_at` rows. Existing rows may use the current
  `seconds.millisZ` string.

### UI Shape

Sidebar becomes the meeting rail:

- Brand and "New meeting" command at top.
- Meeting list grouped minimally by recency if cheap (`Today`, `Earlier`) or
  simply sorted newest-first in the first implementation.
- Each row shows meeting title, timestamp, capture/status dot, and compact
  counts: suggestions, running work, outputs.
- The currently selected meeting is visually distinct.
- Section buttons (`Actions`, `Notes`, `Jobs`, `Audio`) are no longer primary
  sidebar navigation.

Header becomes selected-meeting command:

- Title/name first, timestamp second, status/capture controls third.
- Quiet indicators/tabs expose `Action stream`, `Outputs`, `Source`, and
  `Audio`; the default remains Action Stream.
- Ask Standby and suggested actions stay inside the selected meeting, not in a
  global assistant panel.

Detail surface:

- Keep `MeetingActionStream` as the default selected-meeting detail.
- Treat transcript/source as a drawer or focused source view inside the meeting.
- Jobs and outputs can remain in the stream plus an optional focused view, but
  their counts must be meeting-scoped.

### Data / Control Flow

1. App loads `/api/meetings`.
2. If URL contains `?meeting=<id>`, select that meeting; otherwise select the
   most recently updated meeting.
3. If there are no meetings, render a no-meetings state with `New meeting`.
4. Selecting a meeting updates local state and the URL query, then fetches
   `/api/meetings/{id}`.
5. Creating a meeting appends the lifecycle event, refreshes the summary list,
   selects the new ID, and shows the selected meeting shell.
6. Capture, Ask Standby, approval, ignore, jobs, artifacts, and source transcript
   continue using the selected meeting ID.

### ADR Decision

No new ADR required if implementation stays event-derived and preserves the
existing append-only ledger contract. Escalate to an ADR if a mutable meetings
table, calendar/provider identity, archival/deletion semantics, or cross-meeting
global work queues are introduced.

### ADR-Style Invariants

- Meeting catalog is projection, not source of truth. If violated, event replay
  and UI state can diverge.
- Meeting title changes are events. If violated, auditability and rollback get
  weaker.
- The sidebar selects meetings; it does not run work. If violated, navigation
  becomes an overloaded control plane.
- Selected meeting owns all controls. If violated, actions can accidentally
  target the wrong meeting.

## Alignment Questions

None blocking; assumptions accepted:

- Use generated timestamp-based titles plus inline rename for v1, not calendar
  import.
- Keep URL deep-link compatibility for QA and old flows.
- Keep the Action Stream as the default detail inside the selected meeting.

## Oracle

Automated commands that must exit 0 after implementation:

- `cargo test -p standby-core meeting_summaries -- --nocapture` - proves
  multiple meetings summarize independently with title, timestamps, and counts.
- `./scripts/verify-meeting-catalog.sh` - starts a seeded daemon, creates/seeds
  at least two named meetings, asserts `GET /api/meetings` returns both sorted by
  update time, selects each detail route, and verifies transcript/proposals/jobs
  do not cross meetings.
- `STANDBY_EVIDENCE_DIR=docs/evidence/first-class-meetings bash ./scripts/verify-ui-visual-qa.sh`
  - updated visual QA captures desktop/mobile sidebar/header states and asserts
  meeting names, timestamps, counts, selected state, and Action Stream detail.
- `./scripts/verify.sh` - full repo gate remains green.

Observable QA:

- Open `/` with two seeded meetings. The sidebar is a meeting rail, not a
  section rail.
- Select meeting A and meeting B. The header title/timestamp/status changes, and
  the Action Stream, Ask Standby context count, outputs, and source drawer all
  follow the selected meeting.
- Rename a meeting. The new name appears in the sidebar and header after refresh
  without mutating historical events.

## Verification System

- **Claim:** Standby organizes all meeting artifacts under first-class meeting
  objects and lets the operator safely switch meetings without state bleed.
- **Falsifier:** two seeded meetings show mixed transcript/proposals/jobs,
  sidebar still primarily navigates sections, selected header lacks name or
  timestamp, rename mutates state outside the event log, or old `?meeting=` QA
  routes break.
- **Driver:** `verify-meeting-catalog.sh`, updated visual QA browser captures,
  unit tests over `EventStore::meeting_summaries`, and full `./scripts/verify.sh`.
- **Grader:** JSON assertions over meeting summaries and projections; DOM
  assertions for sidebar/header labels; screenshots for desktop/mobile; event
  replay assertions for title/rename/counts.
- **Evidence packet:** `docs/evidence/first-class-meetings/` with API JSON,
  DOM snapshots, screenshots, and `verdict.json`.
- **Cadence:** run focused catalog script during implementation, updated visual
  QA after UI changes, full gate before closeout.
- **Gaps / waiver:** calendar-derived meeting names, attendees, deletion, and
  cross-meeting search are out of scope.

## Works Critique Focus

- **Public surface:** Does `/api/meetings` match the nearby projection style and
  avoid creating a second source of truth?
- **Human workflow:** Can the operator tell which meeting an approval or Ask
  Standby request will target before clicking?
- **Performance:** Event-derived summaries are acceptable for local v1. If the
  list becomes slow with large ledgers, materialize later behind the same API.
- **Compatibility:** Existing meeting detail routes and visual QA deep links
  must keep working.
- **Operations:** A future bug should be diagnosable from the event ledger,
  summary JSON, and screenshot evidence.

## Fresh-Critic Prompt

Give a fresh-context critic only this packet plus the implementation diff and
oracle. Ask:

- `BLOCKING:` yes/no.
- Where could a real operator approve work into the wrong meeting?
- Where does the plan accidentally create a second source of truth?
- Where can old meeting events or timestamp formats break the new UI?
- Ignore style nits unless they hide one of those failures.

Fresh-context critique was not run during shaping because the available
delegation tool requires explicit subagent authorization in this environment.

## Risks + Rollout

- **Wrong target meeting.** Mitigate by making selected meeting identity dominant
  in the header and keeping create/select state explicit.
- **Timestamp parsing drift.** Mitigate with a parser for existing event
  timestamps and test fixtures containing more than one format if the generator
  changes.
- **Slow catalog scans.** Mitigate later with a materialized cache/table only
  after the API and oracle prove the product shape.
- **Visual clutter returns.** Mitigate by keeping sidebar rows compact and moving
  secondary section controls into the selected meeting header.

Rollback:

- Keep `/api/meetings/{id}` and current Action Stream intact.
- Hide the meeting rail and return to URL-selected single meeting if the catalog
  has a blocking bug.
- Leave evented meeting title/rename events harmless in the ledger even if UI is
  temporarily reverted.

## Premise Source

Premise Source: sha256:0dbfecd0e931c205e5dbb799e6216cc56d1fb08500d15f2ee3f1e428588578c1 docs/premises/2026-06-26-standby-first-class-meetings.md

## HTML Plan

HTML plan: `docs/shape/first-class-meeting-objects.html`.

Rendered review: opened locally after authoring.
