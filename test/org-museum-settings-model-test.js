// Exercise the shared form's actual request handlers with isolated transports.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../resources/org-museum-theme.js'), 'utf8');
function control(value = '') {
  return { value, dataset: {}, disabled: false, hidden: true, listeners: {},
    addEventListener(key, fn) { this.listeners[key] = fn; },
    replaceChildren() {}, appendChild() {} };
}
const config = control();
config.elements = Object.fromEntries(['provider', 'endpoint', 'model', 'key', 'system'].map(key => [key, control()]));
const load = control(), cancel = control(), models = control(), connection = control(), list = control();
const status = { dataset: {} };
const nodes = { 'form[data-browser-config]': config, '[data-browser-load]': load,
  '[data-browser-cancel-load]': cancel, '[data-browser-models]': models,
  '[data-browser-connection]': connection, '#museum-browser-model-list': list,
  '.museum-settings-status-box': status };
let requests = [], transport;
const context = {
  AbortController, setTimeout, clearTimeout,
  localStorage: { getItem() { return null; }, setItem() {} },
  window: { addEventListener() {} }, document: { createElement() { return {}; } },
  fetch(url, options) { requests.push({ url, options }); return transport(options); }
};
const begin = source.indexOf('  function bindGlobalAiSettings(menu) {');
const end = source.indexOf('  function bindControls() {', begin);
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
  transport = async () => ({ ok: true, json: async () => ({ data: [{ id: 'test-only-model' }] }) });
  await models.listeners.click(event);
  assert.equal(models.disabled, false);
  assert.match(connection.textContent, /1 个模型/);
  config.elements.provider.value = 'ollama';
  config.elements.provider.listeners.change();
  assert.equal(config.elements.endpoint.value, 'http://127.0.0.1:11434');
  assert.equal(config.elements.model.value, '');
  console.log('PASS: shared settings validation, duplicate activation, cancellation, HTTP failure recovery, model listing and provider switch');
})().catch(error => { console.error(error); process.exitCode = 1; });
