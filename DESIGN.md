# Standby Design Contract

Standby is an in-call agent command surface, not a transcript viewer, dashboard,
or landing page. The locked default direction is Action Stream: suggested work,
running jobs, completed outputs, and no-card events in one readable feed, with a
compact Ask/source companion.

## Product Shape

- Agent suggestions and approved-work outputs are the primary product objects.
  Meeting-aware chat can carry those suggestions inline; it is not a separate
  dashboard panel unless the user opens it.
- The default route is the Action Stream. It presents proposals, jobs, results,
  and failures in one chronology-oriented column instead of separate dashboard
  regions.
- Running work, completed outputs, and source transcript are exposed through
  small count/status indicators, tabs, shelves, drawers, or focused detail views.
  They do not all need to be visible at once.
- Transcript is source material: available through a drawer, citation, or
  evidence inspector, but not the default center of the UI.
- Suggested actions are explicit review cards. Nothing runs until the user
  approves the deterministic proposal.
- Worker state is always visible as queue, run, done, failure, and receipt
  evidence.
- Audio state separates microphone and call/system lanes. A silent system lane
  is not presented as full capture failure when the mic is transcribing.

## Visual System

- Focused, operational layout with restrained color and 8px or smaller radii.
- Prefer one selected object plus subtle secondary indicators over overloaded
  dashboard grids or large metric cards.
- For the default route, use the PD02 Action Stream pattern: primary feed,
  compact Ask Standby panel, transcript/source drawer, and quiet count chips.
- Navigation must switch real app sections or be removed.
- Cards are for actionable proposal, job, chat response, result, and lane details
  only.
- Status language must be concrete: active, silent, failed, queued, running,
  completed, receipt.
- No decorative hero, marketing copy, fake controls, transcript-dominant default
  layouts, nested cards, dashboard-stat grids, or oversized display type inside
  tool panels.
