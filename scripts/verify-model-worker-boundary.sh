#!/usr/bin/env bash
# Backlog 004 proof: the OMP/GLM worker profile is opt-in, policy-scoped,
# isolated from user-home secrets, and fails visibly with receipts when auth is
# absent. It intentionally does not require live model credentials.
set -euo pipefail

cd "$(dirname "$0")/.."

EVIDENCE="${STANDBY_EVIDENCE_DIR:-docs/evidence/operator-action-control/model-worker-boundary}"
mkdir -p "$EVIDENCE"
export EVIDENCE

TOKEN="${STANDBY_OPERATOR_TOKEN:-standby-verify-token}"
ACTOR="${STANDBY_OPERATOR_ACTOR:-verified-operator}"

cargo build -p standbyd >/dev/null
cargo test -p standby-core omp_research -- --nocapture >"$EVIDENCE/profile-tests.txt"
cargo test -p standby-core --test worker_sandbox -- --nocapture >"$EVIDENCE/sandbox-test.txt"

wait_ready() {
  local addr="$1" pid="$2" log="$3"
  for _ in $(seq 1 80); do
    if curl -fsS "http://$addr/health" >/dev/null 2>&1; then
      return 0
    fi
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
    const files=["stdout.log","stderr.log","prompt.txt","worker-profile.json","sandbox.sb"];
    for(const file of files){
      const source=path.join(dir,file);
      if(fs.existsSync(source)){
        const trackedName=file.endsWith(".log") ? file.replace(/\.log$/, ".txt") : file;
        const target=path.join(process.env.EVIDENCE, `${process.env.PREFIX}-${trackedName}`);
        if(trackedName.endsWith(".txt")){
          const text=fs.readFileSync(source,"utf8").replace(/[ \t]+$/gm,"").replace(/\n+$/,"\n");
          fs.writeFileSync(target,text);
        } else {
          fs.copyFileSync(source,target);
        }
      }
    }
  ' "$projection"
}

DB="$(mktemp -t standby-mwb-fallback.XXXXXX).db"
JOBS="$(mktemp -d -t standby-mwb-fallback-jobs.XXXXXX)"
ADDR="127.0.0.1:4332"
LOG="/tmp/standby-model-worker-boundary-fallback.log"
env -u STANDBY_ALLOW_NETWORK_WORKER \
  STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS" \
  STANDBY_WORKER_PROFILE=omp-research STANDBY_OPERATOR_TOKEN="$TOKEN" \
  STANDBY_OPERATOR_ACTOR="$ACTOR" cargo run -p standbyd >"$LOG" 2>&1 &
PID=$!

DB2=""
JOBS2=""
PID2=""
cleanup() {
  kill "$PID" 2>/dev/null || true
  if [ -n "$PID2" ]; then kill "$PID2" 2>/dev/null || true; fi
  rm -f "$DB" "$DB"-wal "$DB"-shm
  rm -rf "$JOBS"
  if [ -n "$DB2" ]; then rm -f "$DB2" "$DB2"-wal "$DB2"-shm; fi
  if [ -n "$JOBS2" ]; then rm -rf "$JOBS2"; fi
}
trap cleanup EXIT

wait_ready "$ADDR" "$PID" "$LOG"
FALLBACK_PROP="$(approve_demo "$ADDR" "mwb-fallback" '{"prompt":"Run the approved task with the safe fallback worker."}' "$EVIDENCE/fallback-approval.json")"
poll_terminal "$ADDR" "mwb-fallback" "$FALLBACK_PROP" "$EVIDENCE/fallback-final-projection.json"

