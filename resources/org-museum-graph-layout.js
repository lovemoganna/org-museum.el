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
    organic: '纯物理引力与斥力模拟，自然聚合成团，最具探索动感。',
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

  function positions(nodes, links, mode, width, height, options) {
    options = options || {};
    var spacing = Math.max(.7, Math.min(2, Number(options.spacing) || 1));
    var graph = topology(nodes, links), result = new Map(), boxes = [], step = 190 * spacing;

    graph.components.forEach(function (group) {
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
        levels.forEach(function (row, rIdx) {
          var sizes = row.map(function (cluster) { return cluster.length > 1 ? Math.max(step * 1.5, cluster.length * step / Math.PI) : step; });
          var total = sizes.reduce(function (a, b) { return a + b + step * .3; }, 0), x = -total / 2;
          var rowHeight = Math.max.apply(null, sizes);
          row.forEach(function (cluster, i) {
            var center = x + sizes[i] / 2, orbit = sizes[i] * .4;
            cluster.forEach(function (node, j) {
              var angle = j * Math.PI * 2 / cluster.length - (cluster.length === 2 ? 0 : Math.PI / 2);
              local.set(node, {x: center + (cluster.length > 1 ? Math.cos(angle) * orbit : 0),
                y: y + rowHeight / 2 + (cluster.length > 1 ? Math.sin(angle) * orbit : 0), z: 0,
                depth: rIdx, rank: i * 10 + j, isRoot: rIdx === 0});
            }); x += sizes[i] + step * .3;
          }); y += rowHeight + step * .4;
        });
        if (options.orientation === 'horizontal') local.forEach(function (point) { var x = point.x; point.x = point.y; point.y = x; });
      } else if (mode === 'semantic' || mode === 'dagre' || mode === 'treeVertical' || mode === 'treeHorizontal') {
        var isHorizontal = mode === 'semantic' || mode === 'treeHorizontal' || options.orientation === 'horizontal';
        var isTree = mode === 'treeVertical' || mode === 'treeHorizontal';
        var layerGroups = [];

        if (isTree) {
          // BFS Tree depth groups (from DuckDB Editor)
          var depth = new Map(), todo = [], unseen = new Set(group);
          while (unseen.size) {
            var root = groupOrdered.find(function (n) { return unseen.has(n.id) && (graph.incoming.get(n.id) || new Set()).size === 0; }) ||
              groupOrdered.find(function (n) { return unseen.has(n.id); });
            depth.set(root.id, 0); unseen.delete(root.id); todo.push(root.id);
            while (todo.length) {
              var currId = todo.shift();
              var nextNodes = Array.from(graph.outgoing.get(currId) || []).filter(function (id) { return group.indexOf(id) >= 0; });
              nextNodes.sort(function (a, b) { return groupDegree(b) - groupDegree(a) || String(a).localeCompare(String(b)); });
              nextNodes.forEach(function (ch) {
                if (unseen.has(ch)) { unseen.delete(ch); depth.set(ch, depth.get(currId) + 1); todo.push(ch); }
              });
            }
          }
          groupOrdered.forEach(function (n) {
            var lvl = depth.get(n.id) || 0;
            if (!layerGroups[lvl]) layerGroups[lvl] = [];
            layerGroups[lvl].push(n.id);
          });
          layerGroups = layerGroups.filter(Boolean);
        } else {
          // Longest-Path DAG Layering with cycle breaking (from DuckDB Editor)
          var visited = new Set(), inStack = new Set(), backEdges = new Set();
          function detectBack(u) {
            visited.add(u); inStack.add(u);
            (graph.outgoing.get(u) || new Set()).forEach(function (v) {
              if (group.indexOf(v) < 0) return;
              if (!visited.has(v)) detectBack(v);
              else if (inStack.has(v)) backEdges.add(u + '|' + v);
            });
            inStack.delete(u);
          }
          groupOrdered.forEach(function (n) { if (!visited.has(n.id)) detectBack(n.id); });

          var inDeg = new Map(), ranks = new Map();
          group.forEach(function (id) {
            var d = 0;
            (graph.incoming.get(id) || new Set()).forEach(function (p) {
              if (group.indexOf(p) >= 0 && !backEdges.has(p + '|' + id)) d++;
            });
            inDeg.set(id, d);
          });
          var q = groupOrdered.filter(function (n) { return (inDeg.get(n.id) || 0) === 0; }).map(function (n) { return n.id; });
          if (!q.length && group.length) q = [groupOrdered[0].id];
          q.forEach(function (id) { ranks.set(id, 0); });
          var cur = 0;
          while (cur < q.length) {
            var u = q[cur++];
            var rU = ranks.get(u) || 0;
            (graph.outgoing.get(u) || new Set()).forEach(function (v) {
              if (group.indexOf(v) < 0 || backEdges.has(u + '|' + v)) return;
              var nextR = rU + 1;
              if (!ranks.has(v) || ranks.get(v) < nextR) {
                ranks.set(v, nextR);
                q.push(v);
              }
            });
          }
          group.forEach(function (id) { if (!ranks.has(id)) ranks.set(id, 0); });
          var allRanks = Array.from(new Set(Array.from(ranks.values()))).sort(function (a, b) { return a - b; });
          var rankMap = new Map(allRanks.map(function (r, i) { return [r, i]; }));
          layerGroups = Array.from({ length: Math.max(allRanks.length, 1) }, function () { return []; });
          groupOrdered.forEach(function (node) {
            var li = rankMap.get(ranks.get(node.id)) || 0;
            layerGroups[li].push(node.id);
          });
          layerGroups = layerGroups.filter(function (l) { return l.length > 0; });
        }

        // Bi-directional barycentric crossing minimization
        for (var sweep = 0; sweep < 4; sweep++) {
          if (sweep % 2 === 0) {
            for (var lIdx = 1; lIdx < layerGroups.length; lIdx++) {
              var prevPos = new Map(layerGroups[lIdx - 1].map(function (id, idx) { return [id, idx]; }));
              layerGroups[lIdx].sort(function (a, b) {
                var pA = Array.from(graph.incoming.get(a) || []).filter(function (id) { return prevPos.has(id); });
                var pB = Array.from(graph.incoming.get(b) || []).filter(function (id) { return prevPos.has(id); });
                var bcA = pA.length ? pA.reduce(function (s, id) { return s + prevPos.get(id); }, 0) / pA.length : layerGroups[lIdx].indexOf(a);
                var bcB = pB.length ? pB.reduce(function (s, id) { return s + prevPos.get(id); }, 0) / pB.length : layerGroups[lIdx].indexOf(b);
                return bcA - bcB || String(a).localeCompare(String(b));
              });
            }
          } else {
            for (var lIdx = layerGroups.length - 2; lIdx >= 0; lIdx--) {
              var nextPos = new Map(layerGroups[lIdx + 1].map(function (id, idx) { return [id, idx]; }));
              layerGroups[lIdx].sort(function (a, b) {
                var sA = Array.from(graph.outgoing.get(a) || []).filter(function (id) { return nextPos.has(id); });
                var sB = Array.from(graph.outgoing.get(b) || []).filter(function (id) { return nextPos.has(id); });
                var bcA = sA.length ? sA.reduce(function (s, id) { return s + nextPos.get(id); }, 0) / sA.length : layerGroups[lIdx].indexOf(a);
                var bcB = sB.length ? sB.reduce(function (s, id) { return s + nextPos.get(id); }, 0) / sB.length : layerGroups[lIdx].indexOf(b);
                return bcA - bcB || String(a).localeCompare(String(b));
              });
            }
          }
        }

        var colStep = (isHorizontal ? step * 1.55 : step * 1.05);
        var rowStep = (isHorizontal ? step * 0.8 : step * 1.25);
        layerGroups.forEach(function (grp, lIdx) {
          var grpHeight = (grp.length - 1) * rowStep;
          grp.forEach(function (nodeId, nIdx) {
            var cross = nIdx * rowStep - grpHeight / 2;
            var depthPos = lIdx * colStep;
            local.set(nodeId, {
              x: isHorizontal ? depthPos : cross,
              y: isHorizontal ? cross : depthPos,
              z: lIdx * 12,
              depth: lIdx,
              rank: nIdx,
              isRoot: lIdx === 0
            });
          });
        });
      } else if (mode === 'concentric' || mode === 'dandelion' || mode === 'starburst' || mode === 'spoke') {
        var focusedNodeId = options.focusedNodeId || null;
        var hub = (focusedNodeId && groupNodeObjs.find(function (n) { return n.id === focusedNodeId; })) || groupOrdered[0];
        local.set(hub.id, { x: 0, y: 0, z: 0, depth: 0, rank: 0, isRoot: true });
        var rest = groupOrdered.filter(function (n) { return n.id !== hub.id; });
        if (mode === 'starburst') {
          var primary = rest.filter(function (n) { return (graph.adjacent.get(hub.id) || new Set()).has(n.id); });
          var secondary = rest.filter(function (n) { return primary.indexOf(n) < 0; });
          var pR = Math.max(step * 0.8, primary.length * step * 0.22);
          primary.forEach(function (n, i) {
            var angle = i * Math.PI * 2 / Math.max(1, primary.length) - Math.PI / 2;
            local.set(n.id, { x: Math.cos(angle) * pR, y: Math.sin(angle) * pR, z: 10, depth: 1, rank: i, isRoot: false });
          });
          secondary.forEach(function (n, i) {
            var parent = primary.find(function (p) { return (graph.adjacent.get(p.id) || new Set()).has(n.id); }) || primary[i % Math.max(1, primary.length)];
            var pPos = parent ? local.get(parent.id) : { x: 0, y: 0 };
            var angle = Math.atan2(pPos.y, pPos.x) + (i % 3 - 1) * 0.35;
            var dist = pR + step * 0.6 + Math.floor(i / Math.max(1, primary.length)) * step * 0.4;
            local.set(n.id, { x: Math.cos(angle) * dist, y: Math.sin(angle) * dist, z: 20, depth: 2, rank: i, isRoot: false });
          });
        } else if (mode === 'dandelion') {
          var cats = Array.from(new Set(rest.map(function (n) { return n.group || '其他'; }))).sort();
          var catCount = Math.max(cats.length, 1);
          var sectorSize = Math.PI * 2 / catCount;
          cats.forEach(function (cat, cIdx) {
            var catNodes = rest.filter(function (n) { return (n.group || '其他') === cat; });
            var centerAngle = cIdx * sectorSize - Math.PI / 2;
            catNodes.forEach(function (n, i) {
              var ringIdx = Math.floor(i / 3);
              var inRing = i % 3;
              var spread = (inRing - 1) * Math.min(0.25, sectorSize * 0.28);
              var r = step * 0.85 + ringIdx * step * 0.55;
              local.set(n.id, { x: Math.cos(centerAngle + spread) * r, y: Math.sin(centerAngle + spread) * r, z: ringIdx * 15, depth: ringIdx + 1, rank: i, isRoot: false });
            });
          });
        } else if (mode === 'spoke') {
          // Stable center-rooted tree spoke layout (from DuckDB Editor Pro)
          var visitedSpoke = new Set([hub.id]);
          var depthById = new Map([[hub.id, 0]]);
          var childrenById = new Map();
          var queue = [hub.id];
          while (queue.length) {
            var current = queue.shift();
            var d = depthById.get(current) || 0;
            if (d >= 8) continue;
            var children = Array.from(graph.adjacent.get(current) || [])
              .filter(function (id) { return group.indexOf(id) >= 0 && !visitedSpoke.has(id); })
              .sort(function (a, b) { return groupDegree(b) - groupDegree(a) || String(a).localeCompare(String(b)); });
            childrenById.set(current, children);
            children.forEach(function (ch) {
              visitedSpoke.add(ch);
              depthById.set(ch, d + 1);
              queue.push(ch);
            });
          }

          var branches = childrenById.get(hub.id) || [];
          var branchCount = Math.max(branches.length, 1);
          var baseAngle = -Math.PI / 2;
          var branchStep = (Math.PI * 2) / branchCount;
          var branchDistance = Math.max(step * 0.95, branchCount * 26);

          branches.forEach(function (branchId, branchIndex) {
            var angle = baseAngle + branchIndex * branchStep;
            var branchRing = Math.floor(branchIndex / 16);
            var branchRadius = branchDistance + branchRing * 48;
            local.set(branchId, {
              x: Math.cos(angle) * branchRadius,
              y: Math.sin(angle) * branchRadius,
              z: 10,
              depth: 1,
              rank: branchIndex,
              isRoot: false
            });

            function walkSpoke(parentId, depth) {
              if (depth >= 8) return;
              var subChildren = childrenById.get(parentId) || [];
              var spread = Math.min(0.82, Math.max(0.28, (subChildren.length - 1) * 0.18));
              var radius = branchDistance + (depth - 1) * step * 0.78;
              subChildren.forEach(function (childId, index) {
                var childAngle = angle + (subChildren.length === 1 ? 0 : -spread / 2 + index * (spread / Math.max(1, subChildren.length - 1)));
                var crossOffset = (index - (subChildren.length - 1) / 2) * 58;
                local.set(childId, {
                  x: Math.cos(angle) * radius + Math.cos(childAngle + Math.PI / 2) * crossOffset,
                  y: Math.sin(angle) * radius + Math.sin(childAngle + Math.PI / 2) * crossOffset,
                  z: depth * 12,
                  depth: depth,
                  rank: index,
                  isRoot: false
                });
                walkSpoke(childId, depth + 1);
              });
            }
            walkSpoke(branchId, 2);
          });

          // Disconnected nodes placed in satellite orbit cluster
          var disconnected = rest.filter(function (node) { return !visitedSpoke.has(node.id); });
          var satelliteRadius = branchDistance + Math.max(step * 1.6, 260);
          disconnected.forEach(function (node, index) {
            var angle = baseAngle + ((index + 0.5) / Math.max(disconnected.length, 1)) * Math.PI * 2;
            var ring = Math.floor(index / 10);
            local.set(node.id, {
              x: Math.cos(angle) * (satelliteRadius + ring * 52),
              y: Math.sin(angle) * (satelliteRadius + ring * 52),
              z: 25,
              depth: 3,
              rank: index,
              isRoot: false
            });
          });
        } else {
          // concentric: Topological Distance Rings from root hub (from DuckDB Editor Pro)
          var visitedConc = new Set([hub.id]);
          var depthByConc = new Map([[hub.id, 0]]);
          var queueConc = [hub.id];
          while (queueConc.length) {
            var curr = queueConc.shift();
            var dConc = depthByConc.get(curr) || 0;
            Array.from(graph.adjacent.get(curr) || []).forEach(function (nbr) {
              if (group.indexOf(nbr) >= 0 && !visitedConc.has(nbr)) {
                visitedConc.add(nbr);
                depthByConc.set(nbr, dConc + 1);
                queueConc.push(nbr);
              }
            });
          }
          var byDepth = new Map();
          rest.forEach(function (node) {
            var dVal = visitedConc.has(node.id) ? depthByConc.get(node.id) : 99;
            if (!byDepth.has(dVal)) byDepth.set(dVal, []);
            byDepth.get(dVal).push(node);
          });

          var sortedDepths = Array.from(byDepth.keys()).filter(function (d) { return d > 0; }).sort(function (a, b) { return a - b; });
          sortedDepths.forEach(function (d, ringIdx) {
            var ringNodes = byDepth.get(d);
            var r = step * 0.9 + ringIdx * step * 0.72;
            ringNodes.forEach(function (node, idx) {
              var angle = idx * Math.PI * 2 / Math.max(1, ringNodes.length) - Math.PI / 2;
              local.set(node.id, {
                x: Math.cos(angle) * r,
                y: Math.sin(angle) * r,
                z: (ringIdx + 1) * 15,
                depth: d === 99 ? 3 : d,
                rank: idx,
                isRoot: false
              });
            });
          });
        }
      } else if (mode === 'clusteredForce' || mode === 'groupedCircular') {
        var groupMap = new Map();
        if (mode === 'clusteredForce') {
          // Greedy modularity updates for link-defined communities (from DuckDB Editor)
          var membership = new Map(groupOrdered.map(function (n) { return [n.id, n.id]; }));
          var total = Math.max(1, group.length * 2);
          for (var pass = 0; pass < 8; pass++) {
            var changed = false;
            var volumes = new Map();
            groupOrdered.forEach(function (n) { var id = membership.get(n.id); volumes.set(id, (volumes.get(id) || 0) + (graph.adjacent.get(n.id) || new Set()).size); });
            groupOrdered.forEach(function (n) {
              var deg = (graph.adjacent.get(n.id) || new Set()).size; if (!deg) return;
              var curM = membership.get(n.id), cands = new Set([curM]);
              volumes.set(curM, volumes.get(curM) - deg);
              (graph.adjacent.get(n.id) || new Set()).forEach(function (nbr) { if (group.indexOf(nbr) >= 0) cands.add(membership.get(nbr)); });
              var bestM = curM, bestS = -Infinity;
              cands.forEach(function (cand) {
                var internal = Array.from(graph.adjacent.get(n.id) || new Set()).filter(function (nbr) { return membership.get(nbr) === cand; }).length;
                var vol = volumes.get(cand) || 0;
                var sc = internal - deg * vol / total;
                if (sc > bestS + 1e-8 || (Math.abs(sc - bestS) < 1e-8 && cand < bestM)) { bestM = cand; bestS = sc; }
              });
              volumes.set(bestM, (volumes.get(bestM) || 0) + deg);
              if (bestM !== curM) { membership.set(n.id, bestM); changed = true; }
            });
            if (!changed) break;
          }
          groupOrdered.forEach(function (n) {
            var cId = membership.get(n.id);
            if (!groupMap.has(cId)) groupMap.set(cId, []);
            groupMap.get(cId).push(n);
          });
        } else {
          // groupedCircular: strict topic category groups
          groupOrdered.forEach(function (n) {
            var g = n.group || '其他';
            if (!groupMap.has(g)) groupMap.set(g, []);
            groupMap.get(g).push(n);
          });
        }
        var gList = Array.from(groupMap.values());
        var macroR = Math.max(step * (mode === 'groupedCircular' ? 1.05 : 0.85), gList.length * step * 0.28);
        gList.forEach(function (subList, gIdx) {
          var gAngle = gIdx * Math.PI * 2 / gList.length - Math.PI / 2;
          var gx = Math.cos(gAngle) * macroR, gy = Math.sin(gAngle) * macroR;
          var subR = mode === 'groupedCircular' ? Math.max(step * 0.45, subList.length * step * 0.18) :
            Math.max(step * 0.32, Math.sqrt(subList.length) * step * 0.22);
          subList.forEach(function (n, i) {
            var angle = i * Math.PI * 2 / subList.length - Math.PI / 2;
            var isPrimaryHub = n.id === groupOrdered[0].id;
            local.set(n.id, { x: gx + (subList.length === 1 ? 0 : Math.cos(angle) * subR),
              y: gy + (subList.length === 1 ? 0 : Math.sin(angle) * subR), z: gIdx * 10,
              depth: isPrimaryHub ? 0 : (gIdx === 0 ? 1 : 2), rank: i, isRoot: isPrimaryHub });
          });
        });
      } else if (mode === 'grid') {
        var columns = Math.max(1, Math.ceil(Math.sqrt(group.length * Math.max(.6, width / height))));
        groupOrdered.forEach(function (node, i) {
          local.set(node.id, { x: (i % columns) * step * 1.15, y: Math.floor(i / columns) * step * 0.72, z: (i % columns) * 18,
            depth: Math.floor(i / columns), rank: i % columns, isRoot: i === 0 });
        });
      } else if (mode === 'organic' || mode === 'force') {
        var orbit = Math.max(step * .65, step * group.length / (Math.PI * 2));
        groupOrdered.forEach(function (node, i) {
          var angle = i * 2.39996;
          var r = Math.sqrt(i) * step * 0.5 + 40;
          local.set(node.id, { x: Math.cos(angle) * r, y: Math.sin(angle) * r, z: Math.sin(angle * 2) * 20,
            depth: i === 0 ? 0 : Math.ceil(Math.sqrt(i)), rank: i, isRoot: i === 0 });
        });
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

      var values = Array.from(local.values());
      var minX = Math.min.apply(null, values.map(function (p) { return p.x; }));
      var minY = Math.min.apply(null, values.map(function (p) { return p.y; }));
      var maxX = Math.max.apply(null, values.map(function (p) { return p.x; }));
      var maxY = Math.max.apply(null, values.map(function (p) { return p.y; }));
      boxes.push({ local: local, minX: minX, minY: minY, width: maxX - minX + step, height: maxY - minY + step * .75 });
    });

    var area = boxes.reduce(function (sum, box) { return sum + box.width * box.height; }, 0);
    var gap = step * .45, widest = Math.max(1, ...boxes.map(function (box) { return box.width; }));
    var candidates = [widest, Math.sqrt(area * Math.max(.6, width / height))], prefix = 0;
    boxes.forEach(function (box) { prefix += box.width + (prefix ? gap : 0); candidates.push(prefix); });
    var shelf = widest, best = -Infinity;
    candidates.forEach(function (candidate) {
      candidate = Math.max(widest, candidate);
      var x = 0, y = 0, rowHeight = 0, usedWidth = 0;
      boxes.forEach(function (box) {
        if (x && x + box.width > candidate + .01) { x = 0; y += rowHeight + gap; rowHeight = 0; }
        usedWidth = Math.max(usedWidth, x + box.width); x += box.width + gap; rowHeight = Math.max(rowHeight, box.height);
      });
      var score = Math.min(Math.max(220, width - 80) / (usedWidth + 100), Math.max(220, height - 60) / (y + rowHeight + 40));
      if (score > best) { best = score; shelf = candidate; }
    });

    var x = 0, y = 0, rowHeight = 0;
    boxes.forEach(function (box) {
      if (x && x + box.width > shelf + .01) { x = 0; y += rowHeight + gap; rowHeight = 0; }
      var cx = x + box.width / 2, cy = y + box.height / 2;
      box.local.forEach(function (point, node) {
        result.set(node, {
          x: x + point.x - box.minX + step / 2,
          y: y + point.y - box.minY + step * .375,
          z: point.z, cx: cx, cy: cy,
          depth: point.depth != null ? point.depth : 0,
          rank: point.rank != null ? point.rank : 0,
          isRoot: !!point.isRoot
        });
      });
      x += box.width + gap; rowHeight = Math.max(rowHeight, box.height);
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
