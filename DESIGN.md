# Standby Design Contract

Standby is an in-call command surface, not a dashboard or landing page. The first
screen must answer three questions without scrolling: is capture working, what
was just said, and is any approved agent work running.

## Product Shape

- Transcript is the primary surface and renders newest-first so live capture
  stays visible during long calls.
- Suggested actions are explicit review cards. Nothing runs until the user
  approves the deterministic proposal.
- Worker state is always visible as queue, run, done, failure, and receipt
  evidence.
- Audio state separates microphone and call/system lanes. A silent system lane
  is not presented as full capture failure when the mic is transcribing.

## Visual System

- Dense, operational layout with restrained color and 8px or smaller radii.
- Navigation must switch real app sections or be removed.
- Cards are for actionable proposal/job/result objects and lane details only.
- Status language must be concrete: active, silent, failed, queued, running,
  completed, receipt.
- No decorative hero, marketing copy, fake controls, nested cards, or oversized
  display type inside tool panels.
