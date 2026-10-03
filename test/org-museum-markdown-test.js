const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const markdownit = require(path.join(root, "resources/vendor/markdown-it.umd.min.js"));
const window = { markdownit };
const document = {
  createElement() { return { className: "", textContent: "" }; },
  querySelectorAll() { return []; }
};
vm.runInNewContext(fs.readFileSync(path.join(root, "resources/org-museum-markdown.js"), "utf8"),
  { window, document });

function element() {
  return {
    classList: { add() {} },
    setAttribute() {},
    appendChild(child) { this.progress = child.textContent; }
  };
}

const source = "# 中文标题\n\n- **重点**\n- 第二项\n\n" +
  "| 字段 | 说明 |\n| --- | --- |\n| `id` | 编号 |\n\n" +
  "> 引用\n\n```sql\nSELECT 1;\n```\n\n[文档](https://example.org)";
const node = element();
window.orgMuseumMarkdown.render(node, source);
for (const tag of ["<h3>", "<ul>", "<strong>", "<table>", "<blockquote>",
  "<pre>", "<a href=\"https://example.org\""]) {
  assert.ok(node.innerHTML.includes(tag), `missing ${tag}`);
}
assert.ok(node.innerHTML.includes("SELECT 1;"));

const unsafe = element();
window.orgMuseumMarkdown.render(unsafe, "<script>alert(1)</script> [坏链接](javascript:alert(1))");
assert.ok(!unsafe.innerHTML.includes("<script>"));
assert.ok(!unsafe.innerHTML.includes("href=\"javascript:"));

const streaming = element();
window.orgMuseumMarkdown.render(streaming, "# 标题\n\n- 已完成\n\n**未完成", true);
assert.ok(streaming.innerHTML.includes("<h3>标题</h3>"));
assert.ok(!streaming.innerHTML.includes("**未完成"));
assert.equal(streaming.progress, "正在生成…");

console.log("Org Museum Markdown rendering passed");
