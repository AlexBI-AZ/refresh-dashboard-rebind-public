// Behaviour tests for the Refresh tab's name pickers in index.html. The page script runs in
// a sandbox with a small fake document and a fake server: nothing reaches Power BI.
// Run: node _name-picker-ui-tests.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync('index.html', 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1].replace(/\binit\(\);\s*$/, '');

const WS_TEST = '00000000-0000-0000-0000-000000000101';
const WS_DEV = '00000000-0000-0000-0000-000000000102';
const MODEL = '00000000-0000-0000-0000-000000000103';
const DF_A = '00000000-0000-0000-0000-000000000104';
const DF_B = '00000000-0000-0000-0000-000000000105';
const DF_DEV = '00000000-0000-0000-0000-000000000106';

// --- fake document -------------------------------------------------------------------------
const elements = new Map();
let activeElement = null;
function element(id) {
  if (!elements.has(id)) {
    const attributes = {};
    const el = {
      id, value: '', innerHTML: '', textContent: '', innerText: '', className: '', hidden: false, checked: false, disabled: false,
      style: {},
      classList: { toggle() {}, add() {}, remove() {} },
      setAttribute(name, value) { attributes[name] = String(value); },
      getAttribute(name) { return attributes[name]; },
      removeAttribute(name) { delete attributes[name]; },
      select() {}, scrollIntoView() {}, focus() { activeElement = el; },
      querySelector: () => null, querySelectorAll: () => [], appendChild() {}
    };
    elements.set(id, el);
  }
  return elements.get(id);
}

// --- fake server -------------------------------------------------------------------------------
const calls = [];
let signedIn = true;
let startBody = null;
const responses = {
  '/api/catalog/workspaces': () => ({ ok: true, workspaces: [{ id: WS_DEV, name: 'Contoso DEV' }, { id: WS_TEST, name: 'Contoso TEST' }] }),
  '/api/catalog/items': () => ({ ok: true, warnings: [],
    reports: [{ id: 'r1', name: 'Sales Dashboard', datasetId: MODEL, datasetWorkspaceId: WS_TEST }],
    semanticModels: [{ id: MODEL, name: 'Sales Dashboard', isRefreshable: true }, { id: '00000000-0000-0000-0000-000000000107', name: 'Live model', isRefreshable: false }],
    dataflows: Array.from({ length: 230 }, (_, i) => ({ id: i === 0 ? DF_A : ('aaaaaaaa-0000-0000-0000-' + String(i).padStart(12, '0')), name: i === 0 ? 'Star Dataflow' : 'Flow ' + i })) }),
  '/api/catalog/upstream': () => ({ ok: true, warnings: [],
    model: { id: MODEL, name: 'Sales Dashboard', workspaceId: WS_TEST, workspaceName: 'Contoso TEST', isRefreshable: true },
    dataflows: [{ id: DF_A, name: 'Star Dataflow', workspaceId: WS_TEST, workspaceName: 'Contoso TEST' }, { id: DF_DEV, name: 'Shared dates', workspaceId: WS_DEV, workspaceName: 'Contoso DEV' }] }),
  '/api/catalog/names': () => ({ ok: true, workspaces: [{ id: WS_TEST, name: 'Contoso TEST' }], dataflows: [{ workspaceId: WS_TEST, id: DF_B, name: 'Dictionaries', workspaceName: 'Contoso TEST' }], semanticModels: [] })
};
const profilesFixture = [
  { name: 'Damaged', WorkspaceId: WS_TEST, DataflowIds: [DF_B], SemanticModels: ['@{WorkspaceId=' + WS_TEST + '; DatasetId=' + MODEL + '}'], NotifyEmails: '' },
  { name: 'Named', WorkspaceId: WS_TEST, WorkspaceName: 'Contoso TEST', DataflowIds: [DF_A],
    Dataflows: [{ WorkspaceId: WS_TEST, DataflowId: DF_A, Name: 'Star Dataflow', WorkspaceName: 'Contoso TEST' }, { WorkspaceId: WS_DEV, DataflowId: DF_DEV, Name: 'Shared dates', WorkspaceName: 'Contoso DEV' }],
    SemanticModels: [{ WorkspaceId: WS_TEST, DatasetId: MODEL, Name: 'Sales Dashboard', WorkspaceName: 'Contoso TEST' }], NotifyEmails: '' }
];
async function fakeFetch(url, options) {
  const path = String(url).replace('http://localhost', '').split('?')[0];
  calls.push((options && options.method || 'GET') + ' ' + path);
  const reply = (status, body) => ({ ok: status < 400, status, json: async () => body });
  if (path === '/api/profiles') return reply(200, JSON.parse(JSON.stringify(profilesFixture)));
  if (path === '/api/refresh/start') { startBody = JSON.parse(options.body); return reply(400, { ok: false, error: 'stopped by the test' }); }
  if (path.startsWith('/api/catalog/')) {
    if (!signedIn) return reply(401, { ok: false, error: 'Sign in first to look up names.' });
    return reply(200, responses[path]());
  }
  return reply(200, { ok: true });
}

