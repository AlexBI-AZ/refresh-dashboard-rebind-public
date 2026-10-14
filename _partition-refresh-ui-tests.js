const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync('index.html', 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1].replace(/\binit\(\);\s*$/, '');
const elements = new Map();
function element(id) {
  if (!elements.has(id)) elements.set(id, {
    value: '', innerHTML: '', textContent: '', disabled: false,
    querySelector: () => null,
    appendChild() {}
  });
  return elements.get(id);
}
let pendingFetch;
let nextInterval = 0;
let nextCheckedTime = 0;
const activeIntervals = new Set();
const context = vm.createContext({
  window: { location: { origin: 'http://localhost' } },
  document: { getElementById: element, createElement: () => ({ innerHTML: '', className: '' }) },
  localStorage: { removeItem() {}, setItem() {} },
  fetch: () => new Promise(resolve => { pendingFetch = resolve; }),
  setInterval: () => { activeIntervals.add(++nextInterval); return nextInterval; },
  clearInterval: id => activeIntervals.delete(id),
  Date: class {
    toLocaleString() { return 'check-' + ++nextCheckedTime; }
    toLocaleTimeString() { return '08:00:00'; }
  },
  console
});
vm.runInContext(script, context);

async function run() {
  const stalePoll = vm.runInContext('pollPartitionRefreshStatus()', context);
  vm.runInContext('newPartitionRefreshProfile()', context);
  assert.match(element('logsPartitionRefresh').innerHTML, /Partition refresh status and history will appear here/);
  assert.match(element('partitionRefreshState').textContent, /No partition refresh request/);
  pendingFetch({ json: async () => ({ requestId: 'old', running: true, status: 'Unknown' }), ok: true });
  await stalePoll;
  assert.match(element('partitionRefreshState').textContent, /No partition refresh request/);
  assert.equal(activeIntervals.size, 0);

  vm.runInContext('partitionRefreshViewSuppressed = false', context);
  const runningPoll = vm.runInContext('pollPartitionRefreshStatus()', context);
  pendingFetch({ json: async () => ({ requestId: 'current', running: true, status: 'Unknown' }), ok: true });
  await runningPoll;
  assert.equal(activeIntervals.size, 1);
  assert.match(element('partitionRefreshState').innerHTML, /Last checked:<\/strong> check-1/);

  const unchangedPoll = vm.runInContext('pollPartitionRefreshStatus()', context);
  pendingFetch({ json: async () => ({ requestId: 'current', running: true, status: 'Unknown' }), ok: true });
  await unchangedPoll;
  assert.match(element('partitionRefreshState').innerHTML, /Last checked:<\/strong> check-2/);

  const failedPoll = vm.runInContext('pollPartitionRefreshStatus()', context);
  pendingFetch({ json: async () => ({ error: 'Service unavailable', state: { requestId: 'current', running: true, status: 'Unknown' } }), ok: false });
  await failedPoll;
  assert.match(element('partitionRefreshState').innerHTML, /Last checked:<\/strong> check-2/);
  assert.match(element('partitionRefreshState').innerHTML, /Status not verified/);

  vm.runInContext('newPartitionRefreshProfile()', context);
  assert.equal(activeIntervals.size, 0);
  assert.equal(vm.runInContext('partitionRefreshLastChecked', context), '');
  assert.doesNotMatch(element('partitionRefreshState').textContent, /Last checked/);
  vm.runInContext('partitionRefreshViewSuppressed = false', context);

  const terminalPoll = vm.runInContext('pollPartitionRefreshStatus()', context);
  pendingFetch({ json: async () => ({ requestId: 'current', running: false, status: 'Failed' }), ok: true });
  await terminalPoll;
  assert.equal(activeIntervals.size, 0);
  assert.match(element('partitionRefreshState').innerHTML, /Failed/);
  assert.match(element('partitionRefreshState').innerHTML, /Last checked:<\/strong> check-3/);

  const unauthenticatedPoll = vm.runInContext('pollPartitionRefreshStatus()', context);
  pendingFetch({ json: async () => ({ authenticationRequired: true, error: 'Authenticate again', state: { requestId: 'current', running: true, status: 'Unknown' } }), ok: false });
  await unauthenticatedPoll;
  assert.match(element('partitionRefreshState').innerHTML, /Last known status/);
  assert.equal(activeIntervals.size, 0);
  console.log('Partition refresh UI tests OK');
}

run().catch(error => { console.error(error); process.exitCode = 1; });
