# Google Meet local QA - 2026-06-19

## Verdict

Pass for local Google Meet smoke.

Standby ran beside an active Google Meet call in Chrome. Chrome held camera and
microphone during the run. Standby started `mic+system` capture, recorded both
microphone and system-audio lanes, transcribed final segments, generated a
research proposal, approved it, ran the default `local-research` worker, and
rendered the completed result card in the UI.

## Evidence

- `google-meet-second-summary.json`: capture/proposal summary.
- `google-meet-projection-second.json`: full projection after the proposal was
  created.
- `google-meet-worker-summary.json`: approved proposal, completed job, and
  artifact summary.
- `google-meet-projection-approved.json`: full projection after worker
  completion.
- `google-meet-standby-visible.png`: visible UI state showing stopped capture,
  transcript, completed worker, and result card.
- `jobs/job_18ba92c995a137a8_e63c_122/artifact.md`: deterministic local worker
  artifact.

## Notes

- The first capture began speaking too soon after start, so Apple Speech missed
  the initial "research" words and no proposal was expected.
- The second capture added a startup delay and produced the proposal.
- This was a one-person disposable Meet with system audio played locally while
  Meet held Chrome mic/camera. It proves the local Meet coexistence path, not
  a two-party remote-speaker call.
- The disposable Meet tab was closed after the smoke. No Standby daemon/helper
  process was left running.
