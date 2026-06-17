use crate::{
    AUDIO_ACTIVE_RMS, AgentJobSpec, Artifact, AudioLane, AudioLevel, Meeting, MeetingEvent,
    MeetingProjection, Proposal, SourceFailed, SourceFailure, SourceStarted, SourceState,
    SourceStatus, TranscriptSegment, TranscriptSourceKind, event_types, new_id, now_rfc3339ish,
};
use anyhow::{Context, Result};
use rusqlite::types::Type;
use rusqlite::{Connection, params};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use std::path::Path;

pub struct EventStore {
    connection: Connection,
}

impl EventStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let connection = Connection::open(path).context("open sqlite event store")?;
        // WAL + a busy timeout let the daemon's HTTP connection and the worker
        // loop's own connection read and write the same file concurrently.
        connection
            .execute_batch("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;")
            .context("configure sqlite concurrency")?;
        let store = Self { connection };
        store.migrate()?;
        Ok(store)
    }

    pub fn memory() -> Result<Self> {
        let connection = Connection::open_in_memory().context("open in-memory sqlite store")?;
        let store = Self { connection };
        store.migrate()?;
        Ok(store)
    }

    pub fn append<T: Serialize>(
        &self,
        meeting_id: &str,
        event_type: &str,
        trace_id: Option<&str>,
        parent_event_id: Option<&str>,
        payload: &T,
    ) -> Result<MeetingEvent> {
        let payload_json = serde_json::to_value(payload).context("serialize event payload")?;
        let event = MeetingEvent {
            id: new_id("evt"),
            meeting_id: meeting_id.to_string(),
            event_type: event_type.to_string(),
            trace_id: trace_id.map(ToOwned::to_owned),
            parent_event_id: parent_event_id.map(ToOwned::to_owned),
            payload_json,
            created_at: now_rfc3339ish(),
        };
        self.connection.execute(
            "insert into meeting_events
                (id, meeting_id, event_type, trace_id, parent_event_id, payload_json, created_at)
             values (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                event.id,
                event.meeting_id,
                event.event_type,
                event.trace_id,
                event.parent_event_id,
                event.payload_json.to_string(),
                event.created_at,
            ],
        )?;
        Ok(event)
    }

    pub fn list_events(&self, meeting_id: &str) -> Result<Vec<MeetingEvent>> {
        let mut statement = self.connection.prepare(
            "select id, meeting_id, event_type, trace_id, parent_event_id, payload_json, created_at
             from meeting_events
             where meeting_id = ?1
             order by rowid asc",
        )?;

        let rows = statement.query_map([meeting_id], |row| {
            let payload_text: String = row.get(5)?;
            let payload_json = serde_json::from_str::<Value>(&payload_text).map_err(|err| {
                rusqlite::Error::FromSqlConversionFailure(5, Type::Text, Box::new(err))
            })?;
            Ok(MeetingEvent {
                id: row.get(0)?,
                meeting_id: row.get(1)?,
                event_type: row.get(2)?,
                trace_id: row.get(3)?,
                parent_event_id: row.get(4)?,
                payload_json,
                created_at: row.get(6)?,
            })
        })?;

        rows.collect::<std::result::Result<Vec<_>, _>>()
            .context("list meeting events")
    }

    pub fn projection(&self, meeting_id: &str) -> Result<MeetingProjection> {
        let events = self.list_events(meeting_id)?;
        let mut transcript = Vec::new();
        let mut proposals = Vec::new();
        let mut jobs = Vec::new();
        let mut artifacts = Vec::new();
        let mut partial: Option<TranscriptSegment> = None;
        let mut source = SourceState::default();
        let mut title: Option<String> = None;

        for event in &events {
            match event.event_type.as_str() {
                event_types::MEETING_STARTED => {
                    let meeting: Meeting = decode(&event.payload_json)?;
                    if meeting.title.is_some() {
                        title = meeting.title;
                    }
                    if let Some(mode) = meeting.mode {
                        source.mode = Some(mode);
                    }
                }
                event_types::SOURCE_STARTED => {
                    let started: SourceStarted = decode(&event.payload_json)?;
                    let (mic, system) = started.mode.lanes();
                    source.source = Some(started.source);
                    source.mode = Some(started.mode);
                    source.microphone.expected = mic;
                    source.system_audio.expected = system;
                    source.started = true;
                    source.stopped = false;
                    source.failure = None;
                    source.status = SourceStatus::Capturing;
                }
                event_types::AUDIO_LEVEL => {
                    let level: AudioLevel = decode(&event.payload_json)?;
                    let lane = match level.lane {
                        AudioLane::Microphone => &mut source.microphone,
                        AudioLane::SystemAudio => &mut source.system_audio,
                    };
                    lane.expected = true;
                    lane.last_rms = Some(level.rms);
                    lane.captured_ms = lane.captured_ms.max(level.captured_ms);
                    lane.level_events += 1;
                    if level.rms >= AUDIO_ACTIVE_RMS {
                        lane.active = true;
                    }
                }
                event_types::SEGMENT_PARTIAL => {
                    let segment: TranscriptSegment = decode(&event.payload_json)?;
                    partial = Some(segment);
                    if matches!(source.status, SourceStatus::Capturing) {
                        source.status = SourceStatus::Transcribing;
                    }
                }
                event_types::SEGMENT_FINAL => {
                    let segment: TranscriptSegment = decode(&event.payload_json)?;
                    partial = None;
                    if matches!(source.status, SourceStatus::Capturing) {
                        source.status = SourceStatus::Transcribing;
                    }
                    transcript.push(segment);
                }
                event_types::SOURCE_FAILED => {
                    let failed: SourceFailed = decode(&event.payload_json)?;
                    source.source = Some(failed.source);
                    source.failure = Some(SourceFailure {
                        reason: failed.reason,
                        lane: failed.lane,
                        detail: failed.detail,
                    });
                    source.status = SourceStatus::Failed;
                }
                event_types::SOURCE_STOPPED => {
                    source.stopped = true;
                    if source.status != SourceStatus::Failed {
                        source.status = SourceStatus::Stopped;
                    }
                }
                event_types::PROPOSAL_CREATED
                | event_types::PROPOSAL_APPROVED
                | event_types::PROPOSAL_IGNORED => {
                    upsert_by_id(&mut proposals, decode::<Proposal>(&event.payload_json)?);
                }
                event_types::JOB_REQUESTED
                | event_types::JOB_STARTED
                | event_types::JOB_PROGRESS
                | event_types::JOB_COMPLETED
                | event_types::JOB_FAILED
                | event_types::JOB_CANCELED => {
                    upsert_by_id(&mut jobs, decode::<AgentJobSpec>(&event.payload_json)?);
                }
                event_types::ARTIFACT_CREATED => artifacts.push(decode(&event.payload_json)?),
                _ => {}
            }
        }

        derive_source_status(&mut source, &transcript);

        Ok(MeetingProjection {
            meeting_id: meeting_id.to_string(),
            title,
            transcript,
            partial,
            source,
            proposals,
            jobs,
            artifacts,
            events,
        })
    }

    pub fn has_event_type(&self, meeting_id: &str, event_type: &str) -> Result<bool> {
        let count: i64 = self.connection.query_row(
            "select count(*) from meeting_events where meeting_id = ?1 and event_type = ?2",
            params![meeting_id, event_type],
            |row| row.get(0),
        )?;
        Ok(count > 0)
    }

    pub fn find_latest_proposal(&self, proposal_id: &str) -> Result<Option<Proposal>> {
        let mut statement = self.connection.prepare(
            "select payload_json
             from meeting_events
             where event_type in ('proposal.created', 'proposal.approved', 'proposal.ignored')
             order by rowid desc",
        )?;

        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        for row in rows {
            let payload_text = row?;
            let proposal: Proposal =
                serde_json::from_str(&payload_text).context("decode proposal event")?;
            if proposal.id == proposal_id {
                return Ok(Some(proposal));
            }
        }

        Ok(None)
    }

    fn migrate(&self) -> Result<()> {
        self.connection.execute_batch(
            "create table if not exists meeting_events (
                id text primary key,
                meeting_id text not null,
                event_type text not null,
                trace_id text,
                parent_event_id text,
                payload_json text not null,
                created_at text not null
            );
            create index if not exists meeting_events_meeting_idx
                on meeting_events (meeting_id, created_at);
            create table if not exists projections (
                name text primary key,
                version integer not null,
                state_json text not null,
                updated_at text not null
            );",
        )?;
        Ok(())
    }
}

