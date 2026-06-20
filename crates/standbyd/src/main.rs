mod capture;

use anyhow::{Context, Result};
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use standby_core::{
    AgentJobSpec, CaptureMode, EventStore, HelperEvent, JobFailureReason, JobStatus,
    LocalMacAudioSource, Meeting, MeetingProjection, ProposalAgentRun, ProposalContextWindow,
    ProposalRequestEngine, ProposalStatus, WorkerProfile, approve_proposal, default_scratch_root,
    demo_meeting_segments, emit_job_failed, event_types, propose_from_meeting_context, run_job,
    run_proposal_agent,
};
use std::collections::HashMap;
use std::io::Read;
use std::net::SocketAddr;
use std::path::{Path as FsPath, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tokio::sync::mpsc;
use tower_http::services::ServeDir;
use tower_http::trace::TraceLayer;
use tracing::info;
use tracing_subscriber::EnvFilter;

#[derive(Clone)]
pub(crate) struct AppState {
    pub(crate) store: Arc<Mutex<EventStore>>,
    pub(crate) auth: Arc<OperatorAuth>,
    /// Meeting id -> running capture helper pid, for stop signalling.
    pub(crate) captures: Arc<Mutex<HashMap<String, u32>>>,
    /// Out-of-request queue: approval enqueues here; the worker loop drains it.
    pub(crate) job_tx: mpsc::UnboundedSender<QueuedJob>,
}

pub(crate) struct QueuedJob {
    pub(crate) job: AgentJobSpec,
}

#[derive(Debug, Deserialize)]
struct ApproveRequest {
    prompt: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct OperatorAuth {
    token: String,
    actor: String,
}

#[derive(Debug, Clone)]
struct Operator {
    actor: String,
}

impl OperatorAuth {
    fn from_env() -> Self {
        Self {
            token: std::env::var("STANDBY_OPERATOR_TOKEN").unwrap_or_else(|_| generate_token()),
            actor: std::env::var("STANDBY_OPERATOR_ACTOR")
                .unwrap_or_else(|_| "Phaedrus".to_string()),
        }
    }
}

#[derive(Debug, Deserialize)]
struct ProposalRequestInput {
    message: String,
    #[serde(default)]
    context_window: ProposalContextWindow,
    max_proposals: Option<u8>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            // Default to a useful level so an operator sees capture/worker failures
            // without setting RUST_LOG; still overridable via RUST_LOG.
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("standbyd=info,standby_core=warn")),
        )
        .init();

    let db_path = db_path();
    let (job_tx, job_rx) = mpsc::unbounded_channel::<QueuedJob>();
    let store = Arc::new(Mutex::new(open_store(&db_path)?));
    let state = AppState {
        store,
        auth: Arc::new(OperatorAuth::from_env()),
        captures: Arc::new(Mutex::new(HashMap::new())),
        job_tx,
    };
    spawn_worker_loop(db_path, job_rx);
    recover_queued_jobs(&state)?;

    let app = api_router(state).fallback_service(ServeDir::new(ui_dist_path()));
    let addr: SocketAddr = std::env::var("STANDBY_ADDR")
        .unwrap_or_else(|_| "127.0.0.1:4317".to_string())
        .parse()
        .context("parse STANDBY_ADDR")?;

    let listener = tokio::net::TcpListener::bind(addr).await?;
    info!("standbyd listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

fn api_router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/api/meetings/{meeting_id}/demo", post(start_demo))
        .route(
            "/api/meetings/{meeting_id}/capture/start",
            post(capture_start),
        )
        .route(
            "/api/meetings/{meeting_id}/capture/stop",
            post(capture_stop),
        )
        .route("/api/meetings/{meeting_id}/seed", post(seed_capture))
        .route(
            "/api/meetings/{meeting_id}/proposal-requests",
            post(create_proposal_request),
        )
        .route("/api/operator-session", get(operator_session))
        .route("/api/meetings/{meeting_id}", get(meeting_projection))
        .route("/api/meetings/{meeting_id}/events", get(meeting_projection))
        .route("/api/proposals/{proposal_id}/approve", post(approve))
        .route("/api/proposals/{proposal_id}/ignore", post(ignore))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "ok",
        "service": "standbyd"
    }))
}

