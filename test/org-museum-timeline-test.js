// Run with: node test/org-museum-timeline-test.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const cssPath = path.join(root, 'resources', 'org-museum.css');
const timelineJsPath = path.join(root, 'dist', 'resources', 'org-museum-timeline.js');
const timelineHtmlPath = path.join(root, 'dist', 'timeline.html');

console.log('--- TEST 1: Timeline HTML markup contract ---');
const timelineHtml = fs.readFileSync(timelineHtmlPath, 'utf8');
assert(timelineHtml.includes('id="timeline-time-filters"'), 'Missing timeline-time-filters container');
assert(timelineHtml.includes('id="timeline-date-start"'), 'Missing timeline-date-start input');
assert(timelineHtml.includes('id="timeline-date-end"'), 'Missing timeline-date-end input');
assert(timelineHtml.includes('id="timeline-date-clear"'), 'Missing timeline-date-clear button');
assert(timelineHtml.includes('id="timeline-date-feedback"'), 'Missing timeline-date-feedback alert');
assert(timelineHtml.includes('timeline-filter-section-time'), 'Missing timeline-filter-section-time section');
assert(timelineHtml.includes('按时间范围筛选'), 'Missing time filter aria-label');
assert(timelineHtml.includes('id="timeline-grain-selector"'), 'Missing timeline-grain-selector container');
assert(timelineHtml.includes('id="timeline-grain-filters"'), 'Missing timeline-grain-filters container');
assert(timelineHtml.includes('data-grain="day"'), 'Missing day grain button');
assert(timelineHtml.includes('data-grain="month"'), 'Missing month grain button');
assert(timelineHtml.includes('data-grain="year"'), 'Missing year grain button');
assert(timelineHtml.includes('id="timeline-view-selector"'), 'Missing timeline-view-selector container');
assert(timelineHtml.includes('data-view="timeline"'), 'Missing timeline view button');
assert(timelineHtml.includes('data-view="calendar"'), 'Missing calendar view button');
assert(timelineHtml.includes('id="timeline-calendar-view"'), 'Missing timeline-calendar-view container');
console.log('✓ Timeline HTML markup contract verified');

console.log('--- TEST 2: Timeline CSS rules for time filter and mobile touch areas ---');
const css = fs.readFileSync(cssPath, 'utf8');
assert(css.includes('.timeline-filter-section-time'), 'Missing .timeline-filter-section-time styling');
assert(css.includes('.timeline-date-fields'), 'Missing .timeline-date-fields styling');
assert(css.includes('.timeline-date-clear'), 'Missing .timeline-date-clear styling');
assert(css.includes('#timeline-time-filters button::before'), 'Missing #timeline-time-filters bullet override');
assert(css.includes('.timeline-grain-selector'), 'Missing .timeline-grain-selector styling');
assert(css.includes('#timeline-grain-filters button::before'), 'Missing #timeline-grain-filters bullet override');
assert(css.includes('.timeline-grain-selector button'), 'Missing .timeline-grain-selector button styling');
// Verify mobile rules
assert(css.includes('.timeline-filter-sheet .timeline-date-fields'), 'Missing mobile timeline date fields rules');
assert(css.includes('.timeline-filter-sheet .timeline-date-fields input'), 'Missing mobile input rules');
assert(css.includes('.timeline-filter-sheet .timeline-date-clear'), 'Missing mobile clear button rules');
assert(css.includes('.timeline-view-selector'), 'Missing .timeline-view-selector styling');
assert(css.includes('.timeline-calendar-view'), 'Missing .timeline-calendar-view styling');
assert(css.includes('.timeline-calendar-grid'), 'Missing .timeline-calendar-grid styling');
assert(css.includes('.timeline-calendar-cell'), 'Missing .timeline-calendar-cell styling');
assert(css.includes('.timeline-calendar-note-item'), 'Missing .timeline-calendar-note-item styling');
console.log('✓ Timeline CSS contracts verified');

console.log('--- TEST 3: Timeline JS Runtime Behavior ---');
const scriptCode = fs.readFileSync(timelineJsPath, 'utf8');

