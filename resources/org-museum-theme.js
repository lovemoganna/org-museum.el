(function () {
  "use strict";

  // Older Org HTML_HEAD settings may reference another version of this file.
  if (window.orgMuseumThemeBootstrapped) return;
  window.orgMuseumThemeBootstrapped = true;

  // Shared controls for article and dynamically inserted related-reading code.
  var codeSequence = 0;
  window.orgMuseumPrepareCodeBlock = function (pre, code, language) {
    if (pre.dataset.codeControlsReady === '1') return;
    pre.dataset.codeControlsReady = '1';
    if (!code) {
      code = document.createElement('code');
      code.innerHTML = pre.innerHTML;
      pre.replaceChildren(code);
    }
    if (!code.id) {
      do { code.id = 'museum-code-body-' + (++codeSequence); }
      while (document.getElementById(code.id) && document.getElementById(code.id) !== code);
    }
    pre.classList.add('org-museum-code-block', 'org-museum-code-collapsed');
    code.classList.add('org-museum-code');
    code.hidden = true;
    var label = document.createElement('span');
    label.className = 'code-lang-label';
    label.textContent = (language || 'code').toUpperCase();
    var toggle = document.createElement('button');
    toggle.type = 'button'; toggle.className = 'code-copy-btn code-toggle-btn';
    toggle.textContent = '展开';
    toggle.setAttribute('aria-label', '展开代码块');
    toggle.setAttribute('aria-expanded', 'false');
    toggle.setAttribute('aria-controls', code.id);
    toggle.onclick = function () {
      var expanded = code.hidden;
      code.hidden = !expanded;
      pre.classList.toggle('org-museum-code-expanded', expanded);
      pre.classList.toggle('org-museum-code-collapsed', !expanded);
      toggle.textContent = expanded ? '收起' : '展开';
      toggle.setAttribute('aria-label', expanded ? '收起代码块' : '展开代码块');
      toggle.setAttribute('aria-expanded', String(expanded));
    };
    var copy = document.createElement('button');
    copy.type = 'button'; copy.className = 'code-copy-btn'; copy.textContent = '复制';
    copy.setAttribute('aria-label', '复制代码');
    copy.setAttribute('aria-live', 'polite');
    copy.onclick = function () {
      // textContent preserves the authored text even while hidden or wrapped.
      var text = code.textContent;
      function feedback(ok) {
        copy.textContent = ok ? '已复制' : '复制失败';
        copy.setAttribute('aria-label', ok ? '已复制代码' : '复制失败，请重试');
        setTimeout(function () { copy.textContent = '复制'; copy.setAttribute('aria-label', '复制代码'); }, 2000);
      }
      function fallback() {
        var input = document.createElement('textarea');
        input.value = text; input.setAttribute('readonly', '');
        input.style.position = 'fixed'; input.style.left = '-9999px';
        document.body.appendChild(input); input.select();
        var ok = false;
        try { ok = document.execCommand('copy') === true; } catch (_) {}
        input.remove(); copy.focus(); feedback(ok);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { feedback(true); }, fallback);
      } else fallback();
    };
    pre.insertBefore(label, code);
    pre.insertBefore(toggle, code);
    pre.insertBefore(copy, code);
  };

  var key = "org-museum-theme";
  var systemScheme = typeof window.matchMedia === "function" ? window.matchMedia("(prefers-color-scheme: dark)") : null;

  // Keep a category's visual identity stable across pages, filters and themes.
  window.orgMuseumCategoryColor = function (label) {
    var normalized = String(label || "未分类").trim().toLowerCase();
    if (normalized === "ail") normalized = "ai";
    var hash = 2166136261;
    Array.from(normalized).forEach(function (character) {
      hash ^= character.codePointAt(0);
      hash = Math.imul(hash, 16777619);
    });
    return "var(--museum-category-" + ((hash >>> 0) % 7 + 1) + ")";
  };

  function isTheme(value) {
    return value === "light" || value === "dark" || value === "system";
  }

  function normalize(value) {
    return isTheme(value) ? value : "system";
  }

  function readThemeFromUrl() {
    try {
      var value = new URL(location.href).searchParams.get(key);
      return isTheme(value) ? value : null;
    } catch (_error) {
      return null;
    }
  }

  function readStoredTheme() {
    try {
      return normalize(localStorage.getItem(key));
    } catch (_error) {
      return "system";
    }
  }

  function updateControls(theme) {
    var light = theme === "light";
    var isSys = document.documentElement.dataset.themePreference === "system";
    document.querySelectorAll("[data-theme-toggle]").forEach(function (button) {
      button.setAttribute("aria-label", light ? "切换为深色主题" : "切换为浅色主题");
      button.setAttribute("aria-pressed", !isSys ? "true" : "false");
      if (button.classList && button.classList.toggle) button.classList.toggle("is-active", !isSys);
      var label = button.querySelector ? button.querySelector("[data-theme-label]") : null;
      var icon = button.querySelector ? button.querySelector("[data-theme-icon]") : null;
      if (label) label.textContent = light ? "深色" : "浅色";
      if (icon) icon.dataset.themeIcon = light ? "moon" : "sun";
    });
    document.querySelectorAll("[data-theme-system]").forEach(function (button) {
      button.setAttribute("aria-pressed", isSys ? "true" : "false");
      if (button.classList && button.classList.toggle) button.classList.toggle("is-active", isSys);
    });
    document.querySelectorAll("[data-theme-current]").forEach(function (label) {
      label.textContent = (isSys ? "系统 · " : "") + (light ? "浅色" : "深色");
    });
  }

  function currentTheme() {
    return normalize(document.documentElement.dataset.themePreference);
  }

  function syncCurrentThemeUrl(theme) {
    try {
      if (typeof location !== "undefined" && location.protocol === "file:") return;
      var url = new URL(location.href);
      if (!/\.html$/i.test(url.pathname) || typeof history === "undefined" ||
          typeof history.replaceState !== "function") return;
      url.searchParams.set(key, theme);
      history.replaceState(history.state, "", url.href);
    } catch (_error) {}
  }

  function applyTheme(value, persist) {
    var preference = normalize(value);
    var theme = preference === "system" ? (systemScheme && systemScheme.matches ? "dark" : "light") : preference;
    document.documentElement.dataset.themePreference = preference;
    document.documentElement.dataset.theme = theme;
    document.documentElement.style.colorScheme = theme;
    var meta = document.querySelector('meta[name="color-scheme"]');
    if (meta) meta.setAttribute("content", theme);
    updateControls(theme);
    if (persist) {
      try {
        localStorage.setItem(key, preference);
      } catch (_error) {}
      syncCurrentThemeUrl(preference);
    }
  }

  var themeFromUrl = readThemeFromUrl();
  applyTheme(themeFromUrl || readStoredTheme(), Boolean(themeFromUrl));

  var READING_WIDTHS = ["980", "1024", "1180", "1320"];
  var DEFAULT_READING_WIDTH = "1320";
  function normalizeReadingWidth(value) {
    if (value === "wide") return "980";
    return READING_WIDTHS.indexOf(value) >= 0 ? value : DEFAULT_READING_WIDTH;
  }

  function applyReadingPreferences() {
    try {
      if (typeof document === "undefined" || !document.documentElement) return;
      var size = localStorage.getItem("org-museum-reading-size") || "md";
      var width = normalizeReadingWidth(localStorage.getItem("org-museum-reading-width"));
      var font = localStorage.getItem("org-museum-reading-font") || "sans";
      var tone = localStorage.getItem("org-museum-reading-tone") || "default";
      var line = localStorage.getItem("org-museum-reading-line") || "standard";
      var zen = localStorage.getItem("org-museum-zen-mode") === "true";
      document.documentElement.dataset.readingSize = size;
      document.documentElement.dataset.readingWidth = width;
      document.documentElement.dataset.readingFont = font;
      document.documentElement.dataset.readingTone = tone;
      document.documentElement.dataset.readingLine = line;
      document.documentElement.dataset.zenMode = zen ? "true" : "false";
    } catch (_) {}
  }

  function applyLearningPreferences() {
    try {
      if (typeof document === "undefined" || !document.documentElement) return;
      var beginner = localStorage.getItem("org-museum-beginner-mode") !== "false";
      var hover = localStorage.getItem("org-museum-hover-preview") !== "false";
      var lineno = localStorage.getItem("org-museum-code-lineno") !== "false";
      var recall = localStorage.getItem("org-museum-active-recall") === "true";
      document.documentElement.dataset.beginnerMode = beginner ? "true" : "false";
      document.documentElement.dataset.hoverPreview = hover ? "true" : "false";
      document.documentElement.dataset.codeLineno = lineno ? "true" : "false";
      document.documentElement.dataset.activeRecall = recall ? "true" : "false";
    } catch (_) {}
  }

  applyReadingPreferences();
  applyLearningPreferences();

  function syncZenMode() {
    var active = document.documentElement.dataset.zenMode === "true";
    if (document.body && document.body.dataset && document.body.dataset.pageKind === "article")
      document.body.classList.toggle("zen-mode", active);
    document.querySelectorAll("[data-zen-mode-toggle]").forEach(function (control) { control.checked = active; });
    document.querySelectorAll("[data-reading-zen]").forEach(function (button) {
      button.setAttribute("aria-pressed", String(active));
      button.textContent = active ? "退出专注" : "专注阅读";
    });
  }
  window.orgMuseumSetZen = function (active) {
    document.documentElement.dataset.zenMode = active ? "true" : "false";
    try { localStorage.setItem("org-museum-zen-mode", String(Boolean(active))); } catch (_) {}
    syncZenMode();
  };

  function themeUrl(href) {
    try {
      var url = new URL(href, location.href);
      if (!/\.html$/i.test(url.pathname) || url.protocol !== location.protocol) return href;
      if (url.protocol !== "file:" && url.origin !== location.origin) return href;
      url.searchParams.set(key, currentTheme());
      var root = siteRoot();
      if (root && url.pathname.startsWith(root.pathname) && !viewName(url, root)) {
        var current = new URL(location.href);
        var from = viewName(current, root) ? cleanView(current, root) : returnView(root);
        if (from) url.searchParams.set("museum-from", from.pathname.slice(root.pathname.length) + from.search + from.hash);
      }
      return url.href;
    } catch (_error) {
      return href;
    }
  }

  window.orgMuseumThemeUrl = themeUrl;

  // Carry the collection context in the URL, including for local file browsing.
  // Accept only the four views in this export, never an arbitrary return URL.
  function siteRoot() {
    var home = document.querySelector(".museum-wordmark[href]");
    return home ? new URL(".", new URL(home.getAttribute("href"), location.href)) : null;
  }
  function viewName(url, root) {
    if (url.origin !== root.origin || url.protocol !== root.protocol) return "";
    var name = url.pathname.slice(root.pathname.length);
    return url.pathname.startsWith(root.pathname) &&
      /^(index|graph|timeline|related)\.html$/.test(name) ? name : "";
  }
  function cleanView(url, root) {
    if (!viewName(url, root)) return null;
    var clean = new URL(url.pathname, root);
    ["q", "category", "tag", "status", "project", "type", "from", "to", "sort",
      "focus", "view", "source", "target", "mode", "time", "relation",
      "dimension", "layout", "grain"].forEach(function (name) {
      if (url.searchParams.has(name)) clean.searchParams.set(name, url.searchParams.get(name));
    });
    clean.hash = url.hash;
    return clean;
  }
  function returnView(root) {
    try {
      var value = new URL(location.href).searchParams.get("museum-from");
      return value ? cleanView(new URL(value, root), root) : null;
    } catch (_error) { return null; }
  }
  function bindReturnLink() {
    var link = document.querySelector("[data-reading-return]");
    var root = siteRoot();
    var from = root && returnView(root);
    if (!from) return;
    var name = viewName(from, root);
    if (link) {
      link.href = themeUrl(from.href);
      link.textContent = name === "index.html" ?
        (from.search ? "← 返回筛选结果" : "← 全部笔记") :
        {"graph.html": "← 返回图谱", "timeline.html": "← 返回时间线", "related.html": "← 返回关联阅读"}[name];
    }
    var topIndex = document.querySelector(".museum-nav-all");
    if (topIndex && name === "index.html" && from.search && document.body.dataset.pageKind === "article") {
      topIndex.href = themeUrl(from.href);
    }
  }

  function localCurationSession() {
    var localHost = location.hostname === "127.0.0.1" || location.hostname === "localhost";
    return { available: location.protocol === "file:" || localHost, mode: "protocol" };
  }

  var curationSession = localCurationSession();

  function openRelationCuration(config) {
    if (!curationSession.available) return;
    var mode = window.orgMuseumCuration && window.orgMuseumCuration.mode === "loopback" ? "loopback" : "protocol";
    var guidance = mode === "loopback"
      ? "先在浏览器中生成写入前差异；核对后再次确认，才会通过本地认证会话写入。"
      : "请求只会发送到 Emacs 审核；差异与最终确认将在 Emacs 中完成，浏览器不会预览或写入笔记。";
    var submitLabel = mode === "loopback" ? "预览差异" : "发送到 Emacs 审核";
    var targets = (config.targets || []).filter(function (item) { return item.id !== config.sourceId; });
    var dialog = document.createElement("dialog");
    dialog.className = "museum-curation-dialog";
    dialog.setAttribute("aria-labelledby", "museum-curation-title");
    dialog.innerHTML =
      '<form method="dialog" class="museum-curation-form">' +
      '<header><div><small>SAFE CURATION</small><h2 id="museum-curation-title">建立真实关系</h2></div>' +
      '<button value="cancel" aria-label="关闭策展对话框">关闭</button></header>' +
      '<p class="museum-curation-source"></p>' +
      '<p class="museum-curation-guidance"></p>' +
      '<label>目标笔记<select name="target" required></select></label>' +
      '<label>关系类型<select name="type"><option>属于</option><option selected>相关</option>' +
      '<option>前置依赖</option><option>启发影响</option><option value="custom">自定义</option></select></label>' +
      '<label class="museum-curation-custom" hidden>自定义关系<input name="custom" maxlength="32"></label>' +
      '<section class="museum-curation-preview" hidden><strong>写入前差异</strong>' +
      '<div><pre data-before></pre><pre data-after></pre></div></section>' +
      '<p class="museum-curation-status" role="status" aria-live="polite"></p>' +
      '<footer><button value="cancel">取消</button><button type="submit" value="default" class="is-primary">' + submitLabel + '</button></footer>' +
      '</form>';
    var form = dialog.querySelector("form");
    var targetSelect = form.elements.target;
    var typeSelect = form.elements.type;
    var customLabel = dialog.querySelector(".museum-curation-custom");
    var status = dialog.querySelector(".museum-curation-status");
    var submit = dialog.querySelector('button[type="submit"]');
    var transaction = null;
    dialog.querySelector(".museum-curation-source").textContent = "源笔记：" + config.sourceTitle;
    dialog.querySelector(".museum-curation-guidance").textContent = guidance;
    targets.forEach(function (target) {
      var option = document.createElement("option");
      option.value = target.id; option.textContent = target.title + " · " + (target.category || "未分类");
      targetSelect.appendChild(option);
    });
    typeSelect.addEventListener("change", function () {
      customLabel.hidden = typeSelect.value !== "custom";
      if (!customLabel.hidden) form.elements.custom.focus();
    });
    dialog.addEventListener("close", function () { dialog.remove(); });
    form.addEventListener("submit", function (event) {
      if (event.submitter && event.submitter.value === "cancel") return;
      event.preventDefault();
      var relationType = typeSelect.value === "custom" ? form.elements.custom.value.trim() : typeSelect.value;
      if (!targetSelect.value || !relationType) { status.textContent = "请选择目标并填写关系类型。"; return; }
      if (mode === "protocol") {
        var query = new URLSearchParams({ pageId: config.sourceId, action: "add-relation",
          targetId: targetSelect.value, type: relationType });
        location.href = "org-protocol://museum-curate?" + query.toString();
        dialog.close(); return;
      }
      if (typeof window.orgMuseumCurationSubmit !== "function") {
        status.textContent = "本地认证会话未就绪，请重新从 Emacs 启动策展服务。";
        return;
      }
      submit.disabled = true; status.textContent = transaction ? "正在安全写入…" : "正在生成差异…";
      window.orgMuseumCurationSubmit(config, {
        action: "add", targetId: targetSelect.value, type: relationType
      }, transaction).then(function (result) {
        if (transaction) {
          status.textContent = "关系已写入，索引与导出已更新。"; submit.hidden = true; return;
        }
        transaction = result;
        dialog.querySelector("[data-before]").textContent = result.before;
        dialog.querySelector("[data-after]").textContent = result.after;
        dialog.querySelector(".museum-curation-preview").hidden = false;
        targetSelect.disabled = true; typeSelect.disabled = true; form.elements.custom.disabled = true;
        submit.textContent = "确认写入"; submit.disabled = false; status.textContent = "请核对差异后再次确认。";
      }).catch(function (error) { status.textContent = error.message; submit.disabled = false; });
    });
    document.body.appendChild(dialog);
    if (typeof dialog.showModal === "function") dialog.showModal(); else dialog.setAttribute("open", "");
  }

  window.orgMuseumCuration = {
    available: curationSession.available,
    mode: curationSession.mode,
    openRelation: openRelationCuration
  };

  function carryThemeToLocalPage(event) {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey ||
        event.ctrlKey || event.shiftKey || event.altKey) return;
    var link = event.target.closest && event.target.closest("a[href]");
    if (!link || link.hasAttribute("download") || link.target) return;
    var rawHref = link.getAttribute("href");
    if (!rawHref || rawHref.charAt(0) === "#") return;
    link.href = themeUrl(link.href);
  }

  function bindSettingsTabs(menu) {
    var tabs = menu.querySelectorAll("[data-settings-tab]");
    var panels = menu.querySelectorAll("[data-settings-panel]");
    if (!tabs.length || !panels.length) return;

    function selectTab(tabName) {
      if (!Array.from(tabs).some(function (btn) { return btn.dataset.settingsTab === tabName; })) return;
      tabs.forEach(function (btn) {
        var active = btn.dataset.settingsTab === tabName;
        btn.classList.toggle("is-active", active);
        btn.setAttribute("aria-selected", active ? "true" : "false");
        btn.tabIndex = active ? 0 : -1;
      });
      panels.forEach(function (panel) {
        var active = panel.dataset.settingsPanel === tabName;
        panel.hidden = !active;
      });
      try { localStorage.setItem("org-museum-settings-tab", tabName); } catch (_) {}
    }

    tabs.forEach(function (btn) {
      btn.addEventListener("click", function (e) {
        e.preventDefault();
        selectTab(btn.dataset.settingsTab);
      });
      btn.addEventListener("keydown", function (e) {
        if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) return;
        e.preventDefault();
        var items = Array.from(tabs), index = items.indexOf(btn);
        var next = e.key === "Home" ? 0 : e.key === "End" ? items.length - 1 :
          (index + (e.key === "ArrowRight" ? 1 : -1) + items.length) % items.length;
        selectTab(items[next].dataset.settingsTab);
        items[next].focus();
      });
    });

    var initial = Array.from(tabs).find(function (btn) { return btn.getAttribute("aria-selected") === "true"; }) || tabs[0];
    try {
      var savedTab = localStorage.getItem("org-museum-settings-tab");
      initial = Array.from(tabs).find(function (btn) { return btn.dataset.settingsTab === savedTab; }) || initial;
    } catch (_) {}
    selectTab(initial.dataset.settingsTab);
  }

  function bindGlobalAiSettings(menu) {
    var config = menu.querySelector("form[data-browser-config]");
    if (!config || config.dataset.boundGlobal) return;
    config.dataset.boundGlobal = "true";

    var connection = menu.querySelector("[data-browser-connection]");
    var statusBox = menu.querySelector(".museum-settings-status-box");
    var datalist = menu.querySelector("#museum-browser-model-list");
    var modelSelect = menu.querySelector("[data-browser-model-select]");
    var cycleBtn = menu.querySelector("[data-browser-cycle-model]");
    var loadBtn = menu.querySelector("[data-browser-load]");
    var modelsBtn = menu.querySelector("[data-browser-models]");
    var cancelBtn = menu.querySelector("[data-browser-cancel-load]");
    var listing = null, loading = null;
    if (config.elements.model) config.elements.model.required = false;

    function updateStatus(state, msg) {
      if (statusBox) statusBox.dataset.state = state;
      if (connection) connection.textContent = msg;
    }

    function getAvailableModels() {
      var cached = [];
      try { cached = JSON.parse(localStorage.getItem("org-museum-browser-models-list") || "[]"); } catch (_) {}
      if (Array.isArray(cached) && cached.length) return cached;
      if (modelSelect && modelSelect.options) {
        var opts = Array.from(modelSelect.options).map(function (o) { return o.value; }).filter(Boolean);
        if (opts.length) return opts;
      }
      if (datalist && datalist.options) {
        var dOpts = Array.from(datalist.options).map(function (o) { return o.value; }).filter(Boolean);
        if (dOpts.length) return dOpts;
      }
      return [];
    }

    function populateModelOptions(models, currentVal) {
      if (!Array.isArray(models)) return;
      if (datalist) {
        datalist.replaceChildren();
        models.forEach(function (m) {
          var opt = document.createElement("option");
          opt.value = m;
          datalist.appendChild(opt);
        });
      }
      if (modelSelect) {
        modelSelect.replaceChildren();
        var placeholderOpt = document.createElement("option");
        placeholderOpt.value = "";
        placeholderOpt.textContent = models.length ? "选择模型…" : "(请先读取模型列表或手动输入)";
        modelSelect.appendChild(placeholderOpt);
        models.forEach(function (m) {
          var opt = document.createElement("option");
          opt.value = m;
          opt.textContent = m;
          modelSelect.appendChild(opt);
        });
        if (currentVal) {
          if (!models.includes(currentVal)) {
            var customOpt = document.createElement("option");
            customOpt.value = currentVal;
            customOpt.textContent = currentVal + " (当前设置)";
            modelSelect.appendChild(customOpt);
          }
          modelSelect.value = currentVal;
        }
      }
    }

    function selectModel(modelName) {
      if (config.elements.model && config.elements.model.value !== modelName) {
        config.elements.model.value = modelName;
      }
      if (modelSelect && modelSelect.value !== modelName) {
        var hasOpt = Array.from(modelSelect.options || []).some(function (o) { return o.value === modelName; });
        if (!hasOpt && modelName) {
          var opt = document.createElement("option");
          opt.value = modelName;
          opt.textContent = modelName;
          modelSelect.appendChild(opt);
        }
        modelSelect.value = modelName;
      }
      save();
      if (modelName) updateStatus("ready", "已就绪 · " + modelName);
      else updateStatus("idle", "未选择模型");
    }

    function cycleModel(direction) {
      var step = (typeof direction === "number") ? direction : 1;
      var models = getAvailableModels();
      if (!models.length) {
        updateStatus("loading", "正在获取模型列表以供切换…");
        return fetchModels().then(function () {
          var refreshed = getAvailableModels();
          if (refreshed.length) {
            selectModel(config.elements.model.value || refreshed[0]);
          }
        });
      }
      var current = (config.elements.model && config.elements.model.value.trim()) || (modelSelect && modelSelect.value) || "";
      var idx = models.indexOf(current);
      var nextIdx;
      if (idx === -1) {
        nextIdx = step >= 0 ? 0 : models.length - 1;
      } else {
        nextIdx = (idx + step + models.length) % models.length;
      }
      selectModel(models[nextIdx]);
    }

    try {
      var saved = JSON.parse(localStorage.getItem("org-museum-browser-model") || "{}");
      var cachedModels = [];
      try { cachedModels = JSON.parse(localStorage.getItem("org-museum-browser-models-list") || "[]"); } catch (_) {}
      ["provider", "endpoint", "model", "system"].forEach(function (name) {
        if (typeof saved[name] === "string" && config.elements[name]) {
          config.elements[name].value = saved[name];
        }
      });
      populateModelOptions(cachedModels, saved.model || (config.elements.model && config.elements.model.value));
      if (saved.model) {
        updateStatus("ready", "已就绪 · " + saved.model);
      }
    } catch (_) {}

    if (config.elements.endpoint && !config.elements.endpoint.value) {
      config.elements.endpoint.value = "http://127.0.0.1:1234/v1";
    }

    function read() {
      var modelVal = (config.elements.model && config.elements.model.value.trim()) ||
                     (modelSelect && modelSelect.value.trim()) || "";
      return {
        provider: (config.elements.provider && config.elements.provider.value) || "compatible",
        endpoint: (config.elements.endpoint && config.elements.endpoint.value.trim()) || "",
        model: modelVal,
        key: (config.elements.key && config.elements.key.value.trim()) || "",
        system: (config.elements.system && config.elements.system.value.trim()) || ""
      };
    }

    function save() {
      var val = read();
      var persist = { provider: val.provider, endpoint: val.endpoint, model: val.model, system: val.system };
      try {
        localStorage.setItem("org-museum-browser-model", JSON.stringify(persist));
        if (rememberKeyBox && rememberKeyBox.checked && val.key) {
          localStorage.setItem("org-museum-api-key", val.key);
        }
      } catch (_) {}
      try {
        var evt = new CustomEvent("org-museum-model-changed", { detail: val });
        if (typeof window !== "undefined" && typeof window.dispatchEvent === "function") {
          window.dispatchEvent(evt);
        } else if (typeof document !== "undefined" && typeof document.dispatchEvent === "function") {
          document.dispatchEvent(evt);
        }
      } catch (_) {}
    }

    config.addEventListener("input", save);
    config.addEventListener("change", save);

    if (modelSelect) {
      var onModelSelectChange = function () {
        selectModel(modelSelect.value);
      };
      modelSelect.addEventListener("change", onModelSelectChange);
      modelSelect.addEventListener("input", onModelSelectChange);
    }

    if (cycleBtn) {
      cycleBtn.addEventListener("click", function (e) {
        if (e && e.preventDefault) e.preventDefault();
        return cycleModel(1);
      });
    }

    if (config.elements.model) {
      var syncFromInput = function () {
        var val = config.elements.model.value.trim();
        if (modelSelect && modelSelect.value !== val) {
          var hasOpt = Array.from(modelSelect.options || []).some(function (o) { return o.value === val; });
          if (hasOpt) {
            modelSelect.value = val;
          } else if (val) {
            var opt = document.createElement("option");
            opt.value = val;
            opt.textContent = val + " (手动输入)";
            modelSelect.appendChild(opt);
            modelSelect.value = val;
          } else {
            modelSelect.value = "";
          }
        }
      };
      config.elements.model.addEventListener("input", syncFromInput);
      config.elements.model.addEventListener("change", syncFromInput);
    }

    var rememberKeyBox = menu.querySelector ? menu.querySelector("[data-remember-key]") : null;
    if (rememberKeyBox && config.elements.key) {
      try {
        var shouldRemember = localStorage.getItem("org-museum-remember-key") === "true";
        rememberKeyBox.checked = shouldRemember;
        if (shouldRemember && !config.elements.key.value) {
          var rememberedKey = localStorage.getItem("org-museum-api-key");
          if (rememberedKey) config.elements.key.value = rememberedKey;
        }
      } catch (_) {}

      rememberKeyBox.addEventListener("change", function () {
        try {
          if (rememberKeyBox.checked) {
            localStorage.setItem("org-museum-remember-key", "true");
            if (config.elements.key.value) localStorage.setItem("org-museum-api-key", config.elements.key.value);
          } else {
            localStorage.removeItem("org-museum-remember-key");
            localStorage.removeItem("org-museum-api-key");
          }
        } catch (_) {}
      });
    }

    var presetSelect = menu.querySelector ? menu.querySelector("[data-ai-preset-select]") : null;
    if (presetSelect) {
      presetSelect.addEventListener("change", function () {
        var val = presetSelect.value;
        if (!val) return;
        var presets = {
          lmstudio: { provider: "compatible", endpoint: "http://127.0.0.1:1234/v1", model: "qwen2.5-7b-instruct" },
          ollama: { provider: "ollama", endpoint: "http://127.0.0.1:11434", model: "qwen2.5:latest" },
          siliconflow: { provider: "compatible", endpoint: "https://api.siliconflow.cn/v1", model: "deepseek-ai/DeepSeek-V3" },
          openai: { provider: "compatible", endpoint: "https://api.openai.com/v1", model: "gpt-4o-mini" }
        };
        var preset = presets[val];
        if (preset) {
          if (config.elements.provider) config.elements.provider.value = preset.provider;
          if (config.elements.endpoint) config.elements.endpoint.value = preset.endpoint;
          if (config.elements.model) config.elements.model.value = preset.model;
          selectModel(preset.model);
          updateStatus("idle", "已载入预设配置 · 请点击加载并测试");
          save();
        }
      });
    }

    var keyToggleBtn = menu.querySelector ? menu.querySelector("[data-toggle-key-visibility]") : null;
    if (keyToggleBtn && config.elements.key) {
      keyToggleBtn.addEventListener("click", function (e) {
        if (e && e.preventDefault) e.preventDefault();
        var isPwd = config.elements.key.type === "password";
        config.elements.key.type = isPwd ? "text" : "password";
        keyToggleBtn.setAttribute("aria-label", isPwd ? "隐藏密钥" : "显示密钥");
        keyToggleBtn.textContent = isPwd ? "🔒" : "👁️";
      });
    }

    var promptBtns = menu.querySelectorAll ? menu.querySelectorAll("[data-prompt-preset]") : [];
    if (promptBtns && promptBtns.length && config.elements.system) {
      var promptTemplates = {
        beginner: "你是一位耐心、亲切的知识导师。依据提供的资料回答，尽量用通俗生动的比喻向初学者解释核心概念，分步骤引导理解。引用笔记标题，明确区分原文事实与延伸推断；资料不足时明确说明。使用中文。",
        socratic: "你是一位苏格拉底式启发导师。依据提供的资料，不直接给出最终结论，而是提出富有洞察力的问题，引导学习者主动思考并推导答案。引用笔记标题，在回答最后给出 1-2 道自测思考题。使用中文。",
        summary: "你是一位高效的知识管理专家。依据提供的资料，用精炼的结构化列表提炼笔记核心要点、前置依赖与后续行动建议。引用笔记标题，突出关键术语与脉络。使用中文。"
      };
      promptBtns.forEach(function (btn) {
        btn.addEventListener("click", function (e) {
          if (e && e.preventDefault) e.preventDefault();
          var tpl = promptTemplates[btn.dataset.promptPreset];
          if (tpl) {
            config.elements.system.value = tpl;
            promptBtns.forEach(function (b) {
              var isTarget = b === btn;
              b.classList.toggle("is-active", isTarget);
              b.setAttribute("aria-pressed", isTarget ? "true" : "false");
            });
            save();
            updateStatus("ready", "已切换提示词：" + btn.textContent.trim());
            try {
              var quests = JSON.parse(localStorage.getItem("org-museum-learning-quests") || "{}");
              if (!quests.ai_dialogue) {
                quests.ai_dialogue = true;
                localStorage.setItem("org-museum-learning-quests", JSON.stringify(quests));
                if (menu._updateQuestsUI) menu._updateQuestsUI();
              }
            } catch (_) {}
          }
        });
      });
    }

    var onGlobalModelChange = function (evt) {
      if (!evt || !evt.detail) return;
      var newModel = evt.detail.model || "";
      if (config.elements.model && config.elements.model.value !== newModel) {
        config.elements.model.value = newModel;
      }
      if (modelSelect && modelSelect.value !== newModel) {
        var hasOpt = Array.from(modelSelect.options || []).some(function (o) { return o.value === newModel; });
        if (!hasOpt && newModel) {
          var opt = document.createElement("option");
          opt.value = newModel;
          opt.textContent = newModel;
          modelSelect.appendChild(opt);
        }
        modelSelect.value = newModel;
      }
      if (newModel) updateStatus("ready", "已就绪 · " + newModel);
    };
    if (typeof window !== "undefined" && typeof window.addEventListener === "function") window.addEventListener("org-museum-model-changed", onGlobalModelChange);
    if (typeof document !== "undefined" && typeof document.addEventListener === "function") document.addEventListener("org-museum-model-changed", onGlobalModelChange);

    if (config.elements.provider) config.elements.provider.addEventListener("change", function () {
      if (listing) listing.abort();
      if (loading) loading.abort();
      config.elements.endpoint.value = config.elements.provider.value === "ollama" ? "http://127.0.0.1:11434" : "http://127.0.0.1:1234/v1";
      config.elements.model.value = "";
      config.elements.key.value = "";
      if (datalist) datalist.replaceChildren();
      if (modelSelect) {
        modelSelect.replaceChildren();
        var placeholderOpt = document.createElement("option");
        placeholderOpt.value = "";
        placeholderOpt.textContent = "(请先读取模型列表或手动输入)";
        modelSelect.appendChild(placeholderOpt);
        modelSelect.value = "";
      }
      try { localStorage.removeItem("org-museum-browser-models-list"); } catch (_) {}
      updateStatus("idle", "请读取此服务的模型列表。");
      save();
    });
    config.addEventListener("submit", function (e) {
      e.preventDefault();
      fetchModels();
    });

    async function fetchModels() {
      if (listing) return;
      var val = read();
      if (!val.endpoint) {
        updateStatus("error", "请先填写服务地址");
        return;
      }
      updateStatus("loading", "正在获取模型列表…");
      listing = new AbortController();
      var request = listing, timer = setTimeout(function () { request.abort(); }, 20000);
      if (modelsBtn) modelsBtn.disabled = true;
      try {
        var url, headers = {};
        if (val.provider === "ollama") {
          var base = val.endpoint.replace(/\/+$/, "").replace(/\/v1$/, "");
          url = base + "/api/tags";
        } else {
          var base = val.endpoint.replace(/\/+$/, "");
          url = (base.endsWith("/v1") ? base : base + "/v1") + "/models";
          if (val.key) headers["Authorization"] = "Bearer " + val.key;
        }
        var res = await fetch(url, { headers: headers, signal: request.signal });
        if (!res.ok) throw new Error("HTTP " + res.status + " " + res.statusText);
        var data = await res.json();
        var models = [];
        if (Array.isArray(data.models)) {
          models = data.models.map(function (m) { return m.name || m.model || m; });
        } else if (Array.isArray(data.data)) {
          models = data.data.map(function (m) { return m.id || m.name || m; });
        }
        if (models.length) {
          try {
            localStorage.setItem("org-museum-browser-models-list", JSON.stringify(models));
          } catch (_) {}
          var chosen = (config.elements.model && models.includes(config.elements.model.value)) ? config.elements.model.value : models[0];
          if (config.elements.model) config.elements.model.value = chosen;
          populateModelOptions(models, chosen);
          save();
          updateStatus("ready", "已获取 " + models.length + " 个模型");
        } else {
          updateStatus("idle", "未返回模型列表");
        }
      } catch (err) {
        updateStatus("error", err.name === "AbortError" ? "读取超时或已取消，请重试。" : "获取失败：" + err.message);
      } finally {
        clearTimeout(timer); listing = null;
        if (modelsBtn) modelsBtn.disabled = false;
      }
    }

    if (modelsBtn) {
      modelsBtn.addEventListener("click", function (e) {
        e.preventDefault();
        return fetchModels();
      });
    }

    if (loadBtn) {
      loadBtn.addEventListener("click", async function (e) {
        e.preventDefault();
        if (loading) return;
        var val = read();
        if (!val.endpoint) {
          updateStatus("error", "请先填写服务地址");
          return;
        }
        if (!val.model) {
          updateStatus("error", "请先选择或输入模型");
          return;
        }
        updateStatus("loading", "正在测试连接…");
        loading = new AbortController();
        var controller = loading, timer = setTimeout(function () { controller.abort(); }, 60000);
        loadBtn.disabled = true;
        if (cancelBtn) cancelBtn.hidden = false;
        try {
          var url, headers = { "Content-Type": "application/json" };
          var body;
          if (val.provider === "ollama") {
            var base = val.endpoint.replace(/\/+$/, "").replace(/\/v1$/, "");
            url = base + "/api/chat";
            body = JSON.stringify({ model: val.model, messages: [{ role: "user", content: "ping" }], stream: false });
          } else {
            var base = val.endpoint.replace(/\/+$/, "");
            url = (base.endsWith("/v1") ? base : base + "/v1") + "/chat/completions";
            if (val.key) headers["Authorization"] = "Bearer " + val.key;
            body = JSON.stringify({ model: val.model, messages: [{ role: "user", content: "ping" }], max_tokens: 5 });
          }
          var res = await fetch(url, { method: "POST", headers: headers, body: body, signal: controller.signal });
          if (!res.ok) throw new Error("HTTP " + res.status + " " + res.statusText);
          save();
          updateStatus("ready", "已就绪 · " + val.model);
        } catch (err) {
          var errMsg = err.message || "";
          if (err.name === "AbortError") {
            updateStatus("error", "加载超时或已取消");
          } else if (/Failed to fetch|NetworkError|ECONNREFUSED/i.test(errMsg)) {
            updateStatus("error", "连接失败：未检测到本地服务。请先启动 LM Studio/Ollama，并检查服务端口与跨域设置。");
          } else {
            updateStatus("error", "连接失败：" + errMsg);
          }
        } finally {
          clearTimeout(timer); loading = null;
          loadBtn.disabled = false;
          if (cancelBtn) cancelBtn.hidden = true;
        }
      });
    }

    var quickTestBtn = menu.querySelector ? menu.querySelector("[data-browser-quick-test]") : null;
    if (quickTestBtn) {
      quickTestBtn.addEventListener("click", async function (e) {
        if (e && e.preventDefault) e.preventDefault();
        var val = read();
        if (!val.endpoint || !val.model) {
          updateStatus("error", "请先填写服务地址并选择模型");
          return;
        }
        updateStatus("loading", "正在向助教发送测试问候…");
        try {
          var url, headers = { "Content-Type": "application/json" };
          var body;
          if (val.provider === "ollama") {
            var base = val.endpoint.replace(/\/+$/, "").replace(/\/v1$/, "");
            url = base + "/api/chat";
            body = JSON.stringify({ model: val.model, messages: [{ role: "user", content: "你好！请用一句话告诉我你的角色。" }], stream: false });
          } else {
            var base = val.endpoint.replace(/\/+$/, "");
            url = (base.endsWith("/v1") ? base : base + "/v1") + "/chat/completions";
            if (val.key) headers["Authorization"] = "Bearer " + val.key;
            body = JSON.stringify({ model: val.model, messages: [{ role: "user", content: "你好！请用一句话告诉我你的角色。" }], max_tokens: 50 });
          }
          var res = await fetch(url, { method: "POST", headers: headers, body: body });
          if (!res.ok) throw new Error("HTTP " + res.status + " " + res.statusText);
          var data = await res.json();
          var reply = (data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content) ||
                      (data.message && data.message.content) || "助教已成功联通！";
          updateStatus("ready", "助教回复：" + reply.slice(0, 36) + (reply.length > 36 ? "…" : ""));
          try {
            var quests = JSON.parse(localStorage.getItem("org-museum-learning-quests") || "{}");
            if (!quests.ai_dialogue) {
              quests.ai_dialogue = true;
              localStorage.setItem("org-museum-learning-quests", JSON.stringify(quests));
              if (menu._updateQuestsUI) menu._updateQuestsUI();
            }
          } catch (_) {}
        } catch (err) {
          var msg = err.message || "";
          if (/Failed to fetch|NetworkError|ECONNREFUSED/i.test(msg)) {
            updateStatus("error", "连接失败：未检测到本地服务。请先启动 LM Studio/Ollama，并检查服务端口与跨域设置。");
          } else {
            updateStatus("error", "连接失败：" + msg);
          }
        }
      });
    }
    if (cancelBtn) cancelBtn.addEventListener("click", function () { if (loading) loading.abort(); });
    window.addEventListener("pagehide", function () {
      if (listing) listing.abort();
      if (loading) loading.abort();
    });
  }

  function bindGlobalSearch() {
    var search = typeof document.getElementById === "function" ?
      document.getElementById("org-museum-global-search") :
      (typeof document.querySelector === "function" ? document.querySelector("#org-museum-global-search") : null);
    var kind = document.body && document.body.dataset && document.body.dataset.pageKind;
    if (search && (kind === "article" || kind === "ai" || kind === "related")) {
      search.addEventListener("keydown", function (event) {
        if (event.key === "Enter" && !event.isComposing && search.value.trim()) {
          var top = document.querySelector(".museum-topbar");
          var home = top ? top.getAttribute("data-home-href") : "index.html";
          var dest = (home || "index.html") + "?q=" + encodeURIComponent(search.value.trim()) + "#recent-updates";
          location.href = themeUrl(dest);
        }
      });
    }
    document.addEventListener("keydown", function (event) {
      if (event.defaultPrevented || event.isComposing || (document.activeElement && document.activeElement.isContentEditable)) return;
      if (typeof document.querySelector === "function" && document.querySelector("dialog[open], #image-lightbox-overlay.visible")) return;
      if (event.key === "/" && !event.metaKey && !event.ctrlKey && !event.altKey &&
          document.activeElement && !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)) {
        event.preventDefault();
        var drawerInput = (document.body && document.body.classList && document.body.classList.contains("museum-drawer-open") && typeof document.getElementById === "function") ?
          document.getElementById("org-museum-search-input") : null;
        var indexInput = typeof document.getElementById === "function" ? document.getElementById("org-museum-index-search") : null;
        var target = drawerInput || search || indexInput;
        if (target && typeof target.focus === "function") target.focus({ preventScroll: true });
      }
    });
  }

  function bindReadingSettings(menu) {
    if (menu && menu._readingSettingsBound) {
      if (menu._updateReadingPreview) menu._updateReadingPreview();
      return;
    }
    if (menu) menu._readingSettingsBound = true;

    var sizeBtns = menu.querySelectorAll("[data-reading-size]");
    var widthBtns = menu.querySelectorAll("[data-reading-width]");
    var fontBtns = menu.querySelectorAll("[data-reading-font]");
    var toneBtns = menu.querySelectorAll("[data-reading-tone]");
    var lineBtns = menu.querySelectorAll("[data-reading-line]");
    var sceneBtns = menu.querySelectorAll ? menu.querySelectorAll("[data-preset-scene]") : [];
    var previewMetrics = menu.querySelector ? menu.querySelector("[data-preview-metrics]") : null;
    var previewSample = menu.querySelector ? menu.querySelector("[data-preview-sample]") : null;

    function updateGroup(buttons, activeVal, attrName) {
      if (!buttons || !buttons.forEach) return;
      buttons.forEach(function (btn) {
        var active = btn.getAttribute(attrName) === activeVal;
        btn.classList.toggle("is-active", active);
        btn.setAttribute("aria-pressed", active ? "true" : "false");
      });
    }

    function updateSceneState(sz, w, f, t, l) {
      if (!sceneBtns || !sceneBtns.forEach) return;
      var activeScene = "";
      if (sz === "lg" && w === "980" && f === "serif" && t === "warm" && l === "relaxed") {
        activeScene = "eyecare";
      } else if (sz === "md" && w === "1320" && f === "sans" && t === "default" && l === "standard") {
        activeScene = "standard";
      } else if (sz === "sm" && w === "1180" && f === "sans" && t === "slate" && l === "compact") {
        activeScene = "dense";
      }
      sceneBtns.forEach(function (btn) {
        var match = btn.dataset.presetScene === activeScene;
        btn.classList.toggle("is-active", match);
        btn.setAttribute("aria-pressed", match ? "true" : "false");
      });
    }

    function updateReadingPreview() {
      syncZenMode();
      var doc = document.documentElement;
      var sz = (doc && doc.dataset.readingSize) || "md";
      var w = normalizeReadingWidth(doc && doc.dataset.readingWidth);
      var f = (doc && doc.dataset.readingFont) || "sans";
      var t = (doc && doc.dataset.readingTone) || "default";
      var l = (doc && doc.dataset.readingLine) || "standard";

      var sizeLabels = { sm: "精简 11.5px", md: "标准 12px", lg: "适度 13.5px", xl: "放大 15px" };
      var fontLabels = { sans: "现代黑体", serif: "人文宋体" };
      var toneLabels = { default: "默认基调", warm: "护眼暖杏", slate: "柔和冷灰" };
      var lineLabels = { compact: "紧凑 1.55", standard: "标准 1.8", relaxed: "宽松 2.15" };

      if (previewMetrics) {
        previewMetrics.textContent = (sizeLabels[sz] || sz) + " · " + (fontLabels[f] || f) + " · " + (lineLabels[l] || l) + " · " + (toneLabels[t] || t);
      }
      if (previewSample && previewSample.dataset) {
        previewSample.dataset.previewSize = sz;
        previewSample.dataset.previewFont = f;
        previewSample.dataset.previewLine = l;
        previewSample.dataset.previewTone = t;
      }

      updateGroup(sizeBtns, sz, "data-reading-size");
      updateGroup(widthBtns, w, "data-reading-width");
      updateGroup(fontBtns, f, "data-reading-font");
      updateGroup(toneBtns, t, "data-reading-tone");
      updateGroup(lineBtns, l, "data-reading-line");
      updateSceneState(sz, w, f, t, l);
    }

    if (menu) menu._updateReadingPreview = updateReadingPreview;
    updateReadingPreview();

    if (sceneBtns && sceneBtns.forEach) {
      sceneBtns.forEach(function (btn) {
        btn.addEventListener("click", function () {
          var scene = btn.dataset.presetScene;
          var cfg = {
            eyecare: { size: "lg", width: "980", font: "serif", tone: "warm", line: "relaxed" },
            standard: { size: "md", width: "1320", font: "sans", tone: "default", line: "standard" },
            dense: { size: "sm", width: "1180", font: "sans", tone: "slate", line: "compact" }
          }[scene];
          if (!cfg) return;
          var doc = document.documentElement;
          if (doc) {
            doc.dataset.readingSize = cfg.size;
            doc.dataset.readingWidth = cfg.width;
            doc.dataset.readingFont = cfg.font;
            doc.dataset.readingTone = cfg.tone;
            doc.dataset.readingLine = cfg.line;
          }
          try {
            localStorage.setItem("org-museum-reading-size", cfg.size);
            localStorage.setItem("org-museum-reading-width", cfg.width);
            localStorage.setItem("org-museum-reading-font", cfg.font);
            localStorage.setItem("org-museum-reading-tone", cfg.tone);
            localStorage.setItem("org-museum-reading-line", cfg.line);
          } catch (_) {}
          updateReadingPreview();
        });
      });
    }

    sizeBtns.forEach(function (btn) {
      btn.addEventListener("click", function () {
        var val = btn.dataset.readingSize;
        if (document.documentElement) document.documentElement.dataset.readingSize = val;
        try { localStorage.setItem("org-museum-reading-size", val); } catch (_) {}
        updateReadingPreview();
      });
    });

    widthBtns.forEach(function (btn) {
      btn.addEventListener("click", function () {
        var val = btn.dataset.readingWidth;
        if (document.documentElement) document.documentElement.dataset.readingWidth = val;
        try { localStorage.setItem("org-museum-reading-width", val); } catch (_) {}
        updateReadingPreview();
      });
    });

    fontBtns.forEach(function (btn) {
      btn.addEventListener("click", function () {
        var val = btn.dataset.readingFont;
        if (document.documentElement) document.documentElement.dataset.readingFont = val;
        try { localStorage.setItem("org-museum-reading-font", val); } catch (_) {}
        updateReadingPreview();
      });
    });

    if (toneBtns && toneBtns.forEach) {
      toneBtns.forEach(function (btn) {
        btn.addEventListener("click", function () {
          var val = btn.dataset.readingTone;
          if (document.documentElement) document.documentElement.dataset.readingTone = val;
          try { localStorage.setItem("org-museum-reading-tone", val); } catch (_) {}
          updateReadingPreview();
        });
      });
    }

    if (lineBtns && lineBtns.forEach) {
      lineBtns.forEach(function (btn) {
        btn.addEventListener("click", function () {
          var val = btn.dataset.readingLine;
          if (document.documentElement) document.documentElement.dataset.readingLine = val;
          try { localStorage.setItem("org-museum-reading-line", val); } catch (_) {}
          updateReadingPreview();
        });
      });
    }

    var zenToggle = menu.querySelector ? menu.querySelector("[data-zen-mode-toggle]") : null;
    if (zenToggle) {
      zenToggle.checked = document.documentElement && document.documentElement.dataset.zenMode === "true";
      zenToggle.addEventListener("change", function () {
        window.orgMuseumSetZen(zenToggle.checked);
      });
    }
  }

  function bindLearningSettings(menu) {
    if (menu._learningSettingsBound) {
      menu._updateLearningSettings();
      return;
    }
    menu._learningSettingsBound = true;
    var preferences = [
      ["beginner-mode", "beginnerMode"], ["hover-preview", "hoverPreview"],
      ["code-lineno", "codeLineno"], ["active-recall", "activeRecall"]
    ];
    function updateQuests() {
      var quests = {};
      try { quests = JSON.parse(localStorage.getItem("org-museum-learning-quests") || "{}") || {}; } catch (_) {}
      var completed = 0, boxes = menu.querySelectorAll("[data-quest-checkbox]");
      boxes.forEach(function (box) {
        box.checked = quests[box.dataset.questCheckbox] === true;
        if (box.checked) completed++;
      });
      var progress = menu.querySelector("[data-quest-progress-text]");
      if (progress) progress.textContent = "已完成 " + completed + " / " + boxes.length + " 项";
    }
    function update() {
      preferences.forEach(function (entry) {
        var control = menu.querySelector("[data-" + entry[0] + "-toggle]");
        if (control) control.checked = document.documentElement.dataset[entry[1]] === "true";
      });
      updateQuests();
      syncActiveRecallNotice();
    }
    menu._updateLearningSettings = update;
    menu._updateQuestsUI = updateQuests;
    preferences.forEach(function (entry) {
      var control = menu.querySelector("[data-" + entry[0] + "-toggle]");
      if (!control) return;
      control.addEventListener("change", function () {
        var value = control.checked ? "true" : "false";
        document.documentElement.dataset[entry[1]] = value;
        try { localStorage.setItem("org-museum-" + entry[0], value); } catch (_) {}
        if (entry[1] === "hoverPreview" && !control.checked) {
          var card = document.getElementById("museum-hover-card");
          if (card) card.hidden = true;
        }
        syncActiveRecallNotice();
        if (typeof document.dispatchEvent === "function" && typeof CustomEvent === "function")
          document.dispatchEvent(new CustomEvent("museum:learning-change"));
      });
    });
    menu.querySelectorAll("[data-quest-checkbox]").forEach(function (box) {
      box.addEventListener("change", function () {
        try {
          var quests = JSON.parse(localStorage.getItem("org-museum-learning-quests") || "{}") || {};
          quests[box.dataset.questCheckbox] = box.checked;
          localStorage.setItem("org-museum-learning-quests", JSON.stringify(quests));
        } catch (_) {}
        updateQuests();
      });
    });
    var restore = menu.querySelector("[data-restore-guides]");
    if (restore) restore.addEventListener("click", function () {
      ["", "index-", "graph-", "timeline-", "related-", "ai-", "article-"].forEach(function (prefix) {
        try { localStorage.removeItem("org-museum-" + prefix + "guide-dismissed"); } catch (_) {}
      });
      document.querySelectorAll(".museum-study-guide").forEach(function (tip) { tip.hidden = false; });
      restore.textContent = "已恢复新手引导";
    });
    update();
  }

  function bindDataSettings(menu) {
    var countEl = menu.querySelector("[data-storage-count]");
    var sizeEl = menu.querySelector("[data-storage-size]");
    var progressEl = menu.querySelector ? menu.querySelector("[data-storage-progress]") : null;
    var keyStatusEl = menu.querySelector ? menu.querySelector("[data-storage-key-status]") : null;
    var copyBackupBtn = menu.querySelector ? menu.querySelector("[data-copy-backup]") : null;
    var resetAppBtn = menu.querySelector ? menu.querySelector("[data-reset-appearance-only]") : null;
    var resetBtn = menu.querySelector("[data-reset-all-settings]");

    function updateMetrics() {
      try {
        var count = 0, totalBytes = 0;
        if (typeof localStorage !== "undefined") {
          for (var i = 0; i < localStorage.length; i++) {
            var k = localStorage.key(i);
            if (k && k.startsWith("org-museum")) {
              count++;
              var val = localStorage.getItem(k) || "";
              totalBytes += (k.length + val.length) * 2;
            }
          }
        }
        if (countEl) countEl.textContent = count + " 项记录";
        if (sizeEl) sizeEl.textContent = "~" + Math.max(0.2, (totalBytes / 1024)).toFixed(1) + " KB";
        if (progressEl) {
          var completedCount = 0;
          try {
            var comp = JSON.parse(localStorage.getItem("org-museum-related-completed") || "[]");
            if (Array.isArray(comp)) completedCount = comp.length;
          } catch (_) {}
          progressEl.textContent = completedCount + " 组已研读";
        }
        if (keyStatusEl) {
          var hasKey = Boolean(localStorage.getItem("org-museum-api-key"));
          keyStatusEl.textContent = hasKey ? "已在本地保存" : "未保存 (会话级)";
        }
      } catch (_) {
        if (countEl) countEl.textContent = "已就绪";
        if (sizeEl) sizeEl.textContent = "--";
        if (progressEl) progressEl.textContent = "0 组已研读";
        if (keyStatusEl) keyStatusEl.textContent = "未保存";
      }
    }

    updateMetrics();

    if (copyBackupBtn) {
      copyBackupBtn.addEventListener("click", function (e) {
        if (e && e.preventDefault) e.preventDefault();
        try {
          var backupData = {};
          if (typeof localStorage !== "undefined") {
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              if (k && k.startsWith("org-museum")) {
                backupData[k] = localStorage.getItem(k);
              }
            }
          }
          var str = JSON.stringify(backupData, null, 2);
          if (typeof navigator !== "undefined" && navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(str).then(function () {
              if (typeof alert === "function") alert("已将知识库设置与学习记录完整复制到剪贴板！");
            });
          } else {
            if (typeof alert === "function") alert("备份数据已生成（" + Object.keys(backupData).length + " 项配置）。");
          }
        } catch (err) {
          if (typeof alert === "function") alert("读取备份数据失败：" + err.message);
        }
      });
    }

    if (resetAppBtn) {
      resetAppBtn.addEventListener("click", function (e) {
        if (e && e.preventDefault) e.preventDefault();
        try {
          if (typeof localStorage !== "undefined") {
            ["org-museum-reading-size", "org-museum-reading-width", "org-museum-reading-font",
             "org-museum-reading-tone", "org-museum-reading-line", "org-museum-zen-mode", "org-museum-theme"].forEach(function (k) {
              localStorage.removeItem(k);
            });
          }
        } catch (_) {}
        applyTheme("system", true);
        applyReadingPreferences();
        bindReadingSettings(menu);
        updateMetrics();
        if (typeof alert === "function") alert("已成功恢复默认排版与样式！学习记录与密钥已完好保留。");
      });
    }

    var backupBtn = menu.querySelector ? menu.querySelector("[data-browser-backup]") : null;
    if (backupBtn && !backupBtn.dataset.boundTheme) {
      backupBtn.dataset.boundTheme = "true";
      backupBtn.addEventListener("click", function (e) {
        if (backupBtn.dataset.workspaceOwned === "true") return;
        if (e && e.preventDefault) e.preventDefault();
        try {
          var backupData = {
            version: 1,
            appName: "org-museum",
            exportedAt: new Date().toISOString(),
            storage: {}
          };
          if (typeof localStorage !== "undefined") {
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              if (k && k.startsWith("org-museum")) {
                backupData.storage[k] = localStorage.getItem(k);
              }
            }
          }
          var str = JSON.stringify(backupData, null, 2);
          var now = new Date();
          var dStr = now.getFullYear() + "-" + String(now.getMonth() + 1).padStart(2, "0") + "-" + String(now.getDate()).padStart(2, "0");
          if (typeof Blob !== "undefined" && typeof URL !== "undefined" && URL.createObjectURL) {
            var blob = new Blob([str], { type: "application/json" });
            var u = URL.createObjectURL(blob);
            var a = document.createElement("a");
            a.href = u;
            a.download = "org-museum-backup-" + dStr + ".json";
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            setTimeout(function () { URL.revokeObjectURL(u); }, 1500);
          }
          var resultBox = menu.querySelector("[data-browser-sync-result]");
          if (resultBox) {
            resultBox.innerHTML = '<span class="status-success">✅ 已成功导出知识库备份文件（包含 ' + Object.keys(backupData.storage).length + ' 项配置与学习记录）。</span>';
          } else if (typeof alert === "function") {
            alert("已成功生成并下载备份文件（包含 " + Object.keys(backupData.storage).length + " 项记录）！");
          }
        } catch (err) {
          if (typeof alert === "function") alert("导出备份失败：" + err.message);
        }
      });
    }

    var importInput = menu.querySelector ? menu.querySelector("[data-browser-import]") : null;
    if (importInput && !importInput.dataset.boundTheme) {
      importInput.dataset.boundTheme = "true";
      importInput.addEventListener("change", function (e) {
        if (importInput.dataset.workspaceOwned === "true") return;
        var file = e.target && e.target.files && e.target.files[0];
        if (!file) return;
        var reader = new FileReader();
        reader.onload = function (evt) {
          try {
            var parsed = JSON.parse(evt.target.result);
            var data = parsed.storage || parsed;
            if (!data || typeof data !== "object") throw new Error("文件格式不正确，缺少有效配置项");
            var restored = 0;
            Object.keys(data).forEach(function (k) {
              if (k.startsWith("org-museum")) {
                localStorage.setItem(k, data[k]);
                restored++;
              }
            });
            applyTheme(localStorage.getItem("org-museum-theme") || "system", true);
            applyReadingPreferences();
            applyLearningPreferences();
            bindReadingSettings(menu);
            bindLearningSettings(menu);
            updateMetrics();
            var resultBox = menu.querySelector("[data-browser-sync-result]");
            if (resultBox) {
              resultBox.innerHTML = '<span class="status-success">✅ 备份导入成功！已恢复 ' + restored + ' 项数据与个性化设置。</span>';
            } else if (typeof alert === "function") {
              alert("已成功恢复 " + restored + " 项备份记录与设置！");
            }
          } catch (err) {
            if (typeof alert === "function") alert("导入失败：" + err.message);
          } finally {
            e.target.value = "";
          }
        };
        reader.readAsText(file);
      });
    }

    var syncPreviewBtn = menu.querySelector ? menu.querySelector("[data-browser-sync-preview]") : null;
    if (syncPreviewBtn && !syncPreviewBtn.dataset.boundTheme) {
      syncPreviewBtn.dataset.boundTheme = "true";
      syncPreviewBtn.addEventListener("click", function (e) {
        if (syncPreviewBtn.dataset.workspaceOwned === "true") return;
        var resultBox = menu.querySelector("[data-browser-sync-result]");
        if (resultBox && !resultBox.innerHTML.trim()) {
          resultBox.innerHTML = '<div class="sync-notice">💡 <strong>提示：</strong>本地 Org 笔记双向同步需要开启 Emacs 服务。在当前浏览器中，您的全部学习进度均会自动保存在本地，可通过“导出知识库备份”随时迁移。</div>';
        }
      });
    }

    var orgExportBtn = menu.querySelector ? menu.querySelector("[data-browser-org-export]") : null;
    if (orgExportBtn && !orgExportBtn.dataset.boundTheme) {
      orgExportBtn.dataset.boundTheme = "true";
      orgExportBtn.addEventListener("click", function (e) {
        if (orgExportBtn.dataset.workspaceOwned === "true") return;
        var resultBox = menu.querySelector("[data-browser-sync-result]");
        if (resultBox && !resultBox.innerHTML.trim()) {
          resultBox.innerHTML = '<div class="sync-notice">📝 <strong>提示：</strong>当前知识库基于纯文本 Org 架构驱动。您可通过顶栏各页面的“源码”按钮直接阅读标准 Org 语法，或导出完整 JSON 备份。</div>';
        }
      });
    }

    if (resetBtn) {
      resetBtn.addEventListener("click", function (e) {
        if (e && e.preventDefault) e.preventDefault();
        if (typeof confirm === "function" && !confirm("确定要恢复出厂设置吗？这将重置排版大小、学习模式与模型配置。")) return;
        try {
          if (typeof localStorage !== "undefined") {
            var keysToRemove = [];
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              if (k && k.startsWith("org-museum")) keysToRemove.push(k);
            }
            keysToRemove.forEach(function (k) { localStorage.removeItem(k); });
          }
        } catch (_) {}
        applyTheme("system", true);
        applyReadingPreferences();
        applyLearningPreferences();
        bindReadingSettings(menu);
        bindLearningSettings(menu);
        updateMetrics();
        if (typeof alert === "function") alert("已成功恢复初始设置！");
      });
    }
  }

  function initHoverPreview() {
    if (typeof document === "undefined" || !document.body || typeof document.getElementById !== "function") return;
    var card = document.getElementById("museum-hover-card");
    if (!card) {
      card = document.createElement("div");
      card.id = "museum-hover-card";
      card.className = "museum-hover-card";
      card.hidden = true;
      document.body.appendChild(card);
    }

    var hoverTimer = null;
    var activeLink = null;

    function hideCard() {
      if (hoverTimer) { clearTimeout(hoverTimer); hoverTimer = null; }
      activeLink = null;
      if (card) card.hidden = true;
    }

    document.addEventListener("mouseover", function (e) {
      if (document.documentElement && document.documentElement.dataset.hoverPreview === "false") return;
      var link = e.target && e.target.closest && e.target.closest("a[href]");
      if (!link || link === activeLink) return;
      if (link.closest(".museum-topbar") || link.closest(".museum-settings-panel") || link.closest("#museum-ai-panel")) return;

      var href = link.getAttribute("href");
      if (!href || href.startsWith("#") || href.startsWith("javascript:") || href.startsWith("mailto:")) return;
      if (!/\.html($|\?|#)/i.test(href)) return;

      activeLink = link;
      if (hoverTimer) clearTimeout(hoverTimer);
      hoverTimer = setTimeout(function () {
        if (!activeLink) return;
        var rect = link.getBoundingClientRect();
        var title = link.getAttribute("title") || link.textContent.trim() || "关联笔记";
        var catMatch = href.match(/(?:^|\/)(AI|Data|Emacs|SQL|crypto|lisp|ontology|vibe|theme)\//i);
        var catName = link.dataset.category || (catMatch ? catMatch[1] : "");

        card.innerHTML =
          '<div class="museum-hover-card-title">' +
          (catName ? '<span class="rec-tag" style="margin-right:6px;">' + catName + '</span>' : '') +
          title + '</div>' +
          '<div class="museum-hover-card-desc">📖 点击深入阅读笔记 · 支持双链双向探索</div>';

        card.hidden = false;
        var cardRect = card.getBoundingClientRect();
        var top = rect.bottom + 8;
        if (top + cardRect.height > window.innerHeight - 10) {
          top = Math.max(10, rect.top - cardRect.height - 8);
        }
        var left = Math.max(12, Math.min(rect.left, window.innerWidth - cardRect.width - 12));
        card.style.top = top + "px";
        card.style.left = left + "px";
        try {
          var quests = JSON.parse(localStorage.getItem("org-museum-learning-quests") || "{}");
          if (!quests.explore_links) {
            quests.explore_links = true;
            localStorage.setItem("org-museum-learning-quests", JSON.stringify(quests));
            var m = document.querySelector(".museum-settings-menu");
            if (m && m._updateQuestsUI) m._updateQuestsUI();
          }
        } catch (_) {}
      }, 280);
    });

    document.addEventListener("mouseout", function (e) {
      var link = e.target && e.target.closest && e.target.closest("a[href]");
      if (link && link === activeLink) {
        hideCard();
      }
    });

    if (typeof window !== "undefined") {
      window.addEventListener("scroll", hideCard, { passive: true });
    }
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") hideCard();
    });
  }

  var recallTargets = new Map();
  var recallSelector = ".article-container :is(strong,b,.org-bold,.museum-cloze), .related-paper :is(strong,b,.org-bold,.museum-cloze), .museum-md :is(strong,b,.org-bold,.museum-cloze)";

  function syncRecallState(target) {
    var revealed = target.classList.contains("is-revealed");
    target.setAttribute("aria-pressed", String(revealed));
    target.setAttribute("aria-label", revealed ? "隐藏重点内容：" + target.textContent.trim() : "显示重点内容");
  }

  function syncActiveRecallTargets() {
    var active = document.documentElement && document.documentElement.dataset.activeRecall === "true";
    var targets = active ? Array.from(document.querySelectorAll(recallSelector)).filter(function (target) {
      return !target.closest("button, a, pre, code, summary, [contenteditable], .museum-next-learning-hub, .museum-study-guide") &&
        !(target.parentElement && target.parentElement.closest("strong,b,.org-bold,.museum-cloze"));
    }) : [];
    var current = new Set(targets);
    recallTargets.forEach(function (saved, target) {
      if (current.has(target)) return;
      Object.keys(saved.attributes).forEach(function (name) {
        var value = saved.attributes[name];
        if (value === null) target.removeAttribute(name);
        else target.setAttribute(name, value);
      });
      target.classList.toggle("is-revealed", saved.revealed);
      target.removeAttribute("data-museum-recall");
      recallTargets.delete(target);
    });
    targets.forEach(function (target) {
      if (recallTargets.has(target)) return;
      var attributes = {};
      ["role", "tabindex", "aria-label", "aria-pressed"].forEach(function (name) { attributes[name] = target.getAttribute(name); });
      recallTargets.set(target, {attributes: attributes, revealed: target.classList.contains("is-revealed")});
      target.setAttribute("data-museum-recall", "");
      target.setAttribute("role", "button");
      target.setAttribute("tabindex", "0");
      syncRecallState(target);
    });
  }

  function initActiveRecall() {
    if (typeof document === "undefined" || !document.body || typeof document.addEventListener !== "function") return;
    function activate(e) {
      if (document.documentElement && document.documentElement.dataset.activeRecall !== "true") return;
      var cloze = e.target && e.target.closest && e.target.closest("[data-museum-recall]");
      if (!cloze) return;
      if (e.type === "keydown") {
        if (e.isComposing || e.repeat || (e.key !== "Enter" && e.key !== " ")) return;
        e.preventDefault();
      }
      cloze.classList.toggle("is-revealed");
      syncRecallState(cloze);
      try {
        var quests = JSON.parse(localStorage.getItem("org-museum-learning-quests") || "{}");
        if (!quests.active_recall) {
          quests.active_recall = true;
          localStorage.setItem("org-museum-learning-quests", JSON.stringify(quests));
          var m = document.querySelector(".museum-settings-menu");
          if (m && m._updateQuestsUI) m._updateQuestsUI();
        }
      } catch (_) {}
    }
    document.addEventListener("click", activate);
    document.addEventListener("keydown", activate);
    syncActiveRecallTargets();
    var main = typeof MutationObserver === "function" && document.getElementById("main-content");
    if (main) {
      new MutationObserver(function (records) {
        if (document.documentElement.dataset.activeRecall !== "true") return;
        if (records.some(function (record) { return record.addedNodes.length || record.removedNodes.length; })) syncActiveRecallNotice();
      }).observe(main, {childList: true, subtree: true});
    }
  }

  function bindControls() {
    syncZenMode();
    document.querySelectorAll(".museum-study-guide").forEach(function (tip) {
      var prefix = tip.id.replace(/-study-tip$/, "");
      var storageKey = "org-museum-" + prefix + "-guide-dismissed";
      try { tip.hidden = localStorage.getItem(storageKey) === "true"; } catch (_) {}
      var dismiss = tip.querySelector(".study-guide-dismiss");
      if (dismiss) dismiss.addEventListener("click", function () {
        tip.hidden = true;
        try { localStorage.setItem(storageKey, "true"); } catch (_) {}
      });
    });
    updateControls(normalize(document.documentElement.dataset.theme));
    bindReturnLink();
    bindGlobalSearch();
    document.querySelectorAll("[data-theme-toggle]").forEach(function (button) {
      button.addEventListener("click", function () {
        var current = normalize(document.documentElement.dataset.theme);
        applyTheme(current === "light" ? "dark" : "light", true);
      });
    });
    document.querySelectorAll("[data-theme-system]").forEach(function (button) {
      button.addEventListener("click", function () { applyTheme("system", true); });
    });
    document.querySelectorAll(".museum-theme-menu").forEach(function (menu) {
      document.addEventListener("click", function (event) { if (!menu.contains(event.target)) menu.open = false; });
      document.addEventListener("keydown", function (event) {
        if (event.key === "Escape" && menu.open) {
          menu.open = false;
          var summary = menu.querySelector ? menu.querySelector("summary") : null;
          if (summary && typeof summary.focus === "function") summary.focus();
        }
      });
      menu.addEventListener("keydown", function (event) {
        if (event.key === "Escape") {
          menu.open = false;
          var sum = menu.querySelector ? menu.querySelector("summary") : null;
          if (sum && typeof sum.focus === "function") sum.focus();
        }
      });
      bindSettingsTabs(menu);
      bindGlobalAiSettings(menu);
      bindReadingSettings(menu);
      bindLearningSettings(menu);
      bindDataSettings(menu);
    });
    initHoverPreview();
    initActiveRecall();
    document.addEventListener("keydown", function (e) {
      if (e.defaultPrevented || e.isComposing || e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.key === "Escape") {
        if (document.documentElement.dataset.zenMode === "true") window.orgMuseumSetZen(false);
        return;
      }
      if (e.key === "z" || e.key === "Z") {
        var tag = document.activeElement && document.activeElement.tagName;
        if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" ||
            (e.target && (e.target.isContentEditable || (e.target.closest && e.target.closest('button,a,[role="dialog"],dialog,summary'))))) return;
        var doc = document.documentElement;
        if (!doc) return;
        var isZen = doc.dataset.zenMode === "true";
        e.preventDefault();
        window.orgMuseumSetZen(!isZen);
      }
    });
    bindPromptStarters();
    syncActiveRecallNotice();
  }

  function bindPromptStarters() {
    var starters = typeof document.querySelectorAll === "function" ? document.querySelectorAll(".prompt-starter-pill[data-prompt-text]") : [];
    var textarea = (typeof document.getElementById === "function" ? document.getElementById("museum-ai-followup") : null) || (typeof document.querySelector === "function" ? document.querySelector("[data-ai-followup]") : null);
    if (!starters.length || !textarea) return;

    starters.forEach(function (btn) {
      if (btn._boundStarter) return;
      btn._boundStarter = true;
      btn.addEventListener("click", function (e) {
        if (e && e.preventDefault) e.preventDefault();
        var text = btn.getAttribute("data-prompt-text");
        if (text) {
          textarea.value = text;
          if (typeof textarea.focus === "function") textarea.focus();
          if (typeof Event === "function") {
            textarea.dispatchEvent(new Event("input", { bubbles: true }));
          }
        }
      });
    });
  }

  function syncActiveRecallNotice() {
    syncActiveRecallTargets();
    var isArticle = !!(
      (typeof document.querySelector === "function" && document.querySelector(".article-container")) ||
      (typeof document.querySelector === "function" && document.querySelector(".related-paper, .museum-md")) ||
      (typeof document.querySelector === "function" && document.querySelector("#content.museum-article-layout")) ||
      (typeof document.querySelector === "function" && document.querySelector("#main-scroll"))
    );
    var notice = typeof document.getElementById === "function" ? document.getElementById("active-recall-notice") : null;
    if (!isArticle) {
      if (notice) notice.hidden = true;
      return;
    }

    var isActive = document.documentElement && document.documentElement.dataset.activeRecall === "true";

    if (isActive) {
      if (!notice && typeof document.createElement === "function") {
        notice = document.createElement("div");
        notice.id = "active-recall-notice";
        notice.className = "active-recall-notice";
        if (typeof notice.setAttribute === "function") {
          notice.setAttribute("role", "status");
          notice.setAttribute("aria-live", "polite");
        }
        notice.innerHTML = '<span class="recall-icon">🧠</span><span class="recall-msg"><strong>自测模式生效中</strong>：轻触、悬停或用 Tab 聚焦后按 Enter / 空格揭示重点。</span><button type="button" class="recall-exit-btn" aria-label="关闭自测模式">退出自测</button>';

        var targetContainer = (typeof document.querySelector === "function" ? document.querySelector("#museum-article-identity") : null) ||
                              (typeof document.querySelector === "function" ? document.querySelector("#main-scroll") : null) ||
                              (typeof document.getElementById === "function" ? document.getElementById("main-content") : null) ||
                              document.body;
        if (targetContainer && targetContainer.parentNode && targetContainer.id === "museum-article-identity") {
          targetContainer.parentNode.insertBefore(notice, targetContainer.nextSibling);
        } else if (targetContainer && targetContainer.firstChild && typeof targetContainer.insertBefore === "function") {
          targetContainer.insertBefore(notice, targetContainer.firstChild);
        } else if (targetContainer && typeof targetContainer.appendChild === "function") {
          targetContainer.appendChild(notice);
        }

        var exitBtn = notice.querySelector ? notice.querySelector(".recall-exit-btn") : null;
        if (exitBtn && typeof exitBtn.addEventListener === "function") {
          exitBtn.addEventListener("click", function () {
            if (document.documentElement) document.documentElement.dataset.activeRecall = "false";
            try { localStorage.setItem("org-museum-active-recall", "false"); } catch (_) {}
            var toggle = typeof document.querySelector === "function" ? document.querySelector("[data-active-recall-toggle]") : null;
            if (toggle) toggle.checked = false;
            syncActiveRecallNotice();
          });
        }
      }
      if (notice) notice.hidden = false;
    } else if (notice) {
      notice.hidden = true;
    }
  }

  window.syncActiveRecallNotice = syncActiveRecallNotice;

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", bindControls, { once: true });
  } else {
    bindControls();
  }

  document.addEventListener("click", carryThemeToLocalPage, true);

  window.addEventListener("storage", function (event) {
    if (event.key === key) applyTheme(event.newValue, false);
  });
  if (systemScheme) {
    var changed = function () { if (currentTheme() === "system") applyTheme("system", false); };
    if (systemScheme.addEventListener) systemScheme.addEventListener("change", changed);
    else if (systemScheme.addListener) systemScheme.addListener(changed);
  }
})();

