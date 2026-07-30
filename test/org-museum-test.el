;;; org-museum-test.el --- Tests for org-museum -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org-museum)

(defconst org-museum-test--repo-root
  (file-name-directory
   (directory-file-name (file-name-directory load-file-name)))
  "Repository root used by fixture tests.")

(defun org-museum-test--page (id title modified &optional category tags)
  "Build a test page with ID, TITLE, and MODIFIED."
  (make-org-museum-page
   :id id
   :title title
   :path (concat id ".org")
   :tags (or tags '())
   :category (or category "测试")
   :modified modified
   :links-to nil
   :linked-from nil
   :theme ""
   :status "published"))

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
          (should (string-match-p "最近更新" html))
          (should (string-match-p "索引为空" empty))
          (should (string-match-p "\"pages\":\\[\\]" empty)))
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
          (with-temp-file (expand-file-name "beta.org" pages-dir)
            (insert
             "#+TITLE: 第二篇\n"
             "#+WIKI_ID: beta\n"
             "#+CATEGORY: Emacs\n\n"
             "* 内容\n"
             "[[wiki:alpha][返回 Alpha]]\n"))
          (cl-letf (((symbol-function 'org-museum--ensure-d3-deployed)
                     (lambda () nil))
                    ((symbol-function 'org-museum--ensure-hljs-deployed)
                     (lambda () nil))
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
              (should (search-forward "indexedDB.open('org-museum',1)" nil t)))
            (with-temp-buffer
              (insert-file-contents graph-file)
              (should (search-forward "museum-graph-shell" nil t))
              (should (search-forward "尚未形成知识连线" nil t)))))
      (delete-directory root t))))

(provide 'org-museum-test)

;;; org-museum-test.el ends here