// Build a lightweight DOM environment for testing
function createTimelineEnv(initialUrl = 'https://example.test/timeline.html') {
  const listeners = {};
  const elements = {};

  function makeEl(tag, id = '', className = '') {
    const el = {
      tagName: tag.toUpperCase(),
      id: id,
      className: className,
      dataset: {},
      style: {
        setProperty: (k, v) => { el.style[k] = v; }
      },
      attributes: {},
      children: [],
      hidden: false,
      value: '',
      setAttribute: (k, v) => { el.attributes[k] = String(v); },
      getAttribute: (k) => el.attributes[k] || null,
      removeAttribute: (k) => { delete el.attributes[k]; },
      appendChild: (child) => { child.parentElement = el; el.children.push(child); return child; },
      replaceChildren: (...newChildren) => {
        newChildren.forEach(c => { c.parentElement = el; });
        el.children = newChildren.slice();
      },
      closest: (selector) => {
        if (selector === 'button[data-grain]') {
          if (el.tagName === 'BUTTON' && el.dataset && el.dataset.grain) return el;
        }
        if (selector === 'button[data-view]') {
          if (el.tagName === 'BUTTON' && el.dataset && el.dataset.view) return el;
        }
        if (el.parentElement && typeof el.parentElement.closest === 'function') {
          return el.parentElement.closest(selector);
        }
        return null;
      },
      querySelector: (selector) => {
        function search(node) {
          if (selector.startsWith('[data-range="')) {
            const range = selector.slice(13, -2);
            if (node.dataset && node.dataset.range === range) return node;
          } else if (selector.startsWith('[data-value="')) {
            const val = selector.slice(13, -2);
            if (node.dataset && node.dataset.value === val) return node;
          } else if (selector.startsWith('.timeline-calendar-note-item[data-id="')) {
            const id = selector.slice(38, -2);
            if (node.className && node.className.includes('timeline-calendar-note-item') && node.dataset && node.dataset.id === id) return node;
          } else if (selector === '.is-active') {
            if (node.className && node.className.includes('is-active')) return node;
          } else if (selector.startsWith('.')) {
            const cls = selector.slice(1);
            if (node.className && node.className.includes(cls)) return node;
          }
          for (const child of node.children || []) {
            const found = search(child);
            if (found) return found;
          }
          return null;
        }
        for (const child of el.children || []) {
          const found = search(child);
          if (found) return found;
        }
        return null;
      },
      querySelectorAll: (selector) => {
        if (!selector) return [];
        const matches = [];
        function searchAll(node) {
          if (selector === 'button[data-grain]') {
            if (node.tagName === 'BUTTON' && node.dataset && node.dataset.grain) matches.push(node);
          } else if (selector === 'button[data-view]') {
            if (node.tagName === 'BUTTON' && node.dataset && node.dataset.view) matches.push(node);
          } else if (selector === 'button') {
            if (node.tagName === 'BUTTON') matches.push(node);
          } else if (selector === '.is-active') {
            if (node.className && node.className.includes('is-active')) matches.push(node);
          } else if (selector === '.timeline-calendar-note-item') {
            if (node.className && node.className.includes('timeline-calendar-note-item')) matches.push(node);
          } else if (selector.startsWith('.')) {
            const cls = selector.slice(1);
            if (node.className && node.className.includes(cls)) matches.push(node);
          }
          for (const child of node.children || []) {
            searchAll(child);
          }
        }
        for (const child of el.children || []) {
          searchAll(child);
        }
        return matches;
      },
      setCustomValidity: (msg) => { el.customValidity = msg; },
      focus: () => {},
      addEventListener: (type, handler) => {
        el._handlers = el._handlers || {};
        el._handlers[type] = el._handlers[type] || [];
        el._handlers[type].push(handler);
      },
      dispatchEvent: (evt) => {
        evt.target = evt.target || el;
        const handlers = (el._handlers && el._handlers[evt.type]) || [];
        handlers.forEach(h => h(evt));
        if (el.parentElement && typeof el.parentElement.dispatchEvent === 'function') {
          el.parentElement.dispatchEvent(evt);
        }
      },
      click: () => {
        el.dispatchEvent({ type: 'click' });
      }
    };
    Object.defineProperty(el, 'classList', {
      get() {
        return {
          add: (cls) => { if (!el.className.includes(cls)) el.className += ' ' + cls; },
          remove: (cls) => { el.className = el.className.replace(cls, '').trim(); },
          toggle: (cls, force) => {
            if (force === undefined) force = !el.className.includes(cls);
            if (force) { if (!el.className.includes(cls)) el.className += ' ' + cls; }
            else { el.className = el.className.replace(cls, '').trim(); }
          },
          contains: (cls) => el.className.includes(cls)
        };
      }
    });
    let _text = '';
    Object.defineProperty(el, 'textContent', {
      get() {
        if (el.children && el.children.length > 0) {
          return el.children.map(c => c.textContent).join(' ');
        }
        return _text;
      },
      set(val) {
        _text = String(val);
        if (!val) {
          el.children = [];
        }
      }
    });
    return el;
  }

  const sampleData = {
    schemaVersion: 1,
    today: '2026-10-03',
    pages: [
      {
        id: 'note-may',
        title: 'May Note',
        category: 'Emacs',
        categoryLabel: 'Emacs',
        tags: ['emacs'],
        status: 'published',
        created: 1779692400,
        createdDate: '2026-05-25',
        modified: 1790845080,
        modifiedDate: '2026-10-01'
      },
      {
        id: 'note-jul',
        title: 'July Note',
        category: 'Ontology',
        categoryLabel: 'Ontology',
        tags: ['ontology'],
        status: 'published',
        created: 1783753200,
        createdDate: '2026-07-11',
        modified: 1790845080,
        modifiedDate: '2026-10-01'
      },
      {
        id: 'note-oct',
        title: 'Oct Note',
        category: 'Emacs',
        categoryLabel: 'Emacs',
        tags: ['emacs'],
        status: 'published',
        created: 1790845080,
        createdDate: '2026-10-01',
        modified: 1790845080,
        modifiedDate: '2026-10-01'
      }
    ],
    edges: []
  };

  const docEls = {
    'timeline-data': { textContent: JSON.stringify(sampleData) },
    'org-museum-global-search': makeEl('input', 'org-museum-global-search'),
    'timeline-canvas': makeEl('div', 'timeline-canvas'),
    'timeline-svg': makeEl('div', 'timeline-svg'),
    'timeline-mobile-list': makeEl('ol', 'timeline-mobile-list'),
    'timeline-focus-card': makeEl('aside', 'timeline-focus-card'),
    'timeline-tooltip': makeEl('div', 'timeline-tooltip'),
    'timeline-category-filters': makeEl('div', 'timeline-category-filters'),
    'timeline-status-filters': makeEl('p', 'timeline-status-filters'),
    'timeline-match-status': makeEl('p', 'timeline-match-status'),
    'timeline-scope-summary': makeEl('span', 'timeline-scope-summary'),
    'timeline-filter-toggle': makeEl('button', 'timeline-filter-toggle'),
    'timeline-filter-sheet': makeEl('aside', 'timeline-filter-sheet'),
    'timeline-filter-close': makeEl('button', 'timeline-filter-close'),
    'timeline-filter-backdrop': makeEl('div', 'timeline-filter-backdrop'),
    'timeline-filter-result': makeEl('span', 'timeline-filter-result'),
    'timeline-isolated-list': makeEl('div', 'timeline-isolated-list'),
    'timeline-isolated-count': makeEl('span', 'timeline-isolated-count'),
    'timeline-total': makeEl('b', 'timeline-total'),
    'timeline-grain-selector': makeEl('div', 'timeline-grain-selector'),
    'timeline-grain-filters': makeEl('div', 'timeline-grain-filters'),
    'timeline-view-selector': makeEl('div', 'timeline-view-selector'),
    'timeline-calendar-view': makeEl('div', 'timeline-calendar-view'),
    'timeline-time-filters': makeEl('div', 'timeline-time-filters'),
    'timeline-date-start': makeEl('input', 'timeline-date-start'),
    'timeline-date-end': makeEl('input', 'timeline-date-end'),
    'timeline-date-clear': makeEl('button', 'timeline-date-clear'),
    'timeline-date-feedback': makeEl('p', 'timeline-date-feedback')
  };

  ['day', 'month', 'year'].forEach(g => {
    const b1 = makeEl('button');
    b1.dataset.grain = g;
    if (g === 'day') { b1.className = 'is-active'; b1.setAttribute('aria-pressed', 'true'); }
    else { b1.setAttribute('aria-pressed', 'false'); }
    docEls['timeline-grain-selector'].appendChild(b1);

    const b2 = makeEl('button');
    b2.dataset.grain = g;
    if (g === 'day') { b2.className = 'is-active'; b2.setAttribute('aria-pressed', 'true'); }
    else { b2.setAttribute('aria-pressed', 'false'); }
    docEls['timeline-grain-filters'].appendChild(b2);
  });

  ['timeline', 'calendar'].forEach(v => {
    const btn = makeEl('button');
    btn.dataset.view = v;
    if (v === 'timeline') { btn.className = 'is-active'; btn.setAttribute('aria-pressed', 'true'); }
    else { btn.setAttribute('aria-pressed', 'false'); }
    docEls['timeline-view-selector'].appendChild(btn);
  });


  let currentUrl = new URL(initialUrl);

  const sandbox = {
    window: {
      location: {
        get href() { return currentUrl.href; },
        set href(v) { currentUrl = new URL(v, currentUrl.href); },
        get search() { return currentUrl.search; },
        get pathname() { return currentUrl.pathname; },
        get hash() { return currentUrl.hash; }
      },
      addEventListener: (type, handler) => {
        listeners[type] = listeners[type] || [];
        listeners[type].push(handler);
      },
      matchMedia: () => ({ matches: false }),
      scrollTo: () => {},
      requestAnimationFrame: (fn) => setTimeout(fn, 0),
      cancelAnimationFrame: () => {},
      setTimeout: setTimeout,
      clearTimeout: clearTimeout,
      performance: { now: () => Date.now() },
      innerWidth: 1024,
      innerHeight: 768,
      CSS: { escape: s => s }
    },
    document: {
      getElementById: (id) => docEls[id] || null,
      querySelector: (selector) => {
        if (selector === '.timeline-layout') return makeEl('div', '', 'timeline-layout');
        if (selector === '.timeline-scope-bar') return makeEl('section', '', 'timeline-scope-bar');
        return null;
      },
      querySelectorAll: () => [],
      createElement: (tag) => makeEl(tag),
      createTextNode: (text) => ({ textContent: String(text), nodeType: 3 }),
      activeElement: null,
      body: makeEl('body'),
      documentElement: makeEl('html'),
      addEventListener: (type, handler) => {
        listeners[type] = listeners[type] || [];
        listeners[type].push(handler);
      },
      removeEventListener: () => {}
    },
    history: {
      scrollRestoration: 'auto',
      replaceState: (state, title, url) => {
        currentUrl = new URL(url, currentUrl.href);
      },
      pushState: (state, title, url) => {
        currentUrl = new URL(url, currentUrl.href);
      }
    },
    URL: URL,
    URLSearchParams: URLSearchParams,
    Map: Map,
    Set: Set,
    Date: Date,
    JSON: JSON,
    Math: Math,
    String: String,
    Number: Number,
    Array: Array,
    Boolean: Boolean,
    CSS: { escape: s => s },
    d3: undefined // Test headless / list mode branch safely
  };

  sandbox.location = sandbox.window.location;
  sandbox.innerWidth = sandbox.window.innerWidth;
  sandbox.innerHeight = sandbox.window.innerHeight;
  sandbox.matchMedia = sandbox.window.matchMedia;
  sandbox.scrollY = 0;
  sandbox.requestAnimationFrame = sandbox.window.requestAnimationFrame;
  sandbox.cancelAnimationFrame = sandbox.window.cancelAnimationFrame;
  sandbox.setTimeout = setTimeout;
  sandbox.clearTimeout = clearTimeout;

  vm.createContext(sandbox);
  vm.runInContext(scriptCode, sandbox);

  return { sandbox, docEls, getUrl: () => currentUrl, listeners };
}

