// Run with: node test/org-museum-visual-spec-test.js
const assert = require('node:assert/strict');
const path = require('node:path');
const Visual = require('../resources/org-museum-visual-spec.js');

console.log('=== TEST SUITE: Org Museum Visual Specification & Formatter ===\n');

// ------------------------------------------------------------------
// 1. Formatter: formatNumber
// ------------------------------------------------------------------
console.log('--- TEST 1: Formatter.formatNumber ---');
const fmt = Visual.Formatter;

assert.equal(fmt.formatNumber(0), '0');
assert.equal(fmt.formatNumber(42), '42');
assert.equal(fmt.formatNumber(1234), '1,234');
assert.equal(fmt.formatNumber(1234567), '1,234,567');
assert.equal(fmt.formatNumber(-9876), '-9,876');

// Decimals
assert.equal(fmt.formatNumber(12.3456, { decimals: 2 }), '12.35');
assert.equal(fmt.formatNumber(1234.5, { decimals: 2 }), '1,234.50');

// Short abbreviations (K / M / B)
assert.equal(fmt.formatNumber(12400, { short: true }), '12.4K');
assert.equal(fmt.formatNumber(1200000, { short: true }), '1.2M');
assert.equal(fmt.formatNumber(3500000000, { short: true }), '3.5B');
assert.equal(fmt.formatNumber(500, { short: true }), '500');

// Fallbacks for null / undefined / NaN / non-finite
assert.equal(fmt.formatNumber(null), '0');
assert.equal(fmt.formatNumber(undefined), '0');
assert.equal(fmt.formatNumber('invalid-number'), '0');
assert.equal(fmt.formatNumber(NaN), '0');
assert.equal(fmt.formatNumber(Infinity, { fallback: '--' }), '--');

console.log('✓ Formatter.formatNumber passes all standard, grouped, short and fallback assertions');

// ------------------------------------------------------------------
// 2. Formatter: formatPercent
// ------------------------------------------------------------------
console.log('\n--- TEST 2: Formatter.formatPercent ---');

assert.equal(fmt.formatPercent(23.6, 100), '23.6%');
assert.equal(fmt.formatPercent(1, 3, 2), '33.33%');
assert.equal(fmt.formatPercent(50, 100, 0), '50%');

// Zero or invalid denominator
assert.equal(fmt.formatPercent(10, 0), '0.0%');
assert.equal(fmt.formatPercent(0, 0), '0.0%');
assert.equal(fmt.formatPercent(null, null), '0.0%');
assert.equal(fmt.formatPercent(10, -5), '0.0%');

console.log('✓ Formatter.formatPercent handles precise percentages and zero-denominator safely');

// ------------------------------------------------------------------
// 3. Formatter: formatValueWithUnit & formatDateRange
// ------------------------------------------------------------------
console.log('\n--- TEST 3: Formatter.formatValueWithUnit & formatDateRange ---');

assert.equal(fmt.formatValueWithUnit(42, '篇'), '42 篇');
assert.equal(fmt.formatValueWithUnit(1200, '篇'), '1,200 篇');
assert.equal(fmt.formatValueWithUnit(85.5, '%'), '85.5%');
assert.equal(fmt.formatValueWithUnit(500, '¥'), '¥500');

assert.equal(fmt.formatDateRange('2026-09-01', '2026-09-30'), '2026-09-01 ~ 2026-09-30');
assert.equal(fmt.formatDateRange('2026-09-01', '2026-09-01'), '2026-09-01');
assert.equal(fmt.formatDateRange('2026-09-01', ''), '2026-09-01 至今');
assert.equal(fmt.formatDateRange('', ''), '全部时间');

console.log('✓ Units and date ranges formatted with standard typography');

// ------------------------------------------------------------------
// 4. ChartSpec: computeAxisScale
// ------------------------------------------------------------------
console.log('\n--- TEST 4: ChartSpec.computeAxisScale ---');
const spec = Visual.ChartSpec;

const scale1 = spec.computeAxisScale(2);
assert.equal(scale1.ceiling, 3);
assert.deepEqual(scale1.ticks, [3, 2, 0]);

const scale2 = spec.computeAxisScale(5);
assert.equal(scale2.ceiling, 6);
assert.deepEqual(scale2.ticks, [6, 3, 0]);

const scale3 = spec.computeAxisScale(18);
assert.equal(scale3.ceiling, 20);
assert.deepEqual(scale3.ticks, [20, 10, 0]);

const scaleZero = spec.computeAxisScale(0);
assert.equal(scaleZero.ceiling, 1);

console.log('✓ Axis scales calculate aligned zero-axis steps and clean round ceilings');

// ------------------------------------------------------------------
// 5. ChartSpec: computeLabelLayout (Smart Avoidance)
// ------------------------------------------------------------------
console.log('\n--- TEST 5: ChartSpec.computeLabelLayout (Label Avoidance & Submerging) ---');

// 1) Zero value: hidden
const zeroLayout = spec.computeLabelLayout({ barHeight: 0, containerHeight: 110, value: 0 });
assert.equal(zeroLayout.placement, 'hidden');

// 2) Short bar (< 28px): must be placed outside above bar
const shortLayout = spec.computeLabelLayout({ barHeight: 15, containerHeight: 110, value: 1 });
assert.equal(shortLayout.placement, 'outside');
assert.equal(shortLayout.isOutside, true);

// 3) Tall bar near ceiling (containerHeight: 110, barHeight: 100): must be submerged inside top to prevent overflow
const tallLayout = spec.computeLabelLayout({ barHeight: 98, containerHeight: 110, value: 10 });
assert.equal(tallLayout.placement, 'top-submerged');
assert.equal(tallLayout.isOutside, false);

// 4) Medium bar: normal outside
const mediumLayout = spec.computeLabelLayout({ barHeight: 50, containerHeight: 110, value: 5 });
assert.equal(mediumLayout.placement, 'outside');
assert.equal(mediumLayout.isOutside, true);

console.log('✓ Label layout avoids container boundary overflow and prevents truncation');

// ------------------------------------------------------------------
// 6. ChartSpec: buildTooltipText
// ------------------------------------------------------------------
console.log('\n--- TEST 6: ChartSpec.buildTooltipText ---');

const tooltip = spec.buildTooltipText({
  title: '日期：2026-09-20',
  items: [
    { label: '新增', value: 3, unit: '篇' },
    { label: '更新', value: 4, unit: '篇' }
  ]
});
assert.equal(tooltip, '日期：2026-09-20 · 新增：3 篇 · 更新：4 篇');

const categoryTooltip = spec.buildTooltipText({
  title: 'SQL 主题',
  items: [
    { label: '数量', value: 12, unit: '篇', percent: '40.0%' }
  ]
});
assert.equal(categoryTooltip, 'SQL 主题 · 数量：12 篇 (40.0%)');

console.log('✓ Structured tooltip formats dimension, metrics, unit and percentage consistently');

console.log('\n=============================================');
console.log('ALL VISUAL SPEC & FORMATTER TESTS PASSED! (7/7)');
console.log('=============================================');
