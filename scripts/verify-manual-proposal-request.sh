#!/usr/bin/env bash
# Permission-free proof for Ask Standby: seed transcript spans, post an
# operator-authored proposal request, assert the card cites transcript evidence,
# approve it, and wait for the out-of-request worker to return a deterministic
# local artifact.
set -euo pipefail

cd "$(dirname "$0")/.."

EVIDENCE="${STANDBY_EVIDENCE_DIR:-docs/evidence/operator-action-control}"
mkdir -p "$EVIDENCE"
export EVIDENCE

cargo build -p standbyd >/dev/null

DB="$(mktemp -t standby-proposal.XXXXXX).db"
JOBS="$(mktemp -d -t standby-proposal-jobs.XXXXXX)"
ADDR="127.0.0.1:4326"
export STANDBY_DB="$DB" STANDBY_ADDR="$ADDR" STANDBY_JOBS_DIR="$JOBS"
export STANDBY_ENABLE_SEED=1 STANDBY_WORKER_PROFILE=local-research

cargo run -p standbyd >/tmp/standby-proposal-request.log 2>&1 &
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
  kill -0 "$PID" 2>/dev/null || { cat /tmp/standby-proposal-request.log; exit 1; }
  sleep 0.25
done
[ "$READY" = 1 ] || { echo "daemon never became ready"; cat /tmp/standby-proposal-request.log; exit 1; }

SEED="$(node -e 'process.stdout.write(JSON.stringify({events:process.argv.slice(1)}))' \
  '{"type":"source.started","mode":"mic+system","mic":true,"system":true}' \
  '{"type":"segment.final","lane":"system_audio","speaker":"remote_1","text":"Customers keep asking whether local-first meeting tools already exist."}' \
  '{"type":"segment.final","lane":"system_audio","speaker":"remote_2","text":"We should understand productized meeting assistants and open-source options."}' \
  '{"type":"segment.final","lane":"microphone","speaker":"me","text":"Make the output concise enough to approve during this call."}')"
curl -fsS -H 'content-type: application/json' \
  -d "$SEED" \
  -X POST "http://$ADDR/api/meetings/manual/seed" >"$EVIDENCE/manual-seed.json"

STATUS="$(curl -sS -o "$EVIDENCE/manual-max-proposals-response.json" -w "%{http_code}" \
  -H 'content-type: application/json' \
  -d '{"message":"Suggest two tasks from this call","context_window":"recent","max_proposals":2}' \
  -X POST "http://$ADDR/api/meetings/manual/proposal-requests")"
if [ "$STATUS" != "400" ]; then
  echo "FAIL: max_proposals>1 should be rejected until multi-card generation exists; got $STATUS" >&2
  cat "$EVIDENCE/manual-max-proposals-response.json" >&2
  exit 26
fi

curl -fsS -H 'content-type: application/json' \
  -d '{"message":"Research the market map for local-first meeting tools using this call as context","context_window":"recent","max_proposals":1}' \
  -X POST "http://$ADDR/api/meetings/manual/proposal-requests" >"$EVIDENCE/manual-proposal-response.json"

