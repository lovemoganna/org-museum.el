const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// DOM mock helper
function createMockElement(tagName = "div") {
  const el = {
    tagName: tagName.toUpperCase(),
    className: "",
    innerHTML: "",
    _textContent: undefined,
    get textContent() {
      if (this._textContent !== undefined) return this._textContent;
      if (this.children.length === 0) return "";
      return this.children.map(c => c.textContent).join("");
    },
    set textContent(v) {
      this._textContent = v;
      this.children = [];
    },
    value: "",
    disabled: false,
    hidden: false,
    type: "button",
    inert: false,
    style: {},
    dataset: {},
    attributes: {},
    children: [],
    get options() { return this.children; },
    listeners: {},
    parentElement: null,
    scrollHeight: 44,
    scrollTop: 0,
    classList: {
      add(...classes) {
        classes.forEach(c => {
          if (!el.className.split(/\s+/).includes(c)) {
            el.className = (el.className + " " + c).trim();
          }
        });
      },
      remove(...classes) {
        el.className = el.className.split(/\s+/).filter(x => x && !classes.includes(x)).join(" ");
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
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(el.attributes, k) ? el.attributes[k] : null; },
    removeAttribute(k) { delete el.attributes[k]; },
    appendChild(child) {
      el.children.push(child);
      child.parentElement = el;
      return child;
    },
    append(...children) {
      children.forEach(c => el.appendChild(c));
    },
    replaceChildren(...newChildren) {
      el.children = [];
      el._textContent = undefined;
      newChildren.forEach(c => el.appendChild(c));
      el.innerHTML = "";
    },
    focus() { el.isFocused = true; },
    click() { el.dispatchEvent({ type: "click" }); },
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
    }
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
    const raw = selector.slice(1, -1);
    const eqIdx = raw.indexOf("=");
    if (eqIdx !== -1) {
      const attr = raw.slice(0, eqIdx);
      const val = raw.slice(eqIdx + 1).replace(/^["']|["']$/g, "");
      return node.getAttribute(attr) === val;
    }
    return node.getAttribute(raw) !== null;
  }
  return node.tagName === selector.toUpperCase();
}

console.log("--- TEST 1: CSS Contract for Right Sidebar Copilot ---");
const root = path.resolve(__dirname, "..");
const cssContent = fs.readFileSync(path.join(root, "resources/org-museum.css"), "utf8");

assert.ok(cssContent.includes(".museum-ai-sidebar"), "CSS must contain .museum-ai-sidebar");
assert.ok(cssContent.includes(".museum-ai-copilot-header"), "CSS must contain .museum-ai-copilot-header");
assert.ok(cssContent.includes(".museum-ai-copilot-model-bar"), "CSS must contain .museum-ai-copilot-model-bar");
assert.ok(cssContent.includes(".museum-ai-copilot-model-config"), "CSS must contain .museum-ai-copilot-model-config");
assert.ok(cssContent.includes(".museum-ai-copilot-context"), "CSS must contain .museum-ai-copilot-context");
assert.ok(cssContent.includes(".museum-ai-copilot-chat"), "CSS must contain .museum-ai-copilot-chat");
assert.ok(cssContent.includes(".museum-ai-copilot-messages"), "CSS must contain .museum-ai-copilot-messages");
assert.ok(cssContent.includes(".museum-ai-message"), "CSS must contain .museum-ai-message");
assert.ok(cssContent.includes(".museum-ai-message-bubble"), "CSS must contain .museum-ai-message-bubble");
assert.ok(cssContent.includes(".museum-ai-explore-prompts"), "CSS must contain .museum-ai-explore-prompts");
assert.ok(cssContent.includes(".museum-ai-chip"), "CSS must contain .museum-ai-chip");
assert.ok(cssContent.includes(".museum-ai-copilot-composer"), "CSS must contain .museum-ai-copilot-composer");
assert.ok(cssContent.includes(".museum-ai-send-btn"), "CSS must contain .museum-ai-send-btn");
assert.ok(cssContent.includes(".museum-ai-drawer-chevron"), "CSS must contain .museum-ai-drawer-chevron");
assert.ok(cssContent.includes(".museum-ai-stop-btn:focus-visible"), "CSS must contain .museum-ai-stop-btn:focus-visible");
assert.ok(cssContent.includes(".museum-ai-message-bubble .museum-md"), "CSS must contain high-density typography rules for copilot markdown");

// Check right-sidebar positioning
assert.ok(/right:\s*0/.test(cssContent), "Sidebar must dock to the right side");

console.log("✓ CSS tokens and right-sidebar layout rules verified");

console.log("--- TEST 2: Article Panel HTML Contract in org-museum-ai-web.el ---");
const elContent = fs.readFileSync(path.join(root, "org-museum-ai-web.el"), "utf8");

assert.ok(elContent.includes("museum-ai-sidebar"), "HTML generator must declare .museum-ai-sidebar");
assert.ok(elContent.includes("museum-ai-drawer-chevron"), "HTML generator must declare drawer chevron");
assert.ok(elContent.includes("?pageId="), "HTML generator must compute static ai-center link with pageId");
assert.ok(elContent.includes("data-ai-center-link"), "HTML generator must declare data-ai-center-link");
assert.ok(elContent.includes("data-copilot-new"), "HTML generator must declare new session trigger");
assert.ok(elContent.includes("data-copilot-model-select"), "HTML generator must declare model select dropdown");
assert.ok(elContent.includes("data-copilot-model-refresh"), "HTML generator must declare model refresh button");
assert.ok(elContent.includes("data-copilot-config-toggle"), "HTML generator must declare model config toggle button");
assert.ok(elContent.includes("data-copilot-model-config"), "HTML generator must declare model config container");
assert.ok(elContent.includes("data-ai-context-title"), "HTML generator must declare context title element");
assert.ok(elContent.includes("data-ai-chat-turns"), "HTML generator must declare chat turns log");
assert.ok(elContent.includes("data-ai-explore-chips"), "HTML generator must declare explore chips area");
assert.ok(elContent.includes("data-ai-chat-form"), "HTML generator must declare composer chat form");
assert.ok(elContent.includes("data-ai-chat-input"), "HTML generator must declare composer input textarea");
assert.ok(elContent.includes("data-ai-chat-stop"), "HTML generator must declare composer stop button");
assert.ok(elContent.includes("data-ai-chat-send"), "HTML generator must declare composer send button");

console.log("✓ HTML generator output markup contracts verified");

console.log("--- TEST 3: Article Copilot Runtime in org-museum-ai.js ---");

// Build Mock DOM for Article Page
const triggerBtn = createMockElement("button");
triggerBtn.setAttribute("data-ai-toggle", "");
const triggerDot = createMockElement("span");
triggerDot.setAttribute("data-ai-trigger-dot", "");
const triggerShortcut = createMockElement("kbd");
triggerShortcut.setAttribute("data-ai-trigger-shortcut", "");
triggerBtn.appendChild(triggerDot);
triggerBtn.appendChild(triggerShortcut);

const panel = createMockElement("aside");
panel.id = "museum-ai-panel";
panel.className = "museum-ai-panel museum-ai-sidebar";

const engineBadge = createMockElement("span");
engineBadge.setAttribute("data-ai-engine-badge", "");
panel.appendChild(engineBadge);

const modelSelect = createMockElement("select");
modelSelect.setAttribute("data-copilot-model-select", "");
panel.appendChild(modelSelect);

const modelRefreshBtn = createMockElement("button");
modelRefreshBtn.setAttribute("data-copilot-model-refresh", "");
panel.appendChild(modelRefreshBtn);

const configToggleBtn = createMockElement("button");
configToggleBtn.setAttribute("data-copilot-config-toggle", "");
panel.appendChild(configToggleBtn);

const configPanel = createMockElement("div");
configPanel.setAttribute("data-copilot-model-config", "");
configPanel.hidden = true;

const configForm = createMockElement("form");
configForm.setAttribute("data-copilot-config-form", "");

const providerInput = createMockElement("select");
providerInput.setAttribute("data-copilot-provider", "");
configForm.appendChild(providerInput);

const endpointInput = createMockElement("input");
endpointInput.setAttribute("data-copilot-endpoint", "");
configForm.appendChild(endpointInput);

const keyInput = createMockElement("input");
keyInput.setAttribute("data-copilot-key", "");
configForm.appendChild(keyInput);

const configCancelBtn = createMockElement("button");
configCancelBtn.setAttribute("data-copilot-config-cancel", "");
configForm.appendChild(configCancelBtn);

const configStatus = createMockElement("p");
configStatus.setAttribute("data-copilot-config-status", "");
configForm.appendChild(configStatus);

configPanel.appendChild(configForm);
panel.appendChild(configPanel);

const newChatBtn = createMockElement("button");
newChatBtn.setAttribute("data-copilot-new", "");
panel.appendChild(newChatBtn);

const closeBtn = createMockElement("button");
closeBtn.setAttribute("data-ai-close", "");
panel.appendChild(closeBtn);

const contextTitle = createMockElement("span");
contextTitle.setAttribute("data-ai-context-title", "");
panel.appendChild(contextTitle);

const analyzeBtn = createMockElement("button");
analyzeBtn.setAttribute("data-ai-analyze", "");
panel.appendChild(analyzeBtn);

const analyzeLabel = createMockElement("span");
analyzeLabel.setAttribute("data-ai-analyze-label", "");
analyzeBtn.appendChild(analyzeLabel);

const chatTurns = createMockElement("div");
chatTurns.setAttribute("data-ai-chat-turns", "");
panel.appendChild(chatTurns);

const exploreChips = createMockElement("div");
exploreChips.setAttribute("data-ai-explore-chips", "");
panel.appendChild(exploreChips);

const chatForm = createMockElement("form");
chatForm.setAttribute("data-ai-chat-form", "");

const chatInput = createMockElement("textarea");
chatInput.setAttribute("data-ai-chat-input", "");
chatForm.appendChild(chatInput);

const chatStop = createMockElement("button");
chatStop.setAttribute("data-ai-chat-stop", "");
chatStop.hidden = true;
chatForm.appendChild(chatStop);

const chatSend = createMockElement("button");
chatSend.setAttribute("data-ai-chat-send", "");
chatForm.appendChild(chatSend);

const composerHint = createMockElement("small");
composerHint.className = "museum-ai-composer-hint";
composerHint.setAttribute("data-ai-composer-hint", "");
composerHint.textContent = "Ctrl+Enter 发送 · Enter 换行";
chatForm.appendChild(composerHint);

panel.appendChild(chatForm);

const centerLink = createMockElement("a");
centerLink.setAttribute("data-ai-center-link", "");
centerLink.href = "ai-center.html?pageId=duckdb-analytics";
panel.appendChild(centerLink);

const articleContainer = createMockElement("main");
articleContainer.className = "article-container";
articleContainer.dataset.pageId = "duckdb-analytics";
articleContainer.dataset.pageTitle = "DuckDB 深度分析与架构笔记";

const articleH1 = createMockElement("h1");
articleH1.textContent = "DuckDB 深度分析与架构笔记";
articleContainer.appendChild(articleH1);

const articleBody = createMockElement("div");
articleBody.textContent = "DuckDB 是一款嵌入式分析型数据库，支持向量化执行引擎与高度优化的列存结构。";
articleContainer.appendChild(articleBody);

const body = createMockElement("body");
body.appendChild(triggerBtn);
body.appendChild(articleContainer);
body.appendChild(panel);

const sessionStore = new Map();
const mockSessionStorage = {
  getItem(k) { return sessionStore.has(k) ? sessionStore.get(k) : null; },
  setItem(k, v) { sessionStore.set(k, String(v)); },
  removeItem(k) { sessionStore.delete(k); },
  clear() { sessionStore.clear(); }
};

const localStore = new Map();
const mockLocalStorage = {
  getItem(k) { return localStore.has(k) ? localStore.get(k) : null; },
  setItem(k, v) { localStore.set(k, String(v)); }
};

const docListeners = {};
const mockDoc = {
  body,
  createElement(tag) { return createMockElement(tag); },
  querySelector(sel) {
    if (sel === "[data-ai-toggle]") return triggerBtn;
    if (sel === "#museum-ai-panel") return panel;
    if (sel === ".article-container") return articleContainer;
    return body.querySelector(sel);
  },
  querySelectorAll(sel) {
    return body.querySelectorAll(sel);
  },
  addEventListener(type, fn) {
    if (!docListeners[type]) docListeners[type] = [];
    docListeners[type].push(fn);
  },
  dispatchEvent(event) {
    const fns = docListeners[event.type] || [];
    fns.forEach(fn => fn(event));
  }
};

let streamChunkHandler = null;
let streamSignal = null;
const mockBrowserAi = {
  models: async (config) => {
    return ["qwen2.5:7b", "llama3.1:8b", "deepseek-r1:7b"];
  },
  chat: async (config, messages, onChunk, signal) => {
    streamChunkHandler = onChunk;
    streamSignal = signal;
    onChunk("根据 DuckDB 笔记内容，其核心优势在于列式存储与向量化计算。");
    return "根据 DuckDB 笔记内容，其核心优势在于列式存储与向量化计算。";
  }
};

const mockWin = {
  innerWidth: 1440,
  document: mockDoc,
  sessionStorage: mockSessionStorage,
  localStorage: mockLocalStorage,
  matchMedia: (query) => ({ matches: false }),
  navigator: {
    platform: "Win32",
    clipboard: {
      written: "",
      writeText: async (t) => { mockWin.navigator.clipboard.written = t; }
    }
  },
  orgMuseumMarkdown: {
    render: (node, text) => { node.textContent = text; },
    renderDocument: () => {}
  },
  orgMuseumBrowserAi: mockBrowserAi
};

// Set browser model config in localStorage
mockLocalStorage.setItem("org-museum-browser-model", JSON.stringify({
  model: "qwen2.5:7b",
  endpoint: "http://localhost:11434"
}));

const jsContent = fs.readFileSync(path.join(root, "resources/org-museum-ai.js"), "utf8");

// Run script
vm.runInNewContext(jsContent, {
  window: mockWin,
  document: mockDoc,
  sessionStorage: mockSessionStorage,
  localStorage: mockLocalStorage,
  navigator: mockWin.navigator,
  matchMedia: mockWin.matchMedia,
  AbortController,
  setTimeout,
  clearTimeout,
  Date,
  JSON
});

// Verify initial setup
assert.equal(triggerShortcut.textContent, "Ctrl+I", "Windows trigger shortcut should display Ctrl+I");
assert.equal(contextTitle.textContent, "DuckDB 深度分析与架构笔记", "Context title should match article title");
assert.ok(centerLink.href.includes("ai-center.html?pageId="), "ai-center link must point to ai-center.html with pageId");
assert.notEqual(centerLink.href, "#", "ai-center link must not be dummy # dead link");
assert.equal(composerHint.textContent, "Ctrl+Enter 发送 · Enter 换行", "Composer hint matches Windows platform");

// Verify explore chips initialization
assert.equal(exploreChips.children.length, 4, "Should initialize 4 default prompt chips");
assert.equal(exploreChips.children[0].textContent, "提炼这篇笔记的核心要点");

// Verify initial empty chat screen
assert.ok(chatTurns.children.length >= 1, "Should render initial chat welcome state");
const emptyWelcome = chatTurns.querySelector("h3");
assert.ok(emptyWelcome && emptyWelcome.textContent.includes("与 AI 讨论"), "Should render empty chat hero header");

console.log("✓ Initial DOM setup, prompt chips, and context binding verified");

// Test Toggle Sidebar
console.log("--- TEST 4: Sidebar Toggle and Shortcuts ---");
// On desktop >= 1280px, it defaults to open (matching DuckDB Editor)
assert.equal(body.classList.contains("museum-ai-open"), true, "Sidebar defaults to open on wide screens >= 1280px");
assert.equal(panel.inert, false, "Panel is interactive when open");

// Trigger Click toggles closed
triggerBtn.click();
assert.equal(body.classList.contains("museum-ai-open"), false, "Click trigger closes sidebar");
assert.equal(mockLocalStorage.getItem("copilot_sidebar_open"), "false", "Saves closed state to localStorage");

// Ctrl+I Shortcut opens
mockDoc.dispatchEvent({ type: "keydown", key: "i", ctrlKey: true, preventDefault() {} });
assert.equal(body.classList.contains("museum-ai-open"), true, "Ctrl+I re-opens sidebar");
assert.equal(mockLocalStorage.getItem("copilot_sidebar_open"), "true", "Saves open state to localStorage");

// Esc hierarchy: config panel closes before main sidebar
configToggleBtn.click();
assert.equal(configPanel.hidden, false, "Config panel opens");
assert.equal(configToggleBtn.getAttribute("aria-expanded"), "true", "configToggleBtn has aria-expanded=true");
mockDoc.dispatchEvent({ type: "keydown", key: "Escape" });
assert.equal(configPanel.hidden, true, "First Escape closes config panel");
assert.equal(configToggleBtn.getAttribute("aria-expanded"), "false", "configToggleBtn has aria-expanded=false");
assert.equal(body.classList.contains("museum-ai-open"), true, "Sidebar remains open after closing config panel");

// Esc Keydown closes
mockDoc.dispatchEvent({ type: "keydown", key: "Escape" });
assert.equal(body.classList.contains("museum-ai-open"), false, "Second Escape closes sidebar");

// Re-open for following tests
triggerBtn.click();
assert.equal(body.classList.contains("museum-ai-open"), true, "Re-open sidebar for interaction tests");

console.log("✓ Sidebar toggle via trigger and Ctrl+I/Escape shortcuts verified");

async function runAsyncTests() {
  console.log("--- TEST 5: Interactive Chat Flow & Streaming ---");
  const chip0 = exploreChips.children[0];
  // Click chip to send "提炼这篇笔记的核心要点"
  chip0.click();

  // Allow promise tick to resolve
  await new Promise(r => setTimeout(r, 10));

  // Chat turns should now contain user message and assistant message
  assert.equal(chatTurns.children.length, 2, "Chat should contain 2 messages (user + assistant)");
  const userMsg = chatTurns.children[0];
  const assistantMsg = chatTurns.children[1];

  assert.ok(userMsg.classList.contains("is-user"), "First message is user");
  assert.ok(userMsg.textContent.includes("提炼这篇笔记的核心要点"), "User message contains clicked chip text");

  assert.ok(assistantMsg.classList.contains("is-assistant"), "Second message is assistant");
  assert.ok(assistantMsg.textContent.includes("核心优势"), "Assistant rendered stream chunk answer");

  // Verify persistence to sessionStorage
  const storedRaw = mockSessionStorage.getItem("org-museum-copilot-duckdb-analytics");
  assert.ok(storedRaw, "SessionStorage must have stored discussion");
  const stored = JSON.parse(storedRaw);
  assert.equal(stored.length, 2, "Stored discussion contains 2 turns");
  assert.equal(stored[0].content, "提炼这篇笔记的核心要点");

  // Test Copy button on completed assistant message
  const copyBtn = assistantMsg.querySelector(".museum-ai-copy-btn");
  assert.ok(copyBtn, "Completed assistant message has copy button");
  copyBtn.click();
  assert.ok(mockWin.navigator.clipboard.written.includes("核心优势"), "Clipboard receives assistant message text");

  console.log("✓ Interactive chat flow, prompt clicking, streaming, and copy action verified");

  // Test Clear / New Chat
  console.log("--- TEST 6: New Chat Reset ---");
  newChatBtn.click();
  assert.equal(chatTurns.children.length, 1, "Chat turns reset to 1 (empty hero)");
  const newStored = JSON.parse(mockSessionStorage.getItem("org-museum-copilot-duckdb-analytics"));
  assert.deepEqual(newStored, [], "SessionStorage updated to empty array");

  console.log("✓ New chat resets conversation and clears session storage");

  // Test 7: Frontend Model Selection and Switching
  console.log("--- TEST 7: Frontend Model Selection and Switching ---");
  assert.ok(modelSelect.children.length >= 2, "Model selector should have populated options");
  assert.equal(engineBadge.textContent, "qwen2.5:7b", "Engine badge reflects active model");

  // Switch model in frontend
  modelSelect.value = "llama3.1:8b";
  modelSelect.dispatchEvent({ type: "change" });
  const updatedCfg = JSON.parse(mockLocalStorage.getItem("org-museum-browser-model"));
  assert.equal(updatedCfg.model, "llama3.1:8b", "Switching model updates localStorage");
  assert.equal(engineBadge.textContent, "llama3.1:8b", "Engine badge updates to newly selected model");

  // Refresh models
  modelRefreshBtn.click();
  await new Promise(r => setTimeout(r, 10));
  assert.ok(modelSelect.children.some(c => c.value === "deepseek-r1:7b"), "Refresh populates models from frontend service");

  // Config panel toggle
  assert.equal(configPanel.hidden, true, "Config panel is initially hidden");
  configToggleBtn.click();
  assert.equal(configPanel.hidden, false, "Clicking config toggle opens panel");
  configCancelBtn.click();
  assert.equal(configPanel.hidden, true, "Clicking cancel hides config panel");

  // Test two-way org-museum-model-changed event
  mockDoc.dispatchEvent({
    type: "org-museum-model-changed",
    detail: { model: "deepseek-r1:7b" }
  });
  assert.equal(modelSelect.value, "deepseek-r1:7b", "Two-way model changed event updates modelSelect.value");
  assert.equal(engineBadge.textContent, "deepseek-r1:7b", "Two-way model changed event updates engine badge");

  console.log("✓ Frontend model selection, switching, refreshing, and configuration verified");

  console.log("\n========================================");
  console.log("ALL AI ARTICLE COPILOT TESTS PASSED!");
  console.log("========================================\n");
}

runAsyncTests().catch(err => {
  console.error(err);
  process.exit(1);
});
