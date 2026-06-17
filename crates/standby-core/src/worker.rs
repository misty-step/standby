//! Out-of-request worker execution. Approval enqueues an [`AgentJobSpec`]; a
//! claim loop (in the daemon) calls [`run_job`], which launches a real CLI
//! subprocess inside a macOS `sandbox-exec` jail whose only writable target is
//! the job scratch directory. Network is denied for read-only/local profiles.
//!
//! The security property — "an approved meeting card cannot mutate the repo,
//! escape its scratch, or send externally" — is enforced by the OS sandbox, not
//! by trusting the CLI's own flags. `verify-worker-sandbox.sh` proves it with a
//! deliberately malicious worker fixture.

use crate::{
    AgentJobSpec, Artifact, DeliverableSpec, EventStore, JobBudget, JobContext, JobFailureReason,
    JobStatus, PermissionProfile, Proposal, ProposalStatus, WorkerKind, event_types, new_id,
};
use anyhow::{Context, Result};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// A worker profile: which program to launch, its argument template, and
/// whether the OS sandbox permits network (needed for cloud-model CLIs, denied
/// for local/deterministic workers). Args support `{scratch}`, `{prompt_file}`,
/// and `{prompt}` placeholders.
#[derive(Debug, Clone)]
pub struct WorkerProfile {
    pub id: String,
    pub program: String,
    pub args: Vec<String>,
    pub allow_network: bool,
    /// Exact env var names forwarded to the worker (network profiles only).
    /// Scoped per profile so a worker never sees unrelated credentials.
    pub auth_env_keys: Vec<String>,
}

impl WorkerProfile {
    /// Deterministic local worker: a committed shell script that writes a
    /// research-shaped artifact to scratch. No network, no model, no cost — the
    /// default profile for the gate.
    pub fn local_research(worker_script: &Path) -> Self {
        Self {
            id: "local-research".to_string(),
            program: "bash".to_string(),
            args: vec![
                worker_script.display().to_string(),
                "{scratch}".to_string(),
                "{prompt_file}".to_string(),
            ],
            allow_network: false,
            auth_env_keys: vec![],
        }
    }

    /// Claude Code read-only research profile.
    ///
    /// NOT SANDBOX-ACCEPTED in this slice: a cloud-model worker needs network
    /// egress, and `sandbox-exec` cannot reliably scope egress to just the model
    /// API. Network + the reads a CLI needs is a secret-exfil channel that CLI
    /// tool-flags (`--disallowedTools`) do not close. Gated behind
    /// `STANDBY_ALLOW_NETWORK_WORKER=1` and never the default. See AGENTS.md.
    pub fn claude_research() -> Self {
        Self {
            id: "claude-research".to_string(),
            program: "claude".to_string(),
            args: vec![
                "-p".to_string(),
                "--output-format".to_string(),
                "json".to_string(),
                "--disallowedTools".to_string(),
                "Bash".to_string(),
                "--disallowedTools".to_string(),
                "Edit".to_string(),
                "--disallowedTools".to_string(),
                "Write".to_string(),
                "{prompt}".to_string(),
            ],
            allow_network: true,
            auth_env_keys: vec!["ANTHROPIC_API_KEY".to_string()],
        }
    }

    /// Pi read-only fallback profile (`--no-tools`). Same egress caveat and gate
    /// as [`claude_research`].
    pub fn pi_research() -> Self {
        Self {
            id: "pi-research".to_string(),
            program: "pi".to_string(),
            args: vec![
                "-p".to_string(),
                "--no-tools".to_string(),
                "--format".to_string(),
                "json".to_string(),
                "{prompt}".to_string(),
            ],
            allow_network: true,
            auth_env_keys: vec![
                "ANTHROPIC_API_KEY".to_string(),
                "OPENAI_API_KEY".to_string(),
            ],
        }
    }

    /// Build a profile by id, resolving the local worker script relative to the
    /// given repo root. The default and only sandbox-accepted profile is the
    /// network-denied local worker. Cloud-model (network-allowed) profiles are
    /// only honored when `STANDBY_ALLOW_NETWORK_WORKER=1` is set; otherwise any
    /// id falls back to the safe local profile.
    pub fn by_id(id: &str, repo_root: &Path) -> Self {
        let local = || Self::local_research(&repo_root.join("scripts/workers/local-research-worker.sh"));
        let network_workers_enabled =
            std::env::var("STANDBY_ALLOW_NETWORK_WORKER").ok().as_deref() == Some("1");
        match id {
            "claude-research" if network_workers_enabled => Self::claude_research(),
            "pi-research" if network_workers_enabled => Self::pi_research(),
            _ => local(),
        }
    }

