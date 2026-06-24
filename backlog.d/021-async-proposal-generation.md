# Move proposal generation off the capture-ingest critical path

Priority: P1 · Status: ready · Estimate: M

## Goal
The live transcript never stalls while the proposal reasoner runs — proposal generation happens off the capture-ingest task, so finalized segments keep flowing during the (multi-second) model call.

## Oracle
- [ ] During an automatic proposal model call, new finalized transcript segments still append + render with no perceptible lag (the capture stdout reader is not blocked).
- [ ] A slow / timing-out reasoner call cannot delay transcript ingestion or stall the daemon's tokio workers.
- [ ] Concurrent proposal calls are bounded (debounce honored; no unbounded fan-out if segments arrive fast).
- [ ] `./scripts/verify.sh` green; fixture replay stays deterministic.

## Verification System
- Claim: transcript ingestion latency is independent of proposal-model latency.
- Falsifier: a forced slow (e.g. `sleep`) reasoner delays segment append.
- Driver: a live/seed run with an artificially slow provider; compare segment-append timestamps against the in-flight call window.
- Grader: segment append timestamps show no gap aligned to the model call.
- Evidence packet: timing log + redacted projection.
- Cadence: this ticket + a perf regression guard.

## Notes
**Why:** Shipping `020` steps 2–3 (the append-only feed) made the real OpenRouter reasoner the default **and** proactive, so automatic model calls (~5–15s on `deepseek/deepseek-v4-pro`, occasionally hitting the now-60s timeout) actually happen frequently. They run **synchronously** inside `LocalMacAudioSource::ingest`, which is called from the capture stdout reader task (`crates/standbyd/src/capture.rs:102-110`, a `tokio::spawn` loop). While a call runs, that task stops reading helper stdout → finalized segments queue → the transcript lags by the call duration, and a tokio worker is blocked on the `std::thread::spawn(...).join()` in `openrouter_response` / `openai_response`.

Pre-existing (the OpenAI path had the same shape) but newly load-bearing now that a real model is the default. Fix: append the segment fast, then run the reasoner off-path — e.g. `tokio::task::spawn_blocking(move || propose_from_meeting_context(...))` with the store as an `Arc`, keeping the debounce so calls stay bounded. The `ingest`-does-both (append + propose) contract is relied on by the fixture replay + seed tests, so split carefully: either a live-only off-path trigger in `capture.rs`, or make `ingest` append-only and move the trigger to each caller.

The 60s HTTP timeout (set in `020`) reduces flaky timeouts but does not remove the on-path blocking. The cheap-gate model (Option B in `docs/shape/dynamic-proposal-agent.html`) would shrink call duration but is orthogonal to moving it off-path.
