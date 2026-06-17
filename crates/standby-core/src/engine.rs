use crate::{
    Proposal, ProposalKind, ProposalStatus, TranscriptSegment, WorkerKind, demo_segments, new_id,
};

pub struct ProposalEngine;

impl ProposalEngine {
    pub fn detect_research_proposal(
        meeting_id: &str,
        transcript: &[TranscriptSegment],
        existing: &[Proposal],
    ) -> Option<Proposal> {
        if existing.iter().any(|proposal| {
            proposal.kind == ProposalKind::Research
                && proposal.title.to_lowercase().contains("prior art")
        }) {
            return None;
        }

        let evidence: Vec<_> = transcript
            .iter()
            .filter(|segment| {
                let text = segment.text.to_lowercase();
                segment.is_final
                    && (text.contains("prior art")
                        || text.contains("research")
                        || text.contains("market already")
                        || text.contains("already exists"))
            })
            .map(Into::into)
            .collect();

        if evidence.len() < 2 {
            return None;
        }

        Some(Proposal {
            id: new_id("prop"),
            meeting_id: meeting_id.to_string(),
            kind: ProposalKind::Research,
            title: "Prior art research".to_string(),
            rationale: "Maya asked whether this already exists, and the group scoped a short prior-art sweep with local-first constraints.".to_string(),
            draft_prompt: "Research prior art for meeting copilots and agentic note tools with local-first or on-device guarantees. Focus on the last 18 months. Include open source and YC companies. Provide a short list with one-liners, positioning notes, links, and key differentiators.".to_string(),
            evidence,
            suggested_worker: WorkerKind::ResearchAgent,
            confidence: 0.86,
            status: ProposalStatus::Proposed,
        })
    }
}

pub fn demo_meeting_segments(meeting_id: &str) -> Vec<TranscriptSegment> {
    demo_segments(meeting_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_research_only_when_transcript_contains_concrete_ask() {
        let meeting_id = "meeting_test";
        let proposal = ProposalEngine::detect_research_proposal(
            meeting_id,
            &demo_meeting_segments(meeting_id),
            &[],
        )
        .expect("research proposal");

        assert_eq!(proposal.kind, ProposalKind::Research);
        assert_eq!(proposal.suggested_worker, WorkerKind::ResearchAgent);
        assert!(proposal.evidence.len() >= 2);
        assert!(proposal.draft_prompt.contains("local-first"));
    }

    #[test]
    fn does_not_propose_for_vague_chatter() {
        let meeting_id = "meeting_test";
        let transcript = vec![TranscriptSegment {
            id: "span_0".to_string(),
            meeting_id: meeting_id.to_string(),
            speaker: Some("Maya".to_string()),
            start_ms: 0,
            end_ms: 1_000,
            text: "This direction seems interesting, let's keep talking.".to_string(),
            is_final: true,
            confidence: Some(0.9),
            source: crate::TranscriptSourceKind::Demo,
        }];

        let proposal = ProposalEngine::detect_research_proposal(meeting_id, &transcript, &[]);
        assert!(proposal.is_none());
    }
}
