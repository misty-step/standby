//! Supervises the native capture helper subprocess for a meeting and streams
//! its JSONL stdout into the event log via [`LocalMacAudioSource`]. The daemon
//! owns process lifecycle; the helper owns the macOS frameworks. Worker
//! execution lives elsewhere — this module never spawns workers.

use crate::AppState;
use anyhow::{Context, Result};
use standby_core::{CaptureMode, HelperEvent, LocalMacAudioSource, Meeting, event_types};
use std::path::PathBuf;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

/// Resolve the native helper binary: `STANDBY_CAPTURE_HELPER` overrides the
/// default build output path.
pub fn helper_path() -> PathBuf {
    if let Ok(path) = std::env::var("STANDBY_CAPTURE_HELPER") {
        return PathBuf::from(path);
    }
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../native/standby-capture-helper/build/standby-capture-helper")
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

    let path = helper_path();
    let mut child = Command::new(&path)
        .arg("capture")
        .arg("--mode")
        .arg(&mode)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("spawn capture helper at {}", path.display()))?;

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
        while let Ok(Some(line)) = lines.next_line().await {
            let Some(event) = HelperEvent::parse_line(&line) else {
                continue;
            };
            let store = store.lock().expect("store lock");
            if let Err(err) = LocalMacAudioSource::ingest(&store, &meeting, event) {
                tracing::warn!("capture ingest error for {meeting}: {err}");
            }
        }
        let _ = child.wait().await;
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
        std::process::Command::new("kill")
            .arg("-TERM")
            .arg(pid.to_string())
            .status()
            .ok();
    }
    Ok(())
}
