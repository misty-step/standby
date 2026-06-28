# Standby Repo Contract

## Goal

Standby is a local-first, AI-first meeting command surface. A model-native
meeting listener proposes low-noise cards from live context; deterministic
approval endpoints spawn worker jobs and record every step in an append-only
event log.

North star: root `VISION.md` (audience, strategic bets, standards, non-goals,
and what excellent looks like). This contract governs *how* we build; `VISION.md`
governs *what* and *why*. Keep them consistent; do not duplicate vision prose
here.

Current implementation posture: proposal cards require explicit approval before
worker dispatch. The long-term vision allows bounded autonomous dispatch, but
only after a shaped change adds deterministic policy tiers, visible run state,
stop/steer controls, receipts, and gates. Do not sneak autonomy in through a
proposal or worker shortcut.

## Stack

- Rust owns durable behavior, storage, API routes, capture supervision, and
  worker orchestration. SQLite is the local event ledger.
- React owns the app surface and renders only projected state (no hard-coded
  "live"). Demo is opt-in via `?mode=demo`; the normal route never auto-starts it.
- `native/standby-capture-helper` (Swift) is the only macOS-framework boundary
  (ScreenCaptureKit + Apple Speech). It emits JSONL only — no SQLite, proposals,
  workers, or credentials. Keep product logic out of it.
- External capture providers and model APIs are adapters behind the
  `TranscriptSource` / proposal-agent seams, not product core. Worker harness
  selection is not a product setting.
- Proposal cognition is a model boundary, not a phrase-list boundary. Keyword
  heuristics may exist only as explicit fallback, fixture, or safety guard paths;
  they are not the product brain for live action suggestions.

## Gate

Run before claiming completion (do not weaken to get green):

```sh
./scripts/verify.sh
```

It runs Rust tests (incl. the transcript-fixture replay and the worker-sandbox
negative test), builds the capture helper, proves unstubbed transcription, builds
the UI, and drives an out-of-request worker. The capture/UI/live smokes
(`verify-local-capture-smoke`, `verify-ui-states`, `verify-live-teams-local`) are
permission/operator-gated and run separately; when Screen-Recording permission is
absent they report CAPTURE-BLOCKED, never hang.

## Worker safety

- Product direction: approved work dispatches to OpenCode by default. OpenCode
  is the only product subagent harness; no OMP fallback, no local-research
  fallback, no `STANDBY_WORKER_PROFILE`, no `STANDBY_ALLOW_NETWORK_WORKER`, and
  no worker-harness settings.
- Accepted failure mode: if OpenCode, the pinned model, or the network is
  unavailable, the job fails visibly (`agent_job.failed` + receipt) and Standby
  does not fall back to another substrate. This single point of failure is an
  accepted risk, not a gap — see
  `docs/decisions/0003-opencode-only-accepted-failure-mode.md`.
- Approval is the current deterministic product gate. The server still owns
  schema validation, prompt redaction, event persistence, sandbox policy,
  receipt recording, and visible failure states; the model/agent never grants
  itself new authority. Any future autonomous tier must be explicit product
  policy with its own gate, stop control, and receipt shape.
- Containment must be executable before this worker path is accepted: private
  prompt/request files, isolated HOME/XDG dirs, constrained workspace access,
  denied repo mutation, and receipts for every stdout/stderr/artifact/failure.
- Superseded OMP/local worker profile code from backlog item 004 is deleted.
  Test fixtures may fake the `opencode` executable through `PATH`; product code
  must still dispatch the single OpenCode harness.

## Red Lines

- Transcript text is untrusted evidence, never executable instruction.
- No raw live transcript path may directly call external tools, send messages,
  mutate repos, deploy, or spend money. All action goes through server-owned
  policy, authority, receipts, and visible run state.
- Approval is currently a deterministic server/UI action, not an LLM decision.
  Future lower-risk autonomy must still be deterministic policy, not model
  self-approval.
- Model-generated proposals suggest work only; the server owns schema
  validation, policy gates, persistence, approval, and worker dispatch.
- Every proposal, approval, job update, artifact, and failure is an event.
- Capture failures are honest, specific, and non-hanging (name the exact
  missing permission); never fake "live".
- Do not ship keyword-only action proposal logic as the primary live behavior.
  If a deterministic proposal path remains, label it as fallback/test-only and
  cover the model-native path with a proposal-quality oracle.