async fn operator_session(State(state): State<AppState>) -> impl IntoResponse {
    let cookie = format!(
        "standby_operator_token={}; Path=/; SameSite=Strict; HttpOnly",
        state.auth.token
    );
    (
        [(header::SET_COOKIE, cookie)],
        Json(serde_json::json!({
            "actor": state.auth.actor,
            "auth": "operator_session"
        })),
    )
}

fn authorize_operator(state: &AppState, headers: &HeaderMap) -> ApiResult<Operator> {
    let origin = header_text(headers, header::ORIGIN);
    if let Some(origin) = origin {
        if !origin_matches_host(origin, headers) {
            return Err(ApiError::forbidden(
                "operator request origin is not allowed",
            ));
        }
    }

    let header_token = header_text(headers, "x-standby-operator-token");
    let cookie_token = header_text(headers, header::COOKIE).and_then(cookie_operator_token);
    let header_ok = header_token.is_some_and(|token| token == state.auth.token);
    let cookie_ok = cookie_token.is_some_and(|token| token == state.auth.token);

    if !header_ok && !cookie_ok {
        return Err(ApiError::unauthorized("operator token is required"));
    }
    if cookie_ok && !header_ok && origin.is_none() {
        return Err(ApiError::forbidden(
            "operator cookie mutations require a same-origin browser request",
        ));
    }

    Ok(Operator {
        actor: state.auth.actor.clone(),
    })
}

fn header_text<'a, K>(headers: &'a HeaderMap, key: K) -> Option<&'a str>
where
    K: axum::http::header::AsHeaderName,
{
    headers.get(key).and_then(|value| value.to_str().ok())
}

fn cookie_operator_token(cookie: &str) -> Option<&str> {
    cookie.split(';').find_map(|part| {
        let trimmed = part.trim();
        trimmed
            .strip_prefix("standby_operator_token=")
            .filter(|token| !token.is_empty())
    })
}

fn origin_matches_host(origin: &str, headers: &HeaderMap) -> bool {
    let Some(host) = header_text(headers, header::HOST) else {
        return false;
    };
    let Some(rest) = origin
        .strip_prefix("http://")
        .or_else(|| origin.strip_prefix("https://"))
    else {
        return false;
    };
    let origin_host = rest.split('/').next().unwrap_or_default();
    origin_host.eq_ignore_ascii_case(host)
}

fn generate_token() -> String {
    let mut bytes = [0u8; 32];
    if let Ok(mut file) = std::fs::File::open("/dev/urandom") {
        if file.read_exact(&mut bytes).is_ok() {
            return bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        }
    }
    standby_core::new_id("operator")
}

async fn start_demo(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(meeting_id): Path<String>,
) -> ApiResult<Json<MeetingProjection>> {
    let _operator = authorize_operator(&state, &headers)?;
    let store = state
        .store
        .lock()
        .map_err(|_| ApiError::internal("lock store"))?;
    if !store.has_event_type(&meeting_id, event_types::SEGMENT_FINAL)? {
        for segment in demo_meeting_segments(&meeting_id) {
            store.append(
                &meeting_id,
                event_types::SEGMENT_FINAL,
                Some(&meeting_id),
                None,
                &segment,
            )?;
        }
    }

    if !store.has_event_type(&meeting_id, event_types::PROPOSAL_CREATED)? {
        propose_from_meeting_context(&store, &meeting_id)?;
    }

    Ok(Json(store.projection(&meeting_id)?))
}

