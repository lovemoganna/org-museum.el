/* Screen-space geometry for Org Museum's authored relationships. */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.orgMuseumGraphEdges = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';

  function id(value) { return value && typeof value === 'object' ? value.id : value; }
  function flow(edge) {
    var source = id(edge.source), target = id(edge.target);
    var reverse = edge.direction === 'reverse';
    var both = edge.direction === 'both';
    return {source: source, target: target, from: reverse ? target : source,
      to: reverse ? source : target, atStart: reverse || both, atEnd: !reverse};
  }
  function incoming(edge, nodeId) {
    var relation = flow(edge);
    return (relation.atEnd && relation.target === nodeId) ||
      (relation.atStart && relation.source === nodeId);
  }
  function outgoing(edge, nodeId) {
    var relation = flow(edge);
    return (relation.atEnd && relation.source === nodeId) ||
      (relation.atStart && relation.target === nodeId);
  }
  function point(route, t) {
    var u = 1 - t;
    if (route.curveType === 'cubic' && route.c1 && route.c2) {
      return {
        x: u * u * u * route.start.x + 3 * u * u * t * route.c1.x + 3 * u * t * t * route.c2.x + t * t * t * route.end.x,
        y: u * u * u * route.start.y + 3 * u * u * t * route.c1.y + 3 * u * t * t * route.c2.y + t * t * t * route.end.y
      };
    }
    if (route.curveType === 'linear') {
      return {
        x: u * route.start.x + t * route.end.x,
        y: u * route.start.y + t * route.end.y
      };
    }
    return {x: u * u * route.start.x + 2 * u * t * route.control.x + t * t * route.end.x,
      y: u * u * route.start.y + 2 * u * t * route.control.y + t * t * route.end.y};
  }
  function geometry(edge, source, target, sourceRadius, targetRadius, lane, layoutMode) {
    var dx = target.x - source.x, dy = target.y - source.y;
    var distance = Math.max(1, Math.hypot(dx, dy));
    var ux = dx / distance, uy = dy / distance;
    var minDistance = 15;
    var from = Math.max(sourceRadius + 4, minDistance);
    var to = Math.max(targetRadius + 6, minDistance);
    if (from + to >= distance && distance > 2) {
      var scale = (distance * 0.85) / (from + to);
      from = Math.max(2, from * scale);
      to = Math.max(2, to * scale);
    }
    var start = {x: source.x + ux * from, y: source.y + uy * from};
    var end = {x: target.x - ux * to, y: target.y - uy * to};
    var canonical = id(edge.source) < id(edge.target) ? 1 : -1;
    var control = {x: (start.x + end.x) / 2 - uy * lane * canonical,
      y: (start.y + end.y) / 2 + ux * lane * canonical};

    var isHierarchical = layoutMode === 'treeVertical' || layoutMode === 'treeHorizontal' ||
      layoutMode === 'dagre' || layoutMode === 'semantic' || layoutMode === 'hierarchy';
    var isRadial = layoutMode === 'concentric' || layoutMode === 'starburst' ||
      layoutMode === 'dandelion' || layoutMode === 'spoke' || layoutMode === 'grid';

    if (isHierarchical && lane === 0) {
      var isHorizontal = layoutMode === 'treeHorizontal' || (layoutMode !== 'treeVertical' && layoutMode !== 'dagre' && Math.abs(dx) > Math.abs(dy));
      var c1, c2;
      if (isHorizontal) {
        var midX = (start.x + end.x) / 2;
        c1 = {x: midX, y: start.y};
        c2 = {x: midX, y: end.y};
      } else {
        var midY = (start.y + end.y) / 2;
        c1 = {x: start.x, y: midY};
        c2 = {x: end.x, y: midY};
      }
      return {id: edge.id, sourceId: id(edge.source), targetId: id(edge.target),
        lane: lane, start: start, control: control, c1: c1, c2: c2, end: end,
        curveType: 'cubic',
        path: 'M' + start.x + ',' + start.y + 'C' + c1.x + ',' + c1.y + ' ' +
          c2.x + ',' + c2.y + ' ' + end.x + ',' + end.y};
    }

    if (isRadial && lane === 0) {
      return {id: edge.id, sourceId: id(edge.source), targetId: id(edge.target),
        lane: lane, start: start, control: control, end: end,
        curveType: 'linear',
        path: 'M' + start.x + ',' + start.y + 'L' + end.x + ',' + end.y};
    }

    return {id: edge.id, sourceId: id(edge.source), targetId: id(edge.target),
      lane: lane, start: start, control: control, end: end,
      curveType: 'quad',
      path: 'M' + start.x + ',' + start.y + 'Q' + control.x + ',' + control.y +
        ' ' + end.x + ',' + end.y};
  }
  function segments(route) {
    var result = [];
    for (var i = 0; i <= 12; i += 1) result.push(point(route, i / 12));
    return result;
  }
  function crossing(a, b, c, d) {
    function side(p, q, r) { return (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x); }
    var ab1 = side(a, b, c), ab2 = side(a, b, d);
    var cd1 = side(c, d, a), cd2 = side(c, d, b);
    return ab1 * ab2 < -1e-4 && cd1 * cd2 < -1e-4;
  }
  function routeCost(route, nodes, points, radii, accepted) {
    var samples = segments(route), cost = Math.abs(route.lane) * .08;
    nodes.forEach(function (node) {
      if (node.id === route.sourceId || node.id === route.targetId) return;
      var center = points.get(node.id);
      if (!center) return;
      var clearance = (radii.get(node.id) || 10) + 6;
      samples.slice(2, -2).forEach(function (sample) {
        var distance = Math.hypot(sample.x - center.x, sample.y - center.y);
        if (distance < clearance) cost += 160 + (clearance - distance) * 12;
        else if (distance < clearance + 10) cost += (clearance + 10 - distance) * 2;
      });
    });
    accepted.forEach(function (other) {
      var otherSamples = segments(other);
      for (var i = 0; i < samples.length - 1; i += 1) {
        for (var j = 0; j < otherSamples.length - 1; j += 1) {
          if (!crossing(samples[i], samples[i + 1], otherSamples[j], otherSamples[j + 1])) continue;
          var nearSharedEnd = [route.sourceId, route.targetId].some(function (nodeId) {
            if (nodeId !== other.sourceId && nodeId !== other.targetId) return false;
            var center = points.get(nodeId);
            return center && Math.hypot(samples[i].x - center.x, samples[i].y - center.y) < 24;
          });
          if (!nearSharedEnd) cost += 35;
        }
      }
    });
    return cost;
  }
  function routes(nodes, edges, points, radii, previous, layoutMode) {
    var groups = new Map(), result = new Map(), accepted = [];
    edges.forEach(function (edge) {
      var pair = [id(edge.source), id(edge.target)].sort().join('\u0000');
      if (!groups.has(pair)) groups.set(pair, []);
      groups.get(pair).push(edge);
    });
    Array.from(groups).sort(function (a, b) {
      return b[1].length - a[1].length || a[0].localeCompare(b[0]);
    }).forEach(function (entry) {
      var group = entry[1].slice().sort(function (a, b) { return a.id.localeCompare(b.id); });
      var sourceId = id(group[0].source), targetId = id(group[0].target);
      if (sourceId > targetId) { var swapped = sourceId; sourceId = targetId; targetId = swapped; }
      var a = points.get(sourceId), b = points.get(targetId);
      if (!a || !b) return;
      var distance = Math.hypot(b.x - a.x, b.y - a.y);
      var base = Math.min(22, Math.max(12, distance * .2));
      var near = [];
      edges.forEach(function (edge) {
        var s = id(edge.source), t = id(edge.target);
        if (s === sourceId || s === targetId || t === sourceId || t === targetId)
          [s, t].forEach(function (other) {
            if (other !== sourceId && other !== targetId && points.has(other) && !near.includes(other)) near.push(other);
          });
      });
      var exterior = 0;
      if (near.length) {
        var midpoint = {x: (a.x + b.x) / 2, y: (a.y + b.y) / 2};
        var nx = -(b.y - a.y) / Math.max(1, distance), ny = (b.x - a.x) / Math.max(1, distance);
        var toward = near.reduce(function (sum, nodeId) {
          var center = points.get(nodeId);
          return sum + (center.x - midpoint.x) * nx + (center.y - midpoint.y) * ny;
        }, 0);
        exterior = toward > 0 ? -1 : 1;
      }
      var options;
      if (group.length === 1) options = [[0], [base], [-base], [base * 1.8], [-base * 1.8]];
      else if (exterior) options = [exterior, -exterior].map(function (sign) {
        return group.map(function (_edge, index) { return sign * base * (index + 1); });
      }).concat([group.map(function (_edge, index) { return (index % 2 ? 1 : -1) * base; })]);
      else options = [group.map(function (_edge, index) { return (index - (group.length - 1) / 2) * base * 2; }),
        group.map(function (_edge, index) { return base * (index + 1); })];
      var best = null, bestCost = Infinity;
      options.forEach(function (lanes, optionIndex) {
        var candidates = group.map(function (edge, index) {
          var s = id(edge.source), t = id(edge.target);
          return geometry(edge, points.get(s), points.get(t), radii.get(s) || 10,
            radii.get(t) || 10, lanes[index], layoutMode);
        });
        var cost = candidates.reduce(function (sum, route) {
          var former = previous && previous.get(route.id);
          if (former && Math.sign(former.lane) !== Math.sign(route.lane)) sum += 4;
          return sum + routeCost(route, nodes, points, radii, accepted);
        }, optionIndex * .01);
        if (cost < bestCost) { best = candidates; bestCost = cost; }
      });
      best.forEach(function (route) { result.set(route.id, route); accepted.push(route); });
    });
    return result;
  }
  function labelCandidates(route) {
    var candidates = [];
    [.5, .35, .65].forEach(function (t) {
      var p = point(route, t), u = 1 - t;
      var dx, dy;
      if (route.curveType === 'cubic' && route.c1 && route.c2) {
        dx = 3 * u * u * (route.c1.x - route.start.x) + 6 * u * t * (route.c2.x - route.c1.x) + 3 * t * t * (route.end.x - route.c2.x);
        dy = 3 * u * u * (route.c1.y - route.start.y) + 6 * u * t * (route.c2.y - route.c1.y) + 3 * t * t * (route.end.y - route.c2.y);
      } else if (route.curveType === 'linear') {
        dx = route.end.x - route.start.x;
        dy = route.end.y - route.start.y;
      } else {
        dx = u * (route.control.x - route.start.x) + t * (route.end.x - route.control.x);
        dy = u * (route.control.y - route.start.y) + t * (route.end.y - route.control.y);
      }
      var length = Math.max(1, Math.hypot(dx, dy));
      [1, -1].forEach(function (side) {
        [13, 20, 28].forEach(function (offset) {
          candidates.push({x: p.x - dy / length * offset * side,
            y: p.y + dx / length * offset * side});
        });
      });
    });
    return candidates;
  }
  return {flow: flow, incoming: incoming, outgoing: outgoing,
    point: point, routes: routes, labelCandidates: labelCandidates};
});
