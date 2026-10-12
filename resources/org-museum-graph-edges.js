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
  function geometry(edge, source, target, sourceRadius, targetRadius, lane, layoutMode, routingMode, rootCenter, portShift) {
    var dx = target.x - source.x, dy = target.y - source.y;
    var distance = Math.max(1, Math.hypot(dx, dy));
    var ux = dx / distance, uy = dy / distance;
    var minDistance = 15;
    var relationFlow = flow(edge);
    var fromOffset = relationFlow.atStart ? 6 : 4;
    var toOffset = relationFlow.atEnd ? 6 : 4;
    var from = Math.max(sourceRadius + fromOffset, minDistance);
    var to = Math.max(targetRadius + toOffset, minDistance);
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
    // Give parallel curves their own tangent ports on the node boundary.
    // Sharing one chord endpoint makes reciprocal arrows collide at the node.
    if(lane!==0) {
      control={x:(source.x+target.x)/2-uy*lane*canonical,y:(source.y+target.y)/2+ux*lane*canonical};
      var sx=control.x-source.x,sy=control.y-source.y,sl=Math.max(1,Math.hypot(sx,sy));
      var tx=control.x-target.x,ty=control.y-target.y,tl=Math.max(1,Math.hypot(tx,ty));
      var angle=(portShift||0)*canonical,cos=Math.cos(angle),sin=Math.sin(angle);
      start={x:source.x+(sx*cos-sy*sin)/sl*from,y:source.y+(sx*sin+sy*cos)/sl*from};
      end={x:target.x+(tx*cos+ty*sin)/tl*to,y:target.y+(-tx*sin+ty*cos)/tl*to};
    }

    // Explicit routingMode preference
    if (routingMode === 'straight' && lane === 0) {
      return {id: edge.id, sourceId: id(edge.source), targetId: id(edge.target),
        lane: lane, start: start, control: control, end: end,
        curveType: 'linear',
        path: 'M' + start.x + ',' + start.y + 'L' + end.x + ',' + end.y};
    }

    if (routingMode === 'stepped' && lane === 0) {
      var isHorizontalStepped = layoutMode === 'treeHorizontal' || (layoutMode !== 'treeVertical' && layoutMode !== 'dagre' && Math.abs(dx) > Math.abs(dy));
      var c1Step, c2Step;
      if (isHorizontalStepped) {
        var midXStep = (start.x + end.x) / 2;
        c1Step = {x: midXStep, y: start.y};
        c2Step = {x: midXStep, y: end.y};
      } else {
        var midYStep = (start.y + end.y) / 2;
        c1Step = {x: start.x, y: midYStep};
        c2Step = {x: end.x, y: midYStep};
      }
      return {id: edge.id, sourceId: id(edge.source), targetId: id(edge.target),
        lane: lane, start: start, control: control, c1: c1Step, c2: c2Step, end: end,
        curveType: 'cubic',
        path: 'M' + start.x + ',' + start.y + 'C' + c1Step.x + ',' + c1Step.y + ' ' +
          c2Step.x + ',' + c2Step.y + ' ' + end.x + ',' + end.y};
    }

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
      var sId = id(edge.source), tId = id(edge.target);
      var center=rootCenter || {x:0,y:0,id:'root'};
      var isRootLink = sId === center.id || tId === center.id;
      var srx=source.x-center.x,sry=source.y-center.y,trx=target.x-center.x,tryy=target.y-center.y;
      var distToOrigin = Math.abs(srx * tryy - sry * trx) / distance;
      if (isRootLink || layoutMode === 'grid' || distToOrigin > 55) {
        return {id: edge.id, sourceId: id(edge.source), targetId: id(edge.target),
          lane: lane, start: start, control: control, end: end,
          curveType: 'linear',
          path: 'M' + start.x + ',' + start.y + 'L' + end.x + ',' + end.y};
      }
      // Cross-branch edge piercing through center root: bow outward around origin
      var mx = (start.x + end.x) / 2, my = (start.y + end.y) / 2;
      var mDist = Math.hypot(mx-center.x, my-center.y);
      var outX = mDist >= 5 ? (mx-center.x) / mDist : -uy;
      var outY = mDist >= 5 ? (my-center.y) / mDist : ux;
      var bow = Math.max(55, distance * 0.24);
      var curvedControl = {x: mx + outX * bow, y: my + outY * bow};
      return {id: edge.id, sourceId: id(edge.source), targetId: id(edge.target),
        lane: lane, start: start, control: curvedControl, end: end,
        curveType: 'quad',
        path: 'M' + start.x + ',' + start.y + 'Q' + curvedControl.x + ',' + curvedControl.y +
          ' ' + end.x + ',' + end.y};
    }

    return {id: edge.id, sourceId: id(edge.source), targetId: id(edge.target),
      lane: lane, start: start, control: control, end: end,
      curveType: 'quad',
      path: 'M' + start.x + ',' + start.y + 'Q' + control.x + ',' + control.y +
        ' ' + end.x + ',' + end.y};
  }
  function segments(route) {
    var result = [];
    for (var i = 0; i <= 18; i += 1) result.push(point(route, i / 18));
    return result;
  }
  function crossing(a, b, c, d) {
    function side(p, q, r) { return (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x); }
    var ab1 = side(a, b, c), ab2 = side(a, b, d);
    var cd1 = side(c, d, a), cd2 = side(c, d, b);
    return ab1 * ab2 < -1e-4 && cd1 * cd2 < -1e-4;
  }
  function routeCost(route, nodes, points, radii, accepted, obstacles) {
    var samples = segments(route), cost = Math.abs(route.lane) * .12;
    nodes.forEach(function (node) {
      if (node.id === route.sourceId || node.id === route.targetId) return;
      var center = points.get(node.id);
      if (!center) return;
      var clearance = (radii.get(node.id) || 10) + 6;
      samples.slice(2, -2).forEach(function (sample) {
        var distance = Math.hypot(sample.x - center.x, sample.y - center.y);
        if (distance < clearance) cost += 160 + (clearance - distance) * 12;
        else if (distance < clearance + 6) cost += (clearance + 6 - distance) * .15;
      });
    });
    (obstacles || []).forEach(function (box) {
      samples.slice(1,-1).forEach(function (p) {
        if(p.x>box.x-3 && p.x<box.x+box.width+3 && p.y>box.y-3 && p.y<box.y+box.height+3)cost+=100;
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
            return center && Math.hypot(samples[i].x - center.x, samples[i].y - center.y) < (radii.get(nodeId)||10)+14;
          });
          if (!nearSharedEnd) cost += 35;
        }
      }
    });
    return cost;
  }
  function routes(nodes, edges, points, radii, previous, layoutMode, routingMode, obstacles) {
    var groups = new Map(), result = new Map(), accepted = [], plans=[];
    var adjacency=new Map(),roots=new Map();
    nodes.forEach(function(n){adjacency.set(n.id,new Set());});
    edges.forEach(function(e){var s=id(e.source),t=id(e.target);if(adjacency.has(s)&&adjacency.has(t)){adjacency.get(s).add(t);adjacency.get(t).add(s);}});
    nodes.filter(function(n){return n.isRoot || n.depth===0 || n.id==='root';}).sort(function(a,b){return String(a.id).localeCompare(String(b.id));}).forEach(function(root){
      if(roots.has(root.id))return;
      var queue=[root.id],center=points.get(root.id);if(!center)return;
      var reference={id:root.id,x:center.x,y:center.y};roots.set(root.id,reference);
      for(var head=0;head<queue.length;head++) adjacency.get(queue[head]).forEach(function(next){if(!roots.has(next)){roots.set(next,reference);queue.push(next);}});
    });
    edges.forEach(function (edge) {
      var pair = [id(edge.source), id(edge.target)].sort().join('\u0000');
      if (!groups.has(pair)) groups.set(pair, []);
      groups.get(pair).push(edge);
    });
    function candidatesFor(group, lanes) {
      var order=lanes.map(function(lane,index){return {lane:lane,index:index};}).sort(function(a,b){return a.lane-b.lane || a.index-b.index;});
      var ranks=new Map();order.forEach(function(item,i){ranks.set(item.index,i);});
      return group.map(function(edge,index){
        var s=id(edge.source),t=id(edge.target),shift=(ranks.get(index)-(group.length-1)/2)*Math.min(.5,1.1/Math.max(1,group.length-1));
        return geometry(edge,points.get(s),points.get(t),radii.get(s)||10,radii.get(t)||10,lanes[index],layoutMode,routingMode,roots.get(s),shift);
      });
    }
    Array.from(groups).sort(function (a, b) {
      return b[1].length - a[1].length || a[0].localeCompare(b[0]);
    }).forEach(function (entry) {
      var group = entry[1].slice().sort(function (a, b) { return a.id.localeCompare(b.id); });
      var sourceId = id(group[0].source), targetId = id(group[0].target);
      if (sourceId > targetId) { var swapped = sourceId; sourceId = targetId; targetId = swapped; }
      var a = points.get(sourceId), b = points.get(targetId);
      if (!a || !b) return;
      var distance = Math.hypot(b.x - a.x, b.y - a.y);
      var detour = Math.min(24, Math.max(16, distance * .12));
      var wide=Math.min(distance*.48,Math.max(detour*3,48));
      var parallelBase = Math.min(20, Math.max(14, distance * .08));
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
      if (group.length === 1) options = [[0], [detour], [-detour], [detour * 1.5], [-detour * 1.5], [wide], [-wide]];
      else if (group.length === 2) options = [[-parallelBase, parallelBase], [parallelBase, -parallelBase],[-wide,wide],[wide,-wide],
        [wide,wide+parallelBase],[-wide,-wide-parallelBase]];
      else if (exterior) options = [exterior, -exterior].map(function (sign) {
        return group.map(function (_edge, index) { return sign * parallelBase * (index + 1); });
      }).concat([group.map(function (_edge, index) { return (index % 2 ? 1 : -1) * parallelBase; })]);
      else options = [group.map(function (_edge, index) { return (index - (group.length - 1) / 2) * parallelBase * 1.5; }),
        group.map(function (_edge, index) { return parallelBase * (index + 1); })];
      plans.push({group:group,options:options});
      var best = null, bestCost = Infinity;
      options.forEach(function (lanes, optionIndex) {
        var candidates = candidatesFor(group,lanes);
        var cost = candidates.reduce(function (sum, route) {
          var former = previous && previous.get(route.id);
          if (former && Math.sign(former.lane) !== Math.sign(route.lane)) sum += 4;
          return sum + routeCost(route, nodes, points, radii, accepted, obstacles);
        }, optionIndex * .01);
        if (cost < bestCost) { best = candidates; bestCost = cost; }
      });
      best.forEach(function (route) { result.set(route.id, route); accepted.push(route); });
    });
    // Reconsider early choices against the complete network. One greedy pass
    // cannot see crossings introduced by paths that are routed later.
    if(edges.length<=32) for(var pass=0;pass<2;pass++) plans.forEach(function(plan){
      var own=new Set(plan.group.map(function(e){return e.id;}));
      var others=Array.from(result.values()).filter(function(r){return !own.has(r.id);});
      function score(list){return list.reduce(function(sum,r){return sum+routeCost(r,nodes,points,radii,others,obstacles);},0);}
      var best=plan.group.map(function(e){return result.get(e.id);}),bestCost=score(best);
      plan.options.forEach(function(lanes){
        var candidates=candidatesFor(plan.group,lanes);
        var cost=score(candidates);if(cost<bestCost-.01){best=candidates;bestCost=cost;}
      });
      best.forEach(function(r){result.set(r.id,r);});
    });
    return result;
  }
  function labelCandidates(route) {
    var candidates = [];
    [.5, .35, .65, .22, .78].forEach(function (t) {
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
        [13, 20, 28, 38, 50].forEach(function (offset) {
          candidates.push({x: p.x - dy / length * offset * side,
            y: p.y + dx / length * offset * side});
        });
      });
    });
    return candidates;
  }
  return {flow: flow, incoming: incoming, outgoing: outgoing,
    point: point, routes: routes, labelCandidates: labelCandidates, geometry: geometry};
});