// 1. Initial State
const env = createTimelineEnv();
const { docEls, getUrl } = env;
assert.equal(docEls['timeline-total'].textContent, '03');
assert.equal(docEls['timeline-match-status'].textContent, '3 个时间节点');
assert.equal(docEls['timeline-scope-summary'].textContent, '已发布笔记');
assert.equal(docEls['timeline-date-clear'].hidden, true);

const getTimeBtn = (range) => docEls['timeline-time-filters'].children.find(c => c.dataset.range === String(range));
const getCatBtn = (cat) => docEls['timeline-category-filters'].children.find(c => c.dataset.value === String(cat));

assert(docEls['timeline-time-filters'].children.length >= 6, 'Expected at least 6 time shortcuts');
const allBtn = getTimeBtn('all');
assert(allBtn, 'Missing "all" shortcut button');
assert.equal(allBtn.getAttribute('aria-pressed'), 'true', '"All" shortcut should be pressed initially');

console.log('✓ Initial timeline state verified');

// 2. Select "近 7 天"
const recent7Btn = getTimeBtn('7');
assert(recent7Btn, 'Missing 7 days shortcut');
recent7Btn.click();

assert.equal(getUrl().searchParams.get('from'), '2026-09-27');
assert.equal(getUrl().searchParams.get('to'), '2026-10-03');
assert.equal(docEls['timeline-scope-summary'].textContent, '近 7 天');
assert.equal(docEls['timeline-match-status'].textContent, '1 个时间节点'); // Only Oct Note matches
assert.equal(docEls['timeline-date-start'].value, '2026-09-27');
assert.equal(docEls['timeline-date-end'].value, '2026-10-03');
assert.equal(docEls['timeline-date-clear'].hidden, false);
assert.equal(getTimeBtn('7').getAttribute('aria-pressed'), 'true');
assert.equal(getTimeBtn('all').getAttribute('aria-pressed'), 'false');
console.log('✓ Shortcut "近 7 天" filtering verified');

