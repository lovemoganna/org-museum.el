(function () {
  "use strict";

  function one(selector, root) { return (root || document).querySelector(selector); }
  function all(selector, root) { return Array.from((root || document).querySelectorAll(selector)); }
  function put(node, value) { if (node) node.textContent = value == null ? "" : String(value); }
  function statusLabel(value) {
    return ({dirty:"待分析", queued:"已排队", running:"分析中", done:"已完成",
      failed:"失败", stale:"结果已过期", "pending-model":"等待模型",
      "ai-inference":"待验证", accepted:"已确认", rejected:"已否决",
      verified:"已验证", cancelled:"已取消"})[value] || value || "未知状态";
  }
  function modeLabel(value) {
    return ({manual:"手动", assist:"辅助", auto:"自动"})[value] || value;
  }
  function relationLabel(value) {
    return ({related:"相关", supports:"支持", contradicts:"矛盾",
      "depends-on":"依赖", "applies-to":"适用", influences:"启发影响",
      "part-of":"属于"})[value] || value || "";
  }
  function markdown(node, value, streaming) {
    if (window.orgMuseumMarkdown) window.orgMuseumMarkdown.render(node, value, streaming);
    else put(node, "排版组件未加载，请刷新页面。");
  }
  function api(route, payload) {
    if (typeof window.orgMuseumAiApi !== "function")
      return Promise.reject(new Error("请从 Emacs 启动 AI 中心本机服务。"));
    return window.orgMuseumAiApi(route, payload);
  }
  function browserMode() { return document.querySelector('.museum-ai-center-shell')?.dataset.aiChannel === 'browser'; }
  function article() {
    var trigger = one("[data-ai-toggle]");
    var panel = one("#museum-ai-panel");
    var toc = one("#org-museum-right-sidebar");
    if (!panel) return;
    var articleNode = one(".article-container");
    var pageId = articleNode && articleNode.dataset.pageId;
    var noteTitle = (articleNode && (articleNode.dataset.pageTitle || one("h1", articleNode)?.textContent)) || document.title;
    var center = one("[data-ai-center-link]", panel);
    var nav = one(".museum-nav-ai");
    if (center && (!center.getAttribute("href") || center.getAttribute("href") === "#") && nav) {
      center.href = nav.href + (pageId ? "?pageId=" + encodeURIComponent(pageId) : "");
    }

    var isMac = typeof navigator !== "undefined" && /(Mac|iPhone|iPod|iPad)/i.test(navigator.platform || "");
    var shortcutText = isMac ? "⌘I" : "Ctrl+I";
    var shortcutEl = trigger && one("[data-ai-trigger-shortcut]", trigger);
    if (shortcutEl) shortcutEl.textContent = shortcutText;
    var composerHint = one(".museum-ai-composer-hint", panel);
    if (composerHint) {
      composerHint.innerHTML = "<kbd>" + (isMac ? "⌘Enter" : "Ctrl+Enter") + "</kbd> 发送";
    }

    var triggerDot = trigger && one("[data-ai-trigger-dot]", trigger);
    var statusDot = one("[data-ai-status-dot]", panel);
    var analyzeBtn = one("[data-ai-analyze]", panel);
    var analyzeLabel = one("[data-ai-analyze-label]", panel);
    var contextTitleEl = one("[data-ai-context-title]", panel);
    if (contextTitleEl) contextTitleEl.textContent = noteTitle;

    var chatTurns = one("[data-ai-chat-turns]", panel);
    var chatForm = one("[data-ai-chat-form]", panel);
    var chatInput = one("[data-ai-chat-input]", panel);
    var chatSend = one("[data-ai-chat-send]", panel);
    var chatStop = one("[data-ai-chat-stop]", panel);
    var exploreChips = one("[data-ai-explore-chips]", panel);
    var newChatBtn = one("[data-copilot-new]", panel);
    var engineBadge = one("[data-ai-engine-badge]", panel);
    var modelSelect = one("[data-copilot-model-select]", panel);

    var savedConfig = { provider: "compatible", endpoint: "http://127.0.0.1:1234/v1", model: "" };
    try {
      var loaded = JSON.parse(localStorage.getItem("org-museum-browser-model") || "{}");
      if (loaded && typeof loaded === "object") {
        if (loaded.provider) savedConfig.provider = loaded.provider;
        if (loaded.endpoint) savedConfig.endpoint = loaded.endpoint;
        if (loaded.model) savedConfig.model = loaded.model;
        if (loaded.system) savedConfig.system = loaded.system;
      }
    } catch (_) {}

    function getApiKey() {
      if (savedConfig.key) return savedConfig.key;
      var keyEl = document.querySelector('.museum-settings-menu [name="key"]');
      return (keyEl && keyEl.value.trim()) || "";
    }

    function openGlobalAiSettings() {
      var menu = document.querySelector(".museum-settings-menu");
      if (menu) {
        menu.open = true;
        var aiTab = menu.querySelector('[data-settings-tab="ai"]');
        if (aiTab) aiTab.click();
        var input = menu.querySelector('[name="model"]') || menu.querySelector('[name="endpoint"]') || menu.querySelector("input");
        if (input) input.focus();
      }
    }

    function populateCopilotModels(models, currentVal) {
      if (!modelSelect) return;
      modelSelect.replaceChildren();
      var list = Array.isArray(models) ? models.slice() : [];
      if (typeof window.orgMuseumAiApi === "function" && !list.includes("emacs-backend")) {
        list.unshift("emacs-backend");
      }
      if (!list.length) {
        var placeholderOpt = document.createElement("option");
        placeholderOpt.value = currentVal || "";
        placeholderOpt.textContent = currentVal || "选择模型…";
        modelSelect.appendChild(placeholderOpt);
        return;
      }
      list.forEach(function (m) {
        var opt = document.createElement("option");
        opt.value = m;
        opt.textContent = m === "emacs-backend" ? "Emacs 后端" : m;
        modelSelect.appendChild(opt);
      });
      if (currentVal && !list.includes(currentVal)) {
        var customOpt = document.createElement("option");
        customOpt.value = currentVal;
        customOpt.textContent = currentVal;
        modelSelect.appendChild(customOpt);
      }
      modelSelect.value = currentVal || (list[0] || "");
    }

    function updateBadgeModel(modelName) {
      if (engineBadge && !engineBadge.classList.contains("is-generating")) {
        if (modelName) {
          engineBadge.textContent = modelName;
          engineBadge.title = "当前使用模型: " + modelName + " (点击打开全局设置)";
        } else {
          engineBadge.textContent = "未选模型";
          engineBadge.title = "尚未选择 AI 模型 (点击打开全局设置)";
        }
      }
      if (modelSelect) {
        if (modelName) {
          var hasOpt = Array.from(modelSelect.options).some(function (o) { return o.value === modelName; });
          if (!hasOpt) {
            var opt = document.createElement("option");
            opt.value = modelName;
            opt.textContent = modelName === "emacs-backend" ? "Emacs 后端" : modelName;
            modelSelect.appendChild(opt);
          }
          modelSelect.value = modelName;
        } else {
          modelSelect.value = "";
        }
      }
    }

    var cachedModels = [];
    try { cachedModels = JSON.parse(localStorage.getItem("org-museum-browser-models-list") || "[]"); } catch (_) {}
    populateCopilotModels(cachedModels, savedConfig.model);

    if (modelSelect) {
      modelSelect.addEventListener("change", function () {
        var chosenModel = modelSelect.value;
        if (!chosenModel) return;
        savedConfig.model = chosenModel;
        try {
          var persist = JSON.parse(localStorage.getItem("org-museum-browser-model") || "{}");
          persist.model = chosenModel;
          localStorage.setItem("org-museum-browser-model", JSON.stringify(persist));
        } catch (_) {}
        updateBadgeModel(chosenModel);
        updateStateVisual("done", "模型就绪 · " + (chosenModel === "emacs-backend" ? "Emacs 后端" : chosenModel));
        try {
          var evt = new CustomEvent("org-museum-model-changed", { detail: Object.assign({}, savedConfig, { model: chosenModel }) });
          if (typeof window !== "undefined" && typeof window.dispatchEvent === "function") window.dispatchEvent(evt);
          if (typeof document !== "undefined" && typeof document.dispatchEvent === "function") document.dispatchEvent(evt);
        } catch (_) {}
      });
    }

    if (engineBadge) {
      engineBadge.addEventListener("click", function () {
        openGlobalAiSettings();
      });
      engineBadge.addEventListener("keydown", function (e) {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          openGlobalAiSettings();
        }
      });
    }

    var handleModelChanged = function (event) {
      if (event && event.detail && typeof event.detail === "object") {
        if (event.detail.model !== undefined) {
          savedConfig.model = event.detail.model;
          updateBadgeModel(event.detail.model === "emacs-backend" ? "Emacs 后端" : (event.detail.model || ""));
        }
        if (event.detail.provider) {
          savedConfig.provider = event.detail.provider;
        }
        if (event.detail.endpoint) {
          savedConfig.endpoint = event.detail.endpoint;
        }
        if (event.detail.key !== undefined) {
          savedConfig.key = event.detail.key;
        }
        if (event.detail.system !== undefined) {
          savedConfig.system = event.detail.system;
        }
        try {
          var latestList = JSON.parse(localStorage.getItem("org-museum-browser-models-list") || "[]");
          if (latestList.length && modelSelect && modelSelect.options.length <= 1) {
            populateCopilotModels(latestList, savedConfig.model);
          }
        } catch (_) {}
      }
    };
    if (typeof window !== "undefined" && typeof window.addEventListener === "function") {
      window.addEventListener("org-museum-model-changed", handleModelChanged);
    } else if (typeof document !== "undefined" && typeof document.addEventListener === "function") {
      document.addEventListener("org-museum-model-changed", handleModelChanged);
    }

    updateBadgeModel(savedConfig.model);

    var fallbackBrowserAi = {
      base: function (config) {
        var url = new URL(config.endpoint);
        if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
          throw new Error("请输入不包含账号密码的 HTTP 或 HTTPS 服务地址。");
        }
        url.hash = ""; url.search = "";
        var href = url.href.replace(/\/$/, "").replace(/\/(chat\/completions|models|api\/chat|api\/tags)$/, "");
        if (config.provider === "ollama") {
          href = href.replace(/\/v1$/, "");
        } else if (!href.endsWith("/v1")) {
          href += "/v1";
        }
        return href;
      },
      models: async function (config, signal) {
        var isOllama = config.provider === "ollama";
        var base = this.base(config);
        var url = base + (isOllama ? "/api/tags" : "/models");
        var headers = { "Content-Type": "application/json" };
        if (config.key) headers.Authorization = "Bearer " + config.key;
        var res = await fetch(url, { headers: headers, signal: signal, credentials: "omit" });
        if (!res.ok) throw new Error("HTTP " + res.status + " " + res.statusText);
        var data = await res.json();
        return (isOllama ? data.models || [] : data.data || data.models || [])
          .map(function (item) { return item.id || item.name || item.model; }).filter(Boolean);
      },
      chat: async function (config, messages, onChunk, signal) {
        var isOllama = config.provider === "ollama";
        var base = this.base(config);
        var url = base + (isOllama ? "/api/chat" : "/chat/completions");
        var headers = { "Content-Type": "application/json" };
        if (config.key) headers.Authorization = "Bearer " + config.key;
        var res = await fetch(url, {
          method: "POST",
          headers: headers,
          credentials: "omit",
          signal: signal,
          body: JSON.stringify({ model: config.model, messages: messages, stream: true })
        });
        if (!res.ok) {
          var errText = "";
          try { errText = await res.text(); } catch (_) {}
          throw new Error("HTTP " + res.status + (errText ? ": " + errText.slice(0, 200) : ""));
        }
        var answer = "";
        if (!res.body || (res.headers.get("content-type") || "").includes("application/json")) {
          var json = await res.json();
          var choice = (json.choices || [])[0];
          answer = isOllama ? (json.message && json.message.content) || "" : (choice && (choice.delta || choice.message || {}).content) || "";
          if (answer) onChunk(answer);
          return answer;
        }
        var reader = res.body.getReader(), decoder = new TextDecoder(), buffer = "";
        try {
          while (true) {
            var r = await reader.read();
            if (r.done) break;
            buffer += decoder.decode(r.value || new Uint8Array(), { stream: true });
            var end;
            while ((end = buffer.indexOf("\n")) !== -1) {
              var line = buffer.slice(0, end).replace(/\r$/, "");
              buffer = buffer.slice(end + 1);
              if (isOllama) {
                if (line.trim()) {
                  try {
                    var parsedOllama = JSON.parse(line);
                    if (parsedOllama.message && parsedOllama.message.content) {
                      answer += parsedOllama.message.content;
                      onChunk(answer);
                    }
                  } catch (_) {}
                }
              } else {
                if (line.startsWith("data:")) {
                  var dataStr = line.slice(5).trim();
                  if (dataStr === "[DONE]") continue;
                  try {
                    var parsed = JSON.parse(dataStr);
                    var delta = (parsed.choices && parsed.choices[0] && parsed.choices[0].delta && parsed.choices[0].delta.content) || "";
                    if (delta) {
                      answer += delta;
                      onChunk(answer);
                    }
                  } catch (_) {}
                }
              }
            }
          }
        } finally {
          reader.releaseLock();
        }
        if (!answer.trim()) throw new Error("模型没有返回正文，请检查所选模型的聊天能力。");
        return answer;
      }
    };

    function getBrowserAi() {
      if (window.orgMuseumBrowserAi && typeof window.orgMuseumBrowserAi.models === "function") {
        return window.orgMuseumBrowserAi;
      }
      return fallbackBrowserAi;
    }



    var messages = [];
    var storageKey = "org-museum-copilot-" + (pageId || "current");
    try {
      var saved = sessionStorage.getItem(storageKey);
      if (saved) messages = JSON.parse(saved);
    } catch (_) {}

    function persistMessages() {
      try {
        sessionStorage.setItem(storageKey, JSON.stringify(messages));
      } catch (_) {}
    }

    function triggerAnalysis() {
      if (chatInput) {
        chatInput.value = "请对当前笔记进行结构化深度分析，提炼核心论点、论证逻辑与可复用结论。";
        sendCurrentMessage();
      }
    }

    var defaultPrompts = [
      "提炼这篇笔记的核心要点",
      "梳理本文论证逻辑与依据",
      "提取可复用的方法与结论",
      "指出潜在疑问与补充视角"
    ];

    function setupExploreChips() {
      if (!exploreChips) return;
      exploreChips.replaceChildren();

      var analyzeChip = document.createElement("button");
      analyzeChip.type = "button";
      analyzeChip.className = "museum-ai-chip museum-ai-chip-analyze";
      analyzeChip.setAttribute("data-ai-analyze", "");
      analyzeChip.title = "生成或刷新当前笔记结构化分析";
      var analyzeIcon = document.createElement("span");
      analyzeIcon.className = "museum-ai-btn-icon";
      analyzeIcon.setAttribute("aria-hidden", "true");
      var analyzeLabelEl = document.createElement("span");
      analyzeLabelEl.setAttribute("data-ai-analyze-label", "");
      analyzeLabelEl.textContent = "重新分析笔记";
      analyzeChip.appendChild(analyzeIcon);
      analyzeChip.appendChild(analyzeLabelEl);
      analyzeChip.addEventListener("click", triggerAnalysis);
      exploreChips.appendChild(analyzeChip);
      analyzeBtn = analyzeChip;
      analyzeLabel = analyzeLabelEl;

      defaultPrompts.forEach(function (prompt) {
        var chip = document.createElement("button");
        chip.type = "button";
        chip.className = "museum-ai-chip";
        chip.textContent = prompt;
        chip.addEventListener("click", function () {
          if (chatInput) {
            chatInput.value = prompt;
            sendCurrentMessage();
          }
        });
        exploreChips.appendChild(chip);
      });
    }

    setupExploreChips();

    function renderChat() {
      if (!chatTurns) return;
      if (panel && panel.classList) {
        panel.classList.toggle("has-messages", Boolean(messages && messages.length > 0));
      }
      chatTurns.replaceChildren();
      if (!messages || messages.length === 0) {
        var empty = document.createElement("div");
        empty.className = "museum-ai-empty-chat";
        var heroTitle = document.createElement("h3");
        heroTitle.textContent = "与 AI 讨论这篇笔记";
        var heroDesc = document.createElement("p");
        heroDesc.textContent = "随时提问、探讨细节或提炼结论。可直接点击下方探索建议，或在底栏输入问题。";
        empty.append(heroTitle, heroDesc);
        chatTurns.appendChild(empty);
        return;
      }
      messages.forEach(function (msg) {
        var wrap = document.createElement("div");
        wrap.className = "museum-ai-message " + (msg.role === "user" ? "is-user" : "is-assistant");
        if (msg.isStreaming) wrap.classList.add("is-streaming");

        var head = document.createElement("div");
        head.className = "museum-ai-message-header";
        var author = document.createElement("span");
        author.textContent = (msg.role === "user" ? "你" : "Copilot") + (msg.time ? " · " + msg.time : "");
        head.appendChild(author);

        if (msg.role === "assistant" && !msg.isStreaming && msg.content) {
          var copyBtn = document.createElement("button");
          copyBtn.type = "button";
          copyBtn.className = "museum-ai-copy-btn";
          copyBtn.textContent = "复制";
          copyBtn.addEventListener("click", function () {
            if (navigator.clipboard) {
              navigator.clipboard.writeText(msg.content);
              copyBtn.textContent = "已复制";
              setTimeout(function () { copyBtn.textContent = "复制"; }, 1500);
            }
          });
          head.appendChild(copyBtn);
        }
        wrap.appendChild(head);

        var bubble = document.createElement("div");
        bubble.className = "museum-ai-message-bubble";
        if (msg.isStreaming) {
          bubble.classList.add("is-streaming");
          bubble.setAttribute("data-copilot-streaming-bubble", "");
        }

        if (msg.isStreaming && !msg.content) {
          bubble.innerHTML = '<div class="museum-ai-thinking"><span class="museum-ai-spinner" aria-hidden="true"></span> <span>正在思考与整理回答…</span></div>';
        } else {
          markdown(bubble, msg.content, false);
          if (msg.isStreaming) {
            var cursor = document.createElement("span");
            cursor.className = "museum-ai-streaming-cursor";
            cursor.setAttribute("aria-hidden", "true");
            var lastChild = bubble.lastElementChild;
            if (lastChild && (lastChild.tagName === "P" || lastChild.tagName === "LI")) {
              lastChild.appendChild(cursor);
            } else {
              bubble.appendChild(cursor);
            }
          }
        }
        wrap.appendChild(bubble);
        chatTurns.appendChild(wrap);
      });
      chatTurns.scrollTop = chatTurns.scrollHeight;
    }

    function updateStreamingBubble(text) {
      if (!chatTurns) return;
      var streamingBubble = chatTurns.querySelector("[data-copilot-streaming-bubble]");
      if (!streamingBubble) {
        renderChat();
        return;
      }
      if (!text) {
        streamingBubble.innerHTML = '<div class="museum-ai-thinking"><span class="museum-ai-spinner" aria-hidden="true"></span> <span>正在思考与整理回答…</span></div>';
      } else {
        markdown(streamingBubble, text, false);
        var cursor = document.createElement("span");
        cursor.className = "museum-ai-streaming-cursor";
        cursor.setAttribute("aria-hidden", "true");
        var lastChild = streamingBubble.lastElementChild;
        if (lastChild && (lastChild.tagName === "P" || lastChild.tagName === "LI")) {
          lastChild.appendChild(cursor);
        } else {
          streamingBubble.appendChild(cursor);
        }
      }
      var threshold = 120;
      var isNearBottom = chatTurns.scrollHeight - chatTurns.scrollTop - chatTurns.clientHeight <= threshold;
      if (isNearBottom) {
        chatTurns.scrollTop = chatTurns.scrollHeight;
      }
    }

    var activeAbortController = null;
    function setGenerating(isGen) {
      if (chatSend) chatSend.hidden = isGen;
      if (chatStop) chatStop.hidden = !isGen;
      if (chatInput) chatInput.disabled = isGen;
      if (modelSelect) modelSelect.disabled = isGen;
      if (engineBadge) {
        engineBadge.textContent = isGen ? "生成中…" : (savedConfig.model || "讨论模式");
        engineBadge.classList.toggle("is-generating", isGen);
      }
    }

    function sendCurrentMessage() {
      if (!chatInput) return;
      var text = chatInput.value.trim();
      if (!text) return;
      chatInput.value = "";
      chatInput.style.height = "auto";

      var now = new Date();
      var timeStr = ("0" + now.getHours()).slice(-2) + ":" + ("0" + now.getMinutes()).slice(-2);
      messages.push({ role: "user", content: text, time: timeStr });
      var assistantMsg = { role: "assistant", content: "", isStreaming: true, time: timeStr };
      messages.push(assistantMsg);
      persistMessages();
      renderChat();
      setGenerating(true);

      var activeModel = savedConfig.model;
      if (!activeModel) {
        setTimeout(function () {
          assistantMsg.content = "尚未配置 AI 模型。\n\n请点击右上角「设置」按钮配置本地模型服务与模型。";
          assistantMsg.isStreaming = false;
          setGenerating(false);
          persistMessages();
          renderChat();
          openGlobalAiSettings();
        }, 200);
        return;
      }

      var articleText = (articleNode ? (articleNode.innerText || articleNode.textContent) : "").slice(0, 16000);
      var systemPrompt = (savedConfig && savedConfig.system ? savedConfig.system : "你是一个深度阅读与知识复盘助手。") +
        "\n\n【当前阅读笔记】\n标题：" + noteTitle + "\n内容：\n" + articleText;

      var aiClient = getBrowserAi();
      if (activeModel !== "emacs-backend" && aiClient && savedConfig.endpoint) {
        var inferenceConfig = Object.assign({}, savedConfig, {
          model: activeModel,
          key: getApiKey()
        });
        var chatHistory = [{ role: "system", content: systemPrompt }];
        messages.slice(0, -1).forEach(function (m) {
          chatHistory.push({ role: m.role, content: m.content });
        });
        var controller = new AbortController();
        activeAbortController = controller;
        aiClient.chat(inferenceConfig, chatHistory, function (chunk) {
          assistantMsg.content = chunk;
          updateStreamingBubble(chunk);
        }, controller.signal).then(function (finalText) {
          assistantMsg.content = finalText;
          assistantMsg.isStreaming = false;
          setGenerating(false);
          activeAbortController = null;
          persistMessages();
          renderChat();
        }).catch(function (err) {
          if (err.name === "AbortError" || err.message === "已停止生成") {
            assistantMsg.content = (assistantMsg.content || "") + "\n\n*(已停止生成)*";
          } else {
            var msg = err.message || "";
            if (err.name === "TypeError" || msg === "Failed to fetch" || msg.includes("NetworkError")) {
              msg = "无法连接到模型服务 (" + inferenceConfig.endpoint + ")。\n\n请确认：\n1. 本地模型服务（如 LM Studio 或 Ollama）已启动；\n2. 点击右上角「设置」检查服务类型与端口设置；\n3. 若使用 LM Studio，请在 LM Studio 中启动 Local Server 并开启 CORS。";
            }
            assistantMsg.content = (assistantMsg.content || "") + "\n\n*(生成错误：" + msg + ")*";
          }
          assistantMsg.isStreaming = false;
          setGenerating(false);
          activeAbortController = null;
          persistMessages();
          renderChat();
        });
      } else if (typeof window.orgMuseumAiApi === "function") {
        api("action", { action: "chat", pageId: pageId, message: text }).then(function (res) {
          assistantMsg.content = res.answer || res.message || "已完成讨论。";
          assistantMsg.isStreaming = false;
          setGenerating(false);
          persistMessages();
          renderChat();
        }).catch(function (err) {
          assistantMsg.content = "Emacs 模型生成遇到问题：" + err.message;
          assistantMsg.isStreaming = false;
          setGenerating(false);
          persistMessages();
          renderChat();
        });
      } else {
        setTimeout(function () {
          assistantMsg.content = "当前尚未连接模型服务。\n\n请点击右上角「设置」按钮配置本地模型服务地址（如 Ollama `http://127.0.0.1:11434` 或 LM Studio `http://127.0.0.1:1234/v1`）并选择模型。";
          assistantMsg.isStreaming = false;
          setGenerating(false);
          persistMessages();
          renderChat();
          openGlobalAiSettings();
        }, 300);
      }
    }

    if (chatForm) {
      chatForm.addEventListener("submit", function (e) {
        e.preventDefault();
        sendCurrentMessage();
      });
    }
    if (chatInput) {
      chatInput.addEventListener("keydown", function (e) {
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
          e.preventDefault();
          sendCurrentMessage();
        }
      });
      chatInput.addEventListener("input", function () {
        chatInput.style.height = "auto";
        chatInput.style.height = Math.min(Math.max(chatInput.scrollHeight, 44), 140) + "px";
      });
    }
    if (chatStop) {
      chatStop.addEventListener("click", function () {
        if (activeAbortController) activeAbortController.abort();
      });
    }
    if (newChatBtn) {
      newChatBtn.addEventListener("click", function () {
        messages = [];
        persistMessages();
        renderChat();
      });
    }

    function updateStateVisual(state, statusText) {
      if (triggerDot) triggerDot.setAttribute("data-state", state);
      if (statusDot) statusDot.setAttribute("data-state", state);
      if (statusText != null) put(one("[data-ai-status]", panel), statusText);
      if (analyzeLabel) {
        if (state === "running") {
          analyzeLabel.textContent = "正在分析…";
        } else if (state === "done") {
          analyzeLabel.textContent = "重新分析";
        } else if (state === "failed") {
          analyzeLabel.textContent = "重试分析";
        } else {
          analyzeLabel.textContent = "分析笔记";
        }
      }
      if (state === "running") {
        if (analyzeBtn) {
          analyzeBtn.disabled = true;
          analyzeBtn.classList.add("is-loading");
        }
        if (trigger) trigger.setAttribute("title", "AI 分析进行中… (" + shortcutText + ")");
      } else {
        if (analyzeBtn) {
          analyzeBtn.disabled = false;
          analyzeBtn.classList.remove("is-loading");
        }
        var tip = state === "done" ? "AI 讨论与分析 (已就绪 - " + shortcutText + ")" : "打开 AI Copilot 侧边栏 (" + shortcutText + ")";
        if (trigger) trigger.setAttribute("title", tip);
      }
    }

    function setOpen(open, userAction) {
      if (open && matchMedia("(max-width: 1439px)").matches) {
        if (document.body.classList.contains("museum-toc-open")) {
          var tocClose = one("[data-toc-close]");
          if (tocClose) tocClose.click();
        }
        if (document.body.classList.contains("museum-drawer-open")) {
          var drawerClose = one("[data-drawer-close]");
          if (drawerClose) drawerClose.click();
          else {
            var drawerToggle = one("[data-drawer-toggle]");
            if (drawerToggle) drawerToggle.click();
          }
        }
      }
      document.body.classList.toggle("museum-ai-open", open);
      panel.inert = !open;
      panel.setAttribute("aria-hidden", String(!open));
      if (trigger) trigger.setAttribute("aria-expanded", String(open));
      if (userAction) {
        try { localStorage.setItem("copilot_sidebar_open", String(open)); } catch (_) {}
      }
      if (open) {
        load();
        renderChat();
        if (userAction && chatInput) {
          // Let the opening panel become visible before transferring focus.
          var focusInput = function () {
            if (document.body.classList.contains("museum-ai-open")) chatInput.focus();
          };
          // Visibility is animated for 200ms; focusing during that transition
          // can be rejected by the browser while the input is still hidden.
          setTimeout(focusInput, 220);
        }
      } else if (chatInput && document.activeElement === chatInput) {
        chatInput.blur();
      }
    }
    if (trigger) trigger.addEventListener("click", function () { setOpen(!document.body.classList.contains("museum-ai-open"), true); });

    document.addEventListener("keydown", function (event) {
      if ((event.ctrlKey || event.metaKey) && event.key && event.key.toLowerCase() === "i") {
        event.preventDefault();
        setOpen(!document.body.classList.contains("museum-ai-open"), true);
        return;
      }
      if (event.key === "Escape" && document.body.classList.contains("museum-ai-open")) {
        setOpen(false, true);
        if (trigger) trigger.focus();
      }
    });

    all("[data-toc-toggle]").forEach(function (button) {
      button.addEventListener("click", function () {
        if (matchMedia("(max-width: 1439px)").matches &&
            document.body.classList.contains("museum-ai-open")) setOpen(false, true);
      });
    });
    one("[data-ai-close]", panel).addEventListener("click", function () { setOpen(false, true); if (trigger) trigger.focus(); });
    function fillPublic() {
      var source = one(".org-museum-experience");
      var target = one("[data-ai-experiences]", panel);
      if (!target) return;
      target.replaceChildren();
      if (!source) { put(target, "暂无已确认的相关经验。"); return; }
      all(".org-museum-experience-item", source).forEach(function (item) {
        var clone = item.cloneNode(true); target.appendChild(clone);
      });
    }
    function load() {
      fillPublic();
      if (!pageId) {
        updateStateVisual("idle", "这篇笔记暂无索引 ID。");
        return;
      }
      if (typeof window.orgMuseumAiApi !== "function") {
        var activeM = savedConfig.model;
        if (activeM) {
          updateStateVisual("done", "模型就绪 · " + (activeM === "emacs-backend" ? "Emacs 后端" : activeM));
        } else {
          updateStateVisual("idle", "未配置模型");
        }
        return;
      }
      api("page?pageId=" + encodeURIComponent(pageId)).then(function (data) {
        var state = data.analysis ? "done" : data.status === "dirty" ? "dirty" :
          data.status === "failed" ? "failed" : (data.status === "running" || data.status === "queued") ? "running" : "idle";
        var label = data.analysis ? "已分析" : data.status === "dirty" ? "等待分析" :
          data.status === "failed" ? "分析失败，可重试" : (data.status === "running" || data.status === "queued") ? "分析中…" : "尚未分析";
        updateStateVisual(state, label);
        var summaryEl = one("[data-ai-summary]", panel);
        if (summaryEl) markdown(summaryEl, data.analysis ? data.analysis.summary : "暂无分析结果。");
      }).catch(function (error) {
        updateStateVisual("failed", error.message);
      });
    }

    if (pageId && typeof window.orgMuseumAiApi === "function") {
      api("page?pageId=" + encodeURIComponent(pageId)).then(function (data) {
        var state = data.analysis ? "done" : data.status === "dirty" ? "dirty" :
          data.status === "failed" ? "failed" : (data.status === "running" || data.status === "queued") ? "running" : "idle";
        var label = data.analysis ? "已分析" : data.status === "dirty" ? "等待分析" :
          data.status === "failed" ? "分析失败，可重试" : "尚未分析";
        updateStateVisual(state, label);
      }).catch(function () {});
    }


    renderChat();
    var savedOpen = null;
    try { savedOpen = localStorage.getItem("copilot_sidebar_open"); } catch (_) {}
    var shouldOpen = savedOpen === "true";
    setOpen(shouldOpen, false);
    if (toc) {
      var tocButtons = all("[data-toc-toggle]");
      var hoverTimer;
      function desktopHover() { return matchMedia("(hover: hover) and (min-width: 1440px)").matches; }
      function showToc() {
        if (desktopHover()) {
          clearTimeout(hoverTimer); document.body.classList.add("museum-toc-hover");
          tocButtons.forEach(function (button) { button.setAttribute("aria-expanded", "true"); });
        }
      }
      function hideToc() {
        if (desktopHover()) hoverTimer = setTimeout(function () {
          if (!toc.contains(document.activeElement) && !tocButtons.includes(document.activeElement))
            document.body.classList.remove("museum-toc-hover");
          if (!document.body.classList.contains("museum-toc-hover"))
            tocButtons.forEach(function (button) { button.setAttribute("aria-expanded", "false"); });
        }, 220);
      }
      tocButtons.forEach(function (button) {
        button.addEventListener("mouseenter", showToc);
        button.addEventListener("focus", showToc);
        button.addEventListener("mouseleave", hideToc);
      });
      toc.addEventListener("mouseenter", showToc);
      toc.addEventListener("mouseleave", hideToc);
      toc.addEventListener("focusin", showToc);
      toc.addEventListener("focusout", hideToc);
      document.addEventListener("keydown", function (event) {
        if (event.key === "Escape") {
          document.body.classList.remove("museum-toc-hover");
          tocButtons.forEach(function (button) { button.setAttribute("aria-expanded", "false"); });
        }
      });
    }
  }

  function center() {
    var shell = one(".museum-ai-center-shell");
    if (!shell) return;
    var connection = one("[data-ai-connection]", shell);
    var message = one("[data-ai-message]", shell);
    var page = one("[data-ai-page]", shell);
    var target = one("[data-ai-target]", shell);
    var derived = one("[data-ai-derived]", shell);
    var relation = one("[data-ai-relation]", shell);
    var publicRecords = [];
    var current = null;
    var statusTimer;
    var offline = one("[data-ai-offline]", shell);
    var guided = one("[data-ai-guided]", shell);
    var advanced = one(".museum-ai-advanced", shell);
    var requestedPageId = "";
    window.addEventListener("org-museum-ai-select-page", function (event) {
      requestedPageId = event.detail.pageId;
      if (advanced.open) refresh();
      else advanced.open = true;
    });
    function setConnected(connected) {
      offline.hidden = connected;
      guided.hidden = !connected;
      advanced.hidden = !connected;
      all("[data-ai-action], [data-ai-mode], [data-ai-page], [data-ai-target]", shell)
        .forEach(function (control) { control.disabled = !connected; });
    }
    function notify(text) { put(message, text); }
    function selection() { return page.value; }
    function value(selector) { var field = one(selector, shell); return field ? field.value.trim() : ""; }
    function showText(selector, text) {
      var node = one(selector, shell);
      if (!node) return;
      markdown(node, text || "暂无结果。");
    }
    function publicView(records) {
      var holder = one("[data-ai-public]", shell); holder.replaceChildren();
      if (!records.length) {
        var empty = document.createElement("p");
        empty.textContent = "尚无公开经验。已收录结论仍保存在本机，整理并确认后才会出现在这里。";
        var start = document.createElement("button"); start.type = "button";
        start.textContent = "从已收录结论整理";
        start.addEventListener("click", function () {
          var library = one("[data-ai-library]", shell);
          if (library) library.scrollIntoView({block:"start"});
        });
        holder.append(empty, start); return;
      }
      var groups = new Map();
      records.forEach(function (record) {
        var category = record.categoryLabel || record.category || "未分类";
        if (!groups.has(category)) groups.set(category, []);
        groups.get(category).push(record);
      });
      Array.from(groups.keys()).sort(function (a, b) { return a.localeCompare(b, "zh-CN"); })
        .forEach(function (category) {
          var section = document.createElement("section");
          section.className = "museum-ai-public-group";
          var title = document.createElement("h3");
          title.textContent = category + " · " + groups.get(category).length;
          section.appendChild(title);
          groups.get(category).forEach(function (record) {
        var card = document.createElement("article"); card.className = "museum-ai-public-item";
        var link = document.createElement("a"); link.href = record.href; link.textContent = record.title;
        var heading = document.createElement("div"); heading.className = "museum-ai-public-title";
        markdown(heading, record.problem);
        var result = document.createElement("div"); markdown(result, record.result);
        card.append(link, heading, result);
        if (record.pendingSync) { var pending = document.createElement('small'); pending.textContent = '本地已确认 · 尚未公开，待同步到 Emacs'; card.appendChild(pending); }
        if (record.wrongAttempt) {
          var wrong = document.createElement("div");
          var label = document.createElement("strong"); label.textContent = "失败尝试：";
          wrong.appendChild(label);
          var detail = document.createElement("div"); markdown(detail, record.wrongAttempt);
          wrong.appendChild(detail);
          card.appendChild(wrong);
        }
            section.appendChild(card);
          });
          holder.appendChild(section);
        });
    }
    function refreshPublic() {
      api("public").then(function (data) {
        publicRecords = data.experiences || [];
        publicView(publicRecords);
      }).catch(function () { /* Keep the exported public snapshot. */ });
    }
    try {
      publicRecords = JSON.parse(one("#museum-ai-public-data").textContent).experiences || [];
      publicView(publicRecords);
    } catch (_error) { put(one("[data-ai-public]", shell), "公开经验暂时无法读取。"); }
    setConnected(false);
    function fillOptions(select, pages, selected) {
      select.replaceChildren();
      pages.forEach(function (item) {
        var option = document.createElement("option");
        option.value = item.id; option.textContent = item.title;
        select.appendChild(option);
      });
      if (selected && pages.some(function (item) { return item.id === selected; })) select.value = selected;
    }
    function refresh() {
      api("status").then(function (data) {
        setConnected(true);
        put(connection, (browserMode() ? "浏览器本地 · " : "本机已连接 · ") + data.model + " · " + modeLabel(data.mode) +
          (data.paused ? " · 已暂停" : ""));
        var chosen = requestedPageId || selection() ||
          new URLSearchParams(location.search).get("pageId");
        var targetChosen = target.value;
        fillOptions(page, data.pages || [], chosen);
        requestedPageId = "";
        fillOptions(target, data.pages || [], targetChosen);
        var previousDerived = derived.value;
        fillOptions(derived, (data.derived || []).map(function (item) {
          return { id: item.id, title: item.task + " · " + statusLabel(item.status) +
            (item.current ? "" : " · 来源已变更") };
        }), previousDerived);
        var previousRelation = relation.value;
        fillOptions(relation, (data.relations || []).map(function (item) {
          return { id: item.id, title: item.sourcePageId + " → " + item.targetPageId +
            " · " + relationLabel(item.type) + (item.current ? "" : " · 来源已变更") };
        }), previousRelation);
        one("[data-ai-mode]", shell).value = data.mode;
        if (data.batch && data.batch.progress) {
          var bp = data.batch.progress;
          put(one("[data-ai-queue-summary]", shell),
            "批次进度：" + bp.done + "/" + bp.total +
            " 已完成，" + bp.running + " 运行中，" + bp.failed + " 失败；Worker " +
            data.workers + "/" + data.maxWorkers);
        }
        put(one("[data-ai-scan-state]", shell), data.scan || "尚未运行扫描。");
        showText("[data-ai-queue]", (data.queue || []).map(function (job) {
          return (job.title || job.pageId || "笔记") + " · " + statusLabel(job.status) +
            (job.error ? " · " + job.error : "");
        }).join("\n") || "当前队列为空。");
        if (selection()) loadPage();
        else put(one("[data-ai-queue-summary]", shell), "请先选择一篇笔记。");
      }).catch(function (error) {
        setConnected(false);
        put(connection, "当前仅可阅读公开经验。");
      });
    }
    function loadPage() {
      var selected = selection();
      if (!selected) return;
      if (!current || current.pageId !== selected) {
        current = null;
        put(one("[data-ai-queue-summary]", shell), "正在读取所选笔记…");
        showText("[data-ai-current-analysis]", "正在读取分析结果…");
      }
      api("page?pageId=" + encodeURIComponent(selected)).then(function (data) {
        if (selection() !== selected) return;
        current = data;
        var state = data.analysis ? "这篇笔记已完成分析。" :
          data.status === "running" ? "正在分析这篇笔记，请稍候；结果会自动显示。" :
          data.status === "queued" ? "这篇笔记已排队；当前任务结束后会自动开始。" :
          data.status === "dirty" ? "这篇笔记等待分析，点击“开始分析”即可处理。" :
          data.status === "failed" ? "分析失败：" + (data.error || "请重试。") :
          data.status === "stale" ? "旧任务没有可用结果，请点击“开始分析”重试。" :
          "这篇笔记尚未分析。";
        put(one("[data-ai-queue-summary]", shell), state);
        showText("[data-ai-current-analysis]", data.analysis ? data.analysis.summary :
          "此笔记尚无当前版本的分析结果。");
      }).catch(function (error) {
        if (selection() === selected) {
          put(one("[data-ai-queue-summary]", shell), "无法读取这篇笔记：" + error.message);
          showText("[data-ai-current-analysis]", "暂无分析结果。");
          notify(error.message);
        }
      });
    }
    page.addEventListener("change", loadPage);
    one("[data-ai-mode]", shell).addEventListener("change", function (event) {
      api("action", { action: "mode", mode: event.target.value }).then(refresh)
        .catch(function (error) { notify(error.message); });
    });
    function payload(action) {
      return { action: action, pageId: selection(), targetId: target.value,
        query: value("[data-ai-query]"), task: value("[data-ai-task]"),
        evidence: value("[data-ai-evidence]"), expectedHash: current && current.hash,
        derivedId: derived.value, observation: value("[data-ai-observation]") };
    }
    function preview(kind) {
      if (!current) { notify("先选择一篇笔记。 "); return; }
      var data = { kind: kind, pageId: selection(), expectedHash: current.hash,
        problem: value("[data-ai-problem]"), result: value("[data-ai-result]"),
        wrongAttempt: value("[data-ai-wrong]"), cause: value("[data-ai-cause]"),
        scope: value("[data-ai-scope]"), targetId: target.value,
        relationType: value("[data-ai-relation-type]"),
        confidence: Number(value("[data-ai-confidence]")),
        evidence: value("[data-ai-evidence]") };
      api("preview", data).then(function (result) {
        var box = one(kind === "experience" ? "[data-ai-preview]" :
          "[data-ai-advanced-preview]", shell); box.replaceChildren();
        function field(label, content, source) {
          if (content == null || content === "") return;
          var row = document.createElement("div"); row.className = "museum-ai-preview-field";
          var heading = document.createElement("strong"); heading.textContent = label;
          var body = document.createElement(source ? "pre" : "div");
          if (source) { body.className = "museum-ai-evidence"; put(body, content); }
          else markdown(body, String(content));
          row.append(heading, body); box.appendChild(row);
        }
        field("类型", result.kind === "failure" ? "失败经验" :
          result.kind === "relation" ? "笔记关系" : "可复用经验");
        field("来源笔记", result.sourceTitle);
        field("关联笔记", result.targetTitle);
        field("问题", result.problem);
        field("结果或方法", result.result);
        field("失败尝试", result.wrongAttempt);
        field("原因", result.cause);
        field("适用范围", result.scope);
        field("关系类型", relationLabel(result.relationType));
        field("置信度", result.confidence);
        field("原文依据", result.evidence, true);
        field("原文版本", result.sourceHash, true);
        var button = document.createElement("button"); button.type = "button";
        button.textContent = result.localOnly ? "确认保存到本地，待同步" : result.public ? "确认沉淀并公开" : "确认保存私有关系";
        button.addEventListener("click", function () {
          button.disabled = true;
          api("confirm", { transactionId: result.transactionId }).then(function (data) {
            notify(data.localOnly ? "已保存到浏览器本地，尚未公开；可导出或同步到 Emacs。" : "已确认保存；本站静态页面正在更新。");
            box.replaceChildren(); refreshPublic(); refresh();
          }).catch(function (error) { button.disabled = false; notify(error.message); });
        });
        box.appendChild(button);
        notify("请核对来源和内容，再明确确认。 ");
      }).catch(function (error) { notify(error.message); });
    }
    function previewRemoval() {
      if (!relation.value) { notify("当前没有可移除的私有关系。"); return; }
      api("preview-removal", { relationId: relation.value }).then(function (result) {
        var box = one("[data-ai-advanced-preview]", shell); box.replaceChildren();
        var text = document.createElement("p");
        text.textContent = result.sourcePageId + " → " + result.targetPageId + " · " + result.relationType;
        var button = document.createElement("button"); button.type = "button";
        button.textContent = "确认移除这条私有关系";
        button.addEventListener("click", function () {
          button.disabled = true;
          api("confirm-removal", { transactionId: result.transactionId }).then(function () {
            box.replaceChildren(); notify("私有关系已移除。"); refresh();
          }).catch(function (error) { button.disabled = false; notify(error.message); });
        });
        box.append(text, button); notify("请核对即将移除的关系。");
      }).catch(function (error) { notify(error.message); });
    }
    all("[data-ai-action]", shell).forEach(function (button) {
      button.addEventListener("click", function () {
        var action = button.dataset.aiAction;
        if (action.indexOf("preview-") === 0) { preview(action.slice(8)); return; }
        if (action === "remove-relation") { previewRemoval(); return; }
        if (action === "derive-accept" || action === "derive-reject" ||
            action === "derive-verify" || action === "queue-clear") {
          var question = action === "derive-accept" ? "确认这条组合结论可复用？" :
            action === "derive-reject" ? "否决这条知识组合候选？" :
            action === "derive-verify" ? "确认已保存的执行结果作为验证依据？" : "清空待分析队列？";
          if (!window.confirm(question)) return;
        }
        notify("正在处理…");
        api("action", payload(action)).then(function (data) {
          if (data.text) showText(action === "recall" || action === "relations" || action === "context" ?
            "[data-ai-recall-results]" : "[data-ai-review-results]", data.text);
          if (action.startsWith("scan")) {
            var scanState = one("[data-ai-scan-state]", shell);
            if (scanState) put(scanState, data.message || "扫描状态已更新");
          }
          notify(data.message || "操作已完成。"); refresh();
        }).catch(function (error) {
          notify(error.message);
          if (action.startsWith("scan")) {
            var scanState = one("[data-ai-scan-state]", shell);
            if (scanState) put(scanState, "扫描请求未完成：" + error.message);
          } else if (["gap", "gap-ai", "derive", "derive-review"].includes(action)) {
            showText("[data-ai-review-results]", "操作未完成：" + error.message);
          }
        });
      });
    });
    function connect() { api("catalog").then(function (data) {
      setConnected(true);
      put(connection, (browserMode() ? "浏览器本地 · " : "本机已连接 · ") + data.model);
      refreshPublic();
    }).catch(function () {
      setConnected(false);
      put(connection, "当前仅可阅读公开经验。");
    }); }
    connect();
    window.addEventListener('org-museum-ai-channel-change', function () { current = null; connect(); refresh(); });
    advanced.addEventListener("toggle", function () { if (advanced.open) refresh(); });
    statusTimer = setInterval(function () {
      if (advanced.open && document.visibilityState === "visible" &&
          typeof window.orgMuseumAiApi === "function") refresh();
    }, 5000);
    window.addEventListener("pagehide", function () { clearInterval(statusTimer); }, { once: true });
  }

  function conversation() {
    var root = one("[data-ai-conversation]");
    if (!root) return;
    var picker = one("[data-ai-picker]", root);
    var workspace = one("[data-ai-workspace]", root);
    var resume = one("[data-ai-resume]", root);
    var workerSelect = one("[data-ai-workers]", root);
    var search = one("[data-ai-search]", root);
    var list = one("[data-ai-page-list]", root);
    var selection = one("[data-ai-selection]", root);
    var status = one("[data-ai-session-status]", root);
    var turns = one("[data-ai-turns]", root);
    var turnNav = one("[data-ai-turn-nav]", root);
    var directions = one("[data-ai-directions]", root);
    var proposals = one("[data-ai-proposals]", root);
    var preview = one("[data-ai-sediment-preview]", root);
    var followup = one("[data-ai-followup]", root);
    var cancel = one("[data-ai-cancel-session]", root);
    var referenceNode = one("[data-ai-reference]", root);
    var captureSearch = one("[data-ai-capture-search]", root);
    var captureCategory = one("[data-ai-capture-category]", root);
    var sourceCategory = one("[data-ai-source-category]", root);
    var captureResults = one("[data-ai-capture-results]", root);
    var captureDetail = one("[data-ai-capture-detail]", root);
    var captureStatus = one("[data-ai-capture-status]", root);
    var captureCount = one("[data-ai-capture-count]", root);
    var pages = [], chosen = new Set(), sessionId = "", revision = -1, busy = false;
    var pendingReference = null, captureTimer = null, captureRequest = 0;
    function pageTitle(id) {
      var page = pages.find(function (item) { return item.id === id; });
      return page ? page.title : id;
    }
    function sourceLink(source) {
      var page = pages.find(function (item) { return item.id === source.pageId; });
      var href = page && page.href;
      var label = source.title || pageTitle(source.pageId);
      if (!href) { var span = document.createElement("span"); span.textContent = label; return span; }
      var link = document.createElement("a"); link.href = href; link.textContent = label;
      return link;
    }
    function readableTime(value) {
      return value ? String(value).replace("T", " ").slice(0, 16) : "旧会话未记录时间";
    }
    function errorMessage(error) { put(status, error.message || "操作失败，请重试。"); }
    function button(label, action) {
      var node = document.createElement("button");
      node.type = "button"; node.textContent = label;
      node.addEventListener("click", action);
      return node;
    }
    function choose() {
      selection.replaceChildren();
      if (!chosen.size) {
        var emptyChip = document.createElement("span");
        emptyChip.className = "museum-ai-selection-hint";
        emptyChip.textContent = "尚未选择笔记（在下方勾选参与分析的资料，最多 12 篇）";
        selection.appendChild(emptyChip);
        return;
      }
      chosen.forEach(function (id) {
        var chip = document.createElement("span"); chip.className = "museum-ai-chip";
        chip.textContent = pageTitle(id); selection.appendChild(chip);
      });
    }
    function showPages() {
      var term = search.value.trim().toLocaleLowerCase();
      list.replaceChildren();
      var groups = new Map();
      pages.filter(function (item) {
        return chosen.has(item.id) || [item.title, item.categoryLabel, item.category]
          .some(function (value) { return String(value || "").toLocaleLowerCase().includes(term); });
      }).slice(0, 80).forEach(function (item) {
        var category = item.categoryLabel || item.category || "未分类";
        if (!groups.has(category)) groups.set(category, []);
        groups.get(category).push(item);
      });
      Array.from(groups.keys()).sort(function (a, b) { return a.localeCompare(b, "zh-CN"); })
        .forEach(function (category, index) {
          var section = document.createElement("section");
          section.className = "museum-ai-page-group";
          var heading = document.createElement("h3");
          heading.id = "museum-ai-page-group-" + index;
          heading.textContent = category + " · " + groups.get(category).length;
          section.setAttribute("aria-labelledby", heading.id);
          var entries = document.createElement("div");
          entries.className = "museum-ai-page-group-items";
          groups.get(category).forEach(function (item) {
            var label = document.createElement("label");
            var input = document.createElement("input");
            input.type = "checkbox"; input.value = item.id; input.checked = chosen.has(item.id);
            input.addEventListener("change", function () {
              if (input.checked && chosen.size >= 12) {
                input.checked = false; put(status, "一次最多选择 12 篇笔记。"); return;
              }
              if (input.checked) chosen.add(item.id); else chosen.delete(item.id);
              choose();
            });
            var name = document.createElement("span"); name.textContent = item.title;
            label.append(input, name); entries.appendChild(label);
          });
          section.append(heading, entries); list.appendChild(section);
        });
      if (!list.childElementCount) put(list, "没有匹配的笔记。");
    }
    function showPicker() {
      sessionId = ""; revision = -1; picker.hidden = false; workspace.hidden = true;
      pendingReference = null; renderReference(); preview.replaceChildren(); put(status, "");
    }
    function renderReference() {
      referenceNode.replaceChildren(); referenceNode.hidden = !pendingReference;
      if (!pendingReference) return;
      var label = document.createElement("span");
      label.textContent = "将引用已收录结论：" + pendingReference.title;
      referenceNode.append(label, button("移除引用", function () {
        pendingReference = null; renderReference();
      }));
    }
    function captureTurn(turn, label) {
      var control = button(label || "收录此回答", function () {
        control.disabled = true; put(status, "正在保存这条结论…");
        api("capture-add", {sessionId:sessionId, turnId:turn.id}).then(function () {
          put(status, "已收录：原问题、上下文、来源、AI 回答和时间均保存在本机。");
          revision = -1; refreshSession(); loadCaptures();
        }).catch(function (error) { control.disabled = false; errorMessage(error); });
      });
      return control;
    }
    var userScrolledUp = false;
    window.addEventListener("scroll", function () {
      var scrollY = window.scrollY || document.documentElement.scrollTop;
      var viewportHeight = window.innerHeight || document.documentElement.clientHeight;
      var totalHeight = document.documentElement.scrollHeight || document.body.scrollHeight;
      userScrolledUp = (scrollY + viewportHeight) < (totalHeight - 160);
    }, { passive: true });

    function scrollStreamingIntoView(turnCard, answerNode) {
      if (userScrolledUp) return;
      var target = answerNode || turnCard;
      if (!target) return;
      var rect = target.getBoundingClientRect();
      var viewportHeight = window.innerHeight || document.documentElement.clientHeight;
      if (rect.bottom > viewportHeight - 60 || rect.top < 80) {
        target.scrollIntoView({ block: "end", behavior: "smooth" });
      }
    }

    function updateStreamingAnswer(node, text, isStreaming) {
      if (!node) return;
      if (!text) {
        node.innerHTML = '<div class="museum-ai-thinking"><span class="museum-ai-spinner" aria-hidden="true"></span> <span>正在分析与整理回答…</span></div>';
        return;
      }
      markdown(node, text, false);
      if (isStreaming) {
        var cursor = document.createElement("span");
        cursor.className = "museum-ai-streaming-cursor";
        cursor.setAttribute("aria-hidden", "true");
        var last = node.lastElementChild;
        if (last && (last.tagName === "P" || last.tagName === "LI" || last.tagName === "DIV")) {
          last.appendChild(cursor);
        } else {
          node.appendChild(cursor);
        }
      }
    }

    function renderTurn(turn, index, total, saved, wasOpen, sources, sessionCreatedAt) {
      var card = document.createElement("details"); card.className = "museum-ai-turn";
      card.id = "ai-turn-" + turn.id; card.dataset.turnId = turn.id;
      card.dataset.answerLength = String((turn.answer || "").length);
      card.dataset.status = turn.status;
      card.dataset.captureId = saved ? saved.id + ":" + (saved.updatedAt || "") : "";
      card.dataset.takeaway = turn.takeaway ? turn.takeaway.title + ":" + turn.takeaway.conclusion : "";
      card.open = wasOpen.has(turn.id) ? wasOpen.get(turn.id) : index === total - 1;
      var head = document.createElement("summary");
      var number = document.createElement("span"); number.className = "museum-ai-turn-number";
      number.textContent = String(index + 1).padStart(2, "0");
      var heading = document.createElement("span"); heading.className = "museum-ai-turn-heading";
      heading.textContent = turn.kind === "analysis" ? "综合分析所选资料" : turn.prompt;
      var meta = document.createElement("small");
      meta.textContent = readableTime(turn.createdAt || (index === 0 ? sessionCreatedAt : null)) +
        (turn.status === "streaming" ? " · 生成中" :
        turn.status === "done" ? " · 已回答" : " · " + turn.status);
      head.append(number, heading, meta); card.appendChild(head);
      var content = document.createElement("div"); content.className = "museum-ai-turn-content";
      var userBlock = document.createElement("section"); userBlock.className = "museum-ai-speaker museum-ai-user";
      var userLabel = document.createElement("strong"); userLabel.textContent = "你提出的问题";
      var userText = document.createElement("p"); userText.textContent = turn.prompt;
      userBlock.append(userLabel, userText); content.appendChild(userBlock);
      if (turn.referenceId) {
        var reference = document.createElement("p"); reference.className = "museum-ai-turn-reference";
        reference.textContent = "再次引用：" + (turn.referenceTitle || "已收录结论");
        content.appendChild(reference);
      }
      var aiBlock = document.createElement("section"); aiBlock.className = "museum-ai-speaker museum-ai-assistant";
      var aiLabel = document.createElement("strong"); aiLabel.textContent = "AI 的回答";
      var answer = document.createElement("div"); answer.className = "museum-ai-answer";
      if (turn.status === "streaming") {
        updateStreamingAnswer(answer, turn.answer, true);
      } else {
        markdown(answer, turn.answer || "暂无回答。", false);
      }
      aiBlock.append(aiLabel, answer); content.appendChild(aiBlock);
      var cited = sources.filter(function (source) {
        return (turn.answer || "").includes("【" + source.pageId + "】");
      });
      var refs = document.createElement("div"); refs.className = "museum-ai-turn-sources";
      var refsLabel = document.createElement("strong");
      refsLabel.textContent = cited.length ? "AI 引用的笔记" : "本轮参考资料";
      refs.appendChild(refsLabel);
      (cited.length ? cited : sources).forEach(function (source) { refs.appendChild(sourceLink(source)); });
      content.appendChild(refs);
      if (saved) {
        var conclusion = document.createElement("section"); conclusion.className = "museum-ai-turn-conclusion";
        var conclusionLabel = document.createElement("strong"); conclusionLabel.textContent = "已收录结论 · " + saved.category;
        var conclusionText = document.createElement("p"); conclusionText.textContent = saved.conclusion;
        conclusion.append(conclusionLabel, conclusionText,
          button("查看收录内容", function () { showCapture(saved); }));
        content.appendChild(conclusion);
      } else if (turn.status === "done" && turn.takeaway) {
        var takeaway = document.createElement("section"); takeaway.className = "museum-ai-turn-conclusion";
        var takeawayLabel = document.createElement("strong");
        takeawayLabel.textContent = "AI 建议收录 · " + turn.takeaway.category;
        var takeawayText = document.createElement("p"); takeawayText.textContent = turn.takeaway.conclusion;
        var evidence = document.createElement("small");
        evidence.textContent = "来自本轮回答：" + turn.takeaway.evidence;
        takeaway.append(takeawayLabel, takeawayText, evidence,
          captureTurn(turn, "一键收录此结论"));
        content.appendChild(takeaway);
      } else if (turn.status === "done") {
        content.appendChild(captureTurn(turn));
      }
      card.appendChild(content);
      return card;
    }
    function runMessage(payload) {
      if (busy || !sessionId) return;
      if (pendingReference) payload.captureId = pendingReference.id;
      busy = true; userScrolledUp = false; put(status, "正在继续探索…");
      api("session-message", Object.assign({sessionId: sessionId}, payload)).then(function (data) {
        busy = false; pendingReference = null; renderReference(); render(data);
      }).catch(function (error) { busy = false; errorMessage(error); });
    }
    function openSession(id, capture) {
      sessionId = id; resume.value = id; revision = -1;
      api("session?sessionId=" + encodeURIComponent(id)).then(function (data) {
        render(data);
        if (capture) {
          pendingReference = capture; renderReference();
          var original = one("#ai-turn-" + capture.turnId, turns);
          if (original) { original.open = true; original.scrollIntoView({block:"start"}); }
          followup.focus();
        }
      }).catch(errorMessage);
    }
    function showCapture(item) {
      if (!item.answer) {
        api("capture?captureId=" + encodeURIComponent(item.id)).then(function (data) {
          showCapture(data.capture);
        }).catch(function (error) { put(captureStatus, error.message); });
        return;
      }
      captureDetail.replaceChildren();
      var panel = document.createElement("article"); panel.className = "museum-ai-capture-detail";
      var top = document.createElement("div"); top.className = "museum-ai-capture-detail-head";
      var heading = document.createElement("h4"); heading.textContent = "收录详情";
      top.append(heading, button("关闭", function () { captureDetail.replaceChildren(); }));
      var when = document.createElement("small");
      when.textContent = "收录于 " + readableTime(item.createdAt) + (item.updatedAt ? " · 修改于 " + readableTime(item.updatedAt) : "");
      var question = document.createElement("div"); question.className = "museum-ai-capture-origin";
      var qLabel = document.createElement("strong"); qLabel.textContent = "原问题";
      var qText = document.createElement("p"); qText.textContent = item.question;
      question.append(qLabel, qText);
      var sources = document.createElement("div"); sources.className = "museum-ai-turn-sources";
      var sLabel = document.createElement("strong"); sLabel.textContent = "原来源与版本";
      sources.appendChild(sLabel);
      (item.sources || []).forEach(function (source) {
        var row = document.createElement("span"); row.appendChild(sourceLink(source));
        if (source.hash) row.appendChild(document.createTextNode(" · " + source.hash.slice(0, 8)));
        sources.appendChild(row);
      });
      if ((item.staleSourceIds || []).length) {
        var stale = document.createElement("p"); stale.className = "museum-ai-source-warning";
        stale.textContent = "收录时部分来源已变化：" + item.staleSourceIds.map(pageTitle).join("、") + "。请核对原文版本。";
        sources.appendChild(stale);
      }
      var context = document.createElement("details"); context.className = "museum-ai-capture-context";
      var contextSummary = document.createElement("summary");
      contextSummary.textContent = "查看前文上下文（" + (item.context || []).length + " 轮）";
      context.appendChild(contextSummary);
      (item.context || []).forEach(function (turn, index) {
        var block = document.createElement("div");
        var label = document.createElement("strong"); label.textContent = "前文 " + (index + 1) + " · " + readableTime(turn.at);
        var q = document.createElement("div"); q.className = "museum-ai-context-markdown";
        var qTitle = document.createElement("b"); qTitle.textContent = "用户";
        var qBody = document.createElement("div"); markdown(qBody, turn.question || "");
        q.append(qTitle, qBody);
        var a = document.createElement("div"); a.className = "museum-ai-context-markdown";
        var aTitle = document.createElement("b"); aTitle.textContent = "AI";
        var aBody = document.createElement("div"); markdown(aBody, turn.answer || "");
        a.append(aTitle, aBody);
        block.append(label, q, a); context.appendChild(block);
      });
      var original = document.createElement("details"); original.className = "museum-ai-capture-context";
      var originalSummary = document.createElement("summary"); originalSummary.textContent = "查看当时的完整 AI 回答";
      var originalText = document.createElement("div"); markdown(originalText, item.answer);
      original.append(originalSummary, originalText);
      var titleLabel = document.createElement("label"); titleLabel.textContent = "可检索标题";
      var title = document.createElement("input"); title.value = item.title; titleLabel.appendChild(title);
      var categoryLabel = document.createElement("label"); categoryLabel.textContent = "分类";
      var category = document.createElement("select");
      ["结论", "经验", "方法", "待办"].forEach(function (name) {
        var option = document.createElement("option"); option.value = name; option.textContent = name;
        category.appendChild(option);
      });
      category.value = item.category; categoryLabel.appendChild(category);
      var conclusionLabel = document.createElement("div");
      conclusionLabel.className = "museum-ai-conclusion-field";
      var conclusionHead = document.createElement("div");
      var conclusionTitle = document.createElement("strong"); conclusionTitle.textContent = "可复用结论";
      var toggleConclusion = button("编辑 Markdown", function () {
        var editing = conclusion.hidden;
        if (editing) {
          conclusion.hidden = false; conclusionPreview.hidden = true;
          toggleConclusion.textContent = "完成预览"; conclusion.focus();
        } else {
          markdown(conclusionPreview, conclusion.value);
          conclusion.hidden = true; conclusionPreview.hidden = false;
          toggleConclusion.textContent = "编辑 Markdown";
        }
      });
      conclusionHead.append(conclusionTitle, toggleConclusion);
      var conclusionPreview = document.createElement("div");
      conclusionPreview.className = "museum-ai-conclusion-preview";
      markdown(conclusionPreview, item.conclusion || "");
      var conclusion = document.createElement("textarea"); conclusion.rows = 6; conclusion.value = item.conclusion;
      conclusion.hidden = true;
      conclusionLabel.append(conclusionHead, conclusionPreview, conclusion);
      var actions = document.createElement("div"); actions.className = "museum-ai-capture-actions";
      actions.appendChild(button("保存整理", function () {
        api("capture-update", {captureId:item.id, title:title.value,
          category:category.value, conclusion:conclusion.value}).then(function (data) {
          put(captureStatus, "整理已保存，本机结论库已更新。");
          showCapture(data.capture); loadCaptures(); revision = -1; refreshSession();
        }).catch(function (error) { put(captureStatus, error.message); });
      }));
      actions.appendChild(button("引用到当前会话", function () {
        if (!sessionId) { openSession(item.sessionId, item); return; }
        pendingReference = item; renderReference();
        followup.scrollIntoView({block:"center"}); followup.focus();
      }));
      actions.appendChild(button("继续原讨论", function () { openSession(item.sessionId, item); }));
      actions.appendChild(button("整理为公开经验", function () {
        var source = (item.sources || []).find(function (entry) {
          return pages.some(function (page) { return page.id === entry.pageId && page.published; });
        });
        if (!source) {
          put(captureStatus, "来源笔记尚未发布，不能公开这条经验。"); return;
        }
        window.dispatchEvent(new CustomEvent("org-museum-ai-select-page",
          {detail:{pageId:source.pageId}}));
        one("[data-ai-problem]").value = item.question || item.title;
        one("[data-ai-result]").value = conclusion.value;
        put(captureStatus, "已填入公开经验草稿。请核对来源和结果，再预览并确认公开。");
        one("#ai-experience").scrollIntoView({block:"start"});
      }));
      panel.append(top, when, question, sources, context, original,
        titleLabel, categoryLabel, conclusionLabel, actions);
      captureDetail.appendChild(panel);
      panel.scrollIntoView({block:"nearest"});
    }
    function loadCaptures() {
      var request = ++captureRequest;
      var route = "captures?q=" + encodeURIComponent(captureSearch.value.trim()) +
        "&category=" + encodeURIComponent(captureCategory.value) +
        "&sourceCategory=" + encodeURIComponent(sourceCategory.value);
      api(route).then(function (data) {
        if (request !== captureRequest) return;
        captureResults.replaceChildren();
        put(captureCount, data.total + " 条结论");
        var selectedCategory = sourceCategory.value;
        sourceCategory.replaceChildren();
        var allOption = document.createElement("option");
        allOption.value = ""; allOption.textContent = "全部主题";
        sourceCategory.appendChild(allOption);
        (data.sourceCategories || []).forEach(function (entry) {
          var option = document.createElement("option");
          option.value = entry.value; option.textContent = entry.label;
          sourceCategory.appendChild(option);
        });
        sourceCategory.value = selectedCategory;
        if (sourceCategory.value !== selectedCategory) sourceCategory.value = "";
        var groups = new Map();
        (data.captures || []).forEach(function (item) {
          var categories = item.sourceCategories || [];
          var group = selectedCategory ? categories.find(function (entry) {
            return entry.value === selectedCategory;
          }) : categories[0];
          var label = group ? group.label : "未分类";
          if (!groups.has(label)) groups.set(label, []);
          groups.get(label).push(item);
        });
        Array.from(groups.keys()).sort(function (a, b) { return a.localeCompare(b, "zh-CN"); })
          .forEach(function (name) {
            var section = document.createElement("section");
            section.className = "museum-ai-capture-group";
            var groupHeading = document.createElement("h4");
            groupHeading.textContent = name + " · " + groups.get(name).length;
            section.appendChild(groupHeading);
            groups.get(name).forEach(function (item) {
          var card = document.createElement("article"); card.className = "museum-ai-capture";
          var meta = document.createElement("small");
          meta.textContent = item.category + " · " + readableTime(item.createdAt);
          var heading = document.createElement("h4"); heading.textContent = item.title;
          var question = document.createElement("p"); question.textContent = "原问题：" + item.question;
          var conclusion = document.createElement("p"); conclusion.className = "museum-ai-capture-excerpt";
          conclusion.textContent = item.conclusion;
          var sources = document.createElement("small");
          sources.textContent = "来源：" + (item.sources || []).map(function (source) { return source.title; }).join("、");
          var actions = document.createElement("div"); actions.className = "museum-ai-capture-actions";
          actions.append(button("查看与整理", function () { showCapture(item); }),
            button("继续讨论", function () { openSession(item.sessionId, item); }));
          card.append(meta, heading, question, conclusion, sources, actions);
          section.appendChild(card);
        });
            captureResults.appendChild(section);
          });
        if (!captureResults.childElementCount) {
          var emptyState = document.createElement("div");
          emptyState.className = "museum-ai-empty-placeholder";
          emptyState.textContent = "还没有匹配的结论。完成一轮回答后，可直接点击“收录此回答”。";
          captureResults.appendChild(emptyState);
        }
      });
    }
    function proposalCard(item) {
      var card = document.createElement("article"); card.className = "museum-ai-proposal";
      var heading = document.createElement("h4");
      heading.textContent = ({conclusion:"结论", experience:"经验", method:"方法", todo:"待办"})[item.type] || item.type;
      var reason = document.createElement("p");
      reason.textContent = "依据：" + item.evidence + " · " +
        (item.verification === "verified" ? "有来源依据" : "待验证推断");
      var titleLabel = document.createElement("label"); titleLabel.textContent = "标题";
      var title = document.createElement("input"); title.value = item.title;
      titleLabel.appendChild(title);
      var bodyLabel = document.createElement("label"); bodyLabel.textContent = "内容";
      var body = document.createElement("textarea"); body.rows = 4; body.value = item.body;
      bodyLabel.appendChild(body);
      var targetLabel = document.createElement("label"); targetLabel.textContent = "写入笔记";
      var target = document.createElement("select");
      (window.orgMuseumAiSelectedSources || []).forEach(function (source) {
        var option = document.createElement("option");
        option.value = source.pageId; option.textContent = source.title;
        target.appendChild(option);
      });
      target.value = item.targetPageId; targetLabel.appendChild(target);
      card.append(heading, reason, titleLabel, bodyLabel, targetLabel);
      if (item.status === "saved" || item.status === "local") {
        var saved = document.createElement("p"); saved.textContent = item.status === "local" ? "已确认保存本地 Org 增补，待同步到原笔记。" : "已确认写入原笔记。";
        card.appendChild(saved); return card;
      }
      card.appendChild(button("查看写入预览", function () {
        api("session-preview", {sessionId: sessionId, proposalId: item.id,
          targetPageId: target.value, title: title.value.trim(), body: body.value.trim()})
          .then(function (data) {
            preview.replaceChildren();
            var box = document.createElement("div"); box.className = "museum-ai-confirm-box";
            var titleNode = document.createElement("h4"); titleNode.textContent = data.title;
            var textNode = document.createElement("div"); markdown(textNode, data.body);
            var context = document.createElement("p");
            context.textContent = (browserMode() ? "将保存本地增补，待同步到「" : "将追加到「") + data.targetTitle + "」；" +
              (data.public ? "该笔记公开，确认后按现有规则公开。" : "该笔记目前未公开。") +
              "依据：" + data.evidence;
            var confirm = button(browserMode() ? "确认保存本地增补" : "确认写入原笔记", function () {
              confirm.disabled = true;
              api("session-confirm", {transactionId: data.transactionId}).then(function () {
                preview.replaceChildren(); refreshSession();
              }).catch(function (error) { confirm.disabled = false; errorMessage(error); });
            });
            box.append(titleNode, textNode, context, confirm); preview.appendChild(box);
            preview.scrollIntoView({block:"nearest"});
          }).catch(errorMessage);
      }));
      return card;
    }
    function render(data) {
      if (!data || data.id !== sessionId) return;
      var stale = data.stalePageIds || [];
      var batchProgress = data.status === "batching" && data.batch &&
        data.batch.batchId === data.batchId && data.batch.progress;
      var batchText = batchProgress ? "逐篇分析 " + batchProgress.done + "/" + batchProgress.total +
        "，待处理 " + batchProgress.queued + "，运行中 " + batchProgress.running +
        "，失败 " + batchProgress.failed : "";
      put(status, stale.length ? "来源笔记已变化，请开始新一轮分析：" + stale.map(pageTitle).join("、") :
        batchText || data.error || ({batching:"正在并发分析所选笔记…", streaming:"AI 正在分析与回答…", recommending:"AI 正在整理下一步与沉淀建议…",
          ready:"已整理下一步建议；可以直接选择或自由追问。",
          interrupted:"上次请求中断，可以继续追问。"})[data.status] || "探索已保存。");
      if (data.revision === revision) return;
      revision = data.revision; picker.hidden = true; workspace.hidden = false;
      window.orgMuseumAiSelectedSources = data.sources || [];
      if (cancel) cancel.hidden =
        data.status !== "streaming" && data.status !== "recommending" && data.status !== "batching";
      var wasOpen = new Map(all("details[data-turn-id]", turns).map(function (node) {
        return [node.dataset.turnId, node.open];
      }));
      var savedByTurn = new Map((data.captures || []).map(function (item) {
        return [item.turnId, item];
      }));
      turnNav.replaceChildren();
      (data.turns || []).forEach(function (turn, index, allTurns) {
        var saved = savedByTurn.get(turn.id);
        var current = turns.children[index];
        var captureVersion = saved ? saved.id + ":" + (saved.updatedAt || "") : "";
        if (current && current.dataset.turnId === turn.id && turn.status === "streaming") {
          current.dataset.answerLength = String((turn.answer || "").length);
          current.dataset.status = turn.status;
          var answerEl = current.querySelector(".museum-ai-answer");
          if (answerEl) updateStreamingAnswer(answerEl, turn.answer, true);
          var metaEl = current.querySelector("summary small");
          if (metaEl) metaEl.textContent = readableTime(turn.createdAt || (index === 0 ? data.createdAt : null)) + " · 生成中";
          scrollStreamingIntoView(current, answerEl);
        } else if (!current || current.dataset.turnId !== turn.id ||
            current.dataset.answerLength !== String((turn.answer || "").length) ||
            current.dataset.status !== turn.status ||
            current.dataset.captureId !== captureVersion ||
            current.dataset.takeaway !== (turn.takeaway ?
              turn.takeaway.title + ":" + turn.takeaway.conclusion : "")) {
          var updated = renderTurn(turn, index, allTurns.length,
            saved, wasOpen, data.sources || [], data.createdAt);
          if (current) current.replaceWith(updated); else turns.appendChild(updated);
          if (turn.status === "streaming") {
            scrollStreamingIntoView(updated, updated.querySelector(".museum-ai-answer"));
          }
        }
        if (index === 0 || turn.kind === "analysis") {
          var group = document.createElement("strong"); group.className = "museum-ai-nav-group";
          group.textContent = "分析"; turnNav.appendChild(group);
        } else if (index === 1) {
          var followups = document.createElement("strong"); followups.className = "museum-ai-nav-group";
          followups.textContent = "后续追问"; turnNav.appendChild(followups);
        }
        var jump = document.createElement("a"); jump.href = "#ai-turn-" + turn.id;
        jump.textContent = String(index + 1).padStart(2, "0") + " · " +
          (turn.kind === "analysis" ? "综合分析" : turn.prompt);
        jump.addEventListener("click", function (event) {
          event.preventDefault();
          var card = document.getElementById("ai-turn-" + turn.id);
          card.open = true; card.scrollIntoView({block:"start", behavior:"smooth"});
          one("summary", card).focus();
        });
        turnNav.appendChild(jump);
      });
      while (turns.children.length > (data.turns || []).length) turns.lastChild.remove();
      directions.replaceChildren();
      (data.directions || []).forEach(function (item) {
        var card = document.createElement("article"); card.className = "museum-ai-direction";
        var heading = document.createElement("h4"); heading.textContent = item.title;
        var reason = document.createElement("p"); reason.textContent = item.reason;
        var source = document.createElement("small");
        source.textContent = "依据：" + (item.sourcePageIds || []).map(pageTitle).join("、");
        card.append(heading, reason, source,
          button("沿此方向深挖", function () { runMessage({directionId:item.id}); }));
        directions.appendChild(card);
      });
      if (!directions.childElementCount)
        put(directions, data.status === "recommending" ? "正在挑选值得探索的方向…" : "可以自由追问，AI 会根据新问题继续推荐。");
      proposals.replaceChildren();
      (data.proposals || []).forEach(function (item) { proposals.appendChild(proposalCard(item)); });
      if (!proposals.childElementCount)
        put(proposals, data.status === "recommending" ? "正在整理值得沉淀的内容…" : "目前没有足够依据形成沉淀建议；可继续深挖。");
      followup.disabled = stale.length > 0 || data.status === "batching" || data.status === "streaming" || data.status === "recommending";
      one("[data-ai-message-form] button", root).disabled = followup.disabled;
    }
    var currentSessionStatus = "";
    function refreshSession() {
      if (!sessionId || document.visibilityState !== "visible") return;
      api("session?sessionId=" + encodeURIComponent(sessionId)).then(function (data) {
        if (data) currentSessionStatus = data.status || "";
        render(data);
      }).catch(errorMessage);
    }
    window.addEventListener("org-museum-ai-stream", function (event) {
      var detail = event.detail;
      if (!detail || detail.sessionId !== sessionId) return;
      currentSessionStatus = detail.status || "";
      var turnCard = document.getElementById("ai-turn-" + detail.turnId);
      if (!turnCard) {
        refreshSession();
        return;
      }
      turnCard.open = true;
      var answerNode = turnCard.querySelector(".museum-ai-answer");
      if (answerNode) {
        updateStreamingAnswer(answerNode, detail.text, detail.status === "streaming");
        scrollStreamingIntoView(turnCard, answerNode);
      }
      var metaNode = turnCard.querySelector("summary small");
      if (metaNode && detail.status === "streaming") {
        metaNode.textContent = readableTime(detail.createdAt || null) + " · 生成中";
      }
      if (detail.status !== "streaming") {
        refreshSession();
      }
    });
    function resumeList() {
      api("sessions").then(function (data) {
        resume.replaceChildren();
        var empty = document.createElement("option");
        empty.value = ""; empty.textContent = "选择已有会话"; resume.appendChild(empty);
        (data.sessions || []).forEach(function (item) {
          var option = document.createElement("option"); option.value = item.id;
          option.textContent = (item.titles || []).join("、") + " · " + item.createdAt;
          resume.appendChild(option);
        });
      }).catch(errorMessage);
    }
    function connectConversation() { api("catalog").then(function (data) {
      pages = data.pages || [];
      workerSelect.value = String(data.maxWorkers || 2);
      root.hidden = false;
      var initial = new URLSearchParams(location.search).get("pageId");
      if (initial && pages.some(function (item) { return item.id === initial; })) chosen.add(initial);
      choose(); showPages(); resumeList(); loadCaptures();
    }).catch(function () { root.hidden = true; }); }
    connectConversation();
    window.addEventListener('org-museum-ai-channel-change', function () {
      showPicker(); chosen.clear(); pages = []; turns.replaceChildren(); directions.replaceChildren(); proposals.replaceChildren();
      captureDetail.replaceChildren(); captureResults.replaceChildren(); captureRequest++; connectConversation();
    });
    search.addEventListener("input", showPages);
    workerSelect.addEventListener("change", function () {
      workerSelect.disabled = true;
      api("action", {action:"workers", maxWorkers:Number(workerSelect.value)})
        .then(function (data) {
          workerSelect.value = String(data.maxWorkers);
          put(status, "并发 Worker 已设为 " + data.maxWorkers + "；当前请求完成后按新上限调度。");
        }).catch(errorMessage)
        .finally(function () { workerSelect.disabled = false; });
    });
    captureSearch.addEventListener("input", function () {
      clearTimeout(captureTimer); captureTimer = setTimeout(loadCaptures, 220);
    });
    captureCategory.addEventListener("change", loadCaptures);
    sourceCategory.addEventListener("change", loadCaptures);
    one("[data-ai-new-session]", root).addEventListener("click", showPicker);
    if (cancel) cancel.addEventListener("click", function () {
      api("session-cancel", {sessionId:sessionId}).then(render).catch(errorMessage);
    });
    resume.addEventListener("change", function () {
      if (!resume.value) { showPicker(); return; }
      openSession(resume.value);
    });
    one("[data-ai-start]", root).addEventListener("click", function () {
      if (busy) return;
      if (!chosen.size) { put(status, "请先选择至少一篇笔记。"); return; }
      busy = true; userScrolledUp = false; put(status, "正在开始分析…");
      api("session-start", {pageIds:Array.from(chosen)}).then(function (data) {
        busy = false; sessionId = data.id; revision = -1; render(data); resumeList();
      }).catch(function (error) { busy = false; errorMessage(error); });
    });
    one("[data-ai-message-form]", root).addEventListener("submit", function (event) {
      event.preventDefault();
      var message = followup.value.trim();
      if (!message) return;
      runMessage({message:message}); followup.value = "";
    });
    var pollTimer = null;
    function schedulePoll() {
      refreshSession();
      var delay = (currentSessionStatus === "streaming" || currentSessionStatus === "batching") ? 250 : 700;
      pollTimer = setTimeout(schedulePoll, delay);
    }
    pollTimer = setTimeout(schedulePoll, 700);
    window.addEventListener("pagehide", function () { if (pollTimer) clearTimeout(pollTimer); }, {once:true});
  }

  function start() {
    if (window.orgMuseumMarkdown) window.orgMuseumMarkdown.renderDocument();
    article(); center(); conversation();
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
