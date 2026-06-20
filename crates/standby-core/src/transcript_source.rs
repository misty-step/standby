//! Transcript sources turn an external capture format into normalized meeting
//! events. The first and default implementation is [`LocalMacAudioSource`],
//! which consumes the native helper's JSONL. Provider adapters (Vexa, Recall,
//! Teams Graph import, …) would implement the same normalization against their
//! own wire formats, so the proposal/UI/job layers never see provider details.

use crate::{
    AudioDropped, AudioLane, AudioLevel, CaptureMode, EventStore, SourceFailed,
    SourceFailureReason, SourceStarted, SourceStopped, TranscriptSegment, TranscriptSourceKind,
    event_types, new_id, propose_from_meeting_context,
};
use anyhow::Result;
use serde::Deserialize;

/// One event parsed from the native capture helper's stdout (one JSON per line).
/// Field names mirror the helper's contract documented in
/// `native/standby-capture-helper/main.swift`.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum HelperEvent {
    #[serde(rename = "source.started")]
    SourceStarted {
        mode: String,
        #[serde(default)]
        mic: bool,
        #[serde(default)]
        system: bool,
    },
    #[serde(rename = "audio.level")]
    AudioLevel {
        lane: String,
        rms: f32,
        #[serde(default)]
        peak: Option<f32>,
        #[serde(default)]
        captured_ms: u64,
    },
    #[serde(rename = "audio.dropped")]
    AudioDropped {
        lane: String,
        #[serde(default)]
        count: u32,
    },
    #[serde(rename = "segment.partial")]
    SegmentPartial {
        lane: String,
        #[serde(default)]
        speaker: Option<String>,
        text: String,
        #[serde(default)]
        start_ms: u64,
        #[serde(default)]
        end_ms: u64,
    },
    #[serde(rename = "segment.final")]
    SegmentFinal {
        lane: String,
        #[serde(default)]
        speaker: Option<String>,
        text: String,
        #[serde(default)]
        start_ms: u64,
        #[serde(default)]
        end_ms: u64,
    },
    #[serde(rename = "source.failed")]
    SourceFailed {
        reason: String,
        #[serde(default)]
        lane: Option<String>,
        #[serde(default)]
        detail: Option<String>,
    },
    #[serde(rename = "source.stopped")]
    SourceStopped,
    #[serde(rename = "transcribe.final")]
    TranscribeFinal {
        text: String,
        #[serde(default)]
        start_ms: u64,
        #[serde(default)]
        end_ms: u64,
    },
    #[serde(rename = "transcribe.done")]
    TranscribeDone { text: String },
}

impl HelperEvent {
    /// Parse one JSONL line. Unknown or blank lines return `None` rather than
    /// erroring, so a stray diagnostic on stdout can't kill a live capture.
    pub fn parse_line(line: &str) -> Option<Self> {
        let line = line.trim();
        if line.is_empty() {
            return None;
        }
        serde_json::from_str(line).ok()
    }
}

fn lane_from_str(lane: &str) -> Option<AudioLane> {
    match lane {
        "microphone" | "mic" | "me" => Some(AudioLane::Microphone),
        "system_audio" | "system" => Some(AudioLane::SystemAudio),
        _ => None,
    }
}

fn failure_reason_from_str(reason: &str) -> SourceFailureReason {
    match reason {
        "mic_permission_denied" => SourceFailureReason::MicPermissionDenied,
        "screen_recording_permission_denied" => {
            SourceFailureReason::ScreenRecordingPermissionDenied
        }
        "system_audio_permission_denied" => SourceFailureReason::SystemAudioPermissionDenied,
        "system_audio_unsupported_os" => SourceFailureReason::SystemAudioUnsupportedOs,
        "no_input_device" => SourceFailureReason::NoInputDevice,
        "helper_crashed" => SourceFailureReason::HelperCrashed,
        "unsupported" => SourceFailureReason::Unsupported,
        _ => SourceFailureReason::Unknown,
    }
}

fn speaker_for(lane: &str, speaker: Option<String>) -> Option<String> {
    speaker
        .map(|speaker| speaker.trim().to_string())
        .filter(|speaker| !speaker.is_empty())
        .or_else(|| match lane_from_str(lane) {
            Some(AudioLane::Microphone) => Some("me".to_string()),
            Some(AudioLane::SystemAudio) => Some("system_audio".to_string()),
            None => None,
        })
}

