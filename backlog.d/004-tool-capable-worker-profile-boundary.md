# Gate a tool-capable OMP worker profile behind executable safety

Priority: P1 · Status: implemented · Estimate: L

## Goal
Add an opt-in model/tool worker profile only after network egress, secret reads, scratch writes, and allowed tool surfaces are executable and testable.

## Oracle
- [x] A profile such as `omp-research` is ignored unless `STANDBY_ALLOW_NETWORK_WORKER=1`.
- [x] The sandbox negative test proves the profile cannot mutate the repo, read common secret stores, write outside scratch, send external messages, or call unapproved tools.
- [x] Auth failures return `agent_job.failed` with a receipt.

## Verification System
- Claim: a real model worker can use approved tools without becoming an exfiltration or mutation path.
- Falsifier: the worker can read secrets, write outside scratch, use unapproved MCP tools, or silently fail.
- Driver: opt-in worker smoke, extended sandbox negative test, route replay from approved proposal to terminal job.
- Grader: denial attempts fail at the OS/tool boundary and are recorded as worker failure receipts.
- Evidence packet: `docs/evidence/operator-action-control/model-worker-boundary/`.
- Cadence: run only after the profile exists; never part of the default gate until accepted.

## Notes
Implemented after `backlog.d/008-secure-approval-and-ai-execution-gate.md` landed. Do not make this the default worker. `local-research` remains the default; `omp-research` requires `STANDBY_ALLOW_NETWORK_WORKER=1`, per-job network consent, an isolated worker home, prompt redaction, and a fixed OMP tool allowlist.

Why: the AI-first proposal path increases the pressure to use real workers, but network/tool workers are an exfiltration and mutation risk until the approval and worker execution gate is hardened.

## Implementation Receipt

- Added `WorkerProfile::omp_research()` with default `openrouter/z-ai/glm-5.2`, overrideable by `STANDBY_OMP_MODEL`.
- Added profile policy metadata: isolated home, static worker env, auth env keys, and allowed tools.
- OMP runs with `--no-session`, `--no-skills`, `--no-rules`, `--no-extensions`, `--no-lsp`, `--no-pty`, `--tools read,grep,find,web_search`, and a scratch cwd.
- Network/model workers write `worker-profile.json`, redacted `prompt.txt`, stdout/stderr, and sandbox receipts under job scratch.
- `scripts/verify-model-worker-boundary.sh` proves fallback without global opt-in, OMP auth failure with receipt after per-job consent, manifest policy, prompt redaction, and the extended sandbox secret-store denial.