fn decode<T: DeserializeOwned>(value: &Value) -> Result<T> {
    serde_json::from_value(value.clone()).context("decode event payload")
}

/// Resolve the final honest source status from replayed facts. Distinguishes
/// demo seeding (no real source) from a silent lane during live capture.
fn derive_source_status(source: &mut SourceState, transcript: &[TranscriptSegment]) {
    if !source.started && source.failure.is_none() {
        if transcript
            .iter()
            .any(|segment| segment.source == TranscriptSourceKind::Demo)
        {
            source.status = SourceStatus::Demo;
        } else if source.mode.is_some() {
            // meeting.started recorded, but the helper has not reported source.started
            // yet — it is acquiring microphone / screen-recording permission.
            source.status = SourceStatus::WaitingPermission;
        }
        return;
    }

    if source.stopped || source.failure.is_some() {
        return;
    }

    // A lane that has reported levels but never crossed the active threshold is
    // an expected-but-silent lane: surface it instead of pretending it's live.
    let mic_silent = source.microphone.expected
        && !source.microphone.active
        && source.microphone.level_events > 0;
    let system_silent = source.system_audio.expected
        && !source.system_audio.active
        && source.system_audio.level_events > 0;

    if matches!(
        source.status,
        SourceStatus::Capturing | SourceStatus::Transcribing
    ) {
        if system_silent && !mic_silent {
            source.status = SourceStatus::NoSystemAudio;
        } else if mic_silent && !system_silent {
            source.status = SourceStatus::NoMicAudio;
        }
    }
}

