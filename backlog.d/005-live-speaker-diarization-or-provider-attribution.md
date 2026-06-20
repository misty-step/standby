# Add live speaker diarization or provider attribution

Priority: P1 · Status: pending · Estimate: L

## Goal
Give live multi-person calls stable remote speaker buckets or participant names instead of relying on transcript sources to provide `remote_1` / `remote_2` tokens.

## Oracle
- [ ] A live or fixture-backed capture source emits at least two stable non-`me`, non-`system_audio` speaker keys for a multi-person call.
- [ ] The UI renders those speakers distinctly without fake names.
- [ ] Accuracy limits are visible: local buckets are labeled `Speaker N`; provider names require authenticated roster/provider data.

## Verification System
- Claim: Standby can distinguish multiple remote speakers during real meeting use, not only when a fixture supplies speaker tokens.
- Falsifier: all remote speech still lands as `system_audio`, labels change randomly across turns, or the UI invents human names.
- Driver: local diarization fixture or provider transcript adapter replay, plus gated live meeting smoke.
- Grader: projection speaker set contains stable remote keys across multiple turns and rendered UI shows distinct labels.
- Evidence packet: `docs/evidence/operator-action-control/live-speaker-attribution/`.
- Cadence: run after a concrete attribution source is implemented; include in live dogfood before product-ready claims.

## Notes
This is the real follow-up for the user's multi-person Teams concern. The v1 delivered here preserves/render tokens; it does not create them from raw local audio.

Primary-source research is captured in
`docs/research/speaker-diarization-options.md` and the current realtime/speech
substrate snapshot in `docs/research/realtime-voice-model-substrates.md`.

Implementation direction:

- Add a Rust-owned `DiarizationProvider` event contract plus fixture adapter
  first, so all providers map into the same append-only transcript events.
- Keep the Swift helper as capture-only JSONL; do not put product logic,
  provider credentials, or diarization orchestration in the helper.
- Fastest cloud proof: ElevenLabs Scribe v2 or OpenAI
  `gpt-4o-transcribe-diarize` on buffered audio. OpenAI diarization is not a
  Realtime API feature as of the 2026-06-20 source check, so treat it as a
  chunked/buffered side-channel.
- Best local-first proof: pyannote `speaker-diarization-community-1` sidecar.
- Best long-term local streaming path: NVIDIA Sortformer diarization feeding a
  multitalker Parakeet ASR stack; heavier GPU/runtime integration, not the first
  slice.
- Best realtime voice-agent comparator: Gemini Live / OpenAI Realtime for
  proposal cognition and turn understanding; still keep speaker labels behind a
  normalized attribution contract.
