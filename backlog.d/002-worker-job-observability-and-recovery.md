# Make worker dispatch visibly return or fail

Priority: P1 · Status: done · Estimate: M

## Goal
Make every approved worker job visibly move through queued, running, progress, and terminal states, including receipts for failures and no silent queue loss.

## Oracle
- [ ] `scripts/verify-worker-runner.sh` proves approval returns out-of-request, a worker starts, and the projection reaches completed with artifact or failed with receipt.
- [ ] A missing worker script produces a visible `agent_job.failed`, not a spinner.
- [ ] Dispatch queue send failure records a terminal event.

## Verification System
- Claim: after approval, the operator can tell whether the worker is queued, running, done, or failed.
- Falsifier: a job remains queued forever after dispatch failure, lacks progress, or fails without receipt.
- Driver: worker runner smoke, UI state smoke, core worker tests.
- Grader: event log contains `agent_job.started`, `agent_job.progress`, and a terminal event; UI displays the latest job state.
- Evidence packet: `docs/evidence/operator-action-control/worker-*.json`.
- Cadence: focused worker scripts during delivery; full gate before closeout.

## Notes
Durable queue recovery on daemon restart remains the larger next child if not completed in this pass.

Delivered the visible dispatch/return part in this branch with `agent_job.progress`, queue-send failure recording, and worker/UI verification. Daemon-restart queue recovery is tracked separately.
