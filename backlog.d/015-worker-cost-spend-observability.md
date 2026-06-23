# Make worker API spend visible and bounded

Priority: P1 · Status: pending · Estimate: M

## Goal
An operator sees, in real time and cumulatively, what each approved card costs in tokens and dollars, and never spends unbounded money silently.

## Oracle
- [ ] Each completed job records `tokens_in`/`tokens_out` and `cost_usd` parsed from OpenCode's JSONL usage output (tolerating absence).
- [ ] Per-job and per-meeting cumulative spend project into `MeetingProjection` and survive event replay.
- [ ] The UI shows per-job cost and a session total alongside the lane meters, plus an aggregate queue-depth count.
- [ ] (Stretch) `JobBudget` carries an optional `max_cost_usd`; the approval gate warns over budget.

## Children
1. Parse OpenCode usage/cost from worker JSONL stdout in `read_opencode_text_summary` (currently discards it). `worker.rs:~507`.
2. Persist `tokens_in`/`tokens_out` + `cost_usd` on `AgentJobSpec` and emit on `agent_job.completed`/`failed`. `domain.rs:363`; `event_log.rs`.
3. Project cumulative meeting spend in the replay. `domain.rs:423`; `event_log.rs:245`.
4. Render per-job cost + session total + queue depth in the UI. `ui/src/main.tsx`; `main.rs:38,91`.
5. (Stretch) Add `max_cost_usd` to `JobBudget` + over-budget warning at approval. `domain.rs:339`.

## Notes
**Why:** Ops lane: worker API spend is completely invisible. OpenCode emits usage/cost in its JSONL; the parser discards it. `JobBudget` enforces only wall-clock minutes (`domain.rs:339`; `worker.rs:483`). API keys flow into the paid subprocess with the model pinned to `openrouter/z-ai/glm-5.2` (`worker.rs:52`). An operator approving cards during a live meeting spends real money with zero per-job or cumulative visibility. Distinct from done item 002 (which scoped job state/receipts, never cost). Reuses the existing event-sourcing + projection machinery; touches exactly the files already in the worker/spend path.
