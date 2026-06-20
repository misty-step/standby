# Preserve distinct remote speaker attribution

Priority: P1 · Status: done · Estimate: M

## Goal
Ensure Standby preserves and renders multiple remote speaker tokens when a transcript source provides them, instead of collapsing all call audio into `system_audio`.

## Oracle
- [ ] `scripts/verify-speaker-distinction-fixture.sh` replays a multi-speaker fixture and fails if all remote speakers collapse to `system_audio`.
- [ ] UI renders stable labels such as `Speaker 1` and `Speaker 2` for generic remote speaker keys.
- [ ] Proposal evidence retains the speaker key that produced each cited span.

## Verification System
- Claim: speaker distinction is materially better whenever the source provides stable speaker tokens.
- Falsifier: `remote_1` and `remote_2` become one label, evidence loses speaker identity, or UI shows every remote row as `Call audio`.
- Driver: helper-event fixture replay plus seeded UI DOM check.
- Grader: projection JSON and rendered DOM contain distinct speaker labels.
- Evidence packet: `docs/evidence/operator-action-control/speaker-distinction.*`.
- Cadence: fixture script after speaker changes; full gate before closeout.

## Notes
This is not true acoustic diarization. Local live capture still only emits `me` and `system_audio` until the helper has a diarization or provider-attribution source.

Delivered in this branch for transcript sources that provide stable speaker tokens. `scripts/verify-speaker-distinction-fixture.sh` proves projection and UI rendering for `remote_1` / `remote_2`.
