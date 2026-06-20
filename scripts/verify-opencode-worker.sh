#!/usr/bin/env bash
# Backlog 009 proof: approval dispatches the single default OpenCode worker,
# records receipts, and never falls back to OMP/local worker profiles.
set -euo pipefail

cd "$(dirname "$0")/.."

EVIDENCE="${STANDBY_EVIDENCE_DIR:-docs/evidence/opencode-default-worker}"
mkdir -p "$EVIDENCE"
export EVIDENCE

TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-verify-token}"
ACTOR="${STANDBY_OPERATOR_ACTOR:-verified-operator}"

cargo build -p standbyd >/dev/null
cargo test -p standby-core opencode -- --nocapture >"$EVIDENCE/opencode-tests.txt"
cargo test -p standby-core --test worker_sandbox -- --nocapture >"$EVIDENCE/sandbox-test.txt"

OLD_WORKER_PATTERN='STANDBY_WORKER_PROFILE|STANDBY_ALLOW_NETWORK_WORKER|STANDBY_OMP_MODEL|omp-research|claude-research|pi-research'
if rg -n "$OLD_WORKER_PATTERN" crates scripts --glob '!scripts/verify-opencode-worker.sh' >"$EVIDENCE/old-worker-grep.txt"; then
  echo "FAIL: active code/scripts still mention superseded worker settings" >&2
  cat "$EVIDENCE/old-worker-grep.txt" >&2
  exit 1
fi

make_fake_path() {
  local fake_bin
  fake_bin="$(mktemp -d -t standby-fake-opencode-bin.XXXXXX)"
  ln -s "$PWD/scripts/fixtures/fake-opencode.sh" "$fake_bin/opencode"
  printf '%s' "$fake_bin"
}

wait_ready() {
  local addr="$1" pid="$2" log="$3"
  for _ in $(seq 1 80); do
    if curl -fsS "http://$addr/health" >/dev/null 2>&1; then return 0; fi
    kill -0 "$pid" 2>/dev/null || { cat "$log"; return 1; }
    sleep 0.25
  done
  echo "daemon never became ready at $addr" >&2
  cat "$log" >&2
  return 1
}

approve_demo() {
  local addr="$1" meeting="$2" body="$3" output="$4"
  curl -fsS -H "x-standby-operator-token: $TOKEN" \
    -X POST "http://$addr/api/meetings/$meeting/demo" >"$EVIDENCE/$meeting-demo.json"
  local prop
  prop="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if(!p.proposals.length)process.exit(2); process.stdout.write(p.proposals[0].id)' "$EVIDENCE/$meeting-demo.json")"
  curl -fsS -H "x-standby-operator-token: $TOKEN" -H 'content-type: application/json' \
    -d "$body" \
    -X POST "http://$addr/api/proposals/$prop/approve" >"$output"
  printf '%s' "$prop"
}

poll_terminal() {
  local addr="$1" meeting="$2" proposal="$3" output="$4"
  for _ in $(seq 1 180); do
    curl -fsS "http://$addr/api/meetings/$meeting" >"$output"
    if PROP="$proposal" node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const j=p.jobs.find(x=>x.proposal_id===process.env.PROP&&["completed","failed"].includes(x.status)); process.exit(j?0:1)' "$output"; then
      return 0
    fi
    sleep 0.25
  done
  echo "job for $meeting did not reach a terminal state" >&2
  cat "$output" >&2
  return 1
}

