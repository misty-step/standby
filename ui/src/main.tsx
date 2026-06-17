import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  AlertTriangle,
  Bot,
  CheckCircle2,
  ChevronDown,
  Clock3,
  FileText,
  Mic2,
  MicOff,
  PlayCircle,
  Search,
  Settings,
  Sparkles,
  Square,
  Users,
  Volume2,
  VolumeX,
  XCircle,
} from "lucide-react";
import "./styles.css";

type JobStatus = "queued" | "running" | "needs_input" | "completed" | "failed" | "canceled";
type SourceStatus =
  | "idle"
  | "demo"
  | "waiting_permission"
  | "capturing"
  | "transcribing"
  | "no_mic_audio"
  | "no_system_audio"
  | "failed"
  | "stopped";

type TranscriptSegment = {
  id: string;
  speaker: string | null;
  start_ms: number;
  end_ms: number;
  text: string;
  is_final: boolean;
  source: string;
};

type TranscriptEvidence = { segment_id: string; speaker: string | null; text: string };

type Proposal = {
  id: string;
  kind: string;
  title: string;
  rationale: string;
  draft_prompt: string;
  evidence: TranscriptEvidence[];
  suggested_worker: string;
  confidence: number;
  status: "proposed" | "approved" | "ignored";
};

type AgentJobSpec = {
  id: string;
  title: string;
  status: JobStatus;
  profile: string | null;
  progress_note: string | null;
  failure_reason: string | null;
  error: string | null;
  receipt_path: string | null;
};

type Artifact = { id: string; job_id: string; title: string; summary: string; uri: string | null };

type LaneState = {
  expected: boolean;
  active: boolean;
  last_rms: number | null;
  captured_ms: number;
  level_events: number;
};

type SourceFailure = { reason: string; lane: string | null; detail: string | null };

type SourceState = {
  status: SourceStatus;
  source: string | null;
  mode: string | null;
  microphone: LaneState;
  system_audio: LaneState;
  failure: SourceFailure | null;
  started: boolean;
  stopped: boolean;
};

type MeetingProjection = {
  meeting_id: string;
  title: string | null;
  transcript: TranscriptSegment[];
  partial: TranscriptSegment | null;
  source: SourceState;
  proposals: Proposal[];
  jobs: AgentJobSpec[];
  artifacts: Artifact[];
};

const params = new URLSearchParams(window.location.search);
const meetingId = params.get("meeting") ?? "live";
const mode = params.get("mode") ?? "live";
const isDemo = mode === "demo";

const STATUS_LABEL: Record<SourceStatus, { label: string; tone: string }> = {
  idle: { label: "Idle", tone: "idle" },
  demo: { label: "Demo", tone: "demo" },
  waiting_permission: { label: "Waiting for permission", tone: "warn" },
  capturing: { label: "Capturing", tone: "live" },
  transcribing: { label: "Transcribing", tone: "live" },
  no_mic_audio: { label: "No microphone audio", tone: "warn" },
  no_system_audio: { label: "No system audio", tone: "warn" },
  failed: { label: "Capture failed", tone: "error" },
  stopped: { label: "Stopped", tone: "idle" },
};

const FAILURE_TEXT: Record<string, string> = {
  mic_permission_denied:
    "Microphone permission denied. Grant it in System Settings › Privacy & Security › Microphone, then start again.",
  screen_recording_permission_denied:
    "Screen & System Audio Recording permission denied. Grant it in System Settings › Privacy & Security › Screen Recording, then start again.",
  no_input_device: "No audio input device was found.",
  helper_crashed: "The capture helper stopped unexpectedly.",
  unsupported: "This capture mode is not supported.",
  unknown: "Capture failed for an unknown reason.",
};

const JOB_LABEL: Record<JobStatus, string> = {
  queued: "Queued",
  running: "Running",
  needs_input: "Needs input",
  completed: "Completed",
  failed: "Failed",
  canceled: "Canceled",
};

async function post(path: string): Promise<MeetingProjection> {
  const response = await fetch(path, { method: "POST", headers: { "content-type": "application/json" } });
  if (!response.ok) throw new Error(`${path} -> ${response.status}`);
  return response.json();
}

