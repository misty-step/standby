#!/usr/bin/env bash
# Prove Standby preserves and renders distinct remote speaker tokens when the
# transcript source provides them. This is not a diarization proof; it is the v1
# attribution seam and UI rendering proof.
set -euo pipefail

cd "$(dirname "$0")/.."

EVIDENCE="${STANDBY_EVIDENCE_DIR:-docs/evidence/operator-action-control}"
mkdir -p "$EVIDENCE"
export EVIDENCE

cargo test -p standby-core --test fixture_replay speaker_distinction_fixture_preserves_remote_speakers -- --nocapture
npm --prefix ui run build >/dev/null
cargo build -p standbyd >/dev/null

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DB="$(mktemp -t standby-speakers.XXXXXX).db"
JOBS="$(mktemp -d -t standby-speakers-jobs.XXXXXX)"
ADDR="127.0.0.1:4327"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS"
export STANDBY_ENABLE_SEED=1
export STANDBY_OPERATOR_TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-verify-token}"

cargo run -p standbyd >/tmp/standby-speaker-distinction.log 2>&1 &
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
  kill -0 "$PID" 2>/dev/null || { cat /tmp/standby-speaker-distinction.log; exit 1; }
  sleep 0.25
done
[ "$READY" = 1 ] || { echo "daemon never became ready"; cat /tmp/standby-speaker-distinction.log; exit 1; }

SEED="$(node -e 'const fs=require("fs"); const events=fs.readFileSync("crates/standby-core/tests/fixtures/speaker_distinction_meeting.jsonl","utf8").trim().split(/\n/); process.stdout.write(JSON.stringify({events}))')"
curl -fsS -H "x-standby-operator-token: $STANDBY_OPERATOR_TOKEN" -H 'content-type: application/json' \
  -d "$SEED" \
  -X POST "http://$ADDR/api/meetings/speakers/seed" >"$EVIDENCE/speaker-distinction-projection.json"

node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/speaker-distinction-projection.json`,"utf8"));
  const speakers=new Set(p.transcript.map(s=>s.speaker).filter(Boolean));
  for(const expected of ["remote_1","remote_2"]){
    if(!speakers.has(expected)){console.error("FAIL: missing speaker", expected);process.exit(2)}
  }
  const remote=[...speakers].filter(s=>s!=="me"&&s!=="system_audio");
  if(remote.length<2){console.error("FAIL: remote speakers collapsed", [...speakers]);process.exit(3)}
  if(!p.proposals.some(proposal=>proposal.evidence.some(e=>e.speaker==="remote_1"))){
    console.error("FAIL: proposal evidence lost remote speaker");process.exit(4)
  }
  console.log("projection speakers:", [...speakers].join(", "));
'

if [ ! -x "$CHROME" ]; then
  echo "FAIL: Google Chrome not found at $CHROME; cannot verify rendered speaker labels" >&2
  exit 5
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
  --dump-dom "http://$ADDR/?meeting=speakers" >"$EVIDENCE/speaker-distinction-dom.html" 2>/dev/null

grep -q "Speaker 1" "$EVIDENCE/speaker-distinction-dom.html" || { echo "FAIL: rendered DOM missing Speaker 1"; exit 6; }
grep -q "Speaker 2" "$EVIDENCE/speaker-distinction-dom.html" || { echo "FAIL: rendered DOM missing Speaker 2"; exit 7; }

run_chrome "screenshot" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,880 \
  --virtual-time-budget=4500 \
  --screenshot="$EVIDENCE/speaker-distinction.png" "http://$ADDR/?meeting=speakers" >/dev/null 2>&1
if [ ! -s "$EVIDENCE/speaker-distinction.png" ]; then
  echo "FAIL: speaker-distinction screenshot was not written" >&2
  exit 8
fi

echo "speaker-distinction fixture passed; evidence in $EVIDENCE/"
