# Ship standbyd as a signed app with a first-run grant flow

Priority: P2 · Status: pending · Estimate: L

## Goal
A non-developer operator can install, update, and grant permissions to Standby like a real Mac app, instead of running cargo from a terminal.

## Oracle
- [ ] `standbyd` ships as a signed, notarized, stapled `.app` (built + notarized in CI on tag).
- [ ] A first-run in-app flow requests Microphone + Screen & System-Audio Recording (reusing the helper's proven stable-signing TCC-persistence pattern).
- [ ] An update mechanism exists (e.g. Sparkle-style check), not `git pull` + rebuild.

## Notes
**Why:** Ops lane: there is zero release/packaging/delivery infra. Only the capture helper is signed (by a local dev script, never in CI); the daemon is launched bare (`cargo run -p standbyd`, `README:56`) and "updated" by `git pull` + rebuild. The signed-`.app` + in-app grant-flow gap is the explicit followup at `docs/real-meeting-followups.md:46-48` and blocks any non-developer operator. CI (`.github/workflows/verify.yml`) runs a solid gate but has no `.app` build, codesign/notarize, version bump, or artifact upload. Larger and notarization-heavy — sequence after the P0/P1 product and safety work.