// 3. Toggle off "近 7 天"
getTimeBtn('7').click();
assert.equal(getUrl().searchParams.get('from'), null);
assert.equal(getUrl().searchParams.get('to'), null);
assert.equal(docEls['timeline-match-status'].textContent, '3 个时间节点');
assert.equal(docEls['timeline-scope-summary'].textContent, '已发布笔记');
assert.equal(docEls['timeline-date-clear'].hidden, true);
assert.equal(getTimeBtn('all').getAttribute('aria-pressed'), 'true');
console.log('✓ Shortcut toggle-off verified');

// 4. Custom date range: 2026-05-01 to 2026-07-31
docEls['timeline-date-start'].value = '2026-05-01';
docEls['timeline-date-end'].value = '2026-07-31';
docEls['timeline-date-start'].dispatchEvent({ type: 'change' });

assert.equal(getUrl().searchParams.get('from'), '2026-05-01');
assert.equal(getUrl().searchParams.get('to'), '2026-07-31');
assert.equal(docEls['timeline-match-status'].textContent, '2 个时间节点'); // May & July notes match
assert.equal(docEls['timeline-scope-summary'].textContent, '2026-05-01 ~ 2026-07-31');
assert.equal(docEls['timeline-date-clear'].hidden, false);
console.log('✓ Custom date range filtering verified');

