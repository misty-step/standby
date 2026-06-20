# Premise: AI-First Standby Pivot

Date: 2026-06-20

## Operator Signal

The product premise is not "detect a few research phrases in a transcript." It
is an AI-enabled meeting command surface: realtime speech/voice models should
understand live context, propose useful work, accept operator nudges, dispatch
approved subagents, and report back.

The failure to codify that premise produced the wrong local architecture:
keyword heuristics were treated as the proposal brain instead of a fallback or
test fixture.

## Current Repo Evidence

- `crates/standby-core/src/engine.rs` uses static cue lists and deterministic
  thresholds for automatic research proposals.
- `crates/standby-core/src/proposal_request.rs` lets the operator force a card,
  but still constructs the proposal deterministically.
- `crates/standby-core/src/worker.rs` has visible worker lifecycle and sandbox
  boundaries, but model/tool worker profiles remain gated and not yet a robust
  agent execution plane.
- `backlog.d/005-live-speaker-diarization-or-provider-attribution.md` tracks
  the live multi-speaker gap: local capture still does not create stable remote
  speakers.

## External Evidence Summary

- OpenAI Realtime supports live voice-agent sessions and function/tool calling;
  out-of-band responses fit side-channel proposal classification.
- OpenAI `gpt-4o-transcribe-diarize` supports speaker-aware transcription via
  `/v1/audio/transcriptions`, but not Realtime.
- Gemini Live, Deepgram Flux, and ElevenLabs Scribe provide relevant realtime
  voice, turn-taking, transcription, and diarization surfaces that should be
  evaluated through adapters, not hard-coded into product logic.

## Design Consequence

Standby needs a model-native `ProposalAgent` boundary with deterministic
approval, policy, event logging, worker dispatch, and quality gates around it.
The existing heuristic proposal engine should be demoted to fallback/test-only
once the model-native path exists.
