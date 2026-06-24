#!/usr/bin/env bash
# Opt-in live proof for the append-only proposal feed (backlog 020 steps 2-3):
# seed a topic-pivoting transcript and prove the real model APPENDS a second,
# distinct card as the conversation shifts — cards accumulate, they do not
# freeze on one suggestion. Gated: set STANDBY_LIVE_MODEL=1 and
# OPENROUTER_API_KEY to spend model calls.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${STANDBY_LIVE_MODEL:-}" != "1" ]; then
  echo "verify-live-append-feed: skipped (set STANDBY_LIVE_MODEL=1)"
  exit 0
fi

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "verify-live-append-feed: OPENROUTER_API_KEY is required when STANDBY_LIVE_MODEL=1" >&2
  exit 2
fi

EVIDENCE="${STANDBY_EVIDENCE_DIR:-docs/evidence/ai-first-proposals/append-feed}"
mkdir -p "$EVIDENCE"
export EVIDENCE

cargo build -p standbyd >/dev/null

DB="$(mktemp -t standby-append-feed.XXXXXX).db"
JOBS="$(mktemp -d -t standby-append-feed-jobs.XXXXXX)"
ADDR="127.0.0.1:4329"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS"
export STANDBY_ENABLE_SEED=1
export STANDBY_PROPOSAL_PROVIDER="${STANDBY_PROPOSAL_PROVIDER:-openrouter}"
export STANDBY_OPENROUTER_PROPOSAL_MODEL="${STANDBY_OPENROUTER_PROPOSAL_MODEL:-deepseek/deepseek-v4-pro}"
# Fire the reasoner often so the pivot surfaces over the seeded segments.
export STANDBY_PROPOSAL_DEBOUNCE_SEGMENTS="${STANDBY_PROPOSAL_DEBOUNCE_SEGMENTS:-2}"
export STANDBY_OPERATOR_TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-verify-token}"

cargo run -p standbyd >/tmp/standby-append-feed.log 2>&1 &
PID=$!
cleanup() {
  kill "$PID" 2>/dev/null || true
  rm -f "$DB" "$DB"-wal "$DB"-shm
  rm -rf "$JOBS"
}
trap cleanup EXIT

READY=0
for _ in $(seq 1 80); do
  if curl -fsS "http://$ADDR/health" >/dev/null 2>&1; then READY=1; break; fi
  kill -0 "$PID" 2>/dev/null || { cat /tmp/standby-append-feed.log; exit 1; }
  sleep 0.25
done
[ "$READY" = 1 ] || { echo "daemon never became ready"; cat /tmp/standby-append-feed.log; exit 1; }

# A two-topic conversation: budget / action-items first, then a hard pivot to
# competitive market research. The automatic debounced reasoner fires as
# segments finalize; with the open-proposal gate removed, the pivot APPENDS a
# second distinct card instead of being suppressed by the first.
SEED="$(node -e 'process.stdout.write(JSON.stringify({events:process.argv.slice(1)}))' \
  '{"type":"source.started","mode":"mic+system","mic":true,"system":true}' \
  '{"type":"segment.final","lane":"system_audio","speaker":"remote_1","text":"The big open item from last week is the Q3 budget. We still owe finance the revised headcount numbers."}' \
  '{"type":"segment.final","lane":"system_audio","speaker":"remote_1","text":"Someone needs to pull the updated headcount and send finance the revised Q3 budget by Friday."}' \
  '{"type":"segment.final","lane":"system_audio","speaker":"remote_2","text":"Switching gears completely. I keep wondering how our pricing compares to Acme in the European market."}' \
  '{"type":"segment.final","lane":"system_audio","speaker":"remote_2","text":"Can someone run a competitive analysis of Acme pricing tiers across Europe to help our positioning?"}')"

curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -H 'content-type: application/json' \
  -d "$SEED" \
  -X POST "http://$ADDR/api/meetings/append-feed/seed" >"$EVIDENCE/seed-projection.json"

curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" \
  "http://$ADDR/api/meetings/append-feed" >"$EVIDENCE/projection.json"

node - <<'NODE'
const fs = require("fs");
const p = JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/projection.json`, "utf8"));
const cards = (p.proposals || []).filter((c) => c.status === "proposed");
const fail = (code, msg, extra) => {
  console.error(`FAIL: ${msg}`);
  if (extra) console.error(JSON.stringify(extra, null, 2));
  process.exit(code);
};

// Primary proof: the feed ACCUMULATED. Pre-fix, the open-proposal gate capped
// this at one frozen card.
if (cards.length < 2) {
  fail(3, `append feed did not accumulate; expected >=2 cards, got ${cards.length}`, {
    titles: cards.map((c) => c.title),
    no_proposals: (p.no_proposals || []).map((n) => n.reason),
  });
}
if (!cards.every((c) => c.model && c.model.provider === "openrouter")) {
  fail(4, "a card was not produced by the openrouter provider", { models: cards.map((c) => c.model) });
}
// Distinct, not a stuttered duplicate of the same suggestion.
const titles = cards.map((c) => c.title);
if (new Set(titles.map((t) => t.trim().toLowerCase())).size < 2) {
  fail(5, "cards are not distinct (duplicate titles)", { titles });
}
// The post-pivot topic actually surfaced as its own card (model-authored fields
// only — never the raw evidence transcript, which always contains the words).
const authored = cards
  .map((c) => `${c.title} ${c.rationale} ${c.draft_prompt}`)
  .join(" ")
  .toLowerCase();
if (!/(market|research|pricing|competit|acme|positioning|europe)/.test(authored)) {
  fail(6, "the post-pivot market-research topic never surfaced as a card", { titles });
}

const redacted = {
  meeting_id: p.meeting_id,
  card_count: cards.length,
  cards: cards.map((c) => ({
    title: c.title,
    confidence: c.confidence,
    provider: c.model && c.model.provider,
    model: c.model && c.model.model,
    evidence_count: (c.evidence || []).length,
  })),
};
fs.writeFileSync(`${process.env.EVIDENCE}/redacted-pass.json`, JSON.stringify(redacted, null, 2));
console.log(JSON.stringify(redacted, null, 2));
NODE

echo "append-feed live proof passed; cards accumulate on topic shift. evidence in $EVIDENCE/"