async fn meeting_projection(
    State(state): State<AppState>,
    Path(meeting_id): Path<String>,
) -> ApiResult<Json<MeetingProjection>> {
    let store = state
        .store
        .lock()
        .map_err(|_| ApiError::internal("lock store"))?;
    Ok(Json(store.projection(&meeting_id)?))
}

#[derive(Debug, Deserialize)]
struct CaptureParams {
    mode: Option<String>,
}

async fn capture_start(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(meeting_id): Path<String>,
    Query(params): Query<CaptureParams>,
) -> ApiResult<Json<MeetingProjection>> {
    let _operator = authorize_operator(&state, &headers)?;
    let mode = params.mode.unwrap_or_else(|| "mic+system".to_string());
    capture::start_capture(state.clone(), meeting_id.clone(), mode).await?;
    let store = state
        .store
        .lock()
        .map_err(|_| ApiError::internal("lock store"))?;
    Ok(Json(store.projection(&meeting_id)?))
}

async fn capture_stop(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(meeting_id): Path<String>,
) -> ApiResult<Json<MeetingProjection>> {
    let _operator = authorize_operator(&state, &headers)?;
    capture::stop_capture(&state, &meeting_id)?;
    let store = state
        .store
        .lock()
        .map_err(|_| ApiError::internal("lock store"))?;
    Ok(Json(store.projection(&meeting_id)?))
}

#[derive(Debug, Deserialize)]
struct SeedRequest {
    events: Vec<String>,
}

/// Test-only: ingest helper-shaped JSONL events through the real normalization
/// path so UI-state verification can drive every source state without hardware.
/// Disabled unless STANDBY_ENABLE_SEED=1.
async fn seed_capture(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(meeting_id): Path<String>,
    Json(request): Json<SeedRequest>,
) -> ApiResult<Json<MeetingProjection>> {
    let _operator = authorize_operator(&state, &headers)?;
    if std::env::var("STANDBY_ENABLE_SEED").ok().as_deref() != Some("1") {
        return Err(ApiError::forbidden(
            "seed endpoint disabled; set STANDBY_ENABLE_SEED=1",
        ));
    }
    let store = state
        .store
        .lock()
        .map_err(|_| ApiError::internal("lock store"))?;
    for line in &request.events {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        // meeting.started isn't a helper event; emit it directly so tests can
        // drive the waiting-for-permission state.
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) {
            if value.get("type").and_then(|t| t.as_str()) == Some("meeting.started") {
                store.append(
                    &meeting_id,
                    event_types::MEETING_STARTED,
                    Some(&meeting_id),
                    None,
                    &Meeting {
                        id: meeting_id.clone(),
                        title: value
                            .get("title")
                            .and_then(|t| t.as_str())
                            .map(String::from),
                        mode: value
                            .get("mode")
                            .and_then(|m| m.as_str())
                            .map(CaptureMode::parse),
                    },
                )?;
                continue;
            }
        }
        if let Some(event) = HelperEvent::parse_line(line) {
            LocalMacAudioSource::ingest(&store, &meeting_id, event)?;
        }
    }
    Ok(Json(store.projection(&meeting_id)?))
}

async fn create_proposal_request(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(meeting_id): Path<String>,
    Json(request): Json<ProposalRequestInput>,
) -> ApiResult<Json<MeetingProjection>> {
    let _operator = authorize_operator(&state, &headers)?;
    if request.message.trim().is_empty() {
        return Err(ApiError::bad_request(
            "proposal request message is required",
        ));
    }
    if request.max_proposals.unwrap_or(1) > 1 {
        return Err(ApiError::bad_request(
            "proposal requests currently support one proposal; send max_proposals=1",
        ));
    }

    let store = state
        .store
        .lock()
        .map_err(|_| ApiError::internal("lock store"))?;
    let projection = store.projection(&meeting_id)?;
    let proposal_request = ProposalRequestEngine::build(
        &meeting_id,
        &request.message,
        request.context_window,
        request.max_proposals.unwrap_or(1),
        &projection.transcript,
    );
    let request_event = store.append(
        &meeting_id,
        event_types::PROPOSAL_REQUEST_CREATED,
        Some(&proposal_request.id),
        None,
        &proposal_request,
    )?;

    run_proposal_agent(
        &store,
        &meeting_id,
        ProposalAgentRun {
            operator_message: Some(proposal_request.message.clone()),
            transcript_spans: proposal_request.transcript_spans.clone(),
            max_proposals: proposal_request.max_proposals,
            parent_event_id: Some(request_event.id),
            record_no_proposal: true,
        },
    )?;

    Ok(Json(store.projection(&meeting_id)?))
}

