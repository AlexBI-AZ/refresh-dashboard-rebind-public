// Mock backend for the manual's "signed-in" screenshots. It serves the app's own index.html
// and answers the panel's API with fictional data: invented workspaces, reports, models,
// dataflows and example.com addresses. It never calls Power BI and never signs in.
// Usage: node mock-server.mjs <folder with index.html> [port]
// State switch for the capture script: GET /__mock/state?refresh=idle|running|done
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const appDir = process.argv[2];
const port = Number(process.argv[3] || 8798);
if (!appDir || !fs.existsSync(path.join(appDir, "index.html"))) {
  console.error("Usage: node mock-server.mjs <folder with index.html> [port]");
  process.exit(1);
}

const id = (n) => "00000000-0000-0000-0000-" + String(n).padStart(12, "0");
const WS = {
  dev: { id: id(101), name: "Contoso Sales DEV" },
  test: { id: id(102), name: "Contoso Sales TEST" },
  prod: { id: id(103), name: "Contoso Sales PROD" },
  fin: { id: id(104), name: "Fabrikam Finance" },
  ops: { id: id(105), name: "Northwind Operations" },
  shared: { id: id(106), name: "Northwind Shared Dataflows" },
};
const MODELS = {
  [id(201)]: { name: "Sales Overview", ws: WS.test, isRefreshable: true },
  [id(202)]: { name: "Customer Insights", ws: WS.test, isRefreshable: true },
  [id(203)]: { name: "Inventory Health", ws: WS.test, isRefreshable: true },
  [id(204)]: { name: "Sales Live (DirectQuery)", ws: WS.test, isRefreshable: false },
  [id(205)]: { name: "Finance Monthly", ws: WS.fin, isRefreshable: true },
  [id(206)]: { name: "Budget vs Actual", ws: WS.fin, isRefreshable: true },
};
const DATAFLOWS = {
  [id(301)]: { name: "Sales Orders", ws: WS.test },
  [id(302)]: { name: "Customers", ws: WS.test },
  [id(303)]: { name: "Calendar", ws: WS.shared },
  [id(304)]: { name: "Inventory Snapshots", ws: WS.test },
  [id(305)]: { name: "GL Entries", ws: WS.fin },
};
const UPSTREAM = { [id(201)]: [id(301), id(302), id(303)], [id(202)]: [id(302)], [id(203)]: [id(304)], [id(205)]: [id(305)], [id(206)]: [id(305)] };

const dfRef = (dfId) => ({ WorkspaceId: DATAFLOWS[dfId].ws.id, DataflowId: dfId, Name: DATAFLOWS[dfId].name, WorkspaceName: DATAFLOWS[dfId].ws.name });
const modelRef = (mId) => ({ WorkspaceId: MODELS[mId].ws.id, DatasetId: mId, Name: MODELS[mId].name, WorkspaceName: MODELS[mId].ws.name });
let profiles = [
  { name: "Sales Overview, nightly", WorkspaceId: WS.test.id, WorkspaceName: WS.test.name,
    DataflowIds: [id(301), id(302)], Dataflows: [dfRef(id(301)), dfRef(id(302)), dfRef(id(303))],
    SemanticModels: [modelRef(id(201))], NotifyEmails: "sales-team@example.com, bi-support@example.com", EmailDryRun: false },
  { name: "Finance Monthly", WorkspaceId: WS.fin.id, WorkspaceName: WS.fin.name,
    DataflowIds: [id(305)], Dataflows: [dfRef(id(305))],
    SemanticModels: [modelRef(id(205)), modelRef(id(206))], NotifyEmails: "finance-bi@example.com", EmailDryRun: true },
  { name: "Inventory Health (model only)", WorkspaceId: WS.test.id, WorkspaceName: WS.test.name,
    DataflowIds: [], Dataflows: [], SemanticModels: [modelRef(id(203))], NotifyEmails: "", EmailDryRun: false },
];
let partitionProfiles = [
  { name: "Sales history 2025", WorkspaceId: WS.test.id, WorkspaceName: WS.test.name, DatasetId: id(201), DatasetName: "Sales Overview",
    TableName: "Sales", Partitions: ["Sales 2025-01", "Sales 2025-02", "Sales 2025-03"] },
];

