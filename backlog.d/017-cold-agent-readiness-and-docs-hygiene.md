# Make the repo cold-agent ready

Priority: P2 · Status: pending · Estimate: M

## Goal
A cold agent (or new human) can build, run, verify, extend, and debug Standby in one session from its own docs, skills, and gates — without the author's memory.

## Oracle
- [ ] A repo-local verification skill encodes the real routes: canonical gate `./scripts/verify.sh`, hosted subset `verify-ci.sh`, build prereq `build-capture-helper.sh`, daemon run + URL, and a labeled table of permission-gated smokes with `CAPTURE-BLOCKED` semantics.
- [ ] One "start here" architecture/onboarding doc exists (crate map, capture-helper JSONL boundary, `TranscriptSource`/`ProposalAgent` seams) + an index over `docs/`.
- [ ] `docs/evidence/real-meeting/EVIDENCE.md` no longer references the deleted `STANDBY_ALLOW_NETWORK_WORKER`; superseded OMP/fallback artifacts are removed or moved to `superseded/`; an evidence INDEX maps artifacts → backlog item → producing script.
- [ ] `.pi/` is gitignored and documented; `.standby/` is documented as the local ledger + job scratch.
- [ ] `verify-ci.sh` / the README verification table mark which legs are fixture-only in CI vs live-gated, so green never overclaims.

## Notes
**Why:** Docs lane: no repo-local verification/QA skill exists (no `.claude/`, no `CLAUDE.md`) — a cold agent must infer which of 25 verify scripts to run and in what order; the canonical `./scripts/verify.sh` is encoded only as Bash + a README table. `EVIDENCE.md:78-80` still asserts the network-worker opt-in the code deleted (contradicts `AGENTS.md:44-53` and ADR `0002`, which itself says the OMP proofs "must be replaced"). Knowledge is scattered across 4 premises + 11 shape HTML docs + 4 research docs + 2 ADRs + 4 context packets with no index or architecture spine. `.pi/` is an un-gitignored, undocumented orphan (accidental-commit risk). Tests lane adds: CI runs the reduced `verify-ci.sh` (drops real-transcriber + capture + security smokes) and the green badge reads the same as a full run — publish the uncovered-surface list. Root product prose (AGENTS/README, model pin, ports, routes) is fresh and verified — the staleness is in evidence + EVIDENCE.md. Overlaps the evidence-hygiene sub-item in 012.
