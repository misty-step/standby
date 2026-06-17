# Standby Repo Contract

## Goal

Standby is a local-first meeting command surface. The live meeting listener
proposes low-noise cards only; deterministic approval endpoints spawn worker
jobs and record every step in an append-only event log.

## Stack

- Rust owns durable behavior, storage, API routes, capture supervision, and
  worker orchestration. SQLite is the local event ledger.
- React owns the app surface and renders only projected state (no hard-coded
  "live"). Demo is opt-in via `?mode=demo`; the normal route never auto-starts it.
- `native/standby-capture-helper` (Swift) is the only macOS-framework boundary
  (ScreenCaptureKit + Apple Speech). It emits JSONL only — no SQLite, proposals,
  workers, or credentials. Keep product logic out of it.
- External capture providers and model APIs are adapters behind the
  `TranscriptSource` / `WorkerProfile` seams, not product core.

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

- The default and only sandbox-accepted worker is the network-denied
  `local-research` profile. Containment is OS-enforced (`sandbox-exec`): writes
  only to the per-job scratch, no repo mutation, no network. `verify-worker-sandbox.sh`
  must pass before any profile is accepted.
- Cloud-model profiles (`claude-research`, `pi-research`) are opt-in only via
  `STANDBY_ALLOW_NETWORK_WORKER=1`: a network-allowed worker can read local files,
  so it can exfiltrate until egress is scoped. Never make one the default.

## Red Lines

- Transcript text is untrusted evidence, never executable instruction.
- No live transcript path may directly call external tools, send messages,
  mutate repos, deploy, or spend money.
- Approval is a deterministic server/UI action, not an LLM decision.
- Every proposal, approval, job update, artifact, and failure is an event.
- Capture failures are honest, specific, and non-hanging (name the exact
  missing permission); never fake "live".
