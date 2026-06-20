//! Replays a local-capture-shaped JSONL fixture through the same normalization
//! path the live daemon uses, asserting partial/final ordering, dedupe,
//! evidence-cited proposal-agent output, and projection stability — all without
//! macOS permissions or a live call.

use standby_core::{
    EventStore, HelperEvent, LocalMacAudioSource, ProposalKind, TranscriptSourceKind,
};

fn replay(meeting: &str) -> EventStore {
    let fixture = include_str!("fixtures/local_capture_meeting.jsonl");
    replay_fixture(meeting, fixture)
}

fn replay_fixture(meeting: &str, fixture: &str) -> EventStore {
    let store = EventStore::memory().expect("memory store");
    for line in fixture.lines() {
        if let Some(event) = HelperEvent::parse_line(line) {
            LocalMacAudioSource::ingest(&store, meeting, event).expect("ingest");
        }
    }
    store
}

#[test]
fn fixture_replays_into_ordered_local_transcript() {
    let meeting = "fixture_meeting";
    let store = replay(meeting);
    let projection = store.projection(meeting).expect("projection");

    // Exactly the three final segments, in order; partials left no residue.
    assert_eq!(projection.transcript.len(), 3, "expected 3 final segments");
    assert!(projection.partial.is_none(), "partial should be cleared");
    assert!(
        projection.transcript[0].text.contains("already exists"),
        "first final segment preserved"
    );
    assert!(
        projection
            .transcript
            .iter()
            .all(|segment| segment.source == TranscriptSourceKind::LocalMac),
        "all segments tagged local_mac"
    );

    // Honest two-lane attribution: me + system_audio.
    let speakers: Vec<_> = projection
        .transcript
        .iter()
        .filter_map(|segment| segment.speaker.as_deref())
        .collect();
    assert!(speakers.contains(&"system_audio"));
    assert!(speakers.contains(&"me"));
}

#[test]
fn fixture_creates_one_evidence_cited_proposal() {
    let meeting = "fixture_meeting_proposal";
    let store = replay(meeting);
    let projection = store.projection(meeting).expect("projection");

    assert_eq!(
        projection.proposals.len(),
        1,
        "exactly one proposal (deduped)"
    );
    let proposal = &projection.proposals[0];
    assert_eq!(proposal.kind, ProposalKind::Research);
    assert_eq!(
        proposal.model.as_ref().map(|model| model.provider.as_str()),
        Some("recorded-model"),
        "fixture proposal must come from recorded model output"
    );
    assert!(
        !proposal.evidence.is_empty(),
        "proposal must cite transcript evidence"
    );
    assert!(
        proposal
            .evidence
            .iter()
            .any(|evidence| evidence.text.contains("already exists")
                || evidence.text.contains("research sweep")),
        "proposal must cite the triggering research request"
    );

    // Every cited evidence segment id resolves to a real transcript segment.
    for evidence in &proposal.evidence {
        assert!(
            projection
                .transcript
                .iter()
                .any(|segment| segment.id == evidence.segment_id),
            "evidence {} must reference a real transcript segment",
            evidence.segment_id
        );
    }
}

#[test]
fn projection_is_stable_across_replays() {
    let a = replay("stable_a");
    let b = replay("stable_b");
    let pa = a.projection("stable_a").unwrap();
    let pb = b.projection("stable_b").unwrap();
    assert_eq!(pa.transcript.len(), pb.transcript.len());
    assert_eq!(pa.proposals.len(), pb.proposals.len());
}

#[test]
fn speaker_distinction_fixture_preserves_remote_speakers() {
    let meeting = "speaker_distinction";
    let fixture = include_str!("fixtures/speaker_distinction_meeting.jsonl");
    let store = replay_fixture(meeting, fixture);
    let projection = store.projection(meeting).expect("projection");

    let speakers: Vec<_> = projection
        .transcript
        .iter()
        .filter_map(|segment| segment.speaker.as_deref())
        .collect();
    assert!(speakers.contains(&"remote_1"));
    assert!(speakers.contains(&"remote_2"));
    assert!(
        projection
            .proposals
            .iter()
            .flat_map(|proposal| proposal.evidence.iter())
            .any(|evidence| evidence.speaker.as_deref() == Some("remote_1")),
        "proposal evidence should retain the triggering remote speaker"
    );
    assert!(
        speakers
            .iter()
            .filter(|speaker| **speaker != "me" && **speaker != "system_audio")
            .count()
            >= 2,
        "remote speakers must not collapse to system_audio"
    );
}
