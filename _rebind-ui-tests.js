// Behaviour tests for the Rebind tab in index.html: legacy and hostile saved profiles,
// rejected saves, cancellation acknowledgement, operation-bound polling and the Apply
// summary. The page script runs in a sandbox with a fake document and a fake server;
// no request leaves this process.
// Run: node _rebind-ui-tests.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync('index.html', 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1].replace(/\binit\(\);\s*$/, '');

const OLD = '00000000-0000-0000-0000-0000000000a1';
const NEW = '00000000-0000-0000-0000-0000000000b1';
const OLD_DF = '00000000-0000-0000-0000-0000000000a2';
const NEW_DF = '00000000-0000-0000-0000-0000000000b2';
const HOSTILE_ID = '1);fetch("/api/rebind/apply",{method:"POST"});//';

// --- fake document -----------------------------------------------------------------------
const created = [];
function makeNode(tag, id) {
  const attributes = {};
  const listeners = {};
  const classes = new Set();
  const node = {
    tagName: String(tag || 'div').toUpperCase(), id: id || '', value: '', textContent: '', innerText: '',
    hidden: false, checked: false, disabled: false, selected: false, type: '', title: '', placeholder: '',
    style: {}, children: [], _innerHTML: '',
    get className() { return Array.from(classes).join(' '); },
    set className(v) { classes.clear(); String(v || '').split(/\s+/).filter(Boolean).forEach(c => classes.add(c)); },
    get innerHTML() { return this._innerHTML; },
    set innerHTML(v) { this._innerHTML = String(v); this.children = []; },
    classList: {
      add: (...c) => c.forEach(x => classes.add(x)),
      remove: (...c) => c.forEach(x => classes.delete(x)),
      toggle: (c, on) => { if (on === undefined ? !classes.has(c) : on) classes.add(c); else classes.delete(c); },
      contains: c => classes.has(c)
    },
    setAttribute(name, value) { attributes[name] = String(value); },
    getAttribute(name) { return attributes[name]; },
    removeAttribute(name) { delete attributes[name]; },
    attributeNames() { return Object.keys(attributes); },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    dispatch(type) { (listeners[type] || []).forEach(fn => fn({ type, target: node })); },
    listenerTypes() { return Object.keys(listeners); },
    appendChild(child) { this.children.push(child); return child; },
    querySelector: () => null, querySelectorAll: () => [], select() {}, scrollIntoView() {}, focus() {},
    setPointerCapture() {}, hasPointerCapture() { return false; }, releasePointerCapture() {},
    getBoundingClientRect() { return { height: 100 }; }
  };
  return node;
}
const elements = new Map();
function element(id) {
  if (!elements.has(id)) elements.set(id, makeNode('div', id));
  return elements.get(id);
}
function walk(node, visit) { visit(node); (node.children || []).forEach(c => walk(c, visit)); }

// --- fake server -----------------------------------------------------------------------------
const calls = [];
let profileGet = null;
let profilePost = null;
let cancelReply = null;
let statusReply = null;
let applyReply = null;
async function fakeFetch(url, options) {
  const path = String(url).replace('http://localhost', '').split('?')[0];
  const method = (options && options.method) || 'GET';
  const body = options && options.body ? JSON.parse(options.body) : null;
  calls.push({ method, path, body });
  const reply = (status, data) => ({ ok: status < 400, status, json: async () => data });
  if (path === '/api/rebind-profiles' && method === 'GET') return profileGet();
  if (path === '/api/rebind-profiles' && method === 'POST') return profilePost(body);
  if (path === '/api/rebind/cancel') return cancelReply(body);
  if (path === '/api/rebind/status') return statusReply();
  if (path === '/api/rebind/apply') return applyReply(body);
  return reply(200, { ok: true });
}
const replyOf = (status, data) => async () => ({ ok: status < 400, status, json: async () => data });

