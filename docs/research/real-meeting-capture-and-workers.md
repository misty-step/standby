# Research: Real Meeting Capture And Worker Dispatch

Date: 2026-06-17

## Synthesis

Standby should not build one primary capture adapter per meeting app. The
product outcome is "hear the call I am already taking on this Mac," so the
primary capture path should be OS-level local audio capture:

```text
LocalMacAudioSource
  -> microphone audio + system/app audio
  -> streaming transcription
  -> transcript.segment.partial/final events
  -> proposal detector
  -> approved worker jobs
```

Microsoft Teams is still the first dogfood app, but "Teams first" means the
first live test should be a Teams call whose audio flows through the Mac capture
path. Teams, Zoom, Google Meet, Vexa, Recall, and Graph integrations are optional
provider adapters for metadata, diarization, bot capture, or post-meeting
backfill. They should not be the product core.

Approved work should dispatch through a durable local job runner, not inside the
approval request. The first unstubbed worker should be a read-only research
worker that launches an installed local CLI agent with executable tool
restrictions, records stdout, stderr, exit status, duration, and artifact paths
as normalized job events, and passes a malicious-transcript sandbox verifier.
Coding and mutation-capable workers should follow only after permission
enforcement exists.

## Source Matrix

| Source lane | Status | What it contributed | Key refs |
| --- | --- | --- | --- |
| Codebase | complete | Current Standby is demo-only: fixture transcript, `MockResearchWorker`, synchronous approval, no real capture route, and UI copy that overclaims live transcription. | `README.md`, `crates/standby-core/src/worker.rs`, `crates/standbyd/src/main.rs`, `ui/src/main.tsx`, `scripts/verify.sh` |
| Granola | complete | Strong evidence for bot-free meeting capture: desktop app uses system audio plus microphone, works across meeting apps, and accepts weaker desktop diarization in exchange for universal capture. | https://docs.granola.ai/help-center/taking-notes/transcription, https://www.granola.ai/, https://www.granola.ai/blog/granola-microsoft-teams-bot-free-notes |
| Monologue | complete | Conversation material is exposed to agents through API/CLI/MCP style surfaces rather than meeting-app-specific capture contracts. Local evidence shows a single app-owned transcript history. | https://every.to/on-every/introducing-monologue-notes-record-every-meeting-call-and-voice-memo, https://github.com/EveryInc/monologue-toolkit, `/Users/phaedrus/Development/atlas/systems/daybook/scripts/MONOLOGUE-SYNC.md` |
| Open source alternatives | complete | Meetily and Minutes reinforce the local-capture/local-corpus pattern: microphone/system audio, local processing, markdown/JSONL/CLI/MCP access for agents. | https://github.com/Zackriya-Solutions/meetily, https://meetily.ai/open-source, https://www.useminutes.app/for-agents |
| Apple platform docs | complete | ScreenCaptureKit is the native macOS foundation for screen/audio capture; Speech is the native framework for live speech-to-text. | https://developer.apple.com/documentation/screencapturekit, https://developer.apple.com/documentation/speech |
| Rust capture bindings | partial | `screencapturekit-rs` appears to expose ScreenCaptureKit from Rust, including system audio and microphone features. Treat it as a candidate to verify in implementation, not a committed dependency. | https://github.com/svtlabs/screencapturekit-rs, https://crates.io/crates/screencapturekit |
| Teams and bot providers | complete | Teams raw media, Graph transcripts, Vexa, and Recall remain useful optional adapters, but they fail the "any call on my Mac" primary path. | Microsoft Learn, Vexa docs, Recall docs/research |
| Local worker CLIs | complete | `codex`, `claude`, `pi`, `goose`, and `opencode` are installed and expose noninteractive modes suitable for an adapter. | local command help output |

## Evidence

### Granola Pattern: Bot-Free Desktop Capture

Granola's homepage says it works without a meeting bot, uses computer audio, and
works with Zoom, Google Meet, Teams, and other meeting apps:
https://www.granola.ai/

