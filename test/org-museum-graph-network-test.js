const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {test} = require('node:test');
const layout = require('../resources/org-museum-graph-layout.js');

const graphFile = path.join(__dirname, '..', 'dist', 'graph.html');
const html = fs.readFileSync(graphFile, 'utf8');
const match = html.match(/<script type="application\/json" id="graph-data">([^<]+)<\/script>/);
assert(match, 'exported graph embeds its Org data');
const graph = JSON.parse(match[1]);

test('every topology positions the same real graph without changing it', () => {
  assert(graph.nodes.length > 0, 'real notes are available');
  const before = JSON.stringify(graph);
  const signatures = new Set();
  for (const mode of layout.modes) {
    const positions = layout.positions(graph.nodes, graph.links, mode, 1100, 750);
    assert.equal(positions.size, graph.nodes.length);
    let rootCount = 0;
    for (const node of graph.nodes) {
      const point = positions.get(node.id);
      assert(Number.isFinite(point.x) && Number.isFinite(point.y) && Number.isFinite(point.z));
      assert(Number.isFinite(point.depth), `${mode}: finite depth for ${node.id}`);
      assert(Number.isFinite(point.rank), `${mode}: finite rank for ${node.id}`);
      assert.equal(typeof point.isRoot, 'boolean', `${mode}: boolean isRoot for ${node.id}`);
      if (point.isRoot) rootCount++;
    }
    assert(rootCount > 0, `${mode}: at least one root identified`);
    signatures.add(graph.nodes.map(node => {
      const point = positions.get(node.id);
      return `${Math.round(point.x)},${Math.round(point.y)},${Math.round(point.z)}`;
    }).join(';'));
  }
  assert.equal(signatures.size, layout.modes.length, 'topologies have distinct geometry');
  assert.equal(JSON.stringify(graph), before, 'nodes and relations are unchanged');
});

test('random layout selection never repeats the current topology', () => {
  for (const current of layout.modes) {
    for (const random of [0, .1, .3, .5, .7, .99]) {
      const next = layout.next(current, () => random);
      assert(layout.modes.includes(next));
      assert.notEqual(next, current);
    }
  }
});

test('organic springs preserve equal branch lengths in a symmetric star', () => {
  const nodes = ['hub', 'a', 'b', 'c'].map(id => ({id, name: id}));
  const links = ['a', 'b', 'c'].map(target => ({source: 'hub', target}));
  const original = JSON.stringify({nodes, links});
  for (const spacing of [.7, 1, 2]) {
    const points = layout.positions(nodes, links, 'organic', 1100, 750, {spacing});
    const hub = points.get('hub');
    const lengths = links.map(edge => {
      const leaf = points.get(edge.target);
      return Math.hypot(leaf.x - hub.x, leaf.y - hub.y);
    });
    assert(Math.max(...lengths) - Math.min(...lengths) < 1e-6,
      `equivalent branches must reach the same equilibrium at spacing ${spacing}`);
  }
  assert.equal(JSON.stringify({nodes, links}), original);
});

test('organic real-note titles have clearance at desktop and narrow canvas sizes', () => {
  const nodes = graph.nodes.filter(node => node.degree > 0);
  const halfWidth = (node, width) => Math.max(64,
    (Math.min(width < 600 ? 12 : 28, Array.from(String(node.name || node.id)).length) * 11 + 24) / 2);
  for (const [width, height] of [[967, 820], [360, 700], [1400, 700]]) {
    for (const spacing of [.7, 1, 2]) {
      const points = layout.positions(nodes, graph.links, 'organic', width, height, {spacing});
      for (let i = 0; i < nodes.length; i++) for (let j = i + 1; j < nodes.length; j++) {
        const a = points.get(nodes[i].id), b = points.get(nodes[j].id);
        assert(Math.abs(a.x - b.x) >= halfWidth(nodes[i], width) + halfWidth(nodes[j], width) + 19.9 ||
          Math.abs(a.y - b.y) >= 103.9,
          `title clearance: ${nodes[i].name} / ${nodes[j].name}, ${width}, ${spacing}`);
      }
    }
  }
});

test('organic is repeatable and reciprocal links do not distort its geometry', () => {
  const nodes = graph.nodes.filter(node => node.degree > 0);
  const forward = layout.positions(nodes, graph.links, 'organic', 967, 820);
  const reverse = layout.positions(nodes.slice().reverse(), graph.links.slice().reverse(), 'organic', 967, 820);
  const reciprocal = graph.links.concat(graph.links.map(edge => ({...edge, source: edge.target, target: edge.source})));
  const doubled = layout.positions(nodes, reciprocal, 'organic', 967, 820);
  for (const node of nodes) {
    assert.deepEqual(forward.get(node.id), reverse.get(node.id));
    assert.deepEqual(forward.get(node.id), doubled.get(node.id));
  }
});

