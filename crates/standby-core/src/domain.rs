use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static ID_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TranscriptSourceKind {
    Demo,
    Bot,
    Platform,
    LocalMac,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProposalKind {
    Research,
    Coding,
    Doc,
    Followup,
    Question,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum WorkerKind {
    ResearchAgent,
    Codex,
    ClaudeCode,
    Pi,
    Local,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProposalStatus {
    Proposed,
    Approved,
    Ignored,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobStatus {
    Queued,
    Running,
    NeedsInput,
    Completed,
    Failed,
    Canceled,
}

/// How the local capture path was asked to listen. Mirrors the native helper's
/// `--mode` argument; provider adapters may add their own modes later.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum CaptureMode {
    Mic,
    System,
    #[default]
    MicAndSystem,
}

impl CaptureMode {
    /// Which lanes a mode is expected to produce, as `(microphone, system_audio)`.
    pub fn lanes(&self) -> (bool, bool) {
        match self {
            CaptureMode::Mic => (true, false),
            CaptureMode::System => (false, true),
            CaptureMode::MicAndSystem => (true, true),
        }
    }

    /// Parse a helper-style mode string such as `mic`, `system`, or `mic+system`.
    pub fn parse(mode: &str) -> CaptureMode {
        let mic = mode.contains("mic");
        let system = mode.contains("system");
        match (mic, system) {
            (true, false) => CaptureMode::Mic,
            (false, true) => CaptureMode::System,
            _ => CaptureMode::MicAndSystem,
        }
    }
}

/// A single capture lane. Local capture only distinguishes `me` (microphone)
/// from `system_audio`; richer speaker identity is a provider-adapter concern.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AudioLane {
    Microphone,
    SystemAudio,
}

/// The honest, projected state of the capture source. The UI must never show a
/// generic "Live" when the real state is one of these.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum SourceStatus {
    #[default]
    Idle,
    Demo,
    WaitingPermission,
    Capturing,
    Transcribing,
    NoMicAudio,
    NoSystemAudio,
    Failed,
    Stopped,
}

/// Why a capture source failed. Permission reasons are specific so the UI can
/// tell the operator exactly which macOS permission to grant. System audio has
/// TWO distinct permission tiers: `ScreenRecordingPermissionDenied` is the
/// ScreenCaptureKit fallback's "Screen & System Audio Recording" grant;
/// `SystemAudioPermissionDenied` is the Core Audio tap's separate "System Audio
/// Recording Only" grant (`kTCCServiceAudioCapture`). They live in different
/// Settings panes, so the UI must name the right one.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SourceFailureReason {
    MicPermissionDenied,
    ScreenRecordingPermissionDenied,
    /// Core Audio process-tap tier ("System Audio Recording Only").
    SystemAudioPermissionDenied,
    /// Core Audio taps need macOS 14.4+; below that the tap lane is unavailable.
    SystemAudioUnsupportedOs,
    NoInputDevice,
    HelperCrashed,
    Unsupported,
    Unknown,
}

/// Why an agent job failed. Drives a visible failure card with a receipt path,
/// never a silent spinner.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobFailureReason {
    CliNotFound,
    AuthRequired,
    Timeout,
    NonzeroExit,
    SandboxViolation,
    Canceled,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct SourceFailure {
    pub reason: SourceFailureReason,
    pub lane: Option<AudioLane>,
    pub detail: Option<String>,
}

/// Projected activity for a single capture lane. `active` flips true only after
/// a level event at or above [`AUDIO_ACTIVE_RMS`]; `level_events > 0 && !active`
/// is the signal for an expected-but-silent lane (no-mic / no-system-audio).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
pub struct LaneState {
    pub expected: bool,
    pub active: bool,
    pub last_rms: Option<f32>,
    pub captured_ms: u64,
    pub level_events: u32,
    /// Cumulative transcriber-bound buffers dropped on overflow. Nonzero means
    /// lost transcript — surfaced honestly, never silent.
    pub dropped: u32,
}

/// The projected capture state for a meeting, derived from source/audio events.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
pub struct SourceState {
    pub status: SourceStatus,
    pub source: Option<TranscriptSourceKind>,
    pub mode: Option<CaptureMode>,
    pub microphone: LaneState,
    pub system_audio: LaneState,
    pub failure: Option<SourceFailure>,
    pub started: bool,
    pub stopped: bool,
}

