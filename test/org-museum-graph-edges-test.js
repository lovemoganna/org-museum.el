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

test('explicit routingMode parameter overrides curve type (straight, stepped, spline)', () => {
  const nodes = [{id: 'root'}, {id: 'child'}];
  const relations = [{id: 'e1', source: 'root', target: 'child'}];
  const points = new Map([['root', {x: 100, y: 100}], ['child', {x: 250, y: 200}]]);
  const radii = new Map([['root', 18], ['child', 10]]);

  // straight routing mode produces linear path command L even in hierarchical layout
  const straightRoute = edges.routes(nodes, relations, points, radii, null, 'treeVertical', 'straight').get('e1');
  assert.equal(straightRoute.curveType, 'linear');
  assert(straightRoute.path.includes('L'));

  // stepped routing mode produces cubic orthogonal step C with step control points
  const steppedRoute = edges.routes(nodes, relations, points, radii, null, 'treeVertical', 'stepped').get('e1');
  assert.equal(steppedRoute.curveType, 'cubic');
  assert(steppedRoute.path.includes('C'));
  assert(steppedRoute.c1 && steppedRoute.c2);

  // spline routing mode uses layout-adaptive smooth curve
  const splineRoute = edges.routes(nodes, relations, points, radii, null, 'treeVertical', 'spline').get('e1');
  assert.equal(splineRoute.curveType, 'cubic');
});

test('lineage tracing navigates multi-level hierarchy from root to leaves', () => {
  const links = [
    {id: 'e-r-c1', source: 'root', target: 'child1', direction: 'forward'},
    {id: 'e-c1-g1', source: 'child1', target: 'grandchild1', direction: 'forward'},
    {id: 'e-c1-g2', source: 'child1', target: 'grandchild2', direction: 'forward'},
    {id: 'e-r-c2', source: 'root', target: 'child2', direction: 'forward'},
    {id: 'e-cross', source: 'child2', target: 'grandchild1', direction: 'forward'}
  ];

  // Upstream tracing from grandchild1 back to root
  const linGrandchild = layout.lineage('grandchild1', links);
  assert(linGrandchild.upstreamNodes.has('grandchild1'));
  assert(linGrandchild.upstreamNodes.has('child1'));
  assert(linGrandchild.upstreamNodes.has('root'));
  assert(linGrandchild.upstreamNodes.has('child2'));
  assert(linGrandchild.upstreamEdges.has('e-c1-g1'));
  assert(linGrandchild.upstreamEdges.has('e-r-c1'));
  assert(linGrandchild.upstreamEdges.has('e-cross'));
  assert.equal(linGrandchild.downstreamNodes.size, 1, 'leaf node has no downstream descendants');

  // Downstream tracing from root to all leaves
  const linRoot = layout.lineage('root', links);
  assert(linRoot.downstreamNodes.has('child1'));
  assert(linRoot.downstreamNodes.has('child2'));
  assert(linRoot.downstreamNodes.has('grandchild1'));
  assert(linRoot.downstreamNodes.has('grandchild2'));
  assert.equal(linRoot.upstreamNodes.size, 1, 'root has no upstream ancestors');
});