Granola's transcription docs are more precise. They say the desktop app runs on
the user's computer and uses system audio plus microphone. The same docs state
that desktop transcription distinguishes "Me" and "Them" rather than full live
speaker diarization, and that system audio capture includes whatever audio is
playing on the computer:
https://docs.granola.ai/help-center/taking-notes/transcription

Granola's Teams guide describes the Teams path as audio-device setup, not a
Teams API integration. It calls out the macOS Microphone and Screen & System
Audio Recording permissions and warns that mismatched Teams/system audio devices
can cause one-sided capture:
https://www.granola.ai/blog/granola-microsoft-teams-bot-free-notes

Design implication for Standby: copy the product shape, not the exact stack.
Default to one local audio source that can hear any call. Treat speaker identity
as a graduated capability: `me`, `system_audio`, `unknown`, and later diarized
speaker labels when a source provides them.

### Monologue Pattern: Conversation Corpus For Agents

Monologue's launch post describes recording and transcribing meetings, calls,
and voice memos, then making that material available to agents and tools:
https://every.to/on-every/introducing-monologue-notes-record-every-meeting-call-and-voice-memo

The open `monologue-toolkit` repository exposes Monologue notes through a CLI
and an installable agent skill. It is read-only today and supports listing,
searching, fetching, and pulling summaries/transcripts through the public Notes
API:
https://github.com/EveryInc/monologue-toolkit

Local Atlas evidence shows Monologue data as one app-owned transcript history at
`~/Library/Containers/com.zeitalabs.jottleai/Data/Documents/transcription_history.json`.
The sync script reads that corpus and writes markdown; it does not need a Zoom,
Teams, or Meet adapter:
`/Users/phaedrus/Development/atlas/systems/daybook/scripts/MONOLOGUE-SYNC.md`

Design implication for Standby: the durable product object is the local event
ledger and agent-facing artifacts, not the meeting app integration.

### Open Source Pattern: Local Audio Plus Agent Surfaces

Meetily describes itself as a privacy-first meeting assistant built around Rust,
live transcription, speaker diarization, Ollama summarization, and local
processing:
https://github.com/Zackriya-Solutions/meetily

Meetily's open source page emphasizes 100% local processing, no cloud, offline
use, and local control over meeting data:
https://meetily.ai/open-source

Minutes positions the category as local conversation memory: structured markdown
under `~/meetings/`, live transcript JSONL, CLI commands, and MCP tools that can
be read by Codex, Claude Code, Pi, OpenCode, and other agents:
https://www.useminutes.app/for-agents

Design implication for Standby: local capture and local artifacts are enough for
the primary loop. MCP/API integrations should sit behind the worker/artifact
layer, not inside the realtime meeting listener.

### Native Mac Capture

Apple's ScreenCaptureKit documentation describes high-performance capture of
screen and audio content on macOS:
https://developer.apple.com/documentation/screencapturekit

Apple's Speech framework documentation describes live speech-to-text support
through SpeechAnalyzer and related APIs:
https://developer.apple.com/documentation/speech

The Rust `screencapturekit` crate is a candidate adapter for keeping the durable
backend Rust-first while crossing the Apple framework boundary:
https://github.com/svtlabs/screencapturekit-rs

Implementation implication: first prove a small `standby-capture-smoke` binary
can acquire TCC permissions, open a ScreenCaptureKit stream, see nonzero audio
frames from system audio and mic, and emit sanitized audio-frame metrics. Only
then wire transcription and proposal detection.

### Optional Teams/Bot Providers

Microsoft Graph transcript APIs are useful but post-meeting, not a live meeting
command surface. Microsoft real-time media bots are official but Windows/.NET
heavy and optimized for specialized scenarios. Vexa and Recall can still be
valuable for bot capture and speaker-aware transcripts, especially in enterprise
or remote-worker contexts.

Design implication: keep the `TranscriptSource` trait, but make
`LocalMacAudioSource` the default source. Provider adapters are additive:
`VexaBotSource`, `RecallBotSource`, `TeamsGraphImportSource`,
`ZoomRtmsSource`, and similar.