fn upsert_by_id<T>(items: &mut Vec<T>, item: T)
where
    T: HasId,
{
    if let Some(existing) = items.iter_mut().find(|existing| existing.id() == item.id()) {
        *existing = item;
    } else {
        items.push(item);
    }
}

trait HasId {
    fn id(&self) -> &str;
}

impl HasId for Proposal {
    fn id(&self) -> &str {
        &self.id
    }
}

impl HasId for AgentJobSpec {
    fn id(&self) -> &str {
        &self.id
    }
}

impl HasId for Artifact {
    fn id(&self) -> &str {
        &self.id
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        AudioLane, AudioLevel, CaptureMode, ProposalKind, ProposalStatus, SourceFailed,
        SourceFailureReason, SourceStarted, SourceStatus, TranscriptSourceKind, WorkerKind,
        demo_segments,
    };

    fn seg(
        meeting: &str,
        id: &str,
        text: &str,
        is_final: bool,
        source: TranscriptSourceKind,
    ) -> TranscriptSegment {
        TranscriptSegment {
            id: id.to_string(),
            meeting_id: meeting.to_string(),
            speaker: Some("me".to_string()),
            start_ms: 0,
            end_ms: 1_000,
            text: text.to_string(),
            is_final,
            confidence: None,
            source,
        }
    }

    #[test]
    fn projection_reports_no_system_audio_when_system_lane_silent() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_no_sys";
        store
            .append(
                meeting,
                event_types::SOURCE_STARTED,
                None,
                None,
                &SourceStarted {
                    meeting_id: meeting.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                    mode: CaptureMode::MicAndSystem,
                },
            )
            .unwrap();
        store
            .append(
                meeting,
                event_types::AUDIO_LEVEL,
                None,
                None,
                &AudioLevel {
                    meeting_id: meeting.to_string(),
                    lane: AudioLane::Microphone,
                    rms: 0.08,
                    peak: Some(0.2),
                    captured_ms: 1_000,
                },
            )
            .unwrap();
        store
            .append(
                meeting,
                event_types::AUDIO_LEVEL,
                None,
                None,
                &AudioLevel {
                    meeting_id: meeting.to_string(),
                    lane: AudioLane::SystemAudio,
                    rms: 0.0,
                    peak: Some(0.0),
                    captured_ms: 1_000,
                },
            )
            .unwrap();