copy_job_receipts() {
  local projection="$1" proposal="$2" prefix="$3"
  PROP="$proposal" PREFIX="$prefix" node -e '
    const fs=require("fs");
    const path=require("path");
    const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const job=p.jobs.find(j=>j.proposal_id===process.env.PROP);
    if(!job){console.error("FAIL: no job for proposal", process.env.PROP);process.exit(1)}
    if(!job.receipt_path){console.error("FAIL: job has no receipt path", job);process.exit(1)}
    const dir=path.dirname(job.receipt_path);
    const files=["stdout.log","stderr.log","prompt.txt","job-request.json","worker-harness.json","sandbox.sb","opencode-args.txt","artifact.md","config/opencode/opencode.json"];
    for(const file of files){
      const source=path.join(dir,file);
      if(fs.existsSync(source)){
        const safe=file.replace(/\//g,"-").replace(/\.log$/,".txt");
        const target=path.join(process.env.EVIDENCE, `${process.env.PREFIX}-${safe}`);
        if(safe.endsWith(".txt") || safe.endsWith(".md") || safe.endsWith(".json") || safe.endsWith(".sb")){
          const text=fs.readFileSync(source,"utf8").replace(/[ \t]+$/gm,"").replace(/\n+$/,"\n");
          fs.writeFileSync(target,text);
        } else {
          fs.copyFileSync(source,target);
        }
      }
    }
  ' "$projection"
}

FAKE_BIN="$(make_fake_path)"
DB="$(mktemp -t standby-opencode-ok.XXXXXX).db"
JOBS="$(mktemp -d -t standby-opencode-ok-jobs.XXXXXX)"
ADDR="127.0.0.1:4332"
LOG="/tmp/standby-opencode-worker-ok.log"
PATH="$FAKE_BIN:$PATH" STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS" \
  STANDBY_OPERATOR_TOKEN="$TOKEN" STANDBY_OPERATOR_ACTOR="$ACTOR" \
  cargo run -p standbyd >"$LOG" 2>&1 &
PID=$!

DB2=""
JOBS2=""
PID2=""
cleanup() {
  kill "$PID" 2>/dev/null || true
  if [ -n "$PID2" ]; then kill "$PID2" 2>/dev/null || true; fi
  rm -f "$DB" "$DB"-wal "$DB"-shm
  rm -rf "$JOBS" "$FAKE_BIN"
  if [ -n "$DB2" ]; then rm -f "$DB2" "$DB2"-wal "$DB2"-shm; fi
  if [ -n "$JOBS2" ]; then rm -rf "$JOBS2"; fi
}
trap cleanup EXIT

wait_ready "$ADDR" "$PID" "$LOG"
OK_PROP="$(approve_demo "$ADDR" "ocw-ok" '{"prompt":"Research local-first meeting tools. Do not expose sk-live-opencode or password=hunter2."}' "$EVIDENCE/ok-approval.json")"

OK_PROP="$OK_PROP" node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/ok-approval.json`,"utf8"));
  const job=p.jobs.find(j=>j.proposal_id===process.env.OK_PROP);
  if(!job){console.error("FAIL: approval did not enqueue job");process.exit(1)}
  if(job.profile!=="opencode"){console.error("FAIL: expected opencode job, got", job.profile);process.exit(1)}
  if(job.status!=="queued"){console.error("FAIL: approval should return queued job, got", job.status);process.exit(1)}
'

poll_terminal "$ADDR" "ocw-ok" "$OK_PROP" "$EVIDENCE/ok-final-projection.json"
OK_PROP="$OK_PROP" node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/ok-final-projection.json`,"utf8"));
  const job=p.jobs.find(j=>j.proposal_id===process.env.OK_PROP);
  if(job.profile!=="opencode"){console.error("FAIL: expected opencode profile", job.profile);process.exit(1)}
  if(job.status!=="completed"){console.error("FAIL: fake OpenCode should complete", job);process.exit(1)}
  if(!p.artifacts.find(a=>a.job_id===job.id)){console.error("FAIL: completed job has no artifact");process.exit(1)}
  if(p.events.some(e=>e.event_type==="agent_job.network_consent_granted")){console.error("FAIL: consent event should not exist");process.exit(1)}
'
copy_job_receipts "$EVIDENCE/ok-final-projection.json" "$OK_PROP" "ok"