async fn approve(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(proposal_id): Path<String>,
    Json(request): Json<ApproveRequest>,
) -> ApiResult<Json<MeetingProjection>> {
    let operator = authorize_operator(&state, &headers)?;

    let store = state
        .store
        .lock()
        .map_err(|_| ApiError::internal("lock store"))?;
    let proposal = store
        .find_latest_proposal(&proposal_id)?
        .ok_or_else(|| ApiError::not_found(format!("proposal {proposal_id}")))?;

    // Already approved: return current state without re-enqueuing.
    if proposal.status == ProposalStatus::Approved {
        return Ok(Json(store.projection(&proposal.meeting_id)?));
    }

    // Deterministic, server-owned: persist proposal.approved + a queued job, then
    // return immediately. The worker loop runs the job out-of-request.
    let job = approve_proposal(&store, &proposal, &operator.actor, request.prompt)?;
    let meeting_id = proposal.meeting_id.clone();

    let queued_projection = store.projection(&meeting_id)?;
    drop(store);

    if state.job_tx.send(QueuedJob { job: job.clone() }).is_err() {
        let store = state
            .store
            .lock()
            .map_err(|_| ApiError::internal("lock store"))?;
        emit_job_failed(
            &store,
            &job,
            JobFailureReason::Unknown,
            "worker queue unavailable",
        )?;
        return Ok(Json(store.projection(&meeting_id)?));
    }

    Ok(Json(queued_projection))
}

async fn ignore(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(proposal_id): Path<String>,
) -> ApiResult<Json<MeetingProjection>> {
    let _operator = authorize_operator(&state, &headers)?;
    let store = state
        .store
        .lock()
        .map_err(|_| ApiError::internal("lock store"))?;
    let mut proposal = store
        .find_latest_proposal(&proposal_id)?
        .ok_or_else(|| ApiError::not_found(format!("proposal {proposal_id}")))?;
    proposal.status = ProposalStatus::Ignored;
    store.append(
        &proposal.meeting_id,
        event_types::PROPOSAL_IGNORED,
        Some(&proposal.id),
        None,
        &proposal,
    )?;

    Ok(Json(store.projection(&proposal.meeting_id)?))
}

fn db_path() -> PathBuf {
    std::env::var("STANDBY_DB")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(".standby/standby.db"))
}

fn open_store(path: &FsPath) -> Result<EventStore> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).context("create standby data dir")?;
        }
    }
    EventStore::open(path)
}

fn scratch_root() -> PathBuf {
    if let Ok(dir) = std::env::var("STANDBY_JOBS_DIR") {
        return PathBuf::from(dir);
    }
    // Co-locate worker scratch with the event ledger so they share a root
    // regardless of the daemon's working directory.
    match db_path().parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join("jobs"),
        _ => default_scratch_root(),
    }
}

