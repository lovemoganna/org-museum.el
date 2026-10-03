// Run with: node test/org-museum-dashboard-test.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const dashboardCode = fs.readFileSync(path.join(root, 'resources/org-museum-index-dashboard.js'), 'utf8');

// Sample dataset representing org-museum notes
const initialPages = [
  {
    pageId: 'duckdb-intro',
    title: 'DuckDB 快速上手',
    category: 'Sql',
    categoryLabel: 'SQL',
    description: 'DuckDB 基础使用与分析',
    tags: ['duckdb', 'database'],
    status: 'published',
    headings: [{ id: 'sec-1', title: '快速安装' }],
    created: 1789282800,
    createdDate: '2026-09-01',
    dateSource: 'org-date',
    modified: 1790272304,
    modifiedDate: '2026-09-20',
    href: 'pages/duckdb-intro.html'
  },
  {
    pageId: 'duckdb-advanced',
    title: 'DuckDB 高级分析',
    category: 'Sql',
    categoryLabel: 'SQL',
    description: 'DuckDB 深度分析与执行计划',
    tags: ['duckdb', 'analytics'],
    status: 'draft',
    headings: [{ id: 'sec-2', title: '执行计划分析' }],
    created: 1789282800,
    createdDate: '2026-09-05',
    dateSource: 'org-date',
    modified: 1790272304,
    modifiedDate: '2026-09-22',
    href: 'pages/duckdb-advanced.html'
  },
  {
    pageId: 'postgres-overview',
    title: 'PostgreSQL 架构设计',
    category: 'Sql',
    categoryLabel: 'SQL',
    description: 'PostgreSQL 存储引擎与事务隔离',
    tags: ['postgres', 'database'],
    status: 'published',
    headings: [],
    created: 1780000000,
    createdDate: '2026-04-10',
    dateSource: 'org-date',
    modified: 1789000000,
    modifiedDate: '2026-08-15',
    href: 'pages/postgres-overview.html'
  },
  {
    pageId: 'sicp-lisp',
    title: 'SICP 过程抽象',
    category: 'Lisp',
    categoryLabel: 'Lisp',
    description: '深入理解 Scheme 递归与过程抽象',
    tags: ['scheme', 'functional'],
    status: 'published',
    headings: [],
    created: 1785000000,
    createdDate: '2026-06-01',
    dateSource: 'org-date',
    modified: 1790272304,
    modifiedDate: '2026-09-25',
    href: 'pages/sicp-lisp.html'
  },
  {
    pageId: 'duckdb-in-lisp',
    title: 'Common Lisp 与 DuckDB 绑定',
    category: 'Lisp',
    categoryLabel: 'Lisp',
    description: '使用 CFFI 访问 DuckDB 原生接口',
    tags: ['duckdb', 'lisp'],
    status: 'published',
    headings: [],
    created: 1789282800,
    createdDate: '2026-09-15',
    dateSource: 'org-date',
    modified: 1790272304,
    modifiedDate: '2026-09-26',
    href: 'pages/duckdb-in-lisp.html'
  }
];