/* Shared media: also handles full articles inserted by related reading. */
(function () {
  'use strict';
  if (window.orgMuseumMedia || !window.MutationObserver) return;
  var types = {mp3:'audio/mpeg', wav:'audio/wav', ogg:'audio/ogg', m4a:'audio/mp4', mp4:'video/mp4', webm:'video/webm'};
  function seconds(value) {
    if (/^\d+$/.test(value || '')) return Math.min(Number(value), 2147483647);
    var match = /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/.exec(value || '');
    return match ? Math.min((Number(match[1] || 0)*3600 + Number(match[2] || 0)*60 + Number(match[3] || 0)), 2147483647) : 0;
  }
  function describe(href) {
    var url;
    try { url = new URL(href, document.baseURI); } catch (_) { return null; }
    if (!/^https?:$/.test(url.protocol) || url.username || url.password) return null;
    var host = url.hostname.toLowerCase(), id, match;
    var start = seconds(url.searchParams.get('start') || url.searchParams.get('t') || url.hash.replace(/^#t=/, ''));
    if (host === 'youtu.be') id = url.pathname.slice(1).split('/')[0];
    if (['youtube.com','www.youtube.com','m.youtube.com','www.youtube-nocookie.com','youtube-nocookie.com'].indexOf(host) !== -1) {
      if (url.pathname === '/watch') id = url.searchParams.get('v');
      else if ((match = /^\/(?:embed|shorts|live)\/([^/]+)\/?$/.exec(url.pathname))) id = match[1];
    }
    if (id && /^[\w-]{11}$/.test(id)) return {kind:'iframe', key:'youtube:'+id, label:'YouTube', src:'https://www.youtube.com/embed/'+id+'?autoplay=0&playsinline=1&start='+start};
    if (['bilibili.com','www.bilibili.com','m.bilibili.com','player.bilibili.com'].indexOf(host) !== -1) {
      var bvid = null, aid = null;
      if ((match = /^\/video\/(BV[0-9A-Za-z]{10}|av\d+)\/?$/.exec(url.pathname))) {
        if (match[1].slice(0,2) === 'BV') bvid = match[1]; else aid = match[1].slice(2);
      } else if (host === 'player.bilibili.com' && url.pathname === '/player.html') {
        bvid = url.searchParams.get('bvid'); aid = url.searchParams.get('aid');
      }
      var identity = /^BV[0-9A-Za-z]{10}$/.test(bvid || '') ? 'bvid='+bvid : /^\d+$/.test(aid || '') ? 'aid='+aid : null;
      if (identity) {
        var part = Math.max(1, Math.min(parseInt(url.searchParams.get('p'),10) || 1, 10000));
        return {kind:'iframe', key:'bilibili:'+identity+':'+part, label:'哔哩哔哩', src:'https://player.bilibili.com/player.html?'+identity+'&p='+part+'&autoplay=0&t='+start};
      }
    }
    var extension = /\.([a-z0-9]+)$/i.exec(url.pathname);
    var mime = extension && types[extension[1].toLowerCase()];
    return mime ? {kind:mime.split('/')[0], key:url.href, label:mime.startsWith('audio/')?'音频':'视频', src:url.href, mime:mime} : null;
  }
  function enhance(root) {
    root.querySelectorAll('a[href]').forEach(function (link) {
      // Only a standalone paragraph becomes a player; prose, tables, code and
      // existing native players retain their reading/navigation behaviour.
      var paragraph = link.parentElement;
      var container = link.closest('.article-container, .museum-md');
      if (!container || !paragraph || paragraph.tagName !== 'P' || link.closest('figure,pre,nav,.museum-asset')) return;
      if (!Array.from(paragraph.childNodes).every(function(n){return n === link || (n.nodeType === 3 && !n.textContent.trim());})) return;
      var media = describe(link.href);
      if (!media || Array.from(container.querySelectorAll('[data-museum-media-key]')).some(function(n){return n.dataset.museumMediaKey === media.key;})) return;
      var figure = document.createElement('figure');
      figure.className = 'museum-asset museum-media museum-media-'+media.kind;
      figure.dataset.museumMediaKey = media.key;
      var player = document.createElement(media.kind), caption = document.createElement('figcaption');
      if (media.kind === 'iframe') {
        player.title = media.label+'：'+(link.textContent.trim() || '视频播放器');
        player.loading = 'lazy';
        player.referrerPolicy = 'strict-origin-when-cross-origin';
        player.allow = 'encrypted-media; fullscreen; picture-in-picture';
        player.allowFullscreen = true;
        player.src = media.src;
      } else {
        player.controls = true; player.preload = 'none';
        player.setAttribute('aria-label', link.textContent.trim() || media.label);
        if (media.kind === 'video') player.setAttribute('playsinline','');
        var source = document.createElement('source'); source.src = media.src; source.type = media.mime;
        player.appendChild(source);
        player.addEventListener('error', function(){status.hidden = false;});
        source.addEventListener('error', function(){status.hidden = false;});
      }
      caption.className = 'museum-asset-caption';
      var status = document.createElement('span');
      status.textContent = media.kind === 'iframe' ? '若无法播放，可打开源站观看。' : '无法播放此媒体，可打开源文件。';
      status.hidden = media.kind !== 'iframe'; status.setAttribute('role','status');
      paragraph.replaceWith(figure);
      caption.appendChild(link); caption.appendChild(status);
      figure.appendChild(player); figure.appendChild(caption);
    });
    root.querySelectorAll('.article-container audio, .museum-md audio').forEach(prepareAudio);
  }
  var audioSequence = 0;
  function prepareAudio(audio) {
    if (audio.dataset.museumAudioReady || !audio.closest('figure')) return;
    var figure = audio.closest('figure');
    var panel = document.createElement('div'); panel.className = 'museum-audio-controls';
    var title = audio.getAttribute('aria-label') || '音频';
    var source = audio.currentSrc || audio.getAttribute('src') || audio.querySelector('source')?.getAttribute('src') || '';
    var format = /\.([a-z0-9]+)(?:[?#]|$)/i.exec(source);
    var titleId = 'museum-audio-title-'+(++audioSequence);
    var icons = {
      play:'<path d="m9 5 10 7-10 7Z"/>',
      pause:'<path d="M8 5v14M16 5v14"/>',
      volume:'<path d="M11 5 6 9H3v6h3l5 4ZM15 8a6 6 0 0 1 0 8M18 5a10 10 0 0 1 0 14"/>',
      muted:'<path d="M11 5 6 9H3v6h3l5 4ZM16 9l6 6m0-6-6 6"/>'
    };
    function icon(button, name) {
      button.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">'+icons[name]+'</svg>';
    }
    function element(tag, className, text) {
      var node = document.createElement(tag); node.className = className;
      if (text) node.textContent = text; return node;
    }
    function button(className, label) {
      var node = element('button',className); node.type='button'; node.setAttribute('aria-label',label);node.title=label;return node;
    }
    function clock(value) {
      if (!Number.isFinite(value)) return '--:--';
      var total=Math.max(0,Math.floor(value)),hours=Math.floor(total/3600),minutes=Math.floor(total%3600/60),seconds=String(total%60).padStart(2,'0');
      return (hours?hours+':'+String(minutes).padStart(2,'0'):minutes)+':'+seconds;
    }
    var header=element('div','museum-audio-heading');
    var heading=element('div','museum-audio-identity');
    heading.appendChild(element('span','museum-audio-format',(format?format[1].toUpperCase()+' · ':'')+'音频'));
    var name=element('span','museum-audio-title',title);name.id=titleId;heading.appendChild(name);header.appendChild(heading);
    var fallback=button('museum-audio-native','切换系统音频控件');fallback.textContent='系统控件';header.appendChild(fallback);
    panel.setAttribute('role','group');panel.setAttribute('aria-labelledby',titleId);
    var main=element('div','museum-audio-main');
    var play=button('museum-audio-play','播放');icon(play,'play');main.appendChild(play);
    var progress=element('div','museum-audio-progress');
    var meta=element('div','museum-audio-meta');
    var time=element('span','museum-audio-time','0:00 / --:--');
    var status=element('span','museum-audio-status','点击播放');status.setAttribute('role','status');
    meta.append(time,status);
    var seek=element('input','museum-audio-seek');seek.type='range';seek.min='0';seek.max='0';seek.step='0.1';seek.value='0';seek.disabled=true;seek.setAttribute('aria-label',title+'，播放进度');
    progress.append(meta,seek);main.appendChild(progress);
    var footer=element('div','museum-audio-footer');
    var volumeGroup=element('div','museum-audio-volume-group');
    var mute=button('museum-audio-mute','静音');icon(mute,'volume');mute.setAttribute('aria-pressed','false');
    var volume=element('input','museum-audio-volume');volume.type='range';volume.min='0';volume.max='1';volume.step='0.05';volume.value=String(audio.volume);volume.setAttribute('aria-label',title+'，音量');
    volumeGroup.append(mute,volume);
    var speed=element('select','museum-audio-speed');speed.setAttribute('aria-label',title+'，播放速度');
    [0.5,0.75,1,1.25,1.5,2].forEach(function(rate){var option=document.createElement('option');option.value=String(rate);option.textContent=rate+'×';speed.appendChild(option);});speed.value=String(audio.playbackRate);
    footer.append(volumeGroup,speed);panel.append(header,main,footer);
    var requested=false, failed=false, dragging=false, sourceErrors=new Set();
    function syncProgress() {
      var duration=audio.duration,available=Number.isFinite(duration)&&duration>0;
      seek.disabled=!available||failed;seek.max=available?String(duration):'0';
      if (!dragging) seek.value=String(audio.currentTime||0);
      time.textContent=clock(dragging?Number(seek.value):audio.currentTime)+' / '+clock(duration);
      seek.setAttribute('aria-valuetext',clock(Number(seek.value))+'，总时长 '+clock(duration));
      seek.style.setProperty('--audio-progress',available?Math.min(100,100*Number(seek.value)/duration)+'%':'0%');
    }
    function syncState(message) {
      var playing=!audio.paused&&!audio.ended;
      icon(play,playing?'pause':'play');play.setAttribute('aria-label',playing?'暂停':'播放');play.title=playing?'暂停':'播放';
      panel.classList.toggle('is-playing',playing);
      if(message)status.textContent=message;
      syncProgress();
    }
    play.addEventListener('click',function(){
      if(window.orgMuseumPlayer && !audio.dataset.museumGlobalAudio){
        window.orgMuseumPlayer.toggle({src:new URL(source,document.baseURI).href,title:title,page:location.href});return;
      }
      if(!audio.paused||requested){requested=false;audio.pause();syncState('已暂停');return;}
      requested=true;
      if(failed){failed=false;sourceErrors.clear();audio.load();}
      status.textContent='加载中…';
      var promise=audio.play();
      if(promise)promise.catch(function(error){
        if(error.name==='AbortError')return;
        requested=false;syncState('播放失败，请重试或打开源文件');
      });
    });
    audio.addEventListener('playing',function(){failed=false;requested=false;syncState('正在播放');});
    audio.addEventListener('pause',function(){requested=false;syncState(failed?'无法播放，请重试或打开源文件':audio.ended?'播放结束':'已暂停');});
    audio.addEventListener('ended',function(){requested=false;syncState('播放结束');});
    audio.addEventListener('waiting',function(){if(!audio.paused)status.textContent='缓冲中…';});
    function fail(){failed=true;requested=false;audio.pause();syncState('无法播放，请重试或打开源文件');}
    audio.addEventListener('error',fail);
    // A failed <source> does not bubble an error to <audio>. Keep alternate
    // sources usable, but stop buffering when every candidate has failed.
    var sources=Array.from(audio.querySelectorAll('source'));
    sources.forEach(function(source){source.addEventListener('error',function(){
      sourceErrors.add(source);
      if(!audio.hasAttribute('src')&&sourceErrors.size===sources.length&&audio.readyState===0)fail();
    });});
    ['loadedmetadata','durationchange','timeupdate','seeked'].forEach(function(event){audio.addEventListener(event,syncProgress);});
    seek.addEventListener('input',function(){dragging=true;syncProgress();});
    seek.addEventListener('change',function(){audio.currentTime=Number(seek.value);dragging=false;syncProgress();});
    function syncVolume(){
      var muted=audio.muted||audio.volume===0;icon(mute,muted?'muted':'volume');mute.setAttribute('aria-pressed',String(muted));mute.setAttribute('aria-label',muted?'取消静音':'静音');mute.title=muted?'取消静音':'静音';
      volume.value=String(audio.muted?0:audio.volume);
      volume.setAttribute('aria-valuetext',Math.round(Number(volume.value)*100)+'%');
    }
    mute.addEventListener('click',function(){if(audio.volume===0){audio.volume=0.5;audio.muted=false;}else audio.muted=!audio.muted;syncVolume();});
    volume.addEventListener('input',function(){audio.volume=Number(volume.value);audio.muted=audio.volume===0;syncVolume();});
    audio.addEventListener('volumechange',syncVolume);
    speed.addEventListener('change',function(){audio.playbackRate=Number(speed.value);});
    audio.addEventListener('ratechange',function(){speed.value=String(audio.playbackRate);});
    fallback.addEventListener('click',function(){audio.controls=true;audio.hidden=false;panel.hidden=true;figure.classList.remove('museum-audio-player');audio.focus();});
    // Hide the browser controls only after the replacement is fully wired.
    audio.before(panel);audio.dataset.museumAudioReady='1';audio.hidden=true;
    figure.classList.add('museum-audio-player');syncVolume();syncState();
    if(window.orgMuseumPlayer&&!audio.dataset.museumGlobalAudio)window.orgMuseumPlayer.refresh();
  }
  window.orgMuseumMedia = {describe:describe, enhance:enhance, prepareAudio:prepareAudio};
  function init() {
    enhance(document);
    var pending = false;
    new MutationObserver(function(records){
      if (pending || !records.some(function(record){return Array.from(record.addedNodes).some(function(n){return n.nodeType===1 && (n.matches('.article-container,.museum-md') || n.querySelector('.article-container,.museum-md'));});})) return;
      pending = true;
      queueMicrotask(function(){pending=false;enhance(document);});
    }).observe(document.body,{childList:true,subtree:true});
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded',init,{once:true});
  else init();
})();

/* Persistent audio owns its media element outside the navigated document.
 * The same-origin reading frame keeps the existing pages and their scripts
 * intact. Native joint session history handles Back/Forward; never add a
 * second history entry for a frame navigation. */
(function(){
  'use strict';
  if(window.orgMuseumPlayer || !window.history || !window.location || !/^https?:$/.test(location.protocol))return;
  var script=document.currentScript;
  var rootURL=new URL('../',script?script.src:location.href);
  var KEY='org-museum-player-v1',clients=new Set(),queue=[],current=null,root,bar,frame,dialog,audio;
  var titleButton,timer,playButton,previous,next,seek,modeButton,queueList,notice,sourceLink,sourcePage;
  var mode='order',closed=false,savedTime=0,lastSaved=0,catalogLoaded=false;
  var owner=Date.now().toString(36)+Math.random().toString(36).slice(2);
  var icons={play:'<path d="m9 5 10 7-10 7Z"/>',pause:'<path d="M8 5v14M16 5v14"/>',prev:'<path d="M6 5v14m12-14L8 12l10 7Z"/>',next:'<path d="M18 5v14M6 5l10 7-10 7Z"/>',list:'<path d="M9 6h12M9 12h12M9 18h12M3 6h1M3 12h1M3 18h1"/>',close:'<path d="m6 6 12 12M6 18 18 6"/>'};
  function el(tag,cls,text){var n=document.createElement(tag);n.className=cls||'';if(text)n.textContent=text;return n;}
  function icon(b,key){b.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">'+icons[key]+'</svg>';}
  function button(label,key,cls){var b=el('button',cls);b.type='button';b.setAttribute('aria-label',label);b.title=label;if(key)icon(b,key);else b.textContent=label;return b;}
  function clock(n){if(!Number.isFinite(n))return '--:--';n=Math.max(0,Math.floor(n));return Math.floor(n/60)+':'+String(n%60).padStart(2,'0');}
  function valid(track){
    try{var url=new URL(track.src,rootURL);if(!/^https?:$/.test(url.protocol)||url.username||url.password)return null;
      var page=new URL(track.page||rootURL,rootURL);
      return {src:url.href,title:String(track.title||'音频').slice(0,300),page:page.origin===location.origin?page.href:rootURL.href};
    }catch(_){return null;}
  }
  function tracks(doc,page){return Array.from(doc.querySelectorAll('audio:not([data-museum-global-audio])')).map(function(a){return valid({src:new URL(a.getAttribute('src')||a.querySelector('source')?.getAttribute('src')||'',doc.baseURI).href,title:a.getAttribute('aria-label')||doc.title,page:page});}).filter(Boolean);}
  function state(){return {track:current,paused:!audio||audio.paused,time:audio?audio.currentTime:0,duration:audio?audio.duration:NaN,queue:queue.slice(),mode:mode};}
  function save(){
    try{sessionStorage.setItem(KEY,JSON.stringify({queue:queue.slice(0,100),current:current?.src,time:audio?.currentTime||savedTime,mode:mode,volume:audio?.volume??1,muted:audio?.muted||false,rate:audio?.playbackRate||1,closed:closed}));}catch(_){}
  }
  function inline(doc){
    doc.documentElement.classList.add('museum-global-audio-ready');
    doc.querySelectorAll('.museum-audio-player').forEach(function(figure){
      var a=figure.querySelector('audio');if(!a||a.dataset.museumGlobalAudio)return;
      var src=new URL(a.getAttribute('src')||a.querySelector('source')?.getAttribute('src')||'',doc.baseURI).href;
      var active=current&&current.src===src,playing=active&&audio&&!audio.paused;
      var b=figure.querySelector('.museum-audio-play');
      if(b){icon(b,playing?'pause':'play');b.setAttribute('aria-label',playing?'暂停全站播放':'全站播放');b.title=b.getAttribute('aria-label');}
      var label=figure.querySelector('.museum-audio-format');if(label)label.textContent=active?(playing?'正在全站播放':'已暂停 · 全站播放'):'音频 · 全站播放';
    });
  }
  function refresh(){
    inline(document);
    clients.forEach(function(win){try{win.dispatchEvent(new win.Event('museum-player-state'));}catch(_){clients.delete(win);}});
    if(!bar||!current)return;
    var playing=!audio.paused&&!audio.ended;
    icon(playButton,playing?'pause':'play');playButton.setAttribute('aria-label',playing?'暂停':'播放');playButton.title=playButton.getAttribute('aria-label');
    titleButton.querySelector('strong').textContent=current.title;
    titleButton.setAttribute('aria-label',current.title+'，展开播放面板');
    timer.textContent=clock(audio.currentTime)+' / '+clock(audio.duration);
    previous.disabled=next.disabled=queue.length<2;
    seek.disabled=!Number.isFinite(audio.duration)||audio.duration<=0;
    seek.max=Number.isFinite(audio.duration)?audio.duration:0;seek.value=audio.currentTime||0;
    seek.setAttribute('aria-valuetext',clock(audio.currentTime)+'，总时长 '+clock(audio.duration));
    if(navigator.mediaSession){
      navigator.mediaSession.playbackState=playing?'playing':'paused';
      if(Number.isFinite(audio.duration)&&audio.duration>0)try{navigator.mediaSession.setPositionState({duration:audio.duration,position:Math.min(audio.currentTime,audio.duration),playbackRate:audio.playbackRate});}catch(_){}
    }
  }
  function add(list){list.forEach(function(item){var track=valid(item);if(track&&!queue.some(function(t){return t.src===track.src;}))queue.push(track);});if(queueList)renderQueue();}
  function renderQueue(){
    var focused=document.activeElement,hadFocus=queueList.contains(focused),focusedSrc=focused?.closest('.museum-player-queue-item')?.dataset.src;
    queueList.replaceChildren();
    queue.forEach(function(track,index){
      var row=el('li','museum-player-queue-item');
      row.dataset.src=track.src;
      var choose=button(track.title,null,'museum-player-track');choose.textContent='';
      choose.append(el('span','museum-player-number',String(index+1).padStart(2,'0')),el('span','',track.title));
      if(current?.src===track.src)choose.setAttribute('aria-current','true');
      choose.addEventListener('click',function(){select(track);});
      var remove=button('移除 '+track.title,'close','museum-player-remove');
      remove.disabled=current?.src===track.src;
      remove.addEventListener('click',function(){queue=queue.filter(function(t){return t.src!==track.src;});renderQueue();refresh();save();});
      row.append(choose,remove);queueList.append(row);
    });
    dialog.querySelector('.museum-player-count').textContent=queue.length+' 首音频';
    if(hadFocus){var row=Array.from(queueList.children).find(function(n){return n.dataset.src===focusedSrc;})||queueList.firstElementChild;row?.querySelector('button')?.focus({preventScroll:true});}
  }
  function play(){
    if(!audio||!current)return;
    closed=false;bar.hidden=false;document.documentElement.classList.add('museum-player-reserved');
    ensureFrame();notice.textContent='正在加载音频…';
    if(audio.error)audio.load();
    audio.play().catch(function(error){if(error.name!=='AbortError'){notice.textContent='播放失败，可重试或打开源文件。';refresh();}});
  }
  function select(item,resume){
    var track=valid(item);if(!track)return;
    create();add([track]);
    if(current?.src!==track.src||!audio.getAttribute('src')){
      audio.pause();current=queue.find(function(t){return t.src===track.src;});savedTime=resume||0;
      audio.src=current.src;audio.setAttribute('aria-label',current.title);
      dialog.querySelector('.museum-audio-title').textContent=current.title;
      sourceLink.href=current.src;sourcePage.href=current.page;
      if(navigator.mediaSession&&window.MediaMetadata)navigator.mediaSession.metadata=new MediaMetadata({title:current.title,artist:'Org Museum'});
    }
    renderQueue();play();save();refresh();loadCatalog();
  }
  function toggle(track){
    if(current?.src===track.src&&audio){if(audio.paused)play();else audio.pause();refresh();save();}
    else select(track);
  }
  function step(delta,ended){
    if(!current)return;
    if(ended&&mode==='one'){audio.currentTime=0;play();return;}
    var index=queue.findIndex(function(t){return t.src===current.src;});
    if(mode==='shuffle'&&queue.length>1){var offset=1+Math.floor(Math.random()*(queue.length-1));index=(index+offset)%queue.length;}
    else index+=delta;
    if(index<0)index=queue.length-1;
    if(index>=queue.length){if(ended){refresh();save();return;}index=0;}
    select(queue[index]);
  }
  function create(){
    if(root)return;
    root=el('div','');root.id='museum-global-player';
    bar=el('section','museum-player-bar');bar.setAttribute('aria-label','全站音频播放器');
    playButton=button('播放','play','museum-player-toggle');
    titleButton=button('展开正在播放与队列',null,'museum-player-title');titleButton.textContent='';
    timer=el('span','museum-player-time');titleButton.append(el('strong',''),timer);
    seek=el('input','museum-player-seek');seek.type='range';seek.min=0;seek.max=0;seek.step=1;seek.value=0;seek.setAttribute('aria-label','全站音频播放进度');
    previous=button('上一首','prev','museum-player-skip');next=button('下一首','next','museum-player-skip');
    var details=button('播放队列与更多控制','list','museum-player-details'),stop=button('停止播放并收起','close','museum-player-stop');
    bar.append(playButton,titleButton,seek,previous,next,details,stop);
    dialog=el('dialog','museum-player-dialog');dialog.setAttribute('aria-labelledby','museum-player-heading');
    var header=el('div','museum-player-dialog-header'),heading=el('h2','','正在播放');heading.id='museum-player-heading';
    var close=button('关闭播放面板','close');header.append(heading,close);
    var figure=el('figure','museum-asset');
    audio=el('audio','');audio.preload='none';audio.controls=true;audio.dataset.museumGlobalAudio='1';audio.setAttribute('aria-label','全站音频');figure.append(audio);
    window.orgMuseumMedia.prepareAudio(audio);
    var links=el('div','museum-player-links');sourceLink=el('a','','打开音频源文件');sourceLink.target='_blank';sourceLink.rel='noopener';sourcePage=el('a','','回到这篇笔记');links.append(sourcePage,sourceLink);
    var toolbar=el('div','museum-player-queue-toolbar');
    modeButton=button('顺序播放',null,'museum-player-mode');modeButton.setAttribute('aria-label','播放模式：顺序播放');
    var clear=button('清空待播',null,'museum-player-clear');toolbar.append(el('span','museum-player-count'),modeButton,clear);
    queueList=el('ol','museum-player-queue');queueList.setAttribute('aria-label','播放队列');
    notice=el('p','museum-player-notice');notice.setAttribute('role','status');
    dialog.append(header,figure,links,toolbar,queueList,notice);root.append(bar,dialog);document.body.append(root);
    playButton.addEventListener('click',function(){if(audio.paused)play();else audio.pause();});
    previous.addEventListener('click',function(){step(-1);});next.addEventListener('click',function(){step(1);});
    seek.addEventListener('input',function(){if(Number.isFinite(audio.duration))audio.currentTime=Number(seek.value);});
    function show(){dialog.showModal();close.focus();}
    titleButton.addEventListener('click',show);details.addEventListener('click',show);close.addEventListener('click',function(){dialog.close();});
    dialog.addEventListener('click',function(e){if(e.target===dialog){var r=dialog.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)dialog.close();}});
    stop.addEventListener('click',function(){audio.pause();audio.currentTime=0;closed=true;bar.hidden=true;document.documentElement.classList.remove('museum-player-reserved');save();});
    modeButton.addEventListener('click',function(){mode=mode==='order'?'one':mode==='one'?'shuffle':'order';syncMode();save();});
    clear.addEventListener('click',function(){queue=current?[current]:[];renderQueue();refresh();save();});
    sourcePage.addEventListener('click',function(e){if(frame&&!e.ctrlKey&&!e.metaKey){e.preventDefault();dialog.close();frame.src=window.orgMuseumThemeUrl?window.orgMuseumThemeUrl(current.page):current.page;}});
    audio.addEventListener('ended',function(){step(1,true);});
    audio.addEventListener('play',function(){closed=false;bar.hidden=false;document.documentElement.classList.add('museum-player-reserved');ensureFrame();});
    audio.addEventListener('playing',function(){notice.textContent='切换站内页面，音乐会继续播放。';try{localStorage.setItem('org-museum-player-owner',owner+':'+Date.now());}catch(_){}refresh();});
    audio.addEventListener('error',function(){notice.textContent='音频加载失败，请重试或打开源文件。';refresh();});
    ['pause','loadedmetadata','durationchange','seeked','ratechange','volumechange'].forEach(function(event){audio.addEventListener(event,function(){refresh();save();});});
    audio.addEventListener('loadedmetadata',function(){if(savedTime>0){audio.currentTime=Math.min(savedTime,audio.duration||savedTime);savedTime=0;}});
    audio.addEventListener('timeupdate',function(){refresh();if(Date.now()-lastSaved>5000){lastSaved=Date.now();save();}});
    if(navigator.mediaSession){
      [['play',play],['pause',function(){audio.pause();}],['previoustrack',function(){step(-1);}],['nexttrack',function(){step(1);}],['seekto',function(d){audio.currentTime=d.seekTime;}],['seekbackward',function(d){audio.currentTime=Math.max(0,audio.currentTime-(d.seekOffset||10));}],['seekforward',function(d){audio.currentTime=Math.min(audio.duration||Infinity,audio.currentTime+(d.seekOffset||10));}]].forEach(function(pair){try{navigator.mediaSession.setActionHandler(pair[0],pair[1]);}catch(_){}});
    }
    syncMode();
  }
  function syncMode(){var text=mode==='one'?'单曲循环':mode==='shuffle'?'随机播放':'顺序播放';modeButton.textContent=text;modeButton.setAttribute('aria-label','播放模式：'+text);}
  function ensureFrame(){
    if(frame)return;
    var scroll=document.getElementById('main-scroll'),position=scroll?scroll.scrollTop:scrollY;
    window.dispatchEvent(new Event('museum:page-suspend'));window.orgMuseumReadingSuspended=true;
    frame=el('iframe','museum-site-frame');frame.id='museum-site-frame';frame.title='笔记内容';frame.allow='fullscreen; picture-in-picture';
    frame.addEventListener('load',function(){
      try{
        var doc=frame.contentDocument,win=frame.contentWindow;if(!doc||win.location.origin!==location.origin)return;
        if(win.location.href!==location.href)history.replaceState(history.state,'',win.location.href);
        document.title=doc.title;add(tracks(doc,win.location.href));
        if(position!==null){var sc=doc.getElementById('main-scroll');if(sc)sc.scrollTop=position;else win.scrollTo(0,position);position=null;}
        var theme=doc.documentElement.getAttribute('data-theme');if(theme)document.documentElement.setAttribute('data-theme',theme);
        doc.addEventListener('click',function(e){var a=e.target.closest('a[href]');if(!a||a.hasAttribute('download')||a.target||e.ctrlKey||e.metaKey||e.shiftKey)return;var u=new URL(a.href);if(/^https?:$/.test(u.protocol)&&u.origin!==location.origin)a.target='_top';else if(u.origin===location.origin&&!/(?:\.html?|\/)$/i.test(u.pathname)&&u.hash!=='#')a.target='_blank';},true);
      }catch(_){notice.textContent='当前页面无法嵌入，可在新标签页打开原链接。';}
    });
    frame.src=location.href;root.prepend(frame);document.documentElement.classList.add('museum-player-host');
  }
  function syncLocation(win){try{if(frame&&win===frame.contentWindow&&win.location.origin===location.origin&&location.href!==win.location.href)history.replaceState(history.state,'',win.location.href);}catch(_){} }
  function connect(win){clients.add(win);syncLocation(win);refresh();}
  var api={toggle:toggle,add:add,state:state,refresh:refresh,connect:connect,syncLocation:syncLocation};
  try{
    if(window.parent!==window){
      if(window.frameElement?.id!=='museum-site-frame'||!window.parent.orgMuseumPlayer)return;
      api=window.parent.orgMuseumPlayer;window.orgMuseumPlayer=api;api.connect(window);
      window.addEventListener('museum-player-state',function(){var s=api.state();current=s.track;audio={paused:s.paused};inline(document);});
      ['pushState','replaceState'].forEach(function(name){var original=history[name];history[name]=function(){var value=original.apply(history,arguments);api.syncLocation(window);return value;};});
      window.addEventListener('hashchange',function(){api.syncLocation(window);});
      window.addEventListener('popstate',function(){api.syncLocation(window);});
      function ready(){api.add(tracks(document,location.href));api.refresh();}
      if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',ready,{once:true});else ready();
      return;
    }
  }catch(_){return;}
  window.orgMuseumPlayer=api;
  function loadCatalog(){
    if(catalogLoaded)return;catalogLoaded=true;
    fetch(new URL('resources/org-museum-related-data.js',rootURL)).then(function(r){if(!r.ok)throw Error('catalog');return r.text();}).then(function(text){
      var data=JSON.parse(text.slice(text.indexOf('=')+1).trim().replace(/;$/,''));
      (data.pages||[]).forEach(function(page){var blocks=(page.contentHtml||'').match(/<audio\b[^>]*>[\s\S]*?<\/audio>/gi);if(!blocks)return;var doc=new DOMParser().parseFromString(blocks.join(''),'text/html');var list=Array.from(doc.querySelectorAll('audio')).filter(function(a){return a.getAttribute('src')||a.querySelector('source[src]');}).map(function(a){return {src:new URL(a.getAttribute('src')||a.querySelector('source').getAttribute('src'),rootURL).href,title:a.getAttribute('aria-label')||page.title,page:new URL(page.href,rootURL).href};});add(list);});save();refresh();
    }).catch(function(){if(notice)notice.textContent='暂时无法读取全站音频，已发现的歌曲仍可播放。';});
  }
  function ready(){
    add(tracks(document,location.href));inline(document);
    try{
      var saved=JSON.parse(sessionStorage.getItem(KEY)||'null');
      if(saved){add(saved.queue||[]);mode=['order','one','shuffle'].includes(saved.mode)?saved.mode:'order';current=queue.find(function(t){return t.src===saved.current;})||null;savedTime=Math.max(0,Number(saved.time)||0);closed=!!saved.closed;
        if(current&&!closed){create();audio.src=current.src;audio.volume=Math.max(0,Math.min(1,Number(saved.volume)||0));audio.muted=!!saved.muted;audio.playbackRate=[0.5,0.75,1,1.25,1.5,2].includes(saved.rate)?saved.rate:1;dialog.querySelector('.museum-audio-title').textContent=current.title;sourceLink.href=current.src;sourcePage.href=current.page;renderQueue();document.documentElement.classList.add('museum-player-reserved');notice.textContent='已恢复上次队列，点击播放继续。';refresh();}
      }
    }catch(_){}
  }
  window.addEventListener('museum-player-ui-ready',refresh);
  window.addEventListener('pagehide',save);
  window.addEventListener('storage',function(e){if(e.key==='org-museum-player-owner'&&e.newValue&&!e.newValue.startsWith(owner+':')&&audio&&!audio.paused){audio.pause();notice.textContent='已在另一个标签页播放，此处暂停。';}});
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',ready,{once:true});else ready();
})();
