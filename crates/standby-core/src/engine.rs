use crate::{
    Proposal, ProposalKind, ProposalStatus, TranscriptEvidence, TranscriptSegment, WorkerKind,
    demo_segments, new_id,
};

/// Phrases that signal a meeting is asking for prior-art / research work. The
/// detector requires two distinct cue-bearing final segments so a single
/// off-hand mention of "the market" does not fire a proposal.
const RESEARCH_CUES: &[&str] = &[
    "prior art",
    "already exists",
    "already out there",
    "what exists",
    "what's out there",
    "research",
    "look into",
    "investigate",
    "has anyone seen",
    "who else is",
    "existing solution",
    "competitor",
    "in the market",
    "market already",
];

pub struct ProposalEngine;

impl ProposalEngine {
    /// Detect a research proposal from the live transcript. The proposal content
    /// is derived from the actual cited evidence — never hard-coded demo copy —
    /// so a proposal from a real meeting quotes that real meeting. Only one open
    /// research proposal exists at a time.
    pub fn detect_research_proposal(
        meeting_id: &str,
        transcript: &[TranscriptSegment],
        existing: &[Proposal],
    ) -> Option<Proposal> {
        let already_open = existing.iter().any(|proposal| {
            proposal.kind == ProposalKind::Research && proposal.status != ProposalStatus::Ignored
        });
        if already_open {
            return None;
        }

        let evidence: Vec<TranscriptEvidence> = transcript
            .iter()
            .filter(|segment| segment.is_final && contains_research_cue(&segment.text))
            .map(Into::into)
            .collect();

        if evidence.len() < 2 {
            return None;
        }

        let ask = evidence
            .first()
            .map(|item| item.text.trim().to_string())
            .unwrap_or_default();
        let context: Vec<String> = evidence
            .iter()
            .skip(1)
            .map(|item| item.text.trim().to_string())
            .collect();
        let context_line = if context.is_empty() {
            String::new()
        } else {
            format!(" Additional context from the meeting: {}", context.join(" "))
        };

        let draft_prompt = format!(
            "Research the request raised in this live meeting: \"{ask}\".{context_line} \
             Produce a concise briefing: a short list of relevant prior art with one-line \
             summaries, positioning notes, links, and key differentiators. Cite sources.",
        );

        Some(Proposal {
            id: new_id("prop"),
            meeting_id: meeting_id.to_string(),
            kind: ProposalKind::Research,
            title: "Research request".to_string(),
            rationale: format!("Raised in the meeting: \"{ask}\""),
            draft_prompt,
            evidence,
            suggested_worker: WorkerKind::ResearchAgent,
            confidence: 0.82,
            status: ProposalStatus::Proposed,
        })
    }
}

fn contains_research_cue(text: &str) -> bool {
    let lower = text.to_lowercase();
    RESEARCH_CUES.iter().any(|cue| lower.contains(cue))
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

    fn final_seg(meeting: &str, id: &str, speaker: &str, text: &str) -> TranscriptSegment {
        TranscriptSegment {
            id: id.to_string(),
            meeting_id: meeting.to_string(),
            speaker: Some(speaker.to_string()),
            start_ms: 0,
            end_ms: 1_000,
            text: text.to_string(),
            is_final: true,
            confidence: None,
            source: crate::TranscriptSourceKind::LocalMac,
        }
    }

    #[test]
    fn proposal_content_is_derived_from_real_evidence_not_demo_copy() {
        let meeting_id = "m_real";
        let transcript = vec![
            final_seg(
                meeting_id,
                "s0",
                "system_audio",
                "Can someone look into what already exists for on-call routing?",
            ),
            final_seg(
                meeting_id,
                "s1",
                "me",
                "Yeah, do some research on existing solutions and their pricing.",
            ),
        ];
        let proposal =
            ProposalEngine::detect_research_proposal(meeting_id, &transcript, &[]).expect("proposal");
        assert!(
            proposal.rationale.contains("on-call routing"),
            "rationale quotes the real ask, got: {}",
            proposal.rationale
        );
        assert!(
            !proposal.rationale.to_lowercase().contains("maya"),
            "no demo names should leak into a real proposal"
        );
        assert!(proposal.draft_prompt.contains("on-call routing"));
        assert_eq!(proposal.evidence.len(), 2);
    }

    #[test]
    fn does_not_propose_for_realistic_planning_chatter() {
        let meeting_id = "m_chatter";
        let transcript = vec![
            final_seg(
                meeting_id,
                "s0",
                "me",
                "Let's push the deploy to Thursday and tell the client.",
            ),
            final_seg(
                meeting_id,
                "s1",
                "system_audio",
                "Sounds good, I'll update the ticket and the timeline.",
            ),
            final_seg(meeting_id, "s2", "me", "Great, thanks everyone."),
        ];
        assert!(ProposalEngine::detect_research_proposal(meeting_id, &transcript, &[]).is_none());
    }

    #[test]
    fn does_not_propose_twice_while_one_is_open() {
        let meeting_id = "m_dedupe";
        let transcript = vec![
            final_seg(
                meeting_id,
                "s0",
                "system_audio",
                "Has anyone seen prior art for this already?",
            ),
            final_seg(meeting_id, "s1", "me", "Let's research existing solutions."),
        ];
        let first = ProposalEngine::detect_research_proposal(meeting_id, &transcript, &[])
            .expect("first proposal");
        let second = ProposalEngine::detect_research_proposal(
            meeting_id,
            &transcript,
            std::slice::from_ref(&first),
        );
        assert!(second.is_none(), "one open research proposal at a time");
    }
}
