use crate::JobStatus;
use crate::{
    AUDIO_ACTIVE_RMS, AgentJobSpec, Artifact, AudioDropped, AudioLane, AudioLevel, Meeting,
    MeetingEvent, MeetingProjection, NetworkWorkerConsent, NoProposal, Proposal, ProposalRequest,
    SourceFailed, SourceFailure, SourceStarted, SourceState, SourceStatus, SourceStopped,
    TranscriptSegment,
    TranscriptSourceKind, event_types, new_id, now_rfc3339ish,
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
        let mut proposal_requests = Vec::new();
        let mut no_proposals = Vec::new();
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
                event_types::AUDIO_DROPPED => {
                    let dropped: AudioDropped = decode(&event.payload_json)?;
                    let lane = match dropped.lane {
                        AudioLane::Microphone => &mut source.microphone,
                        AudioLane::SystemAudio => &mut source.system_audio,
                    };
                    // Helper emits a cumulative count; max is robust to ordering.
                    lane.dropped = lane.dropped.max(dropped.count);
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
                    // Only clear the in-flight partial if it belongs to the same
                    // speaker/lane, so a final on one lane doesn't wipe another
                    // lane's live partial.
                    if partial
                        .as_ref()
                        .is_some_and(|current| current.speaker == segment.speaker)
                    {
                        partial = None;
                    }
                    if matches!(source.status, SourceStatus::Capturing) {
                        source.status = SourceStatus::Transcribing;
                    }
                    transcript.push(segment);
                }
                event_types::SOURCE_FAILED => {
                    let failed: SourceFailed = decode(&event.payload_json)?;
                    source.source = Some(failed.source);
                    // Mark the specific lane that failed.
                    match failed.lane {
                        Some(AudioLane::Microphone) => source.microphone.failed = true,
                        Some(AudioLane::SystemAudio) => source.system_audio.failed = true,
                        None => {}
                    }
                    // A system-audio failure is PER-LANE when the mic lane is also
                    // expected: the mic keeps capturing, so the whole capture is not
                    // failed. Record the failure for display but leave the status to
                    // the surviving lane / a later stop. Any other failure (mic, or
                    // system-only) fails the whole source.
                    let system_lane_only =
                        failed.lane == Some(AudioLane::SystemAudio) && source.microphone.expected;
                    source.failure = Some(SourceFailure {
                        reason: failed.reason,
                        lane: failed.lane,
                        detail: failed.detail,
                    });
                    if !system_lane_only {
                        source.status = SourceStatus::Failed;
                        // No in-flight utterance survives a whole-source failure.
                        partial = None;
                    }
                }
                event_types::SOURCE_STOPPED => {
                    source.stopped = true;
                    if source.status != SourceStatus::Failed {
                        source.status = SourceStatus::Stopped;
                    }
                    // No ghost partial under a stopped meeting.
                    partial = None;
                }
                event_types::PROPOSAL_REQUEST_CREATED => {
                    proposal_requests.push(decode::<ProposalRequest>(&event.payload_json)?);
                }
                event_types::PROPOSAL_NOT_CREATED => {
                    no_proposals.push(decode::<NoProposal>(&event.payload_json)?);
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
            proposal_requests,
            no_proposals,
            proposals,
            jobs,
            artifacts,
            events,
        })
    }

    /// Distinct meeting ids present in the ledger.
    pub fn meeting_ids(&self) -> Result<Vec<String>> {
        let mut stmt = self
            .connection
            .prepare("select distinct meeting_id from meeting_events order by meeting_id")?;
        let ids = stmt
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(ids)
    }

    /// Reconcile a capture the ledger shows as running but that has no live
    /// helper — after a daemon restart (the in-memory pid map starts empty) or a
    /// stop for a meeting with no live process. Appends `source.stopped` when the
    /// meeting is stuck started / not-stopped / not-failed, so the UI never sits
    /// on a false "capturing" state it cannot clear. Idempotent.
    pub fn reconcile_stopped_if_orphaned(&self, meeting_id: &str) -> Result<bool> {
        let source = self.projection(meeting_id)?.source;
        // Reconcile anything the ledger still treats as live (capturing /
        // transcribing) — including a source kept alive by one lane after a
        // per-lane failure. A whole-source `Failed` is already terminal and must
        // not be masked as a clean stop; a waiting-permission meeting has
        // started == false and is left for a fresh Start to re-init.
        if source.started && !source.stopped && source.status != SourceStatus::Failed {
            self.append(
                meeting_id,
                event_types::SOURCE_STOPPED,
                Some(meeting_id),
                None,
                &SourceStopped {
                    meeting_id: meeting_id.to_string(),
                    source: source.source.unwrap_or(TranscriptSourceKind::LocalMac),
                },
            )?;
            return Ok(true);
        }
        Ok(false)
    }

    /// Reconcile every meeting the ledger still treats as live to
    /// `source.stopped`. On daemon boot no helper can be running yet, so any
    /// such meeting was orphaned by a prior exit. Tolerates a malformed or
    /// schema-evolved event in any single meeting's history (skips that meeting)
    /// so one bad payload can never block startup — mirroring `recoverable_jobs`.
    /// Returns the ids that were reconciled.
    pub fn reconcile_orphaned_captures(&self) -> Result<Vec<String>> {
        let mut reconciled = Vec::new();
        for meeting_id in self.meeting_ids()? {
            match self.reconcile_stopped_if_orphaned(&meeting_id) {
                Ok(true) => reconciled.push(meeting_id),
                Ok(false) => {}
                Err(_) => {}
            }
        }
        Ok(reconciled)
    }

    pub fn has_event_type(&self, meeting_id: &str, event_type: &str) -> Result<bool> {
        let count: i64 = self.connection.query_row(
            "select count(*) from meeting_events where meeting_id = ?1 and event_type = ?2",
            params![meeting_id, event_type],
            |row| row.get(0),
        )?;
        Ok(count > 0)
    }

    pub fn has_network_worker_consent(&self, meeting_id: &str, job_id: &str) -> Result<bool> {
        for event in self.list_events(meeting_id)? {
            if event.event_type != event_types::JOB_NETWORK_CONSENT_GRANTED {
                continue;
            }
            let consent: NetworkWorkerConsent = decode(&event.payload_json)?;
            if consent.job_id == job_id {
                return Ok(true);
            }
        }
        Ok(false)
    }

    pub fn recoverable_jobs(&self) -> Result<Vec<AgentJobSpec>> {
        let mut statement = self.connection.prepare(
            "select event_type, payload_json
             from meeting_events
             where event_type in (
                'agent_job.requested',
                'agent_job.started',
                'agent_job.progress',
                'agent_job.completed',
                'agent_job.failed',
                'agent_job.canceled'
             )
             order by rowid asc",
        )?;

        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        let mut jobs = Vec::new();
        for row in rows {
            let (event_type, payload_text) = row?;
            match serde_json::from_str::<AgentJobSpec>(&payload_text) {
                Ok(job)
                    if is_terminal_job_event(&event_type)
                        || is_terminal_job_status(&job.status) =>
                {
                    remove_by_id(&mut jobs, &job.id);
                }
                Ok(job) if matches!(job.status, JobStatus::Queued | JobStatus::Running) => {
                    upsert_by_id(&mut jobs, job);
                }
                Ok(_) => {}
                Err(_) if is_terminal_job_event(&event_type) => {
                    if let Some(job_id) = job_id_from_payload(&payload_text) {
                        remove_by_id(&mut jobs, &job_id);
                    }
                }
                Err(_) => {}
            }
        }
        Ok(jobs
            .into_iter()
            .filter(|job| matches!(job.status, JobStatus::Queued | JobStatus::Running))
            .collect())
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

fn remove_by_id<T>(items: &mut Vec<T>, id: &str)
where
    T: HasId,
{
    items.retain(|item| item.id() != id);
}

fn is_terminal_job_event(event_type: &str) -> bool {
    matches!(
        event_type,
        event_types::JOB_COMPLETED | event_types::JOB_FAILED | event_types::JOB_CANCELED
    )
}

fn is_terminal_job_status(status: &JobStatus) -> bool {
    matches!(
        status,
        JobStatus::Completed | JobStatus::Failed | JobStatus::Canceled
    )
}

fn job_id_from_payload(payload_text: &str) -> Option<String> {
    serde_json::from_str::<Value>(payload_text)
        .ok()?
        .get("id")?
        .as_str()
        .map(ToOwned::to_owned)
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
        AudioLane, AudioLevel, CaptureMode, DeliverableSpec, JobBudget, JobContext,
        PermissionProfile, ProposalKind, ProposalStatus, SourceFailed, SourceFailureReason,
        SourceStarted, SourceStatus, SourceStopped, TranscriptSourceKind, WorkerKind,
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
    fn projection_tracks_dropped_buffers_per_lane() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_drop";
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
        // Cumulative counts; a later, lower count must never lower the projection.
        for count in [2u32, 5, 3] {
            store
                .append(
                    meeting,
                    event_types::AUDIO_DROPPED,
                    None,
                    None,
                    &crate::AudioDropped {
                        meeting_id: meeting.to_string(),
                        lane: AudioLane::SystemAudio,
                        count,
                    },
                )
                .unwrap();
        }
        let projection = store.projection(meeting).unwrap();
        assert_eq!(projection.source.system_audio.dropped, 5);
        assert_eq!(projection.source.microphone.dropped, 0);
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
                &seg(
                    meeting,
                    "s1",
                    "lets research",
                    false,
                    TranscriptSourceKind::LocalMac,
                ),
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
    fn partial_is_cleared_when_capture_stops() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_ghost";
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
                &seg(
                    meeting,
                    "p1",
                    "half a senten",
                    false,
                    TranscriptSourceKind::LocalMac,
                ),
            )
            .unwrap();
        assert!(store.projection(meeting).unwrap().partial.is_some());

        store
            .append(
                meeting,
                event_types::SOURCE_STOPPED,
                None,
                None,
                &SourceStopped {
                    meeting_id: meeting.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                },
            )
            .unwrap();
        let projection = store.projection(meeting).unwrap();
        assert!(
            projection.partial.is_none(),
            "no ghost partial under a stopped meeting"
        );
        assert_eq!(projection.source.status, SourceStatus::Stopped);
    }

    #[test]
    fn reconcile_stops_an_orphaned_started_capture() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_orphan";
        // A prior daemon started capture and was killed before writing
        // source.stopped — the projection is stuck "capturing".
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
        let before = store.projection(meeting).unwrap().source;
        assert!(before.started && !before.stopped && before.failure.is_none());
        assert_eq!(before.status, SourceStatus::Capturing);

        assert!(store.reconcile_stopped_if_orphaned(meeting).unwrap());
        let after = store.projection(meeting).unwrap().source;
        assert!(after.stopped, "reconcile must mark the capture stopped");
        assert_eq!(after.status, SourceStatus::Stopped);

        // Idempotent: nothing left to reconcile.
        assert!(!store.reconcile_stopped_if_orphaned(meeting).unwrap());
    }

    #[test]
    fn reconcile_leaves_stopped_and_failed_captures_untouched() {
        let store = EventStore::memory().unwrap();

        let stopped = "m_stopped";
        store
            .append(
                stopped,
                event_types::SOURCE_STARTED,
                None,
                None,
                &SourceStarted {
                    meeting_id: stopped.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                    mode: CaptureMode::Mic,
                },
            )
            .unwrap();
        store
            .append(
                stopped,
                event_types::SOURCE_STOPPED,
                None,
                None,
                &SourceStopped {
                    meeting_id: stopped.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                },
            )
            .unwrap();
        assert!(!store.reconcile_stopped_if_orphaned(stopped).unwrap());

        let failed = "m_failed";
        store
            .append(
                failed,
                event_types::SOURCE_STARTED,
                None,
                None,
                &SourceStarted {
                    meeting_id: failed.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                    mode: CaptureMode::Mic,
                },
            )
            .unwrap();
        store
            .append(
                failed,
                event_types::SOURCE_FAILED,
                None,
                None,
                &SourceFailed {
                    meeting_id: failed.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                    reason: SourceFailureReason::HelperCrashed,
                    lane: None,
                    detail: None,
                },
            )
            .unwrap();
        assert!(
            !store.reconcile_stopped_if_orphaned(failed).unwrap(),
            "a failed capture must not be masked as a clean stop"
        );
    }

    #[test]
    fn reconcile_stops_a_capture_after_a_per_lane_failure() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_lane_fail";
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
        // System-audio lane failed, but the mic lane keeps the source
        // "capturing" — NOT a whole-source failure, so a killed daemon still
        // leaves it stuck started on boot. Reconcile must clear it.
        store
            .append(
                meeting,
                event_types::SOURCE_FAILED,
                None,
                None,
                &SourceFailed {
                    meeting_id: meeting.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                    reason: SourceFailureReason::HelperCrashed,
                    lane: Some(AudioLane::SystemAudio),
                    detail: None,
                },
            )
            .unwrap();
        let before = store.projection(meeting).unwrap().source;
        assert_ne!(before.status, SourceStatus::Failed);
        assert!(before.started && !before.stopped && before.failure.is_some());

        assert!(store.reconcile_stopped_if_orphaned(meeting).unwrap());
        assert!(store.projection(meeting).unwrap().source.stopped);
    }

    #[test]
    fn reconcile_orphaned_captures_skips_malformed_meetings_and_does_not_block() {
        let store = EventStore::memory().unwrap();
        let good = "m_good";
        store
            .append(
                good,
                event_types::SOURCE_STARTED,
                None,
                None,
                &SourceStarted {
                    meeting_id: good.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                    mode: CaptureMode::Mic,
                },
            )
            .unwrap();
        // A malformed source.started payload — projecting this meeting errors.
        let bad = "m_bad";
        store
            .append(
                bad,
                event_types::SOURCE_STARTED,
                None,
                None,
                &serde_json::json!({ "garbage": true }),
            )
            .unwrap();
        assert!(store.projection(bad).is_err());

        // The bad meeting must neither block reconciliation of the good one nor
        // abort the whole sweep (which on boot would brick the daemon).
        let reconciled = store.reconcile_orphaned_captures().unwrap();
        assert_eq!(reconciled, vec![good.to_string()]);
        assert!(store.projection(good).unwrap().source.stopped);
    }

    #[test]
    fn meeting_ids_lists_distinct_meetings() {
        let store = EventStore::memory().unwrap();
        for m in ["a", "b", "a"] {
            store
                .append(
                    m,
                    event_types::SOURCE_STARTED,
                    None,
                    None,
                    &SourceStarted {
                        meeting_id: m.to_string(),
                        source: TranscriptSourceKind::LocalMac,
                        mode: CaptureMode::Mic,
                    },
                )
                .unwrap();
        }
        let mut ids = store.meeting_ids().unwrap();
        ids.sort();
        assert_eq!(ids, vec!["a".to_string(), "b".to_string()]);
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
        // System-only capture: a system failure has no surviving lane, so it fails
        // the whole source.
        store
            .append(
                meeting,
                event_types::SOURCE_STARTED,
                None,
                None,
                &SourceStarted {
                    meeting_id: meeting.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                    mode: CaptureMode::System,
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
    fn system_lane_failure_keeps_mic_capture_alive() {
        // mic+system: the system lane fails (tap/permission) but the mic lane is
        // expected and capturing, so the whole source must NOT be Failed — the mic
        // keeps recording, the system lane shows failed, and a clean stop resolves
        // to Stopped (not Failed).
        let store = EventStore::memory().unwrap();
        let meeting = "m_sysfail_mic_alive";
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
                event_types::SOURCE_FAILED,
                None,
                None,
                &SourceFailed {
                    meeting_id: meeting.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                    reason: SourceFailureReason::SystemAudioPermissionDenied,
                    lane: Some(AudioLane::SystemAudio),
                    detail: None,
                },
            )
            .unwrap();

        let mid = store.projection(meeting).unwrap();
        assert_ne!(
            mid.source.status,
            SourceStatus::Failed,
            "mic keeps the capture alive when only the system lane failed"
        );
        assert!(mid.source.system_audio.failed);
        assert!(!mid.source.microphone.failed);
        assert!(
            mid.source.failure.is_some(),
            "the system failure is still surfaced"
        );

        store
            .append(
                meeting,
                event_types::SOURCE_STOPPED,
                None,
                None,
                &SourceStopped {
                    meeting_id: meeting.to_string(),
                    source: TranscriptSourceKind::LocalMac,
                },
            )
            .unwrap();
        assert_eq!(
            store.projection(meeting).unwrap().source.status,
            SourceStatus::Stopped
        );
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
            model: None,
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

    fn job(meeting: &str, id: &str, status: JobStatus) -> AgentJobSpec {
        AgentJobSpec {
            id: id.to_string(),
            meeting_id: meeting.to_string(),
            proposal_id: None,
            worker: WorkerKind::ResearchAgent,
            title: format!("{id} job"),
            prompt: "recover me".to_string(),
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
            progress_note: None,
            failure_reason: None,
            error: None,
            receipt_path: None,
        }
    }

    #[test]
    fn recoverable_jobs_returns_latest_nonterminal_jobs_only() {
        let store = EventStore::memory().unwrap();
        let mut queued = job("m_a", "job_queued", JobStatus::Queued);
        let mut running = job("m_b", "job_running", JobStatus::Queued);
        let mut completed = job("m_c", "job_completed", JobStatus::Queued);
        let mut failed = job("m_d", "job_failed", JobStatus::Queued);

        store
            .append("m_a", event_types::JOB_REQUESTED, None, None, &queued)
            .unwrap();
        store
            .append("m_b", event_types::JOB_REQUESTED, None, None, &running)
            .unwrap();
        running.status = JobStatus::Running;
        store
            .append("m_b", event_types::JOB_STARTED, None, None, &running)
            .unwrap();
        store
            .append("m_c", event_types::JOB_REQUESTED, None, None, &completed)
            .unwrap();
        completed.status = JobStatus::Completed;
        store
            .append("m_c", event_types::JOB_COMPLETED, None, None, &completed)
            .unwrap();
        store
            .append("m_d", event_types::JOB_REQUESTED, None, None, &failed)
            .unwrap();
        failed.status = JobStatus::Failed;
        store
            .append("m_d", event_types::JOB_FAILED, None, None, &failed)
            .unwrap();

        queued.progress_note = Some("still queued".to_string());
        store
            .append("m_a", event_types::JOB_PROGRESS, None, None, &queued)
            .unwrap();

        let recoverable = store.recoverable_jobs().unwrap();
        let ids = recoverable
            .iter()
            .map(|job| job.id.as_str())
            .collect::<Vec<_>>();
        assert_eq!(ids, vec!["job_queued", "job_running"]);
        assert_eq!(
            recoverable[0].progress_note.as_deref(),
            Some("still queued")
        );
        assert_eq!(recoverable[1].status, JobStatus::Running);
    }

    #[test]
    fn recoverable_jobs_excludes_canceled_jobs() {
        let store = EventStore::memory().unwrap();
        let mut canceled = job("m_a", "job_canceled", JobStatus::Queued);

        store
            .append("m_a", event_types::JOB_REQUESTED, None, None, &canceled)
            .unwrap();
        canceled.status = JobStatus::Canceled;
        store
            .append("m_a", event_types::JOB_CANCELED, None, None, &canceled)
            .unwrap();

        assert!(store.recoverable_jobs().unwrap().is_empty());
    }

    #[test]
    fn projection_exposes_recovery_progress_event_payload() {
        let store = EventStore::memory().unwrap();
        let mut recovered = job("m_a", "job_recovered", JobStatus::Queued);
        recovered.progress_note = Some("recovered after daemon restart".to_string());

        store
            .append("m_a", event_types::JOB_PROGRESS, None, None, &recovered)
            .unwrap();

        let projection = store.projection("m_a").unwrap();
        let event = projection
            .events
            .iter()
            .find(|event| event.event_type == event_types::JOB_PROGRESS)
            .unwrap();

        assert_eq!(event.payload_json["id"], "job_recovered");
        assert_eq!(
            event.payload_json["progress_note"],
            "recovered after daemon restart"
        );
        assert_eq!(
            projection.jobs[0].progress_note.as_deref(),
            Some("recovered after daemon restart")
        );
    }

    #[test]
    fn recoverable_jobs_skips_malformed_historical_job_events() {
        let store = EventStore::memory().unwrap();
        let queued = job("m_a", "job_queued", JobStatus::Queued);

        store
            .append(
                "m_bad",
                event_types::JOB_REQUESTED,
                None,
                None,
                &serde_json::json!({"not": "a job"}),
            )
            .unwrap();
        store
            .append("m_a", event_types::JOB_REQUESTED, None, None, &queued)
            .unwrap();

        let recoverable = store.recoverable_jobs().unwrap();
        assert_eq!(recoverable.len(), 1);
        assert_eq!(recoverable[0].id, "job_queued");
    }

    #[test]
    fn recoverable_jobs_does_not_rerun_job_with_malformed_terminal_event() {
        let store = EventStore::memory().unwrap();
        let queued = job("m_a", "job_queued", JobStatus::Queued);

        store
            .append("m_a", event_types::JOB_REQUESTED, None, None, &queued)
            .unwrap();
        store
            .append(
                "m_a",
                event_types::JOB_COMPLETED,
                None,
                None,
                &serde_json::json!({"id": "job_queued", "status": "completed"}),
            )
            .unwrap();

        assert!(store.recoverable_jobs().unwrap().is_empty());
    }
}
