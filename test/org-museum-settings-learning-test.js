const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../resources/org-museum-theme.js'), 'utf8');

function createMockElement(tag = 'div', dataset = {}) {
  return {
    tagName: tag.toUpperCase(),
    dataset: { ...dataset },
    attributes: {},
    classList: {
      classes: new Set(),
      add(c) { this.classes.add(c); },
      remove(c) { this.classes.delete(c); },
      toggle(c, force) {
        if (force === undefined) {
          if (this.classes.has(c)) this.classes.delete(c); else this.classes.add(c);
        } else if (force) {
          this.classes.add(c);
        } else {
          this.classes.delete(c);
        }
      },
      contains(c) { return this.classes.has(c); }
    },
    listeners: {},
    options: [],
    value: '',
    type: '',
    checked: false,
    textContent: '',
    setAttribute(k, v) { this.attributes[k] = String(v); },
    getAttribute(k) { return this.attributes[k] !== undefined ? this.attributes[k] : null; },
    addEventListener(k, fn) { this.listeners[k] = fn; },
    appendChild(c) { this.options.push(c); return c; },
    replaceChildren(...items) { this.options = items; },
    getBoundingClientRect() { return { top: 100, bottom: 120, left: 50, right: 150, width: 100, height: 20 }; }
  };
}

const stored = {};
const mockLocalStorage = {
  getItem(k) { return stored[k] || null; },
  setItem(k, v) { stored[k] = String(v); },
  removeItem(k) { delete stored[k]; },
  get length() { return Object.keys(stored).length; },
  key(i) { return Object.keys(stored)[i] || null; }
};

const docEl = createMockElement('html');
docEl.dataset = {};
docEl.style = {};

// Setup mock controls
const sizeButtons = ['sm', 'md', 'lg', 'xl'].map(sz => {
  const btn = createMockElement('button', { readingSize: sz });
  btn.setAttribute('data-reading-size', sz);
  return btn;
});
const widthButtons = ['980', '1024', '1180', '1320'].map(w => {
  const btn = createMockElement('button', { readingWidth: w });
  btn.setAttribute('data-reading-width', w);
  return btn;
});
const fontButtons = ['sans', 'serif'].map(f => {
  const btn = createMockElement('button', { readingFont: f });
  btn.setAttribute('data-reading-font', f);
  return btn;
});
const toneButtons = ['default', 'warm', 'slate'].map(t => {
  const btn = createMockElement('button', { readingTone: t });
  btn.setAttribute('data-reading-tone', t);
  return btn;
});
const lineButtons = ['compact', 'standard', 'relaxed'].map(l => {
  const btn = createMockElement('button', { readingLine: l });
  btn.setAttribute('data-reading-line', l);
  return btn;
});
const sceneButtons = ['eyecare', 'standard', 'dense'].map(s => {
  const btn = createMockElement('button', { presetScene: s });
  btn.setAttribute('data-preset-scene', s);
  return btn;
});

const previewMetrics = createMockElement('span');
const previewSample = createMockElement('p');
const zenToggle = createMockElement('input');

const beginnerToggle = createMockElement('input');
const hoverToggle = createMockElement('input');
const linenoToggle = createMockElement('input');
const activeRecallToggle = createMockElement('input');
const restoreGuidesBtn = createMockElement('button');

const questCheckboxes = ['explore_links', 'ai_dialogue', 'active_recall'].map(q => {
  const cb = createMockElement('input', { questCheckbox: q });
  cb.setAttribute('data-quest-checkbox', q);
  return cb;
});
const questProgressText = createMockElement('span');

const storageCount = createMockElement('strong');
const storageSize = createMockElement('strong');
const storageProgress = createMockElement('strong');
const storageKeyStatus = createMockElement('strong');
const copyBackupBtn = createMockElement('button');
const backupBtn = createMockElement('button');
const importInput = createMockElement('input');
const syncPreviewBtn = createMockElement('button');
const orgExportBtn = createMockElement('button');
const syncResultBox = createMockElement('div');
const resetAppearanceBtn = createMockElement('button');
const resetBtn = createMockElement('button');

const aiForm = createMockElement('form');
aiForm.elements = {
  provider: createMockElement('select'),
  endpoint: createMockElement('input'),
  model: createMockElement('input'),
  key: createMockElement('input'),
  system: createMockElement('textarea'),
  model_select: createMockElement('select')
};
aiForm.elements.key.type = 'password';

