import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  ArrowUp,
  Bot,
  BriefcaseBusiness,
  CheckCircle2,
  ChevronDown,
  Clock3,
  FileText,
  Maximize2,
  MessageSquareText,
  Mic2,
  MoreHorizontal,
  PenLine,
  Play,
  Search,
  Settings,
  Sparkles,
  Users,
  XCircle,
} from "lucide-react";
import "./styles.css";

type ProposalStatus = "proposed" | "approved" | "ignored";
type JobStatus = "queued" | "running" | "needs_input" | "completed" | "failed" | "canceled";

type TranscriptSegment = {
  id: string;
  meeting_id: string;
  speaker: string | null;
  start_ms: number;
  end_ms: number;
  text: string;
  is_final: boolean;
  confidence: number | null;
  source: string;
};

type TranscriptEvidence = {
  segment_id: string;
  speaker: string | null;
  start_ms: number;
  end_ms: number;
  text: string;
};

type Proposal = {
  id: string;
  meeting_id: string;
  kind: string;
  title: string;
  rationale: string;
  draft_prompt: string;
  evidence: TranscriptEvidence[];
  suggested_worker: string;
  confidence: number;
  status: ProposalStatus;
};

type AgentJobSpec = {
  id: string;
  meeting_id: string;
  proposal_id: string | null;
  worker: string;
  title: string;
  prompt: string;
  status: JobStatus;
  budget: { max_minutes: number; max_cost_usd: number | null };
};

type Artifact = {
  id: string;
  job_id: string;
  title: string;
  summary: string;
  uri: string | null;
};

type MeetingProjection = {
  meeting_id: string;
  title: string | null;
  transcript: TranscriptSegment[];
  proposals: Proposal[];
  jobs: AgentJobSpec[];
  artifacts: Artifact[];
  events: Array<{ id: string; event_type: string; created_at: string }>;
};

const meetingId = new URLSearchParams(window.location.search).get("meeting") ?? "demo";

