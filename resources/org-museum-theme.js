(function () {
  "use strict";

  var key = "org-museum-theme";

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
    return value === "light" || value === "dark";
  }

  function normalize(value) {
    return isTheme(value) ? value : "light";
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
      return "light";
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
  }

  function currentTheme() {
    return normalize(document.documentElement.dataset.theme);
  }

  function applyTheme(value, persist) {
    var theme = normalize(value);
    document.documentElement.dataset.theme = theme;
    document.documentElement.style.colorScheme = theme;
    var meta = document.querySelector('meta[name="color-scheme"]');
    if (meta) meta.setAttribute("content", theme);
    updateControls(theme);
    if (persist) {
      try {
        localStorage.setItem(key, theme);
      } catch (_error) {}
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
      return url.href;
    } catch (_error) {
      return href;
    }
  }

  window.orgMuseumThemeUrl = themeUrl;

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

  function bindControls() {
    updateControls(normalize(document.documentElement.dataset.theme));
    document.querySelectorAll("[data-theme-toggle]").forEach(function (button) {
      button.addEventListener("click", function () {
        var current = normalize(document.documentElement.dataset.theme);
        applyTheme(current === "light" ? "dark" : "light", true);
      });
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
})();
