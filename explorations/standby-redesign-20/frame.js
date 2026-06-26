const transcript = [
  ["01:04-01:22", "Maya", "Receipt and exact claims are required before we cite anything."],
  ["00:41-00:50", "Riley", "End with a concise recommendation before the meeting ends."],
  ["00:31-00:40", "Alex", "Scope it to local-first tools from the last 18 months, including open source."],
  ["00:17-00:30", "Jordan", "Run a quick prior-art sweep focused on audit trails."],
  ["00:00-00:16", "Maya", "Find whether a private meeting assistant can act during the call."]
];

const suggestions = [
  {
    id: "S-24",
    title: "Run private assistant landscape scan",
    state: "suggested",
    detail: "Compare local-first meeting assistants, agent execution, audit trails, and open-source evidence.",
    evidence: "Alex, 00:31-00:40",
    prompt: "Find private meeting assistant products that can act during a live call. Prioritize local-first design, agent execution, audit trails, and open-source evidence. Return cited claims and a recommendation."
  },
  {
    id: "S-25",
    title: "Draft in-room recommendation",
    state: "suggested",
    detail: "Turn completed research into a short recommendation the room can use now.",
    evidence: "Riley, 00:41-00:50",
    prompt: "Write a concise recommendation for this meeting using completed research, source links, confidence level, and caveats."
  }
];

const work = [
  {
    id: "R-11",
    title: "Prior-art sweep",
    state: "running",
    detail: "OpenCode is reading product pages, docs, and repo evidence.",
    receipt: "receipt pending",
    time: "2:18 elapsed"
  },
  {
    id: "R-09",
    title: "Audit-trail comparison",
    state: "completed",
    detail: "Completed with cited output and artifact path.",
    receipt: "/tmp/standby/job-audit-trails/artifact.md",
    time: "done"
  },
  {
    id: "R-07",
    title: "Old source crawl",
    state: "failed",
    detail: "Network timeout retained as a visible job failure.",
    receipt: "agent_job.failed in event log",
    time: "failed"
  }
];

const outputs = [
  {
    id: "O-09",
    title: "Closest product gap",
    state: "completed",
    detail: "Meeting note tools capture and summarize. Code agents execute work. The gap is an approval-gated bridge that lets a private meeting assistant dispatch auditable work during the call.",
    evidence: "Maya, 00:00-00:16",
    receipt: "/tmp/standby/job-audit-trails/artifact.md"
  },
  {
    id: "O-08",
    title: "Recommendation draft",
    state: "draft",
    detail: "Position Standby as a local-first meeting command surface: transcript as evidence, deterministic approval as the gate, OpenCode as the worker, receipts as the trust layer.",
    evidence: "Riley, 00:41-00:50",
    receipt: "draft response"
  }
];

const chat = [
  ["user", "What products are closest to this?"],
  ["agent", "Closest public comparisons are meeting note tools for capture and code agents for execution. The missing piece is an approval-gated bridge between live meeting context and auditable worker runs."],
  ["agent-action", "I can run a private assistant landscape scan using the last minute of meeting context."],
  ["user", "Can you turn that into a recommendation?"],
  ["agent", "Yes. I can draft a short recommendation after the current scan completes, then attach sources and the worker receipt."]
];

const specs = {
  PD01: ["Focused Conversation", renderFocusedConversation],
  PD02: ["Action Stream", renderActionStream],
  PD03: ["Current Decision", renderCurrentDecision],
  PD04: ["Quiet Workboard", renderQuietWorkboard],
  PD05: ["Output Review", renderOutputReview],
  PD06: ["Approval Chat", renderApprovalChat],
  PD07: ["Minimal Room", renderMinimalRoom],
  PD08: ["Ledger Lens", renderLedgerLens],
  PD09: ["Running Lens", renderRunningLens],
  PD10: ["Command Shelf", renderCommandShelf]
};

function topbar(id, name) {
  return `
    <header class="topbar">
      <div class="brand">
        <span class="brand-mark">S</span>
        <div>
          <strong>${id} - ${name}</strong>
          <span>progressive agent surface</span>
        </div>
      </div>
      ${indicatorDock("top")}
    </header>
  `;
}

