(function () {
  "use strict";

  var key = "org-museum-theme";

  function normalize(value) {
    return value === "light" || value === "dark" ? value : "dark";
  }

  function readThemeFromUrl() {
    try {
      var value = new URL(location.href).searchParams.get(key);
      return value === "light" || value === "dark" ? value : null;
    } catch (_error) {
      return null;
    }
  }

  function readStoredTheme() {
    try {
      return normalize(localStorage.getItem(key));
    } catch (_error) {
      return "dark";
    }
  }

  function updateControls(theme) {
    var light = theme === "light";
    document.querySelectorAll("[data-theme-toggle]").forEach(function (button) {
      button.setAttribute("aria-pressed", light ? "true" : "false");
      button.setAttribute("aria-label", light ? "切换为深色主题" : "切换为浅色主题");
      var label = button.querySelector("[data-theme-label]");
      var icon = button.querySelector("[data-theme-icon]");
      if (label) label.textContent = light ? "深色" : "浅色";
      if (icon) icon.textContent = light ? "☾" : "☀";
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

  function carryThemeToLocalPage(event) {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey ||
        event.ctrlKey || event.shiftKey || event.altKey) return;
    var link = event.target.closest && event.target.closest("a[href]");
    if (!link || link.hasAttribute("download") || link.target) return;
    var rawHref = link.getAttribute("href");
    if (!rawHref || rawHref.charAt(0) === "#") return;
    try {
      var url = new URL(link.href, location.href);
      if (!/\.html$/i.test(url.pathname) || url.protocol !== location.protocol) return;
      if (url.protocol !== "file:" && url.origin !== location.origin) return;
      url.searchParams.set(key, currentTheme());
      link.href = url.href;
    } catch (_error) {}
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
