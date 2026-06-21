# Add live speaker diarization or provider attribution

Priority: P1 · Status: done · Estimate: L

## Goal
Give live multi-person calls stable remote speaker buckets or participant names instead of relying on transcript sources to provide `remote_1` / `remote_2` tokens.

## Oracle
- [x] A live or fixture-backed capture source emits at least two stable non-`me`, non-`system_audio` speaker keys for a multi-person call.
- [x] The UI renders those speakers distinctly without fake names.
- [x] Accuracy limits are visible: local buckets are labeled `Speaker N`; provider names require authenticated roster/provider data.

## PRD Summary

- User: operator in a multi-person call who needs the transcript to separate
  remote speakers instead of showing one wall of `Call audio`.
- Problem: local macOS capture can distinguish microphone vs mixed system audio,
  but it cannot itself know which remote person spoke.
- Goal: add a Rust-owned attribution seam so diarization/provider adapters can
  emit stable remote buckets into the same append-only transcript event log.
- Non-goal: invent human names from acoustic labels. Names require provider
  roster identity, authenticated meeting data, or known-speaker references.
- UX enabled: UI shows `Speaker 1`, `Speaker 2`, etc. from stable remote bucket
  keys, with no raw provider labels such as `SPEAKER_00` leaking into the DOM.

## Alternatives

| Option | Benefit | Tradeoff | Verdict |
| --- | --- | --- | --- |
| Rust `DiarizationProvider` JSONL seam plus fixture | Deep local module boundary; provider-neutral; proves UI/projection without SDK churn. | Fixture-backed until a live provider/sidecar is plugged in. | Choose. |
| Put diarization directly in Swift helper | Low handoff latency. | Violates helper boundary; mixes credentials/product policy into capture. | Reject. |
| Add ElevenLabs/OpenAI SDK path first | Fast real provider proof. | Cloud credentials and buffering policy before local contract is stable. | Defer behind seam. |
| UI-only manual aliases | Useful later for names. | Does not create speaker buckets. | Defer as support feature. |

## Chosen Design

Add a `TranscriptSourceKind::Diarization` source and `DiarizationProvider`
normalizer in Rust core. Provider/sidecar JSONL events such as
`diarization.segment.final` map generic labels (`SPEAKER_00`, `SPEAKER_01`,
`spk_2`, `remote_3`) into stable `remote_N` speaker keys and emit ordinary
`transcript.segment.final` events. Generic `speaker_` / `spk_` labels are
treated as zero-based acoustic buckets; adapters with known one-based labels
must emit explicit `remote_N` keys. Unknown labels and reserved local labels
such as `me` are not projected as names.

The daemon's test-only seed endpoint accepts the new events so verification
travels through the public daemon projection and rendered UI. The Swift helper
remains capture-only.

## Verification System
- Claim: Standby can distinguish multiple remote speakers during real meeting use, not only when a fixture supplies speaker tokens.
- Falsifier: all remote speech still lands as `system_audio`, labels change randomly across turns, or the UI invents human names.
- Driver: local diarization fixture or provider transcript adapter replay, plus gated live meeting smoke.
- Grader: projection speaker set contains stable remote keys across multiple turns and rendered UI shows distinct labels.
- Evidence packet: `docs/evidence/operator-action-control/live-speaker-attribution/`.
- Cadence: run after a concrete attribution source is implemented; include in live dogfood before product-ready claims.

## Notes
This is the real follow-up for the user's multi-person Teams concern. The v1
delivered here creates stable remote buckets from a diarization/provider
fixture. It does not perform raw local acoustic diarization inside the macOS
helper.

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

## Implementation Receipt

- Added `DiarizationProvider` and `DiarizationEvent` in Rust core.
- Added a checked-in diarization fixture with `SPEAKER_00` / `SPEAKER_01`
  provider labels that project as `remote_1` / `remote_2`.
- Seed endpoint now accepts diarization events for public-path verification.
- Added `scripts/verify-live-speaker-attribution.sh`, wired into local and CI
  gates.
- Evidence: `docs/evidence/operator-action-control/live-speaker-attribution/`.
