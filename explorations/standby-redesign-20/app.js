const VARIATIONS = [
  ["PD02", "Action Stream", "Suggested, running, completed, and failed work sit in one readable stream; chat is a compact companion."],
  ["PD01", "Focused Conversation", "Chat and suggested work share one primary thread, with quiet indicators for work, outputs, and source."],
  ["PD03", "Current Decision", "One suggested action owns the screen, while running work and outputs stay as small secondary cues."],
  ["PD04", "Quiet Workboard", "Kanban remains available as a standard form factor, but it opens below a focused command surface."],
  ["PD05", "Output Review", "Completed agent output is the main object, with suggested follow-up and source tucked around it."],
  ["PD06", "Approval Chat", "The assistant proposes work inline in the conversation, then approval creates visible run state."],
  ["PD07", "Minimal Room", "A single meeting-aware prompt and one active card, with subtle tabs for everything else."],
  ["PD08", "Ledger Lens", "A slim status ledger supports inspection without becoming the whole product surface."],
  ["PD09", "Running Lens", "The currently running agent gets the focus while queue, outputs, and transcript remain one tap away."],
  ["PD10", "Command Shelf", "A command input plus a small shelf of work/output chips drives the whole meeting surface."]
];

const frame = document.getElementById("previewFrame");
const list = document.getElementById("variationList");
const title = document.getElementById("variationTitle");
const note = document.getElementById("variationNote");
const pos = document.getElementById("positionLabel");
const readout = document.getElementById("viewportReadout");
const wrap = document.getElementById("frameWrap");
const buttons = Array.from(document.querySelectorAll("[data-size]"));

const storedId = localStorage.getItem("standby-action-stream-variation");
let index = Math.max(0, VARIATIONS.findIndex(([id]) => id === storedId));
if (index < 0) index = 0;

function renderList() {
  list.innerHTML = VARIATIONS.map(([id, name, description], i) => `
    <button class="variation-link ${i === index ? "active" : ""}" type="button" data-id="${id}">
      <strong>${id} - ${name}</strong>
      <span>${description}</span>
    </button>
  `).join("");
  for (const item of list.querySelectorAll(".variation-link")) {
    item.addEventListener("click", () => {
      const id = item.getAttribute("data-id");
      const next = VARIATIONS.findIndex(([candidate]) => candidate === id);
      if (next >= 0) {
        index = next;
        sync();
      }
    });
  }
}

function sync() {
  const [id, name, description] = VARIATIONS[index];
  frame.src = `./frame.html?v=14#${id}`;
  title.textContent = `${id} - ${name}`;
  note.textContent = description;
  pos.textContent = `${index + 1} / ${VARIATIONS.length}`;
  localStorage.setItem("standby-action-stream-variation", id);
  renderList();
}

function next() {
  index = (index + 1) % VARIATIONS.length;
  sync();
}

function setViewport(value) {
  for (const button of buttons) button.classList.toggle("active", button.dataset.size === value);
  if (value === "fit") {
    wrap.classList.remove("fixed");
    readout.textContent = "fit";
    return;
  }
  const [width, height] = value.split("x").map(Number);
  const availableWidth = wrap.clientWidth - 28;
  const availableHeight = wrap.clientHeight - 28;
  const scale = Math.min(1, availableWidth / width, availableHeight / height);
  wrap.style.setProperty("--frame-width", `${width}px`);
  wrap.style.setProperty("--frame-height", `${height}px`);
  wrap.style.setProperty("--frame-scale", String(scale));
  wrap.classList.add("fixed");
  readout.textContent = `${width} x ${height} @ ${Math.round(scale * 100)}%`;
}

document.getElementById("nextButton").addEventListener("click", next);
window.addEventListener("keydown", (event) => {
  if (event.key === "ArrowRight") next();
  if (event.key === "ArrowLeft") {
    index = (index - 1 + VARIATIONS.length) % VARIATIONS.length;
    sync();
  }
});
for (const button of buttons) {
  button.addEventListener("click", () => setViewport(button.dataset.size ?? "fit"));
}
window.addEventListener("resize", () => {
  const active = document.querySelector("[data-size].active");
  setViewport(active?.getAttribute("data-size") ?? "fit");
});

renderList();
sync();
setViewport("fit");