function App() {
  const [projection, setProjection] = useState<MeetingProjection | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  async function refresh() {
    const response = await fetch(`/api/meetings/${meetingId}`);
    if (!response.ok) throw new Error(`projection failed: ${response.status}`);
    setProjection(await response.json());
  }

  async function startDemo() {
    setError(null);
    setLoading(true);
    try {
      const response = await fetch(`/api/meetings/${meetingId}/demo`, {
        method: "POST",
      });
      if (!response.ok) throw new Error(`demo failed: ${response.status}`);
      setProjection(await response.json());
    } catch (err) {
      setError(err instanceof Error ? err.message : "Unable to start demo");
    } finally {
      setLoading(false);
    }
  }

  async function approve(proposal: Proposal) {
    const response = await fetch(`/api/proposals/${proposal.id}/approve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        approved_by: "Phaedrus",
        prompt: proposal.draft_prompt,
      }),
    });
    if (!response.ok) throw new Error(`approval failed: ${response.status}`);
    setProjection(await response.json());
  }

  async function ignore(proposal: Proposal) {
    const response = await fetch(`/api/proposals/${proposal.id}/ignore`, {
      method: "POST",
    });
    if (!response.ok) throw new Error(`ignore failed: ${response.status}`);
    setProjection(await response.json());
  }

  useEffect(() => {
    startDemo();
    const interval = window.setInterval(() => {
      refresh().catch(() => undefined);
    }, 2500);
    return () => window.clearInterval(interval);
  }, []);

  const activeProposal = projection?.proposals.find((proposal) => proposal.status === "proposed");
  const runningJob = projection?.jobs.find((job) => job.status === "running") ?? projection?.jobs.at(-1);
  const latestArtifact = projection?.artifacts.at(-1);

  return (
    <div className="app-shell">
      <Sidebar />
      <main className="workspace">
        <TopBar title={projection?.title ?? "Acme / Q2 Planning"} />
        <section className="content-grid">
          <TranscriptPanel segments={projection?.transcript ?? []} loading={loading} error={error} onStart={startDemo} />
          <aside className="work-panel" aria-label="Proposal and job cards">
            <PanelTabs proposals={projection?.proposals.length ?? 0} jobs={projection?.jobs.length ?? 0} />
            {activeProposal ? (
              <ProposalCard proposal={activeProposal} onApprove={approve} onIgnore={ignore} />
            ) : (
              <EmptyProposal />
            )}
            {runningJob ? <JobCard job={runningJob} /> : null}
            {latestArtifact ? <ResultCard artifact={latestArtifact} /> : null}
          </aside>
        </section>
        <CommandStrip />
      </main>
    </div>
  );
}

function Sidebar() {
  const navItems = [
    [Mic2, "Meeting", "active"],
    [FileText, "Notes", ""],
    [BriefcaseBusiness, "Jobs", "count"],
    [MessageSquareText, "Results", ""],
    [Users, "Agents", ""],
    [Settings, "Settings", ""],
  ] as const;

  return (
    <aside className="sidebar">
      <div className="brand-block">
        <div className="window-dots" aria-hidden="true">
          <span className="dot red" />
          <span className="dot yellow" />
          <span className="dot green" />
        </div>
        <div className="brand-mark">T</div>
        <strong>Tacet</strong>
      </div>
      <nav className="nav-list" aria-label="Primary">
        {navItems.map(([Icon, label, state]) => (
          <button key={label} className={`nav-item ${state === "active" ? "active" : ""}`}>
            <Icon size={18} />
            <span>{label}</span>
            {state === "count" ? <span className="nav-count">2</span> : null}
          </button>
        ))}
      </nav>
      <div className="meeting-card">
        <div className="meeting-row">
          <strong>Acme / Q2 Planning</strong>
          <span className="live-pill">Live</span>
        </div>
        <p>Zoom · 6 people</p>
        <p>Started 10:02 AM</p>
        <button className="leave-button">Leave meeting</button>
      </div>
      <div className="user-row">
        <span className="avatar black">JS</span>
        <div>
          <strong>Jordan Smith</strong>
          <p>Local-first</p>
        </div>
        <ChevronDown size={16} />
      </div>
    </aside>
  );
}

function TopBar({ title }: { title: string }) {
  return (
    <header className="topbar">
      <div className="status-cluster">
        <span className="status-dot" />
        <strong>Live meeting</strong>
        <Mic2 size={17} />
        <span>01:24:37</span>
        <Users size={17} />
        <span>6</span>
        <span className="divider" />
        <span>{title}</span>
      </div>
      <div className="status-cluster right">
        <span className="status-dot" />
        <span>Transcribing</span>
        <Mic2 size={17} />
        <Settings size={18} />
        <Maximize2 size={18} />
      </div>
    </header>
  );
}

function TranscriptPanel({
  segments,
  loading,
  error,
  onStart,
}: {
  segments: TranscriptSegment[];
  loading: boolean;
  error: string | null;
  onStart: () => void;
}) {
  return (
    <section className="transcript-panel">
      <div className="transcript-tools">
        <label className="search-field">
          <Search size={18} />
          <input placeholder="Search transcript" />
        </label>
        <button>Speakers <ChevronDown size={14} /></button>
        <button aria-label="More filters"><MoreHorizontal size={18} /></button>
      </div>
      <div className="transcript-list">
        {error ? (
          <div className="empty-state">
            <strong>Daemon unavailable</strong>
            <p>{error}</p>
            <button className="primary small" onClick={onStart}>Retry</button>
          </div>
        ) : null}
        {loading && segments.length === 0 ? (
          <div className="empty-state">
            <strong>Starting demo meeting</strong>
            <p>Seeding transcript spans and proposal detection.</p>
          </div>
        ) : null}
        {segments.map((segment, index) => (
          <TranscriptRow key={segment.id} segment={segment} index={index} />
        ))}
      </div>
      <div className="audio-strip">
        <span className="wave" />
        <strong>Live</strong>
      </div>
    </section>
  );
}

function TranscriptRow({ segment, index }: { segment: TranscriptSegment; index: number }) {
  const initials = (segment.speaker ?? "?")
    .split(" ")
    .map((part) => part[0])
    .join("")
    .slice(0, 2);
  const colors = ["green", "blue", "orange", "violet"];
  return (
    <article className="transcript-row">
      <time>{formatTime(segment.start_ms)}</time>
      <span className={`avatar ${colors[index % colors.length]}`}>{initials}</span>
      <div>
        <strong>{segment.speaker ?? "Unknown speaker"}</strong>
        <p>{segment.text}</p>
      </div>
    </article>
  );
}

function PanelTabs({ proposals, jobs }: { proposals: number; jobs: number }) {
  return (
    <div className="panel-tabs">
      <button className="selected">Proposals <span>{proposals}</span></button>
      <button>Jobs <span>{jobs}</span></button>
      <button>Results</button>
    </div>
  );
}

function ProposalCard({
  proposal,
  onApprove,
  onIgnore,
}: {
  proposal: Proposal;
  onApprove: (proposal: Proposal) => Promise<void>;
  onIgnore: (proposal: Proposal) => Promise<void>;
}) {
  const [prompt, setPrompt] = useState(proposal.draft_prompt);
  const [busy, setBusy] = useState(false);
  const evidence = proposal.evidence[0];

  async function run() {
    setBusy(true);
    try {
      await onApprove({ ...proposal, draft_prompt: prompt });
    } finally {
      setBusy(false);
    }
  }

  return (
    <article className="proposal-card">
      <div className="card-heading">
        <Sparkles size={18} />
        <div>
          <h2>{proposal.title}</h2>
          <p>Why: Maya asked whether this already exists</p>
        </div>
        <ChevronDown size={18} />
      </div>
      <div className="meta-row">
        <span><Bot size={16} /> Research Agent</span>
        <span><Clock3 size={16} /> Budget 8m</span>
      </div>
      <div className="goal-block">
        <strong>Goal</strong>
        <p>{proposal.rationale}</p>
      </div>
      <div className="evidence-block">
        <strong>Evidence</strong>
        <blockquote>{evidence ? evidence.text : "Transcript evidence unavailable."}</blockquote>
      </div>
      <label className="prompt-box">
        <span>Prompt <em>(editable)</em></span>
        <textarea value={prompt} onChange={(event) => setPrompt(event.target.value)} />
        <small>{prompt.length}/2000</small>
      </label>
      <div className="button-row">
        <button className="primary" onClick={run} disabled={busy}>
          <Play size={17} /> {busy ? "Running" : "Run"}
        </button>
        <button><PenLine size={17} /> Edit</button>
        <button onClick={() => onIgnore(proposal)}><XCircle size={17} /> Ignore</button>
        <button><Clock3 size={17} /> Snooze <ChevronDown size={14} /></button>
      </div>
    </article>
  );
}

function EmptyProposal() {
  return (
    <article className="empty-proposal">
      <Sparkles size={19} />
      <div>
        <strong>No pending proposals</strong>
        <p>Approved or ignored cards stay in the event ledger.</p>
      </div>
    </article>
  );
}

function JobCard({ job }: { job: AgentJobSpec }) {
  const percent = job.status === "completed" ? 100 : job.status === "running" ? 47 : 8;
  return (
    <article className="job-card">
      <div className="job-title">
        <span><Bot size={17} /> Research Agent · {job.title}</span>
        <strong>{job.status === "completed" ? "Complete" : "Job running"}</strong>
      </div>
      <div className="progress-track">
        <span style={{ width: `${percent}%` }} />
      </div>
      <div className="job-foot">
        <span>Searching · <strong>Analyzing</strong> · Synthesizing</span>
        <button>View job <Maximize2 size={14} /></button>
      </div>
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
      <span>Research complete</span>
      <p>{artifact.summary}</p>
      <button>Open result <Maximize2 size={14} /></button>
    </article>
  );
}

function CommandStrip() {
  return (
    <footer className="command-strip">
      <button className="kbd">⌘K</button>
      <input placeholder="Ask Tacet or run a command..." />
      <button className="icon-button" aria-label="Add context">+</button>
      <button>Agent <ChevronDown size={14} /></button>
      <button className="send" aria-label="Send command"><ArrowUp size={18} /></button>
      <div className="privacy-row">
        <span>All data stored locally</span>
        <span>End-to-end on device</span>
        <span>Worker agents run locally</span>
      </div>
    </footer>
  );
}

function formatTime(ms: number) {
  const baseMinutes = 10 * 60 + 2;
  const seconds = Math.floor(ms / 1000);
  const total = baseMinutes + seconds;
  const minutes = Math.floor(total / 60);
  const remainder = total % 60;
  return `${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}`;
}

createRoot(document.getElementById("root")!).render(<App />);