FALLBACK_PROP="$FALLBACK_PROP" node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/fallback-final-projection.json`,"utf8"));
  const job=p.jobs.find(j=>j.proposal_id===process.env.FALLBACK_PROP);
  if(job.status!=="completed"){console.error("FAIL: fallback local worker did not complete", job);process.exit(1)}
  if(job.profile!=="local-research"){console.error("FAIL: omp profile should fall back to local-research without global opt-in", job.profile);process.exit(1)}
  if(!p.artifacts.length){console.error("FAIL: fallback completed without artifact");process.exit(1)}
'
copy_job_receipts "$EVIDENCE/fallback-final-projection.json" "$FALLBACK_PROP" "fallback"

DB2="$(mktemp -t standby-mwb-omp.XXXXXX).db"
JOBS2="$(mktemp -d -t standby-mwb-omp-jobs.XXXXXX)"
ADDR2="127.0.0.1:4333"
LOG2="/tmp/standby-model-worker-boundary-omp.log"
env -u OPENROUTER_API_KEY -u ZAI_API_KEY \
  STANDBY_DB="$DB2" STANDBY_ADDR="$ADDR2" STANDBY_JOBS_DIR="$JOBS2" \
  STANDBY_WORKER_PROFILE=omp-research STANDBY_ALLOW_NETWORK_WORKER=1 \
  STANDBY_OMP_MODEL=openrouter/z-ai/glm-5.2 \
  STANDBY_OPERATOR_TOKEN="$TOKEN" STANDBY_OPERATOR_ACTOR="$ACTOR" \
  cargo run -p standbyd >"$LOG2" 2>&1 &
PID2=$!

wait_ready "$ADDR2" "$PID2" "$LOG2"
OMP_PROP="$(approve_demo "$ADDR2" "mwb-omp" '{"prompt":"Research local-first meeting tools. Do not expose sk-live-model-worker or password=hunter2.","network_worker_consent":true}' "$EVIDENCE/omp-approval.json")"
poll_terminal "$ADDR2" "mwb-omp" "$OMP_PROP" "$EVIDENCE/omp-final-projection.json"

OMP_PROP="$OMP_PROP" node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/omp-final-projection.json`,"utf8"));
  const job=p.jobs.find(j=>j.proposal_id===process.env.OMP_PROP);
  if(job.profile!=="omp-research"){console.error("FAIL: expected omp-research profile", job.profile);process.exit(1)}
  if(job.status!=="failed"){console.error("FAIL: missing-auth OMP run should fail visibly", job);process.exit(1)}
  if(job.failure_reason!=="auth_required"){console.error("FAIL: expected auth_required, got", job.failure_reason, job.error);process.exit(1)}
  if(!job.receipt_path){console.error("FAIL: auth failure has no receipt path");process.exit(1)}
  const consent=p.events.some(e=>e.event_type==="agent_job.network_consent_granted" && e.payload_json.job_id===job.id);
  if(!consent){console.error("FAIL: consent event missing for OMP job");process.exit(1)}
'
copy_job_receipts "$EVIDENCE/omp-final-projection.json" "$OMP_PROP" "omp"

node -e '
  const fs=require("fs");
  const manifest=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/omp-worker-profile.json`,"utf8"));
  const tools=(manifest.allowed_tools||[]).join(",");
  const expected="read,grep,find,web_search";
  if(manifest.profile!=="omp-research") throw new Error(`unexpected profile ${manifest.profile}`);
  if(manifest.allow_network!==true) throw new Error("omp profile must be network-enabled");
  if(manifest.isolated_home!==true) throw new Error("omp profile must use isolated home");
  if(tools!==expected) throw new Error(`unexpected tool allowlist ${tools}`);
  for(const forbidden of ["bash","edit","write","task","browser"]){
    if((manifest.allowed_tools||[]).includes(forbidden)) throw new Error(`forbidden tool allowed: ${forbidden}`);
  }
  const prompt=fs.readFileSync(`${process.env.EVIDENCE}/omp-prompt.txt`,"utf8");
  if(prompt.includes("sk-live-model-worker") || prompt.includes("hunter2")) throw new Error("secret-like prompt content was not redacted");
  if(!prompt.includes("[REDACTED_SECRET]")) throw new Error("redacted prompt marker missing");
'

node -e '
  const fs=require("fs");
  for(const file of fs.readdirSync(process.env.EVIDENCE)){
    if(!file.endsWith(".txt")) continue;
    const path=`${process.env.EVIDENCE}/${file}`;
    const text=fs.readFileSync(path,"utf8").replace(/[ \t]+$/gm,"").replace(/\n+$/,"\n");
    fs.writeFileSync(path,text);
  }
  fs.writeFileSync(`${process.env.EVIDENCE}/verdict.json`, JSON.stringify({
    status: "pass",
    checked_at: new Date().toISOString(),
    claim: "omp-research is opt-in, isolated, tool-scoped, consent-gated, redacted, and fails visibly without auth.",
    receipts: fs.readdirSync(process.env.EVIDENCE).sort()
  }, null, 2) + "\n");
'

echo "model-worker-boundary verification passed; evidence in $EVIDENCE/"
