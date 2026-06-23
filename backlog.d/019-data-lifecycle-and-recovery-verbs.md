# Give the operator control of their data and running jobs

Priority: P2 · Status: pending · Estimate: M

## Goal
The operator owns their local data (can delete it, and it doesn't grow unbounded) and can recover from the UI (cancel a running job, retry a failed one) without a terminal.

## Oracle
- [ ] A "delete this meeting" action removes its ledger rows, evidence, and job scratch.
- [ ] The event log has versioned migrations + a retention/size policy with periodic `VACUUM`/checkpoint; job scratch is GC'd.
- [ ] Cancel-running-job and retry-failed-job routes exist and are surfaced in the UI.
- [ ] HTTP projection reads are bounded (cached/materialized projection) rather than O(total events) per read on long meetings.

## Notes
**Why:** Ops + Runtime lanes: for a local-first app whose value is a durable transcript+evidence ledger, "the operator owns their data" currently means "the operator cannot delete their data" — no DELETE route, no retention, no `VACUUM` (`event_log.rs:349-369`); `.standby/standby.db` is already 26M with a growing WAL and per-job scratch persists forever. There are no cancel/retry routes (`main.rs:115-135`) — a wedged job can only be stopped by killing the daemon; the `Canceled` job state already exists but has no producing route (see 016 child 2). Projection replays the entire meeting's events on every HTTP read (`event_log.rs:103`) and the schema's `projections` table (created, never used, `event_log.rs:362`) is the obvious caching seam — coordinate with 016 child 3 before deleting it.