function App() {
  const [projection, setProjection] = useState<MeetingProjection | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function refresh() {
    const response = await fetch(`/api/meetings/${meetingId}`);
    if (!response.ok) throw new Error(`projection failed: ${response.status}`);
    setProjection(await response.json());
  }

  async function act(fn: () => Promise<MeetingProjection>) {
    setBusy(true);
    setError(null);
    try {
      setProjection(await fn());
    } catch (err) {
      setError(err instanceof Error ? err.message : "request failed");
    } finally {
      setBusy(false);
    }
  }

  useEffect(() => {
    // The normal route never auto-starts demo. Demo is opt-in via ?mode=demo.
    if (isDemo) {
      act(() => post(`/api/meetings/${meetingId}/demo`));
    } else {
      refresh().catch((err) => setError(err instanceof Error ? err.message : "load failed"));
    }
    const interval = window.setInterval(() => {
      refresh().catch(() => undefined);
    }, 2000);
    return () => window.clearInterval(interval);
  }, []);

  const source = projection?.source;
  const status: SourceStatus = source?.status ?? "idle";
  const activeProposal = projection?.proposals.find((proposal) => proposal.status === "proposed");
  const latestJob = projection?.jobs.at(-1) ?? null;
  const latestArtifact = projection?.artifacts.at(-1) ?? null;
  const capturing = status === "capturing" || status === "transcribing" || status === "no_mic_audio" || status === "no_system_audio";

  return (
    <div className="app-shell">
      <Sidebar status={status} title={projection?.title ?? null} />
      <main className="workspace">
        <TopBar status={status} title={projection?.title ?? (isDemo ? "Demo meeting" : "Live meeting")} />
        <SourceBanner status={status} source={source ?? null} />
        <section className="content-grid">
          <section className="transcript-panel">
            <CaptureControls
              isDemo={isDemo}
              capturing={capturing}
              busy={busy}
              onStart={() => act(() => post(`/api/meetings/${meetingId}/capture/start?mode=mic%2Bsystem`))}
              onStop={() => act(() => post(`/api/meetings/${meetingId}/capture/stop`))}
              onDemo={() => act(() => post(`/api/meetings/${meetingId}/demo`))}
            />
            {error ? <div className="failure-note">{error}</div> : null}
            <TranscriptList
              segments={projection?.transcript ?? []}
              partial={projection?.partial ?? null}
              status={status}
            />
          </section>
          <aside className="work-panel" aria-label="Proposal and job cards">
            {activeProposal ? (
              <ProposalCard
                proposal={activeProposal}
                onApprove={() => act(() => approveProposal(activeProposal))}
                onIgnore={() => act(() => post(`/api/proposals/${activeProposal.id}/ignore`))}
              />
            ) : (
              <EmptyProposal status={status} />
            )}
            {latestJob ? <JobCard job={latestJob} /> : null}
            {latestArtifact ? <ResultCard artifact={latestArtifact} /> : null}
          </aside>
        </section>
      </main>
    </div>
  );
}

async function approveProposal(proposal: Proposal): Promise<MeetingProjection> {
  const response = await fetch(`/api/proposals/${proposal.id}/approve`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ approved_by: "Phaedrus", prompt: proposal.draft_prompt }),
  });
  if (!response.ok) throw new Error(`approval failed: ${response.status}`);
  return response.json();
}

function Sidebar({ status, title }: { status: SourceStatus; title: string | null }) {
  const navItems = [
    [Mic2, "Meeting"],
    [FileText, "Notes"],
    [Bot, "Jobs"],
    [Settings, "Settings"],
  ] as const;
  const tone = STATUS_LABEL[status].tone;
  return (
    <aside className="sidebar">
      <div className="brand-block">
        <div className="window-dots" aria-hidden="true">
          <span className="dot red" />
          <span className="dot yellow" />
          <span className="dot green" />
        </div>
        <div className="brand-mark">S</div>
        <strong>Standby</strong>
      </div>
      <nav className="nav-list" aria-label="Primary">
        {navItems.map(([Icon, label], index) => (
          <button key={label} className={`nav-item ${index === 0 ? "active" : ""}`}>
            <Icon size={18} />
            <span>{label}</span>
          </button>
        ))}
      </nav>
      <div className="meeting-card">
        <div className="meeting-row">
          <strong>{title ?? "No meeting"}</strong>
          <span className={`live-pill ${tone}`}>{STATUS_LABEL[status].label}</span>
        </div>
        <p>Local capture · macOS</p>
      </div>
    </aside>
  );
}

function TopBar({ status, title }: { status: SourceStatus; title: string }) {
  const meta = STATUS_LABEL[status];
  return (
    <header className="topbar">
      <div className="status-cluster">
        <span className={`status-dot ${meta.tone}`} />
        <strong>{meta.label}</strong>
        <span className="divider" />
        <span>{title}</span>
      </div>
      <div className="status-cluster right">
        <Settings size={18} />
      </div>
    </header>
  );
}

function SourceBanner({ status, source }: { status: SourceStatus; source: SourceState | null }) {
  const meta = STATUS_LABEL[status];
  if (status === "idle") {
    return (
      <div className={`source-banner idle`}>
        <span>Not capturing. Start capture to listen to the call on this Mac.</span>
      </div>
    );
  }
  return (
    <div className={`source-banner ${meta.tone}`}>
      <div className="source-banner-main">
        {status === "failed" ? <AlertTriangle size={16} /> : <Mic2 size={16} />}
        <strong>{meta.label}</strong>
        {source?.failure ? (
          <span className="failure-note inline">
            {FAILURE_TEXT[source.failure.reason] ?? source.failure.detail ?? source.failure.reason}
          </span>
        ) : null}
      </div>
      {source ? <LaneMeters source={source} /> : null}
    </div>
  );
}

