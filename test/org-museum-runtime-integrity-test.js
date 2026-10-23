// Validate the scripts users actually receive, rather than only source snippets.
// Usage: node test/org-museum-runtime-integrity-test.js <export-root>
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(process.argv[2] || 'dist');
const scripts = new Set();
let pages = 0, inline = 0;
function visit(directory) {
  for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) visit(file);
    else if (entry.name.endsWith('.html')) {
      pages++;
      const html = fs.readFileSync(file, 'utf8');
      for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)) {
        const attrs = match[1];
        if (/\btype\s*=\s*["']application\/(?:ld\+)?json["']/i.test(attrs)) continue;
        const src = attrs.match(/\bsrc\s*=\s*["']([^"']+)["']/i);
        if (src) {
          const url = new URL(src[1].replace(/&amp;/g, '&'), 'https://museum.test/' + path.relative(root, file).replaceAll('\\', '/'));
          if (url.origin !== 'https://museum.test') continue;
          const target = path.resolve(root, '.' + decodeURIComponent(url.pathname));
          assert(fs.existsSync(target), `Missing runtime: ${src[1]} in ${file}`);
          scripts.add(target);
        } else if (match[2].trim()) {
          new vm.Script(match[2], {filename: `${file}:inline-${++inline}`});
        }
      }
    }
  }
}
visit(root);
assert(pages > 0, 'No exported HTML found');
for (const file of scripts) new vm.Script(fs.readFileSync(file, 'utf8'), {filename: file});
console.log(`PASS: ${pages} exported HTML pages, ${scripts.size} referenced scripts and ${inline} inline scripts parse successfully`);