    /// An arbitrary program under the same sandbox — used by the sandbox
    /// negative test to run a deliberately malicious worker fixture.
    pub fn custom(id: &str, program: &str, args: Vec<String>, allow_network: bool) -> Self {
        Self {
            id: id.to_string(),
            program: program.to_string(),
            args,
            allow_network,
            auth_env_keys: vec![],
        }
    }
}

/// Build a queued research job from an approved proposal. Permissions are
/// read-only: external mutation is not allowed and requires extra approval.
pub fn build_job_spec(
    proposal: &Proposal,
    approved_by: &str,
    prompt_override: Option<String>,
    profile_id: &str,
) -> AgentJobSpec {
    AgentJobSpec {
        id: new_id("job"),
        meeting_id: proposal.meeting_id.clone(),
        proposal_id: Some(proposal.id.clone()),
        worker: WorkerKind::ResearchAgent,
        title: proposal.title.clone(),
        prompt: prompt_override.unwrap_or_else(|| proposal.draft_prompt.clone()),
        context: JobContext {
            meeting_title: None,
            topic: Some(proposal.title.clone()),
            approved_by: approved_by.to_string(),
            transcript_spans: proposal
                .evidence
                .iter()
                .map(|evidence| evidence.segment_id.clone())
                .collect(),
            meeting_state_snapshot_id: None,
        },
        budget: JobBudget {
            max_minutes: 5,
            max_cost_usd: Some(1.0),
        },
        deliverable: DeliverableSpec {
            description: "Short research briefing with cited sources, written to the job scratch."
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
        profile: Some(profile_id.to_string()),
        progress_note: None,
        failure_reason: None,
        error: None,
        receipt_path: None,
    }
}

/// Approve a proposal: persist `proposal.approved` and a queued
/// `agent_job.requested`. This is the only thing the HTTP approval path does —
/// it never launches the worker. Returns the queued job.
pub fn approve_proposal(
    store: &EventStore,
    proposal: &Proposal,
    approved_by: &str,
    prompt_override: Option<String>,
    profile_id: &str,
) -> Result<AgentJobSpec> {
    let mut approved = proposal.clone();
    approved.status = ProposalStatus::Approved;
    store.append(
        &proposal.meeting_id,
        event_types::PROPOSAL_APPROVED,
        Some(&proposal.id),
        None,
        &approved,
    )?;

    let job = build_job_spec(proposal, approved_by, prompt_override, profile_id);
    store.append(
        &job.meeting_id,
        event_types::JOB_REQUESTED,
        Some(&proposal.id),
        None,
        &job,
    )?;
    Ok(job)
}

/// Generate the `sandbox-exec` profile: deny by default, allow reads, allow
/// writes only under the (canonicalized) scratch dir plus harmless device
/// nodes, and allow network only when the profile requires it.
pub fn sandbox_profile(scratch_canonical: &Path, allow_network: bool) -> String {
    let network = if allow_network {
        "(allow network*)"
    } else {
        "(deny network*)"
    };
    // Defense in depth: deny reads of common secret stores so even a
    // network-allowed worker can't read them to exfiltrate. SBPL is last-match
    // wins, so these override the broad file-read* above. The accepted profile is
    // network-denied, where exfil is impossible regardless.
    let mut deny_reads = String::new();
    if let Ok(home) = std::env::var("HOME") {
        for secret in [
            ".ssh",
            ".aws",
            ".gnupg",
            ".netrc",
            ".config/gcloud",
            "Library/Keychains",
            ".docker/config.json",
        ] {
            deny_reads.push_str(&format!("(deny file-read* (subpath \"{home}/{secret}\"))\n"));
        }
    }
    format!(
        "(version 1)\n\
         (deny default)\n\
         (allow process-exec)\n\
         (allow process-fork)\n\
         (allow sysctl-read)\n\
         (allow mach-lookup)\n\
         (allow signal (target self))\n\
         (allow file-read*)\n\
         {deny_reads}\
         (allow file-write* (subpath \"{scratch}\"))\n\
         (allow file-write-data\n\
         \t(literal \"/dev/null\")\n\
         \t(literal \"/dev/dtracehelper\")\n\
         \t(literal \"/dev/random\")\n\
         \t(literal \"/dev/urandom\"))\n\
         {network}\n",
        scratch = scratch_canonical.display(),
        deny_reads = deny_reads,
        network = network,
    )
}

fn minimal_env(profile: &WorkerProfile) -> Vec<(String, String)> {
    let mut env = vec![(
        "PATH".to_string(),
        std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin:/usr/local/bin".to_string()),
    )];
    // Cloud-model CLIs need just enough to find their auth; local workers get
    // none. Forward only the profile's explicit auth keys — never a fuzzy match —
    // so a worker can't read unrelated credentials from its environment.
    if profile.allow_network {
        if let Ok(home) = std::env::var("HOME") {
            env.push(("HOME".to_string(), home));
        }
        for key in &profile.auth_env_keys {
            if let Ok(value) = std::env::var(key) {
                env.push((key.clone(), value));
            }
        }
    }
    env
}

fn substitute(arg: &str, scratch: &Path, prompt_file: &Path, prompt: &str) -> String {
    arg.replace("{scratch}", &scratch.display().to_string())
        .replace("{prompt_file}", &prompt_file.display().to_string())
        .replace("{prompt}", prompt)
}

/// Run a queued job to completion inside the sandbox, emitting normalized
/// started/progress/artifact/completed/failed events. Synchronous so it can be
/// driven directly from tests and from `spawn_blocking` in the daemon.
pub fn run_job(
    store: &EventStore,
    job: &AgentJobSpec,
    profile: &WorkerProfile,
    scratch_root: &Path,
) -> Result<JobStatus> {
    // Emit started up front so any later failure — including a setup error or a
    // panic — is a visible transition, never a job stuck Queued with no event.
    let mut running = job.clone();
    running.status = JobStatus::Running;
    running.profile = Some(profile.id.clone());
    running.progress_note = Some(format!("preparing sandbox for {}", profile.program));
    store.append(
        &job.meeting_id,
        event_types::JOB_STARTED,
        job.proposal_id.as_deref(),
        None,
        &running,
    )?;

    // Fallible setup. On any error, record a terminal failure instead of bubbling
    // up with no further event. Scratch is canonicalized so the sandbox subpath
    // matches the kernel's resolved path (e.g. /tmp -> /private/tmp).
    let setup = (|| -> Result<(PathBuf, PathBuf, PathBuf)> {
        let job_dir = scratch_root.join(&job.id);
        fs::create_dir_all(&job_dir).context("create job scratch")?;
        let job_dir = fs::canonicalize(&job_dir).context("canonicalize job scratch")?;
        let prompt_file = job_dir.join("prompt.txt");
        fs::write(&prompt_file, &job.prompt).context("write prompt")?;
        let profile_path = job_dir.join("sandbox.sb");
        fs::write(
            &profile_path,
            sandbox_profile(&job_dir, profile.allow_network),
        )
        .context("write sandbox profile")?;
        Ok((job_dir, prompt_file, profile_path))
    })();
    let (job_dir, prompt_file, profile_path) = match setup {
        Ok(paths) => paths,
        Err(err) => {
            return finish_failed(
                store,
                job,
                profile,
                JobFailureReason::Unknown,
                &format!("sandbox setup failed: {err}"),
                "",
            );
        }
    };
    let stdout_path = job_dir.join("stdout.log");
    let stderr_path = job_dir.join("stderr.log");
    let receipt = stdout_path.display().to_string();

    // sandbox-exec -f <profile> <program> <args...>
    let mut args = vec!["-f".to_string(), profile_path.display().to_string()];
    args.push(profile.program.clone());
    for arg in &profile.args {
        args.push(substitute(arg, &job_dir, &prompt_file, &job.prompt));
    }

    let stdout_file = fs::File::create(&stdout_path).context("create stdout log")?;
    let stderr_file = fs::File::create(&stderr_path).context("create stderr log")?;
    let spawn = Command::new("sandbox-exec")
        .args(&args)
        .current_dir(&job_dir)
        .env_clear()
        .envs(minimal_env(profile))
        .stdin(Stdio::null())
        .stdout(stdout_file)
        .stderr(stderr_file)
        .spawn();

    let mut child = match spawn {
        Ok(child) => child,
        Err(err) => {
            return finish_failed(
                store,
                job,
                profile,
                JobFailureReason::CliNotFound,
                &format!("could not launch sandbox: {err}"),
                &receipt,
            );
        }
    };

    let budget = Duration::from_secs((job.budget.max_minutes as u64 * 60).clamp(5, 900));
    let deadline = Instant::now() + budget;
    let status = loop {
        match child.try_wait().context("poll worker")? {
            Some(status) => break status,
            None => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return finish_failed(
                        store,
                        job,
                        profile,
                        JobFailureReason::Timeout,
                        &format!("worker exceeded {}s budget", budget.as_secs()),
                        &receipt,
                    );
                }
                std::thread::sleep(Duration::from_millis(40));
            }
        }
    };

    let stderr_tail = read_tail(&stderr_path, 600);
    if status.success() {
        let artifact_path = job_dir.join("artifact.md");
        let summary = if artifact_path.exists() {
            read_tail(&artifact_path, 600)
        } else {
            read_tail(&stdout_path, 600)
        };
        let uri = if artifact_path.exists() {
            format!("file://{}", artifact_path.display())
        } else {
            format!("file://{}", stdout_path.display())
        };
        let artifact = Artifact {
            id: new_id("artifact"),
            job_id: job.id.clone(),
            title: format!("{} result", job.title),
            summary: if summary.trim().is_empty() {
                "Worker completed with an empty artifact.".to_string()
            } else {
                summary
            },
            uri: Some(uri),
        };
        store.append(
            &job.meeting_id,
            event_types::ARTIFACT_CREATED,
            job.proposal_id.as_deref(),
            None,
            &artifact,
        )?;

        let mut done = running;
        done.status = JobStatus::Completed;
        done.progress_note = Some("worker completed".to_string());
        done.receipt_path = Some(receipt);
        store.append(
            &job.meeting_id,
            event_types::JOB_COMPLETED,
            job.proposal_id.as_deref(),
            None,
            &done,
        )?;
        Ok(JobStatus::Completed)
    } else {
        let reason = classify_failure(&stderr_tail);
        finish_failed(store, job, profile, reason, &stderr_tail, &receipt)
    }
}