function LaneMeters({ source }: { source: SourceState }) {
  return (
    <div className="lane-meters">
      <LaneMeter
        label="Mic"
        lane={source.microphone}
        OnIcon={Mic2}
        OffIcon={MicOff}
      />
      <LaneMeter
        label="System"
        lane={source.system_audio}
        OnIcon={Volume2}
        OffIcon={VolumeX}
      />
    </div>
  );
}

function LaneMeter({
  label,
  lane,
  OnIcon,
  OffIcon,
}: {
  label: string;
  lane: LaneState;
  OnIcon: typeof Mic2;
  OffIcon: typeof MicOff;
}) {
  if (!lane.expected) return null;
  const level = Math.min(100, Math.round((lane.last_rms ?? 0) * 600));
  const Icon = lane.active ? OnIcon : OffIcon;
  return (
    <div className={`lane-meter ${lane.active ? "active" : "silent"}`} title={`${label} RMS ${(lane.last_rms ?? 0).toFixed(3)}`}>
      <Icon size={15} />
      <span>{label}</span>
      <span className="lane-bar">
        <span style={{ width: `${level}%` }} />
      </span>
    </div>
  );
}

function CaptureControls({
  isDemo,
  capturing,
  busy,
  onStart,
  onStop,
  onDemo,
}: {
  isDemo: boolean;
  capturing: boolean;
  busy: boolean;
  onStart: () => void;
  onStop: () => void;
  onDemo: () => void;
}) {
  return (
    <div className="capture-controls">
      {capturing ? (
        <button className="primary danger" onClick={onStop} disabled={busy}>
          <Square size={16} /> Stop capture
        </button>
      ) : (
        <button className="primary" onClick={onStart} disabled={busy}>
          <PlayCircle size={17} /> Start capture
        </button>
      )}
      {isDemo ? (
        <button onClick={onDemo} disabled={busy}>
          Reload demo
        </button>
      ) : (
        <a className="ghost-link" href="?mode=demo&meeting=demo">
          Open demo
        </a>
      )}
      <label className="search-field compact">
        <Search size={16} />
        <input placeholder="Search transcript" />
      </label>
    </div>
  );
}

function TranscriptList({
  segments,
  partial,
  status,
}: {
  segments: TranscriptSegment[];
  partial: TranscriptSegment | null;
  status: SourceStatus;
}) {
  const empty = segments.length === 0 && !partial;
  return (
    <div className="transcript-list">
      {empty ? <TranscriptEmpty status={status} /> : null}
      {segments.map((segment) => (
        <TranscriptRow key={segment.id} segment={segment} />
      ))}
      {partial ? (
        <article className="transcript-row partial">
          <span className={`avatar ${speakerTone(partial.speaker)}`}>{speakerInitials(partial.speaker)}</span>
          <div>
            <strong>{speakerLabel(partial.speaker)}</strong>
            <p className="partial-text">{partial.text}…</p>
          </div>
        </article>
      ) : null}
    </div>
  );
}

function TranscriptEmpty({ status }: { status: SourceStatus }) {
  const message: Record<SourceStatus, { title: string; body: string }> = {
    idle: { title: "No transcript yet", body: "Start capture to transcribe the call playing on this Mac." },
    demo: { title: "Loading demo", body: "Seeding a sample meeting." },
    waiting_permission: {
      title: "Waiting for permission",
      body: "Grant Microphone and Screen Recording access if macOS prompts you.",
    },
    capturing: { title: "Listening", body: "Capturing audio. Transcript appears as people speak." },
    transcribing: { title: "Listening", body: "Capturing audio. Transcript appears as people speak." },
    no_mic_audio: { title: "No microphone audio", body: "The mic lane is silent. Check your input device and mute state." },
    no_system_audio: {
      title: "No system audio",
      body: "The system lane is silent. Make sure the call's audio plays through this Mac.",
    },
    failed: { title: "Capture failed", body: "See the banner above for the exact permission to grant." },
    stopped: { title: "Capture stopped", body: "Start capture again to resume." },
  };
  const copy = message[status];
  return (
    <div className="empty-state">
      <strong>{copy.title}</strong>
      <p>{copy.body}</p>
    </div>
  );
}