node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/manual-proposal-response.json`,"utf8"));
  const req=p.proposal_requests.at(-1);
  if(!req){console.error("FAIL: no proposal_request in projection");process.exit(2)}
  if(req.message.indexOf("market map")<0){console.error("FAIL: request message missing");process.exit(3)}
  if(req.transcript_spans.length<2){console.error("FAIL: request did not cite transcript spans");process.exit(4)}
  const requestEvent=p.events.filter(e=>e.event_type==="proposal_request.created").at(-1);
  const created=p.events.find(e=>e.event_type==="proposal.created" && e.parent_event_id===requestEvent.id);
  if(!created){console.error("FAIL: proposal request did not create a parented proposal");process.exit(5)}
  const proposal=p.proposals.find(x=>x.id===created.payload_json.id);
  if(!proposal){console.error("FAIL: parented proposal missing from projection");process.exit(35)}
  if(!proposal.model || proposal.model.provider==="heuristic"){
    console.error("FAIL: proposal did not record model-native provenance");
    process.exit(27)
  }
  if(proposal.model.provider!=="recorded-model" && proposal.model.provider!=="openai"){
    console.error("FAIL: unexpected proposal provider", proposal.model.provider);
    process.exit(28)
  }
  if(p.jobs.length){console.error("FAIL: proposal request created a job before approval");process.exit(17)}
  if(p.events.some(e=>e.event_type.startsWith("agent_job."))){
    console.error("FAIL: proposal request emitted agent job events before approval");process.exit(18)
  }
  if(proposal.rationale.indexOf("market map")<0 || proposal.draft_prompt.indexOf("market map")<0){
    console.error("FAIL: proposal does not cite operator message");process.exit(6)
  }
  if(proposal.evidence.length<2){console.error("FAIL: proposal lacks transcript evidence");process.exit(7)}
  for(const evidence of proposal.evidence){
    if(!req.transcript_spans.includes(evidence.segment_id)){
      console.error("FAIL: evidence not from request context", evidence.segment_id);process.exit(8)
    }
  }
  const types=p.events.map(e=>e.event_type);
  for(const type of ["proposal_request.created","proposal.created"]){
    if(!types.includes(type)){console.error("FAIL: missing event", type);process.exit(9)}
  }
  if(created.trace_id!==proposal.id){
    console.error("FAIL: proposal.created trace_id should be proposal id, got", created.trace_id);
    process.exit(23)
  }
  if(created.parent_event_id!==requestEvent.id){
    console.error("FAIL: proposal.created is not parented to proposal_request.created");
    process.exit(24)
  }
  process.stdout.write(proposal.id);
' >"$EVIDENCE/manual-proposal-id.txt"
PROP="$(cat "$EVIDENCE/manual-proposal-id.txt")"

curl -fsS -H 'content-type: application/json' \
  -d '{"message":"Create a proposal without any transcript context","context_window":"recent","max_proposals":1}' \
  -X POST "http://$ADDR/api/meetings/empty/proposal-requests" >"$EVIDENCE/manual-no-proposal-response.json"

node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/manual-no-proposal-response.json`,"utf8"));
  const noProposal=p.no_proposals.at(-1);
  if(!noProposal){console.error("FAIL: second proposal request did not record no-proposal decision");process.exit(29)}
  if(noProposal.reason!=="model_returned_no_valid_proposals"){
    console.error("FAIL: unexpected no-proposal reason", noProposal.reason);process.exit(30)
  }
  if(!noProposal.model || noProposal.model.provider==="heuristic"){
    console.error("FAIL: no-proposal decision lacks model provenance");process.exit(31)
  }
  const noEvent=p.events.find(e=>e.event_type==="proposal.not_created" && e.payload_json.id===noProposal.id);
  if(!noEvent){console.error("FAIL: missing proposal.not_created event");process.exit(32)}
  const lastRequest=p.events.filter(e=>e.event_type==="proposal_request.created").at(-1);
  if(!lastRequest || noEvent.parent_event_id!==lastRequest.id){
    console.error("FAIL: proposal.not_created is not parented to latest proposal request");process.exit(33)
  }
  if(p.jobs.length){console.error("FAIL: no-proposal request created a job before approval");process.exit(34)}
'

curl -fsS -H 'content-type: application/json' \
  -d '{"approved_by":"verify-manual-proposal"}' \
  -X POST "http://$ADDR/api/proposals/$PROP/approve" >"$EVIDENCE/manual-approval-response.json"

PROP="$PROP" node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/manual-approval-response.json`,"utf8"));
  const job=p.jobs.find(job=>job.proposal_id===process.env.PROP);
  if(!job){console.error("FAIL: approval did not enqueue a job");process.exit(10)}
  if(job.status==="completed"){console.error("FAIL: job completed inside approval request");process.exit(11)}
  if(job.status!=="queued"){console.error("FAIL: approval response should return queued job, got", job.status);process.exit(25)}
  console.log("approval returned out-of-request; job status:", job.status);
'

DONE=0
for _ in $(seq 1 160); do
  curl -fsS "http://$ADDR/api/meetings/manual" >"$EVIDENCE/manual-final-projection.json"
  if PROP="$PROP" node -e 'const p=JSON.parse(require("fs").readFileSync(`${process.env.EVIDENCE}/manual-final-projection.json`,"utf8")); const j=p.jobs.find(x=>x.proposal_id===process.env.PROP&&["completed","failed"].includes(x.status)); process.exit(j?0:1)'; then DONE=1; break; fi
  sleep 0.25
done
[ "$DONE" = 1 ] || { echo "job did not reach a terminal state"; cat "$EVIDENCE/manual-final-projection.json"; cat /tmp/standby-proposal-request.log; exit 12; }

PROP="$PROP" node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(`${process.env.EVIDENCE}/manual-final-projection.json`,"utf8"));
  const job=p.jobs.find(job=>job.proposal_id===process.env.PROP);
  if(!job){console.error("FAIL: approved job missing from final projection");process.exit(19)}
  const progress=p.events.some(e=>e.event_type==="agent_job.progress");
  if(!progress){console.error("FAIL: no worker progress event recorded");process.exit(13)}
  if(job.status==="failed"){
    if((job.profile||"local-research")==="local-research"){
      console.error("FAIL: deterministic local-research worker failed:", job.error||job.failure_reason||"unknown");
      process.exit(14)
    }
    if(!job.receipt_path){console.error("FAIL: failed non-local worker has no receipt");process.exit(20)}
    console.log("worker failed visibly with receipt:", job.receipt_path);
    process.exit(0)
  }
  if(job.status!=="completed"){
    console.error("FAIL: job reached unexpected terminal status:", job.status);
    process.exit(21)
  }
  const artifact=p.artifacts.find(a=>a.job_id===job.id);
  if(!artifact){console.error("FAIL: completed worker has no artifact");process.exit(15)}
  const path=(artifact.uri||"").replace(/^file:\/\//,"");
  if(!fs.existsSync(path)){console.error("FAIL: artifact file missing:", path);process.exit(16)}
  console.log("worker completed with artifact:", path);
'

echo "manual proposal request smoke passed; evidence in $EVIDENCE/"