function createMockEnvironment(pages, customGeneratedAt) {
  const elements = new Map();
  const listeners = new Map();

  class MockElement {
    constructor(tagName) {
      this.tagName = (tagName || 'DIV').toUpperCase();
      this.children = [];
      this._text = '';
      this.className = '';
      this.dataset = {};
      this.attributes = new Map();
      this.hidden = false;
      this.listeners = new Map();
      this.style = {};
      this.classList = {
        add: (c) => { if (!this.className.includes(c)) this.className += ' ' + c; },
        remove: (c) => { this.className = this.className.replace(new RegExp('\\b' + c + '\\b', 'g'), '').trim(); },
        toggle: (c, force) => {
          const has = this.classList.contains(c);
          const state = force !== undefined ? force : !has;
          if (state) this.classList.add(c); else this.classList.remove(c);
          return state;
        },
        contains: (c) => new RegExp('\\b' + c + '\\b').test(this.className)
      };
    }
    get textContent() {
      if (this.children.length === 0) return this._text || '';
      return this.children.map(c => c.textContent).join('');
    }
    set textContent(val) {
      this._text = String(val || '');
      this.children = [];
    }
    appendChild(child) {
      this.children.push(child);
      child.parentElement = this;
      return child;
    }
    insertBefore(child, beforeChild) {
      const idx = this.children.indexOf(beforeChild);
      if (idx >= 0) this.children.splice(idx, 0, child);
      else this.children.push(child);
      child.parentElement = this;
      return child;
    }
    remove() {
      if (this.parentElement) {
        const idx = this.parentElement.children.indexOf(this);
        if (idx >= 0) this.parentElement.children.splice(idx, 1);
      }
    }
    setAttribute(name, val) { this.attributes.set(name, String(val)); }
    setCustomValidity(message) { this.validationMessage = message; }
    getAttribute(name) { return this.attributes.get(name) || (this[name] !== undefined ? this[name] : null); }
    focus() {}
    blur() {}
    addEventListener(evt, fn) {
      if (!this.listeners.has(evt)) this.listeners.set(evt, []);
      this.listeners.get(evt).push(fn);
    }
    click() {
      const handlers = this.listeners.get('click') || [];
      handlers.forEach(h => h.call(this, { preventDefault: () => {}, stopPropagation: () => {} }));
    }
    querySelector(sel) {
      const all = this.querySelectorAll(sel);
      return all[0] || null;
    }
    querySelectorAll(sel) {
      const results = [];
      function match(node) {
        if (!node) return;
        if (sel === 'a[href]' && (node.tagName === 'A' || node.attributes.has('href'))) results.push(node);
        else if (sel.startsWith('.') && node.classList.contains(sel.slice(1))) results.push(node);
        else if (sel.startsWith('[data-facet-expand="') && node.dataset.facetExpand === sel.slice(20, -2)) results.push(node);
        else if (sel.startsWith('[data-dashboard-metric="') && node.attributes.get('data-dashboard-metric') === sel.slice(24, -2)) results.push(node);
        for (const child of node.children || []) match(child);
      }
      for (const child of this.children) match(child);
      return results;
    }
  }

  function register(id, tag = 'div') {
    const el = new MockElement(tag);
    el.id = id;
    elements.set(id, el);
    return el;
  }

  const dataEl = register('org-museum-index-data', 'script');
  dataEl.textContent = JSON.stringify({
    schemaVersion: 2,
    generatedAt: customGeneratedAt || '2026-09-27T12:00:00+0000',
    pages: pages
  });

  const search = register('org-museum-global-search', 'input');
  const resultList = register('index-search-list');
  const empty = register('index-search-empty');
  const heading = register('index-results-heading');
  const visibleCount = register('index-visible-count');
  const live = register('index-results-live');
  const summary = register('index-filter-summary');
  const summaryChips = register('index-filter-chips');
  const dynamicFilters = register('index-dynamic-filters');
  const typeChart = register('index-type-chart');
  const typeExpand = register('index-type-expand', 'button');
  const typeCaption = register('index-type-caption', 'span');
  const trendChart = register('index-trend-chart');
  const trendAxis = register('index-trend-axis');
  const trendCaption = register('index-trend-caption', 'span');
  const rangeStart = register('index-date-start', 'input');
  const rangeEnd = register('index-date-end', 'input');
  const rangeClear = register('index-date-clear', 'button');
  const recentSeven = register('index-recent-7', 'button');
  const recentThirty = register('index-recent-30', 'button');
  const recentNinety = register('index-recent-90', 'button');
  const recentHalfYear = register('index-recent-180', 'button');
  const recentOneYear = register('index-recent-365', 'button');
  const sortControl = register('index-sort', 'select');
  const resume = register('continue-reading');
  const resumeList = register('continue-reading-list');
  const resumeCount = register('continue-reading-count');

  const metricTotal = new MockElement('strong');
  metricTotal.setAttribute('data-dashboard-metric', 'total');
  const metricCreated = new MockElement('strong');
  metricCreated.setAttribute('data-dashboard-metric', 'recent-created');
  const metricUpdated = new MockElement('strong');
  metricUpdated.setAttribute('data-dashboard-metric', 'recent-updated');

  const metricLabelCreated = new MockElement('span');
  metricLabelCreated.setAttribute('data-dashboard-metric-label', 'recent-created');
  metricLabelCreated.textContent = '近 30 天新增';
  const metricLabelUpdated = new MockElement('span');
  metricLabelUpdated.setAttribute('data-dashboard-metric-label', 'recent-updated');
  metricLabelUpdated.textContent = '近 30 天更新';

  const clearBtn = new MockElement('button');
  clearBtn.setAttribute('data-clear-index-filters', '');

  const documentMock = {
    getElementById: (id) => elements.get(id) || null,
    querySelector: (sel) => {
      if (sel === '[data-clear-index-filters]') return clearBtn;
      if (sel.startsWith('[data-dashboard-metric="total"]')) return metricTotal;
      if (sel.startsWith('[data-dashboard-metric="recent-created"]')) return metricCreated;
      if (sel.startsWith('[data-dashboard-metric="recent-updated"]')) return metricUpdated;
      if (sel.startsWith('[data-dashboard-metric-label="recent-created"]')) return metricLabelCreated;
      if (sel.startsWith('[data-dashboard-metric-label="recent-updated"]')) return metricLabelUpdated;
      if (sel === '.museum-index-matrix') return null;
      if (sel.startsWith('#')) return elements.get(sel.slice(1)) || null;
      return null;
    },
    querySelectorAll: (sel) => {
      if (sel === 'button') {
        const all = [clearBtn, typeExpand, rangeClear, recentThirty];
        for (const el of elements.values()) all.push(...el.querySelectorAll('button'));
        return all;
      }
      return [];
    },
    createElement: (tag) => new MockElement(tag),
    addEventListener: (evt, fn) => {
      if (!listeners.has(evt)) listeners.set(evt, []);
      listeners.get(evt).push(fn);
    },
    body: { classList: new MockElement('body').classList }
  };

  const windowMock = {
    orgMuseumDashboard: null,
    addEventListener: (evt, fn) => {
      if (!listeners.has(evt)) listeners.set(evt, []);
      listeners.get(evt).push(fn);
    }
  };

  const sandbox = {
    document: documentMock,
    window: windowMock,
    location: { search: '', pathname: '/index.html', href: 'http://localhost/index.html', hash: '' },
    history: {
      pushState: (_s, _t, url) => {
        sandbox.location.href = new URL(url, 'http://localhost').href;
        sandbox.location.search = new URL(url, 'http://localhost').search;
      },
      replaceState: (_s, _t, url) => {
        sandbox.location.href = new URL(url, 'http://localhost').href;
        sandbox.location.search = new URL(url, 'http://localhost').search;
      }
    },
    URL: URL,
    URLSearchParams: URLSearchParams,
    Intl: Intl,
    Date: Date,
    Math: Math,
    String: String,
    Number: Number,
    Array: Array,
    Set: Set,
    Boolean: Boolean,
    requestAnimationFrame: (cb) => cb(),
    console: console,
    indexedDB: {
      open: () => ({
        onupgradeneeded: () => {},
        onsuccess: () => {},
        onerror: () => {}
      })
    }
  };

  vm.createContext(sandbox);
  vm.runInContext(dashboardCode, sandbox);

  return {
    state: sandbox.window.orgMuseumDashboard,
    elements,
    metrics: {
      total: metricTotal,
      created: metricCreated,
      updated: metricUpdated,
      labelCreated: metricLabelCreated,
      labelUpdated: metricLabelUpdated
    },
    clearBtn,
    search,
    typeChart,
    trendChart,
    summaryChips,
    resultList,
    recentSeven,
    recentThirty,
    recentNinety,
    recentHalfYear,
    recentOneYear
  };
}

