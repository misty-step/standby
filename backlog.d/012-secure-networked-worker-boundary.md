# Make the worker boundary safe on the real networked profile

Priority: P0 · Status: pending · Estimate: L

## Goal
A worker that has fully obeyed adversarial transcript text cannot exfiltrate the transcript or operator data, spend beyond budget, or read outside its scratch — proven by a gate that runs the production `network=true` profile.

## Oracle
- [ ] Networked workers reach only an allowlisted model-API host; egress to any other host fails (proven with `allow_network=true`, not just the `network=false` fixture).
- [ ] Worker filesystem read is default-deny + explicit allowlist (scratch + toolchain), not allow-all-minus-blocklist.
- [ ] The dispatched prompt is bound to what the operator approved (content-hashed at approval, verified at dispatch); a changed `draft_prompt` is rejected.
- [ ] Redaction is detector-grade (JWT, all `sk-*`/`pk_*` families, PEM-with-spaces, cloud secret keys) + PII, applied before the model AND before any evidence file is written.
- [ ] The acceptance gate greps the produced artifact/receipt/stdout for injected secrets and fails if present.

## Verification System
- Claim: a fully-malicious worker on the shipping (networked) profile cannot leak the transcript or operator files or escape budget.
- Falsifier: an exfil attempt to a non-allowlisted host succeeds; a file outside scratch is read; a secret reaches the model, the ledger, or an evidence file.
- Driver: extend `tests/worker_sandbox.rs` + `scripts/verify-worker-sandbox.sh` to `allow_network=true` with an exfil probe; extend `verify-ai-execution-security.sh` with an output-side secret grep.
- Grader: exfil blocked + transcript bytes never leave + injected secrets absent from all outputs.
- Evidence packet: `docs/evidence/ai-execution-security/networked-profile/`.
- Cadence: every change to `worker.rs` sandbox/redaction/dispatch.

## Children
1. Egress allowlist for networked workers (per-job network namespace or local model-API CONNECT proxy; default-deny other hosts). `worker.rs:177-230`, `ok-sandbox.sb:29`, `real-meeting-followups.md:13-15`.
2. Flip the sandbox to read-allowlist: `(deny file-read*)` default + explicit allows; delete the brittle secret-dir blocklist. `worker.rs:217`.
3. Strengthen the acceptance gate to the real profile: run the sandbox negative test with `allow_network=true` + exfil probe; add an output-side secret assertion. `tests/worker_sandbox.rs:125`, `scripts/verify-ai-execution-security.sh:136-176`.
4. Detector-grade redaction applied on write (event log, dispatched prompt, every evidence artifact) + PII scrubbing. `worker.rs:278-300`.
5. Approval-bound prompt + evidence/instruction separation: content-hash the approved prompt, reject dispatch if `draft_prompt` changed, structurally fence transcript as data. `worker.rs:100,107,373-400`; `engine.rs:625-631`.
6. Per-meeting + per-identity authz: thread `meeting_id` through approve/ignore, scope `find_latest_proposal`, replace the single long-lived process token with a session-bound expiring token, stop hardcoding `approved_by`. `event_log.rs:328-347`; `main.rs:51-69,131-188,432-478`; `worker.rs:111`.

## Notes
**Why:** Security lane found the production worker profile runs `(allow network*)` + `(allow file-read*)` minus a hand-maintained blocklist that omits `~/Documents`, browser profiles, other repos, and most credential stores (`worker.rs:177-230`; `docs/evidence/opencode-default-worker/ok-sandbox.sb`). The sandbox negative test only proves containment with `network=false` (`tests/worker_sandbox.rs:125`), so the accepted real configuration's egress is unproven. Confused-deputy by construction: the transcript-derived `draft_prompt` is the silent default at approval (`worker.rs:100`; `engine.rs:625-631`). Redaction is prefix/whitespace-only and misses JWTs, most key families, and PEM-with-spaces (`worker.rs:278-300`). Authz is one process-wide token + hardcoded `"Phaedrus"` actor + a global `find_latest_proposal` (`event_log.rs:328-347`).

NOT a current leak: the security lane grepped all ~186 checked-in `docs/evidence/` files and found NO live secrets or operator tokens (only env-var names and 401 bodies); transcripts are scripted test phrases. The P0 is the *boundary* — the path by which a REAL confidential transcript would leak once captured.

Hygiene sub-item (P2): purge superseded OMP/fallback evidence that implies deleted behavior (`docs/evidence/operator-action-control/model-worker-boundary/omp-*`, `fallback-*`; `.../artifact.md:9` references `STANDBY_WORKER_PROFILE`). Tracked also in 017.
