/* Org Museum's live graph reads one Org-backed graph snapshot at a time. */
(function () {
  'use strict';
  function parseNodeTimestamp(value) {
    if (!value) return NaN;
    if (typeof value === 'number') return value > 1e11 ? value : value * 1000;
    var number = Number(value);
    if (Number.isFinite(number) && number > 0) return number > 1e11 ? number : number * 1000;
    // Date-only metadata is a local calendar day, matching the other reading views.
    if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return new Date(value + 'T00:00:00').getTime();
    return Date.parse(value);
  }

  function recentNodeIds(nodes, days, now) {
    var end = new Date(now == null ? Date.now() : now);
    end.setHours(0, 0, 0, 0);
    var start = new Date(end);
    start.setDate(start.getDate() - days + 1);
    end.setDate(end.getDate() + 1);
    return new Set(nodes.filter(function (node) {
      var timestamp = parseNodeTimestamp(node.created) || parseNodeTimestamp(node.modified);
      return timestamp >= start.getTime() && timestamp < end.getTime();
    }).map(function (node) { return node.id; }));
  }

  if (typeof window === 'undefined') {
    if (typeof module !== 'undefined') module.exports = {recentNodeIds: recentNodeIds};
    return;
  }
  if (!window.d3 || !document.getElementById('graph-data')) return;
  var switchDimension = null;
  window.orgMuseumGraphNetwork = {
    dimension: '2d',
    supportedDimensions: ['2d', '3d'],
    setDimension: function (name) {
      return switchDimension ? switchDimension(name) : false;
    }
  };
  document.addEventListener('DOMContentLoaded', boot, {once: true});

  function boot() {
    var d3 = window.d3;
    var layouts = window.orgMuseumGraphLayout;
    var edgeMath = window.orgMuseumGraphEdges;
    if (!layouts || !edgeMath) return;
    var canvas = document.getElementById('graph-canvas');
    if (!canvas) return;
    var embedded = JSON.parse(document.getElementById('graph-data').textContent);
    var graph = {nodes: [], links: [], meta: {}};
    var params = new URLSearchParams(location.search);
    var selectedNodeId = params.get('focus') || '';
    var selectedEdgeId = '';
    var focusDepth = Infinity;
    var showIsolated = false;
    var query = (params.get('q') || '').trim().toLowerCase();
    var category = params.get('category') || '*';
    var relation = params.get('relation') || '*';
    var timeRange = params.get('time') || 'all';
    var view = params.get('view') === 'triage' ? 'triage' : 'relations';
    var zoomScale = 1;
    var dimension = params.get('dimension') === '3d' ? '3d' : '2d';
    var presentation = {};
    try { presentation = JSON.parse(localStorage.getItem('org-museum-graph-presentation') || '{}'); } catch (_error) {}
    var layoutMode = layouts.modes.includes(params.get('layout')) ? params.get('layout') :
      layouts.modes.includes(presentation.mode) ? presentation.mode : 'semantic';
    var layoutOptions = {spacing: Math.max(.7, Math.min(2, Number(presentation.spacing) || 1)),
      orientation: presentation.orientation === 'horizontal' ? 'horizontal' : 'vertical'};
    var frozen = presentation.frozen === true;
    var positions = new Map();
    var camera = {yaw: -.45, pitch: -.24, zoom: 1, centerX: 0, centerY: 0, centerZ: 0};
    var orbitStart = null;
    var simulation = null;
    var autoFitPending = true;
    var nodeSelection, edgeSelection, activeNodes = [], activeLinks = [];
    var hoveredEdgeId = '';
    var hoveredNodeId = '';
    var edgeRoutes = new Map();
    var nodeLabelBoxes = [];
    var lastSnapshot = '';
    var api = function (route, payload) {
      if (!window.orgMuseumGraphApi) return Promise.reject(new Error('请从 Emacs 启动本机服务后编辑关系'));
      return window.orgMuseumGraphApi(route, payload);
    };
    var status = document.getElementById('graph-match-status');
    var inspector = document.getElementById('graph-selected-detail');
    var prompt = document.getElementById('graph-selection-prompt');
    var footer = document.querySelector('.graph-workspace-footer');
    var search = document.getElementById('org-museum-global-search');
    var relationFilter = document.getElementById('graph-relation-filter');
    var categoryFilters = document.getElementById('graph-category-filters');
    var triageList = document.getElementById('graph-isolated-list');
    var edgeEditor = document.createElement('section');
    edgeEditor.className = 'graph-edge-editor';
    edgeEditor.hidden = true;
    footer.insertBefore(edgeEditor, footer.querySelector('#graph-legend'));
    var controls = document.querySelector('.graph-view-controls');
    var explore = document.createElement('div');
    explore.className = 'graph-network-controls';
    explore.innerHTML = '<div class="graph-dimension" role="group" aria-label="图谱维度">' +
      '<button type="button" data-dimension="2d" aria-pressed="true">2D</button>' +
      '<button type="button" data-dimension="3d" aria-pressed="false">3D</button></div>' +
      '<button type="button" data-explore="collapse">聚焦邻居</button>' +
      '<button type="button" data-explore="expand">展开一层</button>' +
      '<button type="button" data-explore="connected">关系网络</button>' +
      '<button type="button" data-explore="all">显示全部</button>';
    controls.appendChild(explore);
    var settings = document.createElement('details');
    settings.className = 'graph-layout-settings';
    settings.innerHTML = '<summary>布局微调</summary><div class="graph-layout-panel">' +
      '<div class="graph-layout-panel-head"><strong data-layout-name>拓扑语义层级流</strong>' +
      '<p data-layout-hint></p></div>' +
      '<label>节点间距 <output data-layout-spacing-value></output>' +
      '<input type="range" data-layout-spacing min="0.7" max="2" step="0.1" aria-label="节点间距"></label>' +
      '<label>层级方向<select data-layout-orientation><option value="vertical">从上到下</option>' +
      '<option value="horizontal">从左到右</option></select></label>' +
      '<label class="graph-layout-check"><input type="checkbox" data-layout-freeze>固定布局，停止自动移动</label>' +
      '<button type="button" data-layout-reset>重置拖拽位置</button>' +
      '<small>拖拽可固定单个节点；微调仅影响当前图谱视图。</small></div>';
    controls.insertBefore(settings, document.getElementById('btn-layout'));
    var layoutSelect = settings.querySelector('[data-layout-mode]');
    var layoutMenu = document.getElementById('graph-layout-options');
    var layoutLabel = document.getElementById('graph-layout-label');
    var layoutSearch = document.getElementById('graph-layout-search');
    var layoutCategories = document.getElementById('graph-layout-categories');
    var layoutCategoryNames = { hierarchical: '层级结构', network: '网状结构', radial: '辐射结构', grid: '网格结构' };
    var activeLayoutCategory = '*';

    if (layoutSelect) {
      layouts.modes.forEach(function (mode) {
        var option = document.createElement('option'); option.value = mode; option.textContent = layouts.labels[mode];
        layoutSelect.appendChild(option);
      });
      layoutSelect.addEventListener('change', function () { applyLayout(layoutSelect.value); });
    }

    function renderCommandBarLayoutMenu() {
      if (!layoutMenu) return;
      var query = layoutSearch ? layoutSearch.value.trim().toLowerCase() : '';
      layoutMenu.textContent = '';
      if (layoutCategories) {
        layoutCategories.textContent = '';
        ['*', 'hierarchical', 'network', 'radial', 'grid'].forEach(function (cat) {
          var btn = document.createElement('button');
          var catCount = cat === '*' ? layouts.modes.length :
            layouts.modes.filter(function (k) { return (layouts.categories && layouts.categories[k]) === cat; }).length;
          btn.type = 'button';
          btn.textContent = (layoutCategoryNames[cat] || '全部') + ' ' + catCount;
          btn.setAttribute('aria-pressed', cat === activeLayoutCategory ? 'true' : 'false');
          btn.addEventListener('click', function () {
            activeLayoutCategory = cat;
            renderCommandBarLayoutMenu();
          });
          layoutCategories.appendChild(btn);
        });
      }
      var filteredModes = layouts.modes.filter(function (key) {
        var cat = (layouts.categories && layouts.categories[key]) || 'network';
        var label = layouts.labels[key] || key;
        var hint = layouts.hints[key] || '';
        var catName = layoutCategoryNames[cat] || '';
        var matchCat = activeLayoutCategory === '*' || cat === activeLayoutCategory;
        var matchQuery = !query || (label + ' ' + hint + ' ' + catName).toLowerCase().includes(query);
        return matchCat && matchQuery;
      });
      filteredModes.forEach(function (key) {
        var cat = (layouts.categories && layouts.categories[key]) || 'network';
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.dataset.layout = key;
        btn.setAttribute('aria-pressed', key === layoutMode ? 'true' : 'false');
        var caption = document.createElement('span');
        caption.className = 'graph-layout-caption';
        var title = document.createElement('strong');
        title.textContent = layouts.labels[key] || key;
        var group = document.createElement('em');
        group.textContent = layoutCategoryNames[cat] || '';
        caption.appendChild(title);
        caption.appendChild(group);
        btn.appendChild(caption);
        var hint = document.createElement('small');
        hint.textContent = layouts.hints[key] || '';
        btn.appendChild(hint);
        btn.addEventListener('click', function () {
          applyLayout(key);
          var details = layoutMenu.closest('details');
          if (details) details.open = false;
        });
        layoutMenu.appendChild(btn);
      });
      if (layoutLabel) layoutLabel.textContent = layouts.labels[layoutMode] || layoutMode;
    }
    if (layoutSearch) layoutSearch.addEventListener('input', renderCommandBarLayoutMenu);

    function syncLayoutSettings() {
      if (layoutSelect) layoutSelect.value = layoutMode;
      var nameEl = settings.querySelector('[data-layout-name]');
      if (nameEl) nameEl.textContent = layouts.labels[layoutMode] || layoutMode;
      settings.querySelector('summary').textContent = '布局微调';
      settings.querySelector('[data-layout-hint]').textContent = layouts.hints[layoutMode] || '';
      settings.querySelector('[data-layout-spacing]').value = layoutOptions.spacing;
      settings.querySelector('[data-layout-spacing-value]').textContent = Number(layoutOptions.spacing).toFixed(1) + '×';
      settings.querySelector('[data-layout-orientation]').value = layoutOptions.orientation;
      settings.querySelector('[data-layout-orientation]').disabled = !['hierarchy', 'semantic', 'dagre', 'treeVertical', 'treeHorizontal'].includes(layoutMode);
      settings.querySelector('[data-layout-freeze]').checked = frozen;
      if (layoutLabel) layoutLabel.textContent = layouts.labels[layoutMode] || layoutMode;
      renderCommandBarLayoutMenu();
    }
    function savePresentation() {
      try { localStorage.setItem('org-museum-graph-presentation', JSON.stringify({mode: layoutMode,
        spacing: layoutOptions.spacing, orientation: layoutOptions.orientation, frozen: frozen})); } catch (_error) {}
    }
    function applyLayout(mode) {
      rememberPositions(); layoutMode = mode;
      positions = layouts.positions(visibleNodes(), graph.links, mode, canvas.clientWidth || 900,
        canvas.clientHeight || 700, layoutOptions);
      positions.forEach(function (pos) { delete pos.fx; delete pos.fy; });
      if (simulation) activeNodes.forEach(function (n) { n.fx = null; n.fy = null; });
      autoFitPending = true; syncLayoutSettings(); savePresentation();
      render(); fit(); writeUrl(false); announce('已使用' + (layouts.labels[mode] || mode) + '布局');
    }
    settings.querySelector('[data-layout-spacing]').addEventListener('input', function (event) {
      settings.querySelector('[data-layout-spacing-value]').textContent = Number(event.target.value).toFixed(1) + '×';
    });
    settings.querySelector('[data-layout-spacing]').addEventListener('change', function (event) {
      layoutOptions.spacing = Number(event.target.value); applyLayout(layoutMode);
    });
    settings.querySelector('[data-layout-orientation]').addEventListener('change', function (event) {
      layoutOptions.orientation = event.target.value; applyLayout(layoutMode);
    });
    settings.querySelector('[data-layout-freeze]').addEventListener('change', function (event) {
      frozen = event.target.checked; rememberPositions(); savePresentation(); render();
    });
    settings.querySelector('[data-layout-reset]').addEventListener('click', function () { applyLayout(layoutMode); });
    document.addEventListener('click', function (event) {
      if (!settings.contains(event.target)) settings.open = false;
      document.querySelectorAll('.graph-commandbar details[open]').forEach(function (d) {
        if (!d.contains(event.target)) d.open = false;
      });
    });
    settings.addEventListener('keydown', function (event) {
      if (event.key === 'Escape') { settings.open = false; settings.querySelector('summary').focus(); }
    });
    syncLayoutSettings();
    document.body.classList.add('is-network-runtime');

    function announce(message) { status.textContent = message; }
    function writeUrl(push) {
      var url = new URL(location.href);
      [['q', query], ['category', category === '*' ? '' : category],
       ['relation', relation === '*' ? '' : relation],
       ['time', timeRange === 'all' ? '' : timeRange],
       ['focus', selectedNodeId],
       ['view', view === 'triage' ? 'triage' : ''],
       ['dimension', dimension === '3d' ? '3d' : ''], ['layout', layoutMode]].forEach(function (entry) {
        if (entry[1]) url.searchParams.set(entry[0], entry[1]);
        else url.searchParams.delete(entry[0]);
      });
      history[push ? 'pushState' : 'replaceState']({}, '', url.pathname + url.search + url.hash);
    }
    function nodeById(id) { return graph.nodes.find(function (node) { return node.id === id; }); }
    function endpoint(value) { return value && typeof value === 'object' ? value.id : value; }
    function edgeSource(edge) { return endpoint(edge.source); }
    function edgeTarget(edge) { return endpoint(edge.target); }
    function shortName(name) {
      var chars = Array.from(name || '未命名');
      var limit = window.innerWidth <= 600 ? 9 : 16;
      return chars.length > limit ? chars.slice(0, limit - 1).join('') + '…' : chars.join('');
    }
    function color(node) {
      return window.orgMuseumCategoryColor ? window.orgMuseumCategoryColor(node.group) : 'var(--museum-node-fill)';
    }
    function radius(node) { return 8 + Math.min(9, Math.sqrt(Math.max(0, node.degree || 0)) * 3); }
    function snapshot(value) {
      return JSON.stringify(value);
    }
    function setGraph(value) {
      var next = snapshot(value);
      if (next === lastSnapshot) return;
      graph = {nodes: (value.nodes || []).map(function (node) { return Object.assign({}, node); }),
        links: (value.links || []).map(function (edge) { return Object.assign({}, edge); }),
        meta: value.meta || {}};
      var currentIds = new Set(graph.nodes.map(function (node) { return node.id; }));
      positions.forEach(function (_position, id) { if (!currentIds.has(id)) positions.delete(id); });
      lastSnapshot = next;
      if (selectedNodeId && !nodeById(selectedNodeId)) selectedNodeId = '';
      if (selectedEdgeId && !graph.links.some(function (edge) { return edge.id === selectedEdgeId; })) selectedEdgeId = '';
      updateControls();
      render();
      if (selectedEdgeId) showEdge(graph.links.find(function (edge) { return edge.id === selectedEdgeId; }));
      else if (selectedNodeId) showNode(nodeById(selectedNodeId), false);
      else showPrompt();
    }

    var svg = d3.select(canvas).append('svg')
      .attr('role', 'group')
      .attr('aria-label', '可探索知识图谱')
      .style('display', 'block')
      .style('width', '100%')
      .style('height', '100%')
      .style('pointer-events', 'all')
      .style('cursor', 'grab');

    // 1. Transparent full-canvas catcher: ensures every single pixel of empty space
    // captures pointer, drag, and wheel events without browser SVG dropouts (from DuckDB Editor)
    var bgCatcher = svg.append('rect')
      .attr('class', 'graph-canvas-catcher')
      .attr('x', 0)
      .attr('y', 0)
      .attr('width', '100%')
      .attr('height', '100%')
      .attr('fill', '#000')
      .attr('fill-opacity', 0)
      .attr('pointer-events', 'all')
      .style('pointer-events', 'all')
      .style('cursor', 'grab');

    var edgeLayer = svg.append('g').attr('class', 'graph-links');
    var root = svg.append('g');
    var nodeLayer = root.append('g').attr('class', 'graph-nodes');
    var defs = svg.append('defs');
    defs.append('marker').attr('id', 'network-arrow')
      .attr('viewBox', '0 -4 10 8').attr('refX', 9).attr('refY', 0)
      .attr('markerUnits', 'userSpaceOnUse')
      .attr('markerWidth', 9.5).attr('markerHeight', 9.5)
      .attr('orient', 'auto-start-reverse').append('path')
      .attr('d', 'M0,-3.5L9,0L0,3.5L2.2,0Z').attr('fill', 'currentColor');
    defs.append('marker').attr('id', 'network-arrow-selected')
      .attr('viewBox', '0 -4 10 8').attr('refX', 9.2).attr('refY', 0)
      .attr('markerUnits', 'userSpaceOnUse')
      .attr('markerWidth', 11.5).attr('markerHeight', 11.5)
      .attr('orient', 'auto-start-reverse').append('path')
      .attr('d', 'M0,-3.5L9,0L0,3.5L2.2,0Z').attr('fill', 'currentColor');

    function updateZoomButtons() {
      var inBtn = document.getElementById('btn-zoom-in');
      var outBtn = document.getElementById('btn-zoom-out');
      if (inBtn) inBtn.disabled = zoomScale >= 9.9;
      if (outBtn) outBtn.disabled = zoomScale <= 0.055;
    }

    var zoom = d3.zoom()
      .scaleExtent([0.05, 10])
      .wheelDelta(function (event) {
        // High-precision smooth wheel delta centered at cursor
        return -event.deltaY * (event.deltaMode === 1 ? 0.05 : event.deltaMode ? 1 : 0.002);
      })
      .filter(function (event) {
        if (event.button === 2) return false; // right-click reserved
        if (event.type === 'wheel') return dimension === '2d'; // wheel zoom anywhere on blank area or elements
        // Support both left-click (0) and middle-mouse button (1) dragging/panning
        return dimension === '2d' && (event.button === 0 || event.button === 1);
      })
      .on('zoom', function (event) {
        if (event.sourceEvent) autoFitPending = false;
        zoomScale = event.transform.k;
        root.attr('transform', event.transform);
        updateLabels(); drawEdges(); updateZoomButtons();
      });

    svg.call(zoom).on('dblclick.zoom', null);

    // Double-click on blank space triggers fit-all
    svg.on('dblclick', function (event) {
      if (event.target === svg.node() || (event.target && event.target.classList && event.target.classList.contains('graph-canvas-catcher'))) {
        event.preventDefault();
        fit();
      }
    });

    // Prevent default Windows Chrome autoscroll compass icon on middle-click
    function preventMiddleAutoscroll(event) {
      if (event.button === 1) event.preventDefault();
    }
    ['mousedown', 'pointerdown', 'auxclick'].forEach(function (type) {
      svg.node().addEventListener(type, preventMiddleAutoscroll);
      canvas.addEventListener(type, preventMiddleAutoscroll);
    });

    // Fallback wheel zoom delegator: guarantees any mousewheel on canvas or stage outside SVG triggers smooth zoom
    function handleCanvasWheel(event) {
      if (dimension !== '2d') return;
      if (event.defaultPrevented) return;
      event.preventDefault();
      var delta = -event.deltaY * (event.deltaMode === 1 ? 0.05 : event.deltaMode ? 1 : 0.002);
      var factor = Math.pow(2, delta);
      var targetScale = Math.max(0.05, Math.min(10, zoomScale * factor));
      if (Math.abs(targetScale - zoomScale) < 1e-4) return;
      var rect = canvas.getBoundingClientRect();
      var pointer = [event.clientX - rect.left, event.clientY - rect.top];
      svg.call(zoom.scaleBy, factor, pointer);
    }
    canvas.addEventListener('wheel', handleCanvasWheel, { passive: false });
    var stage = canvas.closest('.graph-canvas-stage');
    if (stage) stage.addEventListener('wheel', handleCanvasWheel, { passive: false });

    function project(node) {
      if (dimension === '2d') return {x: node.x, y: node.y, scale: 1, depth: 0};
      var w = canvas.clientWidth || 900, h = canvas.clientHeight || 700;
      var x = (Number.isFinite(node.x) ? node.x : w / 2) - camera.centerX;
      var y = (Number.isFinite(node.y) ? node.y : h / 2) - camera.centerY;
      var z = (node.z || 0) - camera.centerZ;
      var cy = Math.cos(camera.yaw), sy = Math.sin(camera.yaw);
      var cp = Math.cos(camera.pitch), sp = Math.sin(camera.pitch);
      var rotatedX = x * cy + z * sy;
      var rotatedZ = z * cy - x * sy;
      var rotatedY = y * cp - rotatedZ * sp;
      var depth = y * sp + rotatedZ * cp;
      var scale = camera.zoom * 950 / Math.max(280, 950 - depth);
      return {x: w / 2 + rotatedX * scale, y: h / 2 + rotatedY * scale,
        scale: scale, depth: depth};
    }
    function rememberPositions() {
      activeNodes.forEach(function (node) {
        positions.set(node.id, {x: node.x, y: node.y, z: node.z || 0, cx: node.cx, cy: node.cy,
          fx: node.fx, fy: node.fy});
      });
    }
    function updateDimensionControls() {
      explore.querySelectorAll('[data-dimension]').forEach(function (button) {
        button.setAttribute('aria-pressed', button.dataset.dimension === dimension ? 'true' : 'false');
      });
      canvas.classList.toggle('is-3d', dimension === '3d');
      svg.attr('aria-label', dimension === '3d' ? '可旋转的三维知识图谱' : '可探索知识图谱');
      root.attr('transform', dimension === '3d' ? null : d3.zoomTransform(svg.node()));
    }
    switchDimension = function (name) {
      if (name !== '2d' && name !== '3d') return false;
      if (dimension === name) return true;
      rememberPositions();
      dimension = name;
      window.orgMuseumGraphNetwork.dimension = name;
      updateDimensionControls();
      svg.interrupt(); render(); fit(); writeUrl(false);
      return true;
    };

    function visibleNodes() {
      var filtered = graph.nodes.filter(function (node) {
        var text = [node.name, node.group].concat(node.tags || []).join(' ').toLowerCase();
        return (showIsolated || query || category !== '*' || !graph.links.length ||
          node.degree > 0 || node.id === selectedNodeId) &&
          (category === '*' || node.group === category) && (!query || text.includes(query));
      });
      if (relation !== '*') filtered = filtered.filter(function (node) {
        return graph.links.some(function (edge) {
          return edge.type === relation && (edgeSource(edge) === node.id || edgeTarget(edge) === node.id);
        });
      });
      if (timeRange !== 'all') {
        var days = parseInt(timeRange, 10);
        if (!isNaN(days) && days > 0) {
          var recentIds = recentNodeIds(graph.nodes, days);
          filtered = filtered.filter(function (node) {
            if (node.id === selectedNodeId) return true;
            return recentIds.has(node.id);
          });
        }
      }
      if (!selectedNodeId || !Number.isFinite(focusDepth)) return filtered;
      var allowed = new Set([selectedNodeId]);
      var frontier = [selectedNodeId];
      for (var step = 0; step < focusDepth; step += 1) {
        var next = [];
        graph.links.forEach(function (edge) {
          var source = edgeSource(edge), target = edgeTarget(edge);
          if (frontier.includes(source) && !allowed.has(target)) {allowed.add(target); next.push(target);}
          if (frontier.includes(target) && !allowed.has(source)) {allowed.add(source); next.push(source);}
        });
        frontier = next;
      }
      return filtered.filter(function (node) { return allowed.has(node.id); });
    }
    function updateLabels() {
      placeLabels();
    }
    function placeLabels() {
      if (!nodeSelection) return;
      var transform = d3.zoomTransform(svg.node());
      var scale = dimension === '2d' ? transform.k : (camera.zoom || 1);
      nodeLabelBoxes = [];

      nodeSelection.each(function (node) {
        var text = d3.select(this).select('.graph-node-title');
        var r = radius(node);
        var isKey = node.id === selectedNodeId || node.id === hoveredNodeId;

        // DuckDB Editor auto-filter: at very far zoom-out, only show higher degree or highlighted nodes
        var show = isKey;
        if (!show) {
          if (scale < 0.35) {
            show = (node.degree || 0) > 2;
          } else if (scale < 0.65) {
            show = (node.degree || 0) > 0;
          } else {
            show = true;
          }
        }

        text.style('display', show ? null : 'none');
        if (show) {
          text.attr('x', r + 8).attr('y', 0);
          var p = project(node);
          var x = dimension === '2d' ? p.x * transform.k + transform.x : p.x;
          var y = dimension === '2d' ? p.y * transform.k + transform.y : p.y;
          var labelLen = shortName(node.name).length;
          nodeLabelBoxes.push({
            x: x + (r + 8) * (dimension === '2d' ? transform.k : 1),
            y: y - 8 * (dimension === '2d' ? transform.k : 1),
            width: labelLen * 11 * (dimension === '2d' ? transform.k : 1),
            height: 16 * (dimension === '2d' ? transform.k : 1)
          });
        }
      });
    }
    function tick() {
      rememberPositions();
      nodeSelection.attr('transform', function (node) {
        var p = project(node);
        return 'translate(' + p.x + ',' + p.y + ') scale(' + Math.max(.55, Math.min(1.55, p.scale)) + ')';
      }).style('opacity', function (node) {
        return dimension === '3d' ? Math.max(.5, Math.min(1, .8 + project(node).depth / 1100)) : null;
      });
      placeLabels();
      drawEdges();
    }
    function applyEdgeFocus() {
      if (!edgeSelection) return;
      var activeNodeId = hoveredNodeId || selectedNodeId;
      var focus = selectedEdgeId || hoveredEdgeId || activeNodeId;
      edgeSelection
        .classed('is-selected', function (edge) { return edge.id === selectedEdgeId; })
        .classed('is-hovered', function (edge) { return edge.id === hoveredEdgeId; })
        .classed('is-incident', function (edge) {
          return !selectedEdgeId && !hoveredEdgeId && !!activeNodeId &&
            (edgeSource(edge) === activeNodeId || edgeTarget(edge) === activeNodeId);
        })
        .classed('is-muted', function (edge) {
          if (!focus) return false;
          if (edge.id === selectedEdgeId || edge.id === hoveredEdgeId) return false;
          return !!selectedEdgeId || !!hoveredEdgeId || !activeNodeId ||
            (edgeSource(edge) !== activeNodeId && edgeTarget(edge) !== activeNodeId);
        });
      edgeSelection.select('.graph-network-edge-line')
        .attr('marker-end', function (edge) {
          if (!edgeMath.flow(edge).atEnd) return null;
          return (edge.id === selectedEdgeId || edge.id === hoveredEdgeId)
            ? 'url(#network-arrow-selected)'
            : 'url(#network-arrow)';
        })
        .attr('marker-start', function (edge) {
          if (!edgeMath.flow(edge).atStart) return null;
          return (edge.id === selectedEdgeId || edge.id === hoveredEdgeId)
            ? 'url(#network-arrow-selected)'
            : 'url(#network-arrow)';
        });
      if (nodeSelection) {
        nodeSelection
          .classed('is-selected', function (node) { return node.id === selectedNodeId; })
          .classed('is-hovered', function (node) { return node.id === hoveredNodeId; })
          .classed('is-endpoint', function (node) {
            if (!selectedEdgeId && !hoveredEdgeId) return false;
            var activeId = selectedEdgeId || hoveredEdgeId;
            var edge = graph.links.find(function (e) { return e.id === activeId; });
            return edge && (edgeSource(edge) === node.id || edgeTarget(edge) === node.id);
          })
          .classed('is-context', function (node) {
            if (selectedEdgeId || hoveredEdgeId) {
              var activeId = selectedEdgeId || hoveredEdgeId;
              var edge = graph.links.find(function (e) { return e.id === activeId; });
              return edge && edgeSource(edge) !== node.id && edgeTarget(edge) !== node.id;
            }
            if (activeNodeId) {
              return node.id !== activeNodeId && !graph.links.some(function (edge) {
                return (edgeSource(edge) === activeNodeId && edgeTarget(edge) === node.id) ||
                  (edgeTarget(edge) === activeNodeId && edgeSource(edge) === node.id);
              });
            }
            return false;
          });
      }
    }
    function intersects(a, b, gap) {
      return a.x < b.x + b.width + gap && a.x + a.width + gap > b.x &&
        a.y < b.y + b.height + gap && a.y + a.height + gap > b.y;
    }
    function placeEdgeLabels(points, radii) {
      if (!edgeSelection) return;
      var width = canvas.clientWidth || 900, height = canvas.clientHeight || 700;
      var accepted = [], nodeBoxes = nodeLabelBoxes.slice();
      activeNodes.forEach(function (node) {
        var p = points.get(node.id), r = radii.get(node.id) || 8;
        if (p) nodeBoxes.push({x: p.x - r - 4, y: p.y - r - 4,
          width: 2 * r + 8, height: 2 * r + 8});
      });
      var svgBox = svg.node().getBoundingClientRect();
      nodeSelection.select('.graph-node-title').each(function () {
        if (getComputedStyle(this).display === 'none') return;
        var box = this.getBoundingClientRect();
        if (box.width && box.height) nodeBoxes.push({x: box.left - svgBox.left,
          y: box.top - svgBox.top, width: box.width, height: box.height});
      });
      var ranked = activeLinks.slice().sort(function (a, b) {
        function priority(edge) {
          if (edge.id === selectedEdgeId) return 0;
          if (edge.id === hoveredEdgeId) return 1;
          var activeNode = hoveredNodeId || selectedNodeId;
          if (activeNode && (edgeSource(edge) === activeNode || edgeTarget(edge) === activeNode)) return 2;
          return 3;
        }
        return priority(a) - priority(b) || a.id.localeCompare(b.id);
      });
      ranked.forEach(function (edge) {
        var label = edgeSelection.filter(function (candidate) { return candidate.id === edge.id; })
          .select('.graph-network-edge-label');
        var element = label.node(), route = edgeRoutes.get(edge.id);
        if (!element || !route) { label.style('display', 'none'); return; }

        var isFocusedEdge = edge.id === selectedEdgeId || edge.id === hoveredEdgeId;
        var activeNode = hoveredNodeId || selectedNodeId;
        var isConnectedToFocus = activeNode && (edgeSource(edge) === activeNode || edgeTarget(edge) === activeNode);
        var isCustomSemantic = edge.type && edge.type !== '显式链接' && edge.type !== 'related';

        // Auto edge label display: default only show high-value semantic relationships;
        // Show all edge types when hovering/selecting the edge or incident node
        if (!isFocusedEdge && !isConnectedToFocus && !isCustomSemantic) {
          label.style('display', 'none');
          return;
        }

        label.style('display', null);
        var textWidth = element.getComputedTextLength ? element.getComputedTextLength() : (edge.label || edge.type || '').length * 10;
        var boxWidth = textWidth + 8, boxHeight = 17;
        var chosen = edgeMath.labelCandidates(route).find(function (candidate) {
          var box = {x: candidate.x - boxWidth / 2, y: candidate.y - 12,
            width: boxWidth, height: boxHeight};
          if (box.x < 3 || box.y < 3 || box.x + box.width > width - 3 || box.y + box.height > height - 3) return false;
          if (nodeBoxes.some(function (other) { return intersects(box, other, 3); })) return false;
          if (accepted.some(function (other) { return intersects(box, other, 5); })) return false;
          return !Array.from(edgeRoutes).some(function (entry) {
            if (entry[0] === edge.id) return false;
            for (var t = .08; t < .94; t += .06) {
              var p = edgeMath.point(entry[1], t);
              if (p.x >= box.x - 3 && p.x <= box.x + box.width + 3 &&
                  p.y >= box.y - 3 && p.y <= box.y + box.height + 3) return true;
            }
            return false;
          });
        });
        if (chosen) {
          label.attr('x', chosen.x).attr('y', chosen.y).style('display', null);
          accepted.push({x: chosen.x - boxWidth / 2, y: chosen.y - 12,
            width: boxWidth, height: boxHeight});
        } else label.style('display', 'none');
      });
    }
    function drawEdges() {
      if (!edgeSelection || !nodeSelection) return;
      var transform = d3.zoomTransform(svg.node()), points = new Map(), radii = new Map();
      activeNodes.forEach(function (node) {
        var projection = project(node);
        var scale = dimension === '2d' ? transform.k : Math.max(.55, Math.min(1.55, projection.scale));
        points.set(node.id, dimension === '2d' ? {x: transform.applyX(projection.x),
          y: transform.applyY(projection.y)} : projection);
        radii.set(node.id, radius(node) * scale);
      });
      edgeRoutes = edgeMath.routes(activeNodes, activeLinks, points, radii, edgeRoutes);
      edgeSelection.selectAll('path').attr('d', function (edge) {
        var route = edgeRoutes.get(edge.id); return route ? route.path : null;
      });
      placeEdgeLabels(points, radii);
    }
    function render() {
      if (simulation) simulation.stop();
      var w = canvas.clientWidth || 900, h = canvas.clientHeight || 700;
      var visible = visibleNodes();
      var starting = layouts.positions(visible, graph.links, layoutMode, w, h, layoutOptions);
      activeNodes = visible.map(function (node) {
        var position = positions.get(node.id) || starting.get(node.id) || {x: w / 2, y: h / 2, z: 0};
        return Object.assign({}, node, starting.get(node.id), position);
      });
      if (activeNodes.length) {
        camera.centerX = (Math.min.apply(null, activeNodes.map(function (node) { return node.x; })) +
          Math.max.apply(null, activeNodes.map(function (node) { return node.x; }))) / 2;
        camera.centerY = (Math.min.apply(null, activeNodes.map(function (node) { return node.y; })) +
          Math.max.apply(null, activeNodes.map(function (node) { return node.y; }))) / 2;
        camera.centerZ = (Math.min.apply(null, activeNodes.map(function (node) { return node.z || 0; })) +
          Math.max.apply(null, activeNodes.map(function (node) { return node.z || 0; }))) / 2;
      }
      var ids = new Set(activeNodes.map(function (node) { return node.id; }));
      activeLinks = graph.links.filter(function (edge) {
        return ids.has(edgeSource(edge)) && ids.has(edgeTarget(edge)) &&
          (relation === '*' || relation === edge.type);
      }).map(function (edge) { return Object.assign({}, edge); });
      svg.attr('viewBox', '0 0 ' + w + ' ' + h)
        .attr('preserveAspectRatio', 'none');
      bgCatcher.attr('width', w).attr('height', h);
      edgeSelection = edgeLayer.selectAll('g.graph-network-edge').data(activeLinks, function (edge) { return edge.id; })
        .join(function (enter) {
          var item = enter.append('g').attr('class', 'graph-network-edge').attr('role', 'button').attr('tabindex', 0);
          item.append('path').attr('class', 'graph-network-edge-line');
          item.append('path').attr('class', 'graph-network-edge-hit');
          item.append('text').attr('class', 'graph-network-edge-label');
          return item;
        });
      edgeSelection.select('.graph-network-edge-line')
        .style('--graph-edge-width', function (edge) {
          return Math.max(1.5, Math.min(2.8, 1.8 + .5 * (Math.sqrt(Math.max(.2, edge.weight || 1)) - 1))) + 'px';
        })
        .attr('stroke-dasharray', function (edge) {
          return edge.style === 'dashed' ? '7 5' : edge.style === 'dotted' ? '2 5' : null;
        })
        .attr('marker-end', function (edge) {
          if (!edgeMath.flow(edge).atEnd) return null;
          return (edge.id === selectedEdgeId || edge.id === hoveredEdgeId)
            ? 'url(#network-arrow-selected)'
            : 'url(#network-arrow)';
        })
        .attr('marker-start', function (edge) {
          if (!edgeMath.flow(edge).atStart) return null;
          return (edge.id === selectedEdgeId || edge.id === hoveredEdgeId)
            ? 'url(#network-arrow-selected)'
            : 'url(#network-arrow)';
        });
      edgeSelection.select('.graph-network-edge-label').text(function (edge) { return edge.label || edge.type; });
      edgeSelection.attr('aria-label', function (edge) {
        var flow = edgeMath.flow(edge);
        return (nodeById(flow.from) || {}).name + (edge.direction === 'both' ? ' 与 ' : ' 到 ') +
          (nodeById(flow.to) || {}).name + (edge.direction === 'both' ? ' 双向，' : '，') + (edge.label || edge.type);
      })
        .on('click', function (event, edge) { event.stopPropagation(); showEdge(edge); })
        .on('mouseenter focus', function (_event, edge) { hoveredEdgeId = edge.id; applyEdgeFocus(); drawEdges(); })
        .on('mouseleave blur', function () { hoveredEdgeId = ''; applyEdgeFocus(); drawEdges(); })
        .on('keydown', function (event, edge) { if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault(); showEdge(edge);
        }});
      nodeSelection = nodeLayer.selectAll('g.graph-network-node').data(activeNodes, function (node) { return node.id; })
        .join(function (enter) {
          var item = enter.append('g').attr('class', 'graph-network-node').attr('role', 'button').attr('tabindex', 0);
          item.append('circle').attr('class', 'graph-node-hit-target').attr('r', 25);
          item.append('circle').attr('class', 'graph-node-halo');
          item.append('circle').attr('class', 'graph-node-dot');
          item.append('text').attr('class', 'graph-node-title')
            .attr('text-anchor', 'start')
            .attr('dominant-baseline', 'central');
          item.append('title');
          return item;
        });
      nodeSelection.select('.graph-node-halo').attr('r', function (node) { return radius(node) + 6; });
      nodeSelection.select('.graph-node-dot').attr('r', radius)
        .style('--graph-node-color', color);
      nodeSelection.select('.graph-node-title')
        .attr('x', function (node) { return radius(node) + 8; })
        .attr('y', 0)
        .text(function (node) { return shortName(node.name); });
      nodeSelection.select('title').text(function (node) { return node.name; });
      nodeSelection.attr('aria-label', function (node) { return node.name + '，' + node.degree + ' 条关系'; })
        .classed('is-selected', function (node) { return node.id === selectedNodeId; })
        .classed('is-context', function (node) {
          return !!selectedNodeId && node.id !== selectedNodeId && !graph.links.some(function (edge) {
            return (edgeSource(edge) === selectedNodeId && edgeTarget(edge) === node.id) ||
              (edgeTarget(edge) === selectedNodeId && edgeSource(edge) === node.id);
          });
        })
        .on('click', function (event, node) { event.stopPropagation(); showNode(node); })
        .on('dblclick', function (event, node) { event.stopPropagation(); location.href = node.url; })
        .on('keydown', function (event, node) {
          if (event.key === 'Enter') location.href = node.url;
          if (event.key === ' ') {event.preventDefault(); showNode(node);}
        })
        .on('mouseenter focus', function (event, node) {
          hoveredNodeId = node.id;
          applyEdgeFocus();
          drawEdges();
          var tt = document.getElementById('graph-tooltip');
          if (!tt) return;
          var tTitle = document.getElementById('tt-title');
          var tMeta = document.getElementById('tt-meta');
          if (tTitle) tTitle.textContent = node.name;
          if (tMeta) tMeta.textContent = (node.group || '未分类') + ' · ' + (node.degree || 0) + ' 条关系' +
            (node.tags && node.tags.length ? ' · #' + node.tags.join(' #') : '');
          tt.style.left = Math.min(window.innerWidth - 260, Math.max(10, event.clientX + 14)) + 'px';
          tt.style.top = Math.min(window.innerHeight - 80, Math.max(10, event.clientY + 14)) + 'px';
          tt.classList.add('is-visible');
        })
        .on('mousemove', function (event) {
          var tt = document.getElementById('graph-tooltip');
          if (!tt || !tt.classList.contains('is-visible')) return;
          tt.style.left = Math.min(window.innerWidth - 260, Math.max(10, event.clientX + 14)) + 'px';
          tt.style.top = Math.min(window.innerHeight - 80, Math.max(10, event.clientY + 14)) + 'px';
        })
        .on('mouseleave blur', function () {
          hoveredNodeId = '';
          applyEdgeFocus();
          drawEdges();
          var tt = document.getElementById('graph-tooltip');
          if (tt) tt.classList.remove('is-visible');
        });
      nodeSelection.call(d3.drag().clickDistance(4)
        .on('start', function (event, node) {
          node._dragBefore = {fx: node.fx, fy: node.fy}; node._dragMoved = false;
          if (simulation && !frozen && !event.active) simulation.alphaTarget(.18).restart();
          node.fx = node.x; node.fy = node.y;
        })
        .on('drag', function (event, node) {
          node._dragMoved = true;
          if (dimension === '3d') {
            node.x += event.dx / Math.max(.3, camera.zoom);
            node.y += event.dy / Math.max(.3, camera.zoom);
            node.fx = node.x; node.fy = node.y;
          } else { node.fx = event.x; node.fy = event.y; }
          if (!simulation || frozen) { node.x = node.fx; node.y = node.fy; tick(); }
        })
        .on('end', function (event, node) {
          if (!node._dragMoved) {node.fx = node._dragBefore.fx; node.fy = node._dragBefore.fy;}
          delete node._dragBefore; delete node._dragMoved;
          if (simulation && !event.active) simulation.alphaTarget(0);
          rememberPositions();
        }));
      if (layoutMode === 'force') {
        simulation = d3.forceSimulation(activeNodes).stop()
        .force('link', d3.forceLink(activeLinks).id(function (node) { return node.id; })
          .distance(function (edge) { return 185 * layoutOptions.spacing / Math.sqrt(Math.max(.2, edge.weight || 1)); })
          .strength(.36))
        .force('charge', d3.forceManyBody().strength(-220 * layoutOptions.spacing))
        .force('collide', d3.forceCollide().radius(function (node) { return radius(node) + 42; }).iterations(3))
        .force('x', d3.forceX(function (node) { return node.cx; }).strength(.055))
        .force('y', d3.forceY(function (node) { return node.cy; }).strength(.055))
        .alphaDecay(.035).on('tick', tick).on('end', function () {
          if (autoFitPending) { autoFitPending = false; fit(); }
        });
        if (!frozen) { simulation.tick(100); simulation.alpha(.08).restart(); }
      }
      else {
        simulation = null;
        var byId = new Map(activeNodes.map(function (node) { return [node.id, node]; }));
        activeLinks.forEach(function (edge) {
          edge.source = byId.get(edgeSource(edge));
          edge.target = byId.get(edgeTarget(edge));
        });
      }
      applyEdgeFocus(); tick(); updateLabels();
      document.getElementById('stat-nodes').textContent = graph.nodes.length;
      document.getElementById('stat-links').textContent = graph.links.length;
      document.getElementById('stat-cats').textContent = new Set(graph.nodes.map(function (node) { return node.group; })).size;
      document.getElementById('graph-heading-count').textContent = '/ ' + graph.nodes.length;
      document.getElementById('graph-relation-count').textContent = graph.nodes.filter(function (node) { return node.degree > 0; }).length;
      document.getElementById('graph-triage-count').textContent = graph.nodes.filter(function (node) { return node.degree === 0; }).length;
      announce(view === 'triage'
        ? '待连接笔记 ' + graph.nodes.filter(function (node) { return node.degree === 0; }).length + ' 篇'
        : '显示 ' + activeNodes.length + ' 篇笔记、' + activeLinks.length + ' 条关系');
    }

    function updateControls() {
      var categories = Array.from(new Set(graph.nodes.map(function (node) { return node.group; }).filter(Boolean))).sort();
      if (category !== '*' && !categories.includes(category)) category = '*';
      categoryFilters.textContent = '';
      [['*', '全部']].concat(categories.map(function (name) { return [name, name]; })).forEach(function (entry) {
        var button = document.createElement('button');
        button.type = 'button'; button.textContent = entry[1];
        button.setAttribute('aria-pressed', category === entry[0] ? 'true' : 'false');
        button.addEventListener('click', function () {
          category = entry[0];
          var parentDetails = button.closest('details');
          if (parentDetails) parentDetails.open = false;
          updateControls(); render(); fit(); writeUrl(true);
        });
        categoryFilters.appendChild(button);
      });
      document.getElementById('graph-filter-label').textContent = category === '*' ? '全部主题' : category;
      var timeFilters = document.getElementById('graph-time-filters');
      if (timeFilters) {
        timeFilters.textContent = '';
        var timeOptions = [
          ['all', '全部'],
          ['7', '近 7 天'],
          ['30', '近 30 天'],
          ['90', '近 90 天'],
          ['180', '近半年'],
          ['365', '近 1 年']
        ];
        timeOptions.forEach(function (entry) {
          var button = document.createElement('button');
          button.type = 'button';
          button.textContent = entry[1];
          button.setAttribute('aria-pressed', timeRange === entry[0] ? 'true' : 'false');
          button.addEventListener('click', function () {
            if (entry[0] !== 'all' && timeRange === entry[0]) {
              timeRange = 'all';
            } else {
              timeRange = entry[0];
            }
            var parentDetails = button.closest('details');
            if (parentDetails) parentDetails.open = false;
            updateControls();
            render();
            fit();
            writeUrl(true);
          });
          timeFilters.appendChild(button);
        });
        var activeTime = timeOptions.find(function (opt) { return opt[0] === timeRange; });
        var timeLabelEl = document.getElementById('graph-time-label');
        if (timeLabelEl) timeLabelEl.textContent = activeTime ? activeTime[1] : '全部';
      }
      var types = Array.from(new Set(graph.links.map(function (edge) { return edge.type; }))).sort();
      relationFilter.textContent = '';
      [['*', '全部关系']].concat(types.map(function (name) { return [name, name]; })).forEach(function (entry) {
        var option = document.createElement('option'); option.value = entry[0]; option.textContent = entry[1];
        relationFilter.appendChild(option);
      });
      if (relation !== '*' && !types.includes(relation)) relation = '*';
      relationFilter.value = relation;
      var legend = document.getElementById('graph-relation-legend'); legend.textContent = '';
      types.forEach(function (type) {var item = document.createElement('li'); item.textContent = type; legend.appendChild(item);});
      triageList.textContent = '';
      var isolatedList = graph.nodes.filter(function (node) { return node.degree === 0; });
      if (!isolatedList.length) {
        var emptyMsg = document.createElement('p');
        emptyMsg.className = 'graph-isolated-empty';
        emptyMsg.textContent = '所有笔记均已建立知识连线，暂无待连接笔记。';
        triageList.appendChild(emptyMsg);
      } else {
        isolatedList.forEach(function (node) {
          var item = document.createElement('button'); item.type = 'button'; item.textContent = node.name;
          item.addEventListener('click', function () { showIsolated = true; setView('relations'); showNode(node); });
          triageList.appendChild(item);
        });
      }
      document.getElementById('graph-isolated-count').textContent = isolatedList.length;
      document.getElementById('graph-zero-notice').hidden = graph.links.length !== 0;
    }
    function setView(next, pushHistory) {
      view = next;
      document.body.classList.toggle('graph-triage-mode', next === 'triage');
      document.querySelectorAll('[data-graph-view]').forEach(function (button) {
        button.setAttribute('aria-pressed', button.dataset.graphView === next ? 'true' : 'false');
      });
      document.getElementById('graph-triage-panel').hidden = next !== 'triage';
      controls.hidden = next === 'triage';
      if (next === 'relations') render();
      else announce('待连接笔记 ' + graph.nodes.filter(function (node) { return node.degree === 0; }).length + ' 篇');
      if (pushHistory !== false) writeUrl(true);
    }
    function showPrompt() {
      inspector.hidden = true; edgeEditor.hidden = true; prompt.hidden = false;
      explore.querySelectorAll('[data-explore="collapse"],[data-explore="expand"]').forEach(function (button) { button.disabled = true; });
    }
    function showNode(node, pushHistory) {
      if (!node) return;
      selectedNodeId = node.id; selectedEdgeId = '';
      explore.querySelectorAll('[data-explore="collapse"],[data-explore="expand"]').forEach(function (button) { button.disabled = false; });
      prompt.hidden = true; edgeEditor.hidden = true; inspector.hidden = false;
      document.getElementById('graph-selected-title').textContent = node.name;
      document.getElementById('graph-selected-meta').textContent = (node.group || '未分类') + ' · ' + node.degree + ' 条关系';
      document.getElementById('graph-selected-description').textContent = node.description || '暂无摘要';
      var tags = document.getElementById('graph-selected-tags'); tags.textContent = '';
      (node.tags || []).forEach(function (tag) {var item = document.createElement('span'); item.textContent = '#' + tag; tags.appendChild(item);});
      var facts = document.getElementById('graph-selected-facts'); facts.textContent = '';
      [['状态', ({published:'已发布', draft:'草稿', private:'私有'})[node.status] || node.status || '未标记'], ['来源', node.id]].forEach(function (item) {
        var key = document.createElement('dt'), value = document.createElement('dd');
        key.textContent = item[0]; value.textContent = item[1]; facts.append(key, value);
      });
      document.getElementById('graph-open-link').href = node.url;
      var relatedLink = document.getElementById('graph-related-link');
      if (relatedLink) {
        relatedLink.href = 'related.html?source=' + encodeURIComponent(node.id);
        relatedLink.hidden = false;
      }
      var neighbours = document.getElementById('graph-neighbours'); neighbours.textContent = '';
      [['上游', graph.links.filter(function (edge) { return edgeMath.incoming(edge, node.id); })],
       ['下游', graph.links.filter(function (edge) { return edgeMath.outgoing(edge, node.id); })]].forEach(function (group) {
        var section = document.createElement('section'), heading = document.createElement('h4');
        heading.textContent = group[0] + ' · ' + group[1].length; section.appendChild(heading);
        group[1].forEach(function (edge) {
          var other = nodeById(edgeSource(edge) === node.id ? edgeTarget(edge) : edgeSource(edge));
          var row = document.createElement('button'); row.type = 'button';
          row.textContent = (other ? other.name : '') + ' · ' + (edge.label || edge.type);
          row.addEventListener('click', function () { showEdge(edge); });
          section.appendChild(row);
        });
        neighbours.appendChild(section);
      });
      var add = document.createElement('button'); add.type = 'button'; add.textContent = '新增关系';
      add.addEventListener('click', function () { showEdge(null, node.id); });
      neighbours.appendChild(add);
      render();
      if (pushHistory !== false) writeUrl(true);
    }
    function showEdge(edge, newOwner) {
      if (!edge && !newOwner) return;
      selectedEdgeId = edge ? edge.id : '';
      prompt.hidden = true; inspector.hidden = true; edgeEditor.hidden = false;
      var owner = edge ? edge.ownerId : newOwner;
      var target = edge ? edge.targetId : '';
      edgeEditor.textContent = '';
      var title = document.createElement('h2'); title.textContent = edge ? '关系详情' : '新增关系';
      var form = document.createElement('form');
      function field(label, element) { var wrapper = document.createElement('label'); wrapper.textContent = label; wrapper.appendChild(element); form.appendChild(wrapper); return element; }
      var sourceText = document.createElement('p'); sourceText.textContent = '来源：' + ((nodeById(owner) || {}).name || owner);
      form.appendChild(sourceText);
      var targetSelect = document.createElement('select');
      graph.nodes.filter(function (node) { return node.id !== owner; }).forEach(function (node) {
        var option = document.createElement('option'); option.value = node.id; option.textContent = node.name;
        targetSelect.appendChild(option);
      });
      targetSelect.value = target || (targetSelect.options[0] && targetSelect.options[0].value);
      if (edge) targetSelect.disabled = true;
      field('目标笔记', targetSelect);
      var typeInput = field('关系类型', document.createElement('input'));
      typeInput.required = true; typeInput.maxLength = 48; typeInput.value = edge ? edge.type : '相关';
      var labelInput = field('关系标签', document.createElement('input'));
      labelInput.required = true; labelInput.maxLength = 96; labelInput.value = edge ? edge.label : '相关';
      var directionSelect = document.createElement('select');
      [['forward', '来源 → 目标'], ['reverse', '目标 → 来源'], ['both', '双向']].forEach(function (item) {
        var option = document.createElement('option'); option.value = item[0]; option.textContent = item[1]; directionSelect.appendChild(option);
      });
      directionSelect.value = edge ? edge.direction : 'forward'; field('方向', directionSelect);
      var weightInput = field('权重（0.2–5）', document.createElement('input'));
      weightInput.type = 'number'; weightInput.min = '.2'; weightInput.max = '5'; weightInput.step = '.1';
      weightInput.value = edge ? edge.weight : 1;
      var styleSelect = document.createElement('select');
      [['solid', '实线'], ['dashed', '虚线'], ['dotted', '点线']].forEach(function (item) {
        var option = document.createElement('option'); option.value = item[0]; option.textContent = item[1]; styleSelect.appendChild(option);
      });
      styleSelect.value = edge ? edge.style : 'solid'; field('线条', styleSelect);
      var message = document.createElement('p'); message.className = 'graph-edge-message'; message.setAttribute('role', 'status');
      var actions = document.createElement('div'); actions.className = 'graph-edge-actions';
      var close = document.createElement('button'); close.type = 'button'; close.textContent = '返回图谱';
      close.addEventListener('click', function () { if (selectedNodeId) showNode(nodeById(selectedNodeId)); else showPrompt(); });
      actions.appendChild(close);
      if (window.orgMuseumGraphApi) {
        var save = document.createElement('button'); save.type = 'submit'; save.textContent = '保存关系'; actions.appendChild(save);
        if (edge) {
          var remove = document.createElement('button'); remove.type = 'button'; remove.textContent = '从图谱删除';
          remove.addEventListener('click', function () {
            if (remove.dataset.confirm === 'true') { persist('delete'); return; }
            remove.dataset.confirm = 'true'; remove.textContent = '确认删除';
            message.textContent = '只删除图谱关系；正文中的原有链接会保留。';
            var cancel = document.createElement('button'); cancel.type = 'button'; cancel.textContent = '取消删除';
            cancel.addEventListener('click', function () {
              remove.dataset.confirm = 'false'; remove.textContent = '从图谱删除';
              cancel.remove(); message.textContent = '';
            });
            actions.insertBefore(cancel, remove);
          });
          actions.appendChild(remove);
        }
      } else {
        form.querySelectorAll('input,select').forEach(function (field) { field.disabled = true; });
        message.textContent = '静态导出可浏览；在 Emacs 运行 M-x org-museum-graph-open-live 后可编辑。';
      }
      form.append(actions, message); edgeEditor.append(title, form);
      function persist(action) {
        var targetId = targetSelect.value;
        if (!targetId) {message.textContent = '请先选择目标笔记'; return;}
        message.textContent = '正在保存…';
        api('page?pageId=' + encodeURIComponent(owner)).then(function (page) {
          return api('graph/edge', {action: action, ownerId: owner, targetId: targetId,
            expectedSha256: page.sha256, type: typeInput.value.trim(), label: labelInput.value.trim(),
            direction: directionSelect.value, weight: Number(weightInput.value), style: styleSelect.value});
        }).then(function (result) {
          selectedEdgeId = '';
          setGraph(result.graph);
          showNode(nodeById(owner));
          announce('关系已保存，图谱已同步');
        }).catch(function (error) { message.textContent = error.message || '保存失败'; });
      }
      form.addEventListener('submit', function (event) {event.preventDefault(); persist('upsert');});
      render();
    }
    function fit(instant) {
      if (!activeNodes.length) return;
      var w = canvas.clientWidth || 900, h = canvas.clientHeight || 700;
      if (dimension === '3d') {
        camera.zoom = 1;
        var projected = activeNodes.map(project);
        var xs = projected.map(function (p) { return p.x; });
        var ys = projected.map(function (p) { return p.y; });
        var minPX = Math.min.apply(null, xs), maxPX = Math.max.apply(null, xs);
        var minPY = Math.min.apply(null, ys), maxPY = Math.max.apply(null, ys);
        var spreadX = Math.max(1, maxPX - minPX);
        var spreadY = Math.max(1, maxPY - minPY);
        camera.zoom = Math.max(.2, Math.min(1.5,
          (w - 180) / spreadX,
          (h - 140) / spreadY));
        tick();
        return;
      }
      var xs = activeNodes.map(function (node) { return node.x || 0; });
      var ys = activeNodes.map(function (node) { return node.y || 0; });
      var minX = Math.min.apply(null, xs);
      var maxX = Math.max.apply(null, xs);
      var minY = Math.min.apply(null, ys);
      var maxY = Math.max.apply(null, ys);

      // True geometric center of all active nodes
      var centerX = (minX + maxX) / 2;
      var centerY = (minY + maxY) / 2;

      // Generous symmetrical safety margins: ensure node circles, labels (~90-120px) and glow halos
      // are never clipped by the canvas boundaries or UI chrome
      var marginX = 90;
      var marginY = 55;
      var bw = Math.max(maxX - minX + marginX * 2, 80);
      var bh = Math.max(maxY - minY + marginY * 2, 80);

      // Safe area padding from canvas edge
      var safePad = 32;
      var availableW = Math.max(120, w - safePad * 2);
      var availableH = Math.max(120, h - safePad * 2);

      var fitScale = Math.min(availableW / bw, availableH / bh);
      var scale = Math.max(0.12, Math.min(fitScale, 1.35));

      var visualCenterX = w / 2;
      var visualCenterY = h / 2;

      var tx = visualCenterX - centerX * scale;
      var ty = visualCenterY - centerY * scale;

      var transform = d3.zoomIdentity.translate(tx, ty).scale(scale);
      if (instant === true) svg.interrupt().call(zoom.transform, transform);
      else svg.transition().duration(280).call(zoom.transform, transform);
    }
    function scaleView(factor) {
      if (dimension === '3d') {
        camera.zoom = Math.max(.25, Math.min(4, camera.zoom * factor)); tick();
      } else svg.transition().duration(200).call(zoom.scaleBy, factor);
    }
    document.getElementById('btn-zoom-in').addEventListener('click', function () { scaleView(1.25); });
    document.getElementById('btn-zoom-out').addEventListener('click', function () { scaleView(.8); });
    document.getElementById('btn-reset').addEventListener('click', fit);
    document.getElementById('btn-layout').addEventListener('click', function () {
      applyLayout(layouts.next(layoutMode, Math.random));
    });
    explore.addEventListener('click', function (event) {
      var chosen = event.target.dataset.dimension;
      if (chosen) switchDimension(chosen);
    });
    svg.node().addEventListener('pointerdown', function (event) {
      if (dimension !== '3d') return;
      if (event.target !== svg.node() && (!event.target.classList || !event.target.classList.contains('graph-canvas-catcher'))) return;
      orbitStart = {x: event.clientX, y: event.clientY};
      svg.node().setPointerCapture(event.pointerId);
    });
    svg.node().addEventListener('pointermove', function (event) {
      if (!orbitStart || dimension !== '3d') return;
      camera.yaw += (event.clientX - orbitStart.x) * .006;
      camera.pitch = Math.max(-1.3, Math.min(1.3,
        camera.pitch + (event.clientY - orbitStart.y) * .006));
      orbitStart = {x: event.clientX, y: event.clientY};
      tick();
    });
    svg.node().addEventListener('pointerup', function () { orbitStart = null; });
    svg.node().addEventListener('pointercancel', function () { orbitStart = null; });
    svg.node().addEventListener('wheel', function (event) {
      if (dimension !== '3d') return;
      event.preventDefault(); scaleView(event.deltaY < 0 ? 1.15 : .87);
    }, {passive: false});
    document.getElementById('graph-zero-copy').addEventListener('click', function () {
      var first = graph.nodes[0];
      if (first) { setView('relations'); showNode(first); }
    });
    explore.addEventListener('click', function (event) {
      var action = event.target.dataset.explore;
      if (!action) return;
      if (action === 'collapse') focusDepth = 1;
      else if (action === 'expand') focusDepth = Number.isFinite(focusDepth) ? focusDepth + 1 : 1;
      else { focusDepth = Infinity; showIsolated = action === 'all'; }
      render(); fit();
    });
    document.querySelectorAll('[data-graph-view]').forEach(function (button) {
      button.addEventListener('click', function () { setView(button.dataset.graphView); });
    });
    document.getElementById('btn-clear-selection').addEventListener('click', function () {
      selectedNodeId = ''; selectedEdgeId = ''; focusDepth = Infinity; showPrompt(); render(); fit(); writeUrl(true);
    });
    relationFilter.addEventListener('change', function () { relation = relationFilter.value; render(); fit(); writeUrl(true); });
    if (search) {
      search.value = query;
      search.addEventListener('input', function () { query = search.value.trim().toLowerCase(); render(); fit(); writeUrl(false); });
    }
    document.addEventListener('keydown', function (event) {
      if (event.target && (/^(input|select|textarea)$/i.test(event.target.tagName) || event.target.isContentEditable)) return;
      if (event.key === '+' || event.key === '=') {
        event.preventDefault(); scaleView(1.25);
      } else if (event.key === '-' || event.key === '_') {
        event.preventDefault(); scaleView(0.8);
      } else if (event.key === '0') {
        event.preventDefault(); fit();
      } else if (event.key === 'Escape') {
        if (selectedNodeId || selectedEdgeId) {
          event.preventDefault();
          selectedNodeId = ''; selectedEdgeId = '';
          showPrompt(); render(); writeUrl(true);
        }
      }
    });
    svg.on('click', function (event) {
      if (event.target === svg.node() || (event.target && event.target.classList && event.target.classList.contains('graph-canvas-catcher'))) {
        selectedNodeId = ''; selectedEdgeId = ''; showPrompt(); render(); writeUrl(true);
      }
    });
    window.addEventListener('popstate', function () {
      var restored = new URLSearchParams(location.search);
      query = (restored.get('q') || '').trim().toLowerCase();
      category = restored.get('category') || '*'; relation = restored.get('relation') || '*';
      timeRange = restored.get('time') || 'all';
      selectedNodeId = restored.get('focus') || '';
      view = restored.get('view') === 'triage' ? 'triage' : 'relations';
      dimension = restored.get('dimension') === '3d' ? '3d' : '2d';
      if (layouts.modes.includes(restored.get('layout')) && layoutMode !== restored.get('layout')) {
        layoutMode = restored.get('layout'); positions.clear(); syncLayoutSettings();
      }
      window.orgMuseumGraphNetwork.dimension = dimension;
      updateDimensionControls();
      if (search) search.value = query;
      updateControls(); setView(view, false); render();
      if (selectedNodeId) showNode(nodeById(selectedNodeId), false); else showPrompt();
    });
    var resizeTimer;
    var lastCanvasWidth = canvas.clientWidth || 900;
    function resizeGraph() {
      clearTimeout(resizeTimer);
      autoFitPending = true;
      resizeTimer = setTimeout(function () {
        var width = canvas.clientWidth || 900;
        if (Math.abs(width - lastCanvasWidth) > Math.max(80, lastCanvasWidth * .2)) {
          positions = layouts.positions(visibleNodes(), graph.links, layoutMode,
            width, canvas.clientHeight || 700, layoutOptions);
        }
        lastCanvasWidth = width;
        render(); fit();
      }, 120);
    }
    if (window.ResizeObserver) {
      var resize = new ResizeObserver(resizeGraph); resize.observe(canvas);
    } else window.addEventListener('resize', resizeGraph);
    window.orgMuseumGraphNetwork.dimension = dimension;
    updateDimensionControls();
    setGraph(embedded); showPrompt();
    if (selectedNodeId) showNode(nodeById(selectedNodeId), false);
    if (view === 'triage') setView('triage', false);
    fit(true);
    setTimeout(fit, 500);
    if (window.orgMuseumGraphApi) {
      function refreshGraph() {
        return api('graph').then(function (result) { setGraph(result.graph); });
      }
      refreshGraph().catch(function (error) { announce(error.message); });
      window.addEventListener('focus', function () { refreshGraph().catch(function () {}); });
      document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'visible') refreshGraph().catch(function () {});
      });
      setInterval(function () {
        if (edgeEditor.hidden && document.visibilityState === 'visible')
          refreshGraph().catch(function () {});
      }, 8000);
    }
  }
})();