console.log('--- TEST 1: Initial load & metrics reflection ---');
const env = createMockEnvironment(initialPages);
const state = env.state;

assert.equal(state.sourceData.length, 5);
assert.equal(state.filteredData.length, 5);
assert.equal(env.metrics.total.textContent, '5');
// In our dataset:
// created in last 30 days (ref: 2026-09-27): duckdb-intro (09-01), duckdb-adv (09-05), duckdb-in-lisp (09-15) = 3
// modified in last 30 days: 4 notes
assert.equal(env.metrics.created.textContent, '3');
assert.equal(env.metrics.updated.textContent, '4');
assert.equal(env.metrics.labelCreated.textContent, '近 30 天新增');
assert.equal(env.metrics.labelUpdated.textContent, '近 30 天更新');
console.log('✓ Initial metrics match dataset: 5 total, 3 recent created, 4 recent updated, default 30-day labels');

console.log('--- TEST 2: Dynamic filterSchema generated from real data ---');
assert.deepEqual(Object.keys(state.filterSchema).sort(), ['category', 'project', 'status', 'tags', 'type'].filter(k => state.filterSchema[k]).sort());
assert.deepEqual(state.filterSchema.category, ['Lisp', 'Sql']);
assert.deepEqual(state.filterSchema.status, ['draft', 'published']);
assert.equal(state.filterSchema.project, undefined, 'Project should not exist since no note has project');
assert.equal(state.filterSchema.type, undefined, 'Type should not exist since no note has type');
console.log('✓ Dynamic schema accurately detects existing dimensions and prunes empty ones');

