// Exercise the shared form's actual request handlers with isolated transports.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../resources/org-museum-theme.js'), 'utf8');
function control(value = '') {
  return { value, dataset: {}, disabled: false, hidden: true, listeners: {}, options: [],
    addEventListener(key, fn) { this.listeners[key] = fn; },
    replaceChildren(...items) { this.options = items; },
    appendChild(c) { this.options.push(c); return c; } };
}
const config = control();
const modelSelect = control();
const cycleBtn = control();
config.elements = Object.fromEntries(['provider', 'endpoint', 'model', 'key', 'system'].map(key => [key, control()]));
config.elements.model_select = modelSelect;
const load = control(), cancel = control(), models = control(), connection = control(), list = control();
const status = { dataset: {} };
const nodes = { 'form[data-browser-config]': config, '[data-browser-load]': load,
  '[data-browser-cancel-load]': cancel, '[data-browser-models]': models,
  '[data-browser-connection]': connection, '#museum-browser-model-list': list,
  '[data-browser-model-select]': modelSelect,
  '[data-browser-cycle-model]': cycleBtn,
  '.museum-settings-status-box': status };
let requests = [], transport;
let stored = {};
const context = {
  AbortController, setTimeout, clearTimeout,
  localStorage: {
    getItem(k) { return stored[k] || null; },
    setItem(k, v) { stored[k] = String(v); },
    removeItem(k) { delete stored[k]; }
  },
  window: { addEventListener() {}, dispatchEvent() {} },
  document: { createElement() { return control(); }, addEventListener() {}, dispatchEvent() {} },
  fetch(url, options) { requests.push({ url, options }); return transport(options); },
  CustomEvent: class CustomEvent { constructor(type, init) { this.type = type; this.detail = init && init.detail; } }
};
const begin = source.indexOf('  function bindGlobalAiSettings(menu) {');
const end = source.indexOf('  function bindGlobalSearch() {', begin);
vm.runInNewContext(source.slice(begin, end) + '\nthis.bind = bindGlobalAiSettings;', context);
const menu = { querySelector(selector) { return nodes[selector]; } };
context.bind(menu);
context.bind(menu); // Repeated initialization must not attach another owner.
const event = { preventDefault() {} };
(async () => {
  config.elements.endpoint.value = '';
  await load.listeners.click(event);
  assert.equal(requests.length, 0);
  assert.match(connection.textContent, /服务地址/);
  config.elements.endpoint.value = 'http://127.0.0.1:1234/v1';
  await load.listeners.click(event);
  assert.equal(requests.length, 0);
  assert.match(connection.textContent, /模型/);
  config.elements.model.value = 'test-only-model';
  transport = options => new Promise((_resolve, reject) => options.signal.addEventListener('abort', () => {
    const error = new Error('cancelled'); error.name = 'AbortError'; reject(error);
  }));
  const pending = load.listeners.click(event);
  assert.equal(load.disabled, true);
  assert.equal(cancel.hidden, false);
  await load.listeners.click(event);
  assert.equal(requests.length, 1, 'Repeated activation must not issue duplicate inference');
  cancel.listeners.click();
  await pending;
  assert.equal(load.disabled, false);
  assert.equal(cancel.hidden, true);
  assert.equal(status.dataset.state, 'error');
  assert.match(connection.textContent, /取消/);
  transport = async () => ({ ok: false, status: 503, statusText: 'Unavailable' });
  await load.listeners.click(event);
  assert.equal(load.disabled, false);
  assert.equal(status.dataset.state, 'error');
  assert.match(connection.textContent, /503/);
  
  // Model listing with multiple models
  transport = async () => ({ ok: true, json: async () => ({ data: [{ id: 'model-alpha' }, { id: 'model-beta' }] }) });
  await models.listeners.click(event);
  assert.equal(models.disabled, false);
  assert.match(connection.textContent, /2 个模型/);
  assert.equal(config.elements.model.value, 'model-alpha');
  assert.equal(modelSelect.value, 'model-alpha');

  // Sequential switching via cycle button
  await cycleBtn.listeners.click(event);
  assert.equal(config.elements.model.value, 'model-beta');
  assert.equal(modelSelect.value, 'model-beta');
  assert.match(connection.textContent, /model-beta/);

  // Wrap around cycle back to alpha
  await cycleBtn.listeners.click(event);
  assert.equal(config.elements.model.value, 'model-alpha');
  assert.equal(modelSelect.value, 'model-alpha');

  // Sequential selection via select dropdown change
  modelSelect.value = 'model-beta';
  modelSelect.listeners.change();
  assert.equal(config.elements.model.value, 'model-beta');

  // Sequential selection via select dropdown input
  modelSelect.value = 'model-alpha';
  modelSelect.listeners.input();
  assert.equal(config.elements.model.value, 'model-alpha');

  // Provider switch clears model and cache
  config.elements.provider.value = 'ollama';
  config.elements.provider.listeners.change();
  assert.equal(config.elements.endpoint.value, 'http://127.0.0.1:11434');
  assert.equal(config.elements.model.value, '');
  assert.equal(modelSelect.value, '');
  assert.equal(stored['org-museum-browser-models-list'], undefined);

  console.log('PASS: shared settings validation, duplicate activation, cancellation, HTTP failure recovery, model listing, sequential switching, select syncing and provider switch');
})().catch(error => { console.error(error); process.exitCode = 1; });