node -e '
  const fs=require("fs");
  for (const file of ["ok-approval.json", "ok-final-projection.json"]) {
    const text=fs.readFileSync(`${process.env.EVIDENCE}/${file}`,"utf8");
    if(text.includes("sk-live-opencode") || text.includes("hunter2")) throw new Error(`${file} kept raw secret-like prompt content`);
  }
  const manifest=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/ok-worker-harness.json`,"utf8"));
  if(manifest.harness!=="opencode") throw new Error(`unexpected harness ${manifest.harness}`);
  if(manifest.allow_network!==true) throw new Error("OpenCode worker must allow model network");
  if(manifest.isolated_home!==true) throw new Error("OpenCode worker must use isolated home");
  const prompt=fs.readFileSync(`${process.env.EVIDENCE}/ok-prompt.txt`,"utf8");
  if(prompt.includes("sk-live-opencode") || prompt.includes("hunter2")) throw new Error("secret-like prompt content was not redacted");
  if(!prompt.includes("[REDACTED_SECRET]")) throw new Error("redacted prompt marker missing");
  const args=fs.readFileSync(`${process.env.EVIDENCE}/ok-opencode-args.txt`,"utf8");
  if(args.includes("sk-live-opencode") || args.includes("hunter2")) throw new Error("prompt leaked into argv");
  for(const required of ["run","--format","json","--model","openrouter/z-ai/glm-5.2","--dir","--file"]){
    if(!args.includes(required)) throw new Error(`missing OpenCode arg ${required}`);
  }
'

DB2="$(mktemp -t standby-opencode-missing.XXXXXX).db"
JOBS2="$(mktemp -d -t standby-opencode-missing-jobs.XXXXXX)"
ADDR2="127.0.0.1:4333"
LOG2="/tmp/standby-opencode-worker-missing.log"
PATH="/usr/bin:/bin" STANDBY_DB="$DB2" STANDBY_ADDR="$ADDR2" STANDBY_JOBS_DIR="$JOBS2" \
  STANDBY_OPERATOR_TOKEN="$TOKEN" STANDBY_OPERATOR_ACTOR="$ACTOR" \
  target/debug/standbyd >"$LOG2" 2>&1 &
PID2=$!

wait_ready "$ADDR2" "$PID2" "$LOG2"
MISS_PROP="$(approve_demo "$ADDR2" "ocw-missing" '{"prompt":"Run approved OpenCode worker even when binary is absent."}' "$EVIDENCE/missing-approval.json")"
poll_terminal "$ADDR2" "ocw-missing" "$MISS_PROP" "$EVIDENCE/missing-final-projection.json"
MISS_PROP="$MISS_PROP" node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/missing-final-projection.json`,"utf8"));
  const job=p.jobs.find(j=>j.proposal_id===process.env.MISS_PROP);
  if(job.profile!=="opencode"){console.error("FAIL: missing-binary job should still be opencode", job.profile);process.exit(1)}
  if(job.status!=="failed"){console.error("FAIL: missing OpenCode should fail visibly", job);process.exit(1)}
  if(!job.receipt_path){console.error("FAIL: missing OpenCode failure has no receipt path");process.exit(1)}
  if(p.artifacts.length){console.error("FAIL: missing OpenCode must not produce fallback artifact");process.exit(1)}
'
copy_job_receipts "$EVIDENCE/missing-final-projection.json" "$MISS_PROP" "missing"

node -e '
  const fs=require("fs");
  fs.writeFileSync(`${process.env.EVIDENCE}/verdict.json`, JSON.stringify({
    status: "pass",
    checked_at: new Date().toISOString(),
    claim: "approved Standby work dispatches the default OpenCode worker with private file transport, no fallback, redaction, and visible receipts",
    receipts: fs.readdirSync(process.env.EVIDENCE).sort()
  }, null, 2) + "\n");
'

echo "opencode-worker verification passed; evidence in $EVIDENCE/"