fn recover_queued_jobs(state: &AppState) -> Result<()> {
    let jobs = {
        let store = state
            .store
            .lock()
            .map_err(|_| anyhow::anyhow!("lock store for worker recovery"))?;
        store.recoverable_jobs()?
    };

    let scratch_root = scratch_root();
    for job in jobs {
        let stale_worker_count = match terminate_stale_worker_for_job(&job, &scratch_root) {
            Ok(count) => count,
            Err(err) => {
                let job = mark_job_recovered(job, 0);
                let store = state
                    .store
                    .lock()
                    .map_err(|_| anyhow::anyhow!("lock store for stale worker failure"))?;
                emit_job_failed(
                    &store,
                    &job,
                    JobFailureReason::Unknown,
                    &format!("worker recovery could not terminate stale worker: {err}"),
                )?;
                continue;
            }
        };
        let job = mark_job_recovered(job, stale_worker_count);
        info!("recovering worker job {}", job.id);
        if stale_worker_count > 0 {
            info!(
                job_id = job.id,
                stale_worker_count, "terminated stale worker before recovery"
            );
        }
        {
            let store = state
                .store
                .lock()
                .map_err(|_| anyhow::anyhow!("lock store for worker recovery progress"))?;
            store.append(
                &job.meeting_id,
                event_types::JOB_PROGRESS,
                job.proposal_id.as_deref(),
                None,
                &job,
            )?;
        }
        if state.job_tx.send(QueuedJob { job: job.clone() }).is_err() {
            let store = state
                .store
                .lock()
                .map_err(|_| anyhow::anyhow!("lock store for worker recovery failure"))?;
            emit_job_failed(
                &store,
                &job,
                JobFailureReason::Unknown,
                "worker queue unavailable during recovery",
            )?;
        }
    }
    Ok(())
}

fn mark_job_recovered(mut job: AgentJobSpec, stale_worker_count: usize) -> AgentJobSpec {
    job.status = JobStatus::Queued;
    job.progress_note = Some(recovery_progress_note(stale_worker_count));
    job.failure_reason = None;
    job.error = None;
    job.receipt_path = None;
    job
}

fn recovery_progress_note(stale_worker_count: usize) -> String {
    if stale_worker_count == 0 {
        "recovered after daemon restart".to_string()
    } else {
        format!(
            "recovered after daemon restart; terminated {stale_worker_count} stale worker{}",
            if stale_worker_count == 1 { "" } else { "s" }
        )
    }
}

fn terminate_stale_worker_for_job(job: &AgentJobSpec, scratch_root: &FsPath) -> Result<usize> {
    let job_dir = scratch_root.join(&job.id);
    if !job_dir.exists() {
        return Ok(0);
    }
    let job_dirs = job_dir_match_candidates(&job_dir);

    let pids = stale_worker_pids_for_job(&job_dirs)?;
    for pid in &pids {
        terminate_process_if_still_matches(*pid, false, &job_dirs)?;
    }
    if !pids.is_empty() {
        thread::sleep(Duration::from_millis(200));
        for pid in stale_worker_pids_for_job(&job_dirs)? {
            terminate_process_if_still_matches(pid, true, &job_dirs)?;
        }
        let survivors = stale_worker_pids_for_job(&job_dirs)?;
        if !survivors.is_empty() {
            anyhow::bail!("stale worker processes survived termination: {survivors:?}");
        }
    }
    Ok(pids.len())
}

fn job_dir_match_candidates(job_dir: &FsPath) -> Vec<String> {
    let mut candidates = vec![job_dir.display().to_string()];
    if let Ok(canonical) = job_dir.canonicalize() {
        let canonical = canonical.display().to_string();
        if !candidates.iter().any(|candidate| candidate == &canonical) {
            candidates.push(canonical);
        }
    }
    candidates
}

fn stale_worker_pids_for_job(job_dirs: &[String]) -> Result<Vec<u32>> {
    let output = Command::new("ps")
        .args(["-axo", "pid=,command="])
        .output()
        .context("list worker processes")?;
    if !output.status.success() {
        anyhow::bail!("ps failed while listing worker processes");
    }
    Ok(parse_worker_pids_for_job(
        &String::from_utf8_lossy(&output.stdout),
        job_dirs,
    ))
}

