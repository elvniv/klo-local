const widget = document.querySelector("#klo-widget");
const orb = document.querySelector("#orb");
const close = document.querySelector("#close");
const form = document.querySelector("#prompt-form");
const promptInput = document.querySelector("#prompt");
const events = document.querySelector("#events");
const status = document.querySelector("#status");
const permissionsSummary = document.querySelector("#permissions-summary");
const permissionsButton = document.querySelector("#check-permissions");
const refreshRuns = document.querySelector("#refresh-runs");
const runList = document.querySelector("#run-list");
const traceTitle = document.querySelector("#trace-title");
const traceMeta = document.querySelector("#trace-meta");
const traceEvents = document.querySelector("#trace-events");

orb.addEventListener("click", openWidget);
close.addEventListener("click", closeWidget);
permissionsButton.addEventListener("click", checkPermissions);
refreshRuns.addEventListener("click", loadRuns);
document.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
    event.preventDefault();
    widget.classList.toggle("open");
    if (widget.classList.contains("open")) promptInput.focus();
  }
  if (event.key === "Escape") closeWidget();
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const prompt = promptInput.value.trim();
  if (!prompt) return;
  events.replaceChildren();
  setStatus("starting");

  const response = await fetch("/runs", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ prompt }),
  });
  if (!response.ok) {
    addEvent("Failed to start run.");
    setStatus("failed");
    return;
  }
  const { run_id: runId } = await response.json();
  subscribe(runId);
});

checkPermissions();
loadRuns();

function openWidget() {
  widget.classList.add("open");
  promptInput.focus();
}

function closeWidget() {
  widget.classList.remove("open");
}

function setStatus(value) {
  status.textContent = value;
}

async function checkPermissions() {
  permissionsSummary.textContent = "checking...";
  try {
    const response = await fetch("/permissions/status");
    const data = await response.json();
    const failed = Object.entries(data).filter(([, value]) => !value.ok);
    permissionsSummary.textContent = failed.length
      ? `${failed.length} needed: ${failed.map(([key]) => key).join(", ")}`
      : "ready";
  } catch {
    permissionsSummary.textContent = "sidecar unavailable";
  }
}

function subscribe(runId) {
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const socket = new WebSocket(`${protocol}//${location.host}/ws/runs/${runId}`);
  socket.addEventListener("message", (message) => {
    const event = JSON.parse(message.data);
    renderEvent(event);
  });
  socket.addEventListener("close", () => {
    if (status.textContent === "running") setStatus("closed");
  });
}

function renderEvent(event) {
  const payload = event.payload;
  if (event.type === "status_change") {
    const detail = payload.failure_detail || payload.pause_reason || payload.reason;
    setStatus(detail && payload.status !== "completed" ? `${payload.status} — ${detail}` : payload.status);
  }
  if (event.type === "tool_call") addEvent(`tool: ${payload.name}/${payload.input.action}`);
  if (event.type === "os_context") {
    addEvent(`default browser: ${payload.default_browser.name || payload.default_browser.bundle_id || "unknown"}`);
  }
  if (event.type === "workspace") {
    addEvent(`workspace: dedicated Space ${payload.dedicated_space_enabled ? "on" : "off"}, active ${payload.active_app || "unknown"}`);
  }
  if (event.type === "tool_result") {
    if (payload.screenshot_url) {
      addScreenshotEvent(payload.screenshot_url, payload.geometry);
    } else {
      addEvent(payload.text || "ok");
    }
  }
  if (event.type === "agent_thought") addEvent(payload.text);
  if (event.type === "final_message") addEvent(`final: ${payload.text}`);
}

async function loadRuns() {
  runList.replaceChildren();
  try {
    const response = await fetch("/runs?limit=40");
    const runs = await response.json();
    for (const run of runs) {
      const item = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.innerHTML = `<strong>${escapeHtml(run.status)} · ${formatMs(run.duration_ms)}</strong><span>${escapeHtml(run.prompt)}</span>`;
      button.addEventListener("click", () => loadTrace(run.id));
      item.append(button);
      runList.append(item);
    }
  } catch {
    const item = document.createElement("li");
    item.textContent = "Could not load runs.";
    runList.append(item);
  }
}

async function loadTrace(runId) {
  const response = await fetch(`/runs/${runId}`);
  const data = await response.json();
  const run = data.run;
  traceTitle.textContent = run.prompt;
  traceMeta.textContent = `${run.status} · ${formatMs(run.duration_ms)} · ${run.tool_calls} tools · ${run.screenshots} screenshots`;
  traceEvents.replaceChildren();
  for (const event of data.events) {
    traceEvents.append(renderTraceEvent(event));
  }
}

function renderTraceEvent(event) {
  const item = document.createElement("li");
  const payload = event.payload;
  const title = document.createElement("strong");
  title.textContent = `${event.type} · ${new Date(event.timestamp).toLocaleTimeString()}`;
  item.append(title);

  if (event.type === "tool_result" && payload.screenshot_url) {
    const link = document.createElement("a");
    link.href = payload.screenshot_url;
    link.target = "_blank";
    link.rel = "noreferrer";
    const image = document.createElement("img");
    image.src = payload.screenshot_url;
    image.alt = "Run screenshot";
    link.append(image);
    item.append(link);
  }

  const code = document.createElement("code");
  code.textContent = JSON.stringify(payload, null, 2);
  item.append(code);
  return item;
}

function addEvent(text) {
  const item = document.createElement("li");
  item.textContent = text;
  events.append(item);
  item.scrollIntoView({ block: "nearest" });
}

function formatMs(ms) {
  if (ms == null) return "n/a";
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#039;",
  })[char]);
}

function addScreenshotEvent(url, geometry) {
  const item = document.createElement("li");
  const link = document.createElement("a");
  link.href = url;
  link.target = "_blank";
  link.rel = "noreferrer";
  link.textContent = `screenshot ${geometry.image_width_px}x${geometry.image_height_px}`;
  item.append(link);
  events.append(item);
  item.scrollIntoView({ block: "nearest" });
}
