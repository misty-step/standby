# Collapse the post-OMP dead surface (deletion proposals)

Priority: P2 · Status: pending · Estimate: M

## Goal
Make the `standby-core` interface honestly reflect the deliberately-narrowed product (one harness, one worker kind, event-sourced state with no orphan cache), so neither a contributor nor a model can read affordances the product forbids.

## Oracle
- [ ] No symbol in `src/` is defined-but-never-produced (network-consent cluster, dead job states).
- [ ] Every `WorkerKind` variant has a live producer, or the enum is documented as aspirational in exactly one place.
- [ ] No SQL table or struct field exists without a live read/write (`projections` table, `meeting_state_snapshot_id`).
- [ ] `domain` re-exports are explicit (no `pub use *`) so the compiler flags the next orphan.
- [ ] `./scripts/verify.sh` stays green (worker-sandbox negative + opencode boundary unaffected).

## Children (all deletions are PROPOSALS for human ratification)
1. Delete the orphaned network-consent seam: `NetworkWorkerConsent` (`domain.rs:394-400`), `JOB_NETWORK_CONSENT_GRANTED` (`domain.rs:482`), `EventStore::has_network_worker_consent` (`event_log.rs:269-280`) — zero producers, zero callers.
2. Collapse the job lifecycle to reachable states: delete `JobStatus::NeedsInput` + `JobFailureReason::ConsentRequired` (zero producers, incl. tests) and their UI arms; decide `Canceled` (only a test produces it) — delete now, re-add with a real cancel route (see 019). `domain.rs:60,154`; `event_log.rs:235`; `main.tsx:21,168,1176,1189`.
3. Delete the orphan `projections` table (`event_log.rs:362-367`) and `meeting_state_snapshot_id` (`domain.rs:350`), or file a scoped snapshot-cache ticket; default delete. *(Note: 019 may instead claim the `projections` table as the projection-cache seam — coordinate before deleting.)*
4. Narrow `WorkerKind` to what is built (only `ResearchAgent` is constructed; `profile` always `"opencode"`). `domain.rs:31-37`.
5. Replace `pub use domain::*` glob re-exports with explicit re-exports so dead `pub` items surface as warnings. `lib.rs:8-13`.
6. Worker tidy: remove the second redundant `redact_prompt` (`worker.rs:374`, already redacted upstream); flatten `allow_network` (always true in prod) keeping the test seam.
7. (Separable, later) Split `AgentJobSpec` into `JobSpec`/`JobRun`/`JobOutcome` (`domain.rs:364-392`) and extract a `WorkerSupervisor` from `main.rs` (queue + recovery + `ps`/`kill` reaping, `main.rs:518-720`).

## Notes
**Why:** Architecture + Simplification lanes converged precisely on the same dead surface — the 004→009 OMP deletion was done well but left a measurable tail. The all-`pub` glob (`lib.rs:8-13`) hides it from the compiler (`cargo check` is clean while ~3 symbols are dead). Children 1-6 are mechanical, evidence-backed, behavior-preserving and can ship as one PR behind the existing gate (~60-90 LOC removed across Rust + UI); child 7 is a real refactor with test impact — separate. The core seams (`ProposalAgent`, `TranscriptSource`, event-sourced projection) are genuinely healthy deep modules — this is tidy, not a redesign. The monoliths (`main.tsx` 1302, `main.swift` 1123, `styles.css` 1063) were assessed and judged cohesive — explicitly NOT split here. The "157 unwrap/expect" cleanup is also explicitly NOT here — it was a grep artifact; production error handling is already clean.
