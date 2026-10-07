;;; org-museum-pipeline.el --- Headless source publishing -*- lexical-binding: t; -*-

;; Run in a separate Emacs process.  Legacy HTML is never re-exported.
(require 'org-museum)

(defvar org-museum-pipeline--legacy nil)
(defvar org-museum-pipeline--paths nil)

(defun org-museum-pipeline--merge-index (&rest _)
  "Add preserved published pages to the source index."
  (dolist (record org-museum-pipeline--legacy)
    (let* ((id (alist-get 'id record))
           (path (alist-get 'sourcePath record))
           (date (or (alist-get 'modifiedDate record) "1970-01-01"))
           (time (float-time (date-to-time (concat date "T00:00:00Z"))))
           (page (make-org-museum-page
                  :id id :title (alist-get 'title record) :path path
                  :category (or (alist-get 'category record) "uncategorized")
                  :tags (alist-get 'tags record) :created time :modified time
                  :date-source 'org-date :status "published"
                  :description (alist-get 'description record))))
      (org-museum--index-register-page org-museum--index page)))
  (org-museum--scan-resolve-links org-museum--index))

(defun org-museum-pipeline--filename (original file)
  "Resolve preserved FILE to its original HTML location."
  (or (gethash (expand-file-name file) org-museum-pipeline--paths)
      (funcall original file)))

(defun org-museum-pipeline--export-page (original file &rest args)
  "Keep preserved legacy HTML byte-for-byte."
  (if-let* ((html (gethash (expand-file-name file) org-museum-pipeline--paths)))
      html
    (apply original file args)))

(defun org-museum-pipeline-build (root output legacy-file)
  "Build ROOT source notes into OUTPUT, merging LEGACY-FILE metadata.
ROOT is a disposable build directory; OUTPUT already contains legacy files.
Code blocks are not evaluated.  Only this process receives the adapters."
  (setq org-museum-root-dir (file-name-as-directory (expand-file-name root))
        org-museum-pages-subdir "notes"
        org-museum-scan-dir "notes"
        org-museum-scan-excluded-directories '("_legacy")
        org-museum-shared-export-dir (expand-file-name output)
        org-museum-export-dir (expand-file-name "pages/collected" output)
        org-museum-open-browser-after-export nil
        org-museum-clean-stale-html-on-full-export nil
        org-museum-pipeline--paths (make-hash-table :test 'equal))
  (setq org-museum-pipeline--legacy
        (when (file-exists-p legacy-file)
          (let ((json-array-type 'list) (json-object-type 'alist))
            (json-read-file legacy-file))))
  (dolist (record org-museum-pipeline--legacy)
    (puthash (expand-file-name (alist-get 'sourcePath record))
             (expand-file-name (alist-get 'href record) output)
             org-museum-pipeline--paths))
  (advice-add 'org-museum-index-build :after #'org-museum-pipeline--merge-index)
  (advice-add 'org-museum--export-filename :around #'org-museum-pipeline--filename)
  (advice-add 'org-museum-export-page :around #'org-museum-pipeline--export-page)
  (unwind-protect
      (let ((org-export-use-babel nil)
            (org-confirm-babel-evaluate t)
            (org-export-allow-bind-keywords nil))
        (org-museum--export-all-current))
    (advice-remove 'org-museum-index-build #'org-museum-pipeline--merge-index)
    (advice-remove 'org-museum--export-filename #'org-museum-pipeline--filename)
    (advice-remove 'org-museum-export-page #'org-museum-pipeline--export-page)))

(defun org-museum-pipeline-batch ()
  "Batch entry; paths arrive through environment variables, never eval text."
  (org-museum-pipeline-build
   (or (getenv "MUSEUM_SOURCE_ROOT") (error "MUSEUM_SOURCE_ROOT is required"))
   (or (getenv "MUSEUM_OUTPUT") (error "MUSEUM_OUTPUT is required"))
   (or (getenv "MUSEUM_LEGACY") (error "MUSEUM_LEGACY is required"))))

(defun org-museum-pipeline--guard-legacy-deploy (&rest _)
  "Refuse a legacy HTML push when the target is owned by Actions."
  (when (and org-museum-publish-directory
             (file-exists-p (expand-file-name "museum.json" org-museum-publish-directory)))
    (let* ((json-object-type 'alist)
           (config (json-read-file (expand-file-name "museum.json" org-museum-publish-directory))))
      (when (equal (alist-get 'publishMode config) "actions")
        (user-error "此知识库由 GitHub Actions 发布；请编辑 notes/，不要推送生成网页")))))

(advice-add 'org-museum-publish-deploy :before #'org-museum-pipeline--guard-legacy-deploy)
(advice-add 'org-museum--publish-deploy-current :before #'org-museum-pipeline--guard-legacy-deploy)
(provide 'org-museum-pipeline)
;;; org-museum-pipeline.el ends here
