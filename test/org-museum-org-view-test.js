const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// DOM Mock for testing Org View features
function createMockElement(tagName = "div") {
  let _innerHTML = "";
  const el = {
    tagName: tagName.toUpperCase(),
    className: "",
    get innerHTML() { return _innerHTML; },
    set innerHTML(html) {
      _innerHTML = html;
      el.children = [];
      function parseHTML(str, parent) {
        const tagRegex = /<([a-z0-9-]+)([^>]*)>(.*?)<\/\1>|<([a-z0-9-]+)([^>]*)\/?>/gis;
        let m;
        while ((m = tagRegex.exec(str)) !== null) {
          const tag = m[1] || m[4];
          const attrsStr = m[2] || m[5] || "";
          const inner = m[3] || "";
          const child = createMockElement(tag);
          const classMatch = attrsStr.match(/class=["']([^"']+)["']/i);
          if (classMatch) child.className = classMatch[1];
          child.parentElement = parent;
          parent.children.push(child);
          if (inner && inner.includes("<")) {
            parseHTML(inner, child);
          } else {
            child.textContent = inner;
          }
        }
      }
      parseHTML(html, el);
    },
    textContent: "",
    dataset: {},
    hidden: false,
    attributes: {},
    children: [],
    listeners: {},
    classList: {
      add(c) {
        if (!el.className.split(/\s+/).includes(c)) {
          el.className = (el.className + " " + c).trim();
        }
      },
      remove(c) {
        el.className = el.className.split(/\s+/).filter(x => x && x !== c).join(" ");
      },
      contains(c) {
        return el.className.split(/\s+/).includes(c);
      },
      toggle(c, force) {
        const has = el.classList.contains(c);
        const next = typeof force === "boolean" ? force : !has;
        if (next) el.classList.add(c); else el.classList.remove(c);
        return next;
      }
    },
    setAttribute(k, v) { el.attributes[k] = String(v); },
    getAttribute(k) { return el.attributes[k] || null; },
    appendChild(child) {
      el.children.push(child);
      child.parentElement = el;
      return child;
    },
    insertBefore(newChild, refChild) {
      const idx = el.children.indexOf(refChild);
      if (idx === -1) el.children.unshift(newChild);
      else el.children.splice(idx, 0, newChild);
      newChild.parentElement = el;
      return newChild;
    },
    querySelector(selector) {
      const all = el.querySelectorAll(selector);
      return all[0] || null;
    },
    querySelectorAll(selector) {
      const results = [];
      function recurse(node) {
        for (const child of node.children) {
          if (matches(child, selector)) results.push(child);
          recurse(child);
        }
      }
      recurse(el);
      return results;
    },
    closest(selector) {
      let cur = el;
      while (cur) {
        if (matches(cur, selector)) return cur;
        cur = cur.parentElement;
      }
      return null;
    },
    addEventListener(type, fn) {
      if (!el.listeners[type]) el.listeners[type] = [];
      el.listeners[type].push(fn);
    },
    dispatchEvent(event) {
      const fns = el.listeners[event.type] || [];
      fns.forEach(fn => fn(event));
    },
    scrollIntoView() {},
    getBoundingClientRect() { return { top: 100, bottom: 200 }; }
  };
  return el;
}

function matches(node, selector) {
  if (selector.startsWith(".")) {
    const cls = selector.slice(1);
    return node.classList.contains(cls);
  }
  if (selector.startsWith("#")) {
    return node.id === selector.slice(1);
  }
  if (selector.startsWith("[")) {
    const attr = selector.replace(/[[\]]/g, "");
    return node.attributes[attr] !== undefined;
  }
  return node.tagName === selector.toUpperCase();
}

const mockDocument = {
  createElement(tagName) { return createMockElement(tagName); },
  querySelector() { return null; },
  querySelectorAll() { return []; },
  addEventListener() {}
};

const mockWindow = {
  document: mockDocument,
  navigator: { clipboard: { writeText: async () => {} } },
  orgMuseumMarkdown: {
    render(node, text) { node.innerHTML = "<p>Rendered Markdown</p>"; }
  }
};

