# Recover queued worker jobs after daemon restart

Priority: P1 · Status: pending · Estimate: M

## Goal
Re-enqueue jobs that were requested but never reached a terminal event when `standbyd` restarts.

## Oracle
- [ ] A test daemon queues a job, exits before the worker writes a terminal event, restarts, and the job resumes or fails visibly.
- [ ] Completed and failed jobs are not re-run.

## Verification System
- Claim: a daemon crash or restart cannot silently lose an approved job.
- Falsifier: projection contains `agent_job.requested` without terminal state after restart and no worker retries it.
- Driver: restart smoke with a controllable slow worker.
- Grader: event log reaches `agent_job.completed` or `agent_job.failed` after restart.
- Evidence packet: `docs/evidence/operator-action-control/worker-recovery/`.
- Cadence: focused restart smoke before adding to the main gate.

## Notes
This is separate from the visible status work delivered in the current pass.
