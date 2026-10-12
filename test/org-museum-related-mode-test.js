// Exercise the exported mode transition, including its article return URLs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require('node:path').join(__dirname, '../org-museum.el'), 'utf8');
const transition = source.slice(source.indexOf('function updateMode(nextMode,push){'), source.indexOf('function renderDetail(){'));
const panels = [{scrollTop: 14}, {scrollTop: 27}];
const links = {'related-open-source': {}, 'related-open-target': {}};
const state = {
  document: {
    body: {dataset: {}},
    querySelectorAll: selector => selector === '.related-paper' ? panels : [],
    getElementById: id => links[id]
  },
  window: {}, mode: 'summary', positions: {summary: [0,0], full: [80,90]},
  source: {href: 'source.html'}, target: {href: 'target.html'}, activePane: 'source',
  setActivePane() {}, currentUrl: 'summary', rendered: [],
  setUrl(mode) { state.currentUrl = mode; },
  themed(href) { return href + '?museum-from=related.html%3Fmode%3D' + state.currentUrl; },
  renderPanel(side, page) { state.rendered.push(state.themed(page.href)); }
};
vm.createContext(state);
vm.runInContext(transition, state);
state.updateMode('full', true);
assert.equal(state.currentUrl, 'full');
assert.deepEqual(state.positions.summary, [14,27]);
assert.deepEqual(panels.map(p => p.scrollTop), [80,90]);
for (const href of [...state.rendered, ...Object.values(links).map(a => a.href)]) {
  assert.equal(new URLSearchParams(href.split('?')[1]).get('museum-from'), 'related.html?mode=full');
}
state.updateMode('summary', true);
assert.deepEqual(panels.map(p => p.scrollTop), [14,27]);
assert.match(links['related-open-source'].href, /mode%3Dsummary$/);
console.log('PASS: related reading preserves current mode and both reading positions');