// 5. Date validation on reversed range
docEls['timeline-date-start'].value = '2026-10-01';
docEls['timeline-date-end'].value = '2026-05-01';
docEls['timeline-date-end'].dispatchEvent({ type: 'change' });
assert.equal(docEls['timeline-date-feedback'].hidden, false);
assert.equal(docEls['timeline-date-end'].getAttribute('aria-invalid'), 'true');
assert(docEls['timeline-date-feedback'].textContent.includes('结束日期不能早于开始日期'));
console.log('✓ Date range validation on reversed dates verified');

// 6. Clear button
docEls['timeline-date-clear'].click();
assert.equal(getUrl().searchParams.get('from'), null);
assert.equal(getUrl().searchParams.get('to'), null);
assert.equal(docEls['timeline-match-status'].textContent, '3 个时间节点');
assert.equal(docEls['timeline-scope-summary'].textContent, '已发布笔记');
assert.equal(docEls['timeline-date-start'].value, '');
assert.equal(docEls['timeline-date-end'].value, '');
assert.equal(docEls['timeline-date-clear'].hidden, true);
assert.equal(docEls['timeline-date-feedback'].hidden, true);
console.log('✓ Clear button verified');

// 7. Combined Category + Time Filter
const catBtns = docEls['timeline-category-filters'].children;
const emacsBtn = catBtns.find(c => c.dataset.value === 'Emacs');
assert(emacsBtn, 'Missing Emacs category button');
emacsBtn.click();
assert.equal(docEls['timeline-match-status'].textContent, '2 个时间节点'); // 2 Emacs notes (May & Oct)

