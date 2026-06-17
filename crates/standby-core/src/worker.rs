use crate::{
    AgentJobSpec, Artifact, DeliverableSpec, EventStore, JobBudget, JobContext, JobStatus,
    PermissionProfile, Proposal, ProposalStatus, WorkerKind, new_id,
};
use anyhow::Result;

pub struct MockResearchWorker;

impl MockResearchWorker {
    pub fn approve_and_run(
        store: &EventStore,
        proposal: &Proposal,
        approved_by: &str,
        prompt_override: Option<String>,
    ) -> Result<AgentJobSpec> {
        let mut approved = proposal.clone();
        approved.status = ProposalStatus::Approved;
        store.append(
            &proposal.meeting_id,
            "proposal.approved",
            Some(&proposal.id),
            None,
            &approved,
        )?;

        let mut job = AgentJobSpec {
            id: new_id("job"),
            meeting_id: proposal.meeting_id.clone(),
            proposal_id: Some(proposal.id.clone()),
            worker: WorkerKind::ResearchAgent,
            title: proposal.title.clone(),
            prompt: prompt_override.unwrap_or_else(|| proposal.draft_prompt.clone()),
            context: JobContext {
                meeting_title: Some("Acme / Q2 Planning".to_string()),
                topic: Some("prior art research".to_string()),
                approved_by: approved_by.to_string(),
                transcript_spans: proposal
                    .evidence
                    .iter()
                    .map(|evidence| evidence.segment_id.clone())
                    .collect(),
                meeting_state_snapshot_id: Some(new_id("state")),
            },
            budget: JobBudget {
                max_minutes: 8,
                max_cost_usd: Some(2.0),
            },
            deliverable: DeliverableSpec {
                description:
                    "Short briefing with citations and three architecture recommendations."
                        .to_string(),
            },
            permissions: PermissionProfile {
                can_mutate_external_systems: false,
                requires_extra_approval: vec![
                    "send_external_message".to_string(),
                    "repo_mutation".to_string(),
                    "spend_money".to_string(),
                ],
            },
            status: JobStatus::Queued,
            profile: None,
            progress_note: None,
            failure_reason: None,
            error: None,
            receipt_path: None,
        };

        store.append(
            &job.meeting_id,
            "agent_job.requested",
            Some(&proposal.id),
            None,
            &job,
        )?;

        job.status = JobStatus::Running;
        store.append(
            &job.meeting_id,
            "agent_job.started",
            Some(&proposal.id),
            None,
            &job,
        )?;

        store.append(
            &job.meeting_id,
            "agent_job.progress",
            Some(&proposal.id),
            None,
            &job,
        )?;

        let artifact = Artifact {
            id: new_id("artifact"),
            job_id: job.id.clone(),
            title: "Realtime meeting-agent prior art".to_string(),
            summary: "Mock research complete: compare meeting bots, platform-native media APIs, and local capture. The first product wedge should prove proposal quality and approval telemetry before adding mutation-capable workers.".to_string(),
            uri: Some(format!("standby://artifacts/{}", job.id)),
        };
        store.append(
            &job.meeting_id,
            "artifact.created",
            Some(&proposal.id),
            None,
            &artifact,
        )?;

        job.status = JobStatus::Completed;
        store.append(
            &job.meeting_id,
            "agent_job.completed",
            Some(&proposal.id),
            None,
            &job,
        )?;

        Ok(job)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ProposalEngine, demo_meeting_segments};

    #[test]
    fn approval_creates_normalized_job_events() {
        let meeting_id = "meeting_test";
        let store = EventStore::memory().unwrap();
        let segments = demo_meeting_segments(meeting_id);
        let proposal =
            ProposalEngine::detect_research_proposal(meeting_id, &segments, &[]).expect("proposal");

        MockResearchWorker::approve_and_run(&store, &proposal, "Phaedrus", None).unwrap();

        let projection = store.projection(meeting_id).unwrap();
        assert_eq!(projection.jobs.len(), 1);
        assert_eq!(projection.jobs[0].status, JobStatus::Completed);
        assert_eq!(projection.artifacts.len(), 1);
        assert!(
            store
                .has_event_type(meeting_id, "artifact.created")
                .unwrap()
        );
    }
}
