# Speaker Diarization Options

Date: 2026-06-19

## Finding

Speaker diarization is available, but it is not one product-shaped capability.
For Standby there are three viable lanes:

1. **Cloud, buffered transcription + diarization**: fastest route to real
   speaker labels for recorded or short buffered audio. OpenAI
   `gpt-4o-transcribe-diarize` returns speaker-aware segments through
   `diarized_json`, but it is only available on `/v1/audio/transcriptions`, not
   the Realtime API. ElevenLabs Scribe v2 supports diarization with word-level
   `speaker_id`, up to 32 speakers, and optional role labels.
2. **Local/offline diarization sidecar**: best fit for Standby's local-first
   default. pyannote `speaker-diarization-community-1` runs locally after model
   download and emits generic speaker turns such as `SPEAKER_00`; pyannoteAI
   also offers hosted and streaming APIs if we decide to make a cloud adapter.
3. **GPU streaming stack**: strongest long-term local/streaming option, but
   heavier. NVIDIA NeMo's Sortformer is the diarizer. NVIDIA's multitalker
   Parakeet model consumes diarization outputs as speaker activity information;
   it is not a standalone diarizer.

## Sources

- OpenAI Speech to Text guide: `gpt-4o-transcribe-diarize` supports
  `diarized_json` with `speaker`, `start`, and `end` metadata, requires
  `chunking_strategy` for inputs longer than 30 seconds, supports up to four
  known-speaker references, and is not supported in the Realtime API.
  <https://developers.openai.com/api/docs/guides/speech-to-text>
- OpenAI transcription API reference: `diarized_json` is required to receive
  speaker annotations from `gpt-4o-transcribe-diarize`.
  <https://developers.openai.com/api/reference/python/resources/audio/subresources/transcriptions/methods/create/>
- ElevenLabs Speech to Text API: `scribe_v2` supports `diarize`, `num_speakers`
  from 1-32, `diarization_threshold`, speaker library matching, and optional
  `detect_speaker_roles`; words carry `speaker_id`.
  <https://elevenlabs.io/docs/api-reference/speech-to-text/convert>
- NVIDIA NeMo speaker diarization models: Sortformer generates speaker labels
  directly from audio; NeMo also supports a VAD + embedding + MSDD pipeline.
  <https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/speaker_diarization/models.html>
- NVIDIA multitalker Parakeet model card: streaming multitalker ASR uses
  diarization output as external speaker activity input and deploys one model
  instance per speaker.
  <https://huggingface.co/nvidia/multitalker-parakeet-streaming-0.6b-v1>
- pyannote community-1 model card: local pipeline ingests audio and outputs
  speaker diarization, with offline use after setup.
  <https://huggingface.co/pyannote/speaker-diarization-community-1>
- pyannoteAI streaming diarization docs: hosted beta WebSocket API emits
  real-time speaker turn events from streamed audio.
  <https://docs.pyannote.ai/tutorials/streaming-real-time>

## Standby Design Implication

Do not put diarization in the Swift capture helper or the React UI. The helper
should keep emitting capture JSONL, and the core should accept a narrow
diarization/provider-attribution adapter that emits normalized transcript spans:

```text
audio frames or chunked recording
  -> DiarizationProvider adapter
  -> speaker turns / speaker-attributed transcript spans
  -> EventStore segment.final events
  -> projection + UI labels
```

The default local-first path should be a sidecar contract, not a Python embed in
Rust core:

```json
{"type":"speaker.turn","speaker":"SPEAKER_00","start_ms":1200,"end_ms":3800,"confidence":0.91}
{"type":"segment.final","speaker":"remote_1","start_ms":1200,"end_ms":3800,"text":"...", "source":"diarizer"}
```

Provider adapters can map their native outputs into the same event contract:

- OpenAI: segment-level `speaker`, `start`, `end`, `text`.
- ElevenLabs: fold adjacent words with the same `speaker_id` into transcript
  spans.
- pyannote local/hosted: reconcile speaker turns with local STT spans.
- NVIDIA: Sortformer speaker activity plus multitalker ASR spans.

## Recommended Next Slice

1. Add a `DiarizationProvider` contract and fixture adapter in Rust core. The
   fixture must prove that Standby can ingest speaker turns independent of the
   transcript source.
2. Add one opt-in provider behind the contract:
   - **Fastest cloud proof**: ElevenLabs Scribe v2, because it returns
     word-level `speaker_id` directly and supports many speakers.
   - **Best local-first proof**: pyannote community-1 sidecar, because it can
     run offline and keeps the cloud boundary out of the default path.
3. Add a live gated smoke that records a short meeting buffer, runs the selected
   provider, and verifies two stable remote speaker buckets over multiple turns.

## Open Decisions

- Whether the first provider should be cloud-fast (ElevenLabs/OpenAI) or
  local-first (pyannote sidecar).
- Whether Standby should buffer 10-30 second chunks for near-real-time speaker
  labels, or only attach diarization after a meeting/section finishes.
- Whether named participant identification is in scope. Diarization gives
  `Speaker N`; names require roster/provider identity or voiceprints.
