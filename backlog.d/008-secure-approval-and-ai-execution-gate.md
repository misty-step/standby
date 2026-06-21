# Secure approval and AI execution before network-capable workers

Priority: P0 · Status: done · Estimate: L

## Post-Delivery Direction Correction

The security hardening in this ticket remains required: authenticated mutation
routes, server-bound approval actor, prompt redaction, and visible failure
receipts. The worker product shape changed afterward. Backlog item 009 removes
the global network-worker flag and profile/consent selector UX in favor of one
default OpenCode worker launched by deterministic approval.

## Goal
Only an authenticated local operator can mutate meeting state or approve AI execution, and network/tool-capable workers require explicit per-job consent plus enforceable egress/secret boundaries.

## PRD Summary
- User: meeting operator trusting Standby during live calls.
- Problem: mutation routes are local but unauthenticated/CORS-permissive, approval identity is request-supplied, and network worker enablement is a global env switch.
- Goal: harden the control plane before model/tool workers become product behavior.
- Why now: AI-first proposals increase the value and risk of approvals; security must move before default network workers.
- UX enabled: the operator sees who approved what, which model/tool permissions are requested, and why a network worker is allowed or denied.
- Deliverable type: working code plus adversarial security verification.
- Success signal: unauthorized local-origin mutation attempts fail, approval actor is server-bound, and network workers cannot launch without per-job consent.

## Product Requirements
- P0: all mutation endpoints require local operator auth/session or equivalent origin-safe token.
- P0: approval actor identity comes from the server auth context, not `approved_by` in request JSON.
- P0: CORS/CSRF rules prevent arbitrary local web pages from approving work.
- P0: network/model/tool-capable workers require per-job consent recorded in the event log, not only `STANDBY_ALLOW_NETWORK_WORKER=1`.
- P0: prompt/transcript redaction policy is applied before any cloud/model worker dispatch.
- P0: denial/failure is visible as an event and UI state.

## Oracle
- [x] An unauthenticated `POST` to capture start/stop, proposal requests, approve, and ignore returns 401/403.
- [x] A hostile local-origin request cannot approve a proposal through permissive CORS/CSRF behavior.
- [x] Approval events bind to the authenticated actor and ignore/retire request-supplied `approved_by`.
- [x] A network-capable worker profile cannot start without per-job consent recorded in the event log.
- [x] A redaction/deny fixture proves secret-like transcript or prompt content is not sent to a cloud worker without explicit consent.

## Verification System
- Claim: AI execution is operator-authorized, origin-safe, auditable, and not a silent exfiltration path.
- Falsifier: unauthenticated mutation succeeds, approval actor is spoofable, a network worker starts from a global env flag alone, or prompt content bypasses redaction/consent.
- Driver: adversarial HTTP route replay, browser-origin CSRF attempt, worker profile negative tests, and full gate.
- Grader: HTTP status assertions, event actor assertions, per-job consent event assertions, sandbox denial logs, and visible failure receipts.
- Evidence packet: `docs/evidence/ai-execution-security/`.
- Cadence: focused security scripts before enabling any network worker by default; full gate before merge.

## Children
1. Add local operator auth/session/token for mutation routes while keeping read-only projection easy for the UI.
2. Replace request-supplied approval identity with server-bound actor context.
3. Tighten CORS/CSRF posture and add hostile-origin route replay.
4. Add per-job network/tool consent events and UI warning copy.
5. Add prompt redaction/deny policy before cloud/model worker dispatch.
6. Extend worker sandbox negative tests for egress, common secret stores, repo mutation, scratch writes, and unapproved tools.

## Notes
Why: security/privacy lane found unauthenticated mutation endpoints, spoofable approval identity, broad network-worker risk, and transcript prompt leakage. This gates backlog item 004 and any default network/model worker.

Delivered: `scripts/verify-ai-execution-security.sh` now replays unauthenticated
and hostile-origin mutation attempts, proves server-bound approval actor
identity, denies network worker dispatch without consent, and runs a redaction
fixture for consented network dispatch. Receipts live in
`docs/evidence/ai-execution-security/`.