let refreshMode = "idle";
const T = (h, m, s) => `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
const runLogs = [
  [T(21, 0, 2), "Starting refresh plan in workspace 'Contoso Sales TEST': 3 dataflow(s), 1 semantic model(s)."],
  [T(21, 0, 2), "Authentication: delegated."],
  [T(21, 0, 9), "Validation of semantic model 'Sales Overview': before-refresh snapshot taken (14 universal checks, 0 could not run)."],
  [T(21, 0, 9), "Starting 3 upstream dataflow refresh(es) in parallel."],
  [T(21, 0, 11), "Dataflow 'Sales Orders' in 'Contoso Sales TEST': running."],
  [T(21, 0, 11), "Dataflow 'Customers' in 'Contoso Sales TEST': running."],
  [T(21, 0, 12), "Dataflow 'Calendar' in 'Northwind Shared Dataflows': running."],
  [T(21, 1, 42), "Dataflow 'Calendar' in 'Northwind Shared Dataflows': succeeded."],
  [T(21, 4, 13), "Dataflow 'Customers' in 'Contoso Sales TEST': succeeded."],
  [T(21, 9, 44), "Dataflow 'Sales Orders' in 'Contoso Sales TEST': succeeded."],
  [T(21, 9, 44), "All upstream dataflows completed successfully; starting semantic model refresh."],
  [T(21, 9, 46), "Semantic model 'Sales Overview' in 'Contoso Sales TEST': running."],
];
const doneLogs = [
  [T(21, 16, 18), "Semantic model 'Sales Overview' in 'Contoso Sales TEST': succeeded."],
  [T(21, 16, 31), "Validation of semantic model 'Sales Overview': after-refresh snapshot taken (14 universal checks, 0 could not run)."],
  [T(21, 16, 31), "Validation of semantic model 'Sales Overview': PASS (14 passed, 0 warned, 0 failed of 14)."],
  [T(21, 16, 33), "Notification email submitted for 2 recipient(s)."],
  [T(21, 16, 33), "SUCCESS: All refreshes completed (3 dataflow(s) + 1 semantic model(s))."],
];
const dfDetails = (status) => [id(301), id(302), id(303)].map((d) => ({ id: d, name: DATAFLOWS[d].name, workspaceId: DATAFLOWS[d].ws.id, workspaceName: DATAFLOWS[d].ws.name, status, error: "" }));
function refreshStatus() {
  const base = { emailStatus: "", emailWarning: "", error: "" };
  if (refreshMode === "running") {
    return { ...base, running: true, result: "Running", logs: runLogs.map(([time, text]) => ({ time, text })),
      dataflowStatus: "Success", datasetStatus: "Running (0/1)", dataflowDetails: dfDetails("Success"),
      semanticModelDetails: [{ id: id(201), name: "Sales Overview", workspaceId: WS.test.id, workspaceName: WS.test.name, status: "Running", error: "" }],
      emailStatus: "Pending" };
  }
  if (refreshMode === "done") {
    return { ...base, running: false, result: "Succeeded", logs: runLogs.concat(doneLogs).map(([time, text]) => ({ time, text })),
      dataflowStatus: "Success", datasetStatus: "Completed", dataflowDetails: dfDetails("Success"),
      semanticModelDetails: [{ id: id(201), name: "Sales Overview", workspaceId: WS.test.id, workspaceName: WS.test.name, status: "Succeeded", error: "" }],
      emailStatus: "Sent" };
  }
  return { ...base, running: false, result: "", logs: [], dataflowStatus: "", datasetStatus: "", dataflowDetails: [], semanticModelDetails: [] };
}

const partitionState = {
  running: false, requestId: id(901), submittedAt: "2026-11-23 10:42:05", workspaceId: WS.test.id, datasetId: id(201), tableName: "Sales",
  status: "Completed", extendedStatus: "Completed", startTime: "2026-11-23T10:42:06Z", endTime: "2026-11-23T10:47:31Z",
  attempts: [{ attemptId: 1, startTime: "2026-11-23T10:42:06Z", endTime: "2026-11-23T10:47:31Z", type: "Data" }],
  objects: ["Sales 2025-01", "Sales 2025-02", "Sales 2025-03"].map((p) => ({ table: "Sales", partition: p, status: "Completed" })),
  messages: [],
};

function json(res, status, body) {
  const buf = Buffer.from(JSON.stringify(body), "utf8");
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Content-Length": buf.length });
  res.end(buf);
}
function readBody(req) {
  return new Promise((resolve) => { let s = ""; req.on("data", (c) => (s += c)); req.on("end", () => { try { resolve(JSON.parse(s || "null")); } catch { resolve(null); } }); });
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${port}`);
  const p = url.pathname;
  const q = url.searchParams;
  if (p === "/") {
    const buf = fs.readFileSync(path.join(appDir, "index.html"));
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return res.end(buf);
  }
  if (p === "/favicon.png" || p === "/favicon.ico") {
    res.writeHead(200, { "Content-Type": "image/png" });
    return res.end(fs.readFileSync(path.join(appDir, "favicon.png")));
  }
  if (p === "/__mock/state") { refreshMode = q.get("refresh") || refreshMode; return json(res, 200, { ok: true, refreshMode }); }
  if (p === "/api/auth/status") return json(res, 200, { authenticated: true, msalAvailable: true, authMode: "delegated", error: "" });
  if (p === "/api/profiles") {
    if (req.method === "POST") { const b = await readBody(req); if (Array.isArray(b)) profiles = b; return json(res, 200, { ok: true }); }
    return json(res, 200, profiles);
  }
  if (p === "/api/partition-refresh-profiles") {
    if (req.method === "POST") { const b = await readBody(req); if (Array.isArray(b)) partitionProfiles = b; return json(res, 200, { ok: true }); }
    return json(res, 200, partitionProfiles);
  }
  if (p === "/api/rebind-profiles") return req.method === "POST" ? json(res, 200, { ok: true }) : json(res, 200, []);
  if (p === "/api/rebind/status") return json(res, 200, { running: false, phase: "idle", logs: [] });
  if (p === "/api/refresh/start") { refreshMode = "running"; return json(res, 200, { ok: true }); }
  if (p === "/api/refresh/status") return json(res, 200, refreshStatus());
  if (p === "/api/partition-refresh/status") return json(res, 200, partitionState);
  if (p === "/api/partition-refresh/history") {
    return json(res, 200, { ok: true, value: [
      { requestId: id(901), status: "Completed", startTime: "2026-11-23T10:42:06Z" },
      { requestId: id(902), status: "Completed", startTime: "2026-11-22T21:16:02Z" },
      { requestId: id(903), status: "Failed", startTime: "2026-11-21T21:15:40Z" },
    ] });
  }
  if (p === "/api/catalog/workspaces") return json(res, 200, { ok: true, workspaces: Object.values(WS).sort((a, b) => a.name.localeCompare(b.name)), loadedAt: "2026-11-23T10:00:00Z" });
  if (p === "/api/catalog/items") {
    const ws = (q.get("workspaceId") || "").toLowerCase();
    const models = Object.entries(MODELS).filter(([, m]) => m.ws.id === ws);
    return json(res, 200, { ok: true,
      reports: models.filter(([, m]) => m.isRefreshable).map(([mid, m]) => ({ id: mid.replace("0000002", "0000004"), name: m.name, datasetId: mid, datasetWorkspaceId: ws })),
      semanticModels: models.map(([mid, m]) => ({ id: mid, name: m.name, isRefreshable: m.isRefreshable })),
      dataflows: Object.entries(DATAFLOWS).filter(([, d]) => d.ws.id === ws).map(([did, d]) => ({ id: did, name: d.name })),
      warnings: [] });
  }
  if (p === "/api/catalog/upstream") {
    const mid = (q.get("datasetId") || "").toLowerCase();
    const m = MODELS[mid];
    if (!m) return json(res, 404, { ok: false, error: "Unknown semantic model" });
    return json(res, 200, { ok: true, model: { id: mid, name: m.name, workspaceId: m.ws.id, workspaceName: m.ws.name, isRefreshable: m.isRefreshable },
      dataflows: (UPSTREAM[mid] || []).map((d) => ({ id: d, name: DATAFLOWS[d].name, workspaceId: DATAFLOWS[d].ws.id, workspaceName: DATAFLOWS[d].ws.name })), warnings: [] });
  }
  if (p === "/api/catalog/names") {
    const b = (await readBody(req)) || {};
    const wsName = (w) => (Object.values(WS).find((x) => x.id === String(w).toLowerCase()) || {}).name || "Unknown workspace";
    return json(res, 200, { ok: true,
      workspaces: (b.workspaceIds || []).map((w) => ({ id: w, name: wsName(w) })),
      dataflows: (b.dataflows || []).map((d) => ({ ...d, name: (DATAFLOWS[d.id] || {}).name || "Unknown dataflow", workspaceName: wsName(d.workspaceId) })),
      semanticModels: (b.semanticModels || []).map((m) => ({ ...m, name: (MODELS[m.id] || {}).name || "Unknown semantic model", workspaceName: wsName(m.workspaceId) })) });
  }
  json(res, 404, { ok: false, error: "Not part of the mock" });
}).listen(port, "127.0.0.1", () => console.log(`Mock Control Panel backend on http://localhost:${port}/`));
