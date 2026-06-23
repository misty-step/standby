import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  AlertTriangle,
  Bot,
  CheckCircle2,
  Clock3,
  FileText,
  Mic2,
  MicOff,
  PlayCircle,
  Search,
  Sparkles,
  Square,
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

type Section = "meeting" | "notes" | "jobs" | "audio";

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

type ProposalRequest = {
  id: string;
  message: string;
  context_window: "recent" | "full";
  max_proposals: number;
  transcript_spans: string[];
};

type ProposalModelMetadata = {
  provider: string;
  model: string;
  mode: string;
  reasoning_summary: string | null;
};

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
  model: ProposalModelMetadata | null;
};

type NoProposal = {
  id: string;
  reason: string;
  transcript_spans: string[];
  operator_message: string | null;
  model: ProposalModelMetadata;
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
  dropped?: number;
  failed?: boolean;
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
  proposal_requests: ProposalRequest[];
  no_proposals: NoProposal[];
  proposals: Proposal[];
  jobs: AgentJobSpec[];
  artifacts: Artifact[];
};

const params = new URLSearchParams(window.location.search);
const meetingId = params.get("meeting") ?? "live";
const mode = params.get("mode") ?? "live";
const isDemo = mode === "demo";
const initialSection = readInitialSection(params.get("section"));

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
  system_audio_permission_denied:
    "System Audio Recording permission denied. Grant it in System Settings › Privacy & Security › System Audio Recording (a separate pane from Screen Recording), then start again.",
  system_audio_unsupported_os:
    "System audio capture needs macOS 14.4 or later. On older macOS, capture microphone only or use the Screen Recording fallback.",
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

let operatorSession: Promise<void> | null = null;

async function ensureOperatorSession(force = false): Promise<void> {
  if (force) operatorSession = null;
  if (!operatorSession) {
    operatorSession = fetch("/api/operator-session", { credentials: "same-origin" })
      .then((response) => {
        if (!response.ok) throw new Error(`operator session failed: ${response.status}`);
      })
      .catch((err) => {
        // Never cache a rejected handshake — the next action retries instead of
        // failing forever.
        operatorSession = null;
        throw err;
      });
  }
  return operatorSession;
}

async function post(path: string): Promise<MeetingProjection> {
  await ensureOperatorSession();
  const send = () =>
    fetch(path, {
      method: "POST",
      credentials: "same-origin",
      headers: { "content-type": "application/json" },
    });
  let response = await send();
  if (response.status === 401) {
    // The operator token went stale (e.g. the daemon restarted and minted a new
    // one). Re-mint the session and retry once before surfacing an error.
    await ensureOperatorSession(true);
    response = await send();
  }
  if (!response.ok) throw new Error(`${path} -> ${response.status}`);
  return response.json();
}