function indicatorDock(mode = "") {
  const items = [
    ["suggestions", "2"],
    ["running", "1"],
    ["outputs", "2"],
    ["source", "5"]
  ];
  return `
    <nav class="indicator-dock ${mode}" aria-label="Meeting surfaces">
      ${items.map(([label, count]) => `<button type="button"><strong>${count}</strong><span>${label}</span></button>`).join("")}
    </nav>
  `;
}

function panel(title, meta, body, extra = "") {
  return `
    <section class="panel ${extra}">
      <div class="panel-head">
        <strong>${title}</strong>
        <span>${meta}</span>
      </div>
      ${body}
    </section>
  `;
}

function sourceDrawer(label = "Meeting source") {
  return `
    <details class="source-drawer">
      <summary>${label}</summary>
      <div class="source-list">
        ${transcript.map(([time, speaker, text]) => `
          <article>
            <time>${time}</time>
            <strong>${speaker}</strong>
            <p>${text}</p>
          </article>
        `).join("")}
      </div>
    </details>
  `;
}

function stateDot(state) {
  return `<span class="state-dot ${state}"></span>`;
}

function actionButtons(kind = "suggested") {
  if (kind === "failed") {
    return `<div class="actions"><button class="primary" type="button">Retry</button><button type="button">View receipt</button></div>`;
  }
  if (kind === "completed" || kind === "draft") {
    return `<div class="actions"><button class="primary" type="button">Use output</button><button type="button">Ask follow-up</button><button type="button">View receipt</button></div>`;
  }
  return `<div class="actions"><button class="primary" type="button">Approve</button><button type="button">Edit</button><button class="quiet" type="button">Dismiss</button></div>`;
}

function suggestionCard(item, mode = "full") {
  const editor = mode === "full" ? `
    <label class="fine" for="${item.id}-prompt">Editable prompt</label>
    <textarea id="${item.id}-prompt" aria-label="Editable prompt">${item.prompt}</textarea>
  ` : "";
  return `
    <article class="work-card ${item.state}">
      <div class="work-head">${stateDot(item.state)}<div><strong>${item.title}</strong><span>${item.id} - ${item.state}</span></div></div>
      <p>${item.detail}</p>
      <span class="citation">${item.evidence}</span>
      ${editor}
      ${actionButtons(item.state)}
    </article>
  `;
}

function runCard(item, mode = "compact") {
  const log = mode === "full" ? `<pre>spawn opencode worker\nread sources\nwrite receipt artifact</pre>` : "";
  return `
    <article class="work-card ${item.state}">
      <div class="work-head">${stateDot(item.state)}<div><strong>${item.title}</strong><span>${item.id} - ${item.time}</span></div></div>
      <p>${item.detail}</p>
      <span class="receipt mono">${item.receipt}</span>
      ${log}
      <div class="actions"><button class="primary" type="button">Open</button><button type="button">View receipt</button></div>
    </article>
  `;
}

function outputCard(item, mode = "compact") {
  const detail = mode === "full" ? `<p>${item.detail}</p>` : `<p>${item.detail.slice(0, 150)}.</p>`;
  return `
    <article class="output-card ${item.state}">
      <div class="work-head">${stateDot(item.state)}<div><strong>${item.title}</strong><span>${item.id} - ${item.state}</span></div></div>
      ${detail}
      <span class="citation">${item.evidence}</span>
      <span class="receipt mono">${item.receipt}</span>
      ${actionButtons(item.state)}
    </article>
  `;
}

function chatThread(withAction = false) {
  return `
    <div class="chat-thread">
      ${chat.map(([role, text]) => {
        if (role === "agent-action" && !withAction) return "";
        if (role === "agent-action") {
          return `<article class="chat-action">${suggestionCard(suggestions[0], "compact")}</article>`;
        }
        return `<article class="message ${role}"><strong>${role === "user" ? "You" : "Standby"}</strong><p>${text}</p></article>`;
      }).join("")}
    </div>
  `;
}

