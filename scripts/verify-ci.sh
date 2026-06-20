#!/usr/bin/env bash
# Hosted-CI gate for deterministic Standby behavior. The full local gate remains
# scripts/verify.sh because native live capture depends on the host macOS SDK,
# signing identity, and TCC permissions. This CI gate keeps core proposal,
# worker, speaker-attribution fixture, API, and UI behavior covered.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Darwin" ]; then
  echo "verify-ci: Standby's worker sandbox gate requires macOS sandbox-exec" >&2
  exit 2
fi

cargo fmt --all -- --check
cargo test --workspace
bash ./scripts/verify-model-proposals.sh

npm --prefix ui ci
npm --prefix ui run build

cargo build -p standbyd

bash -n scripts/*.sh scripts/fixtures/*.sh
bash ./scripts/verify-worker-runner.sh
CI_EVIDENCE="$(mktemp -d -t standby-ci-opencode.XXXXXX)"
STANDBY_EVIDENCE_DIR="$CI_EVIDENCE/opencode-worker" bash ./scripts/verify-opencode-worker.sh
CI_EVIDENCE="$(mktemp -d -t standby-ci-evidence.XXXXXX)"
STANDBY_EVIDENCE_DIR="$CI_EVIDENCE/manual-proposal" bash ./scripts/verify-manual-proposal-request.sh
STANDBY_EVIDENCE_DIR="$CI_EVIDENCE/speaker-distinction" bash ./scripts/verify-speaker-distinction-fixture.sh

git diff --check
if [ "${CI:-}" = "true" ]; then
  git diff --exit-code
fi

echo "standby hosted-CI gate passed"