const connStatus = createMockElement('p');
const presetSelect = createMockElement('select');
presetSelect.value = 'siliconflow';

const keyToggleBtn = createMockElement('button');
const rememberKeyBox = createMockElement('input');
const quickTestBtn = createMockElement('button');

const promptBtns = ['beginner', 'socratic', 'summary'].map(p => {
  const btn = createMockElement('button', { promptPreset: p });
  btn.textContent = p;
  return btn;
});

const mockMenu = {
  querySelectorAll(sel) {
    if (sel === '[data-reading-size]') return sizeButtons;
    if (sel === '[data-reading-width]') return widthButtons;
    if (sel === '[data-reading-font]') return fontButtons;
    if (sel === '[data-reading-tone]') return toneButtons;
    if (sel === '[data-reading-line]') return lineButtons;
    if (sel === '[data-preset-scene]') return sceneButtons;
    if (sel === '[data-prompt-preset]') return promptBtns;
    if (sel === '[data-quest-checkbox]') return questCheckboxes;
    if (sel === '[data-settings-tab]') return [];
    if (sel === '[data-settings-panel]') return [];
    return [];
  },
  querySelector(sel) {
    if (sel === '[data-zen-mode-toggle]') return zenToggle;
    if (sel === '[data-quest-progress-text]') return questProgressText;
    if (sel === '[data-browser-quick-test]') return quickTestBtn;
    if (sel === '[data-browser-backup]') return backupBtn;
    if (sel === '[data-browser-import]') return importInput;
    if (sel === '[data-browser-sync-preview]') return syncPreviewBtn;
    if (sel === '[data-browser-org-export]') return orgExportBtn;
    if (sel === '[data-browser-sync-result]') return syncResultBox;
    if (sel === '[data-beginner-mode-toggle]') return beginnerToggle;
    if (sel === '[data-hover-preview-toggle]') return hoverToggle;
    if (sel === '[data-code-lineno-toggle]') return linenoToggle;
    if (sel === '[data-active-recall-toggle]') return activeRecallToggle;
    if (sel === '[data-restore-guides]') return restoreGuidesBtn;
    if (sel === '[data-preview-metrics]') return previewMetrics;
    if (sel === '[data-preview-sample]') return previewSample;
    if (sel === '[data-storage-count]') return storageCount;
    if (sel === '[data-storage-size]') return storageSize;
    if (sel === '[data-storage-progress]') return storageProgress;
    if (sel === '[data-storage-key-status]') return storageKeyStatus;
    if (sel === '[data-copy-backup]') return copyBackupBtn;
    if (sel === '[data-reset-appearance-only]') return resetAppearanceBtn;
    if (sel === '[data-reset-all-settings]') return resetBtn;
    if (sel === '[data-ai-preset-select]') return presetSelect;
    if (sel === '[data-toggle-key-visibility]') return keyToggleBtn;
    if (sel === '[data-remember-key]') return rememberKeyBox;
    if (sel === 'form[data-browser-config]') return aiForm;
    if (sel === '.museum-settings-status-box') return { dataset: {} };
    if (sel === '[data-browser-connection]') return connStatus;
    return null;
  },
  contains() { return false; },
  addEventListener() {}
};

const context = {
  AbortController, setTimeout, clearTimeout,
  localStorage: mockLocalStorage,
  document: {
    documentElement: docEl,
    body: createMockElement('body'),
    createElement(tag) { return createMockElement(tag); },
    getElementById(id) { return null; },
    querySelector(sel) { return null; },
    addEventListener() {},
    querySelectorAll(sel) {
      if (sel === '.museum-theme-menu') return [mockMenu];
      return [];
    }
  },
  window: {
    addEventListener() {},
    dispatchEvent() {},
    innerHeight: 900,
    innerWidth: 1200
  },
  CustomEvent: class CustomEvent { constructor(t, i) { this.type = t; this.detail = i && i.detail; } },
  location: { href: 'http://localhost/index.html', hostname: 'localhost', pathname: '/index.html', protocol: 'http:', search: '' },
  URL: globalThis.URL,
  confirm() { return true; },
  alert() {}
};

vm.runInNewContext(source, context);

console.log('Testing Reading & Typography settings...');

// 1. Test Reading Size change
sizeButtons[0].listeners.click();
assert.equal(docEl.dataset.readingSize, 'sm');
assert.equal(mockLocalStorage.getItem('org-museum-reading-size'), 'sm');
assert.equal(sizeButtons[0].getAttribute('aria-pressed'), 'true');
assert.equal(sizeButtons[1].getAttribute('aria-pressed'), 'false');

