#!/usr/bin/env bash
# Deterministic proposal-agent quality gate. This proves proposal cards come
# from the model-response path (recorded fixtures in CI), not keyword cue lists.
set -euo pipefail

cd "$(dirname "$0")/.."

cargo test -p standby-core engine::tests

node - <<'NODE'
const fs = require("fs");
for (const file of [
  "crates/standby-core/tests/fixtures/model_proposal_positive.json",
  "crates/standby-core/tests/fixtures/model_proposal_no_card.json",
]) {
  const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!parsed.provider || !parsed.model || !Array.isArray(parsed.proposals)) {
    console.error(`invalid model fixture shape: ${file}`);
    process.exit(2);
  }
}
NODE

if rg -n "RESEARCH_CUES|EXPLICIT_REQUEST_FRAMES|NEGATED_REQUEST_FRAMES|detect_research_proposal|ProposalEngine" crates/standby-core/src crates/standbyd/src; then
  echo "verify-model-proposals: heuristic proposal engine symbols must not return to source" >&2
  exit 3
fi

echo "model proposal gate passed"