const storage = {};
const context = vm.createContext({
  window: { location: { origin: 'http://localhost' } },
  document: { getElementById: element, createElement: () => ({ innerHTML: '', className: '' }), get activeElement() { return activeElement; }, querySelectorAll: () => [], addEventListener() {}, body: { dataset: {} } },
  localStorage: { getItem: k => (k in storage ? storage[k] : null), setItem: (k, v) => { storage[k] = String(v); }, removeItem: k => { delete storage[k]; } },
  fetch: fakeFetch, alert: () => {}, confirm: () => true,
  setTimeout, clearTimeout, setInterval: () => 0, clearInterval: () => {},
  console, Date, Promise, JSON, Math, Object, Array, String, RegExp
});
vm.runInContext(script, context);
const run = code => vm.runInContext(code, context);
const tick = ms => new Promise(resolve => setTimeout(resolve, ms || 0));
let checks = 0;

async function main() {
  // 1. Old profiles: rows saved in the damaged "@{...}" text form are read back.
  await run('loadProfiles()');
  const damaged = run("profiles.find(p => p.name === 'Damaged')");
  assert.equal(typeof damaged.SemanticModels[0], 'object');
  assert.equal(damaged.SemanticModels[0].DatasetId, MODEL);
  assert.equal(damaged._repairedRows, true);
  run("selectProfile('Damaged')");
  assert.equal(run('semanticModels.length'), 1, 'the repaired model row is used');
  assert.match(element('refreshPickerNote').textContent, /old damaged format/);
  await tick(120);
  assert.ok(calls.includes('POST /api/catalog/names'), 'names are looked up for rows without names');
  assert.match(element('dfList').innerHTML, /Dictionaries/, 'a looked-up dataflow name is shown');
  checks++;

  // 2. A profile saved with names: each dataflow keeps its own workspace and name.
  run("selectProfile('Named')");
  assert.deepEqual(JSON.parse(run('JSON.stringify(dataflows.map(d => d.name + "@" + d.workspaceName))')), ['Star Dataflow@Contoso TEST', 'Shared dates@Contoso DEV']);
  assert.equal(element('wsPickerInput').value, 'Contoso TEST', 'the workspace picker shows the name');
  checks++;

  // 3. Start: dataflows in the profile's workspace go as DataflowIds, others with their workspace.
  element('notifyEmails').value = '';
  await run('startRefresh()');
  assert.deepEqual(startBody.DataflowIds, [DF_A]);
  assert.deepEqual(startBody.Dataflows, [{ WorkspaceId: WS_DEV, DataflowId: DF_DEV }]);
  assert.equal(startBody.WorkspaceId, WS_TEST);
  element('modelOnly').checked = true;
  await run('startRefresh()');
  assert.deepEqual(startBody.DataflowIds, []);
  assert.deepEqual(startBody.Dataflows, [], 'Model only sends no dataflows in either form');
  element('modelOnly').checked = false;
  checks++;

  // 4. Saving keeps IDs and names, and DataflowIds for older readers.
  const saved = JSON.parse(run("JSON.stringify(buildRefreshProfile('X', validateNotifyEmails(true), getSemanticModelValidation()))"));
  assert.deepEqual(saved.DataflowIds, [DF_A]);
  assert.equal(saved.Dataflows.length, 2);
  assert.deepEqual(saved.Dataflows[1], { WorkspaceId: WS_DEV, DataflowId: DF_DEV, Name: 'Shared dates', WorkspaceName: 'Contoso DEV' });
  assert.equal(saved.SemanticModels[0].Name, 'Sales Dashboard');
  assert.equal(saved.WorkspaceName, 'Contoso TEST');
  checks++;

  // 5. Picking a report adds its model and the dataflows it reads from, once.
  run("dataflows = []; semanticModels = []; document.getElementById('workspaceId').value = ''");
  run("pickWorkspace({ id: '" + WS_TEST + "', name: 'Contoso TEST' })");
  await run("pickModel({ kind: 'report', workspaceId: '" + WS_TEST + "', datasetId: '" + MODEL + "', label: 'Sales Dashboard' })");
  assert.equal(run('semanticModels.length'), 1);
  assert.equal(run('semanticModels[0].name'), 'Sales Dashboard');
  assert.deepEqual(JSON.parse(run('JSON.stringify(dataflows.map(d => d.name))')), ['Star Dataflow', 'Shared dates']);
  assert.match(element('refreshPickerNote').textContent, /Added Sales Dashboard and the 2 dataflows it reads from/);
  await run("pickModel({ kind: 'model', workspaceId: '" + WS_TEST + "', datasetId: '" + MODEL + "', label: 'Sales Dashboard' })");
  assert.equal(run('dataflows.length'), 2, 'picking the same model again adds nothing');
  assert.match(element('refreshPickerNote').textContent, /2 were already in the list/);
  checks++;

  // 6. The picker: multi-word filter, groups, disabled entries, long lists capped.
  activeElement = element('modelPickerInput');
  await run("pickerOpen('model')");
  let list = element('modelPickerList').innerHTML;
  assert.match(list, /picker-group[^>]*>Reports/);
  assert.match(list, /aria-disabled="true"[^>]*><span class="opt-label">Live model/, 'a model that cannot be refreshed is shown but disabled');
  assert.match(list, /already added/i, 'the model in the list is marked as added');
  element('modelPickerInput').value = 'live';
  run("pickerFilter('model')");
  assert.equal(run("pickerState('model').shown.length"), 1);
  assert.equal(run("pickerState('model').active"), -1, 'a disabled entry is never the active choice');
  activeElement = element('dfPickerInput');
  element('dfPickerInput').value = '';
  await run("pickerOpen('df')");
  list = element('dfPickerList').innerHTML;
  assert.match(list, /Showing 200 of 230/);
  element('dfPickerInput').value = 'flow 22';
  run("pickerFilter('df')");
  // Every word must appear somewhere, so "flow 22" also finds "Flow 122".
  assert.deepEqual(JSON.parse(run("JSON.stringify(pickerState('df').shown.map(i => i.label))")), ['Flow 22', 'Flow 122', 'Flow 220', 'Flow 221', 'Flow 222', 'Flow 223', 'Flow 224', 'Flow 225', 'Flow 226', 'Flow 227', 'Flow 228', 'Flow 229']);
  checks++;

  // 7. Keyboard: Enter picks the active entry, Escape closes and restores the chosen text.
  run("pickerChoose('df', 0)");
  assert.equal(run('dataflows.length'), 3, 'the chosen dataflow is added');
  assert.equal(element('dfPickerInput').value, '', 'the add-picker clears after a pick');
  activeElement = element('wsPickerInput');
  element('wsPickerInput').value = 'something typed';
  const escape = { key: 'Escape', preventDefault() {}, stopPropagation() {} };
  element('wsPickerList').hidden = false;
  run('pickerKey')(escape, 'ws');
  assert.equal(element('wsPickerInput').value, 'Contoso TEST', 'Escape restores the chosen workspace name');
  assert.equal(element('wsPickerList').hidden, true);
  checks++;

  // 8. Signed out: the picker says so instead of failing silently; IDs still work.
  signedIn = false;
  run('catalogWorkspaces = null');
  activeElement = element('wsPickerInput');
  await run("pickerOpen('ws')");
  assert.match(element('wsPickerList').innerHTML, /Sign in first/);
  element('workspaceId').value = WS_TEST;
  element('manualDataflowId').value = DF_B;
  run('addDataflowById()');
  assert.ok(run("dataflows.some(d => d.value === '" + DF_B + "')"), 'a dataflow can still be added by ID');
  element('manualDataflowId').value = 'not-a-guid';
  run('addDataflowById()');
  assert.match(element('manualAddError').textContent, /valid GUID/);
  checks++;

  console.log('Name picker UI tests OK (' + checks + ' checks)');
}

main().catch(error => { console.error(error); process.exit(1); });
