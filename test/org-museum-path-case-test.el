;;; org-museum-path-case-test.el --- Cross-platform publish paths -*- lexical-binding: t; -*-
(require 'ert)
(require 'org-museum)

(ert-deftest org-museum-publish-links-require-exact-case ()
  "A path Windows resolves must still fail when it would 404 on Pages."
  (let ((root (make-temp-file "museum-link-case-" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages/AI" root) t)
          (with-temp-file (expand-file-name "pages/AI/学习.html" root) (insert "<p>note</p>"))
          (with-temp-file (expand-file-name "index.html" root)
            (insert "<a href='pages/ai/%E5%AD%A6%E4%B9%A0.html'>note</a>"))
          (should-error
           (org-museum--publish-validate-page-links root '("index.html" "pages/AI/学习.html"))
           :type 'org-museum-publish-error)
          (with-temp-file (expand-file-name "index.html" root)
            (insert "<a href='pages/AI/%E5%AD%A6%E4%B9%A0.html?view=source#section'>note</a>"
                    "<a href='pages/AI/学习.html'>plain unicode</a>"))
          (org-museum--publish-validate-page-links root '("index.html" "pages/AI/学习.html")))
      (delete-directory root t))))

(ert-deftest org-museum-publish-case-only-migration-preserves-content-and-git-paths ()
  "Exercise the real Windows filesystem and Git index, including a stale spelling."
  (skip-unless (eq system-type 'windows-nt))
  (let* ((root (make-temp-file "museum-case-git-" t))
         (staging (make-temp-file "museum-case-stage-" t))
         (org-museum-publish-directory root)
         (old "pages/ai/skills/学习.html")
         (desired "pages/AI/skills/学习.html"))
    (unwind-protect
        (progn
          (org-museum--publish-run "git" '("init"))
          (org-museum--publish-run "git" '("config" "user.name" "Museum Test"))
          (org-museum--publish-run "git" '("config" "user.email" "test@example.invalid"))
          (make-directory (file-name-directory (expand-file-name old root)) t)
          (with-temp-file (expand-file-name old root) (insert "original"))
          (org-museum--publish-run "git" '("add" "."))
          (org-museum--publish-run "git" '("commit" "-m" "baseline"))
          (make-directory (file-name-directory (expand-file-name desired staging)) t)
          (with-temp-file (expand-file-name desired staging) (insert "updated"))
          (org-museum--publish-apply-staging staging root (list desired) (list old))
          (should (member "AI" (directory-files (expand-file-name "pages" root))))
          (should-not (member "ai" (directory-files (expand-file-name "pages" root))))
          (with-temp-buffer
            (insert-file-contents (expand-file-name desired root))
            (should (equal (buffer-string) "updated")))
          (org-museum--publish-stage-and-commit (org-museum--publish-git-status-paths))
          (let ((tracked (split-string
                          (cdr (org-museum--publish-run "git" '("ls-files" "-z"))) "\0" t)))
            (should (member desired tracked))
            (should-not (member old tracked)))
          (org-museum--publish-validate-manifest-integrity
           root (org-museum--publish-read-manifest root)))
      (delete-directory root t)
      (delete-directory staging t))))

(ert-deftest org-museum-export-repairs-existing-directory-spelling ()
  "Incremental export cannot keep a stale lowercase output directory."
  (skip-unless (eq system-type 'windows-nt))
  (let ((root (make-temp-file "museum-export-case-" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "ai/skills" root) t)
          (with-temp-file (expand-file-name "ai/skills/note.html" root) (insert "unchanged"))
          (org-museum--ensure-output-path-case (expand-file-name "AI/skills/note.html" root) root)
          (should (member "AI" (directory-files root)))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "AI/skills/note.html" root))
            (should (equal (buffer-string) "unchanged"))))
      (delete-directory root t))))