test('all 12 layouts clear real note titles at default and extreme spacing', () => {
  const nodes = graph.nodes.filter(node => node.degree > 0);
  const half = (node, width) => Math.max(70, Array.from(node.name || node.id)
    .slice(0, width < 600 ? 12 : 28)
    .reduce((sum, char) => sum + (char.charCodeAt(0) < 256 ? 6.8 : 11), 24) / 2);
  for (const mode of layout.modes) for (const [width, height] of [[939, 890], [360, 524]]) {
    for (const spacing of [.7, 1, 2]) {
      const points = layout.positions(nodes, graph.links, mode, width, height, {spacing});
      for (let i = 0; i < nodes.length; i++) for (let j = i + 1; j < nodes.length; j++) {
        const a = points.get(nodes[i].id), b = points.get(nodes[j].id);
        assert(Math.abs(a.x - b.x) >= half(nodes[i], width) + half(nodes[j], width) + 23.9 ||
          Math.abs(a.y - b.y) >= 103.9,
          `${mode}: title collision at ${width}px / ${spacing}: ${nodes[i].name} / ${nodes[j].name}`);
      }
    }
  }
});

test('every layout covers empty, single, and deep cyclic graphs without omissions', () => {
  const nodes = Array.from({length: 16}, (_, i) => ({id: `n${i}`, name: `层级节点 ${i}`}));
  const links = nodes.slice(1).map((node, i) => ({source: nodes[i].id, target: node.id}));
  links.push({source: 'n15', target: 'n12'});
  const original = JSON.stringify({nodes, links});
  for (const mode of layout.modes) {
    assert.equal(layout.positions([], [], mode, 1000, 700).size, 0);
    assert.equal(layout.positions(nodes.slice(0, 1), [], mode, 1000, 700).size, 1);
    const points = layout.positions(nodes, links, mode, 1000, 700, {focusedNodeId: 'n0'});
    assert.equal(points.size, nodes.length, mode);
    for (const node of nodes) {
      assert(Number.isFinite(points.get(node.id).x) && Number.isFinite(points.get(node.id).y), `${mode}: ${node.id}`);
    }
  }
  const spoke = layout.positions(nodes, links, 'spoke', 1000, 700, {focusedNodeId: 'n0'});
  assert.equal(spoke.get('n11').depth, 11, 'branches beyond the old eight-level cutoff remain reachable');
  assert.equal(JSON.stringify({nodes, links}), original);
});

test('both tidy trees center parents over asymmetric subtrees', () => {
  const nodes = ['root','a','b','a1','a2','a3','b1'].map(id => ({id, name: id}));
  const links = [['root','a'],['root','b'],['a','a1'],['a','a2'],['a','a3'],['b','b1']]
    .map(([source,target]) => ({source,target}));
  for (const mode of ['treeVertical', 'treeHorizontal']) {
    const p = layout.positions(nodes, links, mode, 1100, 750, {focusedNodeId: 'root'});
    const axis = mode === 'treeVertical' ? 'x' : 'y';
    assert(Math.abs(p.get('root')[axis] - (p.get('a')[axis] + p.get('b')[axis])/2) < 1e-6);
    assert(Math.abs(p.get('a')[axis] - (p.get('a1')[axis] + p.get('a3')[axis])/2) < 1e-6);
    assert(p.get('b1')[axis] > p.get('a3')[axis], 'different subtrees occupy separate intervals');
  }
});

test('closed cycles do not collapse into a line in grid and layered layouts', () => {
  const nodes = ['a','b','c'].map(id => ({id, name: id}));
  const links = [{source:'a',target:'b'},{source:'b',target:'c'},{source:'c',target:'a'}];
  for (const mode of ['grid','semantic','dagre']) {
    const p = layout.positions(nodes,links,mode,939,890);
    const a=p.get('a'),b=p.get('b'),c=p.get('c');
    const area=Math.abs((b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x));
    assert(area>1000, `${mode}: separate cyclic relationships without a middle node on the shortcut`);
  }
});

