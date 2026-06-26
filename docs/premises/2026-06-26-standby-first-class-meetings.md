# Premise: First-Class Meeting Objects

Created: 2026-06-26T15:05:34Z

## Source Summary

- Operator identified that Standby still feels like one active meeting with
  sections, not an app organized around separate meetings.
- Operator wants meetings to be the top-level organizing bucket.
- Each meeting should contain its transcript, operator questions, suggested
  actions, approvals, agent runs, and agent outputs.
- Meetings should have visible names and timestamps.
- The sidebar should be redesigned around meeting selection.
- The header should be redesigned around the selected meeting rather than a
  generic live status strip.

## Non-Text Live Evidence

At shape time the repo already had meeting-scoped API routes and event payloads:

- `/api/meetings/{meeting_id}`
- `/api/meetings/{meeting_id}/proposal-requests`
- `/api/meetings/{meeting_id}/capture/start`
- `meeting_id` on transcript segments, proposal requests, proposals, jobs, and
  meeting events.

The UI still used one process-global `meetingId` from the URL and a sidebar
whose primary items were `Actions`, `Notes`, `Jobs`, and `Audio`, so separate
meetings were not first-class in the app shell.

This premise intentionally stores no raw meeting transcript text and no raw
audio path.

## Residual Risk

- The exact meeting naming source is a product choice. The shaped default is a
  generated timestamp-based title with inline rename, not calendar/provider
  import.
- Existing event timestamps are stored as event metadata; the shape requires
  visible start/update timestamps but does not require a new relational meetings
  table unless event-derived summaries prove insufficient.