function App() {
  const [projection, setProjection] = useState<MeetingProjection | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [activeSection, setActiveSection] = useState<Section>(initialSection);
  const [transcriptQuery, setTranscriptQuery] = useState("");

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
  const activeProposals = projection?.proposals.filter((proposal) => proposal.status === "proposed") ?? [];
  const latestJob = projection?.jobs.at(-1) ?? null;
  const latestArtifact = projection?.artifacts.at(-1) ?? null;
  const latestNoProposal = projection?.no_proposals.at(-1) ?? null;
  const proposalCount = activeProposals.length;
  const jobCount = projection?.jobs.length ?? 0;
  const capturing = status === "capturing" || status === "transcribing" || status === "no_mic_audio" || status === "no_system_audio";

  return (
    <div className="app-shell">
      <Sidebar
        status={status}
        title={projection?.title ?? (isDemo ? "Demo meeting" : "Live meeting")}
        activeSection={activeSection}
        onSectionChange={setActiveSection}
        proposalCount={proposalCount}
        jobCount={jobCount}
      />
      <main className="workspace">
        <TopBar status={status} title={projection?.title ?? (isDemo ? "Demo meeting" : "Live meeting")} />
        <SourceBanner status={status} source={source ?? null} />
        <MobileSectionTabs
          activeSection={activeSection}
          onSectionChange={setActiveSection}
          proposalCount={proposalCount}
          jobCount={jobCount}
        />
        <section className="content-grid">
          <section className="transcript-panel">
            <CaptureControls
              isDemo={isDemo}
              capturing={capturing}
              busy={busy}
              transcriptQuery={transcriptQuery}
              onTranscriptQueryChange={setTranscriptQuery}
              onStart={() => act(() => post(`/api/meetings/${meetingId}/capture/start?mode=mic%2Bsystem`))}
              onStop={() => act(() => post(`/api/meetings/${meetingId}/capture/stop`))}
              onDemo={() => act(() => post(`/api/meetings/${meetingId}/demo`))}
            />
            {error ? <div className="failure-note">{error}</div> : null}
            <TranscriptList
              segments={projection?.transcript ?? []}
              partial={projection?.partial ?? null}
              status={status}
              query={transcriptQuery}
            />
          </section>
          <WorkPanel
            section={activeSection}
            projection={projection}
            status={status}
            source={source ?? null}
            activeProposals={activeProposals}
            latestJob={latestJob}
            latestArtifact={latestArtifact}
            latestNoProposal={latestNoProposal}
            busy={busy}
            onRequestProposal={(message) => act(() => requestProposal(message))}
            onApprove={(proposal, prompt) => act(() => approveProposal(proposal, prompt))}
            onIgnore={(proposal) => act(() => post(`/api/proposals/${proposal.id}/ignore`))}
          />
        </section>
      </main>
    </div>
  );
}

async function approveProposal(proposal: Proposal, prompt: string): Promise<MeetingProjection> {
  await ensureOperatorSession();
  const response = await fetch(`/api/proposals/${proposal.id}/approve`, {
    method: "POST",
    credentials: "same-origin",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ prompt }),
  });
  if (!response.ok) throw new Error(`approval failed: ${response.status}`);
  return response.json();
}

async function requestProposal(message: string): Promise<MeetingProjection> {
  await ensureOperatorSession();
  const response = await fetch(`/api/meetings/${meetingId}/proposal-requests`, {
    method: "POST",
    credentials: "same-origin",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ message, context_window: "recent", max_proposals: 1 }),
  });
  if (!response.ok) throw new Error(`proposal request failed: ${response.status}`);
  return response.json();
}

function readInitialSection(value: string | null): Section {
  if (value === "notes" || value === "jobs" || value === "audio") return value;
  return "meeting";
}