fn finish_failed(
    store: &EventStore,
    job: &AgentJobSpec,
    profile: &WorkerProfile,
    reason: JobFailureReason,
    detail: &str,
    receipt: &str,
) -> Result<JobStatus> {
    let mut failed = job.clone();
    failed.status = JobStatus::Failed;
    failed.profile = Some(profile.id.clone());
    failed.failure_reason = Some(reason);
    failed.error = Some(truncate(detail, 500));
    failed.receipt_path = Some(receipt.to_string());
    store.append(
        &job.meeting_id,
        event_types::JOB_FAILED,
        job.proposal_id.as_deref(),
        None,
        &failed,
    )?;
    Ok(JobStatus::Failed)
}

/// Force a terminal failure event for a job whose runner errored or panicked
/// outside `run_job`. The daemon calls this so a job is never silently lost even
/// if the worker thread itself dies.
pub fn emit_job_failed(
    store: &EventStore,
    job: &AgentJobSpec,
    reason: JobFailureReason,
    detail: &str,
) -> Result<()> {
    let mut failed = job.clone();
    failed.status = JobStatus::Failed;
    failed.failure_reason = Some(reason);
    failed.error = Some(truncate(detail, 500));
    store.append(
        &job.meeting_id,
        event_types::JOB_FAILED,
        job.proposal_id.as_deref(),
        None,
        &failed,
    )?;
    Ok(())
}

