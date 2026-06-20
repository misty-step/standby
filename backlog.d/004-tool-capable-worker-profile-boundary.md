# Gate a tool-capable OMP worker profile behind executable safety

Priority: P1 · Status: blocked · Estimate: L

## Goal
Add an opt-in model/tool worker profile only after network egress, secret reads, scratch writes, and allowed tool surfaces are executable and testable.

## Oracle
- [ ] A profile such as `omp-research` is ignored unless `STANDBY_ALLOW_NETWORK_WORKER=1`.
- [ ] The sandbox negative test proves the profile cannot mutate the repo, read common secret stores, write outside scratch, send external messages, or call unapproved tools.
- [ ] Auth failures return `agent_job.failed` with a receipt.

## Verification System
- Claim: a real model worker can use approved tools without becoming an exfiltration or mutation path.
- Falsifier: the worker can read secrets, write outside scratch, use unapproved MCP tools, or silently fail.
- Driver: opt-in worker smoke, extended sandbox negative test, route replay from approved proposal to terminal job.
- Grader: denial attempts fail at the OS/tool boundary and are recorded as worker failure receipts.
- Evidence packet: `docs/evidence/operator-action-control/model-worker-boundary/`.
- Cadence: run only after the profile exists; never part of the default gate until accepted.

## Notes
Blocked on `backlog.d/008-secure-approval-and-ai-execution-gate.md`. Do not make this the default worker. `local-research` remains the accepted default until per-job consent, egress, redaction, and tool scopes are proven.

Why: the AI-first proposal path increases the pressure to use real workers, but network/tool workers are an exfiltration and mutation risk until the approval and worker execution gate is hardened.
