//! Supervises the native capture helper subprocess for a meeting and streams
//! its JSONL stdout into the event log via [`LocalMacAudioSource`]. The daemon
//! owns process lifecycle; the helper owns the macOS frameworks. Worker
//! execution lives elsewhere — this module never spawns workers.

use crate::AppState;
use anyhow::{Context, Result};
use standby_core::{
    CaptureMode, EventStore, HelperEvent, LocalMacAudioSource, Meeting, ProposalAgentRun,
    SourceFailed, SourceFailureReason, TranscriptSourceKind, event_types,
    proposal_debounce_from_env, proposal_decision, record_proposal_decision,
};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

/// Resolve the native helper binary. Defaults to the SIGNED standalone helper
/// that the daemon can spawn and pipe safely. We still build a signed `.app` for
/// LaunchServices / permission-grant experiments, but raw-execing the bundle
/// executable can hang before Swift main on macOS 26.5.1. The standalone helper
/// carries the same stable code-signing identity, so macOS TCC grants persist
/// across rebuilds. `STANDBY_CAPTURE_HELPER` overrides it for experiments.
pub fn helper_path() -> PathBuf {
    if let Ok(path) = std::env::var("STANDBY_CAPTURE_HELPER") {
        return PathBuf::from(path);
    }
    default_helper_path()
}

fn default_helper_path() -> PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../native/standby-capture-helper/build/standby-capture-helper")
}

#[cfg(test)]
mod tests {
    use super::default_helper_path;

    #[test]
    fn default_helper_path_is_signed_standalone_binary() {
        let path = default_helper_path();
        assert!(
            path.ends_with("native/standby-capture-helper/build/standby-capture-helper"),
            "unexpected helper path: {}",
            path.display()
        );
    }

    #[test]
    fn automatic_proposal_releases_store_lock_during_model_call() {
        // 021: run_automatic_proposal must NOT hold the store lock across the
        // model call, or transcript ingestion stalls. With a slow recorded
        // "model call" in flight, the lock must stay acquirable.
        use standby_core::{EventStore, HelperEvent, LocalMacAudioSource};
        use std::sync::{Arc, Mutex};
        use std::time::{Duration, Instant};

        // SAFETY: process-local test env; this is the only proposal test here.
        unsafe {
            std::env::set_var("STANDBY_PROPOSAL_PROVIDER", "recorded");
            std::env::set_var("STANDBY_PROPOSAL_DEBOUNCE_SEGMENTS", "1");
            std::env::set_var("STANDBY_PROPOSAL_TEST_DELAY_MS", "1000");
        }

        let store = Arc::new(Mutex::new(EventStore::memory().expect("store")));
        let meeting = "lock_test";
        for line in [
            r#"{"type":"source.started","mode":"mic+system","mic":true,"system":true}"#,
            r#"{"type":"segment.final","lane":"system_audio","speaker":"remote_1","text":"We should research competitor pricing in Europe."}"#,
            r#"{"type":"segment.final","lane":"system_audio","speaker":"remote_1","text":"And send finance the revised budget by Friday."}"#,
        ] {
            if let Some(event) = HelperEvent::parse_line(line) {
                let guard = store.lock().unwrap();
                LocalMacAudioSource::normalize(&guard, meeting, event).expect("normalize");
            }
        }

        // Run the proposal off-path: it snapshots, then "calls the model" (sleeps
        // 1s) holding NO lock, then appends.
        let store_bg = store.clone();
        let handle = std::thread::spawn(move || {
            super::run_automatic_proposal(&store_bg, "lock_test").expect("propose");
        });

        // Once it is past the snapshot and inside the model call, the lock is free.
        std::thread::sleep(Duration::from_millis(300));
        let start = Instant::now();
        assert!(
            store.try_lock().is_ok(),
            "store lock held during the model call — transcript ingestion would stall"
        );
        assert!(start.elapsed() < Duration::from_millis(100));

        handle.join().expect("join");
        assert!(
            !store
                .lock()
                .unwrap()
                .projection("lock_test")
                .unwrap()
                .proposals
                .is_empty(),
            "the card is recorded once the model call completes"
        );

        // SAFETY: restore env so other tests are unaffected.
        unsafe {
            std::env::remove_var("STANDBY_PROPOSAL_TEST_DELAY_MS");
            std::env::remove_var("STANDBY_PROPOSAL_DEBOUNCE_SEGMENTS");
        }
    }
}

/// Generate a proposal OFF the capture-ingest path: snapshot the projection
/// under the store lock, release the lock for the (multi-second) model call,
/// then re-lock only to append the result. This is what keeps transcript
/// ingestion flowing while the reasoner runs (backlog 021).
fn run_automatic_proposal(store: &Arc<Mutex<EventStore>>, meeting_id: &str) -> Result<()> {
    let run = ProposalAgentRun {
        max_proposals: 1,
        record_no_proposal: true,
        debounce: Some(proposal_debounce_from_env()),
        ..ProposalAgentRun::default()
    };
    let projection = {
        let store = store.lock().expect("store lock");
        store.projection(meeting_id)?
    };
    // The model call happens here with NO store lock held.
    let decision = proposal_decision(&projection, &run, meeting_id)?;
    let store = store.lock().expect("store lock");
    record_proposal_decision(&store, meeting_id, &decision, &run)
}

