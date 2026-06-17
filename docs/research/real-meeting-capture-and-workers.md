# Research: Real Meeting Capture And Worker Dispatch

Date: 2026-06-17

## Synthesis

Standby can be made useful for real meetings, but not by treating Microsoft
Graph transcripts as a live feed. The shortest real Teams path is a meeting-bot
transcript adapter, with Vexa as the first adapter because it exposes Teams bot
creation plus WebSocket transcript updates. The long-term any-call path should
be a native macOS capture adapter using ScreenCaptureKit for app/system audio
and microphone samples, then a transcription engine behind the same transcript
event interface.

Approved work should dispatch through a durable local job runner, not inside the
approval request. The first unstubbed worker should be a read-only research
worker that launches an installed local CLI agent and records stdout, stderr,
exit status, duration, and artifact paths as normalized job events. Coding and
mutation-capable workers should follow only after permission enforcement exists.

## Source Matrix

| Source lane | Status | What it contributed | Key refs |
| --- | --- | --- | --- |
| Codebase | complete | Current Standby is demo-only: fixture transcript, `MockResearchWorker`, synchronous approval, no capture route. | `README.md`, `crates/standby-core/src/worker.rs`, `crates/standbyd/src/main.rs`, `ui/src/main.tsx`, `scripts/verify.sh` |
| Docs | complete | Teams real-time media exists but is specialized; Graph transcripts and AI insights are post-meeting. ScreenCaptureKit and Speech support local capture/transcription primitives. | Microsoft Learn, Apple Developer |
| Retrieval | complete | Vexa gives a concrete Teams/Meet/Zoom bot transcript API with WebSocket updates and self-host/cloud options. | Vexa docs |
| Agentic acquisition | failed | Firecrawl search returned HTTP 402, so it did not contribute evidence. | `firecrawl_search` |
| Extraction | complete | Fetched official Microsoft/Apple/Vexa pages for constraints and protocol details. | Parallel `web_fetch` excerpts |
| Recency / discourse | partial | Microsoft Q&A reinforces that non-.NET Teams live media access is not a simple Java/Node/Python RTMS equivalent. Treated as weaker than official docs. | Microsoft Q&A result |
| Synthesis | complete | Recommended Vexa-first plus local capture fallback, with worker dispatch separated from approval. | This memo |
| Repo-aware critique | complete | Sidecar critic found the one-slice "Teams + all workers" plan blocking; accepted its split-scope recommendation. | Subagent `019ed3aa-97e1-7103-8ad6-da64251d8572` |

## Evidence

### Teams Capture

Microsoft's official real-time media bot platform can give bots raw voice,
video, and screen-sharing streams, but Microsoft frames it for specialized
scenarios such as compliance recording, Cloud Video Interop, and contact center
integration. The same page explicitly recommends Copilot Studio agents or Graph
meeting transcripts for AI meeting-agent scenarios instead of raw media bots:
https://learn.microsoft.com/en-us/microsoftteams/platform/bots/calls-and-meetings/real-time-media-concepts

The Teams calls/meetings bot overview says Graph calling APIs can access
real-time audio/video streams, but application-hosted media bots require the
`Microsoft.Graph.Communications.Calls.Media` .NET library and a Windows Server
or Windows Server guest OS:
https://learn.microsoft.com/en-us/microsoftteams/platform/bots/calls-and-meetings/calls-meetings-bots-overview

Microsoft Graph transcript and recording APIs are not live. The transcripts
overview says apps fetch transcripts/recordings after the meeting or call ends:
https://learn.microsoft.com/en-us/microsoftteams/platform/graph-api/meeting-transcripts/overview-transcripts

Meeting AI Insights are also post-meeting. The limitations section says live
notes are not supported and insights may take up to four hours after the call:
https://learn.microsoft.com/en-us/microsoftteams/platform/graph-api/meeting-transcripts/meeting-insights

### Vexa As First Teams Adapter

Vexa's WebSocket docs describe a concrete bot-plus-transcript protocol:
`POST /bots`, `X-API-Key`, `platform: "teams"`, `native_meeting_id`, and a
Teams `passcode`; then `GET /transcripts/{platform}/{native_id}` for bootstrap
and `ws(s)://.../ws` for live updates:
https://docs.vexa.ai/websocket

Vexa's product pages describe one API across Google Meet, Microsoft Teams, and
Zoom, real-time transcripts with speaker diarization, hosted or self-hosted
deployment, and an MCP wrapper. Treat these as vendor claims, but the WebSocket
protocol is concrete enough for an adapter:
https://vexa.ai/use-cases/sales-call-transcription
https://vexa.ai/integrations/claude-mcp

### Any-App Mac Capture

Apple ScreenCaptureKit is the right native foundation for the eventual any-call
Mac adapter. Apple documents high-performance capture of screen and audio
content, with sample buffers delivered to the app:
https://developer.apple.com/documentation/screencapturekit

Apple's capture sample adds stream outputs for `.screen`, `.audio`, and
`.microphone`, then converts audio `CMSampleBuffer` values into
`AVAudioPCMBuffer`:
https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos

Apple's Speech framework can recognize live or prerecorded audio and provides
SpeechAnalyzer, SpeechTranscriber, and input sequence providers:
https://developer.apple.com/documentation/speech

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

Automation-relevant help output:

- `codex exec` supports non-interactive execution, `--json`, `--output-schema`,
  `--output-last-message`, `--sandbox`, `--ask-for-approval`, and `-C`.
- `claude -p` supports non-interactive output, JSON and stream-JSON output,
  JSON schema, tool allow/deny lists, and permission modes.
- `pi -p` supports non-interactive text/json/rpc modes and tool allow/deny
  lists.
- `opencode run` supports `--format json`.
- `goose run` supports stdin/file instructions, `--quiet`, `--no-session`,
  provider/model overrides, and max-turn limits.

## Conflicts

Microsoft's official guidance creates a tension: Teams has a supported
real-time media path, but Microsoft does not recommend raw media bots for AI
meeting-agent scenarios and the app-hosted media route is Windows/.NET-shaped.
That makes it the wrong first path for a local Rust/Mac product.

Vexa is vendor/product evidence rather than platform-owner evidence, but it has
a concrete API and matches the user outcome sooner. The design should isolate
Vexa behind `TranscriptSource` so Microsoft-native or local-capture adapters can
replace it without changing proposal or worker orchestration.

## Residual Risk

- Vexa Teams joining depends on meeting ID/passcode, bot acceptance, account
  limits, and consent expectations. A real meeting smoke must prove this.
- Local macOS capture needs user-granted TCC permissions and may face audio
  device edge cases. Do not promise speaker identity from the local adapter.
- CLI worker adapters may hit auth prompts or model/account limits. The first
  worker must fail visibly with `agent_job.failed`, not hang the meeting UI.
- Firecrawl search was unavailable due HTTP 402; Parallel search/fetch plus
  local command evidence supplied the research base.