const root = path.resolve(__dirname, "..");
const scriptContent = fs.readFileSync(path.join(root, "resources/org-museum-org-view.js"), "utf8");

// Run script in sandbox
vm.runInNewContext(scriptContent, {
  window: mockWindow,
  document: mockDocument,
  navigator: mockWindow.navigator,
  console
});

// Verify org-museum.css contains all critical requirements
const cssContent = fs.readFileSync(path.join(root, "resources/org-museum.css"), "utf8");

// Requirement 1: Article width & wide-screen check
assert.ok(cssContent.includes("--museum-article-max-width, 1320px)"), "CSS must fallback to 1320px");
assert.ok(!cssContent.includes("calc(100vw - 520px)"), "CSS must not clamp wide screens with 520px bottleneck");

// Requirement 2: Org Buffer Components
assert.ok(cssContent.includes(".museum-org-buffer"), "CSS must include .museum-org-buffer");
assert.ok(cssContent.includes(".org-bullet"), "CSS must include .org-bullet");
assert.ok(cssContent.includes(".org-descriptive-link"), "CSS must include .org-descriptive-link");
assert.ok(cssContent.includes(".museum-org-table"), "CSS must include .museum-org-table");
assert.ok(cssContent.includes(".museum-org-preamble-drawer"), "CSS must include .museum-org-preamble-drawer");

// Requirement 3: Code block folding & babel folding
assert.ok(cssContent.includes(".museum-org-block-container.is-folded .museum-org-block-code"),
  "CSS must hide code block when folded");
assert.ok(cssContent.includes(".museum-org-block-container.is-folded .museum-org-block-md-rendered"),
  "CSS must hide rendered babel block when folded");

// Requirement 4: Default automatic line wrapping
assert.ok(cssContent.includes("white-space: pre-wrap !important;"),
  "CSS must enable pre-wrap for auto line wrapping by default");
assert.ok(cssContent.includes("word-break: break-word !important;"),
  "CSS must enable word-break for auto line wrapping");

// Requirement 5: TOC jump target feedback
assert.ok(cssContent.includes(".museum-org-line.is-jump-target"),
  "CSS must have highlight style for TOC jump target");

// Requirement 6: Smaller compact typography for syntax view and babel code
// Requirement 7: Complete Org Mode face classes
assert.ok(cssContent.includes(".org-face-org-todo"), "CSS must include .org-face-org-todo");
assert.ok(cssContent.includes(".org-face-org-done"), "CSS must include .org-face-org-done");
assert.ok(cssContent.includes(".org-face-org-priority"), "CSS must include .org-face-org-priority");
assert.ok(cssContent.includes(".org-face-org-tag"), "CSS must include .org-face-org-tag");
assert.ok(cssContent.includes(".org-face-org-link-bracket"), "CSS must include .org-face-org-link-bracket");
assert.ok(cssContent.includes(".org-face-org-table-pipe"), "CSS must include .org-face-org-table-pipe");
assert.ok(cssContent.includes(".org-face-org-checkbox"), "CSS must include .org-face-org-checkbox");
assert.ok(cssContent.includes(".org-face-org-date"), "CSS must include .org-face-org-date");
assert.ok(cssContent.includes(".org-face-org-drawer"), "CSS must include .org-face-org-drawer");
assert.ok(cssContent.includes(".museum-org-blank-line"), "CSS must include .museum-org-blank-line");

// Requirement 8: Delimiters inside rendered area and scanning/copying enhancements
assert.ok(cssContent.includes(".museum-org-block-delimiter-begin"), "CSS must style begin_src delimiter");
assert.ok(cssContent.includes(".museum-org-block-delimiter-end"), "CSS must style end_src delimiter");
assert.ok(cssContent.includes(".museum-org-block-folded-hint"), "CSS must style folded hint inside code block");
assert.ok(cssContent.includes(".museum-org-btn-copy-section"), "CSS must style section copy button");
assert.ok(cssContent.includes(".museum-org-search-box"), "CSS must include in-buffer search box");
assert.ok(cssContent.includes(".museum-org-source.has-line-numbers"), "CSS must support line numbers gutter");

