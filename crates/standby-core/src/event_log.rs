use crate::{
    AgentJobSpec, Artifact, MeetingEvent, MeetingProjection, Proposal, new_id, now_rfc3339ish,
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

        for event in &events {
            match event.event_type.as_str() {
                "transcript.segment.final" => transcript.push(decode(&event.payload_json)?),
                "proposal.created" | "proposal.approved" | "proposal.ignored" => {
                    upsert_by_id(&mut proposals, decode::<Proposal>(&event.payload_json)?);
                }
                "agent_job.requested"
                | "agent_job.started"
                | "agent_job.progress"
                | "agent_job.completed"
                | "agent_job.failed"
                | "agent_job.canceled" => {
                    upsert_by_id(&mut jobs, decode::<AgentJobSpec>(&event.payload_json)?);
                }
                "artifact.created" => artifacts.push(decode(&event.payload_json)?),
                _ => {}
            }
        }

        Ok(MeetingProjection {
            meeting_id: meeting_id.to_string(),
            title: Some("Acme / Q2 Planning".to_string()),
            transcript,
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
    use crate::{ProposalKind, ProposalStatus, WorkerKind};

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
