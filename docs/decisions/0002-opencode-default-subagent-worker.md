# 0002: OpenCode is the default Standby subagent worker

Status: accepted  
Date: 2026-06-20

## Decision

Standby uses OpenCode as its default and only product subagent worker harness.
Approved actions dispatch to OpenCode without a worker-profile selector,
fallback harness, global enablement flag, or user-facing harness setting.

This supersedes the OMP/local profile direction delivered in backlog item 004.
The OMP path is legacy-to-delete, not a compatibility target.

## Product Rules

- Subagent execution is a critical default capability, not an opt-in advanced
  profile.
- Approval is the deterministic execution gate. Once the operator approves a
  card, the server queues the OpenCode job.
- No fallback behavior: if OpenCode is missing, unauthenticated, or fails, the
  job records `agent_job.failed` with receipts.
- No worker-harness configuration: remove `STANDBY_WORKER_PROFILE`,
  `STANDBY_ALLOW_NETWORK_WORKER`, `STANDBY_OMP_MODEL`, and any UI/settings path
  that chooses a worker substrate.
- Deterministic Rust code owns validation, policy, persistence, approval,
  sandbox setup, prompt redaction, event projection, and receipts.
- OpenCode owns unsupervised agentic execution and may use dynamic subagents
  internally.

## Research Basis

Local cross-repo research found the same architectural conclusion in the review
stack:

- Cerberus ADR `docs/adr/0002-opencode-as-default-review-substrate.md` accepts
  OpenCode as the production-oriented default because it is server/session-first
  and fits programmatic sessions, structured events, concurrent lanes, durable
  service kernels, and control-plane integration better than OMP.
- Cerberus `src/harness.rs` shows the hardened shape Standby should copy:
  private prompt/request files, isolated HOME/XDG dirs, scrubbed env, prepared
  workspace, OpenCode JSON event output, and generated OpenCode config limiting
  allowed directories and denying edits.
- Bitterblossom `docs/plans/2026-06-19-cerberus-substrate-findings.md` frames
  OpenCode as the production master substrate while the event plane stays
  substrate-agnostic and records dispatch/results.
- Daedalus `docs/premises/2026-06-19-coding-agent-substrates.md` ranks OpenCode
  ahead of OMP for owned review/control-plane platforms because of session,
  concurrency, event, SDK/server, retry, routing, and tool-policy fit.

Standby is not a code-review product, but the substrate lesson transfers: it is
also an unsupervised control-plane product that needs durable eventing,
receipts, policy, and trustworthy background execution.

## Consequences

- Backlog item 004 remains useful only as history and a deletion map.
- Backlog item 009 is the immediate implementation ticket.
- `local-research` can remain only as a test fixture while 009 is in flight; it
  must not be selected by product code.
- Existing tests and scripts that prove OMP fallback behavior are legacy proofs
  and must be replaced by OpenCode-default proofs.
- Security work from backlog item 008 still applies, but the UX simplification
  is that approval launches the default OpenCode worker; there is no second
  product consent toggle or global network-worker switch.

## Acceptance Shape

The implementation is accepted only when the repo proves:

- An approved proposal queues an OpenCode job by default.
- There is no worker profile environment selector or fallback path in product
  code.
- OpenCode runs from private request/prompt files with isolated HOME/XDG dirs,
  scrubbed env, constrained workspace access, and JSON event capture.
- Missing OpenCode/auth produces a visible terminal failure event and receipt.
- Transcript text remains untrusted evidence; it cannot cause execution without
  the deterministic approval route.
