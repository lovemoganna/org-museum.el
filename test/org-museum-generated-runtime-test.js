// Parse the actual scripts emitted by the generator. This catches invalid
// embedded JavaScript even when a copied resources/ file happens to be valid.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const vm = require('node:vm');
const os = require('node:os');
const root = path.resolve(__dirname, '..');
const emacs = process.env.ORG_MUSEUM_TEST_EMACS ||
  (fs.existsSync('C:/v/Emacs/bin/emacs.exe') ? 'C:/v/Emacs/bin/emacs.exe' : 'emacs');
const generators = ['ui-core', 'related-reading', 'timeline', 'shell',
  'reading-state', 'sidebar-search', 'effects', 'toc-relocate'];
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'org-museum-runtime-'));
const output = path.join(temporary, 'scripts.html');
const expression = `(progn (require 'org-museum) (let ((coding-system-for-write 'utf-8-unix)) (with-temp-file ${JSON.stringify(output.replaceAll('\\', '/'))} (dolist (name '(${generators.map(x => 'org-museum--script-' + x).join(' ')})) (insert (funcall name))))))`;
const result = spawnSync(emacs, ['-Q', '--batch', '-L', root, '--eval', expression],
  {cwd: root, encoding: 'utf8', maxBuffer: 10 * 1024 * 1024});
assert.equal(result.status, 0, result.error?.message || result.stderr);
const generated = fs.existsSync(output) ? fs.readFileSync(output, 'utf8') : '';
if (fs.existsSync(output)) fs.unlinkSync(output);
fs.rmdirSync(temporary);
const blocks = [...generated.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)];
assert.equal(blocks.length, generators.length, 'Every generator must emit a script block');
blocks.forEach((block, index) => new vm.Script(block[1], {filename: generators[index] + '.generated.js'}));
module.exports = Object.fromEntries(blocks.map((block, index) => [generators[index], block[1]]));
if (require.main === module) console.log(`PASS: all ${blocks.length} generator-emitted runtimes parse successfully`);
