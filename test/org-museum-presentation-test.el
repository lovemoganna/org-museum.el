;;; org-museum-presentation-test.el --- Presentation contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'org-museum)

(ert-deftest org-museum-theme-head-replaces-local-duplicates-only ()
  (cl-letf (((symbol-function 'org-museum--theme-script-tag)
             (lambda (_) "<script src=\"../../resources/org-museum-theme.js?v=current\"></script>")))
    (with-temp-buffer
      (insert "<html><head><script src=\"../../resources/org-museum-theme.js?v=old\"></script>\n"
              "<SCRIPT SRC='../../resources/org-museum-theme.js?v=older'></SCRIPT>"
              "<link rel=\"stylesheet\" href=\"../../resources/org-museum.css?v=old\">"
              "<link rel=\"stylesheet\" href=\"../../resources/org-museum.css?v=older\">"
              "<link rel=\"stylesheet\" href=\"author.css\">"
              "<script src=\"https://example.test/resources/org-museum-theme.js\"></script>"
              "<script>window.authorCode = true;</script></head>"
              "<body><pre>&lt;script src=\"resources/org-museum-theme.js\"&gt;</pre></body></html>")
      (org-museum--pp-normalize-shared-head "article.html")
      (let ((once (buffer-string)))
        (should (string-search "?v=current" once))
        (should-not (string-search "?v=old" once))
        (should (string-search "https://example.test/resources/org-museum-theme.js" once))
        (should (string-search "window.authorCode = true;" once))
        (should (string-search "author.css" once))
        (should (= 1 (with-temp-buffer
                       (insert once) (goto-char (point-min))
                       (let ((count 0))
                         (while (search-forward "org-museum.css" nil t) (cl-incf count)) count))))
        (should (string-search "&lt;script src=\"resources/org-museum-theme.js\"&gt;" once))
        (org-museum--pp-normalize-shared-head "article.html")
        (should (equal once (buffer-string)))))))

(ert-deftest org-museum-theme-head-adds-missing-bootstrap-without-touching-body ()
  (cl-letf (((symbol-function 'org-museum--theme-script-tag)
             (lambda (_) "<script src=\"resources/org-museum-theme.js?v=current\"></script>")))
    (with-temp-buffer
      (insert "<head><title>Note</title></head><body>Keep me</body>")
      (org-museum--pp-normalize-shared-head "index.html")
      (should (string-search "?v=current" (buffer-string)))
      (should (string-suffix-p "<body>Keep me</body>" (buffer-string))))))

(ert-deftest org-museum-pathways-count-real-tagged-pages-and-resolve-links ()
  "A cross-category tagged note counts just as it does in browser filtering."
  (let ((pages (list
                (make-org-museum-page :id "start" :path "C:/notes/ontology/ontology-concept-boundaries.org" :tags '("ontology"))
                (make-org-museum-page :id "cross-category" :path "C:/notes/sql/model.org" :tags '("ontology" "sql"))
                (make-org-museum-page :id "other-case" :path "C:/notes/ontology/other.org" :tags '("Ontology")))))
    (cl-letf (((symbol-function 'org-museum--page-href)
               (lambda (id out)
                 (should (equal id "start"))
                 (should (equal out "custom/index.html"))
                 "../notes/model.html?a=1&b=2")))
      (let ((html (org-museum--build-learning-pathways-html pages "custom/index.html")))
        (should (string-search "2 篇笔记" html))
        (should (string-search "../notes/model.html?a=1&amp;b=2" html))
        (should-not (string-search "data-pathway=\"duckdb\"" html))))))

(ert-deftest org-museum-pathways-omit-missing-or-untagged-starts ()
  "Partial and empty libraries must not advertise nonexistent starting notes."
  (should (equal "" (org-museum--build-learning-pathways-html nil "index.html")))
  (should (equal "" (org-museum--build-learning-pathways-html
                     (list (make-org-museum-page :id "unrelated" :path "/notes/sql/other.org" :tags '("sql"))
                           (make-org-museum-page :id "untagged-start" :path "/notes/sql/duckdb.org"))
                     "index.html"))))

(ert-deftest org-museum-related-excludes-article-only-org-controls ()
  "Reading panes retain content without copying an unbound article toolbar."
  (let ((result
         (org-museum--related-clean-fragment
          (concat "<div class=\"museum-article-view-toolbar\" role=\"group\">"
                  "<button data-article-syntax>Org Mode</button><span role=\"status\"></span></div>"
                  "<section class=\"museum-org-view\" hidden><pre class=\"museum-org-source\">"
                  "<span>" (make-string 100000 ?x) "</span></pre></section>"
                  "<h2 id=\"kept\">Heading</h2><p>Body</p>"
                  "<pre class=\"src src-sql\">SELECT 1;</pre>"))))
    (should-not (string-search "data-article-syntax" result))
    (should-not (string-search "museum-org-source" result))
    (should-not (string-search "museum-org-view" result))
    (should (string-search "<h2 id=\"kept\">Heading</h2><p>Body</p>" result))
    (should (string-search "SELECT 1;" result))))

(ert-deftest org-museum-org-view-preserves-syntax-and-emacs-font-lock ()
  (let ((file (make-temp-file "museum-org-view-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TITLE: Example\n* Visible\n*bold* and [[https://example.com][link]]\n#+begin_src emacs-lisp\n(message \"hello\")\n#+end_src\n"))
          (let ((html (org-museum--org-source-html file)))
            (should (string-search "org-face-org-level-1" html))
            (should (string-search "org-face-org-link" html))
            (should (string-search "org-face-font-lock-string-face" html))
            (should (string-search "#+begin_src" html))))
      (delete-file file))))

(ert-deftest org-museum-org-view-respects-export-privacy-and-never-evaluates ()
  (let ((file (make-temp-file "museum-org-private-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Visible\n:PROPERTIES:\n:SECRET: drawer-secret\n:END:\nPublic text.\n#+begin_src emacs-lisp :exports results\n(error \"must-not-run\")\n#+end_src\n#+RESULTS:\n: saved-result\n* Private :noexport:\nprivate-secret\n"))
          (let ((html (org-museum--org-source-html file)))
            (should (string-search "Public text" html))
            (should-not (string-search "drawer-secret" html))
            (should-not (string-search "private-secret" html))
            (should (string-search "saved-result" html))))
      (delete-file file))))

(ert-deftest org-museum-browser-ai-catalog-includes-only-published-metadata ()
  (let* ((pages (make-hash-table :test #'equal))
         (org-museum--index (make-org-museum-index :pages pages)))
    (puthash "public" (make-org-museum-page :id "public" :title "Public" :category "Test" :status "published" :path "pages/public.org") pages)
    (puthash "private" (make-org-museum-page :id "private" :title "Private" :status "draft" :path "pages/private.org") pages)
    (let ((catalog (org-museum-ai-web--browser-pages "ai-center.html")))
      (should (= (length catalog) 1))
      (should (equal (alist-get 'id (aref catalog 0)) "public"))
      (should-not (alist-get 'body (aref catalog 0))))))
