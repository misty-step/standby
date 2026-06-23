# 0003: OpenCode-only worker is an accepted single point of failure

Status: accepted  
Date: 2026-06-22

## Decision

Standby dispatches approved agent work only to OpenCode (ADR 0002). If OpenCode
is missing, unauthenticated, or its pinned model / provider / network is
unreachable, the job fails visibly with an `agent_job.failed` event and a
receipt. Standby will NOT add a fallback worker substrate, a retry-to-another-
provider path, or a local-execution degradation mode. This single point of
failure is an accepted product risk.

## Why this is acceptable

- **The realtime core is local and unaffected.** Capture, transcription, the
  append-only event ledger, proposals, and the deterministic approval gate all
  run locally. A worker outage degrades exactly one optional, post-approval
  step — starting background agent work — not the meeting surface itself.
- **The failure is honest and cheap.** The operator sees a terminal
  `agent_job.failed` receipt naming the cause. They lose one piece of agent
  work for one card — not data, transcript, or audit trail.
- **Total provider unavailability mid-call is low-probability, and explicitly
  out of scope.** The owner has accepted that if every provider is down the
  product need not function; engineering around that case is not worth its cost.
- **A fallback substrate would undo the deletion that made the product simple.**
  It would reintroduce the worker-profile selector, multi-harness env flags, and
  policy surface that backlog 004→009 and ADR 0002 deliberately removed. One
  harness is worth more than marginal resilience to a rare outage.

## Consequences

- No `STANDBY_WORKER_PROFILE`, fallback harness, or "try another provider" logic
  enters product code. The existing terminal-failure path (`classify_failure` →
  `agent_job.failed`, `crates/standby-core/src/worker.rs`) is the complete and
  intended behavior.
- This closes the open question raised by the 2026-06-21 groom premise-challenger
  lane ("OpenCode-no-fallback is an unexamined SPOF vs the local-first bet"). It
  is examined and accepted, not unexamined.
- If Standby ever targets offline-capable operation as a first-class
  requirement, this ADR must be revisited. Today that is not a requirement.

## Relationship

Extends ADR `0002-opencode-default-subagent-worker.md`. Does not supersede it.
