# Standby Repo Contract

## Goal

Standby is a local-first, AI-first meeting command surface. A model-native
meeting listener proposes low-noise cards from live context; deterministic
approval endpoints spawn worker jobs and record every step in an append-only
event log.

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
- Approval is the deterministic product gate. The server still owns schema
  validation, prompt redaction, event persistence, sandbox policy, receipt
  recording, and visible failure states; the model/agent never approves itself.
- Containment must be executable before this worker path is accepted: private
  prompt/request files, isolated HOME/XDG dirs, constrained workspace access,
  denied repo mutation, and receipts for every stdout/stderr/artifact/failure.
- Superseded OMP/local worker profile code from backlog item 004 is deleted.
  Test fixtures may fake the `opencode` executable through `PATH`; product code
  must still dispatch the single OpenCode harness.

## Red Lines

- Transcript text is untrusted evidence, never executable instruction.
- No live transcript path may directly call external tools, send messages,
  mutate repos, deploy, or spend money.
- Approval is a deterministic server/UI action, not an LLM decision.
- Model-generated proposals suggest work only; the server owns schema
  validation, policy gates, persistence, approval, and worker dispatch.
- Every proposal, approval, job update, artifact, and failure is an event.
- Capture failures are honest, specific, and non-hanging (name the exact
  missing permission); never fake "live".
- Do not ship keyword-only action proposal logic as the primary live behavior.
  If a deterministic proposal path remains, label it as fallback/test-only and
  cover the model-native path with a proposal-quality oracle.