function Sidebar({
  status,
  title,
  activeSection,
  onSectionChange,
  proposalCount,
  jobCount,
}: {
  status: SourceStatus;
  title: string | null;
  activeSection: Section;
  onSectionChange: (section: Section) => void;
  proposalCount: number;
  jobCount: number;
}) {
  const navItems = [
    { id: "meeting", Icon: Mic2, label: "Meeting", count: proposalCount },
    { id: "notes", Icon: FileText, label: "Notes", count: 0 },
    { id: "jobs", Icon: Bot, label: "Jobs", count: jobCount },
    { id: "audio", Icon: Volume2, label: "Audio", count: 0 },
  ] satisfies Array<{ id: Section; Icon: typeof Mic2; label: string; count: number }>;
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
        {navItems.map(({ Icon, count, id, label }) => (
          <button
            key={id}
            className={`nav-item ${activeSection === id ? "active" : ""}`}
            onClick={() => onSectionChange(id)}
          >
            <Icon size={18} />
            <span>{label}</span>
            {count > 0 ? <span className="nav-count">{count}</span> : null}
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
    </header>
  );
}

function MobileSectionTabs({
  activeSection,
  onSectionChange,
  proposalCount,
  jobCount,
}: {
  activeSection: Section;
  onSectionChange: (section: Section) => void;
  proposalCount: number;
  jobCount: number;
}) {
  const navItems = [
    { id: "meeting", label: "Meeting", count: proposalCount },
    { id: "notes", label: "Notes", count: 0 },
    { id: "jobs", label: "Jobs", count: jobCount },
    { id: "audio", label: "Audio", count: 0 },
  ] satisfies Array<{ id: Section; label: string; count: number }>;
  return (
    <nav className="mobile-section-tabs" aria-label="Meeting views">
      {navItems.map(({ id, label, count }) => (
        <button
          key={id}
          className={activeSection === id ? "active" : ""}
          onClick={() => onSectionChange(id)}
        >
          <span>{label}</span>
          {count > 0 ? <small>{count}</small> : null}
        </button>
      ))}
    </nav>
  );
}

function SourceBanner({ status, source }: { status: SourceStatus; source: SourceState | null }) {
  const meta = STATUS_LABEL[status];
  const copy = sourceBannerCopy(status, source);
  return (
    <div className={`source-banner ${meta.tone}`}>
      <div className="source-banner-main">
        {status === "failed" ? <AlertTriangle size={16} /> : <Mic2 size={16} />}
        <div>
          <strong>{copy.title}</strong>
          <span className="source-summary">{copy.body}</span>
        </div>
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

function sourceBannerCopy(
  status: SourceStatus,
  source: SourceState | null,
): { title: string; body: string } {
  const micAudible = source ? laneAudible(source.microphone) : false;
  const systemAudible = source ? laneAudible(source.system_audio) : false;
  if (status === "idle") {
    return {
      title: "Capture is off",
      body: "Start capture to transcribe this Mac's microphone and call audio.",
    };
  }
  if (micAudible && source?.system_audio.expected && !systemAudible) {
    return {
      title: "Mic transcript is live",
      body: "The call-audio lane is available but silent; in a solo Meet that is normal until another participant or shared audio plays.",
    };
  }
  if (systemAudible && source?.microphone.expected && !micAudible) {
    return {
      title: "Call audio is live",
      body: "The microphone lane is silent. Check mute state if you expect your speech to appear.",
    };
  }
  if (status === "transcribing" || status === "capturing") {
    return {
      title: STATUS_LABEL[status].label,
      body: "Standby is listening locally and publishing finalized transcript lines.",
    };
  }
  if (status === "failed") {
    return {
      title: "Capture failed",
      body: "The exact missing permission or helper error is shown here.",
    };
  }
  return {
    title: STATUS_LABEL[status].label,
    body: "Local capture state from the macOS helper.",
  };
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
  const failed = lane.failed === true;
  const active = laneAudible(lane);
  const Icon = active ? OnIcon : OffIcon;
  const stateLabel = laneStateLabel(lane, true);
  return (
    <div
      className={`lane-meter ${failed ? "failed" : active ? "active" : "silent"}`}
      title={`${label} RMS ${(lane.last_rms ?? 0).toFixed(3)}`}
    >
      <Icon size={15} />
      <span>{label}</span>
      <small>{stateLabel}</small>
      <span className="lane-bar">
        <span style={{ transform: `scaleX(${level / 100})` }} />
      </span>
    </div>
  );
}

function CaptureControls({
  isDemo,
  capturing,
  busy,
  transcriptQuery,
  onTranscriptQueryChange,
  onStart,
  onStop,
  onDemo,
}: {
  isDemo: boolean;
  capturing: boolean;
  busy: boolean;
  transcriptQuery: string;
  onTranscriptQueryChange: (query: string) => void;
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
        <input
          value={transcriptQuery}
          onChange={(event) => onTranscriptQueryChange(event.target.value)}
          placeholder="Search transcript"
        />
      </label>
    </div>
  );
}

function TranscriptList({
  segments,
  partial,
  status,
  query,
}: {
  segments: TranscriptSegment[];
  partial: TranscriptSegment | null;
  status: SourceStatus;
  query: string;
}) {
  const empty = segments.length === 0 && !partial;
  const trimmedQuery = query.trim().toLowerCase();
  const newestFirst = useMemo(() => {
    const ordered = [...segments].reverse();
    if (!trimmedQuery) return ordered;
    return ordered.filter((segment) => transcriptMatches(segment, trimmedQuery));
  }, [segments, trimmedQuery]);
  const partialVisible = partial && (!trimmedQuery || transcriptMatches(partial, trimmedQuery));
  return (
    <div className="transcript-list latest-first" aria-live="polite">
      {empty ? <TranscriptEmpty status={status} /> : null}
      {!empty && trimmedQuery && newestFirst.length === 0 && !partialVisible ? (
        <div className="empty-state">
          <strong>No matching transcript</strong>
          <p>Clear the search to return to the live transcript.</p>
        </div>
      ) : null}
      {partialVisible ? (
        <article className="transcript-row partial">
          <span className={`avatar ${speakerTone(partial.speaker)}`}>{speakerInitials(partial.speaker)}</span>
          <div>
            <strong>{speakerLabel(partial.speaker)}</strong>
            <p className="partial-text">{partial.text}…</p>
          </div>
          <time>{formatTime(partial.start_ms)}</time>
        </article>
      ) : null}
      {newestFirst.map((segment) => (
        <TranscriptRow key={segment.id} segment={segment} />
      ))}
    </div>
  );
}

function transcriptMatches(segment: TranscriptSegment, query: string): boolean {
  return `${speakerLabel(segment.speaker)} ${segment.text}`.toLowerCase().includes(query);
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
      <span className={`avatar ${speakerTone(segment.speaker)}`}>{speakerInitials(segment.speaker)}</span>
      <div>
        <strong>{speakerLabel(segment.speaker)}</strong>
        <p>{segment.text}</p>
      </div>
      <time>{formatTime(segment.start_ms)}</time>
    </article>
  );
}

function ProposalCard({
  proposal,
  onApprove,
  onIgnore,
}: {
  proposal: Proposal;
  onApprove: (prompt: string) => void;
  onIgnore: () => void;
}) {
  const [prompt, setPrompt] = useState(proposal.draft_prompt);
  const evidence = proposal.evidence.slice(0, 3);
  return (
    <article className="proposal-card">
      <div className="card-heading">
        <Sparkles size={18} />
        <div>
          <span className="eyebrow">Suggested action</span>
          <h2>{proposal.title}</h2>
          <p>{proposal.rationale}</p>
        </div>
      </div>
      <div className="meta-row">
        <span><Bot size={16} /> {workerLabel(proposal.suggested_worker)}</span>
        <span><Clock3 size={16} /> {Math.round(proposal.confidence * 100)}% confidence</span>
        {proposal.model ? (
          <span><Sparkles size={16} /> {proposal.model.provider} · {proposal.model.model}</span>
        ) : null}
      </div>
      <p className="model-note">Approval queues the default OpenCode worker; failures surface with receipts.</p>
      {proposal.model?.reasoning_summary ? (
        <p className="model-note">{proposal.model.reasoning_summary}</p>
      ) : null}
      <div className="evidence-block">
        <strong>Evidence</strong>
        {evidence.length > 0 ? (
          evidence.map((item) => (
            <blockquote key={item.segment_id}>
              {`“${item.text}”`}
              {item.speaker ? <cite> — {speakerLabel(item.speaker)}</cite> : null}
            </blockquote>
          ))
        ) : (
          <blockquote>Transcript evidence unavailable.</blockquote>
        )}
      </div>
      <label className="prompt-box">
        <span>Prompt <em>(editable)</em></span>
        <textarea value={prompt} onChange={(event) => setPrompt(event.target.value)} />
      </label>
      <div className="button-row">
        <button className="primary" onClick={() => onApprove(prompt)}>
          <PlayCircle size={17} /> Approve & run
        </button>
        <button onClick={onIgnore}>
          <XCircle size={17} /> Ignore
        </button>
      </div>
    </article>
  );
}

function EmptyProposal({ status, latestNoProposal }: { status: SourceStatus; latestNoProposal: NoProposal | null }) {
  return (
    <article className="empty-proposal">
      <Sparkles size={19} />
      <div>
        <strong>No pending proposals</strong>
        <p>
          {latestNoProposal
            ? `${latestNoProposal.model.provider} returned no card: ${humanReason(latestNoProposal.reason)}.`
            : status === "transcribing" || status === "capturing"
            ? "Standby proposes work when the conversation calls for it."
            : "Approved or ignored cards stay in the event ledger."}
        </p>
        {latestNoProposal?.operator_message ? (
          <small>Last request: {latestNoProposal.operator_message}</small>
        ) : null}
      </div>
    </article>
  );
}

function AskStandbyBox({
  disabled,
  transcriptCount,
  onRequestProposal,
}: {
  disabled: boolean;
  transcriptCount: number;
  onRequestProposal: (message: string) => void;
}) {
  const [message, setMessage] = useState("");
  const trimmed = message.trim();
  return (
    <form
      className="ask-standby"
      onSubmit={(event) => {
        event.preventDefault();
        if (!trimmed) return;
        onRequestProposal(trimmed);
        setMessage("");
      }}
    >
      <label>
        <span>Ask Standby</span>
        <textarea
          value={message}
          onChange={(event) => setMessage(event.target.value)}
          placeholder="Research what came up in this call and propose a task"
        />
      </label>
      <div className="ask-standby-footer">
        <small>{transcriptCount} transcript span{transcriptCount === 1 ? "" : "s"} available</small>
        <button className="primary" disabled={disabled || !trimmed}>
          <Sparkles size={16} /> Create proposal
        </button>
      </div>
    </form>
  );
}

function WorkPanel({
  section,
  projection,
  status,
  source,
  activeProposals,
  latestJob,
  latestArtifact,
  latestNoProposal,
  busy,
  onRequestProposal,
  onApprove,
  onIgnore,
}: {
  section: Section;
  projection: MeetingProjection | null;
  status: SourceStatus;
  source: SourceState | null;
  activeProposals: Proposal[];
  latestJob: AgentJobSpec | null;
  latestArtifact: Artifact | null;
  latestNoProposal: NoProposal | null;
  busy: boolean;
  onRequestProposal: (message: string) => void;
  onApprove: (proposal: Proposal, prompt: string) => void;
  onIgnore: (proposal: Proposal) => void;
}) {
  const jobs = projection?.jobs ?? [];
  const artifacts = projection?.artifacts ?? [];
  const transcript = projection?.transcript ?? [];

  return (
    <aside className="work-panel" aria-label={`${sectionLabel(section)} panel`}>
      <PanelHeader section={section} jobs={jobs.length} proposals={activeProposals.length} />
      {section === "meeting" ? (
        <>
          <WorkOverview
            activeProposals={activeProposals}
            latestJob={latestJob}
            latestArtifact={latestArtifact}
            latestNoProposal={latestNoProposal}
          />
          {latestJob || latestArtifact ? (
            <div className="current-work-stack">
              {latestJob ? <JobCard job={latestJob} /> : null}
              {latestArtifact ? <ResultCard artifact={latestArtifact} /> : null}
            </div>
          ) : null}
          {activeProposals.length > 0 ? (
            <div className="proposal-stack">
              {activeProposals.map((proposal) => (
                <ProposalCard
                  key={proposal.id}
                  proposal={proposal}
                  onApprove={(prompt) => onApprove(proposal, prompt)}
                  onIgnore={() => onIgnore(proposal)}
                />
              ))}
            </div>
          ) : (
            <>
              <AskStandbyBox
                disabled={busy}
                transcriptCount={transcript.length}
                onRequestProposal={onRequestProposal}
              />
              <EmptyProposal status={status} latestNoProposal={latestNoProposal} />
            </>
          )}
        </>
      ) : null}
      {section === "notes" ? <NotesPanel segments={transcript} /> : null}
      {section === "jobs" ? <JobsPanel jobs={jobs} artifacts={artifacts} /> : null}
      {section === "audio" ? <AudioPanel status={status} source={source} /> : null}
    </aside>
  );
}

function WorkOverview({
  activeProposals,
  latestJob,
  latestArtifact,
  latestNoProposal,
}: {
  activeProposals: Proposal[];
  latestJob: AgentJobSpec | null;
  latestArtifact: Artifact | null;
  latestNoProposal: NoProposal | null;
}) {
  const proposalValue = activeProposals.length > 0 ? `${activeProposals.length} open` : latestNoProposal ? "No card" : "Clear";
  const proposalDetail =
    activeProposals.length > 0
      ? activeProposals[0].title
      : latestNoProposal
      ? humanReason(latestNoProposal.reason)
      : "No pending approval";
  return (
    <section className="work-overview" aria-label="Current meeting work">
      <StatusTile
        label="Proposal"
        value={proposalValue}
        detail={proposalDetail}
        tone={activeProposals.length > 0 ? "attention" : "neutral"}
        Icon={Sparkles}
      />
      <StatusTile
        label="Worker"
        value={latestJob ? JOB_LABEL[latestJob.status] : "Idle"}
        detail={latestJob?.title ?? "No job queued"}
        tone={latestJob ? jobTone(latestJob.status) : "neutral"}
        Icon={Bot}
      />
      <StatusTile
        label="Result"
        value={latestArtifact ? "Ready" : "None"}
        detail={latestArtifact?.title ?? "No artifact yet"}
        tone={latestArtifact ? "ok" : "neutral"}
        Icon={CheckCircle2}
      />
    </section>
  );
}

function StatusTile({
  label,
  value,
  detail,
  tone,
  Icon,
}: {
  label: string;
  value: string;
  detail: string;
  tone: "neutral" | "attention" | "live" | "ok" | "error";
  Icon: typeof Bot;
}) {
  return (
    <article className={`status-tile ${tone}`}>
      <div>
        <Icon size={15} />
        <span>{label}</span>
      </div>
      <strong>{value}</strong>
      <p>{detail}</p>
    </article>
  );
}

function PanelHeader({
  section,
  jobs,
  proposals,
}: {
  section: Section;
  jobs: number;
  proposals: number;
}) {
  const copy: Record<Section, { title: string; body: string }> = {
    meeting: {
      title: "Meeting actions",
      body: proposals > 0 ? "Review the suggested task before it starts." : "Approved work and results stay visible here.",
    },
    notes: {
      title: "Notes",
      body: "Newest finalized transcript lines, separated from task approval.",
    },
    jobs: {
      title: "Agent jobs",
      body: jobs > 0 ? `${jobs} worker job${jobs === 1 ? "" : "s"} recorded for this meeting.` : "Approved tasks appear here.",
    },
    audio: {
      title: "Audio",
      body: "Capture lanes and permission state for this Mac.",
    },
  };
  return (
    <header className="panel-header">
      <h1>{copy[section].title}</h1>
      <p>{copy[section].body}</p>
    </header>
  );
}

function NotesPanel({ segments }: { segments: TranscriptSegment[] }) {
  const recent = useMemo(() => [...segments].reverse().slice(0, 8), [segments]);
  if (recent.length === 0) {
    return <EmptyWork icon={FileText} title="No notes yet" body="Final transcript lines will appear here during capture." />;
  }
  return (
    <div className="notes-panel">
      {recent.map((segment) => (
        <article className="note-line" key={segment.id}>
          <strong>{speakerLabel(segment.speaker)}</strong>
          <p>{segment.text}</p>
        </article>
      ))}
    </div>
  );
}

function JobsPanel({ jobs, artifacts }: { jobs: AgentJobSpec[]; artifacts: Artifact[] }) {
  const newestJobs = [...jobs].reverse();
  const newestArtifacts = [...artifacts].reverse();
  if (newestJobs.length === 0) {
    return <EmptyWork icon={Bot} title="No agent jobs yet" body="Approve a suggested action to queue a worker." />;
  }
  return (
    <div className="job-history">
      {newestJobs.map((job) => (
        <JobCard key={job.id} job={job} />
      ))}
      {newestArtifacts.length > 0 ? (
        <section className="artifact-stack" aria-label="Job results">
          <h2>Results</h2>
          {newestArtifacts.map((artifact) => (
            <ResultCard key={artifact.id} artifact={artifact} />
          ))}
        </section>
      ) : null}
    </div>
  );
}

function AudioPanel({ status, source }: { status: SourceStatus; source: SourceState | null }) {
  if (!source) {
    return <EmptyWork icon={Volume2} title="No capture source" body="Start capture to inspect microphone and call-audio lanes." />;
  }
  return (
    <div className="audio-panel">
      <section className="audio-summary">
        <strong>{sourceBannerCopy(status, source).title}</strong>
        <p>{sourceBannerCopy(status, source).body}</p>
        {source.failure ? (
          <div className="failure-note">
            <AlertTriangle size={15} />
            {FAILURE_TEXT[source.failure.reason] ?? source.failure.detail ?? source.failure.reason}
          </div>
        ) : null}
      </section>
      <div className="lane-detail-grid">
        <LaneDetail label="Microphone" lane={source.microphone} />
        <LaneDetail label="Call audio" lane={source.system_audio} />
      </div>
    </div>
  );
}

function LaneDetail({ label, lane }: { label: string; lane: LaneState }) {
  const failed = lane.failed === true;
  const active = laneAudible(lane);
  const state = laneStateLabel(lane, false);
  return (
    <article className={`lane-detail ${failed ? "failed" : active ? "active" : "silent"}`}>
      <div>
        <strong>{label}</strong>
        <span>{state}</span>
      </div>
      <dl>
        <div>
          <dt>Captured</dt>
          <dd>{formatDuration(lane.captured_ms)}</dd>
        </div>
        <div>
          <dt>Level events</dt>
          <dd>{lane.level_events}</dd>
        </div>
        <div>
          <dt>Last RMS</dt>
          <dd>{(lane.last_rms ?? 0).toFixed(3)}</dd>
        </div>
        <div>
          <dt>Dropped</dt>
          <dd>{lane.dropped ?? 0}</dd>
        </div>
      </dl>
    </article>
  );
}

function laneAudible(lane: LaneState): boolean {
  return lane.failed !== true && lane.active && (lane.last_rms ?? 0) > 0.001;
}

function laneStateLabel(lane: LaneState, compact: boolean): string {
  if (lane.failed === true) return "Failed";
  if (laneAudible(lane)) return "Active";
  if (lane.active || lane.level_events > 0) return compact ? "Silent" : "Available, silent";
  return "Silent";
}

function EmptyWork({
  icon: Icon,
  title,
  body,
}: {
  icon: typeof Bot;
  title: string;
  body: string;
}) {
  return (
    <article className="empty-proposal">
      <Icon size={19} />
      <div>
        <strong>{title}</strong>
        <p>{body}</p>
      </div>
    </article>
  );
}

function sectionLabel(section: Section): string {
  switch (section) {
    case "meeting":
      return "Meeting actions";
    case "notes":
      return "Notes";
    case "jobs":
      return "Agent jobs";
    case "audio":
      return "Audio";
  }
}

function JobCard({ job }: { job: AgentJobSpec }) {
  const tone = jobTone(job.status);
  const progressIndex = jobProgressIndex(job.status);
  return (
    <article className={`job-card ${tone}`}>
      <div className="job-title">
        <span><Bot size={17} /> {job.title}</span>
        <strong className={`job-status ${tone}`}>{JOB_LABEL[job.status]}</strong>
      </div>
      <div className="job-steps" aria-label={`Worker status: ${JOB_LABEL[job.status]}`}>
        {["Queued", "Running", "Done"].map((label, index) => (
          <span key={label} className={index <= progressIndex ? "complete" : ""}>
            {label}
          </span>
        ))}
      </div>
      {job.profile ? <p className="job-meta"><strong>Worker</strong> {job.profile}</p> : null}
      <p className="job-meta">{job.progress_note ?? jobDefaultProgress(job.status)}</p>
      {job.receipt_path ? <p className="job-receipt">Receipt: {job.receipt_path}</p> : null}
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

function jobTone(status: JobStatus): "live" | "ok" | "error" {
  return status === "completed" ? "ok" : status === "failed" || status === "canceled" ? "error" : "live";
}

function jobProgressIndex(status: JobStatus): number {
  switch (status) {
    case "queued":
      return 0;
    case "running":
    case "needs_input":
    case "failed":
    case "canceled":
      return 1;
    case "completed":
      return 2;
  }
}

function jobDefaultProgress(status: JobStatus): string {
  switch (status) {
    case "queued":
      return "Waiting for a worker slot.";
    case "running":
      return "Worker is executing.";
    case "needs_input":
      return "Worker needs input before it can continue.";
    case "completed":
      return "Worker completed.";
    case "failed":
      return "Worker failed.";
    case "canceled":
      return "Worker was canceled.";
  }
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
  const generic = genericSpeakerNumber(speaker);
  if (generic) return `Speaker ${generic}`;
  return speaker;
}

function speakerInitials(speaker: string | null): string {
  if (!speaker) return "?";
  if (speaker === "me") return "Me";
  if (speaker === "system_audio") return "Ca";
  const generic = genericSpeakerNumber(speaker);
  if (generic) return `S${generic}`;
  return (speaker ?? "?").slice(0, 2);
}

function speakerTone(speaker: string | null): string {
  if (!speaker) return "violet";
  if (speaker === "me") return "green";
  if (speaker === "system_audio") return "blue";
  const generic = genericSpeakerNumber(speaker);
  if (generic) return Number(generic) % 2 === 0 ? "orange" : "violet";
  return "violet";
}

function genericSpeakerNumber(speaker: string): string | null {
  const match = speaker.match(/^(?:remote|speaker)[_-](\d+)$/i);
  return match ? match[1] : null;
}

function workerLabel(worker: string): string {
  if (worker === "research_agent") return "Research agent";
  return worker.replace(/_/g, " ");
}

function humanReason(reason: string): string {
  switch (reason) {
    case "open_proposal_exists":
      return "there is already a pending proposal";
    case "no_transcript_or_operator_context":
      return "there was no transcript or operator context";
    case "insufficient_context_for_automatic_card":
      return "there was not enough meeting context yet";
    case "low_actionability":
      return "the request did not contain enough delegateable work";
    case "model_returned_no_valid_proposals":
      return "the model response did not cite valid transcript evidence";
    default:
      return reason.replace(/_/g, " ");
  }
}

function failureLabel(reason: string | null): string {
  switch (reason) {
    case "cli_not_found":
      return "OpenCode CLI not found";
    case "auth_required":
      return "OpenCode needs authentication";
    case "consent_required":
      return "Worker approval required";
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

function formatDuration(ms: number): string {
  if (ms < 1_000) return `${ms} ms`;
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds % 60;
  return `${minutes}m ${String(remainder).padStart(2, "0")}s`;
}

createRoot(document.getElementById("root")!).render(<App />);
