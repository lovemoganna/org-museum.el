(function () {
  "use strict";

  var key = "org-museum-theme";

  function normalize(value) {
    return value === "light" || value === "dark" ? value : "dark";
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

  applyTheme(readStoredTheme(), false);

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

  window.addEventListener("storage", function (event) {
    if (event.key === key) applyTheme(event.newValue, false);
  });
})();
