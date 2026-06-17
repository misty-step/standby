#!/usr/bin/env bash
# Deterministic, permission-free proof of the transcript pipeline: replay a
# local-capture-shaped JSONL fixture through the same normalization the live
# daemon uses and assert partial/final ordering, dedupe, evidence-cited proposal
# detection, and projection stability.
set -euo pipefail

cd "$(dirname "$0")/.."
cargo test -p standby-core --test fixture_replay -- --nocapture
echo "local-transcript-fixture replay passed"
