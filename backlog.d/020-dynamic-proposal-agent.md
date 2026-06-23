# Build the real, dynamic proposal agent (OpenRouter cascade + append-only card feed)

Priority: P0 · Status: in-progress · Estimate: L

Shaped: `docs/shape/dynamic-proposal-agent.html` (2026-06-23) — design locked, oracle executable, ready for `/deliver`. Pairs with `011` (the eval is its proof loop).

**Progress (2026-06-23):** Step 1 (real OpenRouter provider as default) delivered + live-verified on branch `deliver/020-openrouter-provider` (commit `c67c336`) — a real `deepseek/deepseek-v4-pro` card reflects the transcript with `provider=openrouter`; `./scripts/verify.sh` green. Pending review. Steps 2–3 (the append-only feed loop) remain: remove the open-proposal gate, debounced/changed-transcript trigger, dedup-by-omission, transcript-like UI feed.

## Goal
Proposal cards reflect what's actually being discussed and accumulate as the conversation shifts — new cards append and older ones push down like the transcript (never auto-removed) — produced by a real OpenRouter model by default (never a stub), with reliable structured output and honest failure.

## Oracle
- [ ] With `OPENROUTER_API_KEY` set and no provider override, a fresh meeting produces a card whose content reflects the real transcript (projection provider = `openrouter`, not `recorded-model`).
- [ ] A topic pivot in the `011` corpus APPENDS a new card tracking the pivot while the prior card stays in the feed (cards never auto-remove); a content-blind output fails the eval.
- [ ] A malformed/contractless model response → exactly one retry → honest `no_proposal("model_provider_error")`; never a keyword card.
- [ ] `./scripts/verify.sh` green; `verify-model-proposals.sh` heuristic-symbol grep green; old ledgers (only `proposal.created`) still project.
- [ ] Per-meeting model spend under a configured ceiling (debounce/sliding-window honored).

## Verification System
Proof loop = `011` eval (recorded **real** OpenRouter responses as the CI anchor — NOT a content-blind stub — plus a gated live run) + a live topic-pivot QA walk. Full claim/falsifier/driver/grader/evidence/cadence in the shape packet's Verification section.

## Notes
**Why:** The operator live-tested the proposal agent (2026-06-23) and it was a content-blind fixture that never changed — the exact "asserted, not measured" failure the groom flagged. Research this session killed the "go OpenAI Realtime" instinct (the cascade wins for a non-speaking listener: 5–30× cheaper, strict-JSON-capable, no 60-min cap) and selected OpenRouter models (reasoner `deepseek/deepseek-v4-pro` default or `z-ai/glm-5.2`; gate `deepseek/deepseek-v4-flash` for the Option-B fast-follow; AVOID `gemini-3.5-flash` via OpenRouter). Provider boundary = a direct `ProposalProvider::OpenRouter` arm, NOT via the OpenCode worker (cognition ≠ sandboxed execution).

Build **step 1 (real provider default) first** — the no-regret unblock so the operator can re-test on a real model immediately. Record an ADR ("cascade, not Realtime API") at deliver time. Supersedes the realtime framing in `013`'s notes.

**Hard constraint (user):** no stubs/placeholders/silent fallbacks; the real path is the default and must work the first time. `Recorded` becomes test/fixture-only.

**Critic (2026-06-23):** fresh-context review of the packet returned *fix-spec-then-deliver* with 3 blockers about the mutable add/update/retire ledger (stale dispatch, approved-card clobber, hallucinated ids). The operator's 2026-06-23 product correction — cards are an **append-only feed** (never mutate/retire; they push down like the transcript) — moots all three: no update, no retire, no card-id round-trip. Residual risk now: dedup-by-omission quality + removing the open-proposal gate without reintroducing per-segment spam (both measured by 011). Re-run a critic on the diff at deliver time.