/// The local-Mac transcript source. Stateless: every method appends to the
/// durable event log so a restart replays cleanly.
pub struct LocalMacAudioSource;

impl LocalMacAudioSource {
    pub const KIND: TranscriptSourceKind = TranscriptSourceKind::LocalMac;

    /// Normalize one helper event into durable meeting events. Returns the
    /// finalized text when this event closed a transcript segment, so callers
    /// can react (e.g. run proposal detection) without re-reading the log.
    pub fn normalize(
        store: &EventStore,
        meeting_id: &str,
        event: HelperEvent,
    ) -> Result<Option<String>> {
        match event {
            HelperEvent::SourceStarted { mode, .. } => {
                store.append(
                    meeting_id,
                    event_types::SOURCE_STARTED,
                    Some(meeting_id),
                    None,
                    &SourceStarted {
                        meeting_id: meeting_id.to_string(),
                        source: TranscriptSourceKind::LocalMac,
                        mode: CaptureMode::parse(&mode),
                    },
                )?;
                Ok(None)
            }
            HelperEvent::AudioLevel {
                lane,
                rms,
                peak,
                captured_ms,
            } => {
                if let Some(lane) = lane_from_str(&lane) {
                    store.append(
                        meeting_id,
                        event_types::AUDIO_LEVEL,
                        Some(meeting_id),
                        None,
                        &AudioLevel {
                            meeting_id: meeting_id.to_string(),
                            lane,
                            rms,
                            peak,
                            captured_ms,
                        },
                    )?;
                }
                Ok(None)
            }
            HelperEvent::AudioDropped { lane, count } => {
                if let Some(lane) = lane_from_str(&lane) {
                    store.append(
                        meeting_id,
                        event_types::AUDIO_DROPPED,
                        Some(meeting_id),
                        None,
                        &AudioDropped {
                            meeting_id: meeting_id.to_string(),
                            lane,
                            count,
                        },
                    )?;
                }
                Ok(None)
            }
            HelperEvent::SegmentPartial {
                lane,
                speaker,
                text,
                start_ms,
                end_ms,
            } => {
                let segment = TranscriptSegment {
                    id: new_id("seg"),
                    meeting_id: meeting_id.to_string(),
                    speaker: speaker_for(&lane, speaker),
                    start_ms,
                    end_ms,
                    text,
                    is_final: false,
                    confidence: None,
                    source: TranscriptSourceKind::LocalMac,
                };
                store.append(
                    meeting_id,
                    event_types::SEGMENT_PARTIAL,
                    Some(meeting_id),
                    None,
                    &segment,
                )?;
                Ok(None)
            }
            HelperEvent::SegmentFinal {
                lane,
                speaker,
                text,
                start_ms,
                end_ms,
            } => {
                let segment = TranscriptSegment {
                    id: new_id("seg"),
                    meeting_id: meeting_id.to_string(),
                    speaker: speaker_for(&lane, speaker),
                    start_ms,
                    end_ms,
                    text: text.clone(),
                    is_final: true,
                    confidence: None,
                    source: TranscriptSourceKind::LocalMac,
                };
                store.append(
                    meeting_id,
                    event_types::SEGMENT_FINAL,
                    Some(meeting_id),
                    None,
                    &segment,
                )?;
                Ok(Some(text))
            }
            HelperEvent::SourceFailed {
                reason,
                lane,
                detail,
            } => {
                store.append(
                    meeting_id,
                    event_types::SOURCE_FAILED,
                    Some(meeting_id),
                    None,
                    &SourceFailed {
                        meeting_id: meeting_id.to_string(),
                        source: TranscriptSourceKind::LocalMac,
                        reason: failure_reason_from_str(&reason),
                        lane: lane.as_deref().and_then(lane_from_str),
                        detail,
                    },
                )?;
                Ok(None)
            }
            HelperEvent::SourceStopped => {
                store.append(
                    meeting_id,
                    event_types::SOURCE_STOPPED,
                    Some(meeting_id),
                    None,
                    &SourceStopped {
                        meeting_id: meeting_id.to_string(),
                        source: TranscriptSourceKind::LocalMac,
                    },
                )?;
                Ok(None)
            }
            // transcribe.* belong to the offline transcriber smoke, not live capture.
            HelperEvent::TranscribeFinal { .. } | HelperEvent::TranscribeDone { .. } => Ok(None),
        }
    }

