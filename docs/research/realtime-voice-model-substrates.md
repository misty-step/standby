# Realtime Voice And Speech Model Substrates

Date: 2026-06-20

## Finding

Standby's automatic action proposal system should be model-native. Current
provider surfaces support realtime speech/voice reasoning, tool/function calls,
turn detection, transcription, and speaker-aware diarization well enough that a
keyword heuristic can only be justified as a fallback or fixture.

## Current Provider Facts

### OpenAI

- Realtime guide positions `gpt-realtime-2` for low-latency voice agents and
  `gpt-realtime-whisper` for streaming transcription.
- Realtime conversations support function calling and out-of-band responses
  (`conversation: "none"`), which fits proposal judging without speaking into
  the meeting.
- `gpt-4o-transcribe-diarize` supports `diarized_json` with speaker segments,
  requires chunking for longer audio, and is not yet supported in Realtime.

Sources:

- <https://developers.openai.com/api/docs/guides/realtime>
- <https://developers.openai.com/api/docs/guides/realtime-conversations>
- <https://developers.openai.com/api/docs/guides/speech-to-text#speaker-diarization>

### Google Gemini

- Gemini Live API supports realtime voice/vision interactions, tool use, audio
  transcriptions, and proactive audio controls.
- Gemini model docs list Flash Live models for low-latency audio-to-audio and
  bidirectional voice/video agents with native audio reasoning.

Sources:

- <https://ai.google.dev/gemini-api/docs/live-api>
- <https://ai.google.dev/gemini-api/docs/models>

### Deepgram

- Flux is positioned as conversational speech recognition for voice agents,
  including model-integrated end-of-turn detection and ultra-low latency.

Source:

- <https://developers.deepgram.com/docs/models-languages-overview>

### ElevenLabs

- Scribe v2 supports word timestamps and speaker diarization up to 32 speakers.
- Scribe v2 Realtime is documented for low-latency realtime transcription and
  word-level timestamps; verify realtime diarization before relying on it.

Source:

- <https://elevenlabs.io/docs/overview/capabilities/speech-to-text>

## Standby Design Implication

Use a provider-shaped architecture:

```text
capture / transcript / audio buffer
  -> RealtimeProposalAgent or SpeechProvider adapter
  -> typed proposal candidates + evidence references
  -> deterministic schema/policy/dedupe/event log
  -> operator approval
  -> worker profile dispatch
  -> durable job events + receipts
```

Rust should own the deep local module boundary. The model should own semantic
judgment. The eval harness should prove the model's judgment quality against
held-out transcripts, operator nudges, paraphrases, negations, and provider
failure cases.