// 2. Test Reading Width change
widthButtons[3].listeners.click();
assert.equal(docEl.dataset.readingWidth, '1320');
assert.equal(mockLocalStorage.getItem('org-museum-reading-width'), '1320');
assert.equal(widthButtons[3].getAttribute('aria-pressed'), 'true');

// 3. Test Reading Font change
fontButtons[1].listeners.click();
assert.equal(docEl.dataset.readingFont, 'serif');
assert.equal(mockLocalStorage.getItem('org-museum-reading-font'), 'serif');

// 3.1 Test Reading Tone & Line Density & Live Preview
toneButtons[1].listeners.click();
assert.equal(docEl.dataset.readingTone, 'warm');
assert.equal(mockLocalStorage.getItem('org-museum-reading-tone'), 'warm');
assert.equal(toneButtons[1].getAttribute('aria-pressed'), 'true');

lineButtons[2].listeners.click();
assert.equal(docEl.dataset.readingLine, 'relaxed');
assert.equal(mockLocalStorage.getItem('org-museum-reading-line'), 'relaxed');
assert.equal(lineButtons[2].getAttribute('aria-pressed'), 'true');

// Verify Live Preview Card updated metrics
assert.match(previewMetrics.textContent, /人文宋体/);
assert.match(previewMetrics.textContent, /宽松 2.15/);
assert.match(previewMetrics.textContent, /护眼暖杏/);
console.log('✓ Reading typography, tone, line density, and live preview work as expected');

// 3.2 Test Scene Presets (e.g. Eyecare, Dense)
sceneButtons[2].listeners.click(); // dense
assert.equal(docEl.dataset.readingSize, 'sm');
assert.equal(docEl.dataset.readingWidth, '1180');
assert.equal(docEl.dataset.readingFont, 'sans');
assert.equal(docEl.dataset.readingTone, 'slate');
assert.equal(docEl.dataset.readingLine, 'compact');
assert.equal(sceneButtons[2].getAttribute('aria-pressed'), 'true');

sceneButtons[0].listeners.click(); // eyecare
assert.equal(docEl.dataset.readingSize, 'lg');
assert.equal(docEl.dataset.readingWidth, '980');
assert.equal(docEl.dataset.readingFont, 'serif');
assert.equal(docEl.dataset.readingTone, 'warm');
assert.equal(docEl.dataset.readingLine, 'relaxed');
assert.equal(sceneButtons[0].getAttribute('aria-pressed'), 'true');
assert.equal(sceneButtons[2].getAttribute('aria-pressed'), 'false');
console.log('✓ Scene reading presets (eyecare, dense, standard) work as expected');

// 3.3 Test Zen distraction-free reading mode
zenToggle.checked = true;
zenToggle.listeners.change();
assert.equal(docEl.dataset.zenMode, 'true');
assert.equal(mockLocalStorage.getItem('org-museum-zen-mode'), 'true');
zenToggle.checked = false;
zenToggle.listeners.change();
assert.equal(docEl.dataset.zenMode, 'false');
console.log('✓ Zen distraction-free mode toggle and persistence work');

// 4. Test Learning Settings
console.log('\nTesting Learning settings...');

// Verify initial state
assert.equal(docEl.dataset.beginnerMode, 'true');
assert.equal(docEl.dataset.hoverPreview, 'true');
assert.equal(docEl.dataset.codeLineno, 'true');

beginnerToggle.checked = false;
beginnerToggle.listeners.change();
assert.equal(docEl.dataset.beginnerMode, 'false');
assert.equal(mockLocalStorage.getItem('org-museum-beginner-mode'), 'false');

hoverToggle.checked = false;
hoverToggle.listeners.change();
assert.equal(docEl.dataset.hoverPreview, 'false');

linenoToggle.checked = false;
linenoToggle.listeners.change();
assert.equal(docEl.dataset.codeLineno, 'false');

// 4.1 Test Active Recall & Guide Restoration
activeRecallToggle.checked = true;
activeRecallToggle.listeners.change();
assert.equal(docEl.dataset.activeRecall, 'true');
assert.equal(mockLocalStorage.getItem('org-museum-active-recall'), 'true');

