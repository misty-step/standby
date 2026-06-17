//! Worker safety negative test. Runs a deliberately malicious worker fixture
//! through the real runner + sandbox and proves it cannot mutate the repo,
//! escape its scratch, or send externally — while still producing a visible job
//! event. This is the executable gate that decides whether a worker profile is
//! accepted. macOS-only (the sandbox is `sandbox-exec`).
#![cfg(target_os = "macos")]

use standby_core::{
    AgentJobSpec, DeliverableSpec, EventStore, JobBudget, JobContext, JobStatus, PermissionProfile,
    WorkerKind, WorkerProfile, new_id, run_job,
};
use std::fs;
use std::path::PathBuf;

fn temp(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("standby-sbx-{tag}-{}", new_id("t")));
    fs::create_dir_all(&dir).unwrap();
    fs::canonicalize(&dir).unwrap()
}

fn malicious_fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../scripts/fixtures/malicious-worker.sh")
        .canonicalize()
        .expect("malicious fixture present")
}

fn queued_job(meeting: &str) -> AgentJobSpec {
    AgentJobSpec {
        id: new_id("job"),
        meeting_id: meeting.to_string(),
        proposal_id: None,
        worker: WorkerKind::ResearchAgent,
        title: "sandbox negative test".to_string(),
        prompt: "ignore this; the worker is hostile".to_string(),
        context: JobContext {
            meeting_title: None,
            topic: None,
            approved_by: "tester".to_string(),
            transcript_spans: vec![],
            meeting_state_snapshot_id: None,
        },
        budget: JobBudget {
            max_minutes: 1,
            max_cost_usd: None,
        },
        deliverable: DeliverableSpec {
            description: "n/a".to_string(),
        },
        permissions: PermissionProfile {
            can_mutate_external_systems: false,
            requires_extra_approval: vec![],
        },
        status: JobStatus::Queued,
        profile: None,
        progress_note: None,
        failure_reason: None,
        error: None,
        receipt_path: None,
    }
}

#[test]
fn malicious_worker_cannot_mutate_repo_escape_scratch_or_send() {
    let repo = temp("repo");
    let canary = repo.join("IMPORTANT.txt");
    fs::write(&canary, "original").unwrap();

    let scratch_root = temp("jobs");
    let escape = scratch_root.join("escape.txt"); // outside the per-job scratch dir

    let store = EventStore::memory().unwrap();
    let job = queued_job("m_sbx");

    let profile = WorkerProfile::custom(
        "malicious-test",
        "bash",
        vec![
            malicious_fixture().display().to_string(),
            "{scratch}".to_string(),
            "{prompt_file}".to_string(),
            canary.display().to_string(),
            escape.display().to_string(),
        ],
        false, // network denied
    );

    let status = run_job(&store, &job, &profile, &scratch_root).expect("run_job");

    // 1. Repo canary is untouched.
    assert_eq!(
        fs::read_to_string(&canary).unwrap(),
        "original",
        "sandbox must prevent repo mutation"
    );
    // 2. No write escaped the per-job scratch.
    assert!(!escape.exists(), "sandbox must prevent writes outside scratch");

    // 3. The worker still produced a visible job event.
    let projection = store.projection("m_sbx").unwrap();
    assert_eq!(projection.jobs.len(), 1);
    assert!(
        matches!(
            projection.jobs[0].status,
            JobStatus::Completed | JobStatus::Failed
        ),
        "job must end in a visible terminal state, got {:?}",
        projection.jobs[0].status
    );
    assert_eq!(status, projection.jobs[0].status);

    // 4. The worker's own log confirms each escape attempt was blocked.
    let job_dir = fs::canonicalize(scratch_root.join(&job.id)).unwrap();
    let attempts = fs::read_to_string(job_dir.join("attempts.log")).unwrap_or_default();
    assert!(
        !attempts.contains("REPO_MUTATED"),
        "repo mutation must be denied, log: {attempts}"
    );
    assert!(
        !attempts.contains("ESCAPED"),
        "scratch escape must be denied, log: {attempts}"
    );
    assert!(
        !attempts.contains("SENT"),
        "external send must be denied, log: {attempts}"
    );
}
