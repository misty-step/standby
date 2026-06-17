# Premise: Standby Local Capture First

Created: 2026-06-17

Sanitized user request:

- Re-shape Standby after challenging the assumption that every meeting app
  needs its own adapter.
- Target Microsoft Teams first as the dogfood meeting app, but make the product
  work for any call the user takes on the Mac.
- Study the pattern used by tools such as Granola, Monologue Notes, and open
  source meeting-note alternatives.
- Prefer OS-level local capture of microphone plus system/app audio as the
  primary capture path.
- Keep meeting-bot, Teams, Zoom, Google Meet, or Graph integrations as optional
  provider adapters for metadata, diarization, enterprise workflows, or fallback
  capture, not as the product core.
- Approved proposal cards must still dispatch to real local worker agents; the
  implementation must not keep mock worker completions in the approved path.

Privacy note: this premise is a short written summary of the request. It does
not include raw meeting audio, private transcript excerpts, credentials,
calendar data, meeting URLs, or third-party account details.