getTimeBtn('7').click();
assert.equal(docEls['timeline-match-status'].textContent, '1 个时间节点'); // Only Oct Emacs note
assert.equal(docEls['timeline-scope-summary'].textContent, 'Emacs · 近 7 天');
assert.equal(getUrl().searchParams.get('category'), 'Emacs');
assert.equal(getUrl().searchParams.get('from'), '2026-09-27');
assert.equal(getUrl().searchParams.get('to'), '2026-10-03');
console.log('✓ Combined Category + Time filter verified');

// 8. Initial URL restoration with ?from= and ?to=
const envRestored = createTimelineEnv('https://example.test/timeline.html?from=2026-07-01&to=2026-07-31');
assert.equal(envRestored.docEls['timeline-match-status'].textContent, '1 个时间节点');
assert.equal(envRestored.docEls['timeline-scope-summary'].textContent, '2026-07-01 ~ 2026-07-31');
assert.equal(envRestored.docEls['timeline-date-start'].value, '2026-07-01');
assert.equal(envRestored.docEls['timeline-date-end'].value, '2026-07-31');
console.log('✓ URL bookmarking and initial param loading verified');

// 9. Grain selection (day by default, month, year)
const dayBtn = docEls['timeline-grain-selector'].children.find(c => c.dataset.grain === 'day');
const monthBtn = docEls['timeline-grain-selector'].children.find(c => c.dataset.grain === 'month');
const yearBtn = docEls['timeline-grain-selector'].children.find(c => c.dataset.grain === 'year');
assert.equal(dayBtn.className.includes('is-active'), true, 'Day grain should be active by default');

monthBtn.click();
assert.equal(monthBtn.className.includes('is-active'), true, 'Month grain should be active after click');
assert.equal(dayBtn.className.includes('is-active'), false, 'Day grain should be inactive');
assert.equal(getUrl().searchParams.get('grain'), 'month', 'URL should contain grain=month');

// Initial URL restoration with ?grain=year
const envYear = createTimelineEnv('https://example.test/timeline.html?grain=year');
const restoredYearBtn = envYear.docEls['timeline-grain-selector'].children.find(c => c.dataset.grain === 'year');
assert.equal(restoredYearBtn.className.includes('is-active'), true, 'Year grain should be active when loaded from URL');
console.log('✓ Timeline grain switching and persistence verified');

console.log('========================================');
// 10. View switching between timeline and calendar modes
// Reset any active filters first so all notes are in scope
const catAllBtn = docEls['timeline-category-filters'].children.find(c => c.dataset.value === '*');
if (catAllBtn) catAllBtn.click();
allBtn.click();
const timelineBtn = docEls['timeline-view-selector'].children.find(c => c.dataset.view === 'timeline');
const calendarBtn = docEls['timeline-view-selector'].children.find(c => c.dataset.view === 'calendar');
assert(timelineBtn, 'Missing timeline view button in DOM');
assert(calendarBtn, 'Missing calendar view button in DOM');

assert.equal(timelineBtn.className.includes('is-active'), true, 'Timeline button should be active initially');
assert.equal(calendarBtn.className.includes('is-active'), false, 'Calendar button should be inactive initially');
assert.equal(docEls['timeline-calendar-view'].hidden, true, 'Calendar view should be hidden initially');
assert.equal(docEls['timeline-canvas'].hidden, false, 'Canvas should be visible initially');

// Switch to Calendar view
calendarBtn.click();
assert.equal(calendarBtn.className.includes('is-active'), true, 'Calendar button should be active after click');
assert.equal(timelineBtn.className.includes('is-active'), false, 'Timeline button should be inactive');
assert.equal(docEls['timeline-calendar-view'].hidden, false, 'Calendar view should be visible');
assert.equal(docEls['timeline-canvas'].hidden, true, 'Canvas should be hidden in calendar mode');
assert.equal(docEls['timeline-mobile-list'].hidden, true, 'Mobile list should be hidden in calendar mode');
assert.equal(getUrl().searchParams.get('view'), 'calendar', 'URL should reflect view=calendar');

