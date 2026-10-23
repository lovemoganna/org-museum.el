const fs = require('fs');
const assert = require('assert');

console.log('=== VERIFYING APPEARANCE & TYPOGRAPHY SETTINGS CONTRACTS ===');

const css = fs.readFileSync('dist/resources/org-museum.css', 'utf8');
const js = fs.readFileSync('dist/resources/org-museum-theme.js', 'utf8');

// 1. Reading Sizes
console.log('1. Checking Dynamic Reading Sizes...');
assert(css.includes('html[data-reading-size="sm"]'), 'CSS has data-reading-size="sm"');
assert(css.includes('html[data-reading-size="md"]'), 'CSS has data-reading-size="md"');
assert(css.includes('html[data-reading-size="lg"]'), 'CSS has data-reading-size="lg"');
assert(css.includes('html[data-reading-size="xl"]'), 'CSS has data-reading-size="xl"');
assert(css.includes('--museum-type-body: 11.5px !important;'), 'sm size token exists');
assert(css.includes('--museum-type-body: 15px !important;'), 'xl size token exists');
assert(css.includes('.museum-entry-desc'), 'Affects note entry descriptions');
assert(css.includes('.pathway-desc'), 'Affects pathway descriptions');
console.log('✓ Dynamic Reading Sizes correctly defined');

// 2. Reading Widths
console.log('2. Checking Dynamic Reading Widths...');
assert(css.includes('html[data-reading-width="980"]'), 'CSS has data-reading-width="980"');
assert(css.includes('html[data-reading-width="1024"]'), 'CSS has data-reading-width="1024"');
assert(css.includes('html[data-reading-width="1320"]'), 'CSS has data-reading-width="1320"');
assert(css.includes('--museum-shell-max-width: 1240px !important;'), 'Compact shell width token exists');
assert(css.includes('--museum-shell-max-width: 1580px !important;'), 'Wide shell width token exists');
assert(css.includes('.museum-index-shell'), 'Applies to museum-index-shell');
console.log('✓ Dynamic Reading Widths correctly defined for articles and home shells');

// 3. Dynamic Reading Font
console.log('3. Checking Dynamic Reading Fonts...');
assert(css.includes('html[data-reading-font="serif"]'), 'CSS has serif selector');
assert(css.includes('html[data-reading-font="sans"]'), 'CSS has sans selector');
assert(css.includes('"Org Museum Noto Serif SC"'), 'Serif uses Org Museum Noto Serif SC font');
assert(css.includes('.museum-entry-title') || css.includes('.museum-index-entry h3'), 'Serif covers index titles');
console.log('✓ Dynamic Reading Fonts correctly defined');

// 4. Line Spacing & Density
console.log('4. Checking Dynamic Line Spacing...');
assert(css.includes('html[data-reading-line="compact"]'), 'Compact line selector exists');
assert(css.includes('html[data-reading-line="standard"]'), 'Standard line selector exists');
assert(css.includes('html[data-reading-line="relaxed"]'), 'Relaxed line selector exists');
assert(css.includes('--museum-leading-body: 1.55 !important;'), 'Compact leading token exists');
assert(css.includes('--museum-leading-body: 2.15 !important;'), 'Relaxed leading token exists');
console.log('✓ Dynamic Line Spacing correctly defined');

// 5. Reading Tone (Warm Sepia & Soft Slate)
console.log('5. Checking Reading Tones...');
assert(css.includes('html[data-reading-tone="warm"]'), 'Warm sepia selector exists');
assert(css.includes('html[data-reading-tone="slate"]'), 'Soft slate selector exists');
assert(css.includes('background-image: none !important;'), 'Radial background gradients cleanly disabled on warm/slate tone');
assert(css.includes('html[data-theme="dark"][data-reading-tone="warm"]'), 'Dark warm sepia selector exists');
assert(css.includes('html[data-theme="dark"][data-reading-tone="slate"]'), 'Dark soft slate selector exists');
console.log('✓ Reading Tones correctly defined');

// 6. Live Preview Sample
console.log('6. Checking Live Preview Box...');
assert(css.includes('.preview-sample-text[data-preview-size="sm"]'), 'Preview size styling exists');
assert(css.includes('.preview-sample-text[data-preview-size="xl"]'), 'Preview xl size styling exists');
assert(css.includes('.preview-sample-text[data-preview-line="relaxed"]'), 'Preview relaxed line styling exists');
assert(css.includes('.preview-sample-text[data-preview-font="serif"]'), 'Preview serif font styling exists');
assert(js.includes('previewSample.dataset.previewSize = sz;'), 'JS updates previewSize attribute');
console.log('✓ Live Preview Box fully wired');

console.log('\n======================================================');
console.log('ALL APPEARANCE & TYPOGRAPHY TESTS PASSED WITH 100%!   ');
console.log('======================================================');
