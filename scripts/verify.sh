#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Rust unit + integration tests (includes the transcript-fixture replay and the
# worker-sandbox containment negative test).
cargo test --workspace
bash ./scripts/verify-model-proposals.sh

# The native capture helper compiles, and transcription is real and unstubbed:
# a deterministic on-device Apple Speech proof. (Live mic/system capture and the
# browser UI-state checks are separate, permission/operator-gated smokes.)
bash ./scripts/build-capture-helper.sh

# TCC-persistence guard: the daemon-spawned helper must carry a STABLE signature,
# never ad-hoc. Ad-hoc cdhash changes every build, so macOS forgets the Microphone
# and System-Audio grants on each rebuild — the dogfood trap. Fail loudly here.
SHIPPED_HELPER="native/standby-capture-helper/build/standby-capture-helper"
LAUNCHSERVICES_APP="native/StandbyCapture.app"
for artifact in "$SHIPPED_HELPER" "$LAUNCHSERVICES_APP"; do
  if codesign -dvv "$artifact" 2>&1 | grep -q "Signature=adhoc"; then
    echo "verify: helper artifact $artifact is ad-hoc signed; TCC grants would" >&2
    echo "  evaporate on rebuild. Build with a stable identity (see build-capture-helper.sh)." >&2
    exit 1
  fi
  codesign -dvv "$artifact" 2>&1 \
    | grep -E "Authority=|TeamIdentifier=|Identifier=" \
    | while IFS= read -r line; do
        printf '  signing (%s): %s\n' "$artifact" "$line"
      done || true
done

bash ./scripts/verify-real-transcriber-smoke.sh

npm --prefix ui run build
cargo build -p standbyd

# New proposal-request public API: operator message + transcript context creates
# an evented proposal card, then approval runs the existing out-of-request worker
# path. This is API-only, so it belongs in the default gate; browser UI smokes
# remain separate. Write transient evidence so the default gate does not dirty
# tracked docs evidence.
VERIFY_EVIDENCE="$(mktemp -d -t standby-verify-evidence.XXXXXX)"
STANDBY_EVIDENCE_DIR="$VERIFY_EVIDENCE/manual-proposal" bash ./scripts/verify-manual-proposal-request.sh
STANDBY_EVIDENCE_DIR="$VERIFY_EVIDENCE/ai-execution-security" bash ./scripts/verify-ai-execution-security.sh
STANDBY_EVIDENCE_DIR="$VERIFY_EVIDENCE/opencode-worker" bash ./scripts/verify-opencode-worker.sh
STANDBY_EVIDENCE_DIR="$VERIFY_EVIDENCE/worker-recovery" bash ./scripts/verify-worker-recovery.sh

echo "standby verification passed"
