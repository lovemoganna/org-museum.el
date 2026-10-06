const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require.resolve('../resources/org-museum-ai.js'), 'utf8');
const start = source.indexOf('    function sourceLink(source) {');
const end = source.indexOf('    function readableTime', start);
assert.ok(start >= 0 && end > start);
const context = {
  pages: [{id:'a', href:'pages/a.html', title:'当前笔记'}],
  pageTitle: id => id,
  document: {createElement: tag => ({tagName:tag})}
};
vm.createContext(context);
vm.runInContext(source.slice(start, end), context);
const known = context.sourceLink({pageId:'a',href:'javascript:alert(1)',title:'历史标题'});
assert.equal(known.tagName,'a');
assert.equal(known.href,'pages/a.html');
assert.equal(known.textContent,'历史标题');
for (const href of ['javascript:alert(1)','data:text/html,unsafe','https://unrelated.invalid/']) {
  const missing = context.sourceLink({pageId:'missing',href,title:'已不存在的来源'});
  assert.equal(missing.tagName,'span');
  assert.equal(missing.href,undefined);
  assert.equal(missing.textContent,'已不存在的来源');
}
console.log('PASS: AI source references use canonical catalog links and missing sources remain text');
