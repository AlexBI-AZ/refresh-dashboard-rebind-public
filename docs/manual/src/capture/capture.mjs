// Takes the manual's screenshots with headless Chrome over the DevTools protocol.
// Needs two servers that are already running:
//   real panel: server.ps1 from a throw-away copy, sign-in disabled, on port 8799
//   mock panel: mock-server.mjs (fictional signed-in data) on port 8798
// Usage: node capture.mjs <chrome.exe> <output folder> <scratch folder for the Chrome profile>
// Writes <name>.png (1440x900 CSS pixels at 2x) and badges.json (element boxes in CSS pixels).
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const [chromePath, outDir, scratch] = process.argv.slice(2);
if (!chromePath || !outDir || !scratch) { console.error("Usage: node capture.mjs <chrome.exe> <out> <scratch>"); process.exit(1); }
const REAL = "http://localhost:8799/";
const MOCK = "http://localhost:8798/";
const W = 1440, H = 900, SCALE = 2, DEBUG_PORT = 9333;
fs.mkdirSync(outDir, { recursive: true });
const profileDir = path.join(scratch, "chrome-capture-profile");
fs.rmSync(profileDir, { recursive: true, force: true });

const chrome = spawn(chromePath, ["--headless=new", `--remote-debugging-port=${DEBUG_PORT}`, `--user-data-dir=${profileDir}`,
  "--no-first-run", "--no-default-browser-check", "--hide-scrollbars", "--force-prefers-color-scheme=light", `--window-size=${W},${H}`, "about:blank"],
  { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function connect() {
  for (let i = 0; i < 50; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/list`)).json();
      const page = list.find((t) => t.type === "page");
      if (page) return page.webSocketDebuggerUrl;
    } catch { /* not up yet */ }
    await sleep(200);
  }
  throw new Error("Chrome did not start");
}

const ws = new WebSocket(await connect());
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let nextId = 1;
const pending = new Map();
const dialogs = [];
ws.addEventListener("message", (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) { const { resolve, reject } = pending.get(msg.id); pending.delete(msg.id); msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result); }
  else if (msg.method === "Page.javascriptDialogOpening") { dialogs.push(msg.params.message); send("Page.handleJavaScriptDialog", { accept: false }); }
});
function send(method, params = {}) {
  const id = nextId++;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}
async function js(expression) {
  const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error("JS error: " + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
  return r.result.value;
}
async function waitFor(expression, timeout = 20000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { if (await js(expression)) return; await sleep(150); }
  throw new Error("Timed out waiting for: " + expression);
}
async function open(base, storage) {
  // Set the page's saved state on its own origin first, then load it again with that state.
  await send("Page.navigate", { url: base });
  await waitFor("document.readyState === 'complete'");
  await js(`localStorage.clear(); ${Object.entries(storage || {}).map(([k, v]) => `localStorage.setItem(${JSON.stringify(k)}, ${JSON.stringify(v)});`).join(" ")} true`);
  await send("Page.navigate", { url: base });
  await waitFor("document.readyState === 'complete'");
  await sleep(1200);
}
const badges = {};
async function shot(name, selectors) {
  await sleep(500);
  const boxes = await js(`(function(){ const out = {}; ${JSON.stringify(selectors)}.forEach(function(s){ const el = document.querySelector(s);
    if (!el) { out[s] = null; return; } const r = el.getBoundingClientRect(); out[s] = [r.x, r.y, r.width, r.height]; }); return out; })()`);
  const missing = Object.entries(boxes).filter(([, v]) => !v || !v[2]).map(([k]) => k);
  if (missing.length) console.warn(`${name}: not visible: ${missing.join(", ")}`);
  badges[name] = boxes;
  const img = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
  fs.writeFileSync(path.join(outDir, name + ".png"), Buffer.from(img.data, "base64"));
  console.log("saved", name);
}
const click = (sel) => js(`(function(){ const el = document.querySelector(${JSON.stringify(sel)}); el.click(); return true; })()`);

await send("Page.enable");
await send("Runtime.enable");
await send("Emulation.setFocusEmulationEnabled", { enabled: true });
await send("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: SCALE, mobile: false });

// 01 First launch: real server, nobody signed in, no profiles.
await open(REAL, {});
await waitFor("document.getElementById('authBadge').textContent === 'Not signed in'");
await shot("01-first-launch", [".tab-toggle", "#profileList", "#sidebarActions .primary", ".version-pill", "#pageTitle", "#authBadge", "#statusBadge", ".btn-help", "#btnAuth", ".config-pane", "#btnStart", "#logsRefresh"]);

// 02 Refresh profile loaded, signed in (mock).
await fetch(MOCK + "__mock/state?refresh=idle");
await open(MOCK, { "dashboard-tab": "refresh", "refresh-dashboard-selected": "Sales Overview, nightly" });
await waitFor("document.getElementById('authBadge').textContent.indexOf('Signed in') === 0 && document.querySelectorAll('#dfList .item-row').length === 3");
await shot("02-refresh-profile", [".profile-card.selected", "#profileName", "#wsPickerInput", "#semanticModelList", "#modelPickerInput", "#dfList", "#dfPickerInput", "#modelOnly", "#notifyEmails", "#emailDryRun", "#refreshAdvanced > summary", "#formRefresh .form-footer .btn-save", "#btnStart", "#authBadge"]);

// 02b The same form scrolled to its end: notification, IDs, Save Profile.
await js("document.querySelector('.config-pane').scrollTop = 100000; true");
await shot("02b-refresh-profile-end", ["#modelOnly", "#notifyEmails", "#emailDryRun", "#refreshAdvanced > summary", "#formRefresh .form-footer .btn-save"]);
await js("document.querySelector('.config-pane').scrollTop = 0; true");

// 03 The report and semantic model picker, opened.
await js("document.getElementById('modelPickerInput').focus(); true");
await waitFor("document.querySelectorAll('#modelPickerList .picker-option').length > 3");
await shot("03-model-picker", ["#modelPickerInput", "#modelPickerList .picker-group", "#modelPickerList .picker-option.disabled"]);
await js("document.getElementById('modelPickerInput').blur(); true");

// 04 New profile dialog.
await click("#sidebarActions .primary");
await waitFor("document.getElementById('modalNew').classList.contains('open')");
await shot("04-new-profile", ["#modalName", "#modalNew .btn-start", "#modalNew .btn-row .btn-save"]);
await js("closeModal('modalNew'); true");

// 05 Refresh running, then 06 finished (mock status).
await open(MOCK, { "dashboard-tab": "refresh", "refresh-dashboard-selected": "Sales Overview, nightly" });
await waitFor("!document.getElementById('btnStart').disabled");
await click("#btnStart");
await waitFor("document.querySelectorAll('#logsRefresh .log-entry').length >= 12 && document.getElementById('statusBadge').textContent === 'Running'");
await shot("05-refresh-running", ["#progressRow", "#dotDataflow", "#dotDataset", "#semanticStatusList", "#statusBadge", "#logsRefresh"]);
await fetch(MOCK + "__mock/state?refresh=done");
await waitFor("document.getElementById('statusBadge').textContent === 'Done'");
await shot("06-refresh-done", ["#progressRow", "#semanticStatusList", "#statusBadge", "#logsRefresh .log-entry:last-child"]);

// 07 Partition Refresh (mock): profile, last request status, history in the log.
// Opened on Refresh first: only the Refresh tab runs the sign-in check, so a panel that
// opens straight on Partition shows "Checking sign-in" until Refresh has been visited.
await open(MOCK, { "dashboard-tab": "refresh", "partition-refresh-selected": "Sales history 2025" });
await waitFor("document.getElementById('authBadge').textContent.indexOf('Signed in') === 0");
await click("#pillPartitionRefresh");
await waitFor("document.getElementById('partitionRefreshState').textContent.indexOf('Request ID') >= 0");
await js("Array.from(document.querySelectorAll('#controlsPartitionRefresh button')).find(b => b.textContent.indexOf('Refresh History') >= 0).click(); true");
await waitFor("document.querySelectorAll('#logsPartitionRefresh .log-entry').length >= 4");
await shot("07-partition", ["#pillPartitionRefresh", "#pwsPickerInput", "#pmodelPickerInput", "#partitionTableName", "#partitionNames", "#partitionAdvanced > summary", "#btnStartPartitionRefresh", "#controlsPartitionRefresh .btn-save", "#partitionRefreshState", "#logsPartitionRefresh"]);

// 08 Rebind form (real server, fictional PBIP fixture).
await open(REAL, { "dashboard-tab": "rebind", "rebind-selected": "Sales Overview: DEV to TEST" });
await waitFor("document.getElementById('reportPath').value.length > 0 && !document.getElementById('btnScan').disabled");
await shot("08-rebind-form", ["#pillRebind", "#rebindProfileList .profile-card", "#rebindProfileName", "#reportPath", "#mappingList .mapping-row select", "#mappingList .mapping-row .form-group:nth-child(2) input", "#mappingList .btn-row-swap", "#mappingList .mapping-row .form-group:nth-child(4) input", "#mappingList .btn-row-remove", ".btn-add-mapping", "#formRebind .form-footer .btn-save", "#controlsRebind .pipeline", "#btnScan", "#btnApply"]);

// 09 After Scan: technical log, summary and decision.
await click("#btnScan");
await waitFor("document.getElementById('rebindSummary').classList.contains('visible') && document.getElementById('statusBadge').textContent === 'Scan complete'", 60000);
await shot("09-rebind-scan", ["#controlsRebind .pipeline", "#logsRebind", "#rebindLogResizeHandle", "#rebindSummaryTitle", "#rebindSummaryStats", "#rebindSummaryDetails", "#btnSummaryApply", "#btnSummaryStop", "#btnApply"]);

// 10 After Apply: replaced and verified.
await click("#btnSummaryApply");
await waitFor("document.getElementById('rebindSummaryTitle').textContent.indexOf('Rebind') === 0 && document.getElementById('statusBadge').textContent !== 'Applying...'", 60000);
await shot("10-rebind-apply", ["#controlsRebind .pipeline", "#logsRebind", "#rebindSummaryTitle", "#rebindSummaryStats", "#rebindSummaryDetails", "#btnSummaryReset"]);

fs.writeFileSync(path.join(outDir, "badges.json"), JSON.stringify({ viewport: [W, H], boxes: badges }, null, 2));
if (dialogs.length) console.log("dialogs seen (dismissed):", dialogs);
ws.close();
chrome.kill();
console.log("done");
