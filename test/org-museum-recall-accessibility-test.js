// Run the actual shared recall handlers with a small DOM fixture.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const code = fs.readFileSync(path.join(__dirname, '../resources/org-museum-theme.js'), 'utf8');
const start = code.indexOf('  var recallTargets =');
assert(start >= 0, 'Recall controls must have reversible DOM state');
const script = code.slice(start, code.indexOf('  function bindControls()', start));
const notice = code.slice(code.indexOf('  function syncActiveRecallNotice()'), code.indexOf('  window.syncActiveRecallNotice ='));
function target(textContent, excluded = false) {
  const attributes = new Map([['role', 'note'], ['tabindex', '-1'], ['aria-label', 'Author label']]);
  const classes = new Set();
  const el = {
    textContent, attributes, parentElement: {closest: () => null},
    getAttribute: name => attributes.get(name) ?? null,
    setAttribute: (name, value) => attributes.set(name, String(value)),
    removeAttribute: name => attributes.delete(name),
    closest: selector => selector === '[data-museum-recall]' ?
      (attributes.has('data-museum-recall') ? el : null) : (excluded ? {} : null),
    classList: {
      contains: name => classes.has(name),
      toggle(name, force) {
        const on = force ?? !classes.has(name);
        if (on) classes.add(name); else classes.delete(name);
        return on;
      }
    }
  };
  return el;
}
const concept = target('Identity');
const linkLabel = target('Linked concept', true);
let nodes = [concept, linkLabel], observeCallback;
const listeners = {};
const main = {};
const document = {
  body: {}, documentElement: {dataset: {activeRecall: 'true'}},
  addEventListener(type, fn) { listeners[type] = fn; },
  getElementById: id => id === 'main-content' ? main : null,
  querySelectorAll: () => nodes,
  querySelector: () => null
};
const context = vm.createContext({document,
  localStorage: {getItem: () => '{}', setItem() {}},
  MutationObserver: class {constructor(fn) { observeCallback = fn; } observe(root, options) {
    assert.equal(root, main); assert.equal(options.attributes, undefined);
  }}
});
vm.runInContext(script + notice + '\ninitActiveRecall();', context);
assert.equal(concept.getAttribute('role'), 'button');
assert.equal(concept.getAttribute('tabindex'), '0');
assert.equal(concept.getAttribute('aria-label'), '显示重点内容');
assert.equal(concept.getAttribute('aria-pressed'), 'false');
assert.equal(linkLabel.getAttribute('role'), 'note', 'Existing links and controls must stay untouched');
function key(key, extra = {}) {
  let prevented = false;
  listeners.keydown({type: 'keydown', key, target: concept, ...extra, preventDefault() { prevented = true; }});
  return prevented;
}
assert.equal(key('Enter'), true);
assert.equal(concept.getAttribute('aria-pressed'), 'true');
assert.equal(concept.getAttribute('aria-label'), '隐藏重点内容：Identity');
assert.equal(key('Enter', {repeat: true}), false);
assert.equal(concept.getAttribute('aria-pressed'), 'true');
assert.equal(key(' '), true, 'Space reveals/conceals without scrolling the document');
assert.equal(concept.getAttribute('aria-pressed'), 'false');
listeners.click({type: 'click', target: concept});
assert.equal(concept.getAttribute('aria-pressed'), 'true', 'Mouse activation remains available');
const later = target('Newly loaded related content');
nodes.push(later);
observeCallback([{addedNodes: [later], removedNodes: []}]);
assert.equal(later.getAttribute('tabindex'), '0');
nodes = [later, linkLabel];
observeCallback([{addedNodes: [], removedNodes: [concept]}]);
assert.equal(concept.getAttribute('role'), 'note', 'Detached content releases its temporary controls');
document.documentElement.dataset.activeRecall = 'false';
vm.runInContext('syncActiveRecallTargets();', context);
for (const el of [concept, later]) {
  assert.equal(el.getAttribute('role'), 'note');
  assert.equal(el.getAttribute('tabindex'), '-1');
  assert.equal(el.getAttribute('aria-label'), 'Author label');
  assert.equal(el.getAttribute('aria-pressed'), null);
  assert.equal(el.getAttribute('data-museum-recall'), null);
  assert.equal(el.classList.contains('is-revealed'), false);
}
console.log('PASS: keyboard, pointer, hidden/revealed labels, dynamic content and original attribute restoration');