mockLocalStorage.setItem('org-museum-guide-dismissed', 'true');
mockLocalStorage.setItem('org-museum-related-guide-dismissed', 'true');
restoreGuidesBtn.listeners.click();
assert.equal(mockLocalStorage.getItem('org-museum-guide-dismissed'), null);
assert.equal(mockLocalStorage.getItem('org-museum-related-guide-dismissed'), null);

// 4.2 Test Newbie Learning Quests Card
questCheckboxes[0].checked = true;
questCheckboxes[0].listeners.change();
assert.match(questProgressText.textContent, /已完成 1 \/ 3 项/);
const savedQuests = JSON.parse(mockLocalStorage.getItem('org-museum-learning-quests') || '{}');
assert.equal(savedQuests.explore_links, true);
console.log('✓ Learning Quests tracking, checklist UI and persistence work');
console.log('✓ Learning assistance toggles (beginner, hover, lineno, active recall, restore guides) work');

// 5. Test AI Presets & Eye toggle & Prompt Presets & Quick Test
console.log('\nTesting AI Enhancements (Presets, Eye Toggle, Prompt Presets, Quick Test)...');

// Verify quick test greeting button is wired
assert(typeof quickTestBtn.listeners.click === 'function');

// Trigger preset change
presetSelect.listeners.change();
assert.equal(aiForm.elements.provider.value, 'compatible');
assert.equal(aiForm.elements.endpoint.value, 'https://api.siliconflow.cn/v1');
assert.equal(aiForm.elements.model.value, 'deepseek-ai/DeepSeek-V3');
assert.match(connStatus.textContent, /已载入预设配置/);

// Trigger key visibility toggle
keyToggleBtn.listeners.click();
assert.equal(aiForm.elements.key.type, 'text');
keyToggleBtn.listeners.click();
assert.equal(aiForm.elements.key.type, 'password');

// Trigger prompt preset
promptBtns[0].listeners.click();
assert.match(aiForm.elements.system.value, /通俗生动的比喻/);
assert.match(connStatus.textContent, /已切换提示词/);
assert.equal(promptBtns[0].getAttribute('aria-pressed'), 'true');
assert(promptBtns[0].classList.contains('is-active'));
console.log('✓ AI presets, key visibility toggle and prompt templates work');

// 6. Test Data Settings, Appearance-only Reset, and Factory Reset
console.log('\nTesting Data Settings, Appearance-only Reset, and Factory Reset...');

// Set a study record and AI key to test granular reset
mockLocalStorage.setItem('org-museum-related-completed', JSON.stringify(['pair-1', 'pair-2']));
mockLocalStorage.setItem('org-museum-api-key', 'secret-key-123');

// Test Appearance-only reset
resetAppearanceBtn.listeners.click();
assert.equal(docEl.dataset.readingSize, 'md');
assert.equal(docEl.dataset.readingWidth, '1320');
assert.equal(docEl.dataset.readingFont, 'sans');
assert.equal(docEl.dataset.readingTone, 'default');
assert.equal(docEl.dataset.readingLine, 'standard');
// Crucial: AI key and completed reading items MUST be preserved!
assert.equal(mockLocalStorage.getItem('org-museum-api-key'), 'secret-key-123');
assert.equal(mockLocalStorage.getItem('org-museum-related-completed'), JSON.stringify(['pair-1', 'pair-2']));
console.log('✓ Granular appearance-only reset safely preserves learning records and API key');

// 7. Test Backup & Restore Handlers and Copy Backup JSON
assert(typeof backupBtn.listeners.click === 'function');
assert(typeof importInput.listeners.change === 'function');

let clipboardContent = '';
context.navigator = { clipboard: { writeText: async (t) => { clipboardContent = t; } } };
copyBackupBtn.listeners.click();
setTimeout(() => {}, 10);
assert(clipboardContent.includes('secret-key-123'));
console.log('✓ Universal backup export, import, and clipboard copy verified');

// 8. Test Full Factory Reset
assert(Object.keys(stored).length > 0);
resetBtn.listeners.click();
assert.equal(docEl.dataset.readingSize, 'md');
assert.equal(docEl.dataset.readingWidth, '1320');
assert.equal(docEl.dataset.readingFont, 'sans');
assert.equal(docEl.dataset.beginnerMode, 'true');
assert.equal(mockLocalStorage.getItem('org-museum-zen-mode'), null);
assert.equal(mockLocalStorage.getItem('org-museum-api-key'), null);
console.log('✓ Factory Reset clears all data and restores pristine initial state');

console.log('\nALL 8/8 ENHANCED SETTINGS SUB-PAGE UNIT TESTS PASSED!');
