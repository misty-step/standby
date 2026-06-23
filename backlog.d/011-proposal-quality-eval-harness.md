# Build a held-out proposal-quality eval harness

Priority: P0 · Status: ready · Estimate: L

Shaped: `docs/shape/proposal-quality-eval.html` (context packet, 2026-06-22) — design locked, oracle executable, ready for `/deliver`.

## Goal
Replace "a card was produced" with a measured precision/recall/false-proposal-rate gate over a held-out, labeled transcript corpus, so the AI-first proposal bet is verified, not asserted.

## Oracle
- [ ] A labeled held-out corpus exists (≥30 meeting windows) tagged `{should_propose, expected kind, gold evidence ids}`, including paraphrased asks, negations, and chatter that should stay silent.
- [ ] A scorer reports precision, recall, F1, and false-proposal rate with a bootstrap confidence interval (not a single pass/fail), emitting a JSON report under `docs/evidence/`.
- [ ] A deliberately degraded proposal (wrong evidence / off-topic) drops the score below a published bar and fails the gate.
- [ ] The gate runs in CI against the recorded provider as a regression anchor and is runnable against the live model under `STANDBY_LIVE_MODEL=1`.

## Verification System
- Claim: Standby's model-native proposals are useful and low-noise — paraphrased asks produce grounded cards; vague/negated chatter does not.
- Falsifier: vague/negated windows produce cards, or genuine asks are missed, above the published bar; or the "eval" only checks card shape.
- Driver: new `crates/standby-core/tests/proposal_eval.rs` + `scripts/verify-proposal-eval.sh` replaying the labeled corpus through `ProposalAgent`.
- Grader: precision/recall/F1/false-proposal-rate vs a published bar, with a bootstrap CI that clears the measured judge noise floor.
- Evidence packet: `docs/evidence/ai-first-proposals/eval/`.
- Cadence: CI on every change (recorded anchor); gated live-model run before any proposal-quality claim.

## Children
1. Build the labeled held-out corpus under `crates/standby-core/tests/fixtures/eval/` (seed from `docs/evidence/real-meeting/`), incl. paraphrase / negation / false-positive-bait cases.
2. Add a scoring grader (`tests/proposal_eval.rs` + `scripts/verify-proposal-eval.sh`) emitting P/R/F1/false-rate with a bootstrap CI + JSON report.
3. Make the eval grade real judgments; keep the recorded provider only as the CI regression anchor.
4. Strengthen the boundary the harness exposes: semantic dedupe across a meeting (beyond the single-open-proposal gate) and an evidence-faithfulness check stronger than id-resolution.
5. Wire the gate into CI with a regression budget (fail on recall/false-rate regressions); run live under `STANDBY_LIVE_MODEL=1`.

## Notes
**Why:** Three independent swarm lanes (Proposal Quality, Tests & Verification, Premise Challenger) converged: there is NO proposal-quality measurement anywhere. The CI "recorded model" is a synthetic stub (`crates/standby-core/src/engine.rs:551-639`) that always emits a card when ≥2 segments exist; every proposal test asserts shape, not usefulness (`crates/standby-core/tests/fixture_replay.rs:60-101`; `scripts/verify-model-proposals.sh` checks fixture shape + absence of keyword symbols only). Backlog 007 named exactly this held-out eval as its success signal ("paraphrased asks produce grounded cards and vague/negated chatter does not", `backlog.d/007:15`) and was marked done without building it (admitted open in `docs/real-meeting-followups.md:80`). The keyword engine was deleted (`AGENTS.md:68`) on the strength of a bet that has never been measured — this de-risks the foundation the architecture rests on. CLAUDE.md: an eval inside its noise floor is not a result — hence the CI anchor + bootstrap CI.

The model boundary itself is a bright spot (strict JSON schema, confidence floor 0.55, evidence-citation rejection at `engine.rs:641-676`) — this ticket measures quality, it does not rebuild the boundary.
