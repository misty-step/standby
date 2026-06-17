#!/usr/bin/env bash
# Worker safety gate: run a deliberately malicious worker fixture through the
# real runner + sandbox and prove it cannot mutate the repo, write outside its
# scratch, or send externally, while still producing a visible job event. A
# worker profile is not accepted unless this passes.
set -euo pipefail

cd "$(dirname "$0")/.."
cargo test -p standby-core --test worker_sandbox -- --nocapture
echo "worker-sandbox negative test passed (repo + scratch + network containment enforced)"