    /// Normalize one event and, when it finalized a segment, run the proposal
    /// agent so a fresh evidence-cited proposal is created if warranted.
    pub fn ingest(store: &EventStore, meeting_id: &str, event: HelperEvent) -> Result<()> {
        if LocalMacAudioSource::normalize(store, meeting_id, event)?.is_some() {
            propose_from_meeting_context(store, meeting_id)?;
        }
        Ok(())
    }
}

/// Provider/sidecar diarization output normalized into transcript events.
/// Inputs must carry generic remote-speaker buckets, not invented human names
/// or local-user identity.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum DiarizationEvent {
    #[serde(rename = "diarization.segment.partial")]
    SegmentPartial {
        speaker: String,
        text: String,
        #[serde(default)]
        start_ms: u64,
        #[serde(default)]
        end_ms: u64,
        #[serde(default)]
        confidence: Option<f32>,
    },
    #[serde(rename = "diarization.segment.final")]
    SegmentFinal {
        speaker: String,
        text: String,
        #[serde(default)]
        start_ms: u64,
        #[serde(default)]
        end_ms: u64,
        #[serde(default)]
        confidence: Option<f32>,
    },
}

impl DiarizationEvent {
    /// Parse one provider/sidecar JSONL event. Unknown lines are ignored so
    /// adapters can share a stream with diagnostics without breaking capture.
    pub fn parse_line(line: &str) -> Option<Self> {
        let line = line.trim();
        if line.is_empty() {
            return None;
        }
        serde_json::from_str(line).ok()
    }
}

/// Normalizes provider/sidecar speaker-attributed transcript segments.
pub struct DiarizationProvider;

impl DiarizationProvider {
    pub const KIND: TranscriptSourceKind = TranscriptSourceKind::Diarization;

    pub fn normalize(
        store: &EventStore,
        meeting_id: &str,
        event: DiarizationEvent,
    ) -> Result<Option<String>> {
        match event {
            DiarizationEvent::SegmentPartial {
                speaker,
                text,
                start_ms,
                end_ms,
                confidence,
            } => {
                let segment = TranscriptSegment {
                    id: new_id("seg"),
                    meeting_id: meeting_id.to_string(),
                    speaker: diarized_speaker_for(&speaker),
                    start_ms,
                    end_ms,
                    text,
                    is_final: false,
                    confidence,
                    source: Self::KIND,
                };
                store.append(
                    meeting_id,
                    event_types::SEGMENT_PARTIAL,
                    Some(meeting_id),
                    None,
                    &segment,
                )?;
                Ok(None)
            }
            DiarizationEvent::SegmentFinal {
                speaker,
                text,
                start_ms,
                end_ms,
                confidence,
            } => {
                let segment = TranscriptSegment {
                    id: new_id("seg"),
                    meeting_id: meeting_id.to_string(),
                    speaker: diarized_speaker_for(&speaker),
                    start_ms,
                    end_ms,
                    text: text.clone(),
                    is_final: true,
                    confidence,
                    source: Self::KIND,
                };
                store.append(
                    meeting_id,
                    event_types::SEGMENT_FINAL,
                    Some(meeting_id),
                    None,
                    &segment,
                )?;
                Ok(Some(text))
            }
        }
    }

    pub fn ingest(store: &EventStore, meeting_id: &str, event: DiarizationEvent) -> Result<()> {
        if DiarizationProvider::normalize(store, meeting_id, event)?.is_some() {
            propose_from_meeting_context(store, meeting_id)?;
        }
        Ok(())
    }
}

fn diarized_speaker_for(raw: &str) -> Option<String> {
    let speaker = raw.trim();
    if speaker.is_empty() {
        return None;
    }
    let normalized = speaker.to_ascii_lowercase().replace('-', "_");
    if let Some(number) = normalized
        .strip_prefix("remote_")
        .and_then(parse_positive_number)
    {
        return Some(format!("remote_{number}"));
    }
    for prefix in ["speaker_", "spk_"] {
        if let Some(suffix) = normalized.strip_prefix(prefix) {
            if let Some(number) = zero_based_generic_speaker_number(suffix) {
                return Some(format!("remote_{number}"));
            }
        }
    }
    None
}

fn parse_positive_number(value: &str) -> Option<u32> {
    let number = value.parse::<u32>().ok()?;
    (number > 0).then_some(number)
}

