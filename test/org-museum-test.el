;;; org-museum-test.el --- Tests for org-museum -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org-museum)

(defconst org-museum-test--repo-root
  (file-name-directory
   (directory-file-name (file-name-directory load-file-name)))
  "Repository root used by fixture tests.")

(defun org-museum-test--page (id title modified &optional category tags status path)
  "Build a test page with ID, TITLE, and MODIFIED."
  (make-org-museum-page
   :id id
   :title title
   :path (or path (concat id ".org"))
   :tags (or tags '())
   :category (or category "测试")
   :modified modified
   :links-to nil
   :linked-from nil
   :theme ""
   :status (or status "published")))

(ert-deftest org-museum-html-escaping-covers-cjk-and-special-characters ()
  (should
   (equal
    (org-museum--html-escape "中文 & <tag> \"引号\"" t)
    "中文 &amp; &lt;tag&gt; &quot;引号&quot;"))
  (let ((encoded (org-museum--json-for-html
                  '((title . "</script><中文>&")))))
    (should-not (string-match-p "</script>" encoded))
    (should (string-match-p "\\\\u003c/script\\\\u003e" encoded))
    (should (string-match-p "中文" encoded))))

(ert-deftest org-museum-pages-sort-by-modified-descending ()
  (let* ((old (org-museum-test--page "old" "旧" 10))
         (new (org-museum-test--page "new" "新" 30))
         (middle (org-museum-test--page "middle" "中" 20))
         (sorted (org-museum--sort-pages-by-modified
                  (list old new middle))))
    (should (equal (mapcar #'org-museum-page-id sorted)
                   '("new" "middle" "old")))))

(ert-deftest org-museum-css-source-prefers-straight-repository-over-roam-copy ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-resource-test-" t)))
         (user-emacs-directory root)
         (repo-dir (expand-file-name "straight/repos/org-museum.el/" root))
         (roam-dir (expand-file-name "org-roam/" root))
         (repo-css (expand-file-name "resources/org-museum.css" repo-dir))
         (roam-css (expand-file-name "resources/org-museum.css" roam-dir))
         (org-museum--plugin-dir nil)
         (load-file-name nil))
    (unwind-protect
        (progn
          (make-directory (file-name-directory repo-css) t)
          (make-directory (file-name-directory roam-css) t)
          (with-temp-file repo-css (insert "CURRENT"))
          (with-temp-file roam-css (insert "STALE"))
          (cl-letf (((symbol-function 'locate-library)
                     (lambda (_library) nil)))
            (should (equal (org-museum--css-source-path) repo-css))))
      (delete-directory root t))))

(ert-deftest org-museum-css-source-dereferences-straight-link-placeholder ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-css-link-test-" t)))
         (org-museum--plugin-dir (expand-file-name "straight/links/org-museum/" root))
         (actual (expand-file-name "straight/repos/org-museum.el/resources/org-museum.css"
                                   root))
         (placeholder (expand-file-name "resources/org-museum.css"
                                        org-museum--plugin-dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory actual) t)
          (with-temp-file actual (insert "/* actual */"))
          (make-directory (file-name-directory placeholder) t)
          (with-temp-file placeholder
            (insert (replace-regexp-in-string "\\\\" "/" actual t t)))
          (should (equal (org-museum--css-source-path) actual)))
      (delete-directory root t))))

(ert-deftest org-museum-bundled-resource-is-copied-before-network-fetch ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-bundled-resource-test-" t)))
         (org-museum-root-dir root)
         (org-museum--plugin-dir (expand-file-name "plugin/" root))
         (bundled (expand-file-name "resources/d3.v7.min.js"
                                    org-museum--plugin-dir))
         (dest (expand-file-name "exports/html/resources/d3.v7.min.js" root))
         (network-called nil))
    (unwind-protect
        (progn
          (make-directory (file-name-directory bundled) t)
          (with-temp-file bundled (insert "/* bundled */"))
          (make-directory (file-name-directory dest) t)
          (with-temp-file dest (insert "/* stale */"))
          (cl-letf (((symbol-function 'url-copy-file)
                     (lambda (&rest _args)
                       (setq network-called t)
                       (error "network should not be used"))))
            (should
             (equal (org-museum--ensure-url-resource
                     "https://invalid.example/d3.js" dest "D3.js")
                    dest)))
          (should-not network-called)
          (with-temp-buffer
            (insert-file-contents dest)
            (should (equal (buffer-string) "/* bundled */"))))
      (delete-directory root t))))

(ert-deftest org-museum-bundled-resource-dereferences-straight-link-placeholders ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-link-resource-test-" t)))
         (org-museum-root-dir root)
         (org-museum--plugin-dir (expand-file-name "straight/links/org-museum/" root))
         (actual (expand-file-name "straight/repos/org-museum.el/resources/highlight.min.js"
                                   root))
         (placeholder (expand-file-name "resources/highlight.min.js"
                                        org-museum--plugin-dir))
         (dest (expand-file-name "exports/html/resources/highlight.min.js" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory actual) t)
          (with-temp-file actual (insert "/* real highlight */"))
          (make-directory (file-name-directory placeholder) t)
          (with-temp-file placeholder
            (insert (replace-regexp-in-string "\\\\" "/" actual t t)))
          (should (equal (org-museum--ensure-url-resource
                          "https://invalid.example/highlight.js"
                          dest "Highlight.js")
                         dest))
          (with-temp-buffer
            (insert-file-contents dest)
            (should (equal (buffer-string) "/* real highlight */"))))
      (delete-directory root t))))

(ert-deftest org-museum-page-metadata-is-injected ()
  (let* ((page (org-museum-test--page
                "page-中文" "标题 & 特殊" 100 "Emacs" '("org" "中文")))
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (setf (org-museum-page-path page) "c:/fixture/page.org")
    (puthash (org-museum-page-id page) page pages)
    (with-temp-buffer
      (insert "<html><body><div id=\"content\"></div></body></html>")
      (cl-letf (((symbol-function 'file-equal-p)
                 (lambda (a b) (equal a b))))
        (org-museum--pp-inject-page-attributes "c:/fixture/page.org"))
      (should (string-match-p "data-page-id=\"page-中文\"" (buffer-string)))
      (should (string-match-p "data-page-title=\"标题 &amp; 特殊\"" (buffer-string)))
      (should (string-match-p "data-page-category=\"Emacs\"" (buffer-string)))
      (should (string-match-p "data-page-tags=\"org,中文\"" (buffer-string))))))

(ert-deftest org-museum-article-heading-anchor-clears-sticky-identity ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward
             ".article-container h2,\n.article-container h3,\n.article-container h4" nil t))
    (should (search-forward "scroll-margin-top: 48px" nil t))))

(ert-deftest org-museum-article-width-is-configurable-and-exported ()
  (should (= org-museum-article-max-width 960))
  (let ((org-museum-article-max-width 912)
        (org-museum--index nil))
    (with-temp-buffer
      (insert "<html><body><div id=\"content\"><h1>Article</h1></div></body></html>")
      (should (org-museum--pp-wrap-content-div "article.html" "article.org"))
      (goto-char (point-min))
      (should (search-forward
               "style=\"--museum-article-max-width: 912px\"" nil t))))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward "var(--museum-article-max-width, 960px)" nil t))))

