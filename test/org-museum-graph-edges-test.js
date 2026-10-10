const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {test} = require('node:test');
const edges = require('../resources/org-museum-graph-edges.js');
const layout = require('../resources/org-museum-graph-layout.js');

const html = fs.readFileSync(path.join(__dirname, '..', 'dist', 'graph.html'), 'utf8');
const match = html.match(/<script type="application\/json" id="graph-data">([^<]+)<\/script>/);
assert(match, 'the exported graph contains real Org data');
const graph = JSON.parse(match[1]);

test('direction drives arrows and upstream/downstream consistently', () => {
  for (const [direction, from, to, start, end] of [
    ['forward', 'a', 'b', false, true],
    ['reverse', 'b', 'a', true, false],
    ['both', 'a', 'b', true, true]
  ]) {
    const relation = {source: {id: 'a'}, target: {id: 'b'}, direction};
    assert.deepEqual(edges.flow(relation),
      {source: 'a', target: 'b', from, to, atStart: start, atEnd: end});
    assert.equal(edges.incoming(relation, 'a'), start);
    assert.equal(edges.outgoing(relation, 'a'), end);
    assert.equal(edges.incoming(relation, 'b'), end);
    assert.equal(edges.outgoing(relation, 'b'), start);
  }
});

test('real reciprocal relations remain distinct and rendering never mutates graph data', () => {
  assert(graph.links.length > 0, 'real relations are available');
  const before = JSON.stringify(graph);
  const positions = layout.positions(graph.nodes, graph.links, 'ring', 1100, 750);
  const radii = new Map(graph.nodes.map(node => [node.id, 12]));
  const routes = edges.routes(graph.nodes, graph.links, positions, radii);
  assert.equal(routes.size, graph.links.length);
  const groups = new Map();
  for (const edge of graph.links) {
    const key = [edge.source, edge.target].sort().join('|');
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(edge);
    const route = routes.get(edge.id);
    assert(route && Number.isFinite(route.start.x) && Number.isFinite(route.end.y));
    assert(Math.hypot(route.start.x - positions.get(edge.source).x,
      route.start.y - positions.get(edge.source).y) >= 15);
    assert(Math.hypot(route.end.x - positions.get(edge.target).x,
      route.end.y - positions.get(edge.target).y) >= 15);
  }
  assert([...groups.values()].some(group => group.length > 1), 'real parallel relations are available');
  for (const group of groups.values()) {
    for (let i = 0; i < group.length; i++) {
      for (let j = i + 1; j < group.length; j++) {
        assert.notEqual(routes.get(group[i].id).path, routes.get(group[j].id).path);
      }
    }
  }
  assert.equal(JSON.stringify(graph), before);
});

test('a route avoids a node between its endpoints when there is room', () => {
  const nodes = [{id: 'a'}, {id: 'b'}, {id: 'c'}];
  const relations = [{id: 'ab', source: 'a', target: 'b'}];
  const points = new Map([['a', {x: 80, y: 100}], ['b', {x: 320, y: 100}],
    ['c', {x: 200, y: 100}]]);
  const radii = new Map(nodes.map(node => [node.id, 12]));
  const route = edges.routes(nodes, relations, points, radii).get('ab');
  const midpoint = edges.point(route, .5);
  assert(Math.hypot(midpoint.x - 200, midpoint.y - 100) > 18);
  assert(Math.abs(route.lane) <= 44, 'the detour stays proportionate');
  assert(edges.labelCandidates(route).some(candidate =>
    Math.hypot(candidate.x - midpoint.x, candidate.y - midpoint.y) >= 12));
});

test('layout-adaptive routing selects cubic S-curves for hierarchy and straight rays for radial/grid', () => {
  const nodes = [{id: 'root'}, {id: 'child'}];
  const relations = [{id: 'e1', source: 'root', target: 'child'}];
  const points = new Map([['root', {x: 100, y: 100}], ['child', {x: 100, y: 300}]]);
  const radii = new Map([['root', 14], ['child', 10]]);

  // Hierarchical layouts use Cubic S-curve
  for (const hMode of ['treeVertical', 'treeHorizontal', 'dagre', 'semantic']) {
    const route = edges.routes(nodes, relations, points, radii, null, hMode).get('e1');
    assert.equal(route.curveType, 'cubic', `${hMode} should use cubic curve`);
    assert(route.path.startsWith('M') && route.path.includes('C'), `${hMode} path should contain cubic command C`);
    assert(route.c1 && route.c2, `${hMode} route should provide control points c1 and c2`);
    // Endpoint clipping: start >= 14+4 = 18 >= 15; end >= 10+6 = 16 >= 15
    const startDist = Math.hypot(route.start.x - 100, route.start.y - 100);
    const endDist = Math.hypot(route.end.x - 100, route.end.y - 300);
    assert(startDist >= 15, `start distance ${startDist} >= 15`);
    assert(endDist >= 16, `end distance ${endDist} >= 16 (targetRadius + 6)`);
  }

  // Radial and grid layouts use straight rays
  for (const rMode of ['concentric', 'starburst', 'dandelion', 'spoke', 'grid']) {
    const route = edges.routes(nodes, relations, points, radii, null, rMode).get('e1');
    assert.equal(route.curveType, 'linear', `${rMode} should use linear ray`);
    assert(route.path.startsWith('M') && route.path.includes('L'), `${rMode} path should contain linear command L`);
  }

  // Force and organic networks use quadratic bezier
  for (const fMode of ['organic', 'force', 'clusteredForce']) {
    const route = edges.routes(nodes, relations, points, radii, null, fMode).get('e1');
    assert.equal(route.curveType, 'quad', `${fMode} should use quad bezier`);
    assert(route.path.startsWith('M') && route.path.includes('Q'), `${fMode} path should contain quadratic command Q`);
  }
});