test('MECE edge and node presentation CSS rules and contracts exist', () => {
  const css = fs.readFileSync(path.join(__dirname, '..', 'resources', 'org-museum.css'), 'utf8');
  assert(css.includes('.graph-network-node.is-root-node'), 'CSS includes root node styling');
  assert(css.includes('.graph-node-root-halo'), 'CSS includes root halo');
  assert(css.includes('.graph-node-root-ring'), 'CSS includes root ring');
  assert(css.includes('@keyframes graph-root-radar'), 'CSS includes rotating radar ring animation');
  assert(!css.includes('r: 26px'), 'CSS pulse animation must not hardcode fixed r geometry overriding D3 dynamic radii');
  assert(css.includes('.graph-network-node:active'), 'CSS includes tactile active feedback');
  assert(css.includes('.graph-network-node:focus'), 'CSS normalizes focus outline');
  assert(css.includes('.graph-node-tier-pill'), 'CSS includes tier badges');
  assert(css.includes('.graph-node-degree-circle'), 'CSS includes degree micro-badge circle');
  assert(css.includes('.graph-node-degree-text'), 'CSS includes degree micro-badge text');
  assert(css.includes('.graph-network-node.is-isolated-node'), 'CSS includes isolated peripheral node styling');
  assert(css.includes('.graph-network-edge.is-trunk'), 'CSS includes trunk edge styling');
  assert(css.includes('.graph-network-edge.is-branch'), 'CSS includes branch edge styling');
  assert(css.includes('.graph-network-edge.is-leaf'), 'CSS includes leaf edge styling');
  assert(css.includes('.graph-network-edge.is-cross'), 'CSS includes cross edge styling');
  assert(css.includes('.graph-network-edge.is-bidirectional'), 'CSS includes bidirectional edge styling');
  assert(css.includes('.graph-network-edge-particle'), 'CSS includes flow particles');
  assert(css.includes('.graph-network-edge.is-upstream'), 'CSS includes upstream lineage highlighting');
  assert(css.includes('.graph-network-edge.is-downstream'), 'CSS includes downstream lineage highlighting');
  assert(css.includes('#38bdf8'), 'CSS distinguishes upstream lineage with cyan #38bdf8');
  assert(css.includes('#50fa7b'), 'CSS distinguishes downstream lineage with emerald #50fa7b');
  assert(css.includes(':root[data-theme="light"] .graph-page.is-network-runtime'), 'CSS includes light theme high-contrast rules');
  assert(css.includes('.graph-layout-fieldset'), 'CSS includes structured layout fieldset');

  const networkJs = fs.readFileSync(path.join(__dirname, '..', 'resources', 'org-museum-graph-network.js'), 'utf8');
  assert(networkJs.includes('network-arrow-trunk'), 'network.js includes trunk marker');
  assert(networkJs.includes('network-arrow-branch'), 'network.js includes branch marker');
  assert(networkJs.includes('network-arrow-cross'), 'network.js includes cross marker');
  assert(networkJs.includes('network-arrow-upstream'), 'network.js includes upstream marker');
  assert(networkJs.includes('network-arrow-downstream'), 'network.js includes downstream marker');
  assert(networkJs.includes('network-glow'), 'network.js includes SVG glow filter');
  assert(networkJs.includes('network-radial-root'), 'network.js includes radial gradient for root 3D sheen');
  assert(networkJs.includes('graph-node-sheen'), 'network.js includes root node specular sheen element');
  assert(networkJs.includes('graph-node-degree-badge'), 'network.js includes degree badge element');
  assert(networkJs.includes('deg >= 100 ? 10.5 : (deg >= 10 ? 8.2 : 6.5)'), 'network.js dynamically expands degree badge radius for multi-digit numbers');
});

test('spoke layout builds true center-rooted BFS tree with outward radial branches', () => {
  const nodes = [{id: 'root'}, {id: 'branch1'}, {id: 'branch2'}, {id: 'leaf1'}, {id: 'subleaf'}];
  const links = [
    {id: 'e-r-b1', source: 'root', target: 'branch1'},
    {id: 'e-r-b2', source: 'root', target: 'branch2'},
    {id: 'e-b1-l1', source: 'branch1', target: 'leaf1'},
    {id: 'e-l1-s', source: 'leaf1', target: 'subleaf'}
  ];
  const points = layout.positions(nodes, links, 'spoke', 1000, 700, {focusedNodeId: 'root'});

  const rootPt = points.get('root');
  assert.equal(rootPt.depth, 0);
  assert.equal(rootPt.isRoot, true);

  const b1 = points.get('branch1'), b2 = points.get('branch2');
  assert.equal(b1.depth, 1);
  assert.equal(b2.depth, 1);
  assert.equal(b1.isRoot, false);
  const rB1 = Math.hypot(b1.x - rootPt.x, b1.y - rootPt.y);
  const rB2 = Math.hypot(b2.x - rootPt.x, b2.y - rootPt.y);
  assert(rB1 > 50 && rB2 > 50, 'branches are at radial distance from root');

  const l1 = points.get('leaf1');
  assert.equal(l1.depth, 2);
  const rL1 = Math.hypot(l1.x - rootPt.x, l1.y - rootPt.y);
  assert(rL1 > rB1, 'sub-branch leaf is further outward from root than parent branch');

  const sl = points.get('subleaf');
  assert.equal(sl.depth, 3);
  const rSL = Math.hypot(sl.x - rootPt.x, sl.y - rootPt.y);
  assert(rSL > rL1, 'subleaf is positioned further outward at depth 3');
});