console.log('--- TEST 3: Acceptance flow Step 1: Search "DuckDB" ---');
// User types "DuckDB" into search
env.search.value = 'DuckDB';
env.search.listeners.get('input')[0]();

assert.equal(state.filteredData.length, 3, '3 DuckDB notes should match');
assert.equal(env.metrics.total.textContent, '3');
assert.equal(env.resultList.children.length, 3);
// Topic distribution should now show 2 Sql and 1 Lisp
const distMap = Object.fromEntries(state.aggregations.typeDistribution.map(x => [x.value, x.count]));
assert.equal(distMap['Sql'], 2);
assert.equal(distMap['Lisp'], 1);
console.log('✓ Searching DuckDB updates metrics, topic chart, and note results');

console.log('--- TEST 4: Acceptance flow Step 2: Click Topic "SQL" ---');
// Find SQL button in typeChart and click it
const sqlRow = env.typeChart.children.find(r => r.dataset.chartType === 'Sql');
assert(sqlRow, 'SQL row must exist in distribution chart');
sqlRow.click();

assert.equal(state.filters.dimensions.category.length, 1);
assert.equal(state.filters.dimensions.category[0], 'Sql');
assert.equal(state.filters.dimensions.topic[0], 'Sql', 'topic property mirrors category');
assert.equal(state.filteredData.length, 2, 'Results narrowed to 2 SQL notes');
assert.equal(env.metrics.total.textContent, '2');
// Topic SQL row has is-active class and aria-pressed="true"
const updatedSqlRow = env.typeChart.children.find(r => r.dataset.chartType === 'Sql');
assert.equal(updatedSqlRow.getAttribute('aria-pressed'), 'true');
assert(updatedSqlRow.className.includes('is-active'));
console.log('✓ Clicking SQL in chart narrows results and highlights row');

console.log('--- TEST 5: Acceptance flow Step 3: Select "近 30 天" ---');
env.recentThirty.click();
assert(state.filters.timeRange !== null, 'timeRange should be set');
assert.equal(env.recentThirty.getAttribute('aria-pressed'), 'true');
assert.equal(state.filteredData.length, 2, 'Both DuckDB SQL notes are within last 30 days');
console.log('✓ Selecting recent 30 days synchronizes all regions');

console.log('--- TEST 6: Acceptance flow Step 4: Deselect SQL from chip ---');
// Active chips should contain: search, category Sql, timeRange
const chips = env.summaryChips.children;
const sqlChip = chips.find(c => c.dataset.chipKey === 'category' && c.dataset.chipValue === 'Sql');
assert(sqlChip, 'Active chip for SQL must exist');
sqlChip.click();