const alerts = [];
const storage = {};
const context = vm.createContext({
  window: { location: { origin: 'http://localhost' } },
  document: {
    getElementById: element,
    createElement: tag => { const n = makeNode(tag); created.push(n); return n; },
    querySelectorAll: () => [], addEventListener() {}, body: { dataset: {} }, activeElement: null
  },
  localStorage: { getItem: k => (k in storage ? storage[k] : null), setItem: (k, v) => { storage[k] = String(v); }, removeItem: k => { delete storage[k]; } },
  fetch: fakeFetch, alert: m => alerts.push(String(m)), confirm: () => true,
  setTimeout, clearTimeout, setInterval: () => 0, clearInterval: () => {},
  console, Date, Promise, JSON, Math, Object, Array, String, RegExp, Number, Set
});
vm.runInContext(script, context);
const run = code => vm.runInContext(code, context);
let checks = 0;

async function main() {
  run("currentTab = 'rebind'");

  // 1. Legacy and hostile saved profiles: rows get fresh internal IDs, no handler text.
  profileGet = replyOf(200, [
    { name: 'Legacy', reportPath: 'C:\\PBIP\\Sales [copy]', mappings: [
      { id: 1730000000000, type: 'Workspace', fromId: OLD, toId: NEW },
      { id: HOSTILE_ID, type: 'dataflow', fromId: '"><img src=x onerror=alert(1)>', toId: NEW_DF }
    ] },
    { name: 'Single row object', reportPath: '', mappings: { id: '<b>', type: 'Bogus', fromId: OLD_DF, toId: '' } },
    { name: 42, mappings: [] },
    'not a profile'
  ]);
  await run('loadRebindProfiles()');
  assert.deepEqual(JSON.parse(run('JSON.stringify(rebindProfiles.map(p => p.name))')), ['Legacy', 'Single row object'], 'invalid entries are dropped');
  assert.equal(run("JSON.stringify(rebindProfiles).includes('id')"), false, 'loaded profiles keep no row IDs');
  run("selectRebindProfile('Legacy')");
  const ids = JSON.parse(run('JSON.stringify(mappings.map(m => m.id))'));
  assert.equal(ids.length, 2);
  ids.forEach(id => assert.equal(typeof id, 'number'));
  assert.notEqual(ids[0], 1730000000000, 'saved numeric IDs are not reused');
  assert.equal(run('mappings[1].type'), 'Dataflow', 'type is matched case-insensitively');
  const list = element('mappingList');
  assert.equal(list.innerHTML, '', 'rows are built as elements, not markup');
  assert.equal(list.children.length, 2);
  let inlineHandlers = 0;
  let textHits = 0;
  walk(list, n => {
    n.attributeNames().forEach(a => { if (/^on/i.test(a)) inlineHandlers++; });
    if (n._innerHTML) textHits++;
  });
  assert.equal(inlineHandlers, 0, 'no inline event handler attributes');
  assert.equal(textHits, 0, 'no row element uses innerHTML');
  const inputs = [];
  walk(list.children[1], n => { if (n.tagName === 'INPUT') inputs.push(n); });
  assert.equal(inputs[0].value, '"><img src=x onerror=alert(1)>', 'a hostile value is only a field value');
  inputs[0].value = OLD_DF;
  inputs[0].dispatch('input');
  assert.equal(run('mappings[1].fromId'), OLD_DF, 'the listener updates its own row');
  assert.equal(run('mappings[0].fromId'), OLD, 'other rows are unchanged');
  run("selectRebindProfile('Single row object')");
  assert.equal(run('mappings.length'), 1, 'a single row saved as an object is read');
  assert.equal(run('mappings[0].type'), 'Workspace', 'an unknown type falls back to Workspace');
  storage['rebind-mappings'] = JSON.stringify([{ id: HOSTILE_ID, type: 'Dataset', fromId: OLD, toId: NEW }]);
  run("mappings = normalizeMappingRows(JSON.parse(localStorage.getItem('rebind-mappings')))");
  assert.equal(typeof run('mappings[0].id'), 'number', 'rows restored from browser storage also get new IDs');
  run('persistMappings()');
  assert.equal(storage['rebind-mappings'].includes('"id"'), false, 'browser storage keeps no row IDs');
  checks++;

  // 2. A rejected save keeps the previous list; the request carries no row IDs.
  run("selectRebindProfile('Legacy')");
  element('rebindProfileName').value = 'Legacy';
  element('reportPath').value = 'C:\\PBIP\\Changed';
  profilePost = replyOf(400, { ok: false, error: 'Profiles were not saved: Profile 1 has an unsupported field' });
  const before = run('JSON.stringify(rebindProfiles)');
  await run('saveRebindProfile()');
  const post = calls.filter(c => c.method === 'POST' && c.path === '/api/rebind-profiles').pop();
  assert.ok(post, 'the save was sent');
  assert.equal(JSON.stringify(post.body).includes('"id"'), false, 'the save request carries no row IDs');
  assert.equal(run('JSON.stringify(rebindProfiles)'), before, 'a rejected save keeps the previous list in the page');
  assert.match(alerts.pop(), /unsupported field/, 'the server error is shown');
  profilePost = async () => { throw new Error('connection reset'); };
  await run('saveRebindProfile()');
  assert.equal(run('JSON.stringify(rebindProfiles)'), before, 'an interrupted save keeps the previous list');
  assert.match(alerts.pop(), /connection reset/);
  profilePost = replyOf(200, { ok: true, count: 2 });
  await run('saveRebindProfile()');
  assert.equal(run("rebindProfiles.find(p => p.name === 'Legacy').reportPath"), 'C:\\PBIP\\Changed', 'a confirmed save updates the list');
  element('rebindProfileName').value = 'Draft only';
  element('reportPath').value = '';
  run("mappings = [newMappingRow('Workspace', 'not-a-guid-yet', '')]");
  const postsBefore = calls.filter(c => c.method === 'POST').length;
  await run('saveRebindProfile()');
  const draftPost = calls.filter(c => c.method === 'POST').pop();
  assert.equal(calls.filter(c => c.method === 'POST').length, postsBefore + 1, 'an unfinished mapping can still be saved as a draft');
  assert.equal(draftPost.body.find(p => p.name === 'Draft only').mappings[0].fromId, 'not-a-guid-yet');
  checks++;

  // 3. A profile file the server cannot read disables saving instead of overwriting it.
  profileGet = replyOf(500, { ok: false, error: 'rebind-profiles.json could not be read' });
  await run('loadRebindProfiles()');
  assert.match(element('rebindProfileList').innerHTML, /could not be read/);
  const postsNow = calls.filter(c => c.method === 'POST' && c.path === '/api/rebind-profiles').length;
  await run('saveRebindProfile()');
  await run('deleteRebindProfile()');
  assert.equal(calls.filter(c => c.method === 'POST' && c.path === '/api/rebind-profiles').length, postsNow, 'nothing is posted while the saved file is unreadable');
  checks++;

  // 4. Cancellation is reported as successful only when the server confirms it.
  const decline = async reply => {
    cancelReply = reply;
    run("scanOperationId = 'scan-1'; scanComplete = true; rebindBusy = false");
    await run('declineRebind()');
    return calls.filter(c => c.path === '/api/rebind/cancel').pop();
  };
  let sent = await decline(replyOf(409, { ok: false, invalidated: false, error: 'A rebind operation is still running' }));
  assert.equal(sent.body.OperationId, 'scan-1', 'cancel names the reviewed Scan');
  assert.equal(element('rebindSummaryTitle').textContent, 'Stop was not confirmed');
  assert.match(element('rebindSummaryMessage').textContent, /still running/);
  assert.equal(element('btnApply').disabled, true, 'Apply stays disabled after a failed cancel');
  assert.equal(run('scanOperationId'), '', 'the page drops the reviewed Scan ID');
  await decline(async () => { throw new Error('server offline'); });
  assert.equal(element('rebindSummaryTitle').textContent, 'Stop was not confirmed', 'a network error is not a successful stop');
  await decline(replyOf(200, { ok: true }));
  assert.equal(element('rebindSummaryTitle').textContent, 'Stop was not confirmed', 'ok without invalidated is not a successful stop');
  await decline(replyOf(200, { ok: true, invalidated: true }));
  assert.equal(element('rebindSummaryTitle').textContent, 'Stopped - nothing was changed');
  checks++;

  // 5. Editing after a Scan withdraws the decision on the server too.
  cancelReply = replyOf(200, { ok: true, invalidated: true });
  run("scanOperationId = 'scan-2'; scanComplete = true; rebindBusy = false");
  run("onPathChange()");
  assert.equal(calls.filter(c => c.path === '/api/rebind/cancel').pop().body.OperationId, 'scan-2');
  assert.equal(run('scanComplete'), false);
  checks++;

  // 6. Polling follows only the operation this page started.
  run("rebindOperationId = 'op-A'; rebindBusy = true; scanComplete = false");
  statusReply = replyOf(200, { operationId: 'op-B', phase: 'scanning', running: true, logs: [] });
  await run("pollRebindStatus('scan')");
  assert.equal(run('rebindBusy'), true, 'a running foreign operation does not end this one');
  statusReply = replyOf(503, { ok: false, phase: 'unknown' });
  await run("pollRebindStatus('scan')");
  assert.equal(run('rebindBusy'), true, 'an unreadable status is not treated as a result');
  statusReply = replyOf(200, { operationId: 'op-B', phase: 'scan_done', running: false, logs: [], scanResults: { mappings: [{ totalOccurrences: 3 }] } });
  await run("pollRebindStatus('scan')");
  assert.equal(element('rebindSummaryTitle').textContent, 'Another Rebind operation replaced this one');
  assert.equal(run('scanComplete'), false, "a foreign Scan's results never enable Apply");
  run("rebindOperationId = 'op-C'; rebindBusy = true");
  statusReply = replyOf(200, { operationId: 'op-C', phase: 'scan_done', running: false, logs: [], scanResults: { mappings: [{ totalOccurrences: 3 }], unreadableFiles: [{ file: 'x.json', reason: 'Unsupported text encoding' }] } });
  await run("pollRebindStatus('scan')");
  assert.equal(run('scanComplete'), false, 'a Scan that could not inspect every file does not enable Apply');
  assert.equal(element('btnSummaryApply').style.display, 'none');
  assert.match(element('rebindSummaryDetails').textContent, /could not be inspected/);
  run("rebindOperationId = 'op-D'; rebindBusy = true");
  statusReply = replyOf(200, { operationId: 'op-D', phase: 'scan_done', running: false, logs: [], scanResults: { mappings: [{ totalOccurrences: 3 }], manifest: [{ file: 'a.json' }] } });
  await run("pollRebindStatus('scan')");
  assert.equal(run('scanOperationId'), 'op-D', 'the reviewed Scan ID is kept for Apply');
  checks++;

  // 7. Apply names the reviewed Scan, and its summary reports partial changes honestly.
  run("mappings = [newMappingRow('Workspace', '" + OLD + "', '" + NEW + "')]");
  element('reportPath').value = 'C:\\PBIP\\Sales [copy]';
  applyReply = replyOf(200, { ok: true, operationId: 'op-E' });
  await run('startApply()');
  const applyCall = calls.filter(c => c.path === '/api/rebind/apply').pop();
  assert.equal(applyCall.body.ScanOperationId, 'op-D');
  assert.equal(run('rebindOperationId'), 'op-E');
  run(`showApplySummary(${JSON.stringify({
    ok: false, partial: true, filesChanged: ['Model\\a.tmdl'], totalReplacements: 2, mappings: [{}],
    problems: [{ file: 'Report\\b.json', reason: 'Write failed: Access to the path is denied.' }],
    verification: { ok: false, reviewedFiles: 3, oldGuidsRemaining: { [OLD]: [{ file: 'Report\\b.json', line: 3 }, { file: 'Report\\b.json', line: 7 }] }, problems: [] }
  })}, false, 'Rebind did not complete')`);
  assert.match(element('rebindSummary').className, /failed/);
  const details = element('rebindSummaryDetails').textContent;
  assert.match(details, /Partial change: 1 file\(s\)/);
  assert.match(details, /Write failed/);
  assert.match(details, /line 3/);
  assert.match(details, /line 7/);
  run(`showApplySummary(${JSON.stringify({ ok: true, filesChanged: ['a'], totalReplacements: 1, mappings: [{}], verification: { ok: false, oldGuidsRemaining: {}, problems: [] } })}, true)`);
  assert.match(element('rebindSummary').className, /failed/, 'a done phase without a passed verification is not shown as success');
  checks++;
}

main().then(() => {
  console.log('Rebind UI tests OK (' + checks + ' checks)');
}).catch(error => {
  console.error(error);
  process.exit(1);
});