// Verify calendar rendered components
assert(docEls['timeline-calendar-view'].children.length >= 3, 'Calendar view should have header, weekdays, and grid');
const calHeader = docEls['timeline-calendar-view'].querySelector('.timeline-calendar-header');
assert(calHeader, 'Calendar header should be rendered');
const calTitle = docEls['timeline-calendar-view'].querySelector('.timeline-calendar-title');
assert(calTitle && calTitle.textContent.includes('2026 年 10 月'), 'Header should display current month');
const calCount = docEls['timeline-calendar-view'].querySelector('.timeline-calendar-month-count');
assert(calCount && calCount.textContent.includes('本月 1 篇笔记'), 'Header should count notes created in current month');

const calGrid = docEls['timeline-calendar-view'].querySelector('.timeline-calendar-grid');
assert(calGrid, 'Calendar grid should be rendered');
const calNotes = docEls['timeline-calendar-view'].querySelectorAll('.timeline-calendar-note-item');
assert.equal(calNotes.length, 1, 'Only notes created in October should appear in October calendar');
assert.equal(calNotes[0].dataset.id, 'note-oct', 'Note-oct should appear on its creation date');
assert.equal(calNotes[0].getAttribute('title'), 'Oct Note', 'Note item title should not contain update indicator');

assert.equal(docEls['timeline-calendar-view'].querySelectorAll('.timeline-calendar-update-tag').length, 0, 'No update tags should exist');

// Navigate to July 2026 to verify note-jul appears on its creation month
const prevBtn = docEls['timeline-calendar-view'].querySelector('.timeline-calendar-prev');
prevBtn.click(); // September
prevBtn.click(); // August
prevBtn.click(); // July
const julTitle = docEls['timeline-calendar-view'].querySelector('.timeline-calendar-title');
assert(julTitle && julTitle.textContent.includes('2026 年 7 月'), 'Header should display July 2026');
const julNotes = docEls['timeline-calendar-view'].querySelectorAll('.timeline-calendar-note-item');
assert.equal(julNotes.length, 1, 'Only note-jul should appear in July 2026 (creation date)');
assert.equal(julNotes[0].dataset.id, 'note-jul', 'July note should match note-jul');

// Return to current month using Today button
const todayBtn = docEls['timeline-calendar-view'].querySelector('.timeline-calendar-today');
todayBtn.click();
const octNotesAfterToday = docEls['timeline-calendar-view'].querySelectorAll('.timeline-calendar-note-item');
assert.equal(octNotesAfterToday.length, 1);

// Click note in calendar to trigger focus and focus-card inspect
const octCalNote = octNotesAfterToday[0];
assert(octCalNote, 'Oct Note button should exist in calendar');
octCalNote.click();
assert.equal(docEls['timeline-focus-card'].hidden, false, 'Focus card should open when clicking calendar note');
assert.equal(getUrl().searchParams.get('focus'), 'note-oct', 'URL should contain focus=note-oct');

// Switch back to timeline view
timelineBtn.click();
assert.equal(timelineBtn.className.includes('is-active'), true, 'Timeline button should be active again');
assert.equal(calendarBtn.className.includes('is-active'), false, 'Calendar button should be inactive');
assert.equal(docEls['timeline-calendar-view'].hidden, true, 'Calendar view should be hidden');
assert.equal(docEls['timeline-canvas'].hidden, false, 'Canvas should be visible again');
assert.equal(getUrl().searchParams.get('view'), null, 'URL should clear view param when returning to default');
console.log('✓ Timeline vs Calendar view switching and calendar note inspection verified');

// 11. Initial URL restoration with ?view=calendar
const envCalendar = createTimelineEnv('https://example.test/timeline.html?view=calendar');
const restoredCalBtn = envCalendar.docEls['timeline-view-selector'].children.find(c => c.dataset.view === 'calendar');
assert.equal(restoredCalBtn.className.includes('is-active'), true, 'Calendar button should be active on url restoration');
assert.equal(envCalendar.docEls['timeline-calendar-view'].hidden, false, 'Calendar view should be visible on url restoration');
assert.equal(envCalendar.docEls['timeline-canvas'].hidden, true, 'Canvas should be hidden on url restoration');
console.log('✓ Calendar view URL bookmarking and initial loading verified');

console.log('ALL TIMELINE TIME & GRAIN FILTER TESTS PASSED!');
console.log('========================================');