assert.equal(state.filters.dimensions.category.length, 0);
assert.equal(state.filteredData.length, 3, 'Restores to all 3 DuckDB notes in last 30 days');
const restoredSqlRow = env.typeChart.children.find(r => r.dataset.chartType === 'Sql');
assert.equal(restoredSqlRow.getAttribute('aria-pressed'), 'false');
console.log('✓ Deselecting SQL chip restores category selection across chart and results');

console.log('--- TEST 7: Acceptance flow Step 5: Clear All ---');
env.clearBtn.click();
assert.equal(state.filters.keyword, '');
assert.equal(state.filters.timeRange, null);
assert.equal(state.filters.dimensions.category.length, 0);
assert.equal(state.filteredData.length, 5, 'Restored to all 5 notes');
assert.equal(env.metrics.total.textContent, '5');
console.log('✓ Clear All fully restores all filters, charts, metrics, and note list');

console.log('--- TEST 8: Data changes: Add note ---');
const newNote = {
  pageId: 'duckdb-spatial',
  title: 'DuckDB 空间计算',
  category: 'Sql',
  categoryLabel: 'SQL',
  tags: ['duckdb', 'gis', 'spatial'],
  status: 'published',
  created: 1790000000,
  createdDate: '2026-09-27',
  modified: 1790000000,
  modifiedDate: '2026-09-27',
  href: 'pages/duckdb-spatial.html'
};
state.setSourceData([...initialPages, newNote]);
assert.equal(state.sourceData.length, 6);
assert.equal(state.filteredData.length, 6);
assert(state.filterSchema.tags.includes('spatial'));
assert.equal(env.metrics.total.textContent, '6');
console.log('✓ Adding note updates sourceData, schema, metrics, and note count');

console.log('--- TEST 9: Data changes: Delete note & prune invalid filter ---');
// Select tag 'spatial'
state.filters.dimensions.tags = ['spatial'];
state.refresh();
assert.equal(state.filteredData.length, 1);

// Now simulate deleting duckdb-spatial
state.setSourceData(initialPages); // spatial note deleted
assert.equal(state.sourceData.length, 5);
assert.equal(state.filterSchema.tags.includes('spatial'), false, 'spatial tag must disappear from schema');
assert.equal(state.filters.dimensions.tags.length, 0, 'invalid spatial filter must be pruned automatically');
assert.equal(state.filteredData.length, 5, 'Results recovered after pruning invalid filter');
console.log('✓ Deleting note prunes schema options and clears stale filter condition');

console.log('--- TEST 10: Empty results handling ---');
env.search.value = 'NonExistentNote123';
env.search.listeners.get('input')[0]();
assert.equal(state.filteredData.length, 0);
assert.equal(env.metrics.total.textContent, '0');
assert.equal(env.metrics.created.textContent, '0');
assert.equal(env.metrics.updated.textContent, '0');
assert.equal(env.elements.get('index-search-empty').hidden, false, 'Empty notice shown');
assert(env.typeChart.textContent.includes('当前条件下没有主题数据'));
assert(env.trendChart.textContent.includes('当前条件下没有时间数据'));
// Filter chips still present
assert(env.summaryChips.children.some(c => c.dataset.chipKey === 'keyword'));
console.log('✓ Zero-result state cleanly sets metrics to 0, chart empty states, and preserves filter removal capabilities');

console.log('--- TEST 11: Trend chart bars display corresponding label values ---');
const trendEnv = createMockEnvironment(initialPages);
const bins = trendEnv.state.aggregations.timeTrend;
assert(bins.length > 0, 'Bins should be generated for time trend');

const trendBins = trendEnv.trendChart.children.filter(c => c.dataset.trendIndex !== undefined);
assert.equal(trendBins.length, bins.length, 'Trend chart should have matching bin count');

