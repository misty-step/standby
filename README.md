# Standby

Standby is a local-first meeting command surface: a quiet panel that listens to a
meeting transcript, drafts proposal cards, and routes approved work to worker
agents while keeping a durable event ledger.

The realtime agent is intentionally narrow. It can create proposal cards and
private meeting state. It cannot mutate external systems. Approved proposal
cards become worker jobs through deterministic API endpoints.

## MVP

- Rust daemon with an append-only SQLite `meeting_events` log.
- Deterministic demo transcript source.
- Proposal engine that emits one research proposal from concrete transcript
  evidence.
- Deterministic approval endpoint that starts a mock research worker.
- Normalized worker events for queued, started, progress, artifact, completed,
  ignored, and failed states.
- React card surface inspired by the Misty Step/Aesthetic operational UI.

## Run

```sh
./scripts/verify.sh
cargo run -p standbyd
```

Then open `http://127.0.0.1:4317`.

The app seeds a demo meeting from the UI. Approving the proposal creates a
research job and result artifact in the local event log.

## Boundaries

The current worker is a local mock that proves orchestration and telemetry
without external keys. Capture adapters for Vexa, Recall.ai, Zoom RTMS, Google
Meet Media API, and local macOS audio belong behind the transcript-source
interface after this loop is stable.