fn parse_worker_pids_for_job(ps_output: &str, job_dirs: &[String]) -> Vec<u32> {
    ps_output
        .lines()
        .filter_map(|line| {
            let mut parts = line.trim_start().splitn(2, char::is_whitespace);
            let pid = parts.next()?.parse::<u32>().ok()?;
            let command = parts.next().unwrap_or_default();
            let workerish = command.contains("sandbox-exec") || command.contains("opencode");
            if pid != std::process::id()
                && workerish
                && command_references_job_dir(command, job_dirs)
            {
                Some(pid)
            } else {
                None
            }
        })
        .collect()
}

fn command_references_job_dir(command: &str, job_dirs: &[String]) -> bool {
    job_dirs
        .iter()
        .any(|job_dir| command_contains_path(command, job_dir))
}

fn command_contains_path(command: &str, path: &str) -> bool {
    command.match_indices(path).any(|(start, _)| {
        let bytes = command.as_bytes();
        let end = start + path.len();
        let before_ok = start == 0 || is_path_boundary(bytes[start - 1]);
        let after_ok = end == bytes.len() || is_path_boundary(bytes[end]);
        before_ok && after_ok
    })
}

fn is_path_boundary(byte: u8) -> bool {
    byte.is_ascii_whitespace() || matches!(byte, b'\'' | b'"' | b'=' | b':' | b',' | b'/' | b'\\')
}

fn pid_still_matches_worker(pid: u32, job_dirs: &[String]) -> Result<bool> {
    let output = Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "pid=,command="])
        .output()
        .context("inspect worker process before signal")?;
    if !output.status.success() {
        return Ok(false);
    }
    Ok(
        parse_worker_pids_for_job(&String::from_utf8_lossy(&output.stdout), job_dirs)
            .contains(&pid),
    )
}

fn terminate_process_if_still_matches(pid: u32, force: bool, job_dirs: &[String]) -> Result<()> {
    if !pid_still_matches_worker(pid, job_dirs)? {
        return Ok(());
    }
    let signal = if force { "-9" } else { "-TERM" };
    let status = Command::new("kill")
        .args([signal, &pid.to_string()])
        .status()
        .context("signal stale worker process")?;
    if status.success() {
        return Ok(());
    }
    tracing::warn!(pid, force, "stale worker process was already gone");
    Ok(())
}

/// Drain queued jobs and run each out-of-request. Every job opens its own SQLite
/// connection (WAL) so worker writes never block HTTP projection reads.
fn spawn_worker_loop(db_path: PathBuf, mut job_rx: mpsc::UnboundedReceiver<QueuedJob>) {
    let scratch_root = scratch_root();
    tokio::spawn(async move {
        while let Some(queued) = job_rx.recv().await {
            let db_path = db_path.clone();
            let scratch_root = scratch_root.clone();
            let job = queued.job;
            let fallback_job = job.clone();
            let fallback_db = db_path.clone();

            // Await each job so a panic or error in the runner can be turned into a
            // visible terminal event instead of a silently lost job.
            let result = tokio::task::spawn_blocking(move || -> Result<()> {
                let store = EventStore::open(&db_path)?;
                let profile = WorkerProfile::opencode();
                run_job(&store, &job, &profile, &scratch_root)?;
                Ok(())
            })
            .await;

            let failure = match result {
                Ok(Ok(())) => None,
                Ok(Err(err)) => Some(format!("worker error: {err}")),
                Err(join_err) => Some(format!("worker panicked: {join_err}")),
            };
            if let Some(detail) = failure {
                tracing::error!("{detail}");
                if let Ok(store) = EventStore::open(&fallback_db) {
                    let _ =
                        emit_job_failed(&store, &fallback_job, JobFailureReason::Unknown, &detail);
                }
            }
        }
    });
}

fn ui_dist_path() -> PathBuf {
    let candidate = FsPath::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../ui/dist")
        .canonicalize();
    candidate.unwrap_or_else(|_| PathBuf::from("ui/dist"))
}

