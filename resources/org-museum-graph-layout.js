/* Position-only layouts, grouped by the real connected components. */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.orgMuseumGraphLayout = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';

  // 12 MECE layout modes (aligned with DuckDB Editor AI Graph)
  var modes = [
    'semantic', 'dagre', 'treeVertical', 'treeHorizontal',
    'organic', 'clusteredForce', 'groupedCircular',
    'concentric', 'starburst', 'dandelion', 'spoke', 'grid'
  ];

  var labels = {
    semantic: '拓扑语义层级流',
    dagre: 'Dagre 严格分层',
    treeVertical: '纵向层级树',
    treeHorizontal: '横向层级树',
    organic: '有机力导向',
    clusteredForce: '社区重心极坐标',
    groupedCircular: '分组环形',
    concentric: '同心圆同轴径向',
    starburst: '星系辐射',
    dandelion: '蒲公英扇形径向',
    spoke: '轮辐辐射骨架',
    grid: '同质正交网格',
    force: '力导向',
    hierarchy: '层级',
    ring: '环形'
  };

  var hints = {
    semantic: '按有向依赖与最长路径分层，双向重心法最小化交叉，适合演进脉络。',
    dagre: '严格有向分层算法，前置关系自上而下流动，阶层分明。',
    treeVertical: '自上而下的树形骨架，适合主干展开与父子分支。',
    treeHorizontal: '自左至右横向展开树，适合长链路阅读与时间线推演。',
    organic: '按真实关系距离均衡排布，避让节点标题，关系群自然展开并保持稳定。',
    clusteredForce: '按关联社群聚拢，各社群沿极坐标环形分布。',
    groupedCircular: '按笔记主题概念分组，组内环状排列，组间连线清晰。',
    concentric: '核心节点居中，关联主题按亲和度环向展开，内外层次分明。',
    starburst: '以核心枢纽为星核，直接分支沿射线爆发辐射。',
    dandelion: '主题概念作为花心，各笔记实例呈扇形花瓣向外发散。',
    spoke: '等角射线对称布局，保证每个子分支间距对称均匀。',
    grid: '同质正交方阵排布，完全消除视觉重叠，便于快速检索。',
    force: '按关系自然聚拢，拖拽可固定节点。',
    hierarchy: '按上下游分层，往返关系放在同一组。',
    ring: '每个关系群独立成环，适合浏览循环关系。'
  };

  var categories = {
    semantic: 'hierarchical', dagre: 'hierarchical', treeVertical: 'hierarchical', treeHorizontal: 'hierarchical', hierarchy: 'hierarchical',
    organic: 'network', clusteredForce: 'network', groupedCircular: 'network', force: 'network',
    concentric: 'radial', starburst: 'radial', dandelion: 'radial', spoke: 'radial', ring: 'radial',
    grid: 'grid'
  };

  function id(value) { return typeof value === 'object' ? value.id : value; }

  function next(previous, random) {
    var choices = modes.filter(function (mode) { return mode !== previous; });
    return choices[Math.min(choices.length - 1, Math.floor(Math.max(0, Math.min(.999999, random())) * choices.length))];
  }

  function topology(nodes, links) {
    var nodeMap = new Map();
    nodes.forEach(function (n) { nodeMap.set(n.id, n); });
    var ordered = nodes.slice().sort(function (a, b) { return String(a.name || a.id).localeCompare(String(b.name || b.id)); });
    var adjacent = new Map(), outgoing = new Map(), incoming = new Map();
    ordered.forEach(function (node) {
      adjacent.set(node.id, new Set());
      outgoing.set(node.id, new Set());
      incoming.set(node.id, new Set());
    });
    links.forEach(function (edge) {
      var a = id(edge.source), b = id(edge.target);
      if (!adjacent.has(a) || !adjacent.has(b) || a === b) return;
      adjacent.get(a).add(b); adjacent.get(b).add(a);
      if (edge.direction === 'reverse') {
        outgoing.get(b).add(a);
        incoming.get(a).add(b);
      } else {
        outgoing.get(a).add(b);
        incoming.get(b).add(a);
        if (edge.direction === 'both' || edge.bidirectional) {
          outgoing.get(b).add(a);
          incoming.get(a).add(b);
        }
      }
    });
    var seen = new Set(), components = [];
    ordered.forEach(function (node) {
      if (seen.has(node.id)) return;
      var group = [], queue = [node.id]; seen.add(node.id);
      for (var cursor = 0; cursor < queue.length; cursor++) {
        var current = queue[cursor]; group.push(current);
        Array.from(adjacent.get(current)).sort().forEach(function (child) {
          if (!seen.has(child)) { seen.add(child); queue.push(child); }
        });
      }
      components.push(group);
    });
    components.sort(function (a, b) { return b.length - a.length || String(a[0]).localeCompare(String(b[0])); });
    return { components: components, outgoing: outgoing, incoming: incoming, adjacent: adjacent, nodeMap: nodeMap };
  }

  // Strongly-connected component condensation layers (for 'hierarchy' mode)
  function layers(group, outgoing) {
    var serial = 0, indexes = new Map(), low = new Map(), stack = [], stacked = new Set(), clusters = [];
    function visit(node) {
      indexes.set(node, serial); low.set(node, serial++); stack.push(node); stacked.add(node);
      (outgoing.get(node) || new Set()).forEach(function (child) {
        if (!indexes.has(child)) { visit(child); low.set(node, Math.min(low.get(node), low.get(child))); }
        else if (stacked.has(child)) low.set(node, Math.min(low.get(node), indexes.get(child)));
      });
      if (low.get(node) === indexes.get(node)) {
        var cluster = [], child;
        do { child = stack.pop(); stacked.delete(child); cluster.push(child); } while (child !== node);
        clusters.push(cluster.sort());
      }
    }
    group.forEach(function (node) { if (!indexes.has(node)) visit(node); });
    var owner = new Map(); clusters.forEach(function (cluster, index) { cluster.forEach(function (node) { owner.set(node, index); }); });
    var edges = clusters.map(function () { return new Set(); }), degree = clusters.map(function () { return 0; });
    group.forEach(function (node) { (outgoing.get(node) || new Set()).forEach(function (child) {
      var a = owner.get(node), b = owner.get(child);
      if (a !== undefined && b !== undefined && a !== b && !edges[a].has(b)) { edges[a].add(b); degree[b]++; }
    }); });
    var depth = clusters.map(function () { return 0; }), queue = [];
    degree.forEach(function (n, i) { if (!n) queue.push(i); });
    for (var cursor = 0; cursor < queue.length; cursor++) edges[queue[cursor]].forEach(function (child) {
      depth[child] = Math.max(depth[child], depth[queue[cursor]] + 1);
      if (--degree[child] === 0) queue.push(child);
    });
    var levels = [];
    clusters.forEach(function (cluster, i) { (levels[depth[i]] || (levels[depth[i]] = [])).push(cluster); });
    for (var pass = 0; pass < 4; pass++) {
      var rank = new Map(); levels.forEach(function (row) { row.forEach(function (cluster, i) { cluster.forEach(function (node) { rank.set(node, i); }); }); });
      levels.forEach(function (row) { row.sort(function (a, b) {
        function center(cluster) {
          var sum = 0, n = 0;
          group.forEach(function (node) { (outgoing.get(node) || new Set()).forEach(function (child) {
            if (cluster.includes(node) && !cluster.includes(child)) { sum += rank.get(child); n++; }
            if (cluster.includes(child) && !cluster.includes(node)) { sum += rank.get(node); n++; }
          }); });
          return n ? sum / n : rank.get(cluster[0]);
        }
        return center(a) - center(b) || String(a[0]).localeCompare(String(b[0]));
      }); });
    }
    return levels;
  }

  // Minimize graph-distance stress within each real component. Reciprocal edges
  // count as one adjacency: they must not squeeze a pair closer than its peers.
  function relaxOrganic(group, graph, local, step, width, height) {
    if (group.length < 2) return;
    var distances = group.map(function (source) {
      var hops = new Map([[source, 0]]), queue = [source];
      for (var head = 0; head < queue.length; head++) {
        graph.adjacent.get(queue[head]).forEach(function (next) {
          if (!hops.has(next)) { hops.set(next, hops.get(queue[head]) + 1); queue.push(next); }
        });
      }
      return group.map(function (target) { return hops.get(target); });
    });
    var points = group.map(function (node) { return local.get(node); });
    for (var pass = 0; pass < 180; pass++) {
      var change = 0;
      var next = points.map(function (point, i) {
        var x = 0, y = 0, sum = 0;
        points.forEach(function (other, j) {
          if (i === j) return;
          var hops = distances[i][j], weight = 1 / (hops * hops);
          var dx = point.x - other.x, dy = point.y - other.y;
          if (Math.abs(dx) + Math.abs(dy) < 1e-8) { dx = i < j ? -1 : 1; dy = 0; }
          // Sublinear separation keeps long paths gently folded instead of
          // stretching every hop into a rigid, oversized straight stem.
          var scale = step * 1.05 * Math.pow(hops, .65) / Math.hypot(dx, dy);
          x += weight * (other.x + dx * scale);
          y += weight * (other.y + dy * scale);
          sum += weight;
        });
        return {x: point.x * .2 + x / sum * .8, y: point.y * .2 + y / sum * .8};
      });
      next.forEach(function (point, i) {
        change = Math.max(change, Math.hypot(point.x - points[i].x, point.y - points[i].y));
        points[i].x = point.x; points[i].y = point.y;
      });
      if (change < .02) break;
    }

    // Rotate the principal axis before packing, without changing any distances.
    // Tall canvases use upright branches; panoramic canvases use a horizontal flow.
    var mx = 0, my = 0;
    points.forEach(function (p) { mx += p.x / points.length; my += p.y / points.length; });
    var xx = 0, xy = 0, yy = 0;
    points.forEach(function (p) { var x = p.x - mx, y = p.y - my; xx += x*x; xy += x*y; yy += y*y; });
    if (Math.hypot(xx - yy, 2 * xy) > (xx + yy) * .05) {
      var angle = ((height || 700) >= (width || 900) * .7 ? Math.PI / 2 : 0) - Math.atan2(2 * xy, xx - yy) / 2;
      var cos = Math.cos(angle), sin = Math.sin(angle);
      points.forEach(function (p) { var x = p.x - mx, y = p.y - my; p.x = x*cos - y*sin; p.y = x*sin + y*cos; });
    }

    // Project overlapping node/title envelopes apart along the cheaper axis.
    // This participates in coordinate solving; no titles or relations are hidden.
    var halves = group.map(function (node) {
      var n = graph.nodeMap.get(node), name = String(n.name || n.id);
      return Math.max(70, (Number(n.labelWidth) || Math.min(width < 600 ? 12 : 28, Array.from(name).length) * 11 + 24) / 2);
    });
    // Preserve the proportions of small motifs (triangles, stars, short chains)
    // by expanding them uniformly before applying any local collision correction.
    if (points.length <= 4) {
      var expansion = 1;
      for (var i = 0; i < points.length; i++) for (var j = i + 1; j < points.length; j++) {
        expansion = Math.max(expansion, Math.min(
          (halves[i] + halves[j] + 24.1) / Math.max(1e-8, Math.abs(points[i].x - points[j].x)),
          104.1 / Math.max(1e-8, Math.abs(points[i].y - points[j].y))));
      }
      points.forEach(function (p) { p.x *= expansion; p.y *= expansion; });
    }
    for (var collisionPass = 0; collisionPass < 80; collisionPass++) {
      var overlap = false;
      for (var i = 0; i < points.length; i++) for (var j = i + 1; j < points.length; j++) {
        var a = points[i], b = points[j], dx = b.x - a.x, dy = b.y - a.y;
        var ox = halves[i] + halves[j] + 24 - Math.abs(dx), oy = 104 - Math.abs(dy);
        if (ox <= 0 || oy <= 0) continue;
        overlap = true;
        if (ox < oy) { var sx = (dx < 0 ? -1 : 1) * (ox + .1) / 2; a.x -= sx; b.x += sx; }
        else { var sy = (dy < 0 ? -1 : 1) * (oy + .1) / 2; a.y -= sy; b.y += sy; }
      }
      if (!overlap) break;
    }
  }

  function titleHalf(node, width) {
    if (Number(node.labelWidth) > 0) return Number(node.labelWidth) / 2 + 10;
    var chars = Array.from(String(node.name || node.id)).slice(0, width < 600 ? 12 : 28);
    return Math.max(70, chars.reduce(function (sum, c) { return sum + (c.charCodeAt(0) < 256 ? 6.8 : 11); }, 24) / 2);
  }

  function embeddingCost(local, graph, step) {
    var list = Array.from(local.keys()), edges = [], cost = 0;
    list.forEach(function (a) { graph.adjacent.get(a).forEach(function (b) {
      if (local.has(b) && String(a) < String(b)) edges.push([a,b]);
    }); });
    function side(a,b,p) { return (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x); }
    edges.forEach(function (edge, i) {
      var a=local.get(edge[0]),b=local.get(edge[1]),dx=b.x-a.x,dy=b.y-a.y,len2=dx*dx+dy*dy;
      cost += len2/(step*step)*.08;
      list.forEach(function (n) {
        if (n===edge[0] || n===edge[1]) return;
        var p=local.get(n),t=((p.x-a.x)*dx+(p.y-a.y)*dy)/Math.max(1,len2);
        if (t<=.06 || t>=.94) return;
        var distance=Math.hypot(p.x-a.x-t*dx,p.y-a.y-t*dy);
        if (distance<38) cost += 30+(38-distance)*.4;
      });
      edges.slice(i+1).forEach(function (other) {
        if (other.some(function (n) { return edge.includes(n); })) return;
        var c=local.get(other[0]),d=local.get(other[1]);
        if (side(a,b,c)*side(a,b,d)<-1e-6 && side(c,d,a)*side(c,d,b)<-1e-6) cost+=12;
      });
    });
    return cost;
  }

  // Search node permutations inside an existing motif, preserving its geometry
  // and partition contracts. Score actual edges, not invented visual links.
  function improveOrder(local, graph, step, eligible, swapDepth) {
    var list=Array.from(local.keys());
    var edgeCount=list.reduce(function(sum,n){return sum+graph.adjacent.get(n).size;},0)/2;
    if (list.length>24 || edgeCount>80) return local;
    var best=embeddingCost(local,graph,step);
    function swap(a,b) {
      var p=local.get(a),q=local.get(b);
      ['x','y','rank'].concat(swapDepth?['depth']:[]).forEach(function (key) { var t=p[key];p[key]=q[key];q[key]=t; });
    }
    for(var pass=0;pass<4;pass++) {
      var changed=false;
      for(var i=0;i<list.length;i++) for(var j=i+1;j<list.length;j++) {
        var a=list[i],b=list[j];if(!eligible(a,b)) continue;
        swap(a,b);var score=embeddingCost(local,graph,step);
        if(score<best-1e-7){best=score;changed=true;}else swap(a,b);
      }
      if(!changed) break;
    }
    return local;
  }

  function relaxAngles(group, graph, local, tree, angles, bounds, mode, step, width) {
    if(group.length>60 || group.length<3) return;
    var hops=new Map();
    group.forEach(function (n) {
      var d=new Map([[n,0]]),queue=[n];
      for(var head=0;head<queue.length;head++) graph.adjacent.get(queue[head]).forEach(function (peer) {
        if(!d.has(peer)){d.set(peer,d.get(queue[head])+1);queue.push(peer);}
      });hops.set(n,d);
    });
    function cost(n) {
      var p=local.get(n),score=0;
      group.forEach(function (peer) {
        if(peer===n) return;
        var q=local.get(peer),d=hops.get(n).get(peer),ideal=1.05*Math.pow(d,.65);
        var error=Math.hypot(p.x-q.x,p.y-q.y)/step-ideal;score+=error*error/(d*d);
        var ox=titleHalf(graph.nodeMap.get(n),width)+titleHalf(graph.nodeMap.get(peer),width)+24-Math.abs(p.x-q.x);
        var oy=104-Math.abs(p.y-q.y);
        if(ox>0 && oy>0) score+=15+Math.min(ox,oy)/10;
      });
      if(group.length<=24) score+=embeddingCost(local,graph,step)*.18;
      return score;
    }
    for(var pass=0;pass<12;pass++) {
      var amount=pass<4?.16:pass<8?.08:.04,changed=false;
      tree.order.slice(1).forEach(function (n) {
        if((mode==='spoke' || mode==='starburst') && tree.depth.get(n)===1) return;
        var p=local.get(n),radius=Math.hypot(p.x,p.y),original=angles.get(n),bestAngle=original,best=cost(n),limit=bounds.get(n);
        [-amount,amount].forEach(function (delta) {
          var angle=Math.max(limit[0],Math.min(limit[1],original+delta));
          p.x=Math.cos(angle)*radius;p.y=Math.sin(angle)*radius;
          var score=cost(n);
          if(score<best-1e-6){best=score;bestAngle=angle;}
        });
        p.x=Math.cos(bestAngle)*radius;p.y=Math.sin(bestAngle)*radius;angles.set(n,bestAngle);
        if(bestAngle!==original) changed=true;
      });
      if(!changed) break;
    }
  }

  function orderedIds(group, graph) {
    return group.slice().sort(function (a, b) {
      return graph.adjacent.get(b).size - graph.adjacent.get(a).size ||
        String(graph.nodeMap.get(a).name || a).localeCompare(String(graph.nodeMap.get(b).name || b)) || String(a).localeCompare(String(b));
    });
  }

  function rootedTree(group, graph, options, directed) {
    var order = orderedIds(group, graph), hub = group.includes(options.focusedNodeId) ? options.focusedNodeId :
      (directed && order.find(function (n) { return graph.incoming.get(n).size === 0; })) || order[0];
    var depth = new Map([[hub, 0]]), children = new Map(), parent = new Map(), queue = [hub];
    for (var head = 0; head < queue.length; head++) {
      var current = queue[head];
      var next = orderedIds(Array.from(graph.adjacent.get(current)), graph);
      if (directed) next.sort(function (a, b) {
        return Number(graph.outgoing.get(current).has(b)) - Number(graph.outgoing.get(current).has(a));
      });
      children.set(current, []);
      next.forEach(function (n) {
        if (depth.has(n)) return;
        depth.set(n, depth.get(current) + 1); parent.set(n, current);
        children.get(current).push(n); queue.push(n);
      });
    }
    var mass = new Map();
    queue.slice().reverse().forEach(function (n) {
      var branch = children.get(n);
      mass.set(n, branch.length ? branch.reduce(function (sum, c) { return sum + mass.get(c); }, 0) : 1);
    });
    return {hub: hub, depth: depth, children: children, parent: parent, order: queue, mass: mass};
  }

  function tidyTree(group, graph, mode, step, width, options) {
    var tree = rootedTree(group, graph, options, true), local = new Map();
    var horizontal = mode === 'treeHorizontal' || options.orientation === 'horizontal';
    var spans = new Map(), siblingGap = step * .22, levelSize = [];
    tree.order.slice().reverse().forEach(function (n) {
      var own = horizontal ? 104 : titleHalf(graph.nodeMap.get(n), width) * 2;
      var kids = tree.children.get(n);
      var total = kids.reduce(function (sum, child) { return sum + spans.get(child); }, 0) + Math.max(0, kids.length - 1) * siblingGap;
      spans.set(n, Math.max(own, total));
      var depth = tree.depth.get(n), axisSize = horizontal ? titleHalf(graph.nodeMap.get(n), width) * 2 : 104;
      levelSize[depth] = Math.max(levelSize[depth] || 0, axisSize);
    });
    var levels = [0];
    for (var i = 1; i < levelSize.length; i++) levels[i] = levels[i-1] + (levelSize[i-1]+levelSize[i])/2 + step * .38;
    function place(n, left) {
      var kids = tree.children.get(n), span = spans.get(n), depth = tree.depth.get(n);
      var total = kids.reduce(function (sum, child) { return sum + spans.get(child); }, 0) + Math.max(0, kids.length - 1) * siblingGap;
      var cursor = left + (span - total) / 2;
      kids.forEach(function (child) { place(child, cursor); cursor += spans.get(child) + siblingGap; });
      var cross = kids.length ? (local.get(kids[0]).cross + local.get(kids[kids.length-1]).cross) / 2 : left + span / 2;
      local.set(n, {x: horizontal ? levels[depth] : cross, y: horizontal ? cross : levels[depth],
        cross: cross, z: depth * 12, depth: depth, rank: tree.order.indexOf(n), isRoot: n === tree.hub});
    }
    place(tree.hub, 0);
    return local;
  }

  function layeredFlow(group, graph, mode, step, width, options) {
    var ordered = orderedIds(group, graph), back = new Map(), seen = new Set(), active = new Set();
    group.forEach(function (n) { back.set(n, new Set()); });
    function visit(n) {
      seen.add(n); active.add(n);
      orderedIds(Array.from(graph.outgoing.get(n)), graph).forEach(function (child) {
        if (active.has(child)) back.get(n).add(child);
        else if (!seen.has(child)) visit(child);
      });
      active.delete(n);
    }
    ordered.forEach(function (n) { if (!seen.has(n)) visit(n); });
    var degree = new Map(), rank = new Map(), queue = [];
    ordered.forEach(function (n) {
      var d = Array.from(graph.incoming.get(n)).filter(function (p) { return !back.get(p).has(n); }).length;
      degree.set(n, d); rank.set(n, 0); if (!d) queue.push(n);
    });
    for (var head = 0; head < queue.length; head++) {
      var n = queue[head];
      orderedIds(Array.from(graph.outgoing.get(n)), graph).forEach(function (child) {
        if (back.get(n).has(child)) return;
        rank.set(child, Math.max(rank.get(child), rank.get(n) + 1));
        degree.set(child, degree.get(child) - 1); if (!degree.get(child)) queue.push(child);
      });
    }
    var rows = [];
    ordered.forEach(function (n) { var r = rank.get(n); (rows[r] || (rows[r] = [])).push(n); });
    var horizontal = mode === 'semantic' || options.orientation === 'horizontal';
    var coords = new Map(), gap = step * .25;
    function crossSize(n) { return horizontal ? 104 : titleHalf(graph.nodeMap.get(n), width) * 2; }
    function project(row, targets) {
      var values = targets.slice(), desiredMean = targets.reduce(function (a,b) { return a+b; }, 0) / row.length;
      for (var i = 1; i < row.length; i++) values[i] = Math.max(values[i], values[i-1] + (crossSize(row[i-1])+crossSize(row[i]))/2 + gap);
      var offset = values.reduce(function (a,b) { return a+b; }, 0) / row.length - desiredMean;
      row.forEach(function (n, i) { coords.set(n, values[i] - offset); });
    }
    rows.forEach(function (row) { project(row, row.map(function (_, i) { return (i - (row.length-1)/2) * step; })); });
    for (var sweep = 0; sweep < 8; sweep++) {
      var indices = rows.map(function (_, i) { return i; }); if (sweep % 2) indices.reverse();
      indices.forEach(function (r) {
        var row = rows[r], prior = new Map(row.map(function (n,i) { return [n,i]; }));
        var targets = new Map();
        row.forEach(function (n) {
          var peers = Array.from(graph.adjacent.get(n)).filter(function (p) { return rank.get(p) !== r; });
          targets.set(n, peers.length ? peers.reduce(function (sum,p) { return sum + coords.get(p); }, 0)/peers.length : coords.get(n));
        });
        row.sort(function (a,b) { return targets.get(a) - targets.get(b) || prior.get(a) - prior.get(b); });
        project(row, row.map(function (n) { return targets.get(n); }));
      });
    }
    var along = [0], axisSizes = rows.map(function (row) {
      return horizontal ? Math.max.apply(null, row.map(function (n) { return titleHalf(graph.nodeMap.get(n), width) * 2; })) : 104;
    });
    for (var r = 1; r < rows.length; r++) along[r] = along[r-1] + (axisSizes[r-1]+axisSizes[r])/2 + step * .3;
    var local = new Map();
    var hasFocus = options && options.focusedNodeId && group.includes(options.focusedNodeId);
    rows.forEach(function (row,r) { row.forEach(function (n,i) {
      var isRoot = hasFocus ? (n === options.focusedNodeId) : (r === 0 && i === 0);
      local.set(n, {x: horizontal ? along[r] : coords.get(n), y: horizontal ? coords.get(n) : along[r],
        z: r*12, depth:r, rank:i, isRoot:isRoot});
    }); });
    // Directed cycles should not be drawn as one collinear stack. Stagger only
    // their cross-axis coordinates; directed layer ranks remain unchanged.
    layers(group,graph.outgoing).forEach(function (row) { row.forEach(function (cycle) {
      if(cycle.length<3 || cycle.some(function(n){return rows[rank.get(n)].length!==1;})) return;
      cycle.slice().sort(function (a,b) { return rank.get(a)-rank.get(b) || String(a).localeCompare(String(b)); }).forEach(function (n,i) {
        var p=local.get(n),shift=(i%2?1:-1)*step*.3;
        if(horizontal) p.y+=shift;else p.x+=shift;
      });
    }); });
    return local;
  }

  // Expand a complete motif without moving individual nodes off its rings,
  // branches or grid. This preserves each mode's geometric constraints.
  function clearMotif(local, graph, width) {
    var entries = Array.from(local.entries()), expansion = 1;
    for (var i = 0; i < entries.length; i++) for (var j = i+1; j < entries.length; j++) {
      var a = entries[i], b = entries[j], dx = Math.abs(a[1].x-b[1].x), dy = Math.abs(a[1].y-b[1].y);
      var requiredX = titleHalf(graph.nodeMap.get(a[0]), width) + titleHalf(graph.nodeMap.get(b[0]), width) + 24;
      if (dx < 1e-8 && dy < 1e-8) throw new Error('Coincident layout nodes: ' + a[0] + ', ' + b[0]);
      expansion = Math.max(expansion, Math.min(requiredX / Math.max(dx,1e-8), 104 / Math.max(dy,1e-8)));
    }
    if (expansion > 1) local.forEach(function (p) { p.x *= expansion; p.y *= expansion; });
    return local;
  }

  function radialTree(group, graph, mode, step, width, options) {
    var tree = rootedTree(group, graph, options, false), local = new Map(), angles = new Map(), bounds = new Map();
    var catIndexMap = null;
    local.set(tree.hub, {x:0,y:0,z:0,depth:0,rank:0,isRoot:true});
    if (group.length === 1) return local;
    function sector(n, start, span, equal) {
      var kids = tree.children.get(n), total = kids.reduce(function (s,c) { return s + (equal ? 1 : tree.mass.get(c)); }, 0);
      var cursor = start;
      kids.forEach(function (child) {
        var childSpan = span * (equal ? 1 : tree.mass.get(child)) / total;
        angles.set(child, cursor + childSpan / 2);
        bounds.set(child,[cursor+(mode==='concentric'?-childSpan*.1:childSpan*.1),cursor+childSpan*(mode==='concentric'?1.1:.9)]);
        sector(child, cursor, childSpan, false); cursor += childSpan;
      });
    }
    sector(tree.hub, -Math.PI, Math.PI*2, mode === 'spoke' || mode === 'starburst');
    if (mode === 'concentric') {
      // Align descendants with their parent's sector. Re-starting every ring at
      // twelve o'clock makes single-child chains cut back across the central hub.
      var first = tree.children.get(tree.hub)[0], rotation = -Math.PI/2-angles.get(first);
      angles.forEach(function (angle,n) { angles.set(n,angle+rotation);var b=bounds.get(n);bounds.set(n,[b[0]+rotation,b[1]+rotation]); });
    } else if (mode === 'dandelion') {
      var categories = new Map();
      catIndexMap = new Map();
      orderedIds(group.filter(function (n) { return n !== tree.hub; }), graph).forEach(function (n) {
        var cat = graph.nodeMap.get(n).group || '其他'; if (!categories.has(cat)) categories.set(cat,[]); categories.get(cat).push(n);
      });
      var cursor = -Math.PI * 1.15, fan = Math.PI * 1.65;
      Array.from(categories.keys()).sort().forEach(function (cat) {
        var list = circularOrder(categories.get(cat), graph), span = fan * list.length / (group.length-1);
        list.forEach(function (n,i) {
          var angle=cursor+span*(i+.5)/list.length,pitch=span/list.length;
          angles.set(n,angle);bounds.set(n,[angle-pitch*.3,angle+pitch*.3]);
          catIndexMap.set(n, i);
        }); cursor += span;
      });
    }
    tree.order.slice(1).forEach(function (n,i) {
      var depth = tree.depth.get(n), angle = angles.get(n), radius;
      if (mode === 'dandelion') {
        var cIdx = (catIndexMap && catIndexMap.get(n)) != null ? catIndexMap.get(n) : i;
        radius = step * (1.12 + Math.floor(cIdx / 4) * .80 + (cIdx % 2 ? .20 : 0));
      }
      else if (mode === 'starburst') radius = step * (1.1 + (depth-1) * .65);
      else radius = step * depth * (mode === 'spoke' ? .9 : 1);
      local.set(n, {x:Math.cos(angle)*radius,y:Math.sin(angle)*radius,z:depth*12,depth:depth,rank:i,isRoot:false});
    });
    relaxAngles(group,graph,local,tree,angles,bounds,mode,step,width);
    return clearMotif(local, graph, width);
  }

  function circularOrder(list, graph) {
    if (list.length < 3) return list.slice();
    var remaining = new Set(orderedIds(list, graph)), result = [], current = remaining.values().next().value;
    while (remaining.size) {
      remaining.delete(current); result.push(current);
      var candidates = orderedIds(Array.from(remaining), graph);
      current = candidates.find(function (n) { return graph.adjacent.get(result[result.length-1]).has(n); }) || candidates[0];
    }
    return result;
  }

  function groupedLayout(group, graph, mode, step, width, options) {
    var order = orderedIds(group, graph), membership = new Map();
    order.forEach(function (n) { membership.set(n, mode === 'groupedCircular' ? graph.nodeMap.get(n).group || '其他' : n); });
    if (mode === 'clusteredForce') {
      var volume = new Map(), total = group.reduce(function (sum,n) { return sum + graph.adjacent.get(n).size; }, 0) || 1;
      order.forEach(function (n) { volume.set(n, graph.adjacent.get(n).size); });
      for (var pass = 0; pass < 12; pass++) {
        var changed = false;
        order.forEach(function (n) {
          var current = membership.get(n), degree = graph.adjacent.get(n).size, counts = new Map();
          volume.set(current, volume.get(current)-degree);
          graph.adjacent.get(n).forEach(function (peer) { var m = membership.get(peer); counts.set(m,(counts.get(m)||0)+1); });
          var best = current, score = (counts.get(current)||0) - degree*(volume.get(current)||0)/total;
          Array.from(counts.keys()).sort().forEach(function (candidate) {
            var gain = counts.get(candidate) - degree*(volume.get(candidate)||0)/total;
            if (gain > score + 1e-8) { best=candidate;score=gain; }
          });
          membership.set(n,best); volume.set(best,(volume.get(best)||0)+degree); if (best!==current) changed=true;
        });
        if (!changed) break;
      }
    }
    var communities = new Map();
    order.forEach(function (n) { var key=membership.get(n); if (!communities.has(key)) communities.set(key,[]); communities.get(key).push(n); });
    var hasFocus = options && options.focusedNodeId && group.includes(options.focusedNodeId);
    var root = hasFocus ? options.focusedNodeId : order[0];
    var groups = Array.from(communities.values()).sort(function (a,b) {
      if (hasFocus) {
        if (a.includes(root)) return -1;
        if (b.includes(root)) return 1;
      }
      return b.length-a.length || String(a[0]).localeCompare(String(b[0]));
    });
    var motifs = groups.map(function (list) {
      var local = new Map(), circle = circularOrder(list,graph);
      var hub = (hasFocus && list.includes(root)) ? root : circle[0];
      if (circle.includes(hub) && circle[0] !== hub) {
        circle.splice(circle.indexOf(hub), 1);
        circle.unshift(hub);
      }
      var central = mode === 'clusteredForce' && circle.length > 3;
      var rim = central ? circle.slice(1) : circle;
      if (central) local.set(hub,{x:0,y:0});
      var radius = rim.length < 2 ? 0 : Math.max(step*.72,rim.length*step/(Math.PI*2));
      rim.forEach(function (n,i) { var angle = -Math.PI/2+i*Math.PI*2/rim.length; local.set(n,{x:Math.cos(angle)*radius,y:Math.sin(angle)*radius}); });
      clearMotif(local,graph,width);
      var extent = Math.max.apply(null,Array.from(local.entries()).map(function (e) { return Math.hypot(e[1].x,e[1].y)+titleHalf(graph.nodeMap.get(e[0]),width); }));
      return {local:local,radius:extent};
    });
    var macro = 0;
    for (var i=0;i<motifs.length;i++) for(var j=i+1;j<motifs.length;j++) {
      var chord = 2*Math.sin(Math.PI*(j-i)/motifs.length);
      macro=Math.max(macro,(motifs[i].radius+motifs[j].radius+step*.25)/chord);
    }
    var local = new Map();
    motifs.forEach(function (motif,i) {
      var angle = motifs.length === 2 ? i*Math.PI : -Math.PI/2+i*Math.PI*2/motifs.length;
      motif.local.forEach(function (p,n) {
        local.set(n,{x:p.x+Math.cos(angle)*macro,y:p.y+Math.sin(angle)*macro,z:i*10,
          depth:n===root?0:1,rank:order.indexOf(n),isRoot:n===root});
      });
    });
    return improveOrder(local,graph,step,function (a,b) {
      return a!==root && b!==root && local.get(a).z===local.get(b).z;
    },false);
  }

  function regularGrid(group, graph, step, width, height, options) {
    options = options || {};
    var order = circularOrder(group,graph);
    var hasFocus = options.focusedNodeId && group.includes(options.focusedNodeId);
    var root = hasFocus ? options.focusedNodeId : order[0];
    if (hasFocus) {
      var rIdx = order.indexOf(root);
      if (rIdx > 0) {
        order.splice(rIdx, 1);
        order.unshift(root);
      }
    }
    var cellX = Math.max(step*1.1,Math.max.apply(null,group.map(function (n) { return titleHalf(graph.nodeMap.get(n),width)*2; }))+step*.2);
    var cellY = Math.max(104,step*.7), aspect = Math.min(1.8,Math.max(.5,width/height)), columns=1,best=Infinity;
    var exact=group.length<=32 && group.reduce(function(sum,n){return sum+graph.adjacent.get(n).size;},0)<=160;
    function grid(cols) {
      var result=new Map();
      order.forEach(function(n,i){
        var row=Math.floor(i/cols),count=Math.min(cols,group.length-row*cols),col=i%cols;
        if(row%2) col=count-1-col;
        result.set(n,{x:(col-(count-1)/2)*cellX,y:row*cellY,z:0,depth:n===root?0:row+1,rank:col,isRoot:n===root});
      });return result;
    }
    for(var c=1;c<=group.length;c++) {
      var rows=Math.ceil(group.length/c),ratio=c*cellX/(rows*cellY);
      var score=Math.abs(Math.log(ratio/aspect))+(rows*c-group.length)/group.length*.35+(exact?embeddingCost(grid(c),graph,step)*.12:0);
      if(score<best){best=score;columns=c;}
    }
    var local=grid(columns);
    return improveOrder(local,graph,step,function(a,b){return a!==root && b!==root;},true);
  }

  function positions(nodes, links, mode, width, height, options) {
    options = options || {};
    var spacing = Math.max(.7, Math.min(2, Number(options.spacing) || 1));
    var graph = topology(nodes, links), result = new Map(), boxes = [], step = 190 * spacing;
    var focusedNodeId = options.focusedNodeId;
    var primaryCompIdx = focusedNodeId
      ? graph.components.findIndex(function (g) { return g.includes(focusedNodeId); })
      : 0;
    if (primaryCompIdx < 0) primaryCompIdx = 0;

    graph.components.forEach(function (group, cIdx) {
      var local = new Map();
      var groupNodeObjs = group.map(function (id) { return graph.nodeMap.get(id) || { id: id, name: id }; });
      var groupDegree = function (id) { return (graph.adjacent.get(id) || new Set()).size; };
      var groupOrdered = groupNodeObjs.slice().sort(function (a, b) {
        return groupDegree(b.id) - groupDegree(a.id) ||
          String(a.group || '').localeCompare(String(b.group || '')) ||
          String(a.name || a.id).localeCompare(String(b.name || b.id));
      });

      if (mode === 'hierarchy') {
        var levels = layers(group, graph.outgoing), y = 0;
        var hasFocus = options.focusedNodeId && group.includes(options.focusedNodeId);
        levels.forEach(function (row, rIdx) {
          var sizes = row.map(function (cluster) { return cluster.length > 1 ? Math.max(step * 1.5, cluster.length * step / Math.PI) : step; });
          var total = sizes.reduce(function (a, b) { return a + b + step * .3; }, 0), x = -total / 2;
          var rowHeight = Math.max.apply(null, sizes);
          row.forEach(function (cluster, i) {
            var center = x + sizes[i] / 2, orbit = sizes[i] * .4;
            cluster.forEach(function (node, j) {
              var angle = j * Math.PI * 2 / cluster.length - (cluster.length === 2 ? 0 : Math.PI / 2);
              var isRoot = hasFocus ? (node === options.focusedNodeId) : (rIdx === 0 && i === 0 && j === 0);
              local.set(node, {x: center + (cluster.length > 1 ? Math.cos(angle) * orbit : 0),
                y: y + rowHeight / 2 + (cluster.length > 1 ? Math.sin(angle) * orbit : 0), z: 0,
                depth: rIdx, rank: i * 10 + j, isRoot: isRoot});
            }); x += sizes[i] + step * .3;
          }); y += rowHeight + step * .4;
        });
        if (options.orientation === 'horizontal') local.forEach(function (point) { var x = point.x; point.x = point.y; point.y = x; });
      } else if (mode === 'semantic' || mode === 'dagre') {
        local = layeredFlow(group, graph, mode, step, width, options);
      } else if (mode === 'treeVertical' || mode === 'treeHorizontal') {
        local = tidyTree(group, graph, mode, step, width, options);
      } else if (mode === 'concentric' || mode === 'dandelion' || mode === 'starburst' || mode === 'spoke') {
        local = radialTree(group, graph, mode, step, width, options);
      } else if (mode === 'clusteredForce' || mode === 'groupedCircular') {
        local = groupedLayout(group, graph, mode, step, width, options);
      } else if (mode === 'grid') {
        local = regularGrid(group, graph, step, width, height, options);
      } else if (mode === 'organic' || mode === 'force') {
        var hasFocus = options.focusedNodeId && group.includes(options.focusedNodeId);
        if (group.length === 1) {
          local.set(group[0], { x: 0, y: 0, z: 0, depth: 0, rank: 0, isRoot: true });
        } else if (group.length === 2) {
          var d2 = step * 0.72;
          var rootNode = (hasFocus && groupOrdered[1].id === options.focusedNodeId) ? groupOrdered[1] : groupOrdered[0];
          var childNode = (rootNode.id === groupOrdered[0].id) ? groupOrdered[1] : groupOrdered[0];
          local.set(rootNode.id, { x: -d2 / 2, y: 0, z: 0, depth: 0, rank: 0, isRoot: true });
          local.set(childNode.id, { x: d2 / 2, y: 0, z: 0, depth: 1, rank: 1, isRoot: false });
        } else if (group.length === 3) {
          // Symmetrical equilateral triangle centered at (0, 0)
          var triR = step * 0.82;
          var baseAngleTri = -Math.PI / 2;
          var focusedIdx = hasFocus ? groupOrdered.findIndex(function (n) { return n.id === options.focusedNodeId; }) : -1;
          var rootIdx = focusedIdx >= 0 ? focusedIdx : 0;
          groupOrdered.forEach(function (node, i) {
            var angle = baseAngleTri + ((i - rootIdx + 3) % 3) * (Math.PI * 2 / 3);
            local.set(node.id, {
              x: Math.cos(angle) * triR,
              y: Math.sin(angle) * triR,
              z: i * 10,
              depth: i === rootIdx ? 0 : 1,
              rank: i,
              isRoot: i === rootIdx
            });
          });
        } else {
          var hub = (hasFocus && groupOrdered.find(function (n) { return n.id === options.focusedNodeId; })) || groupOrdered[0];
          local.set(hub.id, { x: 0, y: 0, z: 0, depth: 0, rank: 0, isRoot: true });
          var visited = new Set([hub.id]);
          var depthMap = new Map([[hub.id, 0]]);
          var childrenMap = new Map();
          var queue = [hub.id];
          while (queue.length) {
            var curr = queue.shift();
            var currDepth = depthMap.get(curr) || 0;
            var children = Array.from(graph.adjacent.get(curr) || [])
              .filter(function (nbr) { return group.indexOf(nbr) >= 0 && !visited.has(nbr); })
              .sort(function (a, b) {
                return groupDegree(b) - groupDegree(a) || String(a).localeCompare(String(b));
              });
            childrenMap.set(curr, children);
            children.forEach(function (ch) {
              visited.add(ch);
              depthMap.set(ch, currDepth + 1);
              queue.push(ch);
            });
          }

          var l1 = childrenMap.get(hub.id) || [];
          var l1Count = Math.max(1, l1.length);
          var l1Radius = Math.max(step * 1.10, l1Count * 48);
          var baseAngle = -Math.PI / 2;
          var angleMap = new Map();

          // Order L1 nodes via greedy nearest-neighbor chain walk to minimize spoke crossings
          if (l1.length > 2) {
            var l1Set = new Set(l1);
            var placed = [l1[0]];
            l1Set.delete(l1[0]);
            while (l1Set.size) {
              var last = placed[placed.length - 1];
              var lastAdj = graph.adjacent.get(last) || new Set();
              var bestId = null, bestScore = -1;
              l1Set.forEach(function (candidate) {
                var score = lastAdj.has(candidate) ? 1000 : 0;
                score += groupDegree(candidate);
                // Favor candidates whose own L1 neighbors are already placed (closing triangles)
                var candAdj = graph.adjacent.get(candidate) || new Set();
                placed.forEach(function (p) { if (candAdj.has(p)) score += 200; });
                if (score > bestScore || (score === bestScore && String(candidate) < String(bestId))) {
                  bestScore = score; bestId = candidate;
                }
              });
              placed.push(bestId);
              l1Set.delete(bestId);
            }
            l1.length = 0;
            placed.forEach(function (id) { l1.push(id); });
          }

          l1.forEach(function (id, idx) {
            var angle = baseAngle + idx * (Math.PI * 2 / l1Count);
            angleMap.set(id, angle);
            local.set(id, {
              x: Math.cos(angle) * l1Radius,
              y: Math.sin(angle) * l1Radius,
              z: 10,
              depth: 1,
              rank: idx,
              isRoot: false
            });
          });

          function walkDescendants(pId, pDepth) {
            var children = childrenMap.get(pId) || [];
            if (!children.length) return;
            var pPos = local.get(pId);
            var pAngle = Math.atan2(pPos.y, pPos.x);
            var cCount = children.length;
            var branchDist = step * 0.96;

            children.forEach(function (cId, cIdx) {
              var branchAngle;
              if (cCount === 1) {
                // Natural outward continuation with subtle curve
                var curl = (pAngle >= 0 ? 0.22 : -0.22);
                branchAngle = pAngle + curl;
              } else {
                var spread = Math.min(1.2, (cCount - 1) * 0.45);
                branchAngle = pAngle + (-spread / 2 + cIdx * (spread / Math.max(1, cCount - 1)));
              }
              angleMap.set(cId, branchAngle);
              local.set(cId, {
                x: pPos.x + Math.cos(branchAngle) * branchDist,
                y: pPos.y + Math.sin(branchAngle) * branchDist,
                z: pDepth * 10,
                depth: pDepth,
                rank: cIdx,
                isRoot: false
              });
              walkDescendants(cId, pDepth + 1);
            });
          }
          l1.forEach(function (id) { walkDescendants(id, 2); });

          var remaining = groupOrdered.filter(function (n) { return !visited.has(n.id); });
          if (remaining.length) {
            var remRadius = l1Radius + step * 1.40;
            remaining.forEach(function (n, idx) {
              var angle = baseAngle + idx * (Math.PI * 2 / Math.max(1, remaining.length));
              local.set(n.id, {
                x: Math.cos(angle) * remRadius,
                y: Math.sin(angle) * remRadius,
                z: 20,
                depth: 2,
                rank: idx,
                isRoot: false
              });
            });
          }
          // Legacy force mode keeps its spring seed; organic uses stress solving below.
          for (var iter = 0; iter < (mode === 'force' ? 130 : 0); iter++) {
            var forces = new Map();
            group.forEach(function (id) { forces.set(id, { fx: 0, fy: 0 }); });

            // 1. Coulomb electrostatic repulsion between all pairs of nodes in group
            for (var i = 0; i < group.length; i++) {
              var idA = group[i], posA = local.get(idA);
              for (var j = i + 1; j < group.length; j++) {
                var idB = group[j], posB = local.get(idB);
                var dx = posB.x - posA.x, dy = posB.y - posA.y;
                var dist = Math.max(20, Math.hypot(dx, dy));
                var rep = Math.min(65, 42000 / (dist * dist));
                var rx = (dx / dist) * rep, ry = (dy / dist) * rep;
                forces.get(idA).fx -= rx; forces.get(idA).fy -= ry;
                forces.get(idB).fx += rx; forces.get(idB).fy += ry;
              }
            }

            // 2. Hooke's spring attraction along edges
            group.forEach(function (idA) {
              var posA = local.get(idA);
              (graph.adjacent.get(idA) || new Set()).forEach(function (idB) {
                if (group.indexOf(idB) <= group.indexOf(idA)) return;
                var posB = local.get(idB);
                var dx = posB.x - posA.x, dy = posB.y - posA.y;
                var dist = Math.max(1, Math.hypot(dx, dy));
                var isLeaf = (graph.adjacent.get(idA) || new Set()).size === 1 || (graph.adjacent.get(idB) || new Set()).size === 1;
                var idealDist = isLeaf ? step * 0.78 : step * 0.94;
                var spring = (dist - idealDist) * 0.046;
                var sx = (dx / dist) * spring, sy = (dy / dist) * spring;
                forces.get(idA).fx += sx; forces.get(idA).fy += sy;
                forces.get(idB).fx -= sx; forces.get(idB).fy -= sy;
              });
            });

            // 3. Apply displacement with damping, anchoring hub softly to (0, 0)
            var cooling = Math.max(0.12, 1 - iter / 150);
            group.forEach(function (id) {
              var pt = local.get(id), f = forces.get(id);
              if (id === hub.id) {
                pt.x += f.fx * 0.08 * cooling - pt.x * 0.04;
                pt.y += f.fy * 0.08 * cooling - pt.y * 0.04;
              } else {
                pt.x += f.fx * 0.38 * cooling - pt.x * 0.008;
                pt.y += f.fy * 0.38 * cooling - pt.y * 0.008;
              }
            });
          }
        }
      } else {
        // ring / default single orbit fallback
        var orbit = Math.max(step * .6, step * group.length / (Math.PI * 2));
        group.forEach(function (node, i) {
          var angle = i * Math.PI * 2 / group.length - Math.PI / 2;
          local.set(node, { x: group.length === 1 ? 0 : Math.cos(angle) * orbit,
            y: group.length === 1 ? 0 : Math.sin(angle) * orbit,
            z: group.length > 2 ? Math.sin(angle * 2) * orbit * .18 : 0,
            depth: i === 0 ? 0 : 1, rank: i, isRoot: i === 0 });
        });
      }

      if (mode === 'organic') relaxOrganic(group, graph, local, step, width, height);
      if (modes.includes(mode) && mode !== 'organic') clearMotif(local, graph, width);
      var values = Array.from(local.values());
      var minX = Math.min.apply(null, values.map(function (p) { return p.x; }));
      var minY = Math.min.apply(null, values.map(function (p) { return p.y; }));
      var maxX = Math.max.apply(null, values.map(function (p) { return p.x; }));
      var maxY = Math.max.apply(null, values.map(function (p) { return p.y; }));
      var isSmall = group.length <= 2;
      var padX = isSmall ? Math.max(48, step * 0.22) : Math.max(64, step * 0.32);
      if (mode === 'organic') groupNodeObjs.forEach(function (node) {
        padX = Math.max(padX, (Number(node.labelWidth) || Math.min(width < 600 ? 12 : 28, Array.from(String(node.name || node.id)).length) * 11 + 24) / 2 + (isSmall ? 6 : 10));
      });
      if (modes.includes(mode) && mode !== 'organic') groupNodeObjs.forEach(function (node) {
        padX = Math.max(padX, titleHalf(node, width) + (isSmall ? 6 : 10));
      });
      var padY = isSmall ? Math.max(36, step * 0.18) : Math.max(48, step * 0.24);
      boxes.push({
        local: local,
        cIdx: cIdx,
        isPrimary: cIdx === primaryCompIdx,
        minX: minX, minY: minY,
        width: maxX - minX + padX * 2,
        height: maxY - minY + padY * 2,
        padX: padX, padY: padY
      });
    });

    var gap = modes.includes(mode) ? step * .35 : Math.max(160, step * 0.80);
    var targetAspect = modes.includes(mode)
      ? Math.min(2.2, Math.max(width < 600 ? .45 : 1.15, (width || 900) / (height || 700)))
      : Math.min(1.65, Math.max(1.15, (width || 900) / (height || 700)));

    function solveShelf(boxList) {
      if (!boxList.length) return { shelf: 0, rows: [] };
      var area = boxList.reduce(function (sum, box) { return sum + box.width * box.height; }, 0);
      var widest = Math.max(1, ...boxList.map(function (box) { return box.width; }));
      var targetWidth = Math.max(widest, Math.sqrt(area * targetAspect));
      var candidates = [widest, targetWidth];
      var prefix = 0;
      boxList.forEach(function (box) { prefix += box.width + (prefix ? gap : 0); candidates.push(prefix); });

      var bestShelf = widest, bestScore = -Infinity;
      candidates.forEach(function (candidate) {
        candidate = Math.max(widest, candidate);
        var x = 0, y = 0, rowHeight = 0, usedWidth = 0;
        boxList.forEach(function (box) {
          if (x && x + box.width > candidate + .01) { x = 0; y += rowHeight + gap; rowHeight = 0; }
          usedWidth = Math.max(usedWidth, x + box.width);
          x += box.width + gap;
          rowHeight = Math.max(rowHeight, box.height);
        });
        var usedHeight = y + rowHeight;
        var curAspect = usedWidth / Math.max(1, usedHeight);
        var logAspectDiff = Math.abs(Math.log(curAspect / targetAspect));
        var areaEff = area / Math.max(1, usedWidth * usedHeight);
        var score = areaEff / (1 + logAspectDiff * logAspectDiff * 3.6);
        if (score > bestScore) { bestScore = score; bestShelf = candidate; }
      });

      var rows = [], currentRow = { boxes: [], width: 0, height: 0 };
      boxList.forEach(function (box) {
        if (currentRow.boxes.length && currentRow.width + gap + box.width > bestShelf + .01) {
          rows.push(currentRow);
          currentRow = { boxes: [], width: 0, height: 0 };
        }
        if (currentRow.boxes.length) currentRow.width += gap;
        currentRow.boxes.push(box);
        currentRow.width += box.width;
        currentRow.height = Math.max(currentRow.height, box.height);
      });
      if (currentRow.boxes.length) rows.push(currentRow);
      return { shelf: bestShelf, rows: rows };
    }

    var connectedBoxes = boxes.filter(function (b) { return b.local.size > 1; });
    var isolatedBoxes = boxes.filter(function (b) { return b.local.size === 1; });
    var rows = [];

    if (connectedBoxes.length > 0 && isolatedBoxes.length > 0) {
      var connectedPacked = solveShelf(connectedBoxes);
      var maxConnWidth = Math.max(1, ...connectedPacked.rows.map(function (r) { return r.width; }));
      var isolatedShelf = Math.max(maxConnWidth, connectedPacked.shelf);
      var isoRows = [], curIsoRow = { boxes: [], width: 0, height: 0, isIsolated: true };
      isolatedBoxes.forEach(function (box) {
        if (curIsoRow.boxes.length && curIsoRow.width + gap + box.width > isolatedShelf + .01) {
          isoRows.push(curIsoRow);
          curIsoRow = { boxes: [], width: 0, height: 0, isIsolated: true };
        }
        if (curIsoRow.boxes.length) curIsoRow.width += gap;
        curIsoRow.boxes.push(box);
        curIsoRow.width += box.width;
        curIsoRow.height = Math.max(curIsoRow.height, box.height);
      });
      if (curIsoRow.boxes.length) isoRows.push(curIsoRow);
      rows = connectedPacked.rows.concat(isoRows);
    } else {
      rows = solveShelf(boxes).rows;
    }

    var maxRowWidth = Math.max(1, ...rows.map(function (r) { return r.width; }));
    var curY = 0;
    rows.forEach(function (r, rIdx) {
      var curX = (rows.length > 1 && r.boxes.length === 1) ? 0 : (maxRowWidth - r.width) / 2;
      r.boxes.forEach(function (box) {
        var boxOffsetY = (r.height - box.height) / 2;
        var cx = curX + box.width / 2, cy = curY + boxOffsetY + box.height / 2;
        box.local.forEach(function (point, node) {
          result.set(node, {
            x: curX + point.x - box.minX + box.padX,
            y: curY + boxOffsetY + point.y - box.minY + box.padY,
            z: point.z, cx: cx, cy: cy,
            depth: point.depth != null ? point.depth : 0,
            rank: point.rank != null ? point.rank : 0,
            isRoot: focusedNodeId ? (node === focusedNodeId) : (box.isPrimary && !!point.isRoot)
          });
        });
        curX += box.width + gap;
      });
      var isTransition = rIdx > 0 && !rows[rIdx - 1].isIsolated && r.isIsolated;
      curY += r.height + (isTransition ? gap * 1.35 : gap);
    });

    if (mode === 'force') result.forEach(function (p, node) {
      var seed = Array.from(String(node)).reduce(function (n, c) { return n + c.charCodeAt(0); }, 0);
      p.x += Math.sin(seed) * 16; p.y += Math.cos(seed) * 16;
    });

    var allXs = Array.from(result.values()).map(function (p) { return p.x; });
    var allYs = Array.from(result.values()).map(function (p) { return p.y; });
    if (allXs.length) {
      var minLX = Math.min.apply(null, allXs), maxLX = Math.max.apply(null, allXs);
      var minLY = Math.min.apply(null, allYs), maxLY = Math.max.apply(null, allYs);
      var shiftX = width / 2 - (minLX + maxLX) / 2;
      var shiftY = height / 2 - (minLY + maxLY) / 2;
      result.forEach(function (p) {
        p.x += shiftX;
        p.y += shiftY;
        p.cx = (p.cx || 0) + shiftX;
        p.cy = (p.cy || 0) + shiftY;
      });
    }

    return result;
  }

  function lineage(nodeId, links) {
    var upstreamNodes = new Set(), downstreamNodes = new Set();
    var upstreamEdges = new Set(), downstreamEdges = new Set();
    if (!nodeId) return { upstreamNodes: upstreamNodes, downstreamNodes: downstreamNodes,
      upstreamEdges: upstreamEdges, downstreamEdges: downstreamEdges };
    upstreamNodes.add(nodeId); downstreamNodes.add(nodeId);

    var upQueue = [nodeId], upVisited = new Set([nodeId]);
    while (upQueue.length) {
      var curr = upQueue.shift();
      (links || []).forEach(function (edge) {
        var s = id(edge.source), t = id(edge.target);
        var rev = edge.direction === 'reverse';
        var bi = edge.direction === 'both' || edge.bidirectional;
        var from = rev ? t : s, to = rev ? s : t;
        if (to === curr && !upVisited.has(from)) {
          upVisited.add(from); upstreamNodes.add(from);
          upstreamEdges.add(edge.id); upQueue.push(from);
        } else if (bi && from === curr && !upVisited.has(to)) {
          upVisited.add(to); upstreamNodes.add(to);
          upstreamEdges.add(edge.id); upQueue.push(to);
        }
      });
    }

    var downQueue = [nodeId], downVisited = new Set([nodeId]);
    while (downQueue.length) {
      var currD = downQueue.shift();
      (links || []).forEach(function (edge) {
        var s = id(edge.source), t = id(edge.target);
        var rev = edge.direction === 'reverse';
        var bi = edge.direction === 'both' || edge.bidirectional;
        var from = rev ? t : s, to = rev ? s : t;
        if (from === currD && !downVisited.has(to)) {
          downVisited.add(to); downstreamNodes.add(to);
          downstreamEdges.add(edge.id); downQueue.push(to);
        } else if (bi && to === currD && !downVisited.has(from)) {
          downVisited.add(from); downstreamNodes.add(from);
          downstreamEdges.add(edge.id); downQueue.push(from);
        }
      });
    }

    return {
      upstreamNodes: upstreamNodes,
      downstreamNodes: downstreamNodes,
      upstreamEdges: upstreamEdges,
      downstreamEdges: downstreamEdges
    };
  }

  return {
    modes: modes, labels: labels, hints: hints, categories: categories, next: next, positions: positions,
    lineage: lineage,
    components: function (nodes, links) { return topology(nodes, links).components; }
  };
});
