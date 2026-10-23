const fs = require('fs');
const assert = require('assert');

// 1. Verify CSS rules in dist/resources/org-museum.css
const css = fs.readFileSync('dist/resources/org-museum.css', 'utf8');

assert(css.includes('html[data-reading-tone="warm"]'), 'CSS must include warm sepia tone');
assert(css.includes('html[data-reading-tone="slate"]'), 'CSS must include soft slate tone');
assert(css.includes('html[data-reading-size="sm"]'), 'CSS must include sm reading size');
assert(css.includes('html[data-reading-size="xl"]'), 'CSS must include xl reading size');
assert(css.includes('html[data-reading-width="980"]'), 'CSS must include 980 width');
assert(css.includes('html[data-reading-width="1024"]'), 'CSS must include 1024 width');
assert(css.includes('html[data-reading-font="serif"]'), 'CSS must include serif font rule');
assert(css.includes('html[data-reading-line="relaxed"]'), 'CSS must include relaxed line height');
assert(css.includes('html[data-code-lineno="true"]'), 'CSS must include code line numbers toggle on');
assert(css.includes('html[data-code-lineno="false"]'), 'CSS must include code line numbers toggle off');
assert(css.includes('html[data-active-recall="true"]'), 'CSS must include active recall cloze');
assert(css.includes('html[data-beginner-mode="true"]'), 'CSS must include beginner mode badges');
assert(css.includes('html[data-zen-mode="true"]'), 'CSS must include zen mode styling');

// 2. Verify JS functions in dist/resources/org-museum-theme.js
const themeJs = fs.readFileSync('dist/resources/org-museum-theme.js', 'utf8');

assert(themeJs.includes('applyReadingPreferences'), 'Theme JS must include applyReadingPreferences');
assert(themeJs.includes('applyLearningPreferences'), 'Theme JS must include applyLearningPreferences');
assert(themeJs.includes('bindReadingSettings'), 'Theme JS must include bindReadingSettings');
assert(themeJs.includes('bindLearningSettings'), 'Theme JS must include bindLearningSettings');
assert(themeJs.includes('bindDataSettings'), 'Theme JS must include bindDataSettings');
assert(themeJs.includes('initHoverPreview'), 'Theme JS must include initHoverPreview');
assert(themeJs.includes('initActiveRecall'), 'Theme JS must include initActiveRecall');

// 3. Verify HTML files have clean, full 4-tab panel structure with learning assistance and presets
const htmlFiles = [
  'dist/index.html',
  'dist/timeline.html',
  'dist/graph.html',
  'dist/related.html',
  'dist/ai-center.html',
  'dist/pages/Emacs/Org/org-babel-01-execution-foundations.html'
];

for (const hf of htmlFiles) {
  const content = fs.readFileSync(hf, 'utf8');
  assert(content.includes('data-settings-tab="appearance"'), `${hf} missing appearance tab`);
  assert(content.includes('data-settings-tab="learning"'), `${hf} missing learning tab`);
  assert(content.includes('data-settings-panel="learning"'), `${hf} missing learning panel`);
  assert(content.includes('data-settings-tab="ai"'), `${hf} missing ai tab`);
  assert(content.includes('data-settings-tab="data"'), `${hf} missing data tab`);
  assert(content.includes('data-preset-scene="eyecare"'), `${hf} missing scene presets`);
  assert(content.includes('data-beginner-mode-toggle'), `${hf} missing beginner mode toggle`);
  assert(content.includes('data-hover-preview-toggle'), `${hf} missing hover preview toggle`);
  assert(content.includes('data-code-lineno-toggle'), `${hf} missing code lineno toggle`);
  assert(content.includes('data-active-recall-toggle'), `${hf} missing active recall toggle`);
  assert(content.includes('data-zen-mode-toggle'), `${hf} missing zen mode toggle`);
  assert(content.includes('museum-glossary-details'), `${hf} missing pocket glossary`);
  assert(content.includes('data-learning-quest-card'), `${hf} missing learning quest card`);
  assert(content.includes('data-restore-guides'), `${hf} missing restore guides button`);
  assert(content.includes('museum-shortcuts-grid'), `${hf} missing shortcuts grid`);
  assert(content.includes('data-reading-tone="warm"'), `${hf} missing reading tone warm`);
  assert(content.includes('data-reading-tone="slate"'), `${hf} missing reading tone slate`);
  assert(content.includes('data-reading-size="xl"'), `${hf} missing reading size xl`);
  assert(content.includes('data-reading-width="1024"'), `${hf} missing reading width 1024`);
  assert(content.includes('data-ai-preset-select'), `${hf} missing ai preset select`);
  assert(content.includes('data-toggle-key-visibility'), `${hf} missing toggle key visibility`);
  assert(content.includes('data-remember-key'), `${hf} missing remember key`);
  assert(content.includes('data-browser-quick-test'), `${hf} missing quick test greeting button`);
  assert(content.includes('data-reset-appearance-only'), `${hf} missing reset appearance button`);
  assert(content.includes('data-reset-all-settings'), `${hf} missing reset all button`);
}

console.log('ALL DIST VERIFICATION ASSERTIONS PASSED (100% COVERAGE)!');