(ert-deftest org-museum-background-effects-are-opt-in-and-motion-safe ()
  (should org-museum-background-effects-enabled)
  (let ((org-museum-background-effects-enabled nil))
    (should (equal (org-museum--sidebar-fx-controls) ""))
    (should (equal (org-museum--script-effects) "")))
  (let* ((org-museum-background-effects-enabled t)
         (controls (org-museum--sidebar-fx-controls))
         (script (org-museum--script-effects)))
    (should (string-match-p "<details class=\"sidebar-fx-controls\"" controls))
    (should (string-match-p "org-museum-bg-fx-v2" script))
    (should-not (string-match-p "org-museum-bg-fx'" script))
    (should (string-match-p "prefers-reduced-motion: reduce" script))
    (should (string-match-p "zen-mode" script))
    (should (string-match-p "MutationObserver" script))
    (should (string-match-p "removeEventListener" script))
    (should (string-match-p "visibilitychange" script))
    (should (string-match-p "pagehide" script))))

(ert-deftest org-museum-long-code-blocks-have-a-real-collapse-state ()
  (let ((script
         (cl-letf (((symbol-function 'org-museum--hljs-lisp-js-src)
                    (lambda (_out-file) "resources/highlight-lisp.min.js"))
                   ((symbol-function 'org-museum--hljs-css-src)
                    (lambda (_out-file) "resources/highlight.monokai.min.css"))
                   ((symbol-function 'org-museum--hljs-js-src)
                    (lambda (_out-file) "resources/highlight.min.js")))
           (org-museum--script-ui-core "article.html"))))
    (should (string-match-p
             (regexp-quote "replace(/\\r?\\n$/,'')") script))
    (should (string-match-p
             (regexp-quote "code.getBoundingClientRect().height>320") script))
    (should (string-match-p "if(isLong)" script))
    (should (string-match-p "org-museum-code-collapsed" script))
    (should (string-match-p "aria-expanded" script)))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward ".org-museum-code-collapsed" nil t))
    (should (search-forward "max-height: 320px" nil t))
    (should (search-forward ".org-museum-code-expanded" nil t))))

