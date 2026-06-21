# Recover queued worker jobs after daemon restart

Priority: P1 · Status: done · Estimate: M

## Goal
Re-enqueue jobs that were requested but never reached a terminal event when `standbyd` restarts.

## PRD Summary

- User: meeting operator who approved work and expects the OpenCode subagent to
  return even if the local daemon restarts.
- Problem: approval persists `agent_job.requested`, but the in-memory worker
  channel is lost on daemon exit.
- Goal: replay the event log on startup and recover queued/running jobs that
  have no terminal event.
- Why now: OpenCode is now the default worker, so approved jobs must survive
  normal local app restarts.
- UX enabled: an approved card either resumes to completion or fails visibly
  after restart; it never stays queued forever.

## Alternatives

| Option | Benefit | Tradeoff | Verdict |
| --- | --- | --- | --- |
| Event-log replay on daemon startup | Uses existing append-only ledger and projection model; no second queue truth. | Re-running a job that died mid-flight can duplicate external reads, so mutation boundaries must remain strict. | Choose. |
| Separate durable queue table | Explicit worker queue semantics. | Adds state to reconcile with event log and another migration surface. | Reject for now. |
| Manual retry/reapprove | Smallest implementation. | Operator-hostile and fails the "approved work returns" promise. | Reject. |
| Supervisor-owned long-running worker process | Stronger for production daemonization. | Too large before local app semantics are proven. | Defer. |

## Chosen Design

Add a Rust core event-log query that returns the latest state for all
non-terminal queued/running jobs. On `standbyd` startup, after opening the store
and spawning the worker loop, enqueue those jobs through the same in-memory
channel used by approval. Completed, failed, and canceled jobs are never
re-enqueued.

## Oracle
- [x] A test daemon queues a job, exits before the worker writes a terminal event, restarts, and the job resumes or fails visibly.
- [x] Completed and failed jobs are not re-run.
- [x] `scripts/verify-worker-recovery.sh` records a restart evidence packet and
  is wired into the full gate.

## Verification System
- Claim: a daemon crash or restart cannot silently lose an approved job.
- Falsifier: projection contains `agent_job.requested` without terminal state after restart and no worker retries it.
- Driver: restart smoke with a controllable fake OpenCode worker.
- Grader: event log reaches `agent_job.completed` or `agent_job.failed` after
  restart, and a second restart does not increase the worker run count for a
  completed job.
- Evidence packet: `docs/evidence/operator-action-control/worker-recovery/`.
- Cadence: focused restart smoke before adding to the main gate.

## Notes
This is separate from the visible status work delivered in the current pass.

## Implementation Receipt

- Added `EventStore::recoverable_jobs()` to replay latest job state across the
  whole event log and return only queued/running jobs.
- `standbyd` now enqueues recoverable jobs on startup through the same worker
  loop used by approval.
- `scripts/verify-worker-recovery.sh` pauses a fake OpenCode job, kills the
  daemon before terminal state, restarts it, observes completion, restarts again,
  and verifies the completed job did not run a third time.
- Evidence: `docs/evidence/operator-action-control/worker-recovery/verdict.json`.
- Gate: `./scripts/verify.sh` passed with the worker recovery verifier included.
