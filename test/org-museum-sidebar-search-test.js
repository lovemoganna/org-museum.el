// Run the actual exported filter against empty, long and markup-like queries.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require('node:path').join(__dirname, '../org-museum.el'), 'utf8');
const section = source.slice(source.indexOf('(defun org-museum--script-sidebar-search ()'));
const script = section.slice(section.indexOf('(function(){'), section.indexOf('</script>'));
const input = {addEventListener(type, fn) { this[type] = fn; }};
const empty = {hidden: true};
const links = ['DuckDB Tutorial', 'Org & <Notes>'].map(textContent => ({
  textContent, dataset: {}, parentElement: {style: {}},
  replaceChildren(...children) { this.children = children; }
}));
const category = {style: {}, querySelectorAll: () => links};
vm.runInNewContext(script, {document: {
  readyState: 'complete', getElementById: () => input,
  querySelector: () => empty, querySelectorAll: () => [category],
  createElement: () => ({}), createTextNode: text => ({textContent: text})
}});
function search(value) { input.value = value; input.input.call(input); }
search('missing');
assert.equal(empty.hidden, false);
assert.equal(category.style.display, 'none');
search('DUCKdb');
assert.equal(empty.hidden, true);
assert.equal(links[0].parentElement.style.display, '');
assert.equal(links[1].parentElement.style.display, 'none');
search('<Notes>');
assert.equal(links[1].children[1].textContent, '<Notes>');
search('x'.repeat(100000));
assert.equal(empty.hidden, false);
search('   ');
assert.equal(empty.hidden, true);
assert.equal(category.style.display, '');
assert.ok(links.every(link => link.parentElement.style.display === ''));
assert.equal(links[1].textContent, 'Org & <Notes>');
assert.match(source, /data-sidebar-search-empty role=\\"status\\" hidden/);
console.log('PASS: sidebar empty feedback, case folding, safe highlighting, long query and reset');
