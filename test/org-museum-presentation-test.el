;;; org-museum-presentation-test.el --- Presentation contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'org-museum)

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