/// Start local-Mac capture for a meeting. Records `meeting.started`, spawns the
/// helper, and streams its events in a background task. Idempotent: a second
/// start while one is running is a no-op.
pub async fn start_capture(state: AppState, meeting_id: String, mode: String) -> Result<()> {
    if state
        .captures
        .lock()
        .expect("captures lock")
        .contains_key(&meeting_id)
    {
        return Ok(());
    }

    let path = helper_path();
    let mut child = Command::new(&path)
        .arg("capture")
        .arg("--mode")
        .arg(&mode)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("spawn capture helper at {}", path.display()))?;

    // Record meeting.started only after the helper is actually running, so a
    // spawn failure leaves the meeting Idle, not a permanent WaitingPermission.
    {
        let store = state.store.lock().expect("store lock");
        store.append(
            &meeting_id,
            event_types::MEETING_STARTED,
            Some(&meeting_id),
            None,
            &Meeting {
                id: meeting_id.clone(),
                title: None,
                mode: Some(CaptureMode::parse(&mode)),
            },
        )?;
    }

    let stdout = child.stdout.take().context("capture helper stdout")?;
    if let Some(pid) = child.id() {
        state
            .captures
            .lock()
            .expect("captures lock")
            .insert(meeting_id.clone(), pid);
    }

    let store = state.store.clone();
    let captures = state.captures.clone();
    let meeting = meeting_id.clone();
    tokio::spawn(async move {
        let mut lines = BufReader::new(stdout).lines();
        // At most one in-flight proposal per meeting; the reader never waits on it.
        let proposing = Arc::new(AtomicBool::new(false));
        while let Ok(Some(line)) = lines.next_line().await {
            let Some(event) = HelperEvent::parse_line(&line) else {
                continue;
            };
            // Append the segment under the lock, then RELEASE it before any model
            // call so the next helper line is read immediately.
            let finalized = {
                let store = store.lock().expect("store lock");
                LocalMacAudioSource::normalize(&store, &meeting, event)
            };
            match finalized {
                Ok(Some(_)) => {
                    if !proposing.swap(true, Ordering::SeqCst) {
                        let store = store.clone();
                        let meeting = meeting.clone();
                        let proposing = proposing.clone();
                        tokio::task::spawn_blocking(move || {
                            if let Err(err) = run_automatic_proposal(&store, &meeting) {
                                tracing::warn!("proposal agent error for {meeting}: {err:#}");
                            }
                            proposing.store(false, Ordering::SeqCst);
                        });
                    }
                }
                Ok(None) => {}
                Err(err) => tracing::warn!("capture ingest error for {meeting}: {err}"),
            }
        }
        // Bound the reap so a helper that closes stdout but doesn't exit can't
        // wedge this task or leak the captures entry.
        if tokio::time::timeout(std::time::Duration::from_secs(10), child.wait())
            .await
            .is_err()
        {
            let _ = child.start_kill();
            let _ = child.wait().await;
        }
        // If the helper ended without a clean stop or an honest failure, it
        // crashed — record a terminal event so the UI never sits on a stale
        // "capturing" state with no explanation.
        {
            let store = store.lock().expect("store lock");
            if let Ok(projection) = store.projection(&meeting) {
                let source = &projection.source;
                if source.started && !source.stopped && source.failure.is_none() {
                    let _ = store.append(
                        &meeting,
                        event_types::SOURCE_FAILED,
                        Some(&meeting),
                        None,
                        &SourceFailed {
                            meeting_id: meeting.clone(),
                            source: TranscriptSourceKind::LocalMac,
                            reason: SourceFailureReason::HelperCrashed,
                            lane: None,
                            detail: Some("capture helper exited unexpectedly".to_string()),
                        },
                    );
                }
            }
        }
        captures.lock().expect("captures lock").remove(&meeting);
    });

    Ok(())
}

/// Stop capture for a meeting by sending SIGTERM so the helper finalizes its
/// transcribers and emits `source.stopped` before exiting.
pub fn stop_capture(state: &AppState, meeting_id: &str) -> Result<()> {
    let pid = state
        .captures
        .lock()
        .expect("captures lock")
        .get(meeting_id)
        .copied();
    if let Some(pid) = pid {
        // Graceful: the helper finalizes its transcribers and emits
        // `source.stopped` before exiting.
        std::process::Command::new("kill")
            .arg("-TERM")
            .arg(pid.to_string())
            .status()
            .ok();
    } else {
        // No live helper in this daemon (e.g. the capture was orphaned by a
        // prior daemon restart, whose in-memory pid map did not survive). Stop
        // must never be a silent no-op: reconcile the ledger directly so the UI
        // leaves the false "capturing" state.
        state
            .store
            .lock()
            .expect("store lock")
            .reconcile_stopped_if_orphaned(meeting_id)?;
    }
    Ok(())
}
