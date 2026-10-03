;;; org-museum-ai-web.el --- Local AI Center bridge -*- lexical-binding: t -*-

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url-parse)

(defvar org-museum-ai-web--previews (make-hash-table :test #'equal))
(defconst org-museum-ai-web--preview-ttl 600)

(defun org-museum-ai-web--article-panel-html (_page)
  "Return the independent article AI Copilot right sidebar and control."
  (concat
   "<button type=\"button\" class=\"museum-ai-trigger\" data-ai-toggle "
   "aria-controls=\"museum-ai-panel\" aria-expanded=\"false\" "
   "title=\"AI Copilot 对话与分析 (Ctrl+I)\">"
   "<span class=\"museum-ai-trigger-icon\" aria-hidden=\"true\"></span>"
   "<span class=\"museum-ai-trigger-text\">AI 讨论</span>"
   "<span class=\"museum-ai-trigger-dot\" data-ai-trigger-dot aria-hidden=\"true\"></span>"
   "<kbd class=\"museum-ai-trigger-shortcut\" data-ai-trigger-shortcut aria-hidden=\"true\">Ctrl+I</kbd>"
   "</button>"
   "<aside id=\"museum-ai-panel\" class=\"museum-ai-panel museum-ai-sidebar\" "
   "aria-label=\"AI Copilot 协作面板\" aria-hidden=\"true\" inert>"
   "<header class=\"museum-ai-copilot-header\">"
   "<div class=\"museum-ai-copilot-brand\">"
   "<span class=\"museum-ai-copilot-brand-icon\" aria-hidden=\"true\"></span>"
   "<div class=\"museum-ai-copilot-title-group\">"
   "<h2 class=\"museum-ai-copilot-title\">AI Copilot</h2>"
   "<span class=\"museum-ai-copilot-badge\" data-ai-engine-badge>讨论模式</span>"
   "</div></div>"
   "<div class=\"museum-ai-copilot-header-actions\">"
   "<button type=\"button\" class=\"museum-ai-icon-btn\" data-copilot-new title=\"清空并开始新讨论\" aria-label=\"新建讨论\">↺</button>"
   "<a data-ai-center-link class=\"museum-ai-icon-btn\" href=\"#\" title=\"打开完整 AI 中心\" aria-label=\"前往 AI 中心\">↗</a>"
   "<button type=\"button\" class=\"museum-ai-icon-btn museum-ai-close-btn\" data-ai-close title=\"收起侧边栏 (Esc)\" aria-label=\"收起侧边栏\">×</button>"
   "</div></header>"
   "<div class=\"museum-ai-copilot-context\">"
   "<div class=\"museum-ai-context-info\">"
   "<span class=\"museum-ai-context-icon\" aria-hidden=\"true\">📄</span>"
   "<span class=\"museum-ai-context-name\" data-ai-context-title>当前正文</span>"
   "</div>"
   "<div class=\"museum-ai-context-actions\">"
   "<button type=\"button\" class=\"museum-ai-context-analyze-btn\" data-ai-analyze title=\"生成或刷新当前笔记结构化分析\">"
   "<span class=\"museum-ai-btn-icon\" aria-hidden=\"true\"></span>"
   "<span data-ai-analyze-label>分析笔记</span>"
   "</button></div></div>"
   "<details class=\"museum-ai-analysis-drawer\" data-ai-analysis-drawer>"
   "<summary class=\"museum-ai-analysis-drawer-summary\">"
   "<span class=\"museum-ai-status-dot\" data-ai-status-dot aria-hidden=\"true\"></span>"
   "<span data-ai-status role=\"status\" aria-live=\"polite\">就绪</span>"
   "<span class=\"museum-ai-analysis-toggle-label\">结构化分析结果</span>"
   "</summary>"
   "<div class=\"museum-ai-analysis-drawer-content\">"
   "<div data-ai-summary class=\"museum-ai-summary-box\">暂无分析结果。</div>"
   "<div class=\"museum-ai-experiences-section\">"
   "<small class=\"museum-ai-subhead\">相关经验参考</small>"
   "<div data-ai-experiences class=\"museum-ai-experiences-box\"></div>"
   "</div></div></details>"
   "<div class=\"museum-ai-copilot-chat\" data-ai-chat-area>"
   "<div class=\"museum-ai-copilot-messages\" data-ai-chat-turns role=\"log\" aria-live=\"polite\"></div>"
   "<div class=\"museum-ai-explore-prompts\" data-ai-explore-prompts>"
   "<div class=\"museum-ai-explore-prompts-title\"><span>💡 探索建议</span></div>"
   "<div class=\"museum-ai-explore-chips\" data-ai-explore-chips></div>"
   "</div></div>"
   "<div class=\"museum-ai-copilot-composer\">"
   "<form data-ai-chat-form class=\"museum-ai-composer-form\">"
   "<textarea data-ai-chat-input name=\"message\" rows=\"2\" "
   "placeholder=\"围绕当前笔记提问、探讨或提炼知识… (Ctrl+Enter 发送)\" "
   "aria-label=\"向 AI Copilot 提问\"></textarea>"
   "<div class=\"museum-ai-composer-bar\">"
   "<span class=\"museum-ai-composer-hint\"><kbd>Ctrl+Enter</kbd> 发送</span>"
   "<div class=\"museum-ai-composer-actions\">"
   "<button type=\"button\" class=\"museum-ai-stop-btn\" data-ai-chat-stop hidden aria-label=\"停止生成\">■ 停止</button>"
   "<button type=\"submit\" class=\"museum-ai-send-btn\" data-ai-chat-send aria-label=\"发送消息\">发送 ↑</button>"
   "</div></div></form></div>"
   "</aside>"))

(defun org-museum-ai-web--public-records (out-file)
  "Return only confirmed, current and published records for OUT-FILE."
  (org-museum-knowledge--ensure)
  (unless org-museum--index (org-museum-index-build))
  (vconcat
   (delq nil
         (mapcar
          (lambda (item)
            (let* ((id (alist-get 'pageId item))
                   (page (and id (gethash id (org-museum-index-pages org-museum--index)))))
              (when (and (eq (alist-get 'published item) t)
                         (org-museum-knowledge--experience-current-p item)
                         page (org-museum--published-page-p page))
                `((id . ,(alist-get 'id item))
                  (pageId . ,id)
                  (title . ,(org-museum-page-title page))
                  (category . ,(or (org-museum-page-category page) "未分类"))
                  (categoryLabel . ,(org-museum--category-label
                                     (or (org-museum-page-category page)
                                         "未分类")))
                  (href . ,(org-museum--page-href id out-file))
                  (problem . ,(alist-get 'problem item))
                  (result . ,(alist-get 'result item))
                  (wrongAttempt . ,(or (alist-get 'wrongAttempt item) ""))
                  (type . ,(or (alist-get 'type item) "experience"))
                  (verification . ,(alist-get 'verification item))))))
          org-museum-knowledge--experiences))))

(defun org-museum-ai-web--browser-html ()
  "Return direct browser model setup and conversation controls."
  (concat
   "<details class=\"museum-ai-browser museum-ai-quick-chat\" data-browser-ai hidden>"
   "<summary>快速讨论<span>临时提问 · 需要保留时导出；资料分析与收录请用下方工作区</span></summary>"
   "<div class=\"museum-ai-browser-shell\">"
   "<section class=\"museum-ai-center-card museum-ai-browser-chat\"><header><div><small>浏览器直连</small><h2>开始一轮讨论</h2></div>"
   "<div class=\"museum-ai-browser-actions\"><button type=\"button\" data-browser-export>导出讨论</button><button type=\"button\" data-browser-clear>新讨论</button></div></header>"
   "<div data-browser-turns aria-live=\"polite\"><p class=\"museum-ai-browser-empty\">在右上角「设置」中选择或连接模型，添加参考笔记，即可开始讨论。</p></div>"
   "<details class=\"museum-ai-browser-sources\"><summary>添加笔记作为资料 <span data-browser-source-count>0</span></summary>"
   "<label>搜索笔记<input type=\"search\" data-browser-source-search placeholder=\"搜索标题或主题\"></label>"
   "<div data-browser-sources role=\"group\" aria-label=\"选择发送给模型的笔记\"></div>"
   "<small>仅发送勾选笔记的可公开正文，每篇最多 20,000 字符。</small></details>"
   "<form data-browser-chat><label>你的问题<textarea name=\"prompt\" rows=\"3\" required placeholder=\"你想弄清什么？\"></textarea></label>"
   "<div class=\"museum-ai-action-row\"><button type=\"submit\" data-browser-send>发送问题</button>"
   "<button type=\"button\" data-browser-stop hidden>停止生成</button></div></form>"
   "<p data-browser-status role=\"status\" aria-live=\"polite\"></p>"
   "<small>讨论保留在本次页面中；需要保存时可导出。写回原笔记仍可使用 Emacs 后端。</small></section></div></details>"))

(defun org-museum-ai-web--browser-pages (out-file)
  "Return public note metadata for optional, explicit browser context."
  (let (pages)
    (when org-museum--index
      (maphash (lambda (_id page)
                 (when (org-museum--published-page-p page)
                   (push `((id . ,(org-museum-page-id page))
                           (title . ,(org-museum-page-title page))
                           (category . ,(or (org-museum-page-category page) "未分类"))
                           (categoryLabel . ,(org-museum--category-label
                                               (or (org-museum-page-category page) "未分类")))
                           (sourceHash . ,(when (file-readable-p (org-museum-page-path page))
                                            (org-museum-knowledge--file-hash (org-museum-page-path page))))
                           (linksTo . ,(vconcat (seq-filter (lambda (id)
                                                            (when-let ((target (gethash id (org-museum-index-pages org-museum--index))))
                                                              (org-museum--published-page-p target)))
                                                          (org-museum-page-links-to page))))
                           (href . ,(org-museum--page-href (org-museum-page-id page) out-file))) pages)))
               (org-museum-index-pages org-museum--index)))
    (vconcat (sort pages (lambda (a b) (string-lessp (alist-get 'title a) (alist-get 'title b)))))))

(defun org-museum-ai-web--export-center ()
  "Write the public AI Center and its approved-only data."
  (let* ((root (org-museum--shared-root))
         (out (expand-file-name "ai-center.html" root))
         (data-file (expand-file-name "ai-public.json" root))
         (script (expand-file-name "resources/org-museum-ai.js" root))
         (records (org-museum-ai-web--public-records out)))
    (org-museum--write-content-if-changed
     data-file
     (let ((json-encoding-pretty-print nil))
       (json-encode `((schemaVersion . 1) (experiences . ,records)))))
    (org-museum--write-content-if-changed
     out
     (concat
      "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
      "<meta name=\"color-scheme\" content=\"dark light\"><title>AI 中心 · Org Museum</title>"
      (org-museum--theme-script-tag out) (org-museum--css-link-tag out)
      org-museum--favicon-link-tag
      "</head><body class=\"org-museum-ai-center\" data-page-kind=\"ai\">"
      (org-museum--build-topbar out 'ai)
      (org-museum--generate-sidebar-html out)
      "<main id=\"main-content\" class=\"museum-ai-center-shell\" tabindex=\"-1\" "
      (format "data-public-data=\"ai-public.json\" data-workspace-id=\"%s\">"
              (secure-hash 'sha256 (file-truename org-museum-root-dir)))
      "<header class=\"museum-ai-center-intro\"><small>ORG MUSEUM / 知识复利</small>"
      "<h1>AI 中心</h1><p>选好资料，接下来的分析、探索和整理交给 AI；你只需选择与确认。</p>"
      "<div class=\"museum-ai-channel\" role=\"group\" aria-label=\"AI 接入方式\">"
      "<button type=\"button\" data-ai-channel=\"browser\" aria-pressed=\"false\">浏览器模型</button>"
      "<button type=\"button\" data-ai-channel=\"emacs\" aria-pressed=\"false\">Emacs 后端</button></div>"
      "<p data-ai-connection role=\"status\" aria-live=\"polite\">正在检查本机服务…</p>"
      "<div class=\"museum-ai-offline\" data-ai-offline hidden>"
      "<strong>Emacs 后端尚未连接。也可切换到浏览器模型直接使用 AI。</strong>"
      "<p>在 Emacs 中按 <kbd>M-x</kbd>，输入 <code>org-museum-ai-center-open</code> 并回车；"
      "请使用 Emacs 新打开的本机页面，并在模型服务中加载你选择的模型。</p>"
      "<p>下方的已确认公开经验仍可直接阅读。</p></div></header>"
      (org-museum-ai-web--browser-html)
      "<section class=\"museum-ai-conversation museum-ai-center-card\" data-ai-conversation hidden>"
      "<div class=\"museum-ai-conversation-head\"><div><small>人 × AI 多轮会话</small><h2>让讨论成为可复用的知识</h2></div>"
      "<button type=\"button\" data-ai-new-session>开始新一轮</button></div>"
      "<label>继续已有探索<select data-ai-resume><option value=\"\">选择已有会话</option></select></label>"
      "<p data-ai-session-status role=\"status\" aria-live=\"polite\"></p>"
      "<div data-ai-picker><label>搜索笔记<input data-ai-search type=\"search\" placeholder=\"按标题或分类搜索，选择多篇笔记\"></label>"
      "<label class=\"museum-ai-worker-setting\">并发 Worker"
      "<select data-ai-workers aria-label=\"同时分析的笔记数量\">"
      "<option value=\"1\">1</option><option value=\"2\">2</option>"
      "<option value=\"3\">3</option><option value=\"4\">4</option></select></label>"
      "<div class=\"museum-ai-selection\" data-ai-selection></div>"
      "<div class=\"museum-ai-page-list\" data-ai-page-list role=\"group\" aria-label=\"选择分析资料\"></div>"
      "<button type=\"button\" data-ai-start>分析所选资料</button></div>"
      "<div data-ai-workspace hidden>"
      "<button type=\"button\" data-ai-cancel-session hidden>停止本轮生成</button>"
      "<div class=\"museum-ai-history\"><aside class=\"museum-ai-history-nav\">"
      "<h3>本轮目录</h3><nav data-ai-turn-nav aria-label=\"跳转到讨论轮次\"></nav></aside>"
      "<section class=\"museum-ai-history-main\"><h3>讨论时间线</h3>"
      "<div class=\"museum-ai-turns\" data-ai-turns aria-label=\"探索对话\"></div>"
      "</section></div>"
      "<section class=\"museum-ai-next\"><h3>建议继续探索</h3>"
      "<div data-ai-directions></div></section>"
      "<section class=\"museum-ai-sediment\"><h3>建议沉淀</h3>"
      "<div data-ai-proposals></div><div data-ai-sediment-preview></div></section>"
      "<form data-ai-message-form><label for=\"museum-ai-followup\">继续讨论或自由追问</label>"
      "<div class=\"museum-ai-reference\" data-ai-reference hidden></div>"
      "<textarea id=\"museum-ai-followup\" data-ai-followup rows=\"3\" placeholder=\"输入你想进一步弄清的问题\"></textarea>"
      "<button type=\"submit\">发送问题</button></form></div>"
      "<section class=\"museum-ai-library\" data-ai-library>"
      "<div class=\"museum-ai-library-head\"><div><small>本机私有 · 持续积累</small>"
      "<h3>已收录结论</h3><p>按问题或来源找回结论，引用到新问题，或接着原讨论继续。</p></div>"
      "<span data-ai-capture-count></span></div>"
      "<div class=\"museum-ai-library-filters\"><label>检索结论"
      "<input data-ai-capture-search type=\"search\" placeholder=\"搜索问题、结论或来源\"></label>"
      "<label>笔记 CATEGORY<select data-ai-source-category><option value=\"\">全部主题</option></select></label>"
      "<label>结论类型<select data-ai-capture-category><option value=\"\">全部类型</option>"
      "<option>结论</option><option>经验</option><option>方法</option><option>待办</option></select></label></div>"
      "<p data-ai-capture-status role=\"status\" aria-live=\"polite\"></p>"
      "<div data-ai-capture-results></div><div data-ai-capture-detail></div>"
      "</section></section>"
      "<details class=\"museum-ai-advanced\"><summary>更多工具：队列、关系、失败模式与巡检</summary>"
      "<div class=\"museum-ai-center-grid museum-ai-guided\" data-ai-guided>"
      "<section id=\"ai-analysis\" class=\"museum-ai-center-card\"><h2>1 · 分析一篇笔记</h2>"
      "<p>先选择要处理的笔记；分析不会修改正文。</p>"
      "<label>选择笔记<select data-ai-page></select></label>"
      "<div class=\"museum-ai-action-row\"><button data-ai-action=\"analyze\">开始分析</button></div>"
      "<p data-ai-queue-summary role=\"status\"></p><div data-ai-current-analysis></div></section>"
      "<section id=\"ai-recall\" class=\"museum-ai-center-card\"><h2>2 · 找相关经验</h2>"
      "<p>用一句话描述当前问题，查看笔记和已确认的解决方法。</p>"
      "<label>当前问题<input data-ai-query placeholder=\"例如：如何处理 DuckDB 导入失败？\"></label>"
      "<div class=\"museum-ai-action-row\"><button data-ai-action=\"recall\">查找经验</button></div>"
      "<div data-ai-recall-results></div></section>"
      "<section id=\"ai-experience\" class=\"museum-ai-center-card\"><h2>3 · 任务结束后沉淀</h2>"
      "<p>填写实际发生的结果，先预览，再由你决定是否公开。</p>"
      "<label>本轮问题<input data-ai-problem></label><label>实际结果或修复<textarea data-ai-result rows=\"3\"></textarea></label>"
      "<button data-ai-action=\"preview-experience\">预览待确认经验</button>"
      "<div data-ai-preview></div></section></div>"
      "<p data-ai-message role=\"status\" aria-live=\"polite\"></p>"
      "<div class=\"museum-ai-center-grid\">"
      "<section class=\"museum-ai-center-card\"><h2>队列与批量分析</h2>"
      "<p>仅在需要批量处理时使用。默认的辅助模式不会在保存时请求模型。</p>"
      "<div class=\"museum-ai-action-row\"><button data-ai-action=\"analyze-dirty\">分析待处理</button>"
      "<button data-ai-action=\"analyze-project\">扫描变更</button><button data-ai-action=\"cancel\">取消当前分析</button>"
      "<button data-ai-action=\"pause\">暂停或继续</button><button data-ai-action=\"queue-clear\">清空队列</button></div>"
      "<label>工作模式<select data-ai-mode><option value=\"manual\">手动</option><option value=\"assist\" selected>辅助</option><option value=\"auto\">自动</option></select></label>"
      "<div data-ai-queue></div></section>"
      "<section class=\"museum-ai-center-card\"><h2>关系与上下文</h2>"
      "<div class=\"museum-ai-action-row\"><button data-ai-action=\"context\">上下文图谱</button>"
      "<button data-ai-action=\"relations\">查看关系</button></div>"
      "<label>关联笔记<select data-ai-target></select></label>"
      "<label>关系类型<select data-ai-relation-type><option value=\"related\">相关</option>"
      "<option value=\"supports\">支持</option><option value=\"contradicts\">矛盾</option>"
      "<option value=\"depends-on\">依赖</option><option value=\"applies-to\">适用</option>"
      "<option value=\"influences\">启发影响</option><option value=\"part-of\">属于</option></select></label>"
      "<label>置信度（0–1）<input data-ai-confidence type=\"number\" min=\"0\" max=\"1\" step=\"0.1\" value=\"0.8\"></label>"
      "<label>原文依据<textarea data-ai-evidence rows=\"3\" placeholder=\"粘贴保存过的 Org 原文片段\"></textarea></label>"
      "<button data-ai-action=\"preview-relation\">预览私有关系</button>"
      "<label>已有关系<select data-ai-relation></select></label>"
      "<button data-ai-action=\"remove-relation\">预览并移除关系</button></section>"
      "<section class=\"museum-ai-center-card\"><h2>失败经验</h2>"
      "<label>失败尝试<textarea data-ai-wrong rows=\"2\"></textarea></label>"
      "<label>失败原因<input data-ai-cause></label><label>适用范围<input data-ai-scope></label>"
      "<button data-ai-action=\"preview-failure\">预览失败模式</button></section>"
      "<section id=\"ai-review\" class=\"museum-ai-center-card\"><h2>巡检</h2>"
      "<label>当前任务<input data-ai-task placeholder=\"需要检查的任务或学习目标\"></label>"
      "<div class=\"museum-ai-action-row\"><button data-ai-action=\"gap\">知识缺口</button>"
      "<button data-ai-action=\"gap-ai\">模型复核</button><button data-ai-action=\"derive\">知识组合</button>"
      "<button data-ai-action=\"scan\">全库扫描</button><button data-ai-action=\"scan-cancel\">取消扫描</button></div>"
      "<p data-ai-scan-state></p><label>知识组合候选<select data-ai-derived></select></label>"
      "<div class=\"museum-ai-action-row\"><button data-ai-action=\"derive-review\">查看候选</button>"
      "<button data-ai-action=\"derive-accept\">确认组合</button>"
      "<button data-ai-action=\"derive-reject\">否决组合</button>"
      "<button data-ai-action=\"derive-cancel\">取消组合</button>"
      "<button data-ai-action=\"scan-status\">查看扫描结果</button>"
      "<button data-ai-action=\"gap-cancel\">取消模型复核</button></div>"
      "<label>验证观察<input data-ai-observation placeholder=\"实际执行后记录的结果\"></label>"
      "<button data-ai-action=\"derive-verify\">用原文结果验证组合</button>"
      "<div data-ai-review-results></div></section></div>"
      "<div data-ai-advanced-preview></div></details>"
      "<section class=\"museum-ai-center-card museum-ai-public\"><h2>已确认公开的经验</h2>"
      "<p>从已收录结论整理，经你预览确认后才会公开。</p>"
      "<div data-ai-public></div></section></main>"
      "<script type=\"application/json\" id=\"museum-ai-public-data\">"
      (org-museum--json-for-html
       `((schemaVersion . 1) (experiences . ,records)))
      "</script>"
      "<script type=\"application/json\" id=\"museum-ai-browser-pages\">"
      (org-museum--json-for-html (org-museum-ai-web--browser-pages out))
      "</script>"
      (org-museum--script-shell)
      (org-museum--script-ai-markdown out)
      (format "<script defer src=\"%s\"></script>"
              (org-museum--html-escape
               (org-museum--versioned-resource-href
                (expand-file-name "resources/org-museum-ai-workspace.js" root) out) t))
      (format "<script defer src=\"%s\"></script>"
              (org-museum--html-escape
               (org-museum--versioned-resource-href
                (expand-file-name "resources/org-museum-ai-browser.js" root) out) t))
      (format "<script defer src=\"%s\"></script>"
              (org-museum--html-escape
               (org-museum--versioned-resource-href script out) t))
      "</body></html>"))))

(defun org-museum-ai-web--json (value)
  (org-museum--curation-http-response 200 (org-museum--curation-json value)))

(defun org-museum-ai-web--request (body)
  (let ((json-object-type 'alist) (json-array-type 'list)
        (json-key-type 'symbol) (json-false :json-false))
    (json-read-from-string (decode-coding-string body 'utf-8 t))))

(defun org-museum-ai-web--field (data key &optional required)
  (let ((value (alist-get key data)))
    (when (and required (or (not (stringp value)) (string-empty-p (string-trim value))))
      (user-error "请填写%s"
                  (or (cdr (assq key '((pageId . "笔记") (task . "当前任务")
                                       (problem . "问题") (result . "实际结果")
                                       (query . "当前问题") (evidence . "原文依据")
                                       (observation . "验证观察"))))
                      "必填内容")))
    value))

(defun org-museum-ai-web--page (id)
  (unless org-museum--index (org-museum-index-build))
  (let ((page (and (stringp id)
                   (gethash id (org-museum-index-pages org-museum--index)))))
    (unless page (user-error "找不到这篇已索引笔记"))
    page))

(defun org-museum-ai-web--page-summary (page)
  (let* ((file (org-museum-page-path page))
         (hash (org-museum-knowledge--file-hash file))
         (job (org-museum-knowledge--job file))
         (item (org-museum-knowledge--analysis file))
         (analysis (when (and item (equal (alist-get 'hash item) hash)) item))
         (status (or (alist-get 'status job) "none")))
    `((pageId . ,(org-museum-page-id page))
      (title . ,(org-museum-page-title page))
      (hash . ,hash)
      (status . ,(cond ((and (equal status "done") (not analysis)) "stale")
                       ((and (equal status "running")
                             (not (eq job org-museum-knowledge--active))) "dirty")
                       ((and (equal status "dirty")
                             (equal file org-museum-knowledge--requested-file))
                        "queued")
                       (t status)))
      (error . ,(or (alist-get 'error job) ""))
      (analysis . ,(when analysis
                     `((summary . ,(alist-get 'summary analysis))
                       (model . ,(alist-get 'model analysis))
                       (generatedAt . ,(alist-get 'generatedAt analysis))))))))

(defun org-museum-ai-web--status ()
  (org-museum-knowledge--ensure)
  (org-museum-derived--ensure)
  (unless org-museum--index (org-museum-index-build))
  `((ok . t) (model . ,org-museum-knowledge-local-model)
    (mode . ,(symbol-name org-museum-knowledge-work-mode))
    (paused . ,(if org-museum-knowledge--paused t :json-false))
    (active . ,(if org-museum-knowledge--active t :json-false))
    (workers . ,(length org-museum-knowledge--actives))
    (maxWorkers . ,org-museum-knowledge-max-workers)
    (batch . ,(org-museum-knowledge--batch-public))
    (scan . ,(if org-museum-deep-scan--job
                 (format "扫描中：%d/%d"
                         (plist-get org-museum-deep-scan--job :position)
                         (length (plist-get org-museum-deep-scan--job :pages)))
               (if org-museum-deep-scan--last-report "扫描已完成" "尚未运行")))
    (derived . ,(vconcat
                 (mapcar (lambda (item)
                           `((id . ,(alist-get 'id item))
                             (task . ,(alist-get 'task item))
                             (claim . ,(or (alist-get 'claim item) ""))
                             (status . ,(alist-get 'status item))
                             (current . ,(if (org-museum-derived--current-p item)
                                             t :json-false))))
                         org-museum-derived--items)))
    (relations . ,(vconcat
                   (mapcar (lambda (item)
                             `((id . ,(alist-get 'id item))
                               (sourcePageId . ,(alist-get 'sourcePageId item))
                               (targetPageId . ,(alist-get 'targetPageId item))
                               (type . ,(alist-get 'type item))
                               (current . ,(if (org-museum-knowledge--relation-current-p item)
                                               t :json-false))))
                           org-museum-knowledge--relations)))
    (queue . ,(vconcat
               (mapcar (lambda (job)
                         (let ((page (org-museum-knowledge--page-for-file
                                      (alist-get 'file job))))
                           `((pageId . ,(and page (org-museum-page-id page)))
                             (title . ,(and page (org-museum-page-title page)))
                             (status . ,(alist-get 'status job))
                             (attempts . ,(alist-get 'attempts job))
                             (error . ,(or (alist-get 'error job) "")))))
                       org-museum-knowledge--queue)))
    (pages . ,(vconcat
               (let (pages)
                 (maphash (lambda (_id page)
                            (push `((id . ,(org-museum-page-id page))
                                    (title . ,(org-museum-page-title page))) pages))
                          (org-museum-index-pages org-museum--index))
                 (sort pages (lambda (a b) (string< (alist-get 'title a)
                                                (alist-get 'title b)))))))))

(defun org-museum-ai-web--catalog ()
  "Return the small, frequently used note picker payload."
  (unless org-museum--index (org-museum-index-build))
  (let (pages)
    (maphash (lambda (id page)
               (push `((id . ,id) (title . ,(org-museum-page-title page))
                       (category . ,(or (org-museum-page-category page)
                                        "未分类"))
                       (categoryLabel . ,(org-museum--category-label
                                          (or (org-museum-page-category page)
                                              "未分类")))
                       (published . ,(if (org-museum--published-page-p page)
                                         t :json-false))
                       (href . ,(org-museum--page-href
                                 id (expand-file-name "ai-center.html"
                                                      (org-museum--shared-root)))))
                     pages))
             (org-museum-index-pages org-museum--index))
    `((ok . t) (model . ,org-museum-knowledge-local-model)
      (maxWorkers . ,org-museum-knowledge-max-workers)
      (pages . ,(vconcat
                 (sort pages (lambda (a b)
                               (string< (alist-get 'title a)
                                        (alist-get 'title b)))))))))

(defun org-museum-ai-web--buffer-result (function &rest args)
  "Call FUNCTION with ARGS and return its displayed text for local use."
  (let (shown)
    (cl-letf (((symbol-function 'display-buffer)
               (lambda (buffer &rest _)
                 (setq shown buffer) buffer)))
      (apply function args))
    (if (buffer-live-p shown)
        (with-current-buffer shown (buffer-substring-no-properties (point-min) (point-max)))
      "命令已启动；请稍后刷新状态。")))

(defun org-museum-ai-web--in-page (id function &rest args)
  (let* ((page (org-museum-ai-web--page id))
         (buffer (find-file-noselect (org-museum-page-path page))))
    (with-current-buffer buffer
      (when (buffer-modified-p)
        (user-error "请先在 Emacs 中保存原笔记"))
      (apply function args))))

(defun org-museum-ai-web--query (path key)
  (let ((query (cadr (split-string path "?"))))
    (when-let* ((value (cadr (assoc key (url-parse-query-string (or query ""))))))
      (decode-coding-string value 'utf-8))))

(defun org-museum-ai-web--evidence (file excerpt expected-hash)
  "Validate exact saved Org evidence and return its provenance."
  (unless (and (stringp excerpt) (<= 8 (length excerpt) 4000))
    (user-error "请选择 8–4000 字的已保存 Org 原文"))
  (unless (equal expected-hash (org-museum-knowledge--file-hash file))
    (user-error "原笔记已变化，请刷新页面后重新预览"))
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (unless (search-forward excerpt nil t)
      (user-error "依据与已保存的 Org 原文不符"))
    `((file . ,file) (line . ,(line-number-at-pos (- (point) (length excerpt))))
      (excerpt . ,excerpt) (excerptHash . ,(secure-hash 'sha256 excerpt))
      (kind . ,(if (org-museum-knowledge--recorded-result-p excerpt)
                   "org-result" "source-excerpt")))))

(defun org-museum-ai-web--preview (data)
  (org-museum-knowledge--ensure)
  (let* ((kind (org-museum-ai-web--field data 'kind t))
         (page (org-museum-ai-web--page (org-museum-ai-web--field data 'pageId t)))
         (file (org-museum-page-path page))
         (hash (org-museum-knowledge--file-hash file))
         (target (and (equal kind "relation")
                      (org-museum-ai-web--page
                       (org-museum-ai-web--field data 'targetId t))))
         (evidence (when (member kind '("relation" "failure"))
                     (org-museum-ai-web--evidence
                      file (org-museum-ai-web--field data 'evidence t)
                      (org-museum-ai-web--field data 'expectedHash t))))
         (id (secure-hash 'sha256 (format "%s:%s:%s:%s" (float-time)
                                          (random) file kind)))
         (record `((kind . ,kind) (pageId . ,(org-museum-page-id page))
                   (file . ,file) (hash . ,hash)
                   (data . ,data) (evidence . ,evidence)
                   (targetHash . ,(and target
                                       (org-museum-knowledge--file-hash
                                        (org-museum-page-path target))))
                   (created . ,(float-time)))))
    (when-let* ((buffer (find-buffer-visiting file)))
      (when (buffer-modified-p buffer)
        (user-error "预览前请先在 Emacs 中保存原笔记")))
    (maphash (lambda (key item)
               (when (> (- (float-time) (alist-get 'created item))
                        org-museum-ai-web--preview-ttl)
                 (remhash key org-museum-ai-web--previews)))
             org-museum-ai-web--previews)
    (unless (member kind '("experience" "failure" "relation"))
      (user-error "无法识别预览类型"))
    (unless (equal hash (org-museum-ai-web--field data 'expectedHash t))
      (user-error "原笔记已变化，请刷新页面后重新预览"))
    (dolist (key (if (equal kind "failure")
                     '(problem cause wrongAttempt result scope)
                   (if (equal kind "relation") '(relationType) '(problem result))))
      (org-museum-ai-web--field data key t))
    (when (and target (equal (org-museum-page-id page)
                             (org-museum-page-id target)))
      (user-error "请选择另一篇已索引笔记"))
    (when (and target
               (not (assoc (alist-get 'relationType data)
                           org-museum-knowledge--relation-types)))
      (user-error "不支持这种关系类型"))
    (when target
      (let ((confidence (alist-get 'confidence data)))
        (unless (and (numberp confidence) (<= 0 confidence 1))
          (user-error "置信度须介于 0 和 1 之间"))))
    (puthash id record org-museum-ai-web--previews)
    `((ok . t) (transactionId . ,id) (kind . ,kind)
      (sourceTitle . ,(org-museum-page-title page))
      (sourceHash . ,hash)
      (targetTitle . ,(and target (org-museum-page-title target)))
      (evidence . ,(or (alist-get 'excerpt evidence) ""))
      (problem . ,(or (alist-get 'problem data) ""))
      (result . ,(or (alist-get 'result data) ""))
      (wrongAttempt . ,(or (alist-get 'wrongAttempt data) ""))
      (cause . ,(or (alist-get 'cause data) ""))
      (scope . ,(or (alist-get 'scope data) ""))
      (relationType . ,(or (alist-get 'relationType data) ""))
      (confidence . ,(or (alist-get 'confidence data) 0))
      (public . ,(if (equal kind "relation") :json-false t)))))

(defun org-museum-ai-web--confirm (data)
  (let* ((id (org-museum-ai-web--field data 'transactionId t))
         (record (gethash id org-museum-ai-web--previews)))
    (unless record (user-error "预览已失效，请重新开始"))
    (remhash id org-museum-ai-web--previews)
    (when (> (- (float-time) (alist-get 'created record))
             org-museum-ai-web--preview-ttl)
      (user-error "预览已失效，请重新开始"))
    (let* ((file (alist-get 'file record))
           (hash (alist-get 'hash record))
           (kind (alist-get 'kind record))
           (input (alist-get 'data record))
           (page-id (alist-get 'pageId record))
           (evidence (alist-get 'evidence record))
           (target (and (equal kind "relation")
                        (org-museum-ai-web--page (alist-get 'targetId input)))))
      (unless (equal hash (org-museum-knowledge--file-hash file))
        (user-error "预览后原笔记发生变化，请重新开始"))
      (when evidence
        (org-museum-ai-web--evidence file (alist-get 'excerpt evidence) hash))
      (when (and target
                 (not (equal (alist-get 'targetHash record)
                             (org-museum-knowledge--file-hash
                              (org-museum-page-path target)))))
        (user-error "预览后关联笔记发生变化，请重新开始"))
      (if target
          (let* ((target-file (org-museum-page-path target))
                 (target-id (org-museum-page-id target))
                 (type (alist-get 'relationType input))
                 (item `((id . ,(secure-hash 'sha256
                                             (format "%s|%s|%s|%s|%s"
                                                     file target-file type hash
                                                     (alist-get 'targetHash record))))
                         (sourcePageId . ,page-id) (targetPageId . ,target-id)
                         (sourceFile . ,file) (targetFile . ,target-file)
                         (sourceHash . ,hash)
                         (targetHash . ,(alist-get 'targetHash record))
                         (type . ,type)
                         (label . ,(cdr (assoc type org-museum-knowledge--relation-types)))
                         (confidence . ,(alist-get 'confidence input))
                         (origin . "user-confirmed")
                         (evidence . ,evidence)
                         (createdAt . ,(format-time-string "%FT%T%z")))))
            (unless (cl-find (alist-get 'id item) org-museum-knowledge--relations
                             :key (lambda (entry) (alist-get 'id entry)) :test #'equal)
              (push item org-museum-knowledge--relations)
              (org-museum-knowledge--persist-derived)))
        (let* ((failure (equal kind "failure"))
               (problem (string-trim (alist-get 'problem input)))
               (result (string-trim (alist-get 'result input)))
               (wrong (string-trim (or (alist-get 'wrongAttempt input) "")))
               (cause (and failure (string-trim (alist-get 'cause input))))
               (scope (and failure (string-trim (alist-get 'scope input))))
               (item `((id . ,(secure-hash 'sha256
                                           (if failure
                                               (concat file hash problem cause wrong result scope)
                                             (concat file hash problem result))))
                       (type . ,(if failure "failure-pattern" "experience"))
                       (file . ,file) (pageId . ,page-id) (sourceHash . ,hash)
                       (problem . ,problem) (result . ,result)
                       (wrongAttempt . ,wrong)
                       (verification . ,(if (and failure
                                                 (equal (alist-get 'kind evidence) "org-result"))
                                            "recorded-result" "user-confirmed"))
                       (createdAt . ,(format-time-string "%FT%T%z"))
                       (published . t))))
          (when failure
            (setf (alist-get 'cause item) cause
                  (alist-get 'scope item) scope
                  (alist-get 'evidence item) evidence))
          (unless (cl-find (alist-get 'id item) org-museum-knowledge--experiences
                           :key (lambda (entry) (alist-get 'id entry)) :test #'equal)
            (push item org-museum-knowledge--experiences)
            (org-museum-knowledge--persist-derived)
            (org-museum--start-background-job 'export-all nil))))
      `((ok . t) (saved . t) (kind . ,kind)))))

(defun org-museum-ai-web--preview-removal (data)
  "Preview removal of one private derived relation."
  (org-museum-knowledge--ensure)
  (let* ((id (org-museum-ai-web--field data 'relationId t))
         (relation (cl-find id org-museum-knowledge--relations
                            :key (lambda (item) (alist-get 'id item)) :test #'equal))
         (token (secure-hash 'sha256 (format "%s:%s:%s" id (float-time) (random)))))
    (unless relation (user-error "这条关系已不存在"))
    (puthash token `((relationId . ,id) (created . ,(float-time)))
             org-museum-ai-web--previews)
    `((ok . t) (transactionId . ,token)
      (changes . ,(vconcat
                    (append
                     (mapcar (lambda (p) `((target . ,(org-museum-page-title (org-museum-ai-web--page (alist-get 'targetPageId p))))
                                           (title . ,(alist-get 'title p)) (body . ,(alist-get 'body p)))) patches)
                     (mapcar (lambda (p) `((target . ,(org-museum-page-title (org-museum-ai-web--page (alist-get 'pageId p))))
                                           (title . ,(alist-get 'problem p)) (body . ,(alist-get 'result p))))
                             (alist-get 'experiences workspace)))))
      (sourcePageId . ,(alist-get 'sourcePageId relation))
      (targetPageId . ,(alist-get 'targetPageId relation))
      (relationType . ,(alist-get 'type relation)))))

(defun org-museum-ai-web--confirm-removal (data)
  "Remove a reviewed private relation without changing source Org notes."
  (let* ((token (org-museum-ai-web--field data 'transactionId t))
         (preview (gethash token org-museum-ai-web--previews))
         (id (alist-get 'relationId preview)))
    (remhash token org-museum-ai-web--previews)
    (unless (and preview
                 (<= (- (float-time) (alist-get 'created preview))
                     org-museum-ai-web--preview-ttl))
      (user-error "预览已失效，请重新开始"))
    (org-museum-knowledge--ensure)
    (let ((relation (cl-find id org-museum-knowledge--relations
                             :key (lambda (item) (alist-get 'id item)) :test #'equal)))
      (unless relation (user-error "这条关系已不存在"))
      (setq org-museum-knowledge--relations
            (delq relation org-museum-knowledge--relations))
      (org-museum-knowledge--persist-derived))
    '((ok . t) (removed . t))))

(defun org-museum-ai-web--action (data)
  "Dispatch bounded AI actions through the existing knowledge runtime."
  (let ((action (org-museum-ai-web--field data 'action t))
        (id (alist-get 'pageId data))
        (page-ids (alist-get 'pageIds data))
        (query (alist-get 'query data)))
    ;; Browser actions always use the local model, even if Emacs has an
    ;; explicitly selected cloud backend for a separate editing session.
    (when (member action '("analyze" "analyze-dirty" "analyze-project"
                           "gap-ai" "derive"))
      (setq org-museum-knowledge--cloud-backend nil
            org-museum-knowledge--cloud-model nil))
    (pcase action
      ("analyze"
       (org-museum-ai-web--in-page id #'org-museum-analyze-current)
       (let* ((summary (org-museum-ai-web--page-summary
                        (org-museum-ai-web--page id)))
              (status (alist-get 'status summary)))
         `((ok . t) (status . ,status)
           (message . ,(pcase status
                         ("running" "正在分析所选笔记，请等待结果")
                         ("queued" "所选笔记已排队，当前任务结束后会自动分析")
                         ("dirty" "所选笔记等待分析，请检查是否已暂停")
                         ("done" "这篇笔记已完成分析")
                         (_ "分析请求已提交，请查看当前笔记状态"))))))
      ("analyze-dirty" (org-museum-analyze-dirty) '((ok . t)))
      ("analyze-project" (org-museum-analyze-project) '((ok . t)))
      ("batch-start"
       (unless (and (listp page-ids) page-ids)
         (user-error "请选择至少一篇笔记"))
       (org-museum-knowledge--start-batch
        (mapcar (lambda (page-id)
                  (org-museum-page-path (org-museum-ai-web--page page-id)))
                page-ids))
       (org-museum-knowledge--batch-public))
      ("batch-status" (org-museum-knowledge--batch-public))
      ("batch-cancel" (org-museum-ai-cancel) '((ok . t)))
      ("cancel" (org-museum-ai-cancel) '((ok . t)))
      ("queue-clear" (org-museum-ai-queue-clear) '((ok . t)))
      ("pause" (org-museum-ai-pause) '((ok . t)))
      ("mode" (org-museum-ai-set-mode
                 (intern (org-museum-ai-web--field data 'mode t))) '((ok . t)))
      ("workers"
       (org-museum-knowledge--set-max-workers
        (alist-get 'maxWorkers data))
       `((ok . t) (maxWorkers . ,org-museum-knowledge-max-workers)))
      ("recall"
       `((ok . t) (text . ,(org-museum-ai-web--in-page
                            id #'org-museum-ai-web--buffer-result
                            #'org-museum-recall
                            (org-museum-ai-web--field data 'query t)))))
      ("context"
       `((ok . t) (text . ,(org-museum-ai-web--in-page
                            id #'org-museum-ai-web--buffer-result
                            #'org-museum-context-graph query))))
      ("relations"
       `((ok . t) (text . ,(org-museum-ai-web--buffer-result
                           #'org-museum-relations))))
      ("gap"
       `((ok . t) (text . ,(org-museum-ai-web--in-page
                            id #'org-museum-ai-web--buffer-result
                            #'org-museum-knowledge-gap
                            (org-museum-ai-web--field data 'task t)))))
      ("gap-ai"
       (let ((buffer (get-buffer "*Org Museum 知识缺口*")))
         (unless buffer (user-error "请先检查知识缺口"))
         (with-current-buffer buffer (org-museum-knowledge-gap-ai)))
       '((ok . t) (message . "模型复核已启动")))
      ("gap-cancel" (org-museum-knowledge-gap-cancel) '((ok . t)))
      ("derive"
       (org-museum-ai-web--in-page
        id #'org-museum-derive-current
        (org-museum-ai-web--field data 'task t)
        (org-museum-ai-web--field data 'targetId t)
        (let ((excerpt (alist-get 'evidence data)))
          (when (and (stringp excerpt) (not (string-empty-p excerpt)))
            (alist-get 'excerpt
                       (org-museum-ai-web--evidence
                        (org-museum-page-path (org-museum-ai-web--page id))
                        excerpt (org-museum-ai-web--field data 'expectedHash t))))))
       '((ok . t) (message . "知识组合已启动；候选保存在私有层")))
      ("derive-cancel" (org-museum-derived-cancel) '((ok . t)))
      ("derive-review"
       `((ok . t) (text . ,(org-museum-ai-web--buffer-result
                           #'org-museum-derived-review
                           (org-museum-ai-web--field data 'derivedId t)))))
      ("derive-accept"
       (org-museum-derived--ensure)
       (let ((item (cl-find (org-museum-ai-web--field data 'derivedId t)
                            org-museum-derived--items
                            :key (lambda (entry) (alist-get 'id entry)) :test #'equal)))
         (unless (and item (org-museum-derived--current-p item)
                      (equal (alist-get 'status item) "ai-inference"))
           (user-error "只能确认来源未变化且尚未审核的候选"))
         (setf (alist-get 'status item) "user-confirmed"
               (alist-get 'confirmedAt item) (format-time-string "%FT%T%z"))
         (org-museum-derived--replace item))
       '((ok . t)))
      ("derive-reject"
       (org-museum-derived--ensure)
       (let ((item (cl-find (org-museum-ai-web--field data 'derivedId t)
                            org-museum-derived--items
                            :key (lambda (entry) (alist-get 'id entry)) :test #'equal)))
         (unless item (user-error "候选已不可用"))
         (setf (alist-get 'status item) "rejected")
         (org-museum-derived--replace item))
       '((ok . t)))
      ("derive-verify"
       (org-museum-derived--ensure)
       (let* ((candidate (cl-find (org-museum-ai-web--field data 'derivedId t)
                                  org-museum-derived--items
                                  :key (lambda (entry) (alist-get 'id entry))
                                  :test #'equal))
              (file (org-museum-page-path (org-museum-ai-web--page id)))
              (evidence (org-museum-ai-web--evidence
                         file (org-museum-ai-web--field data 'evidence t)
                         (org-museum-ai-web--field data 'expectedHash t))))
         (unless (and candidate (org-museum-derived--confirmed-p candidate))
           (user-error "请先确认来源未变化的候选"))
         (unless (equal (alist-get 'kind evidence) "org-result")
           (user-error "验证需要已保存的 #+RESULTS 结果块"))
         (setf (alist-get 'status candidate) "recorded-result"
               (alist-get 'verification candidate)
               `((observation . ,(org-museum-ai-web--field data 'observation t))
                 (file . ,file) (line . ,(alist-get 'line evidence))
                 (sourceHash . ,(org-museum-knowledge--file-hash file))
                 (excerpt . ,(alist-get 'excerpt evidence))
                 (excerptHash . ,(alist-get 'excerptHash evidence))
                 (recordedAt . ,(format-time-string "%FT%T%z"))))
         (org-museum-derived--replace candidate))
       '((ok . t)))
      ("scan" (org-museum-deep-scan) '((ok . t)))
      ("scan-cancel" (org-museum-deep-scan-cancel) '((ok . t)))
      ("scan-status"
       `((ok . t) (text . ,(org-museum-ai-web--buffer-result
                            #'org-museum-deep-scan-status))))
      (_ (user-error "无法识别这项 AI 操作")))))

(defun org-museum-ai-web--browser-fields (item fields)
  "Copy only FIELDS from untrusted browser ITEM."
  (mapcar (lambda (key) (cons key (copy-tree (alist-get key item)))) fields))

(defun org-museum-ai-web--browser-source (item)
  "Resolve a browser source to the actual indexed file and saved version."
  (let* ((id (alist-get 'pageId item))
         (source (org-museum-ai-session--source id)))
    (unless (equal (alist-get 'hash source) (alist-get 'hash item))
      (user-error "来源已变化，不能同步旧版本：%s" id))
    source))

(defun org-museum-ai-web--browser-sync-preview (data)
  "Validate a complete browser workspace before any imports or file writes."
  (org-museum-ai-session--ensure)
  (org-museum-ai-session--captures-ensure)
  (org-museum-derived--ensure)
  (let* ((workspace (copy-tree (alist-get 'workspace data)))
         (sessions (alist-get 'sessions workspace))
         (captures (alist-get 'captures workspace))
         (patches (alist-get 'patches workspace))
         (token (secure-hash 'sha256 (format "browser:%s:%s" (float-time) (random)))))
    (unless (and (equal (alist-get 'schemaVersion workspace) 1)
                 (equal (alist-get 'workspaceId workspace)
                        (secure-hash 'sha256 (file-truename org-museum-root-dir)))
                 (< (length (json-encode workspace)) (* 20 1024 1024)))
      (user-error "备份版本或所属知识库不匹配，或数据过大"))
    (dolist (key '(sessions captures patches relations experiences derived))
      (unless (and (listp (alist-get key workspace))
                   (<= (length (alist-get key workspace)) 5000))
        (user-error "浏览器备份结构无效")))
    (dolist (item sessions)
      (unless (and (stringp (alist-get 'id item))
                   (string-prefix-p "browser-" (alist-get 'id item))
                   (<= 1 (length (alist-get 'sources item)) 12)
                   (integerp (alist-get 'revision item))
                   (cl-every (lambda (turn)
                               (and (stringp (alist-get 'id turn))
                                    (stringp (alist-get 'prompt turn))
                                    (stringp (alist-get 'answer turn))
                                    (member (alist-get 'status turn) '("done" "failed"))))
                             (alist-get 'turns item)))
        (user-error "请先停止生成；会话格式无效"))
      (setf (alist-get 'sources item)
            (mapcar #'org-museum-ai-web--browser-source (alist-get 'sources item)))
      (let ((existing (cl-find (alist-get 'id item) org-museum-ai-session--items
                               :key (lambda (x) (alist-get 'id x)) :test #'equal)))
        (when (and existing
                   (not (equal (alist-get 'revision existing)
                               (alist-get 'browserSyncedRevision existing))))
          (user-error "会话已在 Emacs 中继续修改，不能覆盖：%s" (alist-get 'id item)))))
    (dolist (item captures)
      (let ((existing (cl-find (alist-get 'id item) org-museum-ai-session--captures
                               :key (lambda (x) (alist-get 'id x)) :test #'equal)))
        (when (and existing (stringp (alist-get 'updatedAt existing))
                   (or (not (stringp (alist-get 'updatedAt item)))
                       (string-lessp (alist-get 'updatedAt item) (alist-get 'updatedAt existing))))
          (user-error "结论已在 Emacs 中整理，请勿用旧备份覆盖")))
      (unless (and (cl-find (alist-get 'sessionId item) sessions
                            :key (lambda (x) (alist-get 'id x)) :test #'equal)
                   (member (alist-get 'category item) org-museum-ai-session--capture-categories)
                   (cl-every (lambda (key) (stringp (alist-get key item)))
                             '(id title conclusion question answer)))
        (user-error "收录结论格式无效"))
      (setf (alist-get 'sources item)
            (mapcar (lambda (source)
                      (let ((canonical (org-museum-ai-session--source (alist-get 'pageId source))))
                        ;; Captures preserve historical source versions; they do not authorize writes.
                        (unless (and (stringp (alist-get 'hash source))
                                     (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (alist-get 'hash source)))
                          (user-error "收录结论的原版本无效"))
                        (setf (alist-get 'hash canonical) (alist-get 'hash source)) canonical))
                    (alist-get 'sources item))))
    (dolist (id (alist-get 'removedRelations workspace))
      (unless (and (stringp id) (string-prefix-p "browser-" id)
                   (cl-find id org-museum-knowledge--relations :key (lambda (r) (alist-get 'id r)) :test #'equal))
        (user-error "待移除的浏览器关系已不存在或不属于浏览器导入")))
    (dolist (patch patches)
      (let* ((session (cl-find (alist-get 'sessionId patch) sessions
                               :key (lambda (x) (alist-get 'id x)) :test #'equal))
             (source (cl-find (alist-get 'targetPageId patch) (alist-get 'sources session)
                              :key (lambda (x) (alist-get 'pageId x)) :test #'equal)))
        (unless (and (stringp (alist-get 'id patch))
                     (string-prefix-p "browser-" (alist-get 'id patch))
                     (not (string-match-p "[\n\r]" (alist-get 'id patch)))
                     source (equal (alist-get 'hash source) (alist-get 'baseHash patch))
                     (stringp (alist-get 'title patch)) (<= 4 (length (alist-get 'title patch)) 100)
                     (not (string-match-p "[\n\r]" (alist-get 'title patch)))
                     (stringp (alist-get 'body patch)) (<= 8 (length (alist-get 'body patch)) 3000))
          (user-error "本地增补的目标、版本或内容无效"))))
    (dolist (item (alist-get 'relations workspace))
      (let* ((source (org-museum-ai-web--page (alist-get 'sourcePageId item)))
             (target (org-museum-ai-web--page (alist-get 'targetPageId item))))
        (unless (and (not (eq source target))
                     (assoc (alist-get 'type item) org-museum-knowledge--relation-types)
                     (numberp (alist-get 'confidence item)) (<= 0 (alist-get 'confidence item) 1)
                     (equal (alist-get 'sourceHash item) (org-museum-knowledge--file-hash (org-museum-page-path source)))
                     (equal (alist-get 'targetHash item) (org-museum-knowledge--file-hash (org-museum-page-path target))))
          (user-error "关系来源已变化或关系格式无效"))
        (org-museum-ai-web--evidence (org-museum-page-path source) (alist-get 'evidence item) (alist-get 'sourceHash item))))
    (dolist (item (alist-get 'experiences workspace))
      (org-museum-ai-web--preview
       (append (org-museum-ai-web--browser-fields item '(kind pageId problem result wrongAttempt cause scope evidence))
               (list (cons 'expectedHash (alist-get 'sourceHash item))))))
    (dolist (item (alist-get 'derived workspace))
      (setf (alist-get 'sources item)
            (mapcar (lambda (source)
                      (let* ((canonical (org-museum-ai-web--browser-source source))
                             (page (org-museum-ai-web--page (alist-get 'pageId source)))
                             (text (org-museum-knowledge--source-text (org-museum-page-path page))))
                        (append canonical
                                `((file . ,(org-museum-page-path page))
                                  (excerpt . ,text) (excerptHash . ,(secure-hash 'sha256 text))))))
                    (alist-get 'sources item))))
    (puthash token `((kind . "browser-sync") (workspace . ,workspace)
                     (created . ,(float-time))) org-museum-ai-web--previews)
    `((ok . t) (transactionId . ,token)
      (message . ,(format "将同步 %d 个会话、%d 条结论、%d 条关系、%d 条经验及 %d 个组合候选；%d 项经确认的增补将写回原笔记，移除 %d 条已审核的浏览器关系。现有 Emacs 修改冲突会阻止同步。"
                          (length sessions) (length captures)
                          (length (alist-get 'relations workspace))
                          (length (alist-get 'experiences workspace))
                          (length (alist-get 'derived workspace)) (length patches)
                          (length (alist-get 'removedRelations workspace)))))))

(defun org-museum-ai-web--browser-sync-confirm (data)
  "Apply a reviewed browser import, rolling files and in-memory data back on error."
  (let* ((token (alist-get 'transactionId data))
         (record (gethash token org-museum-ai-web--previews))
         (workspace (alist-get 'workspace record)))
    (unless (and (equal (alist-get 'kind record) "browser-sync")
                 (< (- (float-time) (alist-get 'created record)) org-museum-ai-web--preview-ttl))
      (user-error "同步预览已过期，请重新预览"))
    ;; Revalidate all source hashes and editing conflicts immediately before writes.
    (org-museum-ai-web--browser-sync-preview `((workspace . ,workspace)))
    (let* ((old-sessions (copy-tree org-museum-ai-session--items))
           (old-captures (copy-tree org-museum-ai-session--captures))
           (old-relations (copy-tree org-museum-knowledge--relations))
           (old-experiences (copy-tree org-museum-knowledge--experiences))
           (old-derived (copy-tree org-museum-derived--items))
           (files (delete-dups
                   (append (list (org-museum-ai-session--path) (org-museum-ai-session--captures-path)
                                 (org-museum-knowledge--derived-path) (org-museum-derived--path))
                           (mapcar (lambda (patch) (org-museum-page-path
                                                   (org-museum-ai-web--page (alist-get 'targetPageId patch))))
                                   (alist-get 'patches workspace)))))
           (originals (mapcar (lambda (file) (cons file (when (file-exists-p file)
                                                       (with-temp-buffer (insert-file-contents file) (buffer-string))))) files)))
      (org-museum--curation-persist-backups (seq-filter #'file-exists-p files) token)
      (condition-case err
          (progn
            (dolist (item (alist-get 'sessions workspace))
              (let ((clean (org-museum-ai-web--browser-fields item '(id createdAt revision sources turns directions proposals))))
                (setf (alist-get 'status clean) "ready"
                      (alist-get 'browserSyncedRevision clean) (alist-get 'revision clean))
                (setq org-museum-ai-session--items
                      (cons clean (cl-remove (alist-get 'id clean) org-museum-ai-session--items
                                             :key (lambda (x) (alist-get 'id x)) :test #'equal)))))
            (dolist (item (alist-get 'captures workspace))
              (let ((clean (org-museum-ai-web--browser-fields item '(id sessionId turnId title category conclusion question answer createdAt updatedAt sources context))))
                (setq org-museum-ai-session--captures
                      (cons clean (cl-remove (alist-get 'id clean) org-museum-ai-session--captures
                                             :key (lambda (x) (alist-get 'id x)) :test #'equal)))))
            (dolist (item (alist-get 'relations workspace))
              (unless (cl-find (alist-get 'id item) org-museum-knowledge--relations :key (lambda (x) (alist-get 'id x)) :test #'equal)
                (let* ((source (org-museum-ai-web--page (alist-get 'sourcePageId item)))
                       (target (org-museum-ai-web--page (alist-get 'targetPageId item)))
                       (clean (org-museum-ai-web--browser-fields item '(id sourcePageId targetPageId sourceHash targetHash type confidence createdAt))))
                  (setf (alist-get 'sourceFile clean) (org-museum-page-path source)
                        (alist-get 'targetFile clean) (org-museum-page-path target)
                        (alist-get 'origin clean) "user-confirmed"
                        (alist-get 'label clean) (cdr (assoc (alist-get 'type item) org-museum-knowledge--relation-types))
                        (alist-get 'evidence clean) (org-museum-ai-web--evidence (org-museum-page-path source) (alist-get 'evidence item) (alist-get 'sourceHash item)))
                  (push clean org-museum-knowledge--relations))))
            (setq org-museum-knowledge--relations
                  (cl-remove-if (lambda (r) (member (alist-get 'id r) (alist-get 'removedRelations workspace)))
                                org-museum-knowledge--relations))
            (dolist (item (alist-get 'experiences workspace))
              (unless (cl-find (alist-get 'id item) org-museum-knowledge--experiences :key (lambda (x) (alist-get 'id x)) :test #'equal)
                (let ((clean (org-museum-ai-web--browser-fields item '(id pageId sourceHash problem result wrongAttempt cause scope createdAt))))
                  (setf (alist-get 'file clean) (org-museum-page-path (org-museum-ai-web--page (alist-get 'pageId item)))
                        (alist-get 'type clean) (if (equal (alist-get 'kind item) "failure") "failure-pattern" "experience")
                        (alist-get 'verification clean) "user-confirmed"
                        (alist-get 'published clean) t)
                  (push clean org-museum-knowledge--experiences))))
            (dolist (item (alist-get 'derived workspace))
              (unless (cl-find (alist-get 'id item) org-museum-derived--items :key (lambda (x) (alist-get 'id x)) :test #'equal)
                (let ((clean (org-museum-ai-web--browser-fields item '(id task claim why verification_plan sources createdAt))))
                  ;; Browser verification is imported as evidence, never silently promoted to verified.
                  (setf (alist-get 'status clean) "ai-inference"
                        (alist-get 'backend clean) "Browser")
                  (push clean org-museum-derived--items))))
            (dolist (patch (alist-get 'patches workspace))
              (let* ((file (org-museum-page-path (org-museum-ai-web--page (alist-get 'targetPageId patch))))
                     (marker (concat "# browser-addition: " (alist-get 'id patch))))
                (with-temp-buffer
                  (insert-file-contents file)
                  (unless (save-excursion (goto-char (point-min)) (search-forward marker nil t))
                    (goto-char (point-max))
                    (insert "\n\n" marker "\n* " (alist-get 'title patch) "\n"
                            (org-museum-ai-session--org-safe (alist-get 'body patch)) "\n")
                    (write-region (point-min) (point-max) file nil 'silent)))
                (let* ((session (cl-find (alist-get 'sessionId patch) org-museum-ai-session--items
                                        :key (lambda (s) (alist-get 'id s)) :test #'equal))
                       (source (cl-find (alist-get 'targetPageId patch) (alist-get 'sources session)
                                       :key (lambda (s) (alist-get 'pageId s)) :test #'equal))
                       (proposal (cl-find (alist-get 'proposalId patch) (alist-get 'proposals session)
                                         :key (lambda (p) (alist-get 'id p)) :test #'equal)))
                  (when source (setf (alist-get 'hash source) (org-museum-knowledge--file-hash file)))
                  (when proposal (setf (alist-get 'status proposal) "saved")))))
            (org-museum-ai-session--save)
            (org-museum-ai-session--captures-save)
            (org-museum-knowledge--persist-derived)
            (org-museum-derived--persist)
            (dolist (patch (alist-get 'patches workspace))
              (when-let ((buffer (find-buffer-visiting
                                 (org-museum-page-path (org-museum-ai-web--page (alist-get 'targetPageId patch))))))
                (with-current-buffer buffer (revert-buffer t t))))
            (remhash token org-museum-ai-web--previews)
            (org-museum-index-build t)
            (org-museum--start-background-job 'export-all nil)
            `((ok . t) (message . "已同步到 Emacs；确认的增补已写回，静态页面正在更新。")
              (sourceHashes . ,(let (hashes)
                                 (dolist (patch (alist-get 'patches workspace))
                                   (let ((id (alist-get 'targetPageId patch)))
                                     (setf (alist-get (intern id) hashes)
                                           (org-museum-knowledge--file-hash (org-museum-page-path (org-museum-ai-web--page id))))))
                                 hashes))
              (syncedPatchIds . ,(vconcat (mapcar (lambda (p) (alist-get 'id p)) (alist-get 'patches workspace))))))
        (error
         (setq org-museum-ai-session--items old-sessions
               org-museum-ai-session--captures old-captures
               org-museum-knowledge--relations old-relations
               org-museum-knowledge--experiences old-experiences
               org-museum-derived--items old-derived)
         (dolist (entry originals)
           (if (cdr entry) (with-temp-file (car entry) (insert (cdr entry)))
             (when (file-exists-p (car entry)) (delete-file (car entry)))))
         (signal (car err) (cdr err)))))))

(defun org-museum-ai-web--dispatch-http (method path body)
  "Handle authenticated same-origin local AI requests."
  (condition-case err
      (let* ((route (car (split-string path "?")))
             (data (and (equal method "POST") (org-museum-ai-web--request body))))
        (org-museum-ai-web--json
         (pcase (list method route)
           (`("GET" "/api/v1/ai/status") (org-museum-ai-web--status))
           (`("GET" "/api/v1/ai/batch") (org-museum-knowledge--batch-public))
           (`("GET" "/api/v1/ai/catalog") (org-museum-ai-web--catalog))
           (`("GET" "/api/v1/ai/sessions")
            (org-museum-ai-session--list))
           (`("GET" "/api/v1/ai/session")
            (org-museum-ai-session--public
             (org-museum-ai-session--get
              (org-museum-ai-web--query path "sessionId"))))
           (`("GET" "/api/v1/ai/captures")
            (org-museum-ai-session--capture-list
             (org-museum-ai-web--query path "q")
             (org-museum-ai-web--query path "category")
             (org-museum-ai-web--query path "sourceCategory")))
           (`("GET" "/api/v1/ai/capture")
            (let ((capture (org-museum-ai-session--capture-get
                            (org-museum-ai-web--query path "captureId"))))
              `((ok . t)
                (capture . ,(append
                             (copy-tree capture)
                             (list (cons 'sourceCategories
                                         (org-museum-ai-session--capture-source-categories
                                          capture))))))))
           (`("GET" "/api/v1/ai/public")
            `((ok . t)
              (experiences . ,(org-museum-ai-web--public-records
                               (expand-file-name "ai-center.html"
                                                 (org-museum--shared-root))))))
           (`("GET" "/api/v1/ai/page")
            (org-museum-knowledge--ensure)
            (cons '(ok . t)
                  (org-museum-ai-web--page-summary
                   (org-museum-ai-web--page
                    (org-museum-ai-web--query path "pageId")))))
           (`("POST" "/api/v1/ai/action") (org-museum-ai-web--action data))
           (`("POST" "/api/v1/ai/browser-sync-preview") (org-museum-ai-web--browser-sync-preview data))
           (`("POST" "/api/v1/ai/browser-sync-confirm") (org-museum-ai-web--browser-sync-confirm data))
           (`("POST" "/api/v1/ai/batch-start")
            (org-museum-ai-web--action (cons '(action . "batch-start") data)))
           (`("POST" "/api/v1/ai/session-start")
            (org-museum-ai-session--start data))
           (`("POST" "/api/v1/ai/session-message")
            (org-museum-ai-session--message data))
           (`("POST" "/api/v1/ai/capture-add")
            (org-museum-ai-session--capture-add data))
           (`("POST" "/api/v1/ai/capture-update")
            (org-museum-ai-session--capture-update data))
           (`("POST" "/api/v1/ai/session-cancel")
            (org-museum-ai-session--cancel data))
           (`("POST" "/api/v1/ai/session-preview")
            (org-museum-ai-session--preview data))
           (`("POST" "/api/v1/ai/session-confirm")
            (org-museum-ai-session--confirm data))
           (`("POST" "/api/v1/ai/session-batch-confirm")
            (org-museum-ai-session--batch-confirm data))
           (`("POST" "/api/v1/ai/preview") (org-museum-ai-web--preview data))
           (`("POST" "/api/v1/ai/confirm") (org-museum-ai-web--confirm data))
           (`("POST" "/api/v1/ai/preview-removal")
            (org-museum-ai-web--preview-removal data))
           (`("POST" "/api/v1/ai/confirm-removal")
            (org-museum-ai-web--confirm-removal data))
           (_ (user-error "无法识别 AI 接口")))))
    (error (org-museum--curation-http-error 409 (error-message-string err)))))

;;;###autoload
(defun org-museum-ai-center-open ()
  "Start the authenticated local site and open AI Center."
  (interactive)
  (let ((org-museum-curation-mode 'loopback))
    (org-museum-curation-server-start "ai-center.html")))

(provide 'org-museum-ai-web)
;;; org-museum-ai-web.el ends here
