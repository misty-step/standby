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
    pub proposals: Vec<Proposal>,
    pub jobs: Vec<AgentJobSpec>,
    pub artifacts: Vec<Artifact>,
    pub events: Vec<MeetingEvent>,
}

pub fn new_id(prefix: &str) -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let counter = ID_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_{now:x}_{counter:x}")
}

pub fn now_rfc3339ish() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{:03}Z", now.as_secs(), now.subsec_millis())
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