### Local Worker CLIs

Local commands found in the environment:

```text
codex
claude
pi
goose
opencode
cursor-agent
grok
agy
hermes
thinktank
```

Automation-relevant help output verified locally:

- `codex exec` supports noninteractive execution, JSONL events, output schema,
  output-last-message, sandbox selection, and working directory selection.
- `claude -p` supports noninteractive output, JSON/stream-json, JSON schema,
  tool allow/deny lists, permission modes, and max budget.
- `pi -p` supports noninteractive text/json/rpc modes, read-only tool
  allowlists, no-session mode, and provider/model overrides.
- `opencode run` supports JSON event output.
- `goose run` supports stdin/file instructions, quiet mode, no-session mode,
  provider/model overrides, and max-turn limits.

Design implication: start with one real read-only worker profile that can prove
tool restrictions. Claude Code is the best first target because local help shows
tool allow/deny controls, structured output, and budget limits. Pi is a viable
fallback because it can run with `--no-tools` or an explicit read-only tool list.
Codex remains important for later coding workers, but it should not be the first
approved-meeting worker unless its profile passes the same sandbox verifier. Keep
the adapter output normalized so another CLI can replace it without changing the
meeting UI.

## Conflicts

Teams-first no longer means Teams-API-first. The more correct first product
claim is: "Standby can listen to the audio from a Teams call running on this Mac
and propose work." That also proves the harder long-term requirement: any call
whose audio is routed through the computer can be captured.

Local capture weakens speaker attribution. Granola's desktop behavior shows
this is an acceptable first tradeoff: the user still gets `me` versus
`system_audio` lanes, and provider adapters can improve speaker identity later.

Local capture increases platform-permission risk. TCC permissions, device
selection, audio routing, mute state, and background noise become first-class
product states. The UI and verification harness must expose these states instead
of pretending every call is a clean transcript feed.

## Updated Shape Recommendation

1. Build `LocalMacAudioSource` first.
2. Build a `TranscriptSource` trait that can also host Vexa/Recall/Graph later.
3. Add an audio-capture proof command before proposal work:
   `./scripts/verify-local-capture-smoke.sh`.
4. Add a deterministic real-transcriber proof command that generates a temporary
   known audio sample and asserts a final transcript:
   `./scripts/verify-real-transcriber-smoke.sh`.
5. Add transcript fixture replay for deterministic proposal tests:
   `./scripts/verify-local-transcript-fixture.sh`.
6. Replace `MockResearchWorker` in the approved path with a queued, read-only
   subprocess runner and `./scripts/verify-worker-runner.sh`.
7. Add a malicious-transcript worker safety check:
   `./scripts/verify-worker-sandbox.sh`.
8. Add browser state verification:
   `./scripts/verify-ui-states.sh`.
9. Add a gated live Teams dogfood smoke over the local capture path:
   `STANDBY_LIVE_CAPTURE=1 ./scripts/verify-live-teams-local.sh`.
10. Keep UI demo mode explicit; normal route must show real source state.

## Residual Risk

- macOS capture requires user-granted Microphone and Screen & System Audio
  Recording permissions. Without them, Standby can only be fixture-ready.
- System audio capture may include notification sounds or non-meeting audio. The
  first version should label confidence/source honestly and avoid overpromising
  speaker identity.
- Local transcription accuracy and latency are unproven. The first
  implementation may choose Apple Speech, a local Whisper-family binary, or a
  cloud transcription provider behind a `Transcriber` interface, but it must
  preserve the event schema.
- CLI worker adapters may hit auth prompts or model/account limits. The first
  worker must fail visibly with `agent_job.failed`, not hang the meeting UI.
- A local CLI agent with broad shell or MCP tools can follow malicious transcript
  text. The first worker profile is not accepted until negative sandbox tests
  prove repo mutation and external-send attempts are denied or impossible.
- Provider adapters are still useful, but adding one before the local capture
  proof risks reintroducing the per-app adapter trap.