trendBins.forEach((binEl, idx) => {
  const bin = bins[idx];
  const columns = binEl.children.find(c => c.className === 'dashboard-trend-columns');
  assert(columns, 'Bin should contain columns container');

  const createdBar = columns.children.find(c => c.className === 'dashboard-trend-created');
  const updatedBar = columns.children.find(c => c.className === 'dashboard-trend-updated');
  assert(createdBar, 'Columns should contain createdBar');
  assert(updatedBar, 'Columns should contain updatedBar');

  assert.equal(createdBar.dataset.value, String(bin.created));
  assert.equal(createdBar.dataset.label, String(bin.created));
  assert.equal(createdBar.title, '新增：' + bin.created);

  assert.equal(updatedBar.dataset.value, String(bin.updated));
  assert.equal(updatedBar.dataset.label, String(bin.updated));
  assert.equal(updatedBar.title, '更新：' + bin.updated);

  const createdVal = createdBar.children.find(c => c.className && c.className.includes('dashboard-trend-value'));
  const updatedVal = updatedBar.children.find(c => c.className && c.className.includes('dashboard-trend-value'));
  assert(createdVal, 'createdBar must have label child element');
  assert(updatedVal, 'updatedBar must have label child element');

  assert.equal(createdVal.textContent, String(bin.created));
  assert.equal(updatedVal.textContent, String(bin.updated));
});
console.log('✓ Trend chart bars display corresponding label values for both created and updated series');

console.log('--- TEST 12: Multiple time ranges (7, 30, 90, 180, 365 days) query and shortcut synchronization ---');
const dateEnv = createMockEnvironment(initialPages);
const dState = dateEnv.state;

// 1. Click "近 7 天"
dateEnv.recentSeven.click();
assert(dState.filters.timeRange !== null, 'timeRange should be active for 7 days');
assert.equal(dateEnv.recentSeven.getAttribute('aria-pressed'), 'true');
assert.equal(dateEnv.recentThirty.getAttribute('aria-pressed'), 'false');
let timeChip = dateEnv.summaryChips.children.find(c => c.dataset.chipKey === 'timeRange');
assert(timeChip, 'TimeRange chip must exist');
assert.equal(timeChip.textContent, '时间：最近 7 天 ×');
assert.equal(dState.filteredData.length, 3, 'Notes within 7 days are the 3 most recently modified');
assert.equal(dateEnv.metrics.labelCreated.textContent, '近 7 天新增');
assert.equal(dateEnv.metrics.labelUpdated.textContent, '近 7 天更新');
assert.equal(dateEnv.metrics.created.textContent, '0', '0 notes created within 7 days');
assert.equal(dateEnv.metrics.updated.textContent, '3', '3 notes updated within 7 days');
assert.equal(dState.aggregations.timeTrend.length, 7, '7 days range produces 7 daily bins for chart space');

// 2. Click "近 90 天" (switches to 90 days)
dateEnv.recentNinety.click();
assert.equal(dateEnv.recentSeven.getAttribute('aria-pressed'), 'false');
assert.equal(dateEnv.recentNinety.getAttribute('aria-pressed'), 'true');
assert.equal(dateEnv.recentThirty.getAttribute('aria-pressed'), 'false');
timeChip = dateEnv.summaryChips.children.find(c => c.dataset.chipKey === 'timeRange');
assert.equal(timeChip.textContent, '时间：最近 90 天 ×');
assert.equal(dState.filteredData.length, 5, 'All notes in dataset fall within 90 days');
assert.equal(dateEnv.metrics.labelCreated.textContent, '近 90 天新增');
assert.equal(dateEnv.metrics.labelUpdated.textContent, '近 90 天更新');
assert.equal(dateEnv.metrics.created.textContent, '3', '3 notes created within 90 days');
assert.equal(dateEnv.metrics.updated.textContent, '5', '5 notes updated within 90 days');