// Requirement 9: JS module functions & delimiter inclusion
assert.ok(typeof mockWindow.orgMuseumOrgView === "object", "orgMuseumOrgView must be exposed on window");
assert.ok(typeof mockWindow.orgMuseumOrgView.enhanceSyntaxBuffer === "function", "enhanceSyntaxBuffer must be a function");

// Verify createBabelBlockElement outputs begin_src and end_src inside the pre block
const sampleSrcLines = "def hello():\n    return 'world'";
const babelEl = mockWindow.orgMuseumOrgView.createBabelBlockElement("python", sampleSrcLines, "#+begin_src python", "#+end_src");
const preEl = babelEl.querySelector(".museum-org-block-code");
assert.ok(preEl, "Babel container must contain .museum-org-block-code");
const beginDelimiter = babelEl.querySelector(".museum-org-block-delimiter-begin");
assert.ok(beginDelimiter, "Babel pre block must render .museum-org-block-delimiter-begin inside pre");
assert.ok(beginDelimiter.innerHTML.includes("#+begin_src python"), "Begin delimiter must contain #+begin_src python");
const endDelimiter = babelEl.querySelector(".museum-org-block-delimiter-end");
assert.ok(endDelimiter, "Babel pre block must render .museum-org-block-delimiter-end inside pre");
assert.ok(endDelimiter.innerHTML.includes("#+end_src"), "End delimiter must contain #+end_src");

// Verify buttons for copy full and copy inner
const copyFullBtn = babelEl.querySelector(".museum-org-btn-copy-full");
assert.ok(copyFullBtn, "Babel container must have 复制完整块 button");
const copyCodeBtn = babelEl.querySelector(".museum-org-btn-copy-inner");
assert.ok(copyCodeBtn, "Babel container must have 复制代码 button");

// Real regression: generated link attributes were reinterpreted as =verbatim=.
const inlineLink = mockWindow.orgMuseumOrgView.renderOrgSyntaxLine('[[file:ontology-evidence-evolution.org]]');
assert.ok(inlineLink.innerHTML.includes('href="ontology-evidence-evolution.html"'));
assert.ok(!inlineLink.innerHTML.includes('org-face-org-verbatim'), 'Link markup must survive later emphasis passes');
const mixedInline = mockWindow.orgMuseumOrgView.renderOrgSyntaxLine('~a=b~ =x=y= *重点* [[https://example.test/?a=1&b=2][链接]] [X]');
assert.ok(mixedInline.innerHTML.includes('href="https://example.test/?a=1&amp;b=2"'));
assert.ok(mixedInline.innerHTML.includes('org-face-bold'));
assert.ok(!mixedInline.innerHTML.includes('\u0000'), 'Internal tokens must never leak into the page');
const unsafeLink = mockWindow.orgMuseumOrgView.renderOrgSyntaxLine('[[javascript:alert(1)][链接]]');
assert.ok(!unsafeLink.innerHTML.includes('href='), 'Unsupported Org protocols remain readable text');
const oldQueryAll = mockDocument.querySelectorAll;
mockDocument.querySelectorAll = () => [{textContent:'订单分析流水线', closest:()=>null,
  getAttribute:()=> 'org-babel-02-composition-engineering.html#section-canonical'}];
const sectionLink = mockWindow.orgMuseumOrgView.renderOrgSyntaxLine('[[file:org-babel-02-composition-engineering.org::*7. 完整案例][订单分析流水线]]');
assert.ok(sectionLink.innerHTML.includes('href="org-babel-02-composition-engineering.html#section-canonical"'), 'Org section links reuse the real exported anchor');
mockDocument.querySelectorAll = oldQueryAll;
console.log("All Org Museum Org View unit tests passed!");