(ert-deftest org-museum-cjk-spacing-preserves-code-and-literal-content ()
  (let ((script
         (cl-letf (((symbol-function 'org-museum--hljs-lisp-js-src)
                    (lambda (_out-file) "resources/highlight-lisp.min.js"))
                   ((symbol-function 'org-museum--hljs-css-src)
                    (lambda (_out-file) "resources/highlight.monokai.min.css"))
                   ((symbol-function 'org-museum--hljs-js-src)
                    (lambda (_out-file) "resources/highlight.min.js")))
           (org-museum--script-ui-core "article.html"))))
    (should (string-match-p "parentElement\\.closest" script))
    (should (string-match-p
             (regexp-quote
              "pre,code,kbd,samp,script,style,textarea,[contenteditable]")
             script))))

(ert-deftest org-museum-search-and-tooltip-render-untrusted-text-safely ()
  (let ((ui-script
         (cl-letf (((symbol-function 'org-museum--hljs-lisp-js-src)
                    (lambda (_out-file) "resources/highlight-lisp.min.js"))
                   ((symbol-function 'org-museum--hljs-css-src)
                    (lambda (_out-file) "resources/highlight.monokai.min.css"))
                   ((symbol-function 'org-museum--hljs-js-src)
                    (lambda (_out-file) "resources/highlight.min.js")))
           (org-museum--script-ui-core "article.html")))
        (search-script (org-museum--script-sidebar-search)))
    (should-not (string-match-p
                 (regexp-quote "tt.innerHTML='<strong>'+l.textContent") ui-script))
    (should (string-match-p "tt.replaceChildren" ui-script))
    (should-not (string-match-p
                 (regexp-quote "a.innerHTML = pre +") search-script))
    (should (string-match-p "a.replaceChildren" search-script))))

(ert-deftest org-museum-pages-have-keyboard-skip-navigation ()
  (let* ((root (make-temp-file "org-museum-a11y-test-" t))
         (org-museum-root-dir root)
         (topbar (org-museum--build-topbar
                  (expand-file-name "exports/html/index.html" root) 'home)))
    (should (string-match-p
             (regexp-quote "class=\"museum-skip-link\" href=\"#main-content\"")
             topbar)))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward ".museum-skip-link:focus" nil t))))

(ert-deftest org-museum-lightbox-is-keyboard-accessible ()
  (let ((script
         (cl-letf (((symbol-function 'org-museum--hljs-lisp-js-src)
                    (lambda (_out-file) "resources/highlight-lisp.min.js"))
                   ((symbol-function 'org-museum--hljs-css-src)
                    (lambda (_out-file) "resources/highlight.monokai.min.css"))
                   ((symbol-function 'org-museum--hljs-js-src)
                    (lambda (_out-file) "resources/highlight.min.js")))
           (org-museum--script-ui-core "article.html"))))
    (should (string-match-p "aria-modal" script))
    (should (string-match-p "event.key==='Escape'" script))
    (should (string-match-p "event.key==='Tab'" script))
    (should (string-match-p "lastFocus.focus" script))
    (should (string-match-p "oli.alt=img.alt" script)))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward "#image-lightbox-overlay.visible" nil t))))

(ert-deftest org-museum-mobile-primary-controls-have-touch-sized-hit-areas ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward "--museum-touch-target: 44px" nil t))
    (should (search-forward "min-height: var(--museum-touch-target)" nil t))
    (should (search-forward ".code-copy-btn" nil t))
    (should (search-forward "#graph-category-filters button" nil t))
    (should (search-forward ".museum-status-filters button" nil t))
    (should (search-forward ".museum-filter-summary button" nil t))
    (should (search-forward ".topic-filter" nil t))))

(ert-deftest org-museum-offline-assets-never-fall-back-to-cdns ()
  (cl-letf (((symbol-function 'org-museum--ensure-hljs-deployed)
             (lambda () (list :css nil :js nil :lisp-js nil)))
            ((symbol-function 'org-museum--ensure-d3-deployed)
             (lambda () nil)))
    (should-not (org-museum--hljs-css-src "article.html"))
    (should-not (org-museum--hljs-js-src "article.html"))
    (should-not (org-museum--hljs-lisp-js-src "article.html"))
    (should-not (org-museum--d3-js-src "graph.html"))
    (let ((script (org-museum--script-ui-core "article.html"))
          (graph (org-museum--build-graph-html
                  "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                  "resources/org-museum.css" nil)))
      (should-not (string-match-p "https?://" script))
      (should-not (string-match-p "https?://" graph)))))

(ert-deftest org-museum-graph-emits-one-valid-local-d3-script-tag ()
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (should (string-match-p
             (regexp-quote "<script src=\"resources/d3.v7.min.js\"></script>")
             graph))
    (should-not (string-match-p "src=\"<script" graph))))

(ert-deftest org-museum-org-html-has-complete-monokai-semantic-colors ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (dolist (selector '(".article-container strong"
                        ".article-container em"
                        ".article-container li::marker"
                        ".article-container code:not(.org-museum-code)"
                        ".article-container .todo"
                        ".article-container .timestamp"
                        ".org-keyword"
                        ".org-string"
                        ".org-function-name"
                        ".org-type"
                        ".org-constant"
                        ".org-comment"
                        ".hljs-keyword"
                        ".hljs-string"
                        ".hljs-number"))
      (goto-char (point-min))
      (should (search-forward selector nil t)))))

(ert-deftest org-museum-index-data-and-empty-state-are-stable ()
  (let* ((root (make-temp-file "org-museum-index-test-" t))
         (org-museum-root-dir root)
         (org-museum--plugin-dir org-museum-test--repo-root)
         (out-file (expand-file-name "exports/html/index.html" root))
         (page (org-museum-test--page
                "alpha" "中文 <Alpha>" 42 "Emacs" '("test")))
         (cats `(("Emacs" . (,page))))
         (html (org-museum--build-index-html cats "graph.html" out-file))
         (empty (org-museum--build-index-html nil "graph.html" out-file)))
    (unwind-protect
        (progn
          (should (string-match-p "org-museum-index-data" html))
          (should (string-match-p "\"pageId\":\"alpha\"" html))
          (should (string-match-p "\\\\u003cAlpha\\\\u003e" html))
          (should (string-match-p "搜索标题、分类或标签" html))
          (should (string-match-p "全部笔记 · 按更新时间" html))
          (should (string-match-p "rel=\\\"icon\\\" href=\\\"data:,\\\"" html))
          (should (string-match-p "索引为空" empty))
          (should (string-match-p "\"pages\":\\[\\]" empty)))
      (delete-directory root t))))

(ert-deftest org-museum-index-filters-share-one-url-backed-state ()
  (let* ((root (make-temp-file "org-museum-index-filter-test-" t))
         (org-museum-root-dir root)
         (org-museum--plugin-dir org-museum-test--repo-root)
         (out-file (expand-file-name "exports/html/index.html" root))
         (page (org-museum-test--page
                "alpha" "Alpha" 42 "Sql" '("database") "draft"))
         (html (org-museum--build-index-html
                `(("Sql" . (,page))) "graph.html" out-file)))
    (unwind-protect
        (progn
          (should (string-match-p "data-index-reset" html))
          (should (string-match-p "data-clear-index-filters" html))
          (should (string-match-p "id=\"index-filter-summary\"" html))
          (should (string-match-p "aria-live=\"polite\"" html))
          (should (string-match-p
                   "var state={query:'',category:'',status:'all'}" html))
          (should (string-match-p "history.pushState" html))
          (should (string-match-p "addEventListener('popstate'" html))
          (should (string-match-p "params.get('category')" html))
          (should (string-match-p "params.get('status')" html))
          (should (string-match-p "setAttribute('aria-pressed'" html)))
      (delete-directory root t))))

(ert-deftest org-museum-index-includes-drafts-headings-and-status-filters ()
  (let* ((root (make-temp-file "org-museum-index-status-test-" t))
         (org-museum-root-dir root)
         (org-museum--plugin-dir org-museum-test--repo-root)
         (org-museum-category-label-alist '(("Sql" . "SQL")))
         (default-buffer-file-coding-system 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         (out-file (expand-file-name "exports/html/index.html" root))
         (published-path (expand-file-name "published.org" root))
         (draft-path (expand-file-name "draft.org" root))
         (published (org-museum-test--page
                     "published" "DuckDB 入门" 42 "Sql" '("database")
                     "published" published-path))
         (draft (org-museum-test--page
                 "draft" "DuckDB 草稿" 41 "Sql" '("notes")
                 "draft" draft-path)))
    (unwind-protect
        (progn
          (with-temp-file published-path
            (insert "#+TITLE: DuckDB 入门\n* 安装\n** Windows 配置\n"))
          (with-temp-file draft-path
            (insert "#+TITLE: DuckDB 草稿\n* 查询优化\n"))
          (let ((html (org-museum--build-index-html
                       `(("Sql" . (,published ,draft))) "graph.html" out-file)))
            (should (string-match-p "\"schemaVersion\":2" html))
            (should (string-match-p "\"status\":\"draft\"" html))
            (should (string-match-p "\"title\":\"Windows 配置\"" html))
            (should (string-match-p "\"level\":2" html))
            (should (string-match-p "data-status=\"draft\"" html))
            (should (string-match-p "museum-status-badge" html))
            (should (string-match-p "data-status-filter=\"all\"" html))
            (should (string-match-p "data-status-filter=\"published\"" html))
            (should (string-match-p "data-status-filter=\"draft\"" html))
            (should (string-match-p ">SQL<" html))
            (should (string-match-p "2 篇索引" html))))
      (delete-directory root t))))

(ert-deftest org-museum-description-cache-and-health-are-backward-compatible ()
  (let* ((root (make-temp-file "org-museum-description-test-" t))
         (default-buffer-file-coding-system 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         (described-file (expand-file-name "described.org" root))
         (missing-file (expand-file-name "missing-description.org" root))
         (pages (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (with-temp-file described-file
            (insert "#+TITLE: 有描述\n#+WIKI_ID: described\n"
                    "#+DESCRIPTION: 一段摘要\n#+WIKI_STATUS: published\n"))
          (with-temp-file missing-file
            (insert "#+TITLE: 无描述\n#+WIKI_ID: missing-description\n"
                    "#+WIKI_STATUS: draft\n"))
          (let ((described (org-museum--parse-page-metadata described-file))
                (missing (org-museum--parse-page-metadata missing-file)))
            (should (equal (org-museum-page-description described) "一段摘要"))
            (puthash "described" described pages)
            (puthash "missing-description" missing pages)
            (let ((health (org-museum--index-health-report pages)))
              (should (= (length (plist-get health :isolated)) 2))
              (should (equal (plist-get health :isolated-published)
                             '("described")))
              (should (equal (plist-get health :isolated-draft)
                             '("missing-description")))
              (should (equal (plist-get health :missing-description)
                             '("missing-description")))))
          (let* ((legacy `((pages . [((id . "legacy")
                                      (title . "旧缓存")
                                      (path . ,described-file)
                                      (tags . [])
                                      (category . "Emacs")
                                      (modified . 1)
                                      (links-to . [])
                                      (linked-from . [])
                                      (theme . "")
                                      (status . "published"))])))
                 (index (org-museum--alist-to-index legacy))
                 (page (gethash "legacy" (org-museum-index-pages index))))
            (should page)
            (should-not (org-museum-page-description page))))
      (delete-directory root t))))

(ert-deftest org-museum-external-local-links-are-resolved-and-marked ()
  (let* ((root (make-temp-file "org-museum-local-links-test-" t))
         (source-dir (expand-file-name "pages/Sql" root))
         (source (expand-file-name "source.org" source-dir))
         (target (expand-file-name "target.org" source-dir))
         (external (expand-file-name "queries/查询 & sample.sql" root))
         (external-org (expand-file-name "queries/guide.org" root))
         (missing (expand-file-name "queries/missing.org" root))
         (out-file (expand-file-name "exports/html/pages/Sql/source.html" root))
         (pages (make-hash-table :test 'equal))
         (target-page (org-museum-test--page
                       "target" "目标" 2 "Sql" nil "published" target))
         (source-page (org-museum-test--page
                       "source" "来源" 1 "Sql" nil "published" source))
         (default-buffer-file-coding-system 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         (org-museum-root-dir root)
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (dolist (file (list target external external-org))
            (make-directory (file-name-directory file) t)
            (with-temp-file file (insert "fixture")))
          (make-directory (file-name-directory source) t)
          (with-temp-file source
            (insert "[[file:target.org][内部]]\n"
                    "[[file:../../queries/查询 & sample.sql][查询]]\n"
                    "[[file:../../queries/guide.org][指南]]\n"
                    "[[file:../../queries/missing.org][缺失]]\n"))
          (puthash "source" source-page pages)
          (puthash "target" target-page pages)
          (with-temp-buffer
            (setq buffer-file-name source)
            (insert "[[file:target.org][内部]]\n"
                    "[[file:../../queries/查询 & sample.sql][查询]]\n"
                    "[[file:../../queries/guide.org][指南]]\n"
                    "[[file:../../queries/missing.org][缺失]]\n")
            (org-museum--rewrite-org-museum-links (current-buffer) out-file source)
            (should (string-match-p "target.html" (buffer-string)))
            (should (string-match-p
                     (regexp-quote (replace-regexp-in-string "\\\\" "/" external))
                     (buffer-string))))
          (with-temp-buffer
            (insert (format
                     (concat "<a href=\"%s\">查询</a>"
                             "<a href=\"%s\">指南</a>"
                             "<a href=\"%s\">缺失</a>")
                     (org-museum--path-to-file-url external)
                     (org-museum--path-to-file-url
                      (concat (file-name-sans-extension external-org) ".html"))
                     (org-museum--path-to-file-url missing)))
            (org-museum--pp-annotate-local-file-links)
            (should (string-match-p
                     "data-museum-local-file=\"existing\"" (buffer-string)))
            (should (string-match-p "data-local-path=\".*&amp; sample.sql\""
                                    (buffer-string)))
            (should (string-match-p "data-copy-local-path" (buffer-string)))
            (should (string-match-p "data-local-path=\".*guide.org\""
                                    (buffer-string)))
            (should (string-match-p
                     "data-museum-local-file=\"missing\"" (buffer-string))))
          (let ((health (org-museum--index-health-report pages)))
            (should (= (length (plist-get health :local-external)) 3))
            (should (= (length (plist-get health :local-missing)) 1))))
      (delete-directory root t))))

(ert-deftest org-museum-stale-export-preview-and-cleanup-stay-in-pages-root ()
  (let* ((root (make-temp-file "org-museum-cleanup-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (source (expand-file-name "pages/Emacs/current.org" root))
         (current (expand-file-name "exports/html/pages/Emacs/current.html" root))
         (stale (expand-file-name "exports/html/pages/old.html" root))
         (outside (expand-file-name "exports/html/index.html" root))
         (pages (make-hash-table :test 'equal))
         (page (org-museum-test--page
                "current" "当前页面" 100 "Emacs" nil "published" source))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (puthash "current" page pages)
          (dolist (file (list source current stale outside))
            (make-directory (file-name-directory file) t)
            (with-temp-file file (insert "fixture")))
          (should (equal (org-museum-preview-stale-exports) (list stale)))
          (should-not
           (org-museum--safe-page-html-p outside
                                         (expand-file-name
                                          "exports/html/pages" root)))
          (cl-letf (((symbol-function 'file-symlink-p)
                     (lambda (_file) "simulated-target")))
            (should-not
             (org-museum--safe-page-html-p stale
                                           (expand-file-name
                                            "exports/html/pages" root))))
          (should (file-exists-p stale))
          (should (= (org-museum--clean-stale-exports) 1))
          (should-not (file-exists-p stale))
          (should (file-exists-p current))
          (should (file-exists-p outside))
          (org-museum--write-export-manifest)
          (let ((manifest
                 (expand-file-name
                  "exports/html/.org-museum-manifest.json" root)))
            (should (file-exists-p manifest))
            (with-temp-buffer
              (insert-file-contents manifest)
              (should (search-forward "\"schemaVersion\":1" nil t))
              (should (search-forward "Emacs/current.html" nil t)))))
      (delete-directory root t))))

(ert-deftest org-museum-full-export-failure-skips-manifest-and-cleanup ()
  (let* ((root (make-temp-file "org-museum-failed-export-test-" t))
         (org-museum-root-dir root)
         (org-museum-open-browser-after-export nil)
         (org-museum-clean-stale-html-on-full-export t)
         (pages (make-hash-table :test 'equal))
         (page (org-museum-test--page
                "broken" "导出失败" 100 "Emacs" nil "published"
                (expand-file-name "pages/broken.org" root)))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         (clean-called nil)
         (manifest-called nil))
    (unwind-protect
        (progn
          (puthash "broken" page pages)
          (cl-letf (((symbol-function 'org-museum-index-build)
                     (lambda (&optional _force) org-museum--index))
                    ((symbol-function 'org-museum--ensure-css-deployed)
                     (lambda () nil))
                    ((symbol-function 'org-museum-export-page)
                     (lambda (&rest _args) (error "fixture failure")))
                    ((symbol-function 'org-museum--generate-index-page)
                     (lambda () nil))
                    ((symbol-function 'org-museum-export-graph)
                     (lambda (&rest _args) "graph.html"))
                    ((symbol-function 'org-museum--report-failures)
                     (lambda (_failures) nil))
                    ((symbol-function 'org-museum--write-export-manifest)
                     (lambda () (setq manifest-called t)))
                    ((symbol-function 'org-museum--clean-stale-exports)
                     (lambda () (setq clean-called t))))
            (org-museum-export-all))
          (should-not manifest-called)
          (should-not clean-called))
      (delete-directory root t))))

(ert-deftest org-museum-stale-cleanup-refuses-empty-index ()
  (let* ((root (make-temp-file "org-museum-empty-cleanup-test-" t))
         (org-museum-root-dir root)
         (org-museum-export-dir "exports/html/pages")
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         (stale (expand-file-name "exports/html/pages/stale.html" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory stale) t)
          (with-temp-file stale (insert "must survive"))
          (should-error (org-museum-preview-stale-exports) :type 'user-error)
          (should-error (org-museum--clean-stale-exports) :type 'user-error)
          (should (file-exists-p stale)))
      (delete-directory root t))))

(ert-deftest org-museum-stale-cleanup-refuses-out-of-project-pages-root ()
  (let* ((root (make-temp-file "org-museum-traversal-cleanup-test-" t))
         (org-museum-root-dir (expand-file-name "museum" root))
         (org-museum-export-dir "../outside")
         (pages (make-hash-table :test 'equal))
         (page (org-museum-test--page
                "current" "当前页面" 100 "Emacs" nil "published"
                (expand-file-name "museum/pages/current.org" root)))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory org-museum-root-dir t)
          (make-directory (expand-file-name "outside" root) t)
          (puthash "current" page pages)
          (should-error (org-museum-preview-stale-exports) :type 'user-error))
      (delete-directory root t))))

(ert-deftest org-museum-zero-link-graph-keeps-the-obsidian-style-canvas ()
  (let* ((root (make-temp-file "org-museum-zero-graph-test-" t))
         (org-museum-root-dir root)
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum-category-label-alist '(("Sql" . "SQL")))
         (pages (make-hash-table :test 'equal))
         (draft (org-museum-test--page
                 "duckdb-note" "DuckDB 笔记" 100 "Sql" nil "draft"))
         (published (org-museum-test--page
                     "emacs-note" "Emacs 笔记" 90 "Emacs" nil "published"))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (puthash "duckdb-note" draft pages)
          (puthash "emacs-note" published pages)
          (let* ((json (org-museum--generate-graph-json))
                 (html (org-museum--build-graph-html
                        json "resources/org-museum.css" "resources/d3.v7.min.js")))
            (should (string-match-p "\"status\":\"draft\"" json))
            (should (string-match-p "\"group\":\"SQL\"" json))
            (should (string-match-p "graph-zero-notice" html))
            (should (string-match-p "graph-isolated-fallback" html))
            (should (string-match-p "graph-isolated-list" html))
            (should (string-search "copy.textContent='复制链接'" html))
            (should (string-match-p "graph-wiki-literal" html))
             (should (string-match-p "graph-copy-status" html))
             (should (string-match-p "rel=\\\"icon\\\" href=\\\"data:,\\\"" html))
             (should (string-match-p "setAttribute('aria-pressed'" html))
            (should (string-match-p "navigator.clipboard" html))
            (should (string-match-p "document.execCommand('copy')" html))
            (should (string-match-p "复制失败，请手动复制" html))
            (should (string-match-p "forceSimulation(nodes)" html))
            (should (string-match-p "forceX(width/2)" html))
            (should (string-match-p "graph-node-neighbour" html))
            (should (string-match-p "isolatedFallback.hidden=false" html))
            (should (string-match-p "renderFallbackList" html))
            (should-not
             (string-match-p
              "if(links.length===0)[[:space:]]*{[^}]*return;" html))))
      (delete-directory root t))))

(ert-deftest org-museum-full-export-fixture ()
  (let* ((root (make-temp-file "org-museum-export-test-" t))
         (pages-dir (expand-file-name "pages/Emacs" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum-css-file "resources/org-museum.css")
         (org-museum-open-browser-after-export nil)
         (default-buffer-file-coding-system 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         (org-museum--plugin-dir org-museum-test--repo-root))
    (unwind-protect
        (progn
          (make-directory pages-dir t)
          (with-temp-file (expand-file-name "alpha.org" pages-dir)
            (insert
             "#+TITLE: 中文 & <Alpha>\n"
             "#+WIKI_ID: alpha\n"
             "#+CATEGORY: Emacs\n"
             "#+FILETAGS: :中文:special:\n\n"
             "* 第一节\n正文。\n\n"
             "** 长标题 & 代码\n#+begin_src emacs-lisp\n(message \"ok\")\n#+end_src\n"))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "alpha.org" pages-dir))
            (goto-char (point-max))
            (insert
             "\n** 宽表\n"
             "| 字段一 | 字段二 | 字段三 |\n"
             "|--------+--------+--------|\n"
             "| 很长的内容 | 另一个很长的内容 | 最后一个很长的内容 |\n")
            (write-region (point-min) (point-max)
                          (expand-file-name "alpha.org" pages-dir)))
          (with-temp-file (expand-file-name "beta.org" pages-dir)
            (insert
             "#+TITLE: 第二篇\n"
             "#+WIKI_ID: beta\n"
             "#+CATEGORY: Emacs\n\n"
             "* 内容\n"
             "[[wiki:alpha][返回 Alpha]]\n"))
          (cl-letf (((symbol-function 'url-copy-file)
                     (lambda (&rest _args)
                       (error "fixture export must not use the network")))
                    ((symbol-function 'browse-url)
                     (lambda (&rest _args) nil)))
            (org-museum-export-all))
          (let ((index-file (expand-file-name "exports/html/index.html" root))
                (graph-file (expand-file-name "exports/html/graph.html" root))
                (alpha-file
                 (expand-file-name "exports/html/pages/Emacs/alpha.html" root)))
            (should (file-exists-p index-file))
            (should (file-exists-p graph-file))
            (should (file-exists-p alpha-file))
            (with-temp-buffer
              (insert-file-contents index-file)
              (should (search-forward "museum-index-matrix" nil t))
              (should (search-forward "org-museum-index-data" nil t)))
            (with-temp-buffer
              (insert-file-contents alpha-file)
              (should (search-forward "data-page-id=\"alpha\"" nil t))
              (should (search-forward "museum-article-layout" nil t))
              (should (search-forward "museum-article-identity" nil t))
              (should (search-forward "data-current-section" nil t))
              (should (search-forward "indexedDB.open('org-museum',1)" nil t))
              (goto-char (point-min))
              (should (search-forward "museum-table-scroll" nil t))
              (goto-char (point-min))
              (should (search-forward "data-toc-search" nil t))
              (goto-char (point-min))
              (should (search-forward "data-toc-count" nil t))
              (goto-char (point-min))
              (should (search-forward "data-toc-clear" nil t))
              (goto-char (point-min))
              (should (search-forward "data-toc-empty" nil t))
              (should (search-forward "engagedMs" nil t))
              (should (search-forward "progress>=0.03" nil t))
              (should (search-forward "engagedMs>=30000" nil t))
              (goto-char (point-min))
              (should (search-forward "aria-expanded" nil t))
              (goto-char (point-min))
              (should (search-forward "document.body.appendChild(toc)" nil t))
              (goto-char (point-min))
              (should (search-forward "graph.html?focus=alpha" nil t))
              (goto-char (point-min))
              (should-not (search-forward "cdn.staticfile.net" nil t)))
            (with-temp-buffer
              (insert-file-contents graph-file)
              (should (search-forward "museum-graph-shell" nil t))
              (should (search-forward "var meta=raw.meta||{}" nil t))
              (should (search-forward "new URLSearchParams(location.search)" nil t))
              (should (search-forward ".alphaDecay(alphaDecay)" nil t))
              (should (search-forward "tickCount=0;simulation.alphaTarget(.25)" nil t))
              (should (search-forward "tickCount=0;simulation.alpha(.35)" nil t))
              (goto-char (point-min))
              (should (search-forward "尚未形成知识连线" nil t))
              (goto-char (point-min))
              (should-not (search-forward "https://d3js.org" nil t)))
            (dolist (asset '("d3.v7.min.js"
                             "highlight.min.js"
                             "highlight-lisp.min.js"
                             "highlight.monokai.min.css"))
              (should
               (file-exists-p
                (expand-file-name (concat "exports/html/resources/" asset)
                                  root))))))
      (delete-directory root t))))

(provide 'org-museum-test)

;;; org-museum-test.el ends here
