use crate::TranscriptSegment;
use std::collections::HashSet;

/// Select the finalized transcript context that may be shown to proposal logic.
///
/// The proposal-request API and automatic proposal agent must agree on two
/// safety rules: partial transcript segments are never surfaced as evidence, and
/// recent context windows are computed over finalized segments only. Keeping that
/// policy in one helper prevents the two proposal entry points from drifting.
pub(crate) fn select_final_transcript_segments<'a>(
    transcript: &'a [TranscriptSegment],
    requested_spans: &[String],
    recent_limit: usize,
) -> Vec<&'a TranscriptSegment> {
    if !requested_spans.is_empty() {
        let requested: HashSet<&str> = requested_spans.iter().map(String::as_str).collect();
        return transcript
            .iter()
            .filter(|segment| segment.is_final && requested.contains(segment.id.as_str()))
            .collect();
    }

    let final_segments: Vec<&TranscriptSegment> = transcript
        .iter()
        .filter(|segment| segment.is_final)
        .collect();
    let start = final_segments.len().saturating_sub(recent_limit);
    final_segments.into_iter().skip(start).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn segment(id: &str, is_final: bool) -> TranscriptSegment {
        TranscriptSegment {
            id: id.to_string(),
            meeting_id: "m_context".to_string(),
            speaker: Some("me".to_string()),
            start_ms: 0,
            end_ms: 1_000,
            text: format!("segment {id}"),
            is_final,
            confidence: None,
            source: crate::TranscriptSourceKind::LocalMac,
        }
    }

    #[test]
    fn requested_spans_ignore_partials_even_when_explicit() {
        let transcript = vec![segment("s0", true), segment("s1", false), segment("s2", true)];
        let requested = vec!["s1".to_string(), "s2".to_string()];

        let selected = select_final_transcript_segments(&transcript, &requested, 8);

        assert_eq!(selected.iter().map(|segment| segment.id.as_str()).collect::<Vec<_>>(), vec!["s2"]);
    }

    #[test]
    fn recent_window_uses_final_segments_only() {
        let transcript = vec![
            segment("s0", true),
            segment("partial", false),
            segment("s1", true),
            segment("s2", true),
        ];

        let selected = select_final_transcript_segments(&transcript, &[], 2);

        assert_eq!(selected.iter().map(|segment| segment.id.as_str()).collect::<Vec<_>>(), vec!["s1", "s2"]);
    }
}