fn zero_based_generic_speaker_number(suffix: &str) -> Option<u32> {
    if suffix.is_empty() || !suffix.chars().all(|ch| ch.is_ascii_digit()) {
        return None;
    }
    // Generic diarization labels are treated as zero-based acoustic buckets
    // (`SPEAKER_00`, `speaker_1`, `spk-2`). Adapters with known one-based
    // labels should emit explicit `remote_N` to avoid off-by-one ambiguity.
    suffix.parse::<u32>().ok().map(|number| number + 1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SourceStatus;

    #[test]
    fn parses_helper_jsonl_variants() {
        assert!(matches!(
            HelperEvent::parse_line(
                r#"{"type":"source.started","mode":"mic+system","mic":true,"system":true}"#
            ),
            Some(HelperEvent::SourceStarted { .. })
        ));
        assert!(matches!(
            HelperEvent::parse_line(
                r#"{"type":"audio.level","lane":"system_audio","rms":0.1,"captured_ms":1000}"#
            ),
            Some(HelperEvent::AudioLevel { .. })
        ));
        assert!(matches!(
            HelperEvent::parse_line(
                r#"{"type":"segment.final","lane":"system_audio","speaker":"system_audio","text":"hi"}"#
            ),
            Some(HelperEvent::SegmentFinal { .. })
        ));
        // Blank and junk lines are ignored, never fatal.
        assert!(HelperEvent::parse_line("   ").is_none());
        assert!(HelperEvent::parse_line("not json").is_none());
    }

    #[test]
    fn normalizes_capture_stream_into_projection() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_cap";
        let lines = [
            r#"{"type":"source.started","mode":"mic+system","mic":true,"system":true}"#,
            r#"{"type":"audio.level","lane":"system_audio","rms":0.1,"peak":0.6,"captured_ms":1000}"#,
            r#"{"type":"segment.partial","lane":"system_audio","speaker":"system_audio","text":"can someone"}"#,
            r#"{"type":"segment.partial","lane":"system_audio","speaker":"system_audio","text":"can someone check"}"#,
            r#"{"type":"segment.final","lane":"system_audio","speaker":"system_audio","text":"can someone check what already exists"}"#,
        ];
        for line in lines {
            let event = HelperEvent::parse_line(line).expect("parse");
            LocalMacAudioSource::ingest(&store, meeting, event).unwrap();
        }

        let projection = store.projection(meeting).unwrap();
        // Many partials, exactly one final segment in the transcript (no dupes).
        assert_eq!(projection.transcript.len(), 1);
        assert!(projection.partial.is_none());
        assert_eq!(
            projection.transcript[0].speaker.as_deref(),
            Some("system_audio")
        );
        assert_eq!(
            projection.source.source,
            Some(TranscriptSourceKind::LocalMac)
        );
        assert!(projection.source.system_audio.active);
        // Replaying the same projection is stable.
        let again = store.projection(meeting).unwrap();
        assert_eq!(again.transcript.len(), projection.transcript.len());
    }

    #[test]
    fn normalizes_audio_dropped_into_lane_counter() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_dropnorm";
        for line in [
            r#"{"type":"source.started","mode":"mic+system","mic":true,"system":true}"#,
            r#"{"type":"audio.dropped","lane":"system_audio","count":4}"#,
        ] {
            let event = HelperEvent::parse_line(line).expect("parse");
            LocalMacAudioSource::ingest(&store, meeting, event).unwrap();
        }
        let projection = store.projection(meeting).unwrap();
        assert_eq!(projection.source.system_audio.dropped, 4);
        assert_eq!(projection.source.microphone.dropped, 0);
    }

    #[test]
    fn maps_system_audio_permission_tier_distinctly() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_sysperm";
        for line in [
            r#"{"type":"source.started","mode":"system","mic":false,"system":true}"#,
            r#"{"type":"source.failed","reason":"system_audio_permission_denied","lane":"system_audio","detail":"nope"}"#,
        ] {
            let event = HelperEvent::parse_line(line).expect("parse");
            LocalMacAudioSource::ingest(&store, meeting, event).unwrap();
        }
        let projection = store.projection(meeting).unwrap();
        assert_eq!(projection.source.status, SourceStatus::Failed);
        // Distinct from the ScreenCaptureKit "Screen Recording" tier.
        assert_eq!(
            projection.source.failure.unwrap().reason,
            SourceFailureReason::SystemAudioPermissionDenied
        );
    }

    #[test]
    fn source_failed_event_marks_failed_status() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_capfail";
        for line in [
            r#"{"type":"source.started","mode":"system","mic":false,"system":true}"#,
            r#"{"type":"source.failed","reason":"screen_recording_permission_denied","lane":"system_audio","detail":"denied"}"#,
        ] {
            let event = HelperEvent::parse_line(line).expect("parse");
            LocalMacAudioSource::ingest(&store, meeting, event).unwrap();
        }
        let projection = store.projection(meeting).unwrap();
        assert_eq!(projection.source.status, SourceStatus::Failed);
        assert_eq!(
            projection.source.failure.unwrap().reason,
            SourceFailureReason::ScreenRecordingPermissionDenied
        );
    }

    #[test]
    fn preserves_explicit_remote_speaker_tokens() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_remote_speakers";
        for line in [
            r#"{"type":"source.started","mode":"mic+system","mic":true,"system":true}"#,
            r#"{"type":"segment.final","lane":"system_audio","speaker":"remote_1","text":"Can someone research the prior art?"}"#,
            r#"{"type":"segment.final","lane":"system_audio","speaker":"remote_2","text":"Also include open-source options."}"#,
            r#"{"type":"segment.final","lane":"system_audio","speaker":"","text":"Fallback to the lane label when speaker is blank."}"#,
        ] {
            let event = HelperEvent::parse_line(line).expect("parse");
            LocalMacAudioSource::ingest(&store, meeting, event).unwrap();
        }

        let projection = store.projection(meeting).unwrap();
        let speakers: Vec<_> = projection
            .transcript
            .iter()
            .filter_map(|segment| segment.speaker.as_deref())
            .collect();

        assert!(speakers.contains(&"remote_1"));
        assert!(speakers.contains(&"remote_2"));
        assert!(speakers.contains(&"system_audio"));
    }

    #[test]
    fn diarization_provider_maps_generic_speakers_to_stable_remote_buckets() {
        let store = EventStore::memory().unwrap();
        let meeting = "m_diarized";
        for line in [
            r#"{"type":"diarization.segment.final","speaker":"SPEAKER_00","text":"We should compare existing meeting assistants.","start_ms":0,"end_ms":2000,"confidence":0.91}"#,
            r#"{"type":"diarization.segment.final","speaker":"SPEAKER_01","text":"Include open-source local-first tools too.","start_ms":2100,"end_ms":4200,"confidence":0.89}"#,
            r#"{"type":"diarization.segment.final","speaker":"SPEAKER_00","text":"Make it actionable for this call.","start_ms":4300,"end_ms":5500}"#,
        ] {
            let event = DiarizationEvent::parse_line(line).expect("parse diarization event");
            DiarizationProvider::ingest(&store, meeting, event).unwrap();
        }

        let projection = store.projection(meeting).unwrap();
        let speakers: Vec<_> = projection
            .transcript
            .iter()
            .filter_map(|segment| segment.speaker.as_deref())
            .collect();

        assert_eq!(speakers, vec!["remote_1", "remote_2", "remote_1"]);
        assert!(
            projection
                .transcript
                .iter()
                .all(|segment| segment.source == TranscriptSourceKind::Diarization)
        );
        assert!(
            projection
                .proposals
                .iter()
                .flat_map(|proposal| proposal.evidence.iter())
                .any(|evidence| evidence.speaker.as_deref() == Some("remote_1")),
            "proposal evidence should keep diarized speaker buckets"
        );
    }

    #[test]
    fn diarization_provider_does_not_invent_names_from_unknown_speaker_labels() {
        assert_eq!(
            diarized_speaker_for("SPEAKER_00").as_deref(),
            Some("remote_1")
        );
        assert_eq!(
            diarized_speaker_for("speaker_1").as_deref(),
            Some("remote_2")
        );
        assert_eq!(diarized_speaker_for("spk-2").as_deref(), Some("remote_3"));
        assert_eq!(
            diarized_speaker_for("remote_3").as_deref(),
            Some("remote_3")
        );
        assert_eq!(diarized_speaker_for("me"), None);
        assert_eq!(diarized_speaker_for("system_audio"), None);
        assert_eq!(diarized_speaker_for("call_audio"), None);
        assert_eq!(diarized_speaker_for("Alice"), None);
    }
}
