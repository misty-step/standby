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
  PencilLine,
  PlayCircle,
  Plus,
  Search,
  Sparkles,
  Square,
  Volume2,
  VolumeX,
  XCircle,
} from "lucide-react";
import "./styles.css";

type JobStatus = "queued" | "running" | "completed" | "failed" | "canceled";
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

type DisplayTranscriptSegment = TranscriptSegment & {
  display_start_ms: number;
  display_end_ms: number;
};

type TranscriptTurn = {
  id: string;
  speaker: string | null;
  start_ms: number;
  end_ms: number;
  text: string;
  segments: DisplayTranscriptSegment[];
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

type MeetingSummary = {
  id: string;
  title: string;
  started_at: string | null;
  updated_at: string | null;
  source_status: SourceStatus;
  transcript_count: number;
  question_count: number;
  open_suggestion_count: number;
  running_job_count: number;
  output_count: number;
  latest_activity: string | null;
};

const params = new URLSearchParams(window.location.search);
const initialMeetingId = params.get("meeting");
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
  return postJson<MeetingProjection>(path);
}

async function postJson<T>(path: string, body?: unknown): Promise<T> {
  await ensureOperatorSession();
  const send = () =>
    fetch(path, {
      method: "POST",
      credentials: "same-origin",
      headers: { "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
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

async function fetchMeetings(): Promise<MeetingSummary[]> {
  const response = await fetch("/api/meetings");
  if (!response.ok) throw new Error(`meetings failed: ${response.status}`);
  return response.json();
}

async function fetchProjection(meetingId: string): Promise<MeetingProjection> {
  const response = await fetch(`/api/meetings/${meetingId}`);
  if (!response.ok) throw new Error(`projection failed: ${response.status}`);
  return response.json();
}

function App() {
  const [meetings, setMeetings] = useState<MeetingSummary[]>([]);
  const [selectedMeetingId, setSelectedMeetingId] = useState<string | null>(initialMeetingId);
  const [projection, setProjection] = useState<MeetingProjection | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [activeSection, setActiveSection] = useState<Section>(initialSection);
  const [transcriptQuery, setTranscriptQuery] = useState("");

  async function refresh(targetMeetingId = selectedMeetingId) {
    const summaries = await fetchMeetings();
    setMeetings(summaries);
    const nextMeetingId = targetMeetingId ?? summaries[0]?.id ?? null;
    if (!nextMeetingId) {
      setSelectedMeetingId(null);
      setProjection(null);
      return;
    }
    setSelectedMeetingId(nextMeetingId);
    setProjection(await fetchProjection(nextMeetingId));
  }

  async function act(fn: () => Promise<MeetingProjection | null>) {
    setBusy(true);
    setError(null);
    try {
      const nextProjection = await fn();
      if (nextProjection) setProjection(nextProjection);
    } catch (err) {
      setError(err instanceof Error ? err.message : "request failed");
    } finally {
      setBusy(false);
    }
  }

  useEffect(() => {
    let canceled = false;
    async function boot() {
      setBusy(true);
      setError(null);
      try {
        if (isDemo) {
          const demoMeetingId = initialMeetingId ?? "demo";
          const seeded = await post(`/api/meetings/${demoMeetingId}/demo`);
          const summaries = await fetchMeetings();
          if (canceled) return;
          setSelectedMeetingId(demoMeetingId);
          setProjection(seeded);
          setMeetings(summaries);
          writeMeetingUrl(demoMeetingId, initialSection, true);
          return;
        }
        const summaries = await fetchMeetings();
        const nextMeetingId = initialMeetingId ?? summaries[0]?.id ?? null;
        const nextProjection = nextMeetingId ? await fetchProjection(nextMeetingId) : null;
        if (canceled) return;
        setMeetings(summaries);
        setSelectedMeetingId(nextMeetingId);
        setProjection(nextProjection);
        if (nextMeetingId && !initialMeetingId) writeMeetingUrl(nextMeetingId, initialSection, false);
      } catch (err) {
        if (!canceled) setError(err instanceof Error ? err.message : "load failed");
      } finally {
        if (!canceled) setBusy(false);
      }
    }
    boot();
    return () => {
      canceled = true;
    };
  }, []);

  useEffect(() => {
    const interval = window.setInterval(() => {
      refresh(selectedMeetingId).catch(() => undefined);
    }, 2000);
    return () => window.clearInterval(interval);
  }, [selectedMeetingId]);

  const visibleMeetings = useMemo(() => {
    const catalog = [...meetings];
    if (selectedMeetingId && !catalog.some((meeting) => meeting.id === selectedMeetingId)) {
      catalog.unshift(summaryFromProjection(projection, selectedMeetingId));
    }
    return catalog;
  }, [meetings, projection, selectedMeetingId]);
  const selectedSummary =
    visibleMeetings.find((meeting) => meeting.id === selectedMeetingId) ?? null;
  const source = projection?.source;
  const status: SourceStatus = source?.status ?? "idle";
  // Newest-first feed, mirroring the transcript (TranscriptList): a new card
  // enters at the top and older cards are pushed down. Cards never auto-remove.
  const activeProposals =
    projection?.proposals.filter((proposal) => proposal.status === "proposed").reverse() ?? [];
  const jobs = projection?.jobs ?? [];
  const artifacts = projection?.artifacts ?? [];
  const latestJob = jobs.at(-1) ?? null;
  const latestArtifact = artifacts.at(-1) ?? null;
  const latestNoProposal = projection?.no_proposals.at(-1) ?? null;
  const proposalCount = activeProposals.length;
  const jobCount = jobs.length;
  const artifactCount = artifacts.length;
  const capturing = status === "capturing" || status === "transcribing" || status === "no_mic_audio" || status === "no_system_audio";
  const meetingTitle = displayMeetingTitle(
    projection?.title ?? selectedSummary?.title ?? null,
    selectedMeetingId,
  );

  function selectedOrThrow(): string {
    if (!selectedMeetingId) throw new Error("select or create a meeting first");
    return selectedMeetingId;
  }

  function changeSection(section: Section) {
    setActiveSection(section);
    if (selectedMeetingId) writeMeetingUrl(selectedMeetingId, section, isDemo && selectedMeetingId === "demo");
  }

  function selectMeeting(meetingId: string) {
    act(async () => {
      setSelectedMeetingId(meetingId);
      setActiveSection("meeting");
      writeMeetingUrl(meetingId, "meeting", false);
      const nextProjection = await fetchProjection(meetingId);
      setMeetings(await fetchMeetings());
      return nextProjection;
    });
  }

  function createMeeting() {
    act(async () => {
      const created = await postJson<MeetingProjection>("/api/meetings", {
        title: defaultMeetingTitle(),
      });
      setSelectedMeetingId(created.meeting_id);
      setActiveSection("meeting");
      setTranscriptQuery("");
      writeMeetingUrl(created.meeting_id, "meeting", false);
      setMeetings(await fetchMeetings());
      return created;
    });
  }

  function renameMeeting(title: string) {
    if (!selectedMeetingId) return;
    act(async () => {
      const renamed = await postJson<MeetingProjection>(`/api/meetings/${selectedMeetingId}/rename`, {
        title,
      });
      setMeetings(await fetchMeetings());
      return renamed;
    });
  }

  return (
    <div className="app-shell">
      <MeetingRail
        meetings={visibleMeetings}
        selectedMeetingId={selectedMeetingId}
        busy={busy}
        onCreateMeeting={createMeeting}
        onSelectMeeting={selectMeeting}
      />
      <main className="workspace">
        <MeetingHeader
          meetings={visibleMeetings}
          selectedMeetingId={selectedMeetingId}
          title={meetingTitle}
          summary={selectedSummary}
          status={status}
          source={source ?? null}
          activeSection={activeSection}
          busy={busy}
          capturing={capturing}
          isDemo={isDemo}
          proposalCount={proposalCount}
          jobCount={jobCount}
          artifactCount={artifactCount}
          transcriptCount={projection?.transcript.length ?? selectedSummary?.transcript_count ?? 0}
          onSectionChange={changeSection}
          onSelectMeeting={selectMeeting}
          onCreateMeeting={createMeeting}
          onRenameMeeting={renameMeeting}
          onStart={() => act(() => post(`/api/meetings/${selectedOrThrow()}/capture/start?mode=mic%2Bsystem`))}
          onStop={() => act(() => post(`/api/meetings/${selectedOrThrow()}/capture/stop`))}
          onDemo={() => act(() => post(`/api/meetings/${selectedMeetingId ?? "demo"}/demo`))}
        />
        {!selectedMeetingId ? (
          <EmptyMeetingState busy={busy} onCreateMeeting={createMeeting} />
        ) : activeSection === "meeting" ? (
          <MeetingActionStream
            projection={projection}
            status={status}
            activeProposals={activeProposals}
            latestNoProposal={latestNoProposal}
            proposalCount={proposalCount}
            jobCount={jobCount}
            artifactCount={artifactCount}
            busy={busy}
            error={error}
            transcriptQuery={transcriptQuery}
            onTranscriptQueryChange={setTranscriptQuery}
            onRequestProposal={(message) => act(() => requestProposal(selectedOrThrow(), message))}
            onApprove={(proposal, prompt) => act(() => approveProposal(proposal, prompt))}
            onIgnore={(proposal) => act(() => post(`/api/proposals/${proposal.id}/ignore`))}
          />
        ) : activeSection === "notes" ? (
          <section className="content-grid secondary-grid">
            <section className="transcript-panel">
              <TranscriptSearchControls
                transcriptQuery={transcriptQuery}
                onTranscriptQueryChange={setTranscriptQuery}
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
              onRequestProposal={(message) => act(() => requestProposal(selectedOrThrow(), message))}
              onApprove={(proposal, prompt) => act(() => approveProposal(proposal, prompt))}
              onIgnore={(proposal) => act(() => post(`/api/proposals/${proposal.id}/ignore`))}
            />
          </section>
        ) : (
          <section className="single-work-view">
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
              onRequestProposal={(message) => act(() => requestProposal(selectedOrThrow(), message))}
              onApprove={(proposal, prompt) => act(() => approveProposal(proposal, prompt))}
              onIgnore={(proposal) => act(() => post(`/api/proposals/${proposal.id}/ignore`))}
            />
          </section>
        )}
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

async function requestProposal(meetingId: string, message: string): Promise<MeetingProjection> {
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

function writeMeetingUrl(meetingId: string, section: Section, demoMode: boolean) {
  const next = new URL(window.location.href);
  next.searchParams.set("meeting", meetingId);
  if (section === "meeting") next.searchParams.delete("section");
  else next.searchParams.set("section", section);
  if (demoMode) next.searchParams.set("mode", "demo");
  else next.searchParams.delete("mode");
  window.history.replaceState(null, "", `${next.pathname}${next.search}${next.hash}`);
}

function summaryFromProjection(projection: MeetingProjection | null, meetingId: string): MeetingSummary {
  return {
    id: meetingId,
    title: displayMeetingTitle(projection?.title, meetingId),
    started_at: null,
    updated_at: null,
    source_status: projection?.source.status ?? "idle",
    transcript_count: projection?.transcript.length ?? 0,
    question_count: projection?.proposal_requests.length ?? 0,
    open_suggestion_count:
      projection?.proposals.filter((proposal) => proposal.status === "proposed").length ?? 0,
    running_job_count:
      projection?.jobs.filter((job) => job.status === "queued" || job.status === "running").length ?? 0,
    output_count: projection?.artifacts.length ?? 0,
    latest_activity: null,
  };
}

function defaultMeetingTitle(): string {
  return `Meeting ${new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date())}`;
}

function meetingTitleFallback(meetingId: string | null): string {
  if (!meetingId) return "No meeting selected";
  return meetingId
    .split(/[-_]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function displayMeetingTitle(title: string | null | undefined, meetingId: string | null): string {
  if (!title) return meetingTitleFallback(meetingId);
  return meetingId && title === meetingId ? meetingTitleFallback(meetingId) : title;
}

function formatMeetingTimestamp(value: string | null | undefined): string {
  if (!value) return "No activity yet";
  const epochMatch = value.match(/^(\d{10})\.(\d{3})Z$/);
  const date = epochMatch
    ? new Date(Number(epochMatch[1]) * 1000 + Number(epochMatch[2]))
    : new Date(value);
  if (Number.isNaN(date.getTime())) return value.replace("T", " ").slice(0, 16);
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
}

function meetingActivityTimestamp(meeting: MeetingSummary | null): string {
  return formatMeetingTimestamp(meeting?.updated_at ?? meeting?.started_at ?? meeting?.latest_activity);
}

function MeetingRail({
  meetings,
  selectedMeetingId,
  busy,
  onCreateMeeting,
  onSelectMeeting,
}: {
  meetings: MeetingSummary[];
  selectedMeetingId: string | null;
  busy: boolean;
  onCreateMeeting: () => void;
  onSelectMeeting: (meetingId: string) => void;
}) {
  return (
    <aside className="sidebar meeting-rail">
      <div className="brand-block">
        <div className="brand-mark">S</div>
        <div>
          <strong>Standby</strong>
          <span>Meetings</span>
        </div>
      </div>
      <button className="new-meeting-button" onClick={onCreateMeeting} disabled={busy}>
        <Plus size={16} /> New meeting
      </button>
      <nav className="meeting-list" aria-label="Meetings">
        {meetings.length === 0 ? (
          <div className="meeting-list-empty">
            <strong>No meetings</strong>
            <p>Create a meeting to start collecting transcript, questions, actions, and outputs.</p>
          </div>
        ) : null}
        {meetings.map((meeting) => {
          const meta = STATUS_LABEL[meeting.source_status];
          const active = selectedMeetingId === meeting.id;
          return (
          <button
            key={meeting.id}
            className={`meeting-list-item ${active ? "active" : ""}`}
            onClick={() => onSelectMeeting(meeting.id)}
          >
            <span className="meeting-list-title">
              <span className={`status-dot ${meta.tone}`} />
              <strong>{displayMeetingTitle(meeting.title, meeting.id)}</strong>
            </span>
            <time>{meetingActivityTimestamp(meeting)}</time>
            <span className="meeting-counts" aria-label="Meeting summary counts">
              <span>{meeting.open_suggestion_count} suggestions</span>
              <span>{meeting.running_job_count} running</span>
              <span>{meeting.output_count} outputs</span>
            </span>
          </button>
          );
        })}
      </nav>
    </aside>
  );
}

function MeetingHeader({
  meetings,
  selectedMeetingId,
  title,
  summary,
  status,
  source,
  activeSection,
  busy,
  capturing,
  isDemo,
  proposalCount,
  jobCount,
  artifactCount,
  transcriptCount,
  onSectionChange,
  onSelectMeeting,
  onCreateMeeting,
  onRenameMeeting,
  onStart,
  onStop,
  onDemo,
}: {
  meetings: MeetingSummary[];
  selectedMeetingId: string | null;
  title: string;
  summary: MeetingSummary | null;
  status: SourceStatus;
  source: SourceState | null;
  activeSection: Section;
  busy: boolean;
  capturing: boolean;
  isDemo: boolean;
  proposalCount: number;
  jobCount: number;
  artifactCount: number;
  transcriptCount: number;
  onSectionChange: (section: Section) => void;
  onSelectMeeting: (meetingId: string) => void;
  onCreateMeeting: () => void;
  onRenameMeeting: (title: string) => void;
  onStart: () => void;
  onStop: () => void;
  onDemo: () => void;
}) {
  const meta = STATUS_LABEL[status];
  const failure = source?.failure
    ? FAILURE_TEXT[source.failure.reason] ?? source.failure.detail ?? source.failure.reason
    : null;
  return (
    <header className="topbar meeting-header">
      <div className="meeting-header-main">
        <div className="mobile-brand-row">
          <div className="brand-mark">S</div>
          <strong>Standby</strong>
        </div>
        {selectedMeetingId ? (
          <MeetingTitleEditor title={title} busy={busy} onRename={onRenameMeeting} />
        ) : (
          <div className="meeting-title-display">
            <h1>No meeting selected</h1>
            <p>Create a meeting or pick one from the rail.</p>
          </div>
        )}
        <div className="meeting-meta-line">
          <span className={`status-dot ${meta.tone}`} />
          <strong>{meta.label}</strong>
          <span>{meetingActivityTimestamp(summary)}</span>
          {summary ? (
            <span>
              {summary.question_count} asked / {summary.transcript_count} source
            </span>
          ) : null}
        </div>
      </div>
      <div className="meeting-header-actions">
        <label className="mobile-meeting-select">
          <span>Meeting</span>
          <select
            value={selectedMeetingId ?? ""}
            onChange={(event) => {
              if (event.target.value) onSelectMeeting(event.target.value);
            }}
          >
            <option value="">Select meeting</option>
            {meetings.map((meeting) => (
              <option key={meeting.id} value={meeting.id}>
                {displayMeetingTitle(meeting.title, meeting.id)}
              </option>
            ))}
          </select>
        </label>
        {selectedMeetingId ? (
          capturing ? (
            <button className="primary danger" onClick={onStop} disabled={busy}>
              <Square size={16} /> Stop
            </button>
          ) : (
            <button className="primary" onClick={onStart} disabled={busy}>
              <PlayCircle size={17} /> Start
            </button>
          )
        ) : (
          <button className="primary" onClick={onCreateMeeting} disabled={busy}>
            <Plus size={16} /> New
          </button>
        )}
        {isDemo && selectedMeetingId ? (
          <button onClick={onDemo} disabled={busy}>
            Reload demo
          </button>
        ) : (
          <a className="ghost-link button-like" href="?mode=demo&meeting=demo">
            Demo
          </a>
        )}
      </div>
      {selectedMeetingId ? (
        <MeetingViewTabs
          activeSection={activeSection}
          proposalCount={proposalCount}
          jobCount={jobCount}
          artifactCount={artifactCount}
          transcriptCount={transcriptCount}
          onSectionChange={onSectionChange}
        />
      ) : null}
      {failure ? (
        <div className="failure-note header-failure">
          <AlertTriangle size={15} /> {failure}
        </div>
      ) : null}
    </header>
  );
}

function MeetingTitleEditor({
  title,
  busy,
  onRename,
}: {
  title: string;
  busy: boolean;
  onRename: (title: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(title);
  useEffect(() => {
    setDraft(title);
    setEditing(false);
  }, [title]);

  function submit() {
    const trimmed = draft.trim();
    if (!trimmed || trimmed === title) {
      setDraft(title);
      setEditing(false);
      return;
    }
    onRename(trimmed);
    setEditing(false);
  }

  if (editing) {
    return (
      <form
        className="meeting-title-edit"
        onSubmit={(event) => {
          event.preventDefault();
          submit();
        }}
      >
        <input
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          onBlur={submit}
          autoFocus
          maxLength={120}
        />
      </form>
    );
  }

  return (
    <div className="meeting-title-display">
      <h1>{title}</h1>
      <button className="icon-button" onClick={() => setEditing(true)} disabled={busy} title="Rename meeting">
        <PencilLine size={15} />
      </button>
    </div>
  );
}

function MeetingViewTabs({
  activeSection,
  onSectionChange,
  proposalCount,
  jobCount,
  artifactCount,
  transcriptCount,
}: {
  activeSection: Section;
  onSectionChange: (section: Section) => void;
  proposalCount: number;
  jobCount: number;
  artifactCount: number;
  transcriptCount: number;
}) {
  const navItems = [
    { id: "meeting", label: "Action stream", count: proposalCount },
    { id: "jobs", label: "Outputs", count: artifactCount || jobCount },
    { id: "notes", label: "Source", count: transcriptCount },
    { id: "audio", label: "Audio", count: 0 },
  ] satisfies Array<{ id: Section; label: string; count: number }>;
  return (
    <nav className="meeting-view-tabs" aria-label="Meeting views">
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

function EmptyMeetingState({
  busy,
  onCreateMeeting,
}: {
  busy: boolean;
  onCreateMeeting: () => void;
}) {
  return (
    <section className="empty-meeting-view">
      <div>
        <Sparkles size={24} />
        <h1>Start with a meeting</h1>
        <p>Each transcript, question, suggested action, agent run, and output now belongs to a named meeting.</p>
        <button className="primary" onClick={onCreateMeeting} disabled={busy}>
          <Plus size={17} /> New meeting
        </button>
      </div>
    </section>
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

function TranscriptSearchControls({
  transcriptQuery,
  onTranscriptQueryChange,
}: {
  transcriptQuery: string;
  onTranscriptQueryChange: (query: string) => void;
}) {
  return (
    <div className="transcript-search-controls">
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
  const { turns, partialTurn } = useMemo(() => {
    const timeline = buildTranscriptTimeline(segments);
    return {
      turns: buildTranscriptTurns(timeline),
      partialTurn: partial ? buildPartialTranscriptTurn(partial, timeline) : null,
    };
  }, [segments, partial]);
  const newestFirst = useMemo(() => {
    const ordered = [...turns].reverse();
    if (!trimmedQuery) return ordered;
    return ordered.filter((turn) => transcriptTurnMatches(turn, trimmedQuery));
  }, [turns, trimmedQuery]);
  const partialVisible: TranscriptTurn | null =
    partialTurn && (!trimmedQuery || transcriptTurnMatches(partialTurn, trimmedQuery))
      ? partialTurn
      : null;
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
        <TranscriptTurnRow turn={partialVisible} partial />
      ) : null}
      {newestFirst.map((segment) => (
        <TranscriptTurnRow key={segment.id} turn={segment} />
      ))}
    </div>
  );
}

function transcriptTurnMatches(turn: TranscriptTurn, query: string): boolean {
  return `${speakerLabel(turn.speaker)} ${turn.text}`.toLowerCase().includes(query);
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

function TranscriptTurnRow({ turn, partial = false }: { turn: TranscriptTurn; partial?: boolean }) {
  return (
    <article className={`transcript-row${partial ? " partial" : ""}`}>
      <span className={`avatar ${speakerTone(turn.speaker)}`}>{speakerInitials(turn.speaker)}</span>
      <div className="transcript-copy">
        <div className="transcript-speaker-line">
          <strong>{speakerLabel(turn.speaker)}</strong>
          <small>{turn.segments.length} span{turn.segments.length === 1 ? "" : "s"}</small>
        </div>
        <p className={partial ? "partial-text" : undefined}>{partial ? `${turn.text}…` : turn.text}</p>
      </div>
      <time>{formatTimeRange(turn.start_ms, turn.end_ms)}</time>
    </article>
  );
}

function buildTranscriptTimeline(segments: TranscriptSegment[]): DisplayTranscriptSegment[] {
  if (!transcriptNeedsSyntheticTimeline(segments)) {
    return segments.map((segment) => ({
      ...segment,
      display_start_ms: segment.start_ms,
      display_end_ms: Math.max(segment.end_ms, segment.start_ms),
    }));
  }

  let cursor = 0;
  return segments.map((segment) => {
    const duration = Math.max(1_500, segment.end_ms - segment.start_ms, estimateSpeechDurationMs(segment.text));
    const displaySegment = {
      ...segment,
      display_start_ms: cursor,
      display_end_ms: cursor + duration,
    };
    cursor = displaySegment.display_end_ms + 250;
    return displaySegment;
  });
}

function transcriptNeedsSyntheticTimeline(segments: TranscriptSegment[]): boolean {
  if (segments.length < 3) return false;
  const starts = segments.map((segment) => segment.start_ms);
  const distinctStarts = new Set(starts).size;
  const monotonic = starts.every((start, index) => index === 0 || start >= starts[index - 1]);
  const allAtZero = starts.every((start) => start === 0);
  const tooFewDistinctStarts = distinctStarts <= Math.max(2, Math.floor(segments.length / 3));
  return allAtZero || !monotonic || tooFewDistinctStarts;
}

function estimateSpeechDurationMs(text: string): number {
  const wordCount = text.trim().split(/\s+/).filter(Boolean).length;
  return Math.min(8_000, Math.max(1_800, wordCount * 360));
}

function buildPartialTranscriptTurn(
  partial: TranscriptSegment,
  timeline: DisplayTranscriptSegment[],
): TranscriptTurn {
  const lastEnd = timeline.at(-1)?.display_end_ms ?? 0;
  const rawStart = partial.start_ms > 0 ? partial.start_ms : lastEnd;
  const rawEnd = Math.max(partial.end_ms, rawStart + estimateSpeechDurationMs(partial.text));
  const displayPartial: DisplayTranscriptSegment = {
    ...partial,
    display_start_ms: rawStart,
    display_end_ms: rawEnd,
  };
  return segmentToTurn(displayPartial);
}

function buildTranscriptTurns(segments: DisplayTranscriptSegment[]): TranscriptTurn[] {
  const turns: TranscriptTurn[] = [];
  for (const segment of segments) {
    const previous = turns.at(-1);
    if (previous && shouldMergeTranscriptSegment(previous, segment)) {
      previous.segments.push(segment);
      previous.end_ms = Math.max(previous.end_ms, segment.display_end_ms);
      previous.text = normalizeTranscriptText(`${previous.text} ${segment.text}`);
    } else {
      turns.push(segmentToTurn(segment));
    }
  }
  return turns;
}

function shouldMergeTranscriptSegment(turn: TranscriptTurn, segment: DisplayTranscriptSegment): boolean {
  const sameSpeaker = speakerLabel(turn.speaker) === speakerLabel(segment.speaker);
  const gap = segment.display_start_ms - turn.end_ms;
  const combinedLength = turn.text.length + segment.text.length;
  return sameSpeaker && gap <= 8_000 && turn.segments.length < 6 && combinedLength < 560;
}

function segmentToTurn(segment: DisplayTranscriptSegment): TranscriptTurn {
  return {
    id: segment.id,
    speaker: segment.speaker,
    start_ms: segment.display_start_ms,
    end_ms: segment.display_end_ms,
    text: normalizeTranscriptText(segment.text),
    segments: [segment],
  };
}

function normalizeTranscriptText(text: string): string {
  return text.replace(/\s+/g, " ").trim();
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

function MeetingActionStream({
  projection,
  status,
  activeProposals,
  latestNoProposal,
  proposalCount,
  jobCount,
  artifactCount,
  busy,
  error,
  transcriptQuery,
  onTranscriptQueryChange,
  onRequestProposal,
  onApprove,
  onIgnore,
}: {
  projection: MeetingProjection | null;
  status: SourceStatus;
  activeProposals: Proposal[];
  latestNoProposal: NoProposal | null;
  proposalCount: number;
  jobCount: number;
  artifactCount: number;
  busy: boolean;
  error: string | null;
  transcriptQuery: string;
  onTranscriptQueryChange: (query: string) => void;
  onRequestProposal: (message: string) => void;
  onApprove: (proposal: Proposal, prompt: string) => void;
  onIgnore: (proposal: Proposal) => void;
}) {
  const jobs = useMemo(() => [...(projection?.jobs ?? [])].reverse(), [projection?.jobs]);
  const artifacts = useMemo(() => [...(projection?.artifacts ?? [])].reverse(), [projection?.artifacts]);
  const transcript = projection?.transcript ?? [];
  const hasStreamItems =
    activeProposals.length > 0 || jobs.length > 0 || artifacts.length > 0 || latestNoProposal !== null;

  return (
    <section className="action-layout">
      <section className="action-main-panel" aria-label="Action stream">
        <header className="action-header">
          <div>
            <h1>Action stream</h1>
            <p>Suggested work, running jobs, and completed outputs in one readable feed.</p>
          </div>
          <WorkIndicatorDock proposals={proposalCount} jobs={jobCount} artifacts={artifactCount} transcript={transcript.length} />
        </header>
        <div className="action-stream-list">
          {!hasStreamItems ? (
            <EmptyWork
              icon={Sparkles}
              title="No action items yet"
              body="Ask Standby for work or keep listening until a proposal appears."
            />
          ) : null}
          {activeProposals.map((proposal) => (
            <ProposalCard
              key={proposal.id}
              proposal={proposal}
              onApprove={(prompt) => onApprove(proposal, prompt)}
              onIgnore={() => onIgnore(proposal)}
            />
          ))}
          {jobs.map((job) => (
            <JobCard key={job.id} job={job} />
          ))}
          {artifacts.map((artifact) => (
            <ResultCard key={artifact.id} artifact={artifact} />
          ))}
          {latestNoProposal ? <NoProposalEvent noProposal={latestNoProposal} /> : null}
        </div>
      </section>
      <aside className="action-companion" aria-label="Ask and source">
        <AskStandbyBox
          disabled={busy}
          transcriptCount={transcript.length}
          onRequestProposal={onRequestProposal}
        />
        {error ? <div className="failure-note companion-error">{error}</div> : null}
        <details className="source-drawer">
          <summary>
            <span>Meeting source</span>
            <small>{transcript.length} transcript span{transcript.length === 1 ? "" : "s"}</small>
          </summary>
          <TranscriptSearchControls
            transcriptQuery={transcriptQuery}
            onTranscriptQueryChange={onTranscriptQueryChange}
          />
          <TranscriptList
            segments={transcript}
            partial={projection?.partial ?? null}
            status={status}
            query={transcriptQuery}
          />
        </details>
      </aside>
    </section>
  );
}

function WorkIndicatorDock({
  proposals,
  jobs,
  artifacts,
  transcript,
}: {
  proposals: number;
  jobs: number;
  artifacts: number;
  transcript: number;
}) {
  return (
    <div className="work-indicators" aria-label="Available meeting views">
      <span><strong>{proposals}</strong> suggestions</span>
      <span><strong>{jobs}</strong> running/work</span>
      <span><strong>{artifacts}</strong> outputs</span>
      <span><strong>{transcript}</strong> source</span>
    </div>
  );
}

function NoProposalEvent({ noProposal }: { noProposal: NoProposal }) {
  return (
    <article className="no-proposal-event">
      <div>
        <Sparkles size={17} />
        <strong>No card created</strong>
      </div>
      <p>{noProposal.model.provider} returned no action: {humanReason(noProposal.reason)}.</p>
      {noProposal.operator_message ? <small>Request: {noProposal.operator_message}</small> : null}
    </article>
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

function formatTimeRange(startMs: number, endMs: number): string {
  const start = formatTime(startMs);
  const end = formatTime(endMs);
  return start === end ? start : `${start}-${end}`;
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