fn classify_failure(stderr_tail: &str) -> JobFailureReason {
    let lower = stderr_tail.to_lowercase();
    if lower.contains("command not found") || lower.contains("no such file") {
        JobFailureReason::CliNotFound
    } else if lower.contains("auth")
        || lower.contains("login")
        || lower.contains("api key")
        || lower.contains("unauthorized")
    {
        JobFailureReason::AuthRequired
    } else {
        JobFailureReason::NonzeroExit
    }
}

fn read_tail(path: &Path, max_bytes: usize) -> String {
    let content = fs::read_to_string(path).unwrap_or_default();
    truncate(&content, max_bytes)
}

fn truncate(text: &str, max: usize) -> String {
    let trimmed = text.trim();
    if trimmed.len() <= max {
        trimmed.to_string()
    } else {
        let start = trimmed.len() - max;
        // Respect char boundaries.
        let mut idx = start;
        while idx < trimmed.len() && !trimmed.is_char_boundary(idx) {
            idx += 1;
        }
        format!("…{}", &trimmed[idx..])
    }
}

/// Resolve the default scratch root: `<STANDBY_DB dir or .standby>/jobs`.
pub fn default_scratch_root() -> PathBuf {
    PathBuf::from(".standby/jobs")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ProposalEngine, demo_meeting_segments};
    use std::io::Write;

    fn temp_dir(tag: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!("standby-worker-{tag}-{}", new_id("t")));
        fs::create_dir_all(&base).unwrap();
        base
    }

    fn approved_job(store: &EventStore, meeting: &str) -> AgentJobSpec {
        let segments = demo_meeting_segments(meeting);
        let proposal =
            ProposalEngine::detect_research_proposal(meeting, &segments, &[]).expect("proposal");
        approve_proposal(store, &proposal, "tester", None, "local-research").unwrap()
    }

    #[test]
    fn local_worker_produces_real_artifact_in_scratch() {
        let meeting = "m_worker_ok";
        let store = EventStore::memory().unwrap();
        let job = approved_job(&store, meeting);

        // A tiny real worker: reads the prompt file, writes an artifact to scratch.
        let script_dir = temp_dir("script");
        let script = script_dir.join("worker.sh");
        let mut file = fs::File::create(&script).unwrap();
        writeln!(
            file,
            "#!/usr/bin/env bash\nset -euo pipefail\nSCRATCH=\"$1\"\nPROMPT_FILE=\"$2\"\nprintf 'Briefing for: %s\\n' \"$(head -c 40 \"$PROMPT_FILE\")\" > \"$SCRATCH/artifact.md\"\necho done"
        )
        .unwrap();

        let profile = WorkerProfile::local_research(&script);
        let scratch_root = temp_dir("scratch");
        let status = run_job(&store, &job, &profile, &scratch_root).unwrap();
        assert_eq!(status, JobStatus::Completed);

        let projection = store.projection(meeting).unwrap();
        assert_eq!(projection.jobs.len(), 1);
        assert_eq!(projection.jobs[0].status, JobStatus::Completed);
        assert_eq!(projection.artifacts.len(), 1);
        assert!(projection.artifacts[0].summary.contains("Briefing for"));
    }

    #[test]
    fn approval_only_enqueues_does_not_run() {
        let meeting = "m_enqueue";
        let store = EventStore::memory().unwrap();
        let _job = approved_job(&store, meeting);
        let projection = store.projection(meeting).unwrap();
        // Exactly one queued job, no started/completed/artifact yet.
        assert_eq!(projection.jobs.len(), 1);
        assert_eq!(projection.jobs[0].status, JobStatus::Queued);
        assert!(projection.artifacts.is_empty());
        assert!(!store.has_event_type(meeting, event_types::JOB_STARTED).unwrap());
    }

    #[test]
    fn setup_failure_still_emits_terminal_event() {
        // A scratch root under a file can't be created; the job must not get stuck
        // Queued — it must transition started -> failed with a reason.
        let meeting = "m_setupfail";
        let store = EventStore::memory().unwrap();
        let job = approved_job(&store, meeting);
        let profile = WorkerProfile::local_research(Path::new("/nonexistent/worker.sh"));
        let status = run_job(&store, &job, &profile, Path::new("/dev/null/scratch")).unwrap();

        assert_eq!(status, JobStatus::Failed);
        let projection = store.projection(meeting).unwrap();
        assert_eq!(projection.jobs[0].status, JobStatus::Failed);
        assert!(store.has_event_type(meeting, event_types::JOB_STARTED).unwrap());
        assert!(store.has_event_type(meeting, event_types::JOB_FAILED).unwrap());
        assert!(projection.jobs[0].failure_reason.is_some());
    }

    #[test]
    fn by_id_defaults_to_network_denied_local_profile() {
        // Without the explicit opt-in, even a cloud id must resolve to the safe
        // network-denied local profile.
        if std::env::var("STANDBY_ALLOW_NETWORK_WORKER").ok().as_deref() == Some("1") {
            return; // opt-in is active in this environment; skip
        }
        let profile = WorkerProfile::by_id("claude-research", Path::new("/repo"));
        assert_eq!(profile.id, "local-research");
        assert!(!profile.allow_network);
        assert!(profile.auth_env_keys.is_empty());
    }
}
