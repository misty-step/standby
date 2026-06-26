use crate::{
    ProposalContextWindow, ProposalRequest, TranscriptEvidence, TranscriptSegment, new_id,
    proposal_context::select_final_transcript_segments,
};

const REQUEST_CONTEXT_RECENT_LIMIT: usize = 8;

pub struct ProposalRequestEngine;

impl ProposalRequestEngine {
    /// Build the append-only operator request event from an explicit Ask Standby
    /// message and the selected transcript context. The request records which
    /// transcript spans were used; generated proposals then cite those same spans.
    pub fn build(
        meeting_id: &str,
        message: &str,
        context_window: ProposalContextWindow,
        max_proposals: u8,
        transcript: &[TranscriptSegment],
    ) -> ProposalRequest {
        let evidence = Self::context(transcript, context_window);
        ProposalRequest {
            id: new_id("preq"),
            meeting_id: meeting_id.to_string(),
            message: message.trim().to_string(),
            context_window,
            max_proposals: max_proposals.clamp(1, 3),
            transcript_spans: evidence
                .iter()
                .map(|evidence| evidence.segment_id.clone())
                .collect(),
        }
    }

    pub fn context(
        transcript: &[TranscriptSegment],
        context_window: ProposalContextWindow,
    ) -> Vec<TranscriptEvidence> {
        let recent_limit = match context_window {
            ProposalContextWindow::Full => usize::MAX,
            ProposalContextWindow::Recent => REQUEST_CONTEXT_RECENT_LIMIT,
        };
        select_final_transcript_segments(transcript, &[], recent_limit)
            .into_iter()
            .map(Into::into)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn operator_request_records_context_without_transcript_cue() {
        let meeting_id = "m_operator_request";
        let transcript = vec![
            final_seg(
                meeting_id,
                "s0",
                "remote_1",
                "We keep hearing that customers want the meeting notes to stay local.",
            ),
            final_seg(
                meeting_id,
                "s1",
                "remote_2",
                "The important thing is whether this can fit the live workflow.",
            ),
        ];
        let request = ProposalRequestEngine::build(
            meeting_id,
            "Research local-first meeting tools using this call as context",
            ProposalContextWindow::Recent,
            3,
            &transcript,
        );

        assert_eq!(request.transcript_spans, vec!["s0", "s1"]);
        assert_eq!(
            request.message,
            "Research local-first meeting tools using this call as context"
        );
        assert_eq!(request.max_proposals, 3);
    }

    #[test]
    fn operator_request_recent_context_is_bounded() {
        let meeting_id = "m_context_limit";
        let transcript: Vec<TranscriptSegment> = (0..10)
            .map(|index| {
                final_seg(
                    meeting_id,
                    &format!("s{index}"),
                    "me",
                    &format!("meeting sentence {index}"),
                )
            })
            .collect();

        let request = ProposalRequestEngine::build(
            meeting_id,
            "Suggest a follow-up task",
            ProposalContextWindow::Recent,
            9,
            &transcript,
        );

        assert_eq!(request.max_proposals, 3);
        assert_eq!(request.transcript_spans.len(), 8);
        assert_eq!(request.transcript_spans[0], "s2");
        assert_eq!(request.transcript_spans[7], "s9");
    }

    #[test]
    fn empty_operator_message_still_records_a_sanitized_request() {
        let meeting_id = "m_empty_operator_request";
        let request =
            ProposalRequestEngine::build(meeting_id, "   ", ProposalContextWindow::Recent, 1, &[]);

        assert!(request.message.is_empty());
        assert!(request.transcript_spans.is_empty());
    }
}