/// `meeting.started` payload — carries the honest meeting title and mode instead
/// of a hard-coded demo title.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Meeting {
    pub id: String,
    pub title: Option<String>,
    pub mode: Option<CaptureMode>,
}

/// `transcript.source.started` payload.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct SourceStarted {
    pub meeting_id: String,
    pub source: TranscriptSourceKind,
    pub mode: CaptureMode,
}

/// `transcript.source.failed` payload.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct SourceFailed {
    pub meeting_id: String,
    pub source: TranscriptSourceKind,
    pub reason: SourceFailureReason,
    pub lane: Option<AudioLane>,
    pub detail: Option<String>,
}

/// `transcript.source.stopped` payload.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct SourceStopped {
    pub meeting_id: String,
    pub source: TranscriptSourceKind,
}

/// `audio.source.level` payload — one sanitized loudness sample for a lane.
/// Carries no audio content, only metrics.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct AudioLevel {
    pub meeting_id: String,
    pub lane: AudioLane,
    pub rms: f32,
    pub peak: Option<f32>,
    pub captured_ms: u64,
}

/// `audio.source.dropped` payload — cumulative count of transcriber-bound buffers
/// dropped on overflow for a lane. Carries no audio content, only the counter.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct AudioDropped {
    pub meeting_id: String,
    pub lane: AudioLane,
    pub count: u32,
}