function TranscriptRow({ segment }: { segment: TranscriptSegment }) {
  return (
    <article className="transcript-row">
      <time>{formatTime(segment.start_ms)}</time>
      <span className={`avatar ${speakerTone(segment.speaker)}`}>{speakerInitials(segment.speaker)}</span>
      <div>
        <strong>{speakerLabel(segment.speaker)}</strong>
        <p>{segment.text}</p>
      </div>
    </article>
  );
}

function ProposalCard({
  proposal,
  onApprove,
  onIgnore,
}: {
  proposal: Proposal;
  onApprove: () => void;
  onIgnore: () => void;
}) {
  const [prompt, setPrompt] = useState(proposal.draft_prompt);
  const evidence = proposal.evidence[0];
  return (
    <article className="proposal-card">
      <div className="card-heading">
        <Sparkles size={18} />
        <div>
          <h2>{proposal.title}</h2>
          <p>{proposal.rationale}</p>
        </div>
      </div>
      <div className="meta-row">
        <span><Bot size={16} /> {workerLabel(proposal.suggested_worker)}</span>
        <span><Clock3 size={16} /> {Math.round(proposal.confidence * 100)}% confidence</span>
      </div>
      <div className="evidence-block">
        <strong>Evidence</strong>
        <blockquote>
          {evidence ? `“${evidence.text}”` : "Transcript evidence unavailable."}
          {evidence?.speaker ? <cite> — {speakerLabel(evidence.speaker)}</cite> : null}
        </blockquote>
      </div>
      <label className="prompt-box">
        <span>Prompt <em>(editable)</em></span>
        <textarea value={prompt} onChange={(event) => setPrompt(event.target.value)} />
      </label>
      <div className="button-row">
        <button className="primary" onClick={onApprove}>
          <PlayCircle size={17} /> Approve & run
        </button>
        <button onClick={onIgnore}>
          <XCircle size={17} /> Ignore
        </button>
      </div>
    </article>
  );
}

function EmptyProposal({ status }: { status: SourceStatus }) {
  return (
    <article className="empty-proposal">
      <Sparkles size={19} />
      <div>
        <strong>No pending proposals</strong>
        <p>
          {status === "transcribing" || status === "capturing"
            ? "Standby proposes work when the conversation calls for it."
            : "Approved or ignored cards stay in the event ledger."}
        </p>
      </div>
    </article>
  );
}

function JobCard({ job }: { job: AgentJobSpec }) {
  const tone = job.status === "completed" ? "ok" : job.status === "failed" ? "error" : "live";
  return (
    <article className={`job-card ${tone}`}>
      <div className="job-title">
        <span><Bot size={17} /> {job.title}</span>
        <strong className={`job-status ${tone}`}>{JOB_LABEL[job.status]}</strong>
      </div>
      {job.profile ? <p className="job-meta">Worker: {job.profile}</p> : null}
      {job.status === "running" && job.progress_note ? <p className="job-meta">{job.progress_note}</p> : null}
      {job.status === "queued" ? <p className="job-meta">Waiting for a worker slot…</p> : null}
      {job.status === "failed" ? (
        <div className="failure-note">
          <AlertTriangle size={15} /> {failureLabel(job.failure_reason)}
          {job.error ? <code>{job.error}</code> : null}
          {job.receipt_path ? <small>Receipt: {job.receipt_path}</small> : null}
        </div>
      ) : null}
    </article>
  );
}

function ResultCard({ artifact }: { artifact: Artifact }) {
  return (
    <article className="result-card">
      <div>
        <CheckCircle2 size={18} />
        <strong>{artifact.title}</strong>
      </div>
      <p>{artifact.summary}</p>
      {artifact.uri ? <small className="receipt-link">{artifact.uri}</small> : null}
    </article>
  );
}

function speakerLabel(speaker: string | null): string {
  if (!speaker) return "Unknown";
  if (speaker === "me") return "Me";
  if (speaker === "system_audio") return "Call audio";
  return speaker;
}

function speakerInitials(speaker: string | null): string {
  if (speaker === "me") return "Me";
  if (speaker === "system_audio") return "Ca";
  return (speaker ?? "?").slice(0, 2);
}

function speakerTone(speaker: string | null): string {
  if (speaker === "me") return "green";
  if (speaker === "system_audio") return "blue";
  return "violet";
}

function workerLabel(worker: string): string {
  if (worker === "research_agent") return "Research agent";
  return worker.replace(/_/g, " ");
}

function failureLabel(reason: string | null): string {
  switch (reason) {
    case "cli_not_found":
      return "Worker CLI not found";
    case "auth_required":
      return "Worker CLI needs authentication";
    case "timeout":
      return "Worker timed out";
    case "sandbox_violation":
      return "Blocked by the sandbox";
    case "nonzero_exit":
      return "Worker exited with an error";
    default:
      return "Worker failed";
  }
}

function formatTime(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds % 60;
  return `${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}`;
}

createRoot(document.getElementById("root")!).render(<App />);
