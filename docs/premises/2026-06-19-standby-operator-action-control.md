# Premise: Operator-Controlled Proposals And Speaker Distinction

Created: 2026-06-19T20:12:59Z

## Source Summary

- Live Standby dogfood is running against a Teams meeting at
  `http://127.0.0.1:4317/?meeting=teams-live`.
- Operator confirmed transcript is coming in during the live Teams call.
- Operator asked for an easier way to force or prompt action proposals when the
  agent should be doing work.
- Operator proposed an "Ask Standby" flow: send a message, combine that message
  with current call transcript context, generate task proposal cards, approve
  selected cards, then run worker jobs and report back.
- Operator also identified speaker-distinction as a needed ticket: there are
  many remote participants, but Standby currently labels the system lane as
  undifferentiated `call audio` / `system_audio`.

## Non-Text Live Evidence

At capture time, the live projection for `teams-live` reported:

- `source.status`: `transcribing`
- `transcript_count`: `43`
- `partial`: `true`
- unique transcript speaker labels: `["system_audio"]`

This evidence intentionally omits raw transcript text and raw audio paths.

## Residual Risk

- The operator's "dozen people" count is accepted as live observation, not
  independently verified from attendee roster data.
- Transcript accuracy and speaker identity remain unverified.
- Superseded `local-research`/OMP product profile code has been replaced by the
  default OpenCode subagent worker direction in
  `docs/decisions/0002-opencode-default-subagent-worker.md`.