        let projection = store.projection(meeting).unwrap();
        assert_eq!(projection.source.status, SourceStatus::NoSystemAudio);
        assert!(projection.source.microphone.active);
        assert!(!projection.source.system_audio.active);
        assert!(projection.source.system_audio.expected);
    }

    #[test]
    fn projection_tracks_partial_then_final_segment() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_partial";
        store
            .append(
                meeting,
                event_types::SOURCE_STARTED,
                None,
                None,
                &SourceStarted {
                    meeting_id: meeting.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                    mode: CaptureMode::Mic,
                },
            )
            .unwrap();
        store
            .append(
                meeting,
                event_types::SEGMENT_PARTIAL,
                None,
                None,
                &seg(meeting, "s1", "lets research", false, TranscriptSourceKind::LocalMac),
            )
            .unwrap();

        let mid = store.projection(meeting).unwrap();
        assert_eq!(mid.source.status, SourceStatus::Transcribing);
        assert!(mid.partial.is_some());
        assert_eq!(mid.transcript.len(), 0);

        store
            .append(
                meeting,
                event_types::SEGMENT_FINAL,
                None,
                None,
                &seg(
                    meeting,
                    "s1",
                    "lets research prior art",
                    true,
                    TranscriptSourceKind::LocalMac,
                ),
            )
            .unwrap();

        let done = store.projection(meeting).unwrap();
        assert!(done.partial.is_none());
        assert_eq!(done.transcript.len(), 1);
        assert!(done.transcript[0].is_final);
    }

    #[test]
    fn projection_marks_demo_status_for_seeded_demo_segments() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_demo";
        for segment in demo_segments(meeting) {
            store
                .append(meeting, event_types::SEGMENT_FINAL, None, None, &segment)
                .unwrap();
        }
        let projection = store.projection(meeting).unwrap();
        assert_eq!(projection.source.status, SourceStatus::Demo);
        assert!(!projection.source.started);
    }

    #[test]
    fn projection_reports_waiting_permission_after_meeting_started() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_wait";
        store
            .append(
                meeting,
                event_types::MEETING_STARTED,
                None,
                None,
                &crate::Meeting {
                    id: meeting.to_string(),
                    title: None,
                    mode: Some(CaptureMode::MicAndSystem),
                },
            )
            .unwrap();
        let projection = store.projection(meeting).unwrap();
        assert_eq!(projection.source.status, SourceStatus::WaitingPermission);
    }

    #[test]
    fn projection_surfaces_source_failure_reason() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_fail";
        store
            .append(
                meeting,
                event_types::SOURCE_STARTED,
                None,
                None,
                &SourceStarted {
                    meeting_id: meeting.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                    mode: CaptureMode::MicAndSystem,
                },
            )
            .unwrap();
        store
            .append(
                meeting,
                event_types::SOURCE_FAILED,
                None,
                None,
                &SourceFailed {
                    meeting_id: meeting.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                    reason: SourceFailureReason::ScreenRecordingPermissionDenied,
                    lane: Some(AudioLane::SystemAudio),
                    detail: Some("screen recording permission denied".to_string()),
                },
            )
            .unwrap();

        let projection = store.projection(meeting).unwrap();
        assert_eq!(projection.source.status, SourceStatus::Failed);
        let failure = projection.source.failure.expect("failure present");
        assert_eq!(
            failure.reason,
            SourceFailureReason::ScreenRecordingPermissionDenied
        );
        assert_eq!(failure.lane, Some(AudioLane::SystemAudio));
    }

    #[test]
    fn projection_replays_latest_proposal_state() {
        let store = EventStore::memory().unwrap();
        let mut proposal = Proposal {
            id: "prop_test".to_string(),
            meeting_id: "meeting_test".to_string(),
            kind: ProposalKind::Research,
            title: "Research prior art".to_string(),
            rationale: "Concrete ask".to_string(),
            draft_prompt: "Research this".to_string(),
            evidence: vec![],
            suggested_worker: WorkerKind::ResearchAgent,
            confidence: 0.84,
            status: ProposalStatus::Proposed,
        };

        store
            .append("meeting_test", "proposal.created", None, None, &proposal)
            .unwrap();
        proposal.status = ProposalStatus::Approved;
        store
            .append("meeting_test", "proposal.approved", None, None, &proposal)
            .unwrap();

        let projection = store.projection("meeting_test").unwrap();
        assert_eq!(projection.proposals.len(), 1);
        assert_eq!(projection.proposals[0].status, ProposalStatus::Approved);
    }
}
