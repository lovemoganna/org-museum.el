;;; org-museum-editing-performance-test.el --- Editing isolation -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org-museum)

(ert-deftest org-museum-save-metadata-does-not-run-editing-hooks ()
  "Save-time metadata parsing must not activate interactive integrations."
  (let ((file (make-temp-file "museum-editing-" nil ".org"))
        (calls 0))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert ":PROPERTIES:\n:ID: note-id\n:END:\n"
                    "#+TITLE: Editing test\n#+FILETAGS: :test:\n"
                    "#+WIKI_RELATION: other | supports\n* Heading\nBody\n"))
          (let* ((org-mode-hook (list (lambda () (cl-incf calls))))
                 (page (org-museum--parse-page-metadata file)))
            (should (= calls 0))
            (should (equal (org-museum-page-id page) "note-id"))
            (should (equal (org-museum-page-title page) "Editing test"))
            (should (equal (org-museum-page-tags page) '("test")))))
      (delete-file file))))

(ert-deftest org-museum-save-flush-keeps-editing-hooks-out-of-indexing ()
  "Exercise the actual deferred-save path, including index persistence."
  (let* ((root (make-temp-file "museum-save-editing-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir nil)
         (org-museum--index nil)
         (org-museum--pending-save-files (make-hash-table :test #'equal))
         (org-museum--project-save-timer nil)
         (org-museum--project-save-retry-used nil)
         (org-museum-knowledge--root nil)
         (org-museum-knowledge--queue nil)
         (org-museum-knowledge--analyses nil)
         (org-museum-knowledge--experiences nil)
         (org-museum-knowledge--relations nil)
         (org-museum-knowledge--persist-timer nil)
         (org-museum-knowledge--auto-timer nil)
         (org-museum-knowledge-work-mode 'manual)
         (file (expand-file-name "note.org" root))
         (calls 0))
    (unwind-protect
        (let* ((hook (lambda () (cl-incf calls)))
               (org-mode-hook (list hook))
               (text-mode-hook (list hook))
               (after-change-major-mode-hook (list hook)))
          (with-temp-file file (insert "#+TITLE: Before\n#+WIKI_ID: note\n"))
          (org-museum-index-build t)
          (with-temp-buffer
            (setq buffer-file-name file)
            (delay-mode-hooks (org-mode))
            (setq org-museum-knowledge--reminded t)
            (org-museum-mode 1)
            (insert "#+TITLE: After\n#+WIKI_ID: note\n* Heading\nUpdated\n")
            (write-region (point-min) (point-max) file nil 'silent)
            (run-hooks 'after-save-hook))
          (when (timerp org-museum--project-save-timer)
            (cancel-timer org-museum--project-save-timer))
          (org-museum--flush-pending-saves)
          (should (= calls 0))
          (should (= 0 (hash-table-count org-museum--pending-save-files)))
          (should (equal "After" (org-museum-page-title
                                  (gethash "note" (org-museum-index-pages
                                                   org-museum--index)))))
          (should (file-regular-p (org-museum--index-file-path))))
      (when (timerp org-museum--project-save-timer)
        (cancel-timer org-museum--project-save-timer))
      (when (timerp org-museum-knowledge--persist-timer)
        (cancel-timer org-museum-knowledge--persist-timer))
      (delete-directory root t))))

;;; org-museum-editing-performance-test.el ends here
