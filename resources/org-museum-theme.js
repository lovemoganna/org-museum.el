(function () {
  "use strict";

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
    document.querySelectorAll("[data-theme-toggle]").forEach(function (button) {
      button.setAttribute("aria-label", light ? "切换为深色主题" : "切换为浅色主题");
      var label = button.querySelector("[data-theme-label]");
      var icon = button.querySelector("[data-theme-icon]");
      if (label) label.textContent = light ? "深色" : "浅色";
      if (icon) icon.dataset.themeIcon = light ? "moon" : "sun";
    });
    document.querySelectorAll("[data-theme-system]").forEach(function (button) {
      button.setAttribute("aria-pressed", document.documentElement.dataset.themePreference === "system" ? "true" : "false");
    });
    document.querySelectorAll("[data-theme-current]").forEach(function (label) {
      label.textContent = (document.documentElement.dataset.themePreference === "system" ? "系统 · " : "") + (light ? "浅色" : "深色");
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
      "focus", "view", "source", "target", "mode"].forEach(function (name) {
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
          updateStatus("error", "连接失败：" + (err.name === "AbortError" ? "加载已取消或超时" : err.message));
        } finally {
          clearTimeout(timer); loading = null;
          loadBtn.disabled = false;
          if (cancelBtn) cancelBtn.hidden = true;
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

  function bindControls() {
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
      menu.addEventListener("keydown", function (event) {
        if (event.key === "Escape") { menu.open = false; menu.querySelector("summary").focus(); }
      });
      bindSettingsTabs(menu);
      bindGlobalAiSettings(menu);
    });
  }

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
