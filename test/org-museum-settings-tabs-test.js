// Run with node test/org-museum-settings-tabs-test.js.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../resources/org-museum-theme.js'), 'utf8');
const start = source.indexOf('  function bindSettingsTabs(menu) {');
const end = source.indexOf('  function bindGlobalAiSettings(menu) {', start);
function fixture(saved, blocked = false) {
  const tabs = ['appearance', 'ai'].map((name, index) => ({
    dataset: { settingsTab: name }, attributes: { 'aria-selected': String(index === 0) },
    classList: { toggle() {} }, listeners: {},
    setAttribute(key, value) { this.attributes[key] = value; },
    getAttribute(key) { return this.attributes[key]; },
    addEventListener(key, fn) { this.listeners[key] = fn; },
    focus() { focused = this; }
  }));
  let focused;
  const panels = ['appearance', 'ai'].map(name => ({ dataset: { settingsPanel: name } }));
  const context = { localStorage: {
    getItem() { if (blocked) throw Error('blocked'); return saved; },
    setItem(_key, value) { if (blocked) throw Error('blocked'); saved = value; }
  }};
  vm.runInNewContext(source.slice(start, end) + '\nthis.bind = bindSettingsTabs;', context);
  context.bind({ querySelectorAll(selector) { return selector === '[data-settings-tab]' ? tabs : panels; } });
  return { tabs, panels, focused: () => focused, saved: () => saved };
}
for (const [saved, blocked, expected] of [['ai', false, 1], ['invalid', false, 0], [null, true, 0]]) {
  const f = fixture(saved, blocked);
  assert.equal(f.tabs[expected].tabIndex, 0);
  assert.equal(f.tabs[1 - expected].tabIndex, -1);
  assert.equal(f.panels[expected].hidden, false);
  assert.equal(f.panels[1 - expected].hidden, true);
  let index = expected;
  for (const [key, next] of [['ArrowRight', 1 - expected], ['Home', 0], ['End', 1], ['ArrowRight', 0], ['ArrowLeft', 1]]) {
    let prevented = false;
    f.tabs[index].listeners.keydown({ key, preventDefault() { prevented = true; } });
    assert(prevented);
    assert.equal(f.focused(), f.tabs[next]);
    assert.equal(f.tabs[next].attributes['aria-selected'], 'true');
    assert.equal(f.tabs[next].tabIndex, 0);
    assert.equal(f.tabs[1 - next].tabIndex, -1);
    assert.equal(f.panels[next].hidden, false);
    if (!blocked) assert.equal(f.saved(), f.tabs[next].dataset.settingsTab);
    index = next;
  }
}
console.log('PASS: settings keyboard navigation, roving focus, saved preference, invalid preference and unavailable storage');
