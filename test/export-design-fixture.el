;;; export-design-fixture.el --- Build Org Museum design fixtures -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'org-museum)

(defconst org-museum-fixture--repo-root
  (file-name-directory
   (directory-file-name (file-name-directory load-file-name))))

(defconst org-museum-fixture--pages
  '(("01-emacs.org"
     "emacs-observer"
     "Emacs 插件高价值增量观察（滚动）"
     "Emacs"
     "2026-07-26"
     ":emacs:plugin:brief:")
    ("02-ontology-mvp.org"
     "ontology-mvp"
     "本体MVP"
     "Ontology"
     "2026-07-12"
     ":ontology:mvp:")
    ("03-duckdb-package.org"
     "duckdb-emacs-package"
     "DuckDB 实战入门：Emacs Package 数据分析"
     "Sql"
     "2026-06-27"
     ":duckdb:sql:emacs:")
    ("04-duckdb-ontology.org"
     "duckdb-ontology"
     "DuckDB 本体建模"
     "Ontology"
     "2026-06-21"
     ":duckdb:ontology:")
    ("05-sicp.org"
     "sicp-sqrt"
     "SICP Lisp 过程抽象练习：平方根迭代逼近器"
     "lisp"
     "2026-06-13"
     ":sicp:lisp:")
    ("06-orgtheme.org"
     "orgtheme-pro"
     "OrgTheme 专业版主题开发系统"
     "Theme"
     "2026-06-08"
     ":theme:emacs:")))

(defun org-museum-fixture--write-page (root spec linked)
  (pcase-let ((`(,filename ,id ,title ,category ,date ,tags) spec))
    (let* ((dir (expand-file-name (concat "pages/" category) root))
           (file (expand-file-name filename dir))
           (coding-system-for-write 'utf-8-unix))
      (make-directory dir t)
      (with-temp-file file
        (insert
         (format "#+TITLE: %s\n" title)
         (format "#+WIKI_ID: %s\n" id)
         (format "#+CATEGORY: %s\n" category)
         (format "#+DATE: %s\n" date)
         (format "#+FILETAGS: %s\n\n" tags))
        (if (string= id "emacs-observer")
            (insert
             "* 筛选原则\n"
             "不追求固定数量，只保留会改变配置、工作流或维护判断的增量。"
             "优先记录 P0 / P1，P2 只在确有异常价值时进入简报。\n\n"
             "| 级别 | 进入条件 | 处理方式 |\n"
             "|------+----------+----------|\n"
             "| P0 | 立即影响配置或安全 | 当天验证 |\n"
             "| P1 | 改变主要工作流 | 纳入下一次配置迭代 |\n"
             "| P2 | 具有异常高价值 | 保留观察 |\n\n"
             "* 本次观察\n"
             "- Org Mode 维护动态\n"
             "- 包管理与兼容性\n"
             "- 当前工作台可直接采用的变化\n\n"
             "* 影响与适用场景\n"
             "本轮变化主要影响包刷新、补全排序和长期维护判断。"
             "所有建议先在隔离配置中验证，再进入主工作台。\n\n"
             "* 给当前 Emacs 工作台的行动建议\n"
             "综合权衡稳定性与收益，本次建议优先合并 Orderless 的配置优化，"
             "并在单机环境试用 tree-sitter-lisp 的增量解析能力。\n\n"
             "#+begin_src emacs-lisp\n"
             "(setq completion-styles '(orderless basic))\n"
             "(package-refresh-contents)\n"
             "#+end_src\n\n"
             (if linked
                 "[[wiki:orgtheme-pro][查看 OrgTheme 专业版主题开发系统]]\n"
               "当前版本尚未添加 Org 链接。\n")
             "\n* 变更记录\n"
             "2026-07-26：完成本轮筛选与行动建议。\n")
          (insert
           "* 概览\n"
           (format "%s 的工作笔记，用于验证 *粗体*、/强调/、~行内代码~、中英文长标题、表格与关系索引。\n\n" title)
           "* 内容\n"
           "这里保留一段简洁正文，确保导出布局使用真实 Org 层级。\n"
           (if (and linked (string= id "ontology-mvp"))
               "\n[[wiki:emacs-observer][回到 Emacs 插件高价值增量观察]]\n"
             ""))
          (when (string= id "duckdb-emacs-package")
            (insert "\n* 长代码块\n#+begin_src sql\n")
            (dotimes (line 24)
              (insert (format "SELECT %d AS lesson_step;\n" (1+ line))))
            (insert "#+end_src\n"))))
      (let* ((parts (mapcar #'string-to-number (split-string date "-")))
             (time (encode-time 0 0 12
                                (nth 2 parts) (nth 1 parts) (nth 0 parts))))
        (set-file-times file time)))))

(defun org-museum-fixture--export-root (root linked)
  (dolist (spec org-museum-fixture--pages)
    (org-museum-fixture--write-page root spec linked))
  (let ((org-museum-root-dir root)
        (org-museum-scan-dir "pages")
        (org-museum-pages-subdir "pages")
        (org-museum-export-dir "exports/html/pages")
        (org-museum-shared-export-dir "exports/html")
        (org-museum-css-file "resources/org-museum.css")
        (org-museum-open-browser-after-export nil)
        (org-museum--plugin-dir org-museum-fixture--repo-root)
        (default-buffer-file-coding-system 'utf-8-unix)
        (coding-system-for-write 'utf-8-unix))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (&rest _args) nil)))
      (org-museum-export-all))))

(let* ((base (make-temp-file "org-museum-design-fixture-" t))
       (main-root (expand-file-name "main" base))
       (zero-root (expand-file-name "zero" base)))
  (make-directory main-root t)
  (make-directory zero-root t)
  (org-museum-fixture--export-root main-root t)
  (org-museum-fixture--export-root zero-root nil)
  (princ (format "FIXTURE_BASE=%s\n" base))
  (princ (format "MAIN_EXPORT=%s\n"
                 (expand-file-name "exports/html" main-root)))
  (princ (format "ZERO_EXPORT=%s\n"
                 (expand-file-name "exports/html" zero-root))))

;;; export-design-fixture.el ends here