// 3. Click "近半年" (180 days)
dateEnv.recentHalfYear.click();
assert.equal(dateEnv.recentNinety.getAttribute('aria-pressed'), 'false');
assert.equal(dateEnv.recentHalfYear.getAttribute('aria-pressed'), 'true');
timeChip = dateEnv.summaryChips.children.find(c => c.dataset.chipKey === 'timeRange');
assert.equal(timeChip.textContent, '时间：最近半年 ×');
assert.equal(dateEnv.metrics.labelCreated.textContent, '近半年新增');
assert.equal(dateEnv.metrics.labelUpdated.textContent, '近半年更新');
assert.equal(dateEnv.metrics.created.textContent, '5', 'All 5 notes created within 180 days');
assert.equal(dateEnv.metrics.updated.textContent, '5', 'All 5 notes updated within 180 days');

// 4. Click "近 1 年" (365 days)
dateEnv.recentOneYear.click();
assert.equal(dateEnv.recentHalfYear.getAttribute('aria-pressed'), 'false');
assert.equal(dateEnv.recentOneYear.getAttribute('aria-pressed'), 'true');
timeChip = dateEnv.summaryChips.children.find(c => c.dataset.chipKey === 'timeRange');
assert.equal(timeChip.textContent, '时间：最近 1 年 ×');
assert.equal(dState.filteredData.length, 5, 'All notes are within 1 year');
assert.equal(dateEnv.metrics.labelCreated.textContent, '近 1 年新增');
assert.equal(dateEnv.metrics.labelUpdated.textContent, '近 1 年更新');
assert.equal(dateEnv.metrics.created.textContent, '5', '5 notes created within 1 year');
assert.equal(dateEnv.metrics.updated.textContent, '5', '5 notes updated within 1 year');

// 5. Click "近 1 年" again de-selects it
dateEnv.recentOneYear.click();
assert.equal(dState.filters.timeRange, null, 'timeRange should be cleared after re-clicking');
assert.equal(dateEnv.recentOneYear.getAttribute('aria-pressed'), 'false');
timeChip = dateEnv.summaryChips.children.find(c => c.dataset.chipKey === 'timeRange');
assert(!timeChip, 'TimeRange chip should be removed');
assert.equal(dateEnv.metrics.labelCreated.textContent, '近 30 天新增');
assert.equal(dateEnv.metrics.labelUpdated.textContent, '近 30 天更新');
assert.equal(dateEnv.metrics.created.textContent, '3');
assert.equal(dateEnv.metrics.updated.textContent, '4');
console.log('✓ Multiple time ranges (7d, 30d, 90d, 180d, 365d) switch, toggle, and synchronize metrics + labels + chart space correctly');

console.log('--- TEST 13: Timezone UTC vs local date alignment without off-by-one future day ---');
// Real-world reproduction: build time generated in UTC after 00:00 UTC (e.g. 2026-10-02T00:32:02+0000)
// while local notes and user local date are 2026-10-01.
const tzPages = [
  {
    pageId: 'note-1',
    title: 'Note 1',
    category: 'AI',
    categoryLabel: 'AI',
    description: 'Note 1 description',
    tags: ['ai'],
    status: 'published',
    headings: [],
    created: 1790901122,
    createdDate: '2026-10-01',
    dateSource: 'org-date',
    modified: 1790901122,
    modifiedDate: '2026-10-01',
    href: 'pages/note-1.html'
  },
  {
    pageId: 'note-2',
    title: 'Note 2',
    category: 'SQL',
    categoryLabel: 'SQL',
    description: 'Note 2 description',
    tags: ['sql'],
    status: 'draft',
    headings: [],
    created: 1790901122,
    createdDate: '2026-09-26',
    dateSource: 'org-date',
    modified: 1790901122,
    modifiedDate: '2026-10-01',
    href: 'pages/note-2.html'
  }
];

const tzEnv = createMockEnvironment(tzPages, '2026-10-02T00:32:02+0000');
const tzState = tzEnv.state;

