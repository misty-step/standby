use anyhow::{Context, Result};
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use standby_core::{
    EventStore, MeetingProjection, MockResearchWorker, ProposalEngine, ProposalStatus,
    demo_meeting_segments,
};
use std::net::SocketAddr;
use std::path::{Path as FsPath, PathBuf};
use std::sync::{Arc, Mutex};
use tower_http::cors::CorsLayer;
use tower_http::services::ServeDir;
use tower_http::trace::TraceLayer;
use tracing::info;
use tracing_subscriber::EnvFilter;

#[derive(Clone)]
struct AppState {
    store: Arc<Mutex<EventStore>>,
}

#[derive(Debug, Deserialize)]
struct ApproveRequest {
    approved_by: Option<String>,
    prompt: Option<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    let state = AppState {
        store: Arc::new(Mutex::new(open_store()?)),
    };

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
        .route("/api/meetings/{meeting_id}", get(meeting_projection))
        .route("/api/meetings/{meeting_id}/events", get(meeting_projection))
        .route("/api/proposals/{proposal_id}/approve", post(approve))
        .route("/api/proposals/{proposal_id}/ignore", post(ignore))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "ok",
        "service": "standbyd"
    }))
}

async fn start_demo(
    State(state): State<AppState>,
    Path(meeting_id): Path<String>,
) -> ApiResult<Json<MeetingProjection>> {
    let store = state
        .store
        .lock()
        .map_err(|_| ApiError::internal("lock store"))?;
    if !store.has_event_type(&meeting_id, "transcript.segment.final")? {
        for segment in demo_meeting_segments(&meeting_id) {
            store.append(
                &meeting_id,
                "transcript.segment.final",
                Some(&meeting_id),
                None,
                &segment,
            )?;
        }
    }

    let projection = store.projection(&meeting_id)?;
    if !store.has_event_type(&meeting_id, "proposal.created")? {
        if let Some(proposal) = ProposalEngine::detect_research_proposal(
            &meeting_id,
            &projection.transcript,
            &projection.proposals,
        ) {
            store.append(
                &meeting_id,
                "proposal.created",
                Some(&proposal.id),
                None,
                &proposal,
            )?;
        }
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

async fn approve(
    State(state): State<AppState>,
    Path(proposal_id): Path<String>,
    Json(request): Json<ApproveRequest>,
) -> ApiResult<Json<MeetingProjection>> {
    let store = state
        .store
        .lock()
        .map_err(|_| ApiError::internal("lock store"))?;
    let proposal = store
        .find_latest_proposal(&proposal_id)?
        .ok_or_else(|| ApiError::not_found(format!("proposal {proposal_id}")))?;

    if proposal.status != ProposalStatus::Approved {
        MockResearchWorker::approve_and_run(
            &store,
            &proposal,
            request.approved_by.as_deref().unwrap_or("Phaedrus"),
            request.prompt,
        )?;
    }

    Ok(Json(store.projection(&proposal.meeting_id)?))
}

async fn ignore(
    State(state): State<AppState>,
    Path(proposal_id): Path<String>,
) -> ApiResult<Json<MeetingProjection>> {
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
        "proposal.ignored",
        Some(&proposal.id),
        None,
        &proposal,
    )?;

    Ok(Json(store.projection(&proposal.meeting_id)?))
}

fn open_store() -> Result<EventStore> {
    let path = std::env::var("STANDBY_DB")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(".standby/standby.db"));
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).context("create standby data dir")?;
    }
    EventStore::open(path)
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
