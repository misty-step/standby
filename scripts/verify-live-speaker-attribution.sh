#!/usr/bin/env bash
# Prove a diarization/provider attribution fixture creates stable remote speaker
# buckets through the daemon projection and rendered UI.
set -euo pipefail

cd "$(dirname "$0")/.."

EVIDENCE="${STANDBY_EVIDENCE_DIR:-docs/evidence/operator-action-control/live-speaker-attribution}"
mkdir -p "$EVIDENCE"
export EVIDENCE

cargo test -p standby-core --test fixture_replay live_speaker_attribution_fixture_creates_remote_buckets_from_diarization -- --nocapture
npm --prefix ui run build >/dev/null
cargo build -p standbyd >/dev/null

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DB="$(mktemp -t standby-live-speakers.XXXXXX).db"
JOBS="$(mktemp -d -t standby-live-speakers-jobs.XXXXXX)"
ADDR="127.0.0.1:4329"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS"
export STANDBY_ENABLE_SEED=1
export STANDBY_OPERATOR_TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-verify-token}"

cargo run -p standbyd >/tmp/standby-live-speaker-attribution.log 2>&1 &
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
  kill -0 "$PID" 2>/dev/null || { cat /tmp/standby-live-speaker-attribution.log; exit 1; }
  sleep 0.25
done
[ "$READY" = 1 ] || { echo "daemon never became ready"; cat /tmp/standby-live-speaker-attribution.log; exit 1; }

SEED="$(node -e 'const fs=require("fs"); const events=fs.readFileSync("crates/standby-core/tests/fixtures/live_speaker_attribution.jsonl","utf8").trim().split(/\n/); process.stdout.write(JSON.stringify({events}))')"
curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -H 'content-type: application/json' \
  -d "$SEED" \
  -X POST "http://$ADDR/api/meetings/live-speakers/seed" >"$EVIDENCE/live-speaker-attribution-projection.json"

node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/live-speaker-attribution-projection.json`,"utf8"));
  const speakers=new Set(p.transcript.map(s=>s.speaker).filter(Boolean));
  for(const expected of ["remote_1","remote_2"]){
    if(!speakers.has(expected)){console.error("FAIL: missing speaker", expected);process.exit(2)}
  }
  if(speakers.has("SPEAKER_00") || speakers.has("SPEAKER_01")){
    console.error("FAIL: provider labels leaked into projected speaker keys", [...speakers]);process.exit(3)
  }
  const remote=p.transcript.filter(s=>s.speaker && s.speaker!=="me" && s.speaker!=="system_audio");
  if(remote.length<3){console.error("FAIL: expected multiple diarized remote turns", remote);process.exit(4)}
  if(!remote.every(s=>s.source==="diarization")){
    console.error("FAIL: remote speaker buckets must come from diarization seam", remote);process.exit(5)
  }
  if(!p.proposals.some(proposal=>proposal.evidence.some(e=>e.speaker==="remote_1"))){
    console.error("FAIL: proposal evidence lost diarized remote speaker");process.exit(6)
  }
  fs.writeFileSync(`${process.env.EVIDENCE}/verdict.json`, JSON.stringify({
    status: "pass",
    checked_at: new Date().toISOString(),
    claim: "diarization/provider fixture creates stable remote speaker buckets without fake names",
    speakers: [...speakers].sort(),
    remote_turns: remote.length,
    receipts: fs.readdirSync(process.env.EVIDENCE).sort()
  }, null, 2) + "\n");
'

if [ ! -x "$CHROME" ]; then
  echo "FAIL: Google Chrome not found at $CHROME; cannot verify rendered speaker labels" >&2
  exit 7
fi

run_chrome() {
  local label="$1"; shift
  "$CHROME" "$@" &
  local chrome_pid=$!
  for _ in $(seq 1 80); do
    if ! kill -0 "$chrome_pid" 2>/dev/null; then
      wait "$chrome_pid"
      return $?
    fi
    sleep 0.25
  done
  kill "$chrome_pid" 2>/dev/null || true
  wait "$chrome_pid" 2>/dev/null || true
  echo "FAIL: Chrome $label timed out" >&2
  return 124
}

run_chrome "DOM dump" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,880 \
  --virtual-time-budget=4500 \
  --dump-dom "http://$ADDR/?meeting=live-speakers" >"$EVIDENCE/live-speaker-attribution-dom.html" 2>/dev/null

grep -q "Speaker 1" "$EVIDENCE/live-speaker-attribution-dom.html" || { echo "FAIL: rendered DOM missing Speaker 1"; exit 8; }
grep -q "Speaker 2" "$EVIDENCE/live-speaker-attribution-dom.html" || { echo "FAIL: rendered DOM missing Speaker 2"; exit 9; }
grep -q "SPEAKER_00" "$EVIDENCE/live-speaker-attribution-dom.html" && { echo "FAIL: raw provider speaker leaked into DOM"; exit 10; }

run_chrome "screenshot" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,880 \
  --virtual-time-budget=4500 \
  --screenshot="$EVIDENCE/live-speaker-attribution.png" "http://$ADDR/?meeting=live-speakers" >/dev/null 2>&1
if [ ! -s "$EVIDENCE/live-speaker-attribution.png" ]; then
  echo "FAIL: live-speaker-attribution screenshot was not written" >&2
  exit 11
fi

node -e '
  const fs=require("fs");
  const path=`${process.env.EVIDENCE}/verdict.json`;
  const verdict=JSON.parse(fs.readFileSync(path,"utf8"));
  verdict.receipts=fs.readdirSync(process.env.EVIDENCE).sort();
  fs.writeFileSync(path, JSON.stringify(verdict, null, 2) + "\n");
'

echo "live speaker attribution fixture passed; evidence in $EVIDENCE/"