type ApiResult<T> = Result<T, ApiError>;

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: message.into(),
        }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: message.into(),
        }
    }

    fn not_found(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message: message.into(),
        }
    }

    fn forbidden(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            message: message.into(),
        }
    }

    fn unauthorized(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: message.into(),
        }
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(value: anyhow::Error) -> Self {
        Self::internal(value.to_string())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(serde_json::json!({
                "error": self.message
            })),
        )
            .into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use standby_core::{DeliverableSpec, JobBudget, JobContext, PermissionProfile, WorkerKind};

    fn job(status: JobStatus) -> AgentJobSpec {
        AgentJobSpec {
            id: "job_test".to_string(),
            meeting_id: "meeting_test".to_string(),
            proposal_id: Some("proposal_test".to_string()),
            worker: WorkerKind::ResearchAgent,
            title: "Research".to_string(),
            prompt: "Do work".to_string(),
            context: JobContext {
                meeting_title: None,
                topic: None,
                approved_by: "tester".to_string(),
                transcript_spans: vec![],
                meeting_state_snapshot_id: None,
            },
            budget: JobBudget {
                max_minutes: 1,
                max_cost_usd: None,
            },
            deliverable: DeliverableSpec {
                description: "test".to_string(),
            },
            permissions: PermissionProfile {
                can_mutate_external_systems: false,
                requires_extra_approval: vec![],
            },
            status,
            profile: Some("opencode".to_string()),
            progress_note: Some("old progress".to_string()),
            failure_reason: Some(JobFailureReason::Unknown),
            error: Some("old error".to_string()),
            receipt_path: Some("/tmp/old/stdout.log".to_string()),
        }
    }

    #[test]
    fn mark_job_recovered_clears_stale_receipt_and_failure_state() {
        let recovered = mark_job_recovered(job(JobStatus::Running), 0);

        assert_eq!(recovered.status, JobStatus::Queued);
        assert_eq!(
            recovered.progress_note.as_deref(),
            Some("recovered after daemon restart")
        );
        assert!(recovered.failure_reason.is_none());
        assert!(recovered.error.is_none());
        assert!(recovered.receipt_path.is_none());
    }

    #[test]
    fn mark_job_recovered_records_stale_worker_cleanup() {
        let recovered = mark_job_recovered(job(JobStatus::Running), 2);

        assert_eq!(
            recovered.progress_note.as_deref(),
            Some("recovered after daemon restart; terminated 2 stale workers")
        );
    }

    #[test]
    fn parse_worker_pids_for_job_matches_worker_commands_for_job_dir_candidates() {
        let job_dirs = vec![
            "/tmp/standby/job_a".to_string(),
            "/private/tmp/standby/job_a".to_string(),
        ];
        let ps_output = "\
          123 sandbox-exec -f /tmp/standby/job_a/sandbox.sb opencode run --dir /tmp/standby/job_a
          124 opencode run --dir /private/tmp/standby/job_a --file /private/tmp/standby/job_a/prompt.txt
          456 opencode run --dir /tmp/standby/job_b
          789 bash /tmp/standby/job_a/not-a-worker
          abc opencode run --dir /tmp/standby/job_a
        ";

        assert_eq!(
            parse_worker_pids_for_job(ps_output, &job_dirs),
            vec![123, 124]
        );
    }

    #[test]
    fn command_references_job_dir_does_not_match_path_prefixes() {
        let job_dirs = vec!["/tmp/standby/job_a".to_string()];

        assert!(command_references_job_dir(
            "opencode run --dir /tmp/standby/job_a --file /tmp/standby/job_a/prompt.txt",
            &job_dirs
        ));
        assert!(command_references_job_dir(
            "sandbox-exec -f /tmp/standby/job_a/sandbox.sb opencode run",
            &job_dirs
        ));
        assert!(!command_references_job_dir(
            "opencode run --dir /tmp/standby/job_ab",
            &job_dirs
        ));
        assert!(!command_references_job_dir(
            "opencode run --dir /prefix/tmp/standby/job_a",
            &job_dirs
        ));
    }
}