function askBox(label = "Ask Standby") {
  return `
    <form class="ask-box">
      <label for="ask">${label}</label>
      <textarea id="ask" aria-label="${label}">What is the strongest recommendation we can make before the meeting ends?</textarea>
      <div class="actions"><button class="primary" type="button">Ask</button><button type="button">Attach work state</button></div>
    </form>
  `;
}

function workRail(title = "Agent work") {
  return panel(title, "one column", `
    <div class="scroll">
      <div class="rail-list">
        ${suggestions.map((item) => suggestionCard(item, "compact")).join("")}
        ${work.map((item) => runCard(item)).join("")}
        ${outputs.map((item) => outputCard(item)).join("")}
      </div>
    </div>
  `, "quiet-panel");
}

function focusShell(id, name, body, extra = "") {
  return `<main class="app ${extra}">${topbar(id, name)}${body}</main>`;
}

function renderFocusedConversation() {
  return focusShell("PD01", "Focused Conversation", `
    <div class="layout focused-conversation">
      ${panel("Meeting-aware thread", "suggestions inline", `<div class="scroll">${chatThread(true)}</div>${askBox()}${sourceDrawer()}`, "primary-panel")}
      <aside class="side-pocket">
        ${indicatorDock()}
        ${panel("Next work", "2 pending", `<div class="pocket-list">${suggestionCard(suggestions[1], "compact")}${runCard(work[0])}</div>`, "quiet-panel")}
      </aside>
    </div>
  `);
}

function renderActionStream() {
  return focusShell("PD02", "Action Stream", `
    <div class="layout stream-layout">
      ${panel("Action stream", "suggest, run, output", `
        <div class="scroll">
          <div class="stream-list">
            ${suggestionCard(suggestions[0])}
            ${runCard(work[0])}
            ${outputCard(outputs[0], "full")}
            ${suggestionCard(suggestions[1], "compact")}
          </div>
        </div>
      `, "primary-panel")}
      ${panel("Ask", "meeting-aware", `<div class="compact-chat">${chatThread(false)}</div>${askBox()}${sourceDrawer()}`, "quiet-panel")}
    </div>
  `);
}

function renderCurrentDecision() {
  return focusShell("PD03", "Current Decision", `
    <div class="layout decision-layout">
      ${panel("Suggested action", "approve, edit, dismiss", `<div class="decision-focus">${suggestionCard(suggestions[0])}</div>`, "primary-panel")}
      <aside class="decision-side">
        ${indicatorDock()}
        ${panel("After approval", "visible state", `<div class="pocket-list">${runCard(work[0])}${outputCard(outputs[0])}</div>`, "quiet-panel")}
      </aside>
    </div>
  `);
}

function renderQuietWorkboard() {
  const columns = [
    ["Suggested", suggestions.map((item) => suggestionCard(item, "compact"))],
    ["Running", [runCard(work[0])]],
    ["Done", outputs.map((item) => outputCard(item))],
    ["Failed", [runCard(work[2])]]
  ];
  return focusShell("PD04", "Quiet Workboard", `
    <div class="layout board-layout">
      ${panel("Command", "current focus", `<div class="board-command"><div class="board-summary"><article class="message agent"><strong>Standby</strong><p>Current focus is the recommendation. Workboard lanes are available below when you want to inspect state.</p></article>${indicatorDock()}</div>${askBox()}</div>`, "primary-panel")}
      <section class="board-drawer" aria-label="Work board">
        ${columns.map(([title, cards]) => `<article><header><strong>${title}</strong><span>${cards.length}</span></header><div>${cards.join("")}</div></article>`).join("")}
      </section>
    </div>
  `);
}

function renderOutputReview() {
  return focusShell("PD05", "Output Review", `
    <div class="layout review-layout">
      ${panel("Output to review", "completed agent work", `<div class="review-document">${outputCard(outputs[0], "full")}</div>`, "primary-panel")}
      <aside class="side-pocket">
        ${panel("Use next", "follow-up", `<div class="pocket-list">${suggestionCard(suggestions[1], "compact")}${askBox("Ask about this output")}</div>`, "quiet-panel")}
        ${sourceDrawer("Transcript source")}
      </aside>
    </div>
  `);
}

