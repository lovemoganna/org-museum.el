(function () {
  "use strict";

  var parser = typeof window.markdownit === "function" ? window.markdownit({
    html: false,
    linkify: true,
    breaks: true
  }) : null;

  if (parser) {
    ["heading_open", "heading_close"].forEach(function (type) {
      parser.renderer.rules[type] = function (tokens, index) {
        var token = tokens[index];
        var level = Math.min(6, Number(token.tag.slice(1)) + 2);
        return token.nesting > 0 ? "<h" + level + ">" : "</h" + level + ">\n";
      };
    });
    parser.renderer.rules.image = function (tokens, index) {
      return '<span class="museum-md-image-alt">图片：' +
        parser.utils.escapeHtml(tokens[index].content || "") + '</span>';
    };
  }

  function stablePrefix(source) {
    var lines = String(source || "").split("\n");
    var fence = null;
    var boundary = 0;
    var position = 0;
    lines.forEach(function (line, index) {
      var marker = /^\s{0,3}(`{3,}|~{3,})/.exec(line);
      if (marker) {
        if (!fence) fence = { char: marker[1][0], length: marker[1].length };
        else if (marker[1][0] === fence.char && marker[1].length >= fence.length) fence = null;
      }
      position += line.length + (index < lines.length - 1 ? 1 : 0);
      if (!fence && line.trim() === "") boundary = position;
    });
    return String(source || "").slice(0, boundary);
  }

  function render(node, source, streaming) {
    if (!node) return;
    node.classList.add("museum-md");
    if (!parser) {
      node.textContent = "排版组件未加载，请刷新页面。";
      return;
    }
    var text = streaming ? stablePrefix(source) : String(source || "");
    node.innerHTML = parser.render(text);
    node.setAttribute("data-ai-rendered", "");
    if (streaming) {
      var progress = document.createElement("p");
      progress.className = "museum-md-progress";
      progress.textContent = "正在生成…";
      node.appendChild(progress);
    }
  }

  function renderDocument() {
    document.querySelectorAll("[data-ai-markdown]:not([data-ai-rendered])").forEach(function (node) {
      render(node, node.textContent);
    });
  }

  window.orgMuseumMarkdown = {
    render: render, renderDocument: renderDocument, stablePrefix: stablePrefix
  };
})();