// 1. Click "近 7 天"
tzEnv.recentSeven.click();
assert(tzState.filters.timeRange !== null, 'timeRange should be active');
// End date must NOT be 2026-10-02 (the UTC tomorrow)
assert.equal(tzState.filters.timeRange.end, '2026-10-01', 'End date must align with local note date 2026-10-01, not 2026-10-02');
assert.equal(tzState.filters.timeRange.start, '2026-09-25', 'Start date for 7d should be 2026-09-25');
assert.equal(tzEnv.elements.get('index-date-end').value, '2026-10-01', 'Input date-end must be 2026-10-01');

// 2. Trend chart bins should end on 2026-10-01 and contain no bin for 2026-10-02
const tzTrendBins = tzState.aggregations.timeTrend;
assert.equal(tzTrendBins.length, 7, 'Trend chart should have 7 bins');
assert.equal(tzTrendBins[tzTrendBins.length - 1].start, '2026-10-01');
assert.equal(tzTrendBins[tzTrendBins.length - 1].end, '2026-10-01');
assert(tzTrendBins.every(b => b.start <= '2026-10-01'), 'No future bins beyond 2026-10-01');

// 3. Topic distribution should properly reflect categories of matched notes
const tzTopics = tzState.aggregations.typeDistribution;
assert(tzTopics.some(t => t.value === 'AI' && t.count === 1), 'AI category mapped correctly');
assert(tzTopics.some(t => t.value === 'SQL' && t.count === 1), 'SQL category mapped correctly');
console.log('✓ Timezone UTC vs local date alignment: no extra future day in filters, trend chart, or topic distribution');

// --- TEST 14: Beautified tag chips in index results ---
console.log('--- TEST 14: Beautified tag chips in index results ---');
const tagChips = tzEnv.resultList.querySelectorAll('.museum-tag-chip');
assert(tagChips.length >= 2, 'Tag chips should be rendered for notes with tags');
const aiChip = tagChips.find(c => c.dataset.tag === 'ai');
assert(aiChip, 'Note 1 tag chip for "ai" should be rendered');
assert.equal(aiChip.tagName, 'BUTTON', 'Tag chip should be an accessible button');
assert(aiChip.textContent.includes('#'), 'Tag chip should include # prefix');
assert(aiChip.textContent.includes('ai'), 'Tag chip should include tag name');

// Click tag chip to filter
aiChip.click();
assert(tzState.filters.dimensions.tags.includes('ai'), 'Clicking tag chip should filter by tag');
const activeChips = tzEnv.resultList.querySelectorAll('.museum-tag-chip');
const activeAiChip = activeChips.find(c => c.dataset.tag === 'ai');
assert(activeAiChip, 'Active tag chip should exist in re-rendered results');
assert.equal(activeAiChip.getAttribute('aria-pressed'), 'true', 'Active tag chip should have aria-pressed="true"');
console.log('✓ Beautified tag chips in index search results rendered and interactive');

console.log('--- TEST 15: Reversed dates preserve applied filters and report an error ---');
const invalidDateEnv = createMockEnvironment(initialPages);
const startInput = invalidDateEnv.elements.get('index-date-start');
const endInput = invalidDateEnv.elements.get('index-date-end');
startInput.value = '2026-09-20';
endInput.value = '2026-09-01';
endInput.listeners.get('change').forEach(handler => handler());
assert.equal(invalidDateEnv.state.filters.timeRange, null, 'Invalid dates must not change the applied filter');
assert.equal(endInput.value, '2026-09-01', 'Do not silently replace the entered end date');
assert.equal(endInput.getAttribute('aria-invalid'), 'true');
assert(endInput.validationMessage.includes('结束日期'));
endInput.value = '2026-09-25';
endInput.listeners.get('change').forEach(handler => handler());
assert.equal(invalidDateEnv.state.filters.timeRange.end, '2026-09-25');
assert.equal(endInput.getAttribute('aria-invalid'), 'false');
assert.equal(endInput.validationMessage, '');
console.log('✓ Invalid range reported; corrected range applied');

console.log('\n========================================');
console.log('ALL DASHBOARD INTEGRATION TESTS PASSED!');
console.log('========================================');
