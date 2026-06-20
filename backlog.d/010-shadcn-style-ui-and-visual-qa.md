# Shadcn-style UI polish and visual QA

Priority: P1 · Status: pending · Estimate: L

## Goal

Make Standby's local meeting command surface visually clear, dense enough for
live use, and consistent enough to extend, using shadcn-style component
composition and semantic design tokens where they fit the current Vite app.

## PRD Summary

- User: meeting operator watching live transcript, proposal cards, and OpenCode
  job status during a call.
- Problem: the UI works, but the hierarchy, spacing, controls, audio status,
  transcript flow, and job/proposal state treatment still feel ad hoc.
- Goal: turn the current React surface into a coherent operational interface
  with stable visual primitives and visual regression evidence.
- Why now: the functional backlog is close enough that UX debt becomes the next
  blocker to trustworthy dogfood.
- UX enabled: transcript and current action state are visible without fighting
  scroll; proposal/job status is scannable; audio/capture state is legible;
  navigation either works or disappears.

## Product Requirements

- P0: transcript, active proposals, running jobs, and latest artifact/failure
  are visible in the first working viewport on desktop.
- P0: navigation controls either route to meaningful panels or are removed.
- P0: audio/capture controls show exact state and failure reason without
  ambiguous "live" copy.
- P0: proposal approval and OpenCode job status use clear visual hierarchy and
  receipt links.
- P0: desktop and mobile layouts avoid text overlap, nested cards, and
  scroll traps.
- P1: use actual shadcn/Tailwind components if setup cost is justified by the
  repo; otherwise use shadcn-style semantic primitives without unnecessary
  dependency churn.

## Oracle

- [ ] A browser QA script or Playwright walk captures desktop and mobile
  screenshots for idle, demo/proposal, running job, completed artifact, and
  failure states.
- [ ] Console/network checks are clean during the scripted walk.
- [ ] The UI build passes and `scripts/verify-ui-states.sh` remains green or is
  replaced by a stronger visual verifier.
- [ ] A fresh visual/UX critic finds no blocking hierarchy, layout, or workflow
  issue.
- [ ] `./scripts/verify.sh` passes after the UI changes.

## Verification System

- Claim: Standby's interface is usable during a real meeting and visually
  coherent across the main state set.
- Falsifier: important state is offscreen or ambiguous, controls do nothing,
  text overlaps, visual hierarchy hides the current job/proposal, or screenshots
  show regressions on desktop/mobile.
- Driver: local daemon plus seeded state replay and browser screenshots.
- Grader: DOM/state assertions, screenshot review, console/network error scan,
  and fresh visual critic.
- Evidence packet: `docs/evidence/ui-visual-qa/`.
- Cadence: run after major UI layout changes, then before merge.

## Implementation Notes

1. Run `shadcn info` and official docs before choosing the dependency path.
2. Compare three alternatives before coding:
   - actual shadcn/Tailwind initialization,
   - small local semantic component layer inspired by shadcn,
   - minimal CSS-only cleanup.
3. Prefer fewer, deeper UI primitives over many one-off class blocks.
4. Keep the app surface operational, not marketing-like.
5. Add or strengthen visual QA before broad UI rewrite work.
