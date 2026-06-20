# Groom Report: AI-First Standby Backlog

Date: 2026-06-20

## Tidy Diff

- `001`, `002`, and `003` are marked done in the branch but are still untracked
  local backlog files, so they were not archived.
- Harness Kit backlog tidy helper was attempted from the Standby checkout via
  `cargo run --manifest-path /Users/phaedrus/Development/harness-kit/Cargo.toml --locked -p harness-kit-checks -- backlog ids-from-range origin/main..HEAD`; it returned no archiveable IDs.
- No deletions or silent merges were applied.

## Source Matrix

| Surface | Status | Evidence | Contribution |
| --- | --- | --- | --- |
| Product/value | complete | `docs/vision.md`, operator prompt, `docs/premises/2026-06-20-ai-first-standby.md` | Reframed Standby as AI-first meeting command surface, not keyword proposal demo. |
| Architecture | complete | `crates/standby-core/src/engine.rs`, `proposal_request.rs`, architecture lane | Root cause is missing `ProposalAgent` boundary. |
| Verification | complete | `scripts/verify*.sh`, verification lane | Added proposal-quality gate as first child of P0 epic. |
| Security/privacy | complete | `crates/standbyd/src/main.rs`, `worker.rs`, security lane | Added P0 secure approval/AI execution gate before default OpenCode workers. |
| Speech/diarization | partial | `docs/research/speaker-diarization-options.md`, `docs/research/realtime-voice-model-substrates.md` | Kept diarization as separate adapter epic; updated provider facts. |
| Agent readiness | complete | `AGENTS.md`, Harness Kit shared primitive edits | Repo and shared harness now forbid heuristic-primary model-native product brains. |
| Runtime reliability | partial | `backlog.d/006-recover-worker-queue-after-daemon-restart.md` | Existing recovery ticket remains after worker visibility work. |
| External exemplars | partial | OpenAI, Gemini, Deepgram, ElevenLabs primary docs | Enough to shape first model-native slice; provider bake-off still needed in implementation. |

## World-Class Plan

Standby should feel like a local-first meeting operations console with a real
agent brain: it listens, understands context, asks for approval before acting,
dispatches bounded work, and leaves receipts. The near-term sequence is:

1. Continue hardening the model-native `ProposalAgent` now that the heuristic
   engine has been removed from source.
2. Harden the approval and AI execution control plane before default network or
   tool workers exist.
3. Add true diarization/provider attribution through a normalized adapter.
4. Recover queued jobs after daemon restart.
5. Replace the superseded worker-profile path with the single default OpenCode
   subagent worker.
6. Add tighter egress scoping after the default OpenCode path has executable
   filesystem/env/workspace/receipt proof.

## Emissions

- Added and implemented `backlog.d/007-ai-first-proposal-agent.md`.
  **Why:** live repo read plus architecture and verification lanes proved the
  old primary proposal path was cue-list driven; the source now uses a typed
  proposal-agent boundary with recorded fixtures and an opt-in OpenAI provider.
- Added `backlog.d/008-secure-approval-and-ai-execution-gate.md`.
  **Why:** security lane found unauthenticated mutation routes, spoofable
  approval identity, and global network-worker enablement risk.
- Superseded `backlog.d/004-tool-capable-worker-profile-boundary.md` and added
  `backlog.d/009-default-opencode-subagent-worker.md`.
  **Why:** the product direction is OpenCode by default, not opt-in OMP/local
  worker profiles.
- Updated `backlog.d/005-live-speaker-diarization-or-provider-attribution.md`.
  **Why:** diarization remains real product work, but OpenAI diarization is a
  buffered transcription side-channel, not Realtime.

## Best Next Pickup

Pick up `009-default-opencode-subagent-worker.md` next. Do not extend the
superseded OMP/local profile path, and do not reintroduce keyword cue lists as
the proposal brain.

## Residual Risk

- The live OpenAI provider path passed its opt-in smoke and left a redacted
  receipt at `docs/evidence/ai-first-proposals/live-model/redacted-pass.json`.
- Current branch has substantial pre-existing dirty/untracked work from the
  ongoing Standby slice; this groom did not attempt to clean or archive it.
- Full strategic swarm was narrowed to four read-only lanes because the user
  requested immediate synthesis/execution, not a day-long exhaustive offsite.
