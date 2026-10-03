const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'dist', 'resources', 'org-museum-graph.js'), 'utf8');
const start = source.indexOf('function applyAutoLayout(){');
const end = source.indexOf('\nfunction setLayoutMode(mode){', start);
assert(start >= 0 && end > start, 'exported layout function exists');
const layoutSource = source.slice(start, end);
const modes = ['semantic', 'dagre', 'treeVertical', 'treeHorizontal', 'organic',
  'clusteredForce', 'groupedCircular', 'concentric', 'starburst', 'dandelion', 'spoke', 'grid'];
const names = 'ABCDEFGHIJKLMNO'.split('');
const edgePairs = [['A', 'B'], ['A', 'C'], ['B', 'D'], ['C', 'D'], ['D', 'E'],
  ['E', 'F'], ['F', 'C'], ['G', 'H'], ['H', 'I'], ['I', 'J'], ['J', 'K'], ['K', 'G'],
  ['E', 'L'], ['L', 'M'], ['M', 'N'], ['N', 'O'], ['O', 'G']];
const signatures = new Set();

for (const mode of modes) {
  const nodes = names.map((id, index) => ({id, name: id, group: ['读书', '编程', '写作'][index % 3],
    labelWidth: 96, degree: 2}));
  const links = edgePairs.map(([source, target]) => ({source, target}));
  const context = {canvasNodes: nodes, links, state: {layout: mode}, manualPositions: {},
    width: 1100, height: 750, activeNeighborhood: null, matches: () => true,
    visibleEdge: () => true, renderTick: () => {}, fitView: () => {}, Map, Set, Math,
    Number, Array, Object};
  vm.runInNewContext(layoutSource + '\napplyAutoLayout();', context, {timeout: 2000});
  for (const node of nodes) {
    assert(Number.isFinite(node.x) && Number.isFinite(node.y), `${mode}: finite ${node.id}`);
  }
  for (let i = 0; i < nodes.length; i++) for (let j = i + 1; j < nodes.length; j++) {
    const a = nodes[i], b = nodes[j];
    assert(Math.abs(a.x - b.x) >= 130 || Math.abs(a.y - b.y) >= 64,
      `${mode}: ${a.id} and ${b.id} overlap`);
  }
  signatures.add(nodes.map(node => `${Math.round(node.x)},${Math.round(node.y)}`).join(';'));
  context.manualPositions = {A: {x: 1800, y: 1200}};
  vm.runInNewContext(layoutSource + '\napplyAutoLayout();', context, {timeout: 2000});
  assert.equal(nodes[0].x, 1800, `${mode}: manual x preserved`);
  assert.equal(nodes[0].y, 1200, `${mode}: manual y preserved`);
}
assert(signatures.size >= 10, `only ${signatures.size} distinct layouts`);

const html = fs.readFileSync(path.join(__dirname, '..', 'dist', 'graph.html'), 'utf8');
const marker = '<script type="application/json" id="graph-data">';
const dataStart = html.indexOf(marker);
assert(dataStart >= 0, 'real graph data exists');
const dataEnd = html.indexOf('</script>', dataStart);
const graph = JSON.parse(html.slice(dataStart + marker.length, dataEnd));
for (const mode of modes) {
  const nodes = graph.nodes.filter(node => node.degree > 0).map(node => ({...node, labelWidth: 110}));
  const links = graph.links;
  const context = {canvasNodes: nodes, links, state: {layout: mode}, manualPositions: {},
    width: 1100, height: 750, activeNeighborhood: null, matches: () => true,
    visibleEdge: () => true, renderTick: () => {}, fitView: () => {}, Map, Set, Math,
    Number, Array, Object};
  vm.runInNewContext(layoutSource + '\napplyAutoLayout();', context, {timeout: 2000});
  for (const node of nodes) assert(Number.isFinite(node.x) && Number.isFinite(node.y), `${mode}: real ${node.id}`);
  for (let i = 0; i < nodes.length; i++) for (let j = i + 1; j < nodes.length; j++) {
    const a = nodes[i], b = nodes[j];
    assert(Math.abs(a.x - b.x) >= 145 || Math.abs(a.y - b.y) >= 64,
      `${mode}: real nodes ${a.id} and ${b.id} overlap`);
  }
}
console.log(`${modes.length} layouts passed: cycles, placement, manual positions, ${graph.nodes.length} real notes`);
