# Default OpenCode subagent worker

Priority: P0 · Status: done · Estimate: L

## Goal

Approved Standby action cards dispatch to a single OpenCode subagent worker by
default, with no OMP path, no local fallback, no worker profile settings, and
visible event-log receipts for success or failure.

## PRD Summary

- User: meeting operator who approves AI-suggested work during a live call.
- Problem: current worker code still models execution as configurable profiles
  and falls back to deterministic local/OMP paths, which contradicts the
  opinionated product experience.
- Goal: make subagent execution the default product path through OpenCode.
- Why now: suggested actions are only credible if approved work actually runs
  through the intended unsupervised agent harness and reports back.
- UX enabled: approve a proposal, see a running OpenCode job, then see the
  result or failure receipt without choosing a harness or toggling settings.
- Deliverable type: code, deletion, receipts, and gate updates.
- Success signal: the default local app can approve a proposal and produce an
  OpenCode-backed terminal job event, or an honest OpenCode failure receipt.

## Product Requirements

- P0: delete product use of `WorkerProfile` selection for `local-research`,
  `omp-research`, `claude-research`, or `pi-research`.
- P0: delete product dependence on `STANDBY_WORKER_PROFILE`,
  `STANDBY_ALLOW_NETWORK_WORKER`, and `STANDBY_OMP_MODEL`.
- P0: approval queues the OpenCode worker by default; no second network-worker
  consent toggle is required after approval.
- P0: missing OpenCode, missing auth, or policy denial records
  `agent_job.failed` with a receipt path and human-readable reason.
- P0: OpenCode receives context via private files, not sensitive prompt argv.
- P0: OpenCode runs with isolated HOME/XDG dirs, scrubbed env, constrained
  workspace access, and JSON event capture.
- P0: transcript text is evidence only; it cannot bypass approval, choose tools,
  mutate repos, spend money, or send messages.
- P1: UI job status names OpenCode explicitly enough that the operator can tell
  a real subagent is running.

## Oracle

- [x] `rg "STANDBY_WORKER_PROFILE|STANDBY_ALLOW_NETWORK_WORKER|STANDBY_OMP_MODEL|omp-research|claude-research|pi-research" crates scripts README.md AGENTS.md backlog.d docs` returns only historical/superseded references, not product code or active gates.
- [x] Approving a seeded proposal queues an `agent_job.requested` whose worker
  substrate/profile is OpenCode.
- [x] If `opencode` is unavailable or unauthenticated, the job reaches
  `agent_job.failed` with receipt files; no fallback job runs.
- [x] If `opencode` is available, a smoke produces `agent_job.started`,
  progress/output events, and either an artifact or terminal failure receipt.
- [x] The worker sandbox negative test proves the worker cannot mutate the repo,
  read common secret stores, or write outside scratch.
- [x] `./scripts/verify.sh` passes and includes the OpenCode-default worker
  boundary proof.

## Verification System

- Claim: Standby has one product worker substrate, OpenCode, and approved work
  dispatches to it by default with auditable receipts.
- Falsifier: any product profile selector remains, OMP/local fallback runs,
  approval needs a hidden env flag, prompt content leaks through argv, OpenCode
  failure disappears, or the worker can mutate/read outside allowed boundaries.
- Driver: unit tests over worker config, route replay from seeded proposal to
  terminal job, missing-binary/auth-failure smoke, available-OpenCode smoke when
  auth exists, sandbox negative test, and full gate.
- Grader: event assertions, receipt-file assertions, env/argv inspection,
  sandbox denial logs, and source grep for deleted fallback settings.
- Evidence packet: `docs/evidence/opencode-default-worker/`.
- Cadence: red test for fallback/profile deletion first, then implementation,
  then full gate.

## Implementation Notes

1. Replace the configurable worker profile model with an `OpenCodeWorker`
   boundary that prepares the job scratch, private prompt/request files, isolated
   HOME/XDG dirs, redacted prompt content, scrubbed env, and OpenCode config.
2. Port the hardened pieces from Cerberus `src/harness.rs`: private file
   transport, JSON event reduction, directory permission config, env allowlist,
   and receipt collection.
3. Delete OMP CLI arguments, OMP model envs, fallback selection, and default
   local worker references from product paths.
4. Keep deterministic fixtures only behind test names that cannot be selected by
   the running product.
5. Replace `scripts/verify-model-worker-boundary.sh` with an OpenCode-default
   verifier and wire it into `./scripts/verify.sh`.

## Implementation Receipt

- Deleted product worker profile selection and the local/OMP/Claude/Pi fallback
  paths.
- Approval now queues `profile: "opencode"` by construction; the daemon worker
  loop always runs `WorkerProfile::opencode()`.
- OpenCode runs as `opencode run --format json --model openrouter/z-ai/glm-5.2`
  with private `job-request.json` and `prompt.txt` attachments, isolated
  HOME/XDG dirs, scrubbed env allowlist, generated OpenCode permission config,
  and sandbox receipts.
- `scripts/fixtures/fake-opencode.sh` lets CI prove the product command path
  without spending tokens; missing real OpenCode still fails visibly with
  `agent_job.failed` and receipt files.
- `scripts/verify-opencode-worker.sh` replaces the old OMP boundary verifier and
  is wired into `./scripts/verify.sh`.
- Real OpenCode route proof passed: approving a seeded proposal through
  `standbyd` ran `openrouter/z-ai/glm-5.2`, completed through the default
  OpenCode worker, and surfaced parsed model text (`STANDBY_OK`) instead of raw
  JSONL in `docs/evidence/opencode-default-worker/live-real-opencode-route-verdict.json`.
