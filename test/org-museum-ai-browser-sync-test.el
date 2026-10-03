;;; org-museum-ai-browser-sync-test.el --- Browser import safety -*- lexical-binding: t -*-
(require 'ert)
(require 'org-museum)

(defmacro org-museum-ai-sync-test--wiki (&rest body)
  `(let* ((org-museum-root-dir (make-temp-file "org-museum-browser-sync-" t))
          (org-museum--index nil) (org-museum-knowledge--root nil)
          (org-museum-knowledge--queue nil) (org-museum-knowledge--analyses nil)
          (org-museum-knowledge--experiences nil) (org-museum-knowledge--relations nil)
          (org-museum-knowledge--persist-timer nil) (org-museum-knowledge--auto-timer nil)
          (org-museum-ai-web--previews (make-hash-table :test #'equal))
          (file (expand-file-name "pages/first.org" org-museum-root-dir)))
     (unwind-protect
         (progn
           (make-directory (file-name-directory file) t)
           (with-temp-file file (insert "#+TITLE: First\n#+WIKI_ID: first\nSaved source evidence.\n"))
           (setq org-museum--index
                 (make-org-museum-index :pages (let ((table (make-hash-table :test #'equal)))
                                                (puthash "first" (make-org-museum-page :id "first" :path file :title "First" :status "published") table) table)))
           (org-museum-knowledge--ensure)
    (let ((org-museum-ai-session--root nil) (org-museum-ai-session--items nil)
          (org-museum-ai-session--captures-root nil) (org-museum-ai-session--captures nil)
          (org-museum-derived--root nil) (org-museum-derived--items nil))
      ,@body))
       (when (timerp org-museum-knowledge--persist-timer) (cancel-timer org-museum-knowledge--persist-timer))
       (when (timerp org-museum-knowledge--auto-timer) (cancel-timer org-museum-knowledge--auto-timer))
       (delete-directory org-museum-root-dir t))))

(defun org-museum-ai-sync-test--workspace (file root)
  `((schemaVersion . 1) (workspaceId . ,(secure-hash 'sha256 (file-truename root)))
    (sessions . (((id . "browser-test") (revision . 1) (createdAt . "2026-10-01")
                  (sources . (((pageId . "first") (hash . ,(org-museum-knowledge--file-hash file))
                               (file . "C:/outside/forged.org"))))
                  (turns . (((id . "turn-1") (prompt . "测试问题") (answer . "已完成回答") (status . "done"))))
                  (directions . nil) (proposals . nil))))
    (captures . nil) (patches . nil) (relations . nil) (experiences . nil) (derived . nil)))

(ert-deftest org-museum-ai-browser-sync-is-reviewed-and-does-not-trust-file-paths ()
  (org-museum-ai-sync-test--wiki
   (let* ((workspace (org-museum-ai-sync-test--workspace file org-museum-root-dir))
          (preview (org-museum-ai-web--browser-sync-preview `((workspace . ,workspace)))))
     (should-not org-museum-ai-session--items)
     (cl-letf (((symbol-function 'org-museum-index-build) (lambda (&rest _) t))
               ((symbol-function 'org-museum--start-background-job) (lambda (&rest _) t)))
       (org-museum-ai-web--browser-sync-confirm `((transactionId . ,(alist-get 'transactionId preview)))))
     (let ((source (car (alist-get 'sources (car org-museum-ai-session--items)))))
       (should (equal "first" (alist-get 'pageId source)))
       (should-not (alist-get 'file source)))
     (should-error (org-museum-ai-web--browser-sync-confirm `((transactionId . ,(alist-get 'transactionId preview))))))))

(ert-deftest org-museum-ai-browser-sync-rechecks-source-after-preview ()
  (org-museum-ai-sync-test--wiki
   (let ((preview (org-museum-ai-web--browser-sync-preview
                   `((workspace . ,(org-museum-ai-sync-test--workspace file org-museum-root-dir))))))
     (with-temp-file file (insert "Changed source"))
     (should-error (org-museum-ai-web--browser-sync-confirm `((transactionId . ,(alist-get 'transactionId preview)))))
     (should-not org-museum-ai-session--items))))

(ert-deftest org-museum-ai-browser-sync-rolls-back-storage-failure ()
  (org-museum-ai-sync-test--wiki
   (let ((preview (org-museum-ai-web--browser-sync-preview
                   `((workspace . ,(org-museum-ai-sync-test--workspace file org-museum-root-dir))))))
     (cl-letf (((symbol-function 'org-museum-ai-session--captures-save) (lambda () (error "write failed"))))
       (should-error (org-museum-ai-web--browser-sync-confirm `((transactionId . ,(alist-get 'transactionId preview))))))
     (should-not org-museum-ai-session--items)
     (should-not (file-exists-p (org-museum-ai-session--path))))))

(ert-deftest org-museum-ai-browser-sync-writes-reviewed-addition-once-and-protects-emacs-edits ()
  (org-museum-ai-sync-test--wiki
   (let* ((workspace (org-museum-ai-sync-test--workspace file org-museum-root-dir))
          (original-hash (org-museum-knowledge--file-hash file)))
     (setf (alist-get 'patches workspace)
           `(((id . "browser-patch") (sessionId . "browser-test") (targetPageId . "first")
              (title . "Reviewed addition") (body . "This is the reviewed addition body.") (baseHash . ,original-hash))))
     (cl-letf (((symbol-function 'org-museum-index-build) (lambda (&rest _) t))
               ((symbol-function 'org-museum--start-background-job) (lambda (&rest _) t)))
       (let* ((preview (org-museum-ai-web--browser-sync-preview `((workspace . ,workspace))))
              (result (org-museum-ai-web--browser-sync-confirm `((transactionId . ,(alist-get 'transactionId preview))))))
         (should (equal (alist-get 'first (alist-get 'sourceHashes result)) (org-museum-knowledge--file-hash file)))
         (setf (alist-get 'patches workspace) nil
               (alist-get 'hash (car (alist-get 'sources (car (alist-get 'sessions workspace))))) (org-museum-knowledge--file-hash file)
               (alist-get 'revision (car (alist-get 'sessions workspace))) 2))
       (let ((preview (org-museum-ai-web--browser-sync-preview `((workspace . ,workspace)))))
         (org-museum-ai-web--browser-sync-confirm `((transactionId . ,(alist-get 'transactionId preview)))))
       (with-temp-buffer (insert-file-contents file)
                         (should (= 1 (how-many "browser-addition: browser-patch" (point-min) (point-max)))))
       (setf (alist-get 'revision (car org-museum-ai-session--items)) 99)
       (should-error (org-museum-ai-web--browser-sync-preview `((workspace . ,workspace))))))))

(provide 'org-museum-ai-browser-sync-test)