test('concentric layout arranges nodes in rings strictly by topological distance from root', () => {
  const nodes = [{id: 'root'}, {id: 'child1'}, {id: 'child2'}, {id: 'grandchild'}];
  const links = [
    {id: 'e1', source: 'root', target: 'child1'},
    {id: 'e2', source: 'root', target: 'child2'},
    {id: 'e3', source: 'child1', target: 'grandchild'}
  ];
  const points = layout.positions(nodes, links, 'concentric', 1000, 700, {focusedNodeId: 'root'});

  const rootPt = points.get('root');
  assert.equal(rootPt.depth, 0);
  assert.equal(rootPt.isRoot, true);

  const c1 = points.get('child1'), c2 = points.get('child2');
  assert.equal(c1.depth, 1);
  assert.equal(c2.depth, 1);
  const rC1 = Math.hypot(c1.x - rootPt.x, c1.y - rootPt.y);
  const rC2 = Math.hypot(c2.x - rootPt.x, c2.y - rootPt.y);
  assert(Math.abs(rC1 - rC2) < 1e-4, 'same topological distance nodes share concentric ring radius');

  const gc = points.get('grandchild');
  assert.equal(gc.depth, 2);
  const rGC = Math.hypot(gc.x - rootPt.x, gc.y - rootPt.y);
  assert(rGC > rC1, 'depth 2 grandchild is in outer concentric ring');
});

test('focusedNodeId parameter successfully re-anchors layout root', () => {
  const nodes = [{id: 'nodeA'}, {id: 'nodeB'}, {id: 'nodeC'}];
  const links = [{id: 'e1', source: 'nodeA', target: 'nodeB'}, {id: 'e2', source: 'nodeB', target: 'nodeC'}];

  const defaultPoints = layout.positions(nodes, links, 'spoke', 1000, 700);
  // Default picks highest degree (nodeB, degree 2)
  assert.equal(defaultPoints.get('nodeB').isRoot, true);

  // Explicitly focus nodeA
  const focusedPoints = layout.positions(nodes, links, 'spoke', 1000, 700, {focusedNodeId: 'nodeA'});
  assert.equal(focusedPoints.get('nodeA').isRoot, true);
  assert.equal(focusedPoints.get('nodeA').depth, 0);
  assert.equal(focusedPoints.get('nodeB').isRoot, false);
  assert.equal(focusedPoints.get('nodeB').depth, 1);
});

test('radial cross-branch edges curve outward around center root to avoid penetration', () => {
  const nodes = [{id: 'root'}, {id: 'left'}, {id: 'right'}];
  const relations = [{id: 'cross', source: 'left', target: 'right'}];
  // left at (-150, 0), right at (150, 0) - straight line would pass through (0, 0) center root
  const points = new Map([['left', {x: -150, y: 0}], ['right', {x: 150, y: 0}]]);
  const radii = new Map([['left', 12], ['right', 12]]);

  const route = edges.routes(nodes, relations, points, radii, null, 'spoke').get('cross');
  assert.equal(route.curveType, 'quad', 'cross-branch edge through origin bows outward as quadratic curve');
  assert(route.path.includes('Q'), 'path contains quadratic bezier command Q');
  assert(Math.hypot(route.control.x, route.control.y) > 40, 'control point is pushed away from center root');
});

test('lineage traverses bidirectional relations in both upstream and downstream chains', () => {
  const links = [
    {id: 'e-bi', source: 'peerA', target: 'peerB', direction: 'both'},
    {id: 'e-down', source: 'peerB', target: 'child', direction: 'forward'}
  ];
  const linB = layout.lineage('peerB', links);
  assert(linB.upstreamNodes.has('peerA'), 'bidirectional link traversed upstream');
  assert(linB.downstreamNodes.has('peerA'), 'bidirectional link traversed downstream');
  assert(linB.downstreamNodes.has('child'), 'child reached downstream');
});