test('hierarchy respects reverse direction and keeps directed cycles together', () => {
  const nodes = ['a','b','c','d','e'].map(id => ({id}));
  const links = [{source:'b',target:'a',direction:'reverse'},
    {source:'b',target:'c'}, {source:'c',target:'b'}, {source:'c',target:'d'},
    {source:'e',target:'d'}];
  const points = layout.positions(nodes,links,'hierarchy',1000,700);
  assert(points.get('a').y < Math.min(points.get('b').y, points.get('c').y));
  assert(points.get('d').y > Math.max(points.get('b').y, points.get('c').y));
  assert(points.get('e').y < points.get('d').y);
  assert.equal(layout.components(nodes,links).length,1);
  const horizontal = layout.positions(nodes,links,'hierarchy',1000,700,{orientation:'horizontal'});
  assert(horizontal.get('a').x < Math.min(horizontal.get('b').x,horizontal.get('c').x));
});

test('disconnected components remain separate and spacing expands geometry', () => {
  const nodes = ['a','b','c','d','e','f','orphan'].map(id=>({id}));
  const links = [{source:'a',target:'b'},{source:'b',target:'c'},
    {source:'d',target:'e'},{source:'e',target:'f'}];
  const groups = layout.components(nodes,links);
  assert.equal(groups.length,3);
  for(const mode of layout.modes) {
    const points=layout.positions(nodes,links,mode,1100,750);
    for(let i=0;i<groups.length;i++) for(let j=i+1;j<groups.length;j++) {
      const a=groups[i].map(id=>points.get(id)),b=groups[j].map(id=>points.get(id));
      const extent=(list,key)=>[Math.min(...list.map(p=>p[key])),Math.max(...list.map(p=>p[key]))];
      const ax=extent(a,'x'),ay=extent(a,'y'),bx=extent(b,'x'),by=extent(b,'y');
      assert(ax[1]<bx[0] || bx[1]<ax[0] || ay[1]<by[0] || by[1]<ay[0],mode+' components overlap');
    }
  }
  const near=layout.positions(nodes,links,'ring',1100,750,{spacing:.8});
  const far=layout.positions(nodes,links,'ring',1100,750,{spacing:1.8});
  const distance=p=>Math.hypot(p.get('a').x-p.get('b').x,p.get('a').y-p.get('b').y);
  assert(distance(far)>distance(near)*2);
});

test('graph commandbar includes time filter contracts and CSS', () => {
  assert(html.includes('class="graph-filter-summary graph-time-summary"'), 'graph has time summary details');
  assert(html.includes('id="graph-time-filters"'), 'graph has time filters container');
  assert(html.includes('id="graph-time-label"'), 'graph has time label');
  const css = fs.readFileSync(path.join(__dirname, '..', 'resources', 'org-museum.css'), 'utf8');
  assert(css.includes('.graph-page.is-network-runtime .graph-time-summary'), 'css includes graph time summary');
  assert(css.includes('#graph-time-filters'), 'css includes graph time filters');
  // Nodes in graph data contain created/modified timestamps for time filtering
  const datedNodes = graph.nodes.filter(n => n.created || n.modified);
  assert(datedNodes.length > 0, 'graph nodes contain created/modified dates');
});

const {recentNodeIds} = require('../resources/org-museum-graph-network.js');

test('graph time filter partitions real notes with a pinned clock', () => {
  const latest = Math.max(...graph.nodes.map(n => Number(n.created || n.modified) * 1000 || 0));
  const anchor = new Date(latest);
  anchor.setHours(12, 0, 0, 0);
  const nodes7 = recentNodeIds(graph.nodes, 7, anchor);
  const nodes30 = recentNodeIds(graph.nodes, 30, anchor);
  const nodes90 = recentNodeIds(graph.nodes, 90, anchor);
  assert(nodes7.size > 0, 'latest real notes appear in their calendar window');
  for (const id of nodes7) assert(nodes30.has(id));
  for (const id of nodes30) assert(nodes90.has(id));
  assert(nodes90.size <= graph.nodes.length);
});

test('recent dates include the whole first day and exclude future or invalid dates', () => {
  const nodes = [
    {id: 'first', created: '2026-10-03'},
    {id: 'today', created: '2026-10-09'},
    {id: 'old', created: '2026-10-02'},
    {id: 'future', created: '2026-10-10'},
    {id: 'fallback', created: 'invalid', modified: '2026-10-08'},
    {id: 'missing'}
  ];
  assert.deepEqual([...recentNodeIds(nodes, 7, new Date(2026, 9, 9, 23, 59))], ['first', 'today', 'fallback']);
  assert.equal(recentNodeIds([], 7, new Date(2026, 9, 9)).size, 0);
  assert.equal(recentNodeIds(nodes, 7, new Date(2027, 9, 9)).size, 0);
});
