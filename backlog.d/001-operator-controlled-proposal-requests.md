# Add operator-controlled proposal requests

Priority: P0 · Status: done · Estimate: M

## Goal
Let the meeting operator explicitly ask Standby to propose work from a message plus recent transcript context, without weakening the approval-before-execution invariant.

## Oracle
- [x] `scripts/verify-manual-proposal-request.sh` seeds a meeting, posts an Ask Standby message, observes `proposal_request.created` plus evidence-cited `proposal.created`, approves one card, and sees a terminal worker result or receipt.
- [x] The normal transcript-triggered proposal flow still works.
- [x] No worker starts until the approval endpoint is called.

## Verification System
- Claim: an operator can force a useful proposal card during a live call and then approve it through the existing worker path.
- Falsifier: request creates no card, card lacks transcript evidence, request directly runs a worker, approval hangs without job status, or worker returns no artifact/failure receipt.
- Driver: seeded daemon route replay plus the full Standby gate.
- Grader: JSON assertions over proposal request, proposal, job, artifact, and event types.
- Evidence packet: `docs/evidence/operator-action-control/`.
- Cadence: run focused script during implementation; run `./scripts/verify.sh` before closeout.

## Notes
Use one conservative proposal first. The operator prompt is intent; transcript spans are evidence. Approval remains deterministic server behavior.

Delivered in this branch with `proposal_request.created`, `POST /api/meetings/{meeting_id}/proposal-requests`, React Ask Standby control, and `scripts/verify-manual-proposal-request.sh`.