/// RMS at or above this counts a lane as carrying real audio.
pub const AUDIO_ACTIVE_RMS: f32 = 0.005;

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct TranscriptSegment {
    pub id: String,
    pub meeting_id: String,
    pub speaker: Option<String>,
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
    pub is_final: bool,
    pub confidence: Option<f32>,
    pub source: TranscriptSourceKind,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct TranscriptEvidence {
    pub segment_id: String,
    pub speaker: Option<String>,
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
}

impl From<&TranscriptSegment> for TranscriptEvidence {
    fn from(segment: &TranscriptSegment) -> Self {
        Self {
            segment_id: segment.id.clone(),
            speaker: segment.speaker.clone(),
            start_ms: segment.start_ms,
            end_ms: segment.end_ms,
            text: segment.text.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Proposal {
    pub id: String,
    pub meeting_id: String,
    pub kind: ProposalKind,
    pub title: String,
    pub rationale: String,
    pub draft_prompt: String,
    pub evidence: Vec<TranscriptEvidence>,
    pub suggested_worker: WorkerKind,
    pub confidence: f32,
    pub status: ProposalStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct JobBudget {
    pub max_minutes: u16,
    pub max_cost_usd: Option<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct JobContext {
    pub meeting_title: Option<String>,
    pub topic: Option<String>,
    pub approved_by: String,
    pub transcript_spans: Vec<String>,
    pub meeting_state_snapshot_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct DeliverableSpec {
    pub description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct PermissionProfile {
    pub can_mutate_external_systems: bool,
    pub requires_extra_approval: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct AgentJobSpec {
    pub id: String,
    pub meeting_id: String,
    pub proposal_id: Option<String>,
    pub worker: WorkerKind,
    pub title: String,
    pub prompt: String,
    pub context: JobContext,
    pub budget: JobBudget,
    pub deliverable: DeliverableSpec,
    pub permissions: PermissionProfile,
    pub status: JobStatus,
    /// Worker profile id that ran (or will run) this job, e.g. `claude-research`.
    #[serde(default)]
    pub profile: Option<String>,
    /// Latest human-readable progress note streamed from the worker.
    #[serde(default)]
    pub progress_note: Option<String>,
    /// Why the job failed, when it did. Pairs with `error` + `receipt_path`.
    #[serde(default)]
    pub failure_reason: Option<JobFailureReason>,
    /// Failure detail (sanitized stderr tail or sandbox-denial message).
    #[serde(default)]
    pub error: Option<String>,
    /// Path to the on-disk receipt (stdout/stderr/exit) under the job scratch.
    #[serde(default)]
    pub receipt_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Artifact {
    pub id: String,
    pub job_id: String,
    pub title: String,
    pub summary: String,
    pub uri: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct MeetingEvent {
    pub id: String,
    pub meeting_id: String,
    pub event_type: String,
    pub trace_id: Option<String>,
    pub parent_event_id: Option<String>,
    pub payload_json: Value,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct MeetingProjection {
    pub meeting_id: String,
    pub title: Option<String>,
    pub transcript: Vec<TranscriptSegment>,
    /// The latest in-flight partial segment, if transcription is mid-utterance.
    /// Cleared when its final segment lands.
    #[serde(default)]
    pub partial: Option<TranscriptSegment>,
    /// Honest capture state for the meeting (status, lanes, failure).
    #[serde(default)]
    pub source: SourceState,
    pub proposals: Vec<Proposal>,
    pub jobs: Vec<AgentJobSpec>,
    pub artifacts: Vec<Artifact>,
    pub events: Vec<MeetingEvent>,
}

pub fn new_id(prefix: &str) -> String {
    // Globally unique across daemon restarts: the per-process counter resets to 1
    // on restart, so millisecond + counter alone could collide between two
    // meetings and make a by-id lookup resolve the wrong one. Nanoseconds + pid
    // make a collision practically impossible.
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let counter = ID_COUNTER.fetch_add(1, Ordering::Relaxed);
    let pid = std::process::id();
    format!("{prefix}_{now:x}_{pid:x}_{counter:x}")
}

pub fn now_rfc3339ish() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{:03}Z", now.as_secs(), now.subsec_millis())
}

/// Canonical event-type strings. Every producer (daemon, capture source, worker
/// runner) and the projection use these so the taxonomy can't drift by typo.
pub mod event_types {
    pub const MEETING_STARTED: &str = "meeting.started";
    pub const SOURCE_STARTED: &str = "transcript.source.started";
    pub const SOURCE_FAILED: &str = "transcript.source.failed";
    pub const SOURCE_STOPPED: &str = "transcript.source.stopped";
    pub const AUDIO_LEVEL: &str = "audio.source.level";
    pub const AUDIO_DROPPED: &str = "audio.source.dropped";
    pub const SEGMENT_PARTIAL: &str = "transcript.segment.partial";
    pub const SEGMENT_FINAL: &str = "transcript.segment.final";
    pub const PROPOSAL_CREATED: &str = "proposal.created";
    pub const PROPOSAL_APPROVED: &str = "proposal.approved";
    pub const PROPOSAL_IGNORED: &str = "proposal.ignored";
    pub const JOB_REQUESTED: &str = "agent_job.requested";
    pub const JOB_STARTED: &str = "agent_job.started";
    pub const JOB_PROGRESS: &str = "agent_job.progress";
    pub const JOB_COMPLETED: &str = "agent_job.completed";
    pub const JOB_FAILED: &str = "agent_job.failed";
    pub const JOB_CANCELED: &str = "agent_job.canceled";
    pub const ARTIFACT_CREATED: &str = "artifact.created";
}

pub fn demo_segments(meeting_id: &str) -> Vec<TranscriptSegment> {
    let rows = [
        (
            "Maya Patel",
            0,
            16_000,
            "Before we build this, I want to sanity check: has anyone seen anything like this in the market already?",
        ),
        (
            "Jordan Smith",
            17_000,
            30_000,
            "Good call. We should do a quick prior art sweep, focus on productized meeting copilots with local-first guarantees.",
        ),
        (
            "Alex Chen",
            31_000,
            40_000,
            "Especially ones that run agents locally. Let's scope to the last 18 months.",
        ),
        (
            "Riley Johnson",
            41_000,
            50_000,
            "And include open source plus YC companies. Budget eight minutes?",
        ),
        (
            "Maya Patel",
            51_000,
            60_000,
            "Perfect. Please capture the reasoning and key differentiators.",
        ),
    ];

    rows.iter()
        .enumerate()
        .map(
            |(index, (speaker, start_ms, end_ms, text))| TranscriptSegment {
                id: format!("span_{index}"),
                meeting_id: meeting_id.to_string(),
                speaker: Some((*speaker).to_string()),
                start_ms: *start_ms,
                end_ms: *end_ms,
                text: (*text).to_string(),
                is_final: true,
                confidence: Some(0.96),
                source: TranscriptSourceKind::Demo,
            },
        )
        .collect()
}