function renderApprovalChat() {
  return focusShell("PD06", "Approval Chat", `
    <div class="layout approval-chat">
      ${panel("Ask and approve", "proposal in context", `<div class="scroll">${chatThread(true)}</div>${askBox()}${sourceDrawer()}`, "primary-panel")}
      ${panel("Work state", "small surface", `<div class="mini-ledger">${work.map((item) => `<button type="button">${stateDot(item.state)}<strong>${item.title}</strong><span>${item.time}</span></button>`).join("")}</div>`, "quiet-panel")}
    </div>
  `);
}

function renderMinimalRoom() {
  return focusShell("PD07", "Minimal Room", `
    <div class="minimal-layout">
      <section class="minimal-card">
        <div class="minimal-head">
          <strong>Standby</strong>
          ${indicatorDock()}
        </div>
        ${askBox()}
        <div class="single-card">${suggestionCard(suggestions[0], "compact")}</div>
        ${sourceDrawer()}
      </section>
    </div>
  `, "minimal-app");
}

function renderLedgerLens() {
  const rows = [
    [suggestions[0].id, "suggested", suggestions[0].title, suggestions[0].evidence],
    [work[0].id, "running", work[0].title, work[0].time],
    [outputs[0].id, "completed", outputs[0].title, outputs[0].receipt],
    [work[2].id, "failed", work[2].title, work[2].receipt]
  ];
  return focusShell("PD08", "Ledger Lens", `
    <div class="layout ledger-layout">
      ${panel("Selected output", "readable first", `<div class="review-document">${outputCard(outputs[0], "full")}</div>`, "primary-panel")}
      ${panel("Status ledger", "inspect", `<table class="status-ledger"><tbody>${rows.map(([id, state, title, meta]) => `<tr><td>${id}</td><td>${state}</td><td>${title}</td><td>${meta}</td></tr>`).join("")}</tbody></table>${askBox("Ask from ledger")}`, "quiet-panel")}
    </div>
  `);
}

function renderRunningLens() {
  return focusShell("PD09", "Running Lens", `
    <div class="layout running-layout">
      ${panel("Running now", "worker in progress", `<div class="run-focus">${runCard(work[0], "full")}</div>`, "primary-panel")}
      <aside class="side-pocket">
        ${indicatorDock()}
        ${panel("Ready when done", "outputs and follow-up", `<div class="pocket-list">${outputCard(outputs[1])}${suggestionCard(suggestions[1], "compact")}</div>`, "quiet-panel")}
        ${sourceDrawer()}
      </aside>
    </div>
  `);
}

function renderCommandShelf() {
  return focusShell("PD10", "Command Shelf", `
    <div class="shelf-layout">
      <section class="command-surface">
        <div>
          <strong>Ask, approve, or find work</strong>
          <span>Meeting context and agent state are attached.</span>
        </div>
        ${askBox("Command Standby")}
      </section>
      <section class="work-shelf" aria-label="Work shelf">
        <button type="button">${stateDot("suggested")}<strong>${suggestions[0].title}</strong><span>suggested</span></button>
        <button type="button">${stateDot("running")}<strong>${work[0].title}</strong><span>running</span></button>
        <button type="button">${stateDot("completed")}<strong>${outputs[0].title}</strong><span>output</span></button>
        <button type="button">${stateDot("failed")}<strong>${work[2].title}</strong><span>failed</span></button>
      </section>
      ${panel("Selected item", "expanded only when selected", `<div class="selected-shelf">${suggestionCard(suggestions[0])}</div>${sourceDrawer()}`, "primary-panel")}
    </div>
  `);
}

function render() {
  const id = location.hash.replace("#", "") || "PD01";
  const [name, builder] = specs[id] || specs.PD01;
  document.getElementById("mount").innerHTML = builder(name);
}

window.addEventListener("hashchange", render);
render();
