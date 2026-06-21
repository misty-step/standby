#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";

const [url, screenshotPath, domPath, reportPath, widthArg, heightArg, mode = "desktop"] =
  process.argv.slice(2);

if (!url || !screenshotPath || !domPath || !reportPath || !widthArg || !heightArg) {
  console.error(
    "usage: capture-ui-state.mjs <url> <screenshot.png> <dom.html> <report.json> <width> <height> [desktop|mobile]",
  );
  process.exit(64);
}

const chrome = resolveChrome();
if (!fs.existsSync(chrome)) {
  console.error(`Chrome not found at ${chrome}`);
  process.exit(65);
}

const width = Number(widthArg);
const height = Number(heightArg);
const port = 44000 + Math.floor(Math.random() * 1000);
const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), "standby-cdp-"));
const chromeProcess = spawn(
  chrome,
  [
    "--headless=new",
    "--disable-gpu",
    "--hide-scrollbars",
    "--no-first-run",
    "--no-default-browser-check",
    `--window-size=${width},${height}`,
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${userDataDir}`,
    "about:blank",
  ],
  { stdio: ["ignore", "pipe", "pipe"] },
);

let stderr = "";
chromeProcess.stderr.on("data", (chunk) => {
  stderr += chunk.toString();
});

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function resolveChrome() {
  if (process.env.CHROME) {
    if (fs.existsSync(process.env.CHROME)) return process.env.CHROME;
    const found = spawnSync("which", [process.env.CHROME], { encoding: "utf8" });
    if (found.status === 0) return found.stdout.trim();
    return process.env.CHROME;
  }
  const candidates = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "google-chrome",
    "chromium",
    "chromium-browser",
  ];
  for (const candidate of candidates) {
    if (candidate.startsWith("/") && fs.existsSync(candidate)) return candidate;
    const found = spawnSync("which", [candidate], { encoding: "utf8" });
    if (found.status === 0) return found.stdout.trim();
  }
  return candidates[0];
}

async function waitForJson(endpoint) {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      const response = await fetch(endpoint);
      if (response.ok) return response.json();
    } catch {
      // Chrome is still starting.
    }
    if (chromeProcess.exitCode !== null) break;
    await delay(100);
  }
  throw new Error(`Chrome CDP endpoint never became ready: ${endpoint}\n${stderr}`);
}

class CdpClient {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
    ws.addEventListener("message", (event) => this.onMessage(event));
  }

  onMessage(event) {
    const message = JSON.parse(event.data);
    if (message.id && this.pending.has(message.id)) {
      const { resolve, reject, timeout } = this.pending.get(message.id);
      this.pending.delete(message.id);
      clearTimeout(timeout);
      if (message.error) reject(new Error(message.error.message));
      else resolve(message.result ?? {});
      return;
    }
    if (message.method) this.events.push(message);
  }

  send(method, params = {}) {
    const id = this.nextId;
    this.nextId += 1;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`CDP timeout: ${method}`));
      }, 10_000);
      this.pending.set(id, { resolve, reject, timeout });
    });
  }

  waitFor(method, timeoutMs = 8_000) {
    return new Promise((resolve, reject) => {
      const started = Date.now();
      const tick = () => {
        const index = this.events.findIndex((event) => event.method === method);
        if (index >= 0) {
          const [event] = this.events.splice(index, 1);
          resolve(event);
          return;
        }
        if (Date.now() - started > timeoutMs) {
          reject(new Error(`Timed out waiting for ${method}`));
          return;
        }
        setTimeout(tick, 50);
      };
      tick();
    });
  }
}

function websocketOpen(ws) {
  return new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", reject, { once: true });
  });
}

function collectIssues(events) {
  const consoleErrors = [];
  const networkErrors = [];
  const pageErrors = [];

  for (const event of events) {
    if (event.method === "Runtime.exceptionThrown") {
      pageErrors.push(event.params?.exceptionDetails?.text ?? "runtime exception");
    }
    if (event.method === "Runtime.consoleAPICalled" && event.params?.type === "error") {
      const args = event.params.args ?? [];
      consoleErrors.push(args.map((arg) => arg.value ?? arg.description ?? "").join(" "));
    }
    if (event.method === "Log.entryAdded" && event.params?.entry?.level === "error") {
      consoleErrors.push(event.params.entry.text);
    }
    if (event.method === "Network.loadingFailed") {
      const url = event.params?.requestId ?? "";
      networkErrors.push(`${url}: ${event.params?.errorText ?? "network failure"}`);
    }
    if (event.method === "Network.responseReceived") {
      const response = event.params?.response;
      const responseUrl = response?.url ?? "";
      if (response && response.status >= 400 && !responseUrl.endsWith("/favicon.ico")) {
        networkErrors.push(`${response.status} ${responseUrl}`);
      }
    }
  }

  if (networkErrors.length === 0) {
    for (let index = consoleErrors.length - 1; index >= 0; index -= 1) {
      if (consoleErrors[index] === "Failed to load resource: the server responded with a status of 404 (Not Found)") {
        consoleErrors.splice(index, 1);
      }
    }
  }

  return { consoleErrors, networkErrors, pageErrors };
}

try {
  await waitForJson(`http://127.0.0.1:${port}/json/version`);
  const targetResponse = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, {
    method: "PUT",
  });
  if (!targetResponse.ok) throw new Error(`create Chrome target failed: ${targetResponse.status}`);
  const target = await targetResponse.json();
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await websocketOpen(ws);
  const cdp = new CdpClient(ws);

  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");
  await cdp.send("Log.enable");
  await cdp.send("Network.enable");
  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: mode === "mobile" ? 2 : 1,
    mobile: mode === "mobile",
  });
  await cdp.send("Page.navigate", { url });
  await cdp.waitFor("Page.loadEventFired");
  await delay(1_500);

  const screenshot = await cdp.send("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: false,
  });
  fs.mkdirSync(path.dirname(screenshotPath), { recursive: true });
  fs.writeFileSync(screenshotPath, Buffer.from(screenshot.data, "base64"));

  const dom = await cdp.send("Runtime.evaluate", {
    expression: "document.documentElement.outerHTML",
    returnByValue: true,
  });
  fs.writeFileSync(domPath, `${(dom.result?.value ?? "").replace(/[ \t]+$/gm, "")}\n`);

  const issues = collectIssues(cdp.events);
  const report = {
    status:
      issues.consoleErrors.length === 0 &&
      issues.networkErrors.length === 0 &&
      issues.pageErrors.length === 0
        ? "pass"
        : "fail",
    url,
    viewport: { width, height, mode },
    screenshot: path.basename(screenshotPath),
    dom: path.basename(domPath),
    ...issues,
  };
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);

  await cdp.send("Browser.close").catch(() => undefined);
  ws.close();
  if (report.status !== "pass") process.exit(2);
} catch (error) {
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(
    reportPath,
    `${JSON.stringify(
      {
        status: "fail",
        url,
        error: error instanceof Error ? error.message : String(error),
        stderr,
      },
      null,
      2,
    )}\n`,
  );
  chromeProcess.kill("SIGKILL");
  process.exit(1);
} finally {
  chromeProcess.kill("SIGTERM");
  try {
    fs.rmSync(userDataDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  } catch {
    // Chrome can release profile files a moment after Browser.close returns.
  }
}
