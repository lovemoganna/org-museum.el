;;; org-museum.el --- Org Mode Wiki Generator -*- lexical-binding: t -*-

;; Copyright (C) 2026
;; Version: 2.3.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: wiki, org-mode, hypermedia

;;; Commentary:
;; MECE-refactored static wiki generator based on Org Mode.
;; v2.3.0 — all prior fixes retained + 4 new changes:
;;   Fix-01  §9   Bidirectional linked-from stale removal on third-party edits
;;   Fix-02  §29  Debounced on-save via run-with-idle-timer
;;   Fix-03  §11  CSS mtime included in needs-export-p
;;   Fix-04  §18  file: asset link path rewriting for non-.org resources
;;   Fix-05  §12  pp-wrap-content-div returns bool; postprocess short-circuits
;;   Fix-06  §23  D3 simulation pre-heat for large tier (meta.pre-ticks)
;;   Fix-07  §22  graph-render-js :link-arrow support via SVG defs/marker
;;   Fix-08  §22  Local graph neighbour capping with _overflow virtual node
;;   Fix-09  §24  Scroll spy uses IntersectionObserver relative to #main-scroll
;;   Fix-10  §25  Tubes mousemove listener promoted to module-level named ref
;;   Fix-11  §17  update-links-globally handles [[id:...]] links
;;   Fix-12  §28  Status report includes stale-exports count
;;   Fix-13  §29  defvar org-museum--dispatch-transient before with-eval-after-load
;;                to prevent void-variable error on transient load
;;   Fix-14  §2   New defcustom org-museum-pages-subdir ("pages")
;;   Fix-15  §5   New helper org-museum--pages-base-dir
;;   Fix-16  §17  org-museum-create-page files under pages/<category-dir>/
;;                with org-museum--category-to-dir normalization + guards

;;; Code:

(require 'org)
(require 'ox-html)
(require 'ox-publish)
(require 'cl-lib)
(require 'json)

;; ============================================================
;; §1  CONSTANTS
;; ============================================================

(defconst org-museum--d3-cdn
  "https://d3js.org/d3.v7.min.js"
  "D3.js CDN URL (single source of truth).")

(defconst org-museum--hljs-css-cdn
  "https://cdn.staticfile.net/highlight.js/11.10.0/styles/monokai.min.css"
  "Highlight.js CSS CDN URL.")

(defconst org-museum--hljs-js-cdn
  "https://cdn.staticfile.net/highlight.js/11.10.0/highlight.min.js"
  "Highlight.js script CDN URL.")

(defconst org-museum--graph-palette
  ["#f92672" "#a6e22e" "#66d9ef" "#fd971f" "#ae81ff" "#e6db74" "#f8f8f2"]
  "Monokai-derived colour palette for graph categories.")

;; ============================================================
;; §2  CUSTOMISATION
;; ============================================================

(defgroup org-museum nil
  "Org Museum customisation group."
  :group 'org
  :prefix "org-museum-")

(defcustom org-museum-root-dir nil
  "Root directory of the Org Museum project."
  :type 'directory
  :group 'org-museum)

(defcustom org-museum-export-dir "exports/html/pages"
  "HTML export directory for pages, relative to `org-museum-root-dir'."
  :type 'string
  :group 'org-museum)

(defcustom org-museum-shared-export-dir "exports/html"
  "Shared export directory (index.html, graph.html, resources/)."
  :type 'string
  :group 'org-museum)

(defcustom org-museum-scan-dir nil
  "Subdirectory to scan for .org files.  nil means entire root."
  :type '(choice (const nil) string)
  :group 'org-museum)

;; Fix-14: pages base directory — all category subdirs live here.
(defcustom org-museum-pages-subdir "pages"
  "Subdirectory under `org-museum-root-dir' where all page files are stored.
Category subdirectories are created inside this directory by
`org-museum-create-page'.  Must be consistent with `org-museum-scan-dir'
when that variable is non-nil.
Example final layout:
  <root>/pages/risk-control/aml-detection.org
  <root>/pages/market/wash-trading.org"
  :type 'string
  :group 'org-museum)

(defcustom org-museum-index-file ".org-museum-index.json"
  "Cache file path for the built index."
  :type 'string
  :group 'org-museum)

(defcustom org-museum-css-file "resources/org-museum.css"
  "CSS filename relative to the org-museum.el plugin directory."
  :type 'string
  :group 'org-museum)

(defcustom org-museum-open-browser-after-export t
  "When non-nil, open graph in browser after full export."
  :type 'boolean
  :group 'org-museum)

(defcustom org-museum-local-graph-neighbour-limit 12
  "Maximum neighbours shown in local per-page graph.
Nodes beyond this limit are folded into a virtual _overflow node.
Applicable scope: org-museum--generate-local-graph-data (Fix-08)."
  :type 'integer
  :group 'org-museum)

(defcustom org-museum-save-debounce-seconds 0.5
  "Idle seconds to wait before flushing the index after a save.
Applicable scope: org-museum--on-save debounce (Fix-02).
Known limitation: timer is per-buffer; rapid cross-buffer saves
still trigger multiple flushes."
  :type 'number
  :group 'org-museum)

;; ============================================================
;; §3  INTERNAL STATE
;; ============================================================

(defvar org-museum--index nil
  "Current Org Museum index (org-museum-index struct).")

(defvar org-museum--plugin-dir nil
  "Resolved directory of org-museum.el.  Set once at load time.")

;; Fix-02: per-buffer debounce timer handle
(defvar-local org-museum--save-timer nil
  "Idle timer handle for debounced index flush.
Applicable scope: org-museum--on-save (Fix-02).")

;; ============================================================
;; §4  DATA STRUCTURES
;; ============================================================

(cl-defstruct org-museum-page
  "Single wiki page."
  id title path tags category modified links-to linked-from theme status)

(cl-defstruct org-museum-index
  "Full wiki index."
  pages        ; hash-table id -> page
  tags         ; hash-table tag -> (id ...)
  categories   ; hash-table cat -> (id ...)
  graph)       ; hash-table (reserved)

;; ============================================================
;; §5  PATH HELPERS
;; ============================================================

(defun org-museum--plugin-dir ()
  "Return the directory containing org-museum.el."
  (or org-museum--plugin-dir
      (setq org-museum--plugin-dir
            (if-let ((lib (locate-library "org-museum")))
                (let* ((dir (file-name-directory lib))
                       (css (expand-file-name org-museum-css-file dir)))
                  (if (file-exists-p css)
                      dir
                    (let ((repos (expand-file-name
                                  (concat "straight/repos/org-museum.el/")
                                  user-emacs-directory)))
                      (if (file-exists-p
                           (expand-file-name org-museum-css-file repos))
                          repos
                        dir))))
              default-directory))))

(defun org-museum--shared-root ()
  "Absolute path to shared export root."
  (expand-file-name org-museum-shared-export-dir org-museum-root-dir))

(defun org-museum--pages-root ()
  "Absolute path to per-page export root."
  (expand-file-name org-museum-export-dir org-museum-root-dir))

(defun org-museum--scan-root ()
  "Absolute path to the .org scan root."
  (expand-file-name (or org-museum-scan-dir "") org-museum-root-dir))

;; Fix-15: single source of truth for the pages base directory.
(defun org-museum--pages-base-dir ()
  "Absolute path to the pages base directory.
All category subdirectories created by `org-museum-create-page'
are rooted here, regardless of `org-museum-scan-dir'.
Layout: <org-museum-root-dir>/<org-museum-pages-subdir>/"
  (expand-file-name org-museum-pages-subdir org-museum-root-dir))

(defun org-museum--index-file-path ()
  "Absolute path to the index JSON cache."
  (expand-file-name org-museum-index-file org-museum-root-dir))

(defun org-museum--css-source-path ()
  "Absolute path of the source CSS file."
  (expand-file-name org-museum-css-file (org-museum--plugin-dir)))

(defun org-museum--css-output-path ()
  "Absolute path of the deployed CSS file."
  (expand-file-name org-museum-css-file (org-museum--shared-root)))

(defun org-museum--relative-path (target from-file)
  "Return TARGET path relative to the directory of FROM-FILE, forward-slashed."
  (replace-regexp-in-string
   "\\\\" "/"
   (file-relative-name (expand-file-name target)
                       (file-name-directory (expand-file-name from-file)))))

(defun org-museum--css-link-tag (from-out-file)
  "Return <link> tag for CSS, relative to FROM-OUT-FILE."
  (format "<link rel=\"stylesheet\" href=\"%s\">"
          (org-museum--relative-path (org-museum--css-output-path) from-out-file)))

;; ============================================================
;; §6  CSS DEPLOYMENT
;; ============================================================

(defun org-museum--ensure-css-deployed ()
  "Copy the source CSS to the export directory when stale."
  (let ((src (org-museum--css-source-path))
        (dst (org-museum--css-output-path)))
    (when (file-exists-p src)
      (make-directory (file-name-directory dst) t)
      (when (or (not (file-exists-p dst))
                (> (org-museum--file-mtime src) (org-museum--file-mtime dst)))
        (copy-file src dst t)
        (message "Org Museum CSS updated: %s" dst)))))

;; ============================================================
;; §7  INDEX — BUILD / SCAN
;; ============================================================

;;;###autoload
(defun org-museum-index-build (&optional force)
  "Build or rebuild the Org Museum index.
With prefix FORCE, always rebuild from scratch."
  (interactive "P")
  (let ((index-path (org-museum--index-file-path)))
    (if (and (not force)
             (file-exists-p index-path)
             (org-museum--index-fresh-p index-path))
        (org-museum--index-load index-path)
      (message "Building Org Museum index…")
      (setq org-museum--index (org-museum--index-scan))
      (org-museum--index-save org-museum--index index-path)
      (message "Org Museum index built: %d pages"
               (hash-table-count (org-museum-index-pages org-museum--index))))))

(defun org-museum--index-scan ()
  "Scan all .org files and return a fresh org-museum-index."
  (let ((index (make-org-museum-index
                :pages      (make-hash-table :test 'equal)
                :tags       (make-hash-table :test 'equal)
                :categories (make-hash-table :test 'equal)
                :graph      (make-hash-table :test 'equal))))
    (org-museum--scan-collect-pages index)
    (org-museum--scan-resolve-links index)
    index))

(defun org-museum--scan-collect-pages (index)
  "Populate INDEX with page metadata from all .org files."
  (let ((seen (make-hash-table :test 'equal))
        (scan-root (org-museum--scan-root)))
    (dolist (dir (delete-dups
                  (delq nil
                        (list scan-root
                              (unless (string= scan-root org-museum-root-dir)
                                org-museum-root-dir)))))
      (when (file-directory-p dir)
        (dolist (file (directory-files-recursively dir "\\.org$"))
          (unless (gethash file seen)
            (puthash file t seen)
            (condition-case err
                (when-let ((page (org-museum--parse-page-metadata file)))
                  (org-museum--index-register-page index page))
              (error (message "Org Museum: parse error in %s: %s"
                              file (error-message-string err))))))))))

(defun org-museum--index-register-page (index page)
  "Add PAGE to INDEX, updating tag/category tables."
  (puthash (org-museum-page-id page) page (org-museum-index-pages index))
  (dolist (tag (org-museum-page-tags page))
    (org-museum--adjoin-to-list (org-museum-index-tags index) tag
                                (org-museum-page-id page)))
  (org-museum--adjoin-to-list (org-museum-index-categories index)
                              (org-museum-page-category page)
                              (org-museum-page-id page)))

(defun org-museum--parse-page-metadata (file)
  "Extract metadata from .org FILE; return an org-museum-page or nil."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (let* ((ast  (org-element-parse-buffer))
           (kw   (org-museum--extract-keywords ast))
           (id   (or (org-entry-get (point-min) "ID" t)
                     (gethash "WIKI_ID" kw)
                     (org-museum--generate-id file)))
           (title  (or (gethash "TITLE" kw) (file-name-base file)))
           (tags   (org-museum--parse-tags (gethash "FILETAGS" kw)))
           (cat    (or (gethash "CATEGORY" kw) "uncategorized"))
           (theme  (gethash "WIKI_THEME" kw))
           (status (or (gethash "WIKI_STATUS" kw) "published")))
      (make-org-museum-page
       :id id :title title :path file :tags tags :category cat
       :modified (org-museum--file-mtime file)
       :links-to nil :linked-from nil :theme theme :status status))))

(defun org-museum--scan-resolve-links (index)
  "Resolve and record bidirectional links for all pages in INDEX."
  (maphash
   (lambda (id page)
     (let ((outgoing (org-museum--extract-links-from-file
                      (org-museum-page-path page)
                      (org-museum-index-pages index))))
       (setf (org-museum-page-links-to page) outgoing)
       (dolist (target-id outgoing)
         (when-let ((target (gethash target-id (org-museum-index-pages index))))
           (cl-pushnew id (org-museum-page-linked-from target) :test #'equal)))))
   (org-museum-index-pages index)))

(defun org-museum--extract-links-from-file (file pages-table)
  "Return list of page IDs linked from FILE (wiki:, museum:, id:, file: links)."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((links '())
          (dir   (file-name-directory file)))
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[\\(?:wiki\\|museum\\):\\([^]]+\\)\\]" nil t)
        (let ((id (match-string 1)))
          (when (gethash id pages-table)
            (cl-pushnew id links :test #'equal))))
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[id:\\([^]]+\\)\\]" nil t)
        (let ((id (match-string 1)))
          (when (gethash id pages-table)
            (cl-pushnew id links :test #'equal))))
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[file:\\([^]]+\\.org\\)" nil t)
        (let* ((target-file (expand-file-name (match-string 1) dir))
               (target-page (org-museum--find-page-by-path target-file pages-table)))
          (when target-page
            (cl-pushnew (org-museum-page-id target-page) links :test #'equal))))
      links)))

;; ============================================================
;; §8  INDEX FRESHNESS
;; ============================================================

(defun org-museum--index-fresh-p (index-path)
  "Return non-nil when INDEX-PATH is newer than every .org file."
  (let ((index-mtime (org-museum--file-mtime index-path))
        (scan-root   (org-museum--scan-root)))
    (and (file-directory-p scan-root)
         (not (cl-some (lambda (f) (> (org-museum--file-mtime f) index-mtime))
                       (directory-files-recursively scan-root "\\.org$")))
         (or (null org-museum--index)
             (not (org-museum--index-has-ghost-pages-p org-museum--index))))))

(defun org-museum--index-has-ghost-pages-p (index)
  "Return non-nil if any page in INDEX no longer exists on disk."
  (let ((has-ghost nil))
    (maphash (lambda (_id page)
               (unless (file-exists-p (org-museum-page-path page))
                 (setq has-ghost t)))
             (org-museum-index-pages index))
    has-ghost))

;; ============================================================
;; §9  INDEX — INCREMENTAL UPDATE  [Fix-01 + Fix-02]
;; ============================================================

(defun org-museum--index-remove-page (id page)
  "Remove PAGE (with ID) from the current index, cleaning all cross-references.
Mutates `org-museum--index' in place.
Applicable scope: incremental update, index verification."
  (let ((pages (org-museum-index-pages org-museum--index)))
    (maphash (lambda (key ids)
               (puthash key (delete id ids)
                        (org-museum-index-tags org-museum--index)))
             (org-museum-index-tags org-museum--index))
    (maphash (lambda (key ids)
               (puthash key (delete id ids)
                        (org-museum-index-categories org-museum--index)))
             (org-museum-index-categories org-museum--index))
    (dolist (link-id (org-museum-page-links-to page))
      (when-let ((linked (gethash link-id pages)))
        (setf (org-museum-page-linked-from linked)
              (delete id (org-museum-page-linked-from linked)))))
    (remhash id pages)))

;; Fix-01: verify linked-from consistency for a single page.
(defun org-museum--verify-linked-from-for-page (page-id)
  "Rebuild linked-from for PAGE-ID by scanning all pages' links-to lists.
This is a targeted repair for the case where a third-party page removed
its outgoing link to PAGE-ID but the incremental update only ran on that
third-party file, leaving PAGE-ID's linked-from stale.
Applicable scope: called from org-museum--index-update-file step 5 (Fix-01).
Known limitation: O(n) scan over all pages; acceptable for wikis ≤5000 pages."
  (when-let* ((pages (org-museum-index-pages org-museum--index))
              (page  (gethash page-id pages)))
    (let ((actual-inbound '()))
      (maphash (lambda (id pg)
                 (when (and (not (string= id page-id))
                            (member page-id (org-museum-page-links-to pg)))
                   (push id actual-inbound)))
               pages)
      (setf (org-museum-page-linked-from page) actual-inbound))))

(defun org-museum--index-update-file (file)
  "Incrementally update the index for FILE with precise bidirectional link repair.
Steps:
  1. Guard: skip out-of-project or non-.org files
  2. Remove old page entry and clean its outgoing link targets' linked-from
  3. Re-parse and register new page metadata
  4. Compute removed/added outgoing link diff; update affected pages
  5. [Fix-01] Rebuild linked-from for the new page via full inbound scan,
     correcting stale entries left by third-party page edits
  6. Persist to JSON cache
Applicable scope: after-save-hook, single-file refresh.
Known limitation: step 5 is O(n) over all pages; scales to ~5000 pages."
  (unless (org-museum--file-in-project-p file)
    (message "Org Museum [Index]: skipping out-of-project file %s" file)
    (cl-return-from org-museum--index-update-file nil))

  (unless org-museum--index
    (condition-case err
        (org-museum-index-build)
      (error
       (message "Org Museum [Index]: build failed: %s" (error-message-string err))
       (cl-return-from org-museum--index-update-file nil))))

  (let* ((pages      (org-museum-index-pages org-museum--index))
         (old-pg     (org-museum--find-page-by-path file pages))
         (old-id     (when old-pg (org-museum-page-id old-pg)))
         (old-links  (if old-pg
                         (copy-sequence (org-museum-page-links-to old-pg))
                       '())))

    (when old-id
      (org-museum--index-remove-page old-id old-pg))

    (condition-case err
        (when-let ((new-pg (org-museum--parse-page-metadata file)))
          (org-museum--index-register-page org-museum--index new-pg)

          (let* ((new-links  (org-museum--extract-links-from-file
                              file (org-museum-index-pages org-museum--index)))
                 (new-id     (org-museum-page-id new-pg))
                 (removed    (cl-set-difference old-links new-links :test #'equal))
                 (added      (cl-set-difference new-links old-links :test #'equal)))

            (setf (org-museum-page-links-to new-pg) new-links)

            (dolist (target-id removed)
              (when-let ((target (gethash target-id pages)))
                (setf (org-museum-page-linked-from target)
                      (delete old-id (org-museum-page-linked-from target)))))

            (dolist (target-id added)
              (when-let ((target (gethash target-id pages)))
                (cl-pushnew new-id (org-museum-page-linked-from target)
                            :test #'equal)))

            ;; Fix-01: full inbound scan to repair stale linked-from
            (org-museum--verify-linked-from-for-page new-id)))

      (error
       (message "Org Museum [Index]: incremental update failed for %s: %s"
                file (error-message-string err))))

    (org-museum--index-save org-museum--index
                            (org-museum--index-file-path))))

;; ============================================================
;; §10  SERIALISATION
;; ============================================================

(defun org-museum--page-to-alist (page)
  "Serialise PAGE to a JSON-compatible alist."
  `((id          . ,(org-museum-page-id page))
    (title       . ,(org-museum-page-title page))
    (path        . ,(org-museum-page-path page))
    (tags        . ,(vconcat (org-museum-page-tags page)))
    (category    . ,(org-museum-page-category page))
    (modified    . ,(org-museum-page-modified page))
    (links-to    . ,(vconcat (org-museum-page-links-to page)))
    (linked-from . ,(vconcat (org-museum-page-linked-from page)))
    (theme       . ,(or (org-museum-page-theme page) ""))
    (status      . ,(or (org-museum-page-status page) "published"))))

(defun org-museum--index-to-alist (index)
  "Serialise INDEX to JSON-compatible alist."
  (let (pages-list)
    (maphash (lambda (_id page) (push (org-museum--page-to-alist page) pages-list))
             (org-museum-index-pages index))
    `((pages . ,(vconcat pages-list)))))

(defun org-museum--json-get (plist key &optional as-list)
  "Extract value from JSON alist PLIST at KEY.
When AS-LIST is non-nil, coerce vectors to lists."
  (let ((v (cdr (assq key plist))))
    (if as-list
        (cond ((null v)    nil)
              ((vectorp v) (append v nil))
              ((listp v)   (if (and v (consp (car v))) nil v))
              (t           nil))
      (cond ((stringp v) v)
            ((null v)    "")
            (t           (format "%s" v))))))

(defun org-museum--alist-to-index (data)
  "Reconstruct an org-museum-index from deserialised JSON alist DATA."
  (let ((index (make-org-museum-index
                :pages      (make-hash-table :test 'equal)
                :tags       (make-hash-table :test 'equal)
                :categories (make-hash-table :test 'equal)
                :graph      (make-hash-table :test 'equal))))
    (seq-do
     (lambda (plist)
       (let* ((id   (org-museum--json-get plist 'id))
              (page (make-org-museum-page
                     :id          id
                     :title       (org-museum--json-get plist 'title)
                     :path        (org-museum--json-get plist 'path)
                     :tags        (org-museum--json-get plist 'tags       :as-list)
                     :category    (org-museum--json-get plist 'category)
                     :modified    (cdr (assq 'modified plist))
                     :links-to    (org-museum--json-get plist 'links-to   :as-list)
                     :linked-from (org-museum--json-get plist 'linked-from :as-list)
                     :theme       (org-museum--json-get plist 'theme)
                     :status      (org-museum--json-get plist 'status))))
         (when (and id (not (string-empty-p id)))
           (org-museum--index-register-page index page))))
     (cdr (assq 'pages data)))
    index))

(defun org-museum--index-save (index path)
  "Write INDEX to JSON at PATH."
  (with-temp-file path
    (let ((json-encoding-pretty-print nil))
      (insert (json-encode (org-museum--index-to-alist index))))))

(defun org-museum--index-load (path)
  "Load index from JSON at PATH into `org-museum--index'."
  (let ((json-array-type  'vector)
        (json-object-type 'alist)
        (json-key-type    'symbol))
    (setq org-museum--index
          (org-museum--alist-to-index (json-read-file path)))))

;; ============================================================
;; §11  EXPORT ENGINE — SINGLE PAGE  [Fix-03]
;; ============================================================

;;;###autoload
(defun org-museum-export-page (file &optional force)
  "Export a single Org Museum FILE to HTML."
  (interactive (list (buffer-file-name) current-prefix-arg))
  (org-museum--guard-init)
  (org-museum--ensure-css-deployed)
  (let ((out-file (org-museum--export-filename file)))
    (if (and (not force) (not (org-museum--needs-export-p file out-file)))
        (message "Skipping unchanged page: %s" (file-name-nondirectory file))
      (make-directory (file-name-directory out-file) t)
      (org-museum--export-with-theme file out-file))))

;; Fix-03: CSS mtime now included in staleness check.
(defun org-museum--needs-export-p (org-file html-file)
  "Return non-nil when ORG-FILE or the deployed CSS is newer than HTML-FILE.
Checks (in order):
  1. HTML-FILE does not exist
  2. ORG-FILE mtime > HTML-FILE mtime
  3. [Fix-03] CSS output file mtime > HTML-FILE mtime
Applicable scope: org-museum-export-page, org-museum--count-stale-pages.
Known limitation: does not track transitive template dependencies."
  (or (not (file-exists-p html-file))
      (> (org-museum--file-mtime org-file) (org-museum--file-mtime html-file))
      (let ((css-out (org-museum--css-output-path)))
        (and (file-exists-p css-out)
             (> (org-museum--file-mtime css-out)
                (org-museum--file-mtime html-file))))))

(defun org-museum--export-with-theme (org-file out-file)
  "Export ORG-FILE to OUT-FILE with CSS, link-rewriting, and post-processing."
  (let ((tmp (make-temp-file "org-museum-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert-file-contents org-file)
            (org-mode)
            (org-museum--strip-drawers)
            (org-museum--rewrite-org-museum-links (current-buffer) out-file)
            (goto-char (point-min))
            (insert (format "#+HTML_HEAD: %s\n"
                            (org-museum--css-link-tag out-file)))
            (write-region (point-min) (point-max) tmp))
          (let ((export-buf (find-file-noselect tmp)))
            (unwind-protect
                (with-current-buffer export-buf
                  (let ((org-export-with-toc                 t)
                        (org-html-doctype                    "html5")
                        (org-html-head-include-default-style nil)
                        (org-html-preamble                   nil)
                        (org-html-postamble                  nil)
                        (org-export-with-broken-links        'mark)
                        (org-export-with-drawers             nil)
                        (org-export-with-properties          nil)
                        (coding-system-for-write             'utf-8))
                    (org-export-to-file 'html out-file)))
              (when (buffer-live-p export-buf) (kill-buffer export-buf))))
          (when (file-exists-p out-file)
            (org-museum--postprocess-html out-file org-file)))
      (when (file-exists-p tmp) (delete-file tmp)))))

(defun org-museum--strip-drawers ()
  "Remove all property drawers and orphaned :END: markers from current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t))
      (while (re-search-forward "^[ \t]*:[A-Z]+:[ \t]*$" nil t)
        (let ((beg (line-beginning-position)))
          (when (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
            (delete-region beg (min (point-max) (1+ (line-end-position)))))))
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
        (delete-region (line-beginning-position)
                       (min (point-max) (1+ (line-end-position))))))))

;; ============================================================
;; §12  POST-PROCESSING  [Fix-05]
;; ============================================================

(defun org-museum--postprocess-html (out-file org-file)
  "Wrap, inject sidebars, nav, and scripts into OUT-FILE.
[Fix-05] Short-circuits if pp-wrap-content-div fails, adding the
failed file to the export error report rather than producing
malformed HTML."
  (with-temp-buffer
    (insert-file-contents out-file)
    (org-museum--pp-remove-inline-styles)
    (if (not (org-museum--pp-wrap-content-div out-file))
        (progn
          (message "Org Museum [Export]: aborting post-processing for %s \
(#content div not found)" out-file)
          nil)
      (org-museum--pp-append-nav-and-graph out-file org-file)
      (org-museum--pp-inject-sidebars-and-scripts out-file)
      (write-region (point-min) (point-max) out-file)
      t)))

(defun org-museum--pp-remove-inline-styles ()
  "Strip <style>…</style> blocks from current buffer."
  (goto-char (point-min))
  (while (re-search-forward "<style[^>]*>" nil t)
    (let ((beg (match-beginning 0)))
      (when (re-search-forward "</style>" nil t)
        (delete-region beg (point))))))

;; Fix-05: now returns t on success, nil on failure.
(defun org-museum--pp-wrap-content-div (out-file)
  "Wrap #content with scroll/article containers in current buffer.
Returns t on success, nil when #content is not found.
[Fix-05] Callers must check the return value and short-circuit on nil.
Applicable scope: org-museum--postprocess-html."
  (goto-char (point-min))
  (if (re-search-forward "<div id=\"content\"[^>]*>" nil t)
      (progn
        (replace-match
         "<div id=\"main-scroll\"><div id=\"content\"><div class=\"article-container\">")
        t)
    (message "Org Museum [PostProcess]: #content not found in %s — \
check org-export output for this file" out-file)
    nil))

(defun org-museum--pp-append-nav-and-graph (out-file org-file)
  "Append wiki-nav links and local graph to current buffer."
  (let* ((page      (when org-museum--index
                      (org-museum--find-page-by-path
                       org-file (org-museum-index-pages org-museum--index))))
         (links     (when page (org-museum-page-links-to page)))
         (backs     (when page (org-museum-page-linked-from page)))
         (nav-html  (when (or links backs)
                      (org-museum--build-nav-html links backs out-file)))
         (graph-html (when page
                       (org-museum--generate-local-graph-html page)))
         (appended  (concat (or nav-html "") (or graph-html ""))))
    (goto-char (point-max))
    (cond
     ((re-search-backward "</div>\\([\n\r\t ]*\\)</body>" nil t)
      (replace-match (concat appended "\n</div></div></div>\\1</body>")))
     (t
      (when (re-search-backward "</div>" nil t)
        (replace-match (concat appended "\n</div></div></div>")))))))

(defun org-museum--pp-inject-sidebars-and-scripts (out-file)
  "Inject sidebar, TOC, and script HTML before </body>."
  (goto-char (point-max))
  (when (re-search-backward "</body>" nil t)
    (insert (org-museum--build-sidebar-injection out-file))
    (insert "\n")))

;; ============================================================
;; §13  PROJECT EXPORT
;; ============================================================

;;;###autoload
(defun org-museum-export-all ()
  "Export the entire Org Museum as a static HTML site."
  (interactive)
  (org-museum-index-build t)
  (org-museum--ensure-css-deployed)
  (let ((total   (hash-table-count (org-museum-index-pages org-museum--index)))
        (success 0)
        (skipped 0)
        (failed  '()))
    (maphash
     (lambda (_id page)
       (condition-case err
           (progn (org-museum-export-page (org-museum-page-path page) t)
                  (cl-incf success))
         (error (push (list (org-museum-page-id page) (error-message-string err))
                      failed))))
     (org-museum-index-pages org-museum--index))
    (org-museum--generate-index-page)
    (let ((graph-file (org-museum-export-graph :silent t)))
      (message "Export complete: %d/%d pages, %d failed"
               success total (length failed))
      (when failed (org-museum--report-failures failed))
      (when (and org-museum-open-browser-after-export graph-file)
        (browse-url (concat "file:///"
                            (replace-regexp-in-string "\\\\" "/" graph-file)))))))

(defun org-museum--report-failures (failed)
  "Show FAILED export items in a buffer."
  (with-current-buffer (get-buffer-create "*Org Museum Failures*")
    (erase-buffer)
    (insert "* Export Failures\n\n")
    (dolist (item failed)
      (insert (format "- %s :: %s\n" (car item) (cadr item))))
    (display-buffer (current-buffer))))

;; ============================================================
;; §14  INDEX PAGE GENERATION
;; ============================================================

(defun org-museum--generate-index-page ()
  "Write index.html directly to the shared export root."
  (let* ((shared-root (org-museum--shared-root))
         (index-html  (expand-file-name "index.html" shared-root))
         (graph-href  "graph.html")
         (cats        (org-museum--sorted-categories)))
    (make-directory shared-root t)
    (with-temp-file index-html
      (insert (org-museum--build-index-html cats graph-href index-html)))))

(defun org-museum--sorted-categories ()
  "Return an alist of (category . pages) sorted alphabetically."
  (let (cats)
    (when org-museum--index
      (maphash (lambda (cat ids)
                 (let* ((ids-list (org-museum--ensure-list ids))
                        (pages    (delq nil
                                        (mapcar (lambda (id)
                                                  (gethash id (org-museum-index-pages org-museum--index)))
                                                ids-list))))
                   (setq pages (sort pages (lambda (a b)
                                             (string< (org-museum-page-title a)
                                                      (org-museum-page-title b)))))
                   (when pages (push (cons cat pages) cats))))
               (org-museum-index-categories org-museum--index)))
    (sort cats (lambda (a b) (string< (car a) (car b))))))

(defun org-museum--build-index-html (cats graph-href out-file)
  "Return full index.html string for CATS, with GRAPH-HREF link."
  (concat
   "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n"
   "  <meta charset=\"utf-8\">\n"
   "  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
   "  <title>Org Museum</title>\n"
   (format "  %s\n" (org-museum--css-link-tag out-file))
   "</head>\n<body>\n"
   "<div id=\"main-scroll\"><div id=\"content\"><div class=\"article-container\">\n"
   "<h1 class=\"title\">📚 Org Museum</h1>\n"
   (apply #'concat
          (mapcar (lambda (ce)
                    (concat
                     (format "<h2>%s</h2>\n<ul>\n" (car ce))
                     (apply #'concat
                            (mapcar (lambda (p)
                                      (format "  <li><a href=\"%s\">%s</a></li>\n"
                                              (org-museum--page-href
                                               (org-museum-page-id p) out-file)
                                              (org-museum-page-title p)))
                                    (cdr ce)))
                     "</ul>\n"))
                  cats))
   "</div></div></div>\n"
   (org-museum--build-sidebar-injection out-file)
   "</body>\n</html>\n"))

;; ============================================================
;; §15  KNOWLEDGE GRAPH EXPORT  [Fix-06]
;; ============================================================

(defun org-museum--graph-performance-tier (node-count)
  "Return a plist describing the rendering tier for NODE-COUNT nodes.
Tiers:
  small  (≤100)  — full force simulation
  medium (≤500)  — reduced collision precision, faster alpha decay
  large  (>500)  — minimal simulation, tick limit applied + pre-heat
[Fix-06] large tier now includes :pre-ticks 100 in the returned plist,
passed to the JS layer via graph JSON meta field so the simulation
pre-heats silently before DOM rendering begins.
Applicable scope: graph.html generation."
  (cond
   ((<= node-count 100)
    (list :tier 'small  :label "Full Simulation"
          :charge -200  :alpha-decay 0.0228 :tick-limit nil   :pre-ticks nil))
   ((<= node-count 500)
    (list :tier 'medium :label "Reduced Precision"
          :charge -120  :alpha-decay 0.04   :tick-limit 150   :pre-ticks 50))
   (t
    (list :tier 'large  :label "Cluster View"
          :charge -80   :alpha-decay 0.08   :tick-limit 80    :pre-ticks 100))))

;;;###autoload
(cl-defun org-museum-export-graph (&key silent)
  "Generate graph.html in the shared export root."
  (interactive)
  (org-museum--guard-init)
  (org-museum--ensure-css-deployed)
  (let* ((shared-root (org-museum--shared-root))
         (graph-html  (expand-file-name "graph.html" shared-root))
         (css-href    (org-museum--relative-path
                       (org-museum--css-output-path) graph-html))
         (data-json   (org-museum--generate-graph-json)))
    (make-directory shared-root t)
    (with-temp-file graph-html
      (insert (org-museum--build-graph-html data-json css-href)))
    (unless silent
      (browse-url (concat "file:///" (replace-regexp-in-string "\\\\" "/" graph-html)))
      (message "Graph generated: %s" graph-html))
    graph-html))

(defun org-museum--generate-graph-json ()
  "Return JSON string of all nodes and links, with performance tier metadata.
[Fix-06] Includes pre-ticks in meta for large/medium tiers."
  (let ((nodes '()) (links '()) (degree (make-hash-table :test 'equal)))
    (maphash
     (lambda (id page)
       (dolist (target (org-museum-page-links-to page))
         (cl-incf (gethash id     degree 0))
         (cl-incf (gethash target degree 0))
         (push `((source . ,id) (target . ,target) (value . 1)) links)))
     (org-museum-index-pages org-museum--index))
    (maphash
     (lambda (id page)
       (push `((id     . ,id)
               (name   . ,(org-museum-page-title page))
               (group  . ,(org-museum-page-category page))
               (tags   . ,(vconcat (org-museum-page-tags page)))
               (degree . ,(gethash id degree 0))
               (url    . ,(org-museum--page-href id nil)))
             nodes))
     (org-museum-index-pages org-museum--index))
    (let* ((n-count   (length nodes))
           (tier      (org-museum--graph-performance-tier n-count))
           (pre-ticks (plist-get tier :pre-ticks)))
      (json-encode
       `((nodes . ,(vconcat (nreverse nodes)))
         (links . ,(vconcat (nreverse links)))
         (meta  . ((node-count  . ,n-count)
                   (tier        . ,(symbol-name (plist-get tier :tier)))
                   (tier-label  . ,(plist-get tier :label))
                   (charge      . ,(plist-get tier :charge))
                   (alpha-decay . ,(plist-get tier :alpha-decay))
                   (tick-limit  . ,(or (plist-get tier :tick-limit) :false))
                   (pre-ticks   . ,(or pre-ticks :false)))))))))

;; ============================================================
;; §16  LINKS — ORG PROTOCOL HANDLERS
;; ============================================================

(dolist (proto '("org-museum" "museum" "wiki"))
  (org-link-set-parameters
   proto
   :follow   #'org-museum-link-follow
   :export   #'org-museum-link-export
   :complete #'org-museum-link-complete
   :face     'org-link))

(defun org-museum-link-follow (id _)
  "Visit page ID or create it if absent."
  (if-let ((page (org-museum--find-page id)))
      (find-file (org-museum-page-path page))
    (org-museum-create-page id)))

(defun org-museum-link-export (id desc backend info)
  "Export wiki link ID with optional DESC for BACKEND."
  (let* ((page    (org-museum--find-page id))
         (title   (if page (org-museum-page-title page) id))
         (display (or desc title))
         (out-file (or (plist-get info :output-file) nil))
         (href    (org-museum--page-href id out-file)))
    (pcase backend
      ('html  (format "<a href=\"%s\" class=\"org-museum-link\">%s</a>" href display))
      ('latex (format "\\href{%s}{%s}" href display))
      ('md    (format "[%s](%s)" display href))
      (_      display))))

(defun org-museum-link-complete ()
  "Completion for wiki: / museum: links."
  (org-museum--guard-quick)
  (concat "wiki:"
          (completing-read "Org Museum Page: "
                           (hash-table-keys (org-museum-index-pages org-museum--index))
                           nil t)))

;; ============================================================
;; §17  PAGE MANAGEMENT  [Fix-11 + Fix-16]
;; ============================================================

;;;###autoload
(defun org-museum-create-page (title &optional category)
  "Create a new Org Museum page with TITLE filed under a category subdirectory.

Directory layout (always under `org-museum-pages-subdir'):
  <root>/<pages-subdir>/<category-dir>/<id>.org

Example:
  org-museum-root-dir     = ~/wiki/
  org-museum-pages-subdir = \"pages\"  (default)
  title    = \"AML Detection\"
  category = \"risk control\"
  → ~/wiki/pages/risk-control/aml-detection.org

Guards:
  - Empty title:    signals an error before touching the filesystem
  - Path collision: refuses if the target .org file already exists
  - ID collision:   refuses if ID already registered in the index in any
                    other location, preventing silent link breakage

[Fix-16] Files are now placed under `org-museum--pages-base-dir'/
<category-dir>/ regardless of `org-museum-scan-dir'."
  (interactive
   (list
    ;; ── Arg 1: title ─────────────────────────────────────────────
    (let ((raw (string-trim (read-string "Page Title: "))))
      (when (string-empty-p raw)
        (error "Org Museum [Create]: title must not be empty"))
      raw)
    ;; ── Arg 2: category (existing or new, with completion) ───────
    (let* ((existing (when org-museum--index
                       (sort (hash-table-keys
                              (org-museum-index-categories org-museum--index))
                             #'string<)))
           (raw (string-trim
                 (completing-read
                  "Category (existing or new, default: uncategorized): "
                  existing nil nil))))
      (if (string-empty-p raw) "uncategorized" raw))))

  ;; ── Derived path values ───────────────────────────────────────
  (let* ((id         (org-museum--title-to-id title))
         (cat        (if (and category
                              (not (string-empty-p (string-trim category))))
                         (string-trim category)
                       "uncategorized"))
         (cat-dir    (org-museum--category-to-dir cat))
         ;; Fix-16: always rooted at <root>/pages/, not at scan-root
         (base-dir   (org-museum--pages-base-dir))
         (target-dir (expand-file-name cat-dir base-dir))
         (filepath   (expand-file-name (concat id ".org") target-dir)))

    ;; ── Guard 1: file path collision ─────────────────────────────
    (when (file-exists-p filepath)
      (error "Org Museum [Create]: file already exists: %s"
             (file-relative-name filepath org-museum-root-dir)))

    ;; ── Guard 2: ID collision across all categories ───────────────
    (when (and org-museum--index
               (gethash id (org-museum-index-pages org-museum--index)))
      (error "Org Museum [Create]: ID '%s' already registered in index \
(possibly a duplicate title in another category)" id))

    ;; ── Create subdirectory + file ────────────────────────────────
    (make-directory target-dir t)
    (find-file filepath)
    (insert (format "\
#+TITLE:       %s
#+WIKI_ID:     %s
#+CATEGORY:    %s
#+WIKI_STATUS: draft
#+DATE:        %s
#+FILETAGS:    :%s:

* %s

** Overview

** Content

** References
"
                    title id cat
                    (format-time-string "%Y-%m-%d")
                    cat-dir   ; use normalised dir name as tag (no spaces)
                    title))

    ;; ── Rebuild index + confirm ───────────────────────────────────
    (org-museum-index-build t)
    (message "Org Museum [Create]: '%s' → %s"
             title
             (file-relative-name filepath org-museum-root-dir))))

;;;###autoload
(defun org-museum-rename-page (old-id new-id)
  "Rename page OLD-ID to NEW-ID and update all cross-links.
[Fix-11] Now also rewrites [[id:OLD-ID]] org-id format links.
Known limitation: does not handle custom_id property links."
  (interactive
   (let* ((ids (hash-table-keys (org-museum-index-pages org-museum--index)))
          (old (completing-read "Page ID to rename: " ids nil t)))
     (list old (read-string (format "New ID (was: %s): " old) old))))
  (let* ((page     (or (gethash old-id (org-museum-index-pages org-museum--index))
                       (error "Page not found: %s" old-id)))
         (old-path (expand-file-name (org-museum-page-path page)))
         (new-path (expand-file-name
                    (concat new-id ".org") (file-name-directory old-path))))
    (when (gethash new-id (org-museum-index-pages org-museum--index))
      (error "ID already exists: %s" new-id))
    (rename-file old-path new-path)
    (with-current-buffer (find-file-noselect new-path)
      (goto-char (point-min))
      (if (re-search-forward "^#\\+WIKI_ID:\\s-.*$" nil t)
          (replace-match (format "#+WIKI_ID: %s" new-id))
        (goto-char (point-min))
        (insert (format "#+WIKI_ID: %s\n" new-id)))
      (save-buffer) (kill-buffer))
    (let ((count (org-museum--update-links-globally old-id new-id)))
      (org-museum-index-build t)
      (message "Renamed %s → %s; %d files updated." old-id new-id count))))

;; Fix-11: now handles wiki:, museum:, and id: link formats.
(defun org-museum--update-links-globally (old-id new-id)
  "Replace all wiki/museum/id links to OLD-ID with NEW-ID; return file count.
[Fix-11] Three link formats are handled:
  [[wiki:OLD-ID]]    → [[wiki:NEW-ID]]
  [[museum:OLD-ID]]  → [[museum:NEW-ID]]
  [[id:OLD-ID]]      → [[id:NEW-ID]]
Applicable scope: org-museum-rename-page, on-save ID change detection.
Known limitation: CUSTOM_ID property links are not rewritten."
  (let ((count 0)
        (pattern (format "\\[\\[\\(wiki\\|museum\\|id\\):%s\\(\\]\\|\\[\\)"
                         (regexp-quote old-id))))
    (dolist (file (directory-files-recursively (org-museum--scan-root) "\\.org$"))
      (with-temp-buffer
        (insert-file-contents file)
        (let (modified)
          (goto-char (point-min))
          (while (re-search-forward pattern nil t)
            (replace-match (format "[[\\1:%s\\2" new-id) t)
            (setq modified t))
          (when modified
            (write-region (point-min) (point-max) file)
            (cl-incf count)))))
    count))

;; ── LINK CHECKER ─────────────────────────────────────────────

(defun org-museum-check-links ()
  "Scan all wiki links and report their validity.
Categories:
  Valid    — target page exists in index
  Missing  — target ID not in index (similarity suggestions provided)
  Absolute — file: links with absolute paths (portability risk)
Applicable scope: pre-publish review, CI validation.
Known limitation: only scans wiki:/museum:/id:/file: link types."
  (interactive)
  (org-museum--guard-init)
  (let ((pages (org-museum-index-pages org-museum--index))
        valid-links missing-links absolute-links)
    (maphash
     (lambda (_id page)
       (let ((file (org-museum-page-path page)))
         (when (file-exists-p file)
           (with-temp-buffer
             (insert-file-contents file)
             (goto-char (point-min))
             (while (re-search-forward
                     "\\[\\[\\(?:wiki\\|museum\\):\\([^]]+\\)\\]" nil t)
               (let ((target (match-string 1)))
                 (if (gethash target pages)
                     (push (list :from (org-museum-page-id page)
                                 :to target) valid-links)
                   (push (list :from (org-museum-page-id page)
                               :to target
                               :suggestions
                               (org-museum--suggest-similar-ids target pages))
                         missing-links))))
             (goto-char (point-min))
             (while (re-search-forward "\\[\\[file:\\([^]]+\\)\\]" nil t)
               (let ((path (match-string 1)))
                 (when (file-name-absolute-p path)
                   (push (list :from (org-museum-page-id page)
                               :path path) absolute-links))))))))
     pages)
    (with-current-buffer (get-buffer-create "*Org Museum Link Check*")
      (erase-buffer) (org-mode)
      (insert "#+TITLE: Org Museum Link Check Report\n")
      (insert (format "#+DATE: %s\n\n" (format-time-string "%Y-%m-%d %H:%M")))
      (insert (format "* Summary\n\n- Valid: %d  Missing: %d  Absolute: %d\n\n"
                      (length valid-links)
                      (length missing-links)
                      (length absolute-links)))
      (when missing-links
        (insert "* Missing Link Targets\n\n")
        (dolist (item missing-links)
          (insert (format "- [[museum:%s][%s]] → ==%s== not found\n"
                          (plist-get item :from)
                          (plist-get item :from)
                          (plist-get item :to)))
          (when (plist-get item :suggestions)
            (insert (format "  Suggestions: %s\n"
                            (mapconcat #'identity
                                       (plist-get item :suggestions) ", "))))))
      (when absolute-links
        (insert "\n* Absolute file: Links (Portability Risk)\n\n")
        (dolist (item absolute-links)
          (insert (format "- [[museum:%s][%s]] → =%s=\n"
                          (plist-get item :from)
                          (plist-get item :from)
                          (plist-get item :path)))))
      (display-buffer (current-buffer)))
    (message "Org Museum [Links]: %d valid, %d missing, %d absolute"
             (length valid-links) (length missing-links) (length absolute-links))))

(defun org-museum--suggest-similar-ids (target pages)
  "Return up to 3 existing page IDs most similar to TARGET string."
  (let* ((all-ids (hash-table-keys pages))
         (scored  (mapcar (lambda (id)
                            (cons id (org-museum--string-overlap target id)))
                          all-ids))
         (sorted  (sort scored (lambda (a b) (> (cdr a) (cdr b))))))
    (mapcar #'car (seq-take sorted 3))))

(defun org-museum--string-overlap (a b)
  "Return character-set overlap score between strings A and B."
  (let* ((set-a  (delete-dups (string-to-list a)))
         (set-b  (delete-dups (string-to-list b)))
         (common (length (cl-intersection set-a set-b)))
         (maxlen (max 1 (max (length set-a) (length set-b)))))
    (/ (float common) maxlen)))

;; ============================================================
;; §18  UTILITY / HELPER FUNCTIONS  [Fix-04 + Fix-16]
;; ============================================================

(defun org-museum--file-in-project-p (file)
  "Return non-nil if FILE resides under `org-museum-root-dir'."
  (and org-museum-root-dir
       file
       (file-exists-p file)
       (string-prefix-p
        (file-truename (file-name-as-directory
                        (expand-file-name org-museum-root-dir)))
        (file-truename (expand-file-name file)))))

(defun org-museum--guard-init ()
  "Ensure the plugin is fully ready before export or graph operations."
  (unless org-museum-root-dir
    (error "Org Museum [Config]: org-museum-root-dir is not set.  \
Run M-x org-museum-init to configure"))
  (unless (file-directory-p org-museum-root-dir)
    (error "Org Museum [Config]: root-dir does not exist: %s"
           org-museum-root-dir))
  (dolist (dir (list (org-museum--shared-root) (org-museum--scan-root)))
    (condition-case nil
        (make-directory dir t)
      (error
       (error "Org Museum [Export]: cannot create export directory: %s" dir)))
    (unless (file-writable-p dir)
      (error "Org Museum [Export]: export directory not writable: %s" dir)))
  (let ((css-src (org-museum--css-source-path)))
    (unless (file-exists-p css-src)
      (error "Org Museum [CSS]: source CSS not found at %s.  \
Check org-museum-css-file or reinstall the plugin" css-src)))
  (unless org-museum--index
    (condition-case err
        (org-museum-index-build)
      (error
       (error "Org Museum [Index]: failed to build index: %s"
              (error-message-string err))))))

(defun org-museum--guard-quick ()
  "Lightweight guard: verify root-dir and index only."
  (unless org-museum-root-dir
    (error "Org Museum [Config]: org-museum-root-dir is not set"))
  (unless org-museum--index
    (org-museum-index-build)))

;; Fix-04: rewrites file: links for non-.org assets (images, PDFs, etc.)
(defun org-museum--rewrite-org-museum-links (buf out-file)
  "Rewrite wiki:, museum:, id:, and asset file: links in BUF to relative HTML paths.
[Fix-04] file: links pointing to image/PDF/SVG/attachment resources are now
rewritten to paths relative to OUT-FILE, fixing broken asset URLs in
pages exported from subdirectories.
Applicable scope: org-museum--export-with-theme pre-processing.
Known limitation: only rewrites extensions: png jpg gif webp svg pdf txt."
  (with-current-buffer buf
    ;; wiki:/museum: wiki page links
    (goto-char (point-min))
    (while (re-search-forward
            "\\[\\[\\(?:wiki\\|museum\\):\\([^]]+\\)\\]\\(\\[\\([^]]+\\)\\]\\)?\\]" nil t)
      (let* ((id   (match-string 1))
             (desc (match-string 3))
             (page (org-museum--find-page id))
             (href (org-museum--page-href id out-file)))
        (replace-match
         (if page
             (format "[[file:%s]%s]" href (if desc (format "[%s]" desc) ""))
           (match-string 0))
         t t)))
    ;; id: org-id links
    (goto-char (point-min))
    (while (re-search-forward
            "\\[\\[id:\\([^]]+\\)\\]\\(\\[\\([^]]+\\)\\]\\)?\\]" nil t)
      (let* ((id   (match-string 1))
             (desc (match-string 3))
             (page (org-museum--find-page id))
             (href (org-museum--page-href id out-file)))
        (replace-match
         (if page
             (format "[[file:%s]%s]" href (if desc (format "[%s]" desc) ""))
           (match-string 0))
         t t)))
    ;; [Fix-04] file: links to non-.org resources — rewrite to out-file-relative paths
    (goto-char (point-min))
    (while (re-search-forward
            "\\[\\[file:\\([^]]+\\.\\(?:png\\|jpg\\|jpeg\\|gif\\|webp\\|svg\\|pdf\\|txt\\|zip\\)\\)\\]"
            nil t)
      (let* ((asset-path  (match-string 1))
             (full-asset  (expand-file-name asset-path
                                            (file-name-directory
                                             (buffer-file-name buf))))
             (rel-to-out  (org-museum--relative-path full-asset out-file)))
        (unless (string= asset-path rel-to-out)
          (replace-match
           (format "[[file:%s]" rel-to-out) t t nil 0))))))

(defun org-museum--page-href (id &optional current-out-file)
  "Return relative HTML path to page ID from CURRENT-OUT-FILE."
  (if-let ((page (org-museum--find-page id)))
      (let* ((target-html (org-museum--export-filename (org-museum-page-path page)))
             (base-dir    (if current-out-file
                              (file-name-directory (expand-file-name current-out-file))
                            (org-museum--shared-root))))
        (replace-regexp-in-string "\\\\" "/"
                                  (file-relative-name target-html base-dir)))
    (concat id ".html")))

(defun org-museum--export-filename (org-file)
  "Return the target HTML path for ORG-FILE.
The output mirrors the source directory structure under scan-root,
ensuring org-museum--page-href can correctly compute relative URLs."
  (let* ((scan-root (org-museum--scan-root))
         (rel-dir   (file-relative-name
                     (file-name-directory (expand-file-name org-file))
                     scan-root))
         (out-root  (org-museum--scan-root))
         (out-dir   (if (string= rel-dir ".")
                        out-root
                      (expand-file-name rel-dir out-root))))
    (expand-file-name (concat (file-name-base org-file) ".html") out-dir)))

(defun org-museum--parse-tags (tags-string)
  "Convert a FILETAGS string to a list of tag strings."
  (when (and tags-string (not (string-empty-p tags-string)))
    (cl-remove-if #'string-empty-p (split-string tags-string ":" t))))

(defun org-museum--extract-keywords (ast)
  "Return a hash-table of keyword→value from org AST."
  (let ((kw (make-hash-table :test 'equal)))
    (org-element-map ast 'keyword
      (lambda (k)
        (puthash (org-element-property :key k)
                 (org-element-property :value k) kw)))
    kw))

(defun org-museum--generate-id (file)
  "Derive a page ID from FILE path relative to the scan root."
  (replace-regexp-in-string
   "[/\\\\]" "-"
   (file-name-sans-extension
    (file-relative-name file (org-museum--scan-root)))))

(defun org-museum--title-to-id (title)
  "Convert TITLE to a URL-safe ID string."
  (downcase
   (replace-regexp-in-string "[^a-z0-9\u4e00-\u9fff]+" "-" (string-trim title))))

;; Fix-16: category name → filesystem-safe directory name.
(defun org-museum--category-to-dir (category)
  "Convert CATEGORY to a filesystem-safe subdirectory name.
Rules applied in order:
  1. Trim surrounding whitespace
  2. Collapse runs of non-alphanumeric, non-CJK chars to a single hyphen
  3. Strip any leading or trailing hyphens
  4. Lowercase the result
CJK characters (\\u4e00–\\u9fff) are preserved as-is.
Applicable scope: org-museum-create-page (Fix-16)."
  (downcase
   (replace-regexp-in-string
    "-+$" ""
    (replace-regexp-in-string
     "^-+" ""
     (replace-regexp-in-string
      "[^a-z0-9\u4e00-\u9fff]+" "-"
      (string-trim (or category "uncategorized")))))))

(defun org-museum--file-mtime (file)
  "Return modification time of FILE as a float."
  (float-time (file-attribute-modification-time (file-attributes file))))

(defun org-museum--adjoin-to-list (table key value)
  "Add VALUE to the list stored in TABLE at KEY (deduplicating)."
  (puthash key (cl-adjoin value (gethash key table) :test #'equal) table))

(defun org-museum--ensure-list (val)
  "Coerce VAL to a list."
  (cond ((null val)    nil)
        ((vectorp val) (append val nil))
        ((listp val)   val)
        (t             (list val))))

(defun org-museum--find-page (id)
  "Look up page by ID in the current index."
  (when org-museum--index
    (gethash id (org-museum-index-pages org-museum--index))))

(defun org-museum--find-page-by-path (path pages-table)
  "Find the page in PAGES-TABLE whose path equals PATH."
  (let (result)
    (maphash (lambda (_id page)
               (when (file-equal-p (org-museum-page-path page) path)
                 (setq result page)))
             pages-table)
    result))

;; ============================================================
;; §19  SIDEBAR INJECTION
;; ============================================================

(defun org-museum--build-sidebar-injection (out-file)
  "Return the full sidebar+script HTML string to inject before </body>."
  (concat
   "<input type=\"checkbox\" id=\"mobile-sidebar-toggle\" class=\"mobile-toggle\">\n"
   "<input type=\"checkbox\" id=\"mobile-toc-toggle\"     class=\"mobile-toggle\">\n"
   "<div id=\"mobile-hud\">\n"
   "  <label for=\"mobile-sidebar-toggle\" id=\"btn-sidebar\" class=\"hud-btn\">"
   "<span>≡</span> MENU</label>\n"
   "  <label for=\"mobile-toc-toggle\" id=\"btn-toc\" class=\"hud-btn\">"
   "TOC <span>≡</span></label>\n"
   "</div>\n"
   "<div id=\"zen-mask\"></div>\n"
   "<canvas id=\"org-museum-fx-canvas\" aria-hidden=\"true\"></canvas>\n"
   (org-museum--generate-sidebar-html out-file)
   "<aside id=\"org-museum-right-sidebar\" class=\"glass-drawer\">"
   "<h4>ON THIS PAGE</h4></aside>\n"
   (org-museum--script-ui-core)
   (org-museum--script-effects)
   (org-museum--script-toc-relocate)))

;; ============================================================
;; §20  LEFT SIDEBAR HTML
;; ============================================================

(defun org-museum--generate-sidebar-html (out-file)
  "Generate left sidebar HTML for OUT-FILE."
  (unless (and org-museum--index
               (> (hash-table-count (org-museum-index-pages org-museum--index)) 0))
    (let ((idx-path (org-museum--index-file-path)))
      (when (file-exists-p idx-path)
        (ignore-errors (org-museum--index-load idx-path)))))
  (let* ((shared-root (org-museum--shared-root))
         (home-href   (org-museum--relative-path
                       (expand-file-name "index.html" shared-root) out-file))
         (graph-href  (org-museum--relative-path
                       (expand-file-name "graph.html" shared-root) out-file))
         (cats        (org-museum--sorted-categories)))
    (with-output-to-string
      (princ "<div id=\"org-museum-sidebar\">\n")
      (princ "  <div class=\"sidebar-brand\">📚 Org Museum</div>\n")
      (princ (format "  <a class=\"sidebar-nav-btn\" href=\"%s\">🏠 Home</a>\n"
                     (replace-regexp-in-string "\\\\" "/" home-href)))
      (princ (format "  <a class=\"sidebar-nav-btn graph\" href=\"%s\">🕸 Graph</a>\n"
                     (replace-regexp-in-string "\\\\" "/" graph-href)))
      (princ "  <div class=\"sidebar-search\">\n")
      (princ "    <input type=\"text\" id=\"org-museum-search-input\" placeholder=\"Search…\">\n")
      (princ "  </div>\n")
      (princ (org-museum--sidebar-fx-controls))
      (if (null cats)
          (princ "  <p class=\"sidebar-empty\">(Index empty — run org-museum-index-build)</p>\n")
        (dolist (cat-entry cats)
          (princ "  <div class=\"sidebar-category\">\n")
          (princ (format "    <div class=\"sidebar-cat-label\">%s</div>\n" (car cat-entry)))
          (princ "    <ul>\n")
          (dolist (p (cdr cat-entry))
            (princ (format "      <li><a href=\"%s\">%s</a></li>\n"
                           (org-museum--page-href (org-museum-page-id p) out-file)
                           (org-museum-page-title p))))
          (princ "    </ul>\n")
          (princ "  </div>\n")))
      (princ "</div>\n")
      (princ (org-museum--script-sidebar-search)))))

(defun org-museum--sidebar-fx-controls ()
  "Return HTML for the background-effects control panel."
  (concat
   "  <div class=\"sidebar-fx-controls\">\n"
   "    <div class=\"fx-label\">✨ Effects</div>\n"
   "    <div class=\"fx-buttons\">\n"
   "      <button class=\"fx-btn\" data-fx=\"none\">Off</button>\n"
   "      <button class=\"fx-btn\" data-fx=\"tubes\">Tubes</button>\n"
   "      <button class=\"fx-btn\" data-fx=\"matrix\">Matrix</button>\n"
   "      <button class=\"fx-btn\" data-fx=\"particles\">Particles</button>\n"
   "    </div>\n"
   "  </div>\n"))

;; ============================================================
;; §21  WIKI NAVIGATION
;; ============================================================

(defun org-museum--build-nav-html (links backs out-file)
  "Generate nav HTML for LINKS (outgoing) and BACKS (incoming)."
  (concat
   "<nav class=\"org-museum-nav\">\n"
   (when links
     (concat
      "<div class=\"org-museum-nav-links\">"
      "<span class=\"org-museum-nav-label\">Outgoing:</span>"
      (mapconcat (lambda (id)
                   (let* ((p (gethash id (org-museum-index-pages org-museum--index)))
                          (title (if p (org-museum-page-title p) id)))
                     (format "<a href=\"%s\" class=\"org-museum-link\">%s</a>"
                             (org-museum--page-href id out-file) title)))
                 links " ")
      "</div>\n"))
   (when backs
     (concat
      "<div class=\"org-museum-nav-backlinks\">"
      "<span class=\"org-museum-nav-label\">Incoming:</span>"
      (mapconcat (lambda (id)
                   (let* ((p (gethash id (org-museum-index-pages org-museum--index)))
                          (title (if p (org-museum-page-title p) id)))
                     (format "<a href=\"%s\" class=\"org-museum-link\">%s</a>"
                             (org-museum--page-href id out-file) title)))
                 backs " ")
      "</div>\n"))
   "</nav>\n"))

;; ============================================================
;; §22  LOCAL KNOWLEDGE GRAPH  [Fix-07 + Fix-08]
;; ============================================================

(defun org-museum--graph-render-js (config)
  "Return a JS snippet that renders a D3 graph using CONFIG plist.
CONFIG keys:
  :container-id       string  — CSS id of mount element
  :data-var           string  — JS variable holding {nodes,links}
  :height             number  — SVG height px (default 220)
  :center-color       string  — fill for center node
  :node-color         string  — fill for regular nodes
  :link-color         string  — stroke for links
  :font-size          string  — label font size (default \"11px\")
  :nav-on-click       bool    — navigate on node click
  :show-labels        bool    — render text labels
  :use-category-color bool    — use palette based on node.group
  :link-arrow         bool    — [Fix-07] add directional arrowheads to links
Applicable scope: local graph (§22) and global graph (§23).
Known limitation: category coloring ignores :node-color and :center-color."
  (let* ((cid      (plist-get config :container-id))
         (dv       (plist-get config :data-var))
         (height   (or (plist-get config :height) 220))
         (c-col    (or (plist-get config :center-color) "#f92672"))
         (n-col    (or (plist-get config :node-color)   "#66d9ef"))
         (l-col    (or (plist-get config :link-color)   "#66d9ef"))
         (fsize    (or (plist-get config :font-size)    "11px"))
         (nav      (if (plist-get config :nav-on-click)       "true" "false"))
         (labels   (if (plist-get config :show-labels)        "true" "false"))
         (use-cat  (if (plist-get config :use-category-color) "true" "false"))
         (arrows   (if (plist-get config :link-arrow)         "true" "false"))
         (palette  (json-encode org-museum--graph-palette)))
    (format "
  var pal=%s;
  var cats=Array.from(new Set((%s).nodes.map(function(d){return d.group||'';})));
  function catCol(c){return pal[cats.indexOf(c)%%%%(pal.length)]||'#75715e';}
  function nCol(d){return (%s)?catCol(d.group):(d.center?'%s':'%s');}
  function nR(d){return d.center?9:Math.max(5,Math.min(18,5+(d.degree||0)*1.8));}
  var el=document.getElementById('%s');
  if(!el||!(%s).nodes||(%s).nodes.length<1)return;
  var W=el.clientWidth||400,H=%d;
  var svg=d3.select('#%s').append('svg')
    .attr('width','100%%%%').attr('height',H).attr('viewBox','0 0 '+W+' '+H);
  if(%s){
    svg.append('defs').append('marker')
      .attr('id','arrow-%s').attr('viewBox','0 -4 8 8')
      .attr('refX',18).attr('refY',0)
      .attr('markerWidth',6).attr('markerHeight',6)
      .attr('orient','auto')
      .append('path').attr('d','M0,-4L8,0L0,4').attr('fill','%s');
  }
  var g=svg.append('g');
  var sim=d3.forceSimulation((%s).nodes)
    .force('link',d3.forceLink((%s).links).id(function(d){return d.id;}).distance(80))
    .force('charge',d3.forceManyBody().strength(-160))
    .force('center',d3.forceCenter(W/2,H/2))
    .force('collide',d3.forceCollide().radius(function(d){return nR(d)+6;}));
  var linkSel=g.append('g').selectAll('line').data((%s).links).enter()
    .append('line').attr('stroke','%s').attr('stroke-opacity',0.9).attr('stroke-width',2)
    .attr('marker-end',(%s)?'url(#arrow-%s)':null);
  var node=g.append('g').selectAll('g').data((%s).nodes).enter()
    .append('g').style('cursor','pointer');
  node.append('circle').attr('r',nR).attr('fill',nCol)
    .attr('stroke','rgba(255,255,255,0.2)').attr('stroke-width',1.5);
  if(%s){
    node.append('text').attr('dx',13).attr('dy','.35em')
      .text(function(d){return d.name;})
      .style('font-size','%s').style('fill','#f8f8f2')
      .style('font-family','var(--font-sans)');
  }
  if(%s){node.on('click',function(e,d){window.location.href=d.url||(d.id+'.html');});}
  sim.on('tick',function(){
    linkSel.attr('x1',function(d){return d.source.x;}).attr('y1',function(d){return d.source.y;})
        .attr('x2',function(d){return d.target.x;}).attr('y2',function(d){return d.target.y;});
    node.attr('transform',function(d){return 'translate('+d.x+','+d.y+')';});
  });"
            palette dv use-cat c-col n-col
            cid dv dv height cid
            arrows cid l-col
            dv dv dv
            l-col arrows cid dv
            labels fsize nav)))

;; Fix-08: neighbour capping with _overflow virtual node.
(defun org-museum--generate-local-graph-data (page)
  "Return JSON-compatible alist for a local graph centred on PAGE.
[Fix-08] When total neighbour count exceeds `org-museum-local-graph-neighbour-limit',
neighbours are sorted by degree descending; excess nodes are folded into a
virtual node {id: \"_overflow\", name: \"+ N more\"} that links back to the
page's entry in graph.html.
Applicable scope: org-museum--generate-local-graph-html.
Known limitation: _overflow node always links to graph.html root, not
  to a pre-filtered view of this page's full neighbourhood."
  (let* ((center-id  (org-museum-page-id page))
         (limit      org-museum-local-graph-neighbour-limit)
         (all-nbrs   (cl-union (org-museum-page-links-to page)
                               (org-museum-page-linked-from page)
                               :test #'equal))
         (sorted-nbrs
          (sort (copy-sequence all-nbrs)
                (lambda (a b)
                  (let ((pa (gethash a (org-museum-index-pages org-museum--index)))
                        (pb (gethash b (org-museum-index-pages org-museum--index))))
                    (> (if pa (length (org-museum-page-links-to pa)) 0)
                       (if pb (length (org-museum-page-links-to pb)) 0))))))
         (capped     (seq-take sorted-nbrs limit))
         (overflow   (- (length all-nbrs) (length capped)))
         (nodes      (list `((id . ,center-id)
                             (name . ,(org-museum-page-title page))
                             (center . t)
                             (degree . 0)
                             (url . ,(org-museum--page-href center-id nil)))))
         (links      '()))
    (dolist (nid capped)
      (when-let ((p (gethash nid (org-museum-index-pages org-museum--index))))
        (push `((id . ,nid)
                (name . ,(org-museum-page-title p))
                (degree . ,(length (org-museum-page-links-to p)))
                (url . ,(org-museum--page-href nid nil)))
              nodes)
        (if (member nid (org-museum-page-links-to page))
            (push `((source . ,center-id) (target . ,nid)) links)
          (push `((source . ,nid) (target . ,center-id)) links))))
    (when (> overflow 0)
      (let* ((graph-url (org-museum--relative-path
                         (expand-file-name "graph.html" (org-museum--shared-root))
                         (org-museum--export-filename (org-museum-page-path page))))
             (overflow-id "_overflow"))
        (push `((id . ,overflow-id)
                (name . ,(format "+ %d more" overflow))
                (degree . 0)
                (url . ,graph-url))
              nodes)
        (push `((source . ,center-id) (target . ,overflow-id)) links)))
    `((nodes . ,(vconcat nodes)) (links . ,(vconcat links)))))

(defun org-museum--generate-local-graph-html (page)
  "Return HTML+JS for a local D3 graph around PAGE.
[Fix-07] Passes :link-arrow t to the shared renderer.
[Fix-08] Neighbour count is capped via generate-local-graph-data."
  (let* ((data   (org-museum--generate-local-graph-data page))
         (json   (json-encode data))
         (render (org-museum--graph-render-js
                  (list :container-id    "local-graph"
                        :data-var        "data"
                        :height          220
                        :center-color    "#f92672"
                        :node-color      "#66d9ef"
                        :link-color      "#66d9ef"
                        :font-size       "11px"
                        :show-labels     t
                        :nav-on-click    t
                        :link-arrow      t
                        :use-category-color nil))))
    (format "
<div id=\"local-graph-container\">
  <h3>🕸 Related Pages</h3>
  <div id=\"local-graph\"></div>
  <script>
  (function(){
    var data=%s;
    function init(){%s}
    if(typeof d3==='undefined'){
      var s=document.createElement('script');
      s.src='%s';s.onload=init;document.head.appendChild(s);
    }else{init();}
  })();
  </script>
</div>"
            json render org-museum--d3-cdn)))

;; ============================================================
;; §23  GLOBAL GRAPH HTML  [Fix-06 pre-ticks]
;; ============================================================

(defun org-museum--build-graph-html (json-data css-href)
  "Return complete graph.html content with performance-tier awareness.
[Fix-06] Reads meta.pre-ticks from JSON and silently pre-heats the
D3 simulation before DOM rendering begins, preventing node pile-up
in large-tier graphs."
  (format "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
  <title>Org Museum — Knowledge Graph</title>
  <link rel=\"stylesheet\" href=\"%s\">
  <script src=\"%s\"></script>
</head>
<body class=\"graph-page\">
  <div id=\"graph-controls\">
    <h3>🕸 Org Museum Graph</h3>
    <p id=\"graph-render-mode\" style=\"font-size:0.75rem;color:#94a3b8\"></p>
    <p>Zoom / Drag / Hover</p>
    <a class=\"graph-btn primary\" href=\"index.html\">⬅ Back Home</a>
    <button class=\"graph-btn\" id=\"btn-reset\">Reset View</button>
    <button class=\"graph-btn\" id=\"btn-freeze\">Freeze Layout</button>
    <div id=\"graph-search-wrap\">
      <input id=\"graph-search\" type=\"text\" placeholder=\"Search nodes…\">
    </div>
  </div>
  <div id=\"graph-canvas\"></div>
  <div id=\"graph-tooltip\">
    <div class=\"tt-title\" id=\"tt-title\"></div>
    <div class=\"tt-meta\"  id=\"tt-meta\"></div>
    <div class=\"tt-hint\">Click to navigate</div>
  </div>
  <div id=\"graph-stats\">
    <div class=\"stat-badge\"><strong id=\"stat-nodes\">0</strong> Pages</div>
    <div class=\"stat-badge\"><strong id=\"stat-links\">0</strong> Links</div>
    <div class=\"stat-badge\"><strong id=\"stat-cats\">0</strong> Cats</div>
  </div>
  <script>
  (function(){
    var raw=%s;
    var nodes=raw.nodes.map(function(d){return Object.assign({},d);});
    var links=raw.links.map(function(d){return Object.assign({},d);});

    var meta=raw.meta||{};
    var charge     = meta.charge      || -200;
    var alphaDecay = meta['alpha-decay'] || 0.0228;
    var tickLimit  = meta['tick-limit']  || null;
    var preTicks   = meta['pre-ticks']   || 0;
    var tierLabel  = meta['tier-label']  || 'Full Simulation';
    var modeEl=document.getElementById('graph-render-mode');
    if(modeEl) modeEl.textContent='Render: '+tierLabel+(preTicks?' (pre-heat '+preTicks+'t)':'');

    document.getElementById('stat-nodes').textContent=nodes.length;
    document.getElementById('stat-links').textContent=links.length;
    var cats=Array.from(new Set(nodes.map(function(d){return d.group;})));
    document.getElementById('stat-cats').textContent=cats.length;

    var pal=%s;
    function col(c){return pal[cats.indexOf(c)%%pal.length]||'#75715e';}
    function nR(d){return Math.max(6,Math.min(22,7+(d.degree||0)*2.2));}

    var cvs=document.getElementById('graph-canvas'),W=cvs.clientWidth,H=cvs.clientHeight;
    var svg=d3.select('#graph-canvas').append('svg').attr('width',W).attr('height',H);

    svg.append('defs').append('marker')
      .attr('id','arrow-global').attr('viewBox','0 -4 8 8')
      .attr('refX',22).attr('refY',0)
      .attr('markerWidth',6).attr('markerHeight',6)
      .attr('orient','auto')
      .append('path').attr('d','M0,-4L8,0L0,4').attr('fill','#66d9ef').attr('opacity',0.6);

    var cont=svg.append('g');
    var zm=d3.zoom().scaleExtent([0.05,8])
      .on('zoom',function(e){cont.attr('transform',e.transform);});
    svg.call(zm);

    var sim=d3.forceSimulation(nodes)
      .alphaDecay(alphaDecay)
      .force('link',d3.forceLink(links).id(function(d){return d.id;})
             .distance(function(d){return 100+(d.source.degree||0)*5;}))
      .force('charge',d3.forceManyBody().strength(charge))
      .force('center',d3.forceCenter(W/2,H/2))
      .force('collide',d3.forceCollide().radius(function(d){return nR(d)+8;}));

    if(preTicks>0){
      sim.stop();
      for(var pt=0;pt<preTicks;pt++){sim.tick();}
    }

    var lSel=cont.append('g').attr('class','graph-links')
      .selectAll('line').data(links).enter()
      .append('line')
      .attr('stroke','#66d9ef').attr('stroke-opacity',0.4).attr('stroke-width',1.5)
      .attr('marker-end','url(#arrow-global)');

    var nSel=cont.append('g').attr('class','graph-nodes')
      .selectAll('g').data(nodes).enter()
      .append('g').style('cursor','pointer')
      .call(d3.drag()
        .on('start',function(e,d){if(!e.active)sim.alphaTarget(0.3).restart();d.fx=d.x;d.fy=d.y;})
        .on('drag', function(e,d){d.fx=e.x;d.fy=e.y;})
        .on('end',  function(e,d){if(!e.active)sim.alphaTarget(0);d.fx=null;d.fy=null;}));

    nSel.append('circle').attr('r',nR).attr('fill',function(d){return col(d.group);})
      .attr('stroke','rgba(255,255,255,0.2)').attr('stroke-width',1.5);
    nSel.append('text').attr('dx',function(d){return nR(d)+4;}).attr('dy','.35em')
      .text(function(d){return d.name;}).attr('fill','#f8f8f2')
      .style('font-size','11px').style('font-family','var(--font-sans)');

    var tickCount=0;
    function tickRender(){
      lSel.attr('x1',function(d){return d.source.x;}).attr('y1',function(d){return d.source.y;})
          .attr('x2',function(d){return d.target.x;}).attr('y2',function(d){return d.target.y;});
      nSel.attr('transform',function(d){return 'translate('+d.x+','+d.y+')';});
    }
    if(preTicks>0){tickRender();}
    sim.on('tick',function(){
      tickCount++;
      tickRender();
      if(tickLimit&&tickCount>=tickLimit)sim.stop();
    });
    if(preTicks>0){sim.alpha(0.3).restart();}

    var adj={};
    nodes.forEach(function(n){adj[n.id]=new Set();});
    links.forEach(function(l){
      var s=l.source.id||l.source,t=l.target.id||l.target;
      if(adj[s])adj[s].add(t);if(adj[t])adj[t].add(s);
    });

    var tt=document.getElementById('graph-tooltip');
    nSel.on('mouseover',function(e,d){
      nSel.select('circle')
        .classed('dimmed',     function(n){return n.id!==d.id&&!adj[d.id].has(n.id);})
        .classed('highlighted',function(n){return n.id===d.id;});
      nSel.select('text').classed('highlighted',function(n){return n.id===d.id;});
      lSel.classed('highlighted',function(l){
        return(l.source.id||l.source)===d.id||(l.target.id||l.target)===d.id;});
      document.getElementById('tt-title').textContent=d.name;
      document.getElementById('tt-meta').innerHTML=
        'Cat: <b>'+d.group+'</b><br>Links: <b>'+d.degree+'</b>';
      tt.style.visibility='visible';
    }).on('mousemove',function(e){
      tt.style.top=(e.clientY+16)+'px';tt.style.left=(e.clientX+16)+'px';
    }).on('mouseout',function(){
      nSel.select('circle').classed('dimmed highlighted',false);
      nSel.select('text').classed('highlighted',false);
      lSel.classed('highlighted',false);
      tt.style.visibility='hidden';
    }).on('click',function(e,d){window.location.href=d.url||(d.id+'.html');});

    var fz=false;
    document.getElementById('btn-reset').addEventListener('click',function(){
      svg.transition().duration(600).call(zm.transform,d3.zoomIdentity);});
    document.getElementById('btn-freeze').addEventListener('click',function(){
      fz=!fz;this.textContent=fz?'Unfreeze':'Freeze';
      if(fz)sim.stop();else{tickCount=0;sim.alphaTarget(0.3).restart();}});
    document.getElementById('graph-search').addEventListener('input',function(){
      var q=this.value.toLowerCase().trim();
      if(!q){nSel.select('circle').classed('dimmed highlighted',false);
             nSel.select('text').classed('highlighted',false);return;}
      nSel.select('circle')
        .classed('highlighted',function(d){return d.name.toLowerCase().indexOf(q)>=0;})
        .classed('dimmed',     function(d){return d.name.toLowerCase().indexOf(q)<0;});
      nSel.select('text').classed('highlighted',function(d){
        return d.name.toLowerCase().indexOf(q)>=0;});
    });
  })();
  </script>
</body>
</html>"
          css-href
          org-museum--d3-cdn
          json-data
          (json-encode org-museum--graph-palette)))

;; ============================================================
;; §24  SCRIPT: UI CORE  [Fix-09]
;; ============================================================

(defun org-museum--script-ui-core ()
  "Return the main UI script block.
[Fix-09] initScrollSpy now uses IntersectionObserver with #main-scroll
as the root element, eliminating the offsetTop coordinate-system mismatch
that caused TOC highlight to freeze on the first heading."
  (format
   "<script>
(function(){
'use strict';

/* ── 1. Keyboard navigation ── */
var lastKey='',lastKeyTime=0;
document.addEventListener('keydown',function(e){
  if(e.target.matches('input,textarea,[contenteditable=\"true\"]'))return;
  if(e.metaKey||e.ctrlKey||e.altKey)return;
  var now=Date.now(),key=e.key,sc=document.getElementById('main-scroll')||window;
  if(key==='g'){
    if(lastKey==='g'&&(now-lastKeyTime<500)){
      e.preventDefault();sc.scrollTo({top:0,behavior:'smooth'});lastKey='';return;
    }lastKey='g';lastKeyTime=now;return;
  }lastKey='';
  if(key==='G'){e.preventDefault();sc.scrollTo({top:99999,behavior:'smooth'});return;}
  if(['j','k','n','p'].includes(key)){
    var hs=Array.from(document.querySelectorAll('#content h2,#content h3,#content h4'));
    if(!hs.length)return;
    var sp=(sc.scrollTop||window.scrollY)+120,t=null;
    if(key==='j'||key==='n'){for(var i=0;i<hs.length;i++)if(hs[i].offsetTop>sp){t=hs[i];break;}}
    else{for(var j=hs.length-1;j>=0;j--)if(hs[j].offsetTop<sp-20){t=hs[j];break;}}
    if(t){e.preventDefault();sc.scrollTo({top:t.offsetTop-80,behavior:'smooth'});}
  }
});

/* ── 2. Scroll spy [Fix-09: IntersectionObserver relative to #main-scroll] ── */
function initScrollSpy(){
  var sc=document.getElementById('main-scroll');
  var tl=document.querySelectorAll('#org-museum-right-sidebar a[href^=\"#\"]');
  if(!tl.length)return;

  tl.forEach(function(l){
    l.addEventListener('click',function(e){
      var tid=this.getAttribute('href').slice(1),te=document.getElementById(tid);
      if(!te)return;
      e.preventDefault();
      var iz=document.body.classList.contains('zen-mode');
      if(iz)document.body.classList.remove('zen-mode');
      (sc||window).scrollTo({top:te.offsetTop-80,behavior:'smooth'});
      if(iz)setTimeout(function(){document.body.classList.add('zen-mode');updZ();},800);
      history.pushState(null,null,'#'+tid);
    });
  });

  var activeId=null;
  var observer=new IntersectionObserver(function(entries){
    entries.forEach(function(entry){
      if(entry.isIntersecting){
        activeId=entry.target.id;
        tl.forEach(function(l){
          l.classList.toggle('toc-active',l.getAttribute('href')==='#'+activeId);
        });
      }
    });
  },{
    root: sc||null,
    rootMargin: '-10%% 0px -80%% 0px',
    threshold: 0
  });

  tl.forEach(function(l){
    var tid=l.getAttribute('href').slice(1);
    var te=document.getElementById(tid);
    if(te)observer.observe(te);
  });
}

/* ── 3. Code blocks ── */
function initCodeBlocks(){
  var blocks=document.querySelectorAll('pre.src');
  if(!blocks.length)return;
  var langMap={\"emacs-lisp\":\"lisp\",\"sh\":\"bash\"};
  blocks.forEach(function(pre){
    var m=pre.className.match(/src-(\\S+)/),lang=m?m[1]:'text';
    lang=langMap[lang]||lang;
    var code=pre.querySelector('code');
    if(!code){code=document.createElement('code');code.innerHTML=pre.innerHTML;
               pre.innerHTML='';pre.appendChild(code);}
    code.className='hljs language-'+lang;
    var lbl=document.createElement('span');lbl.className='code-lang-label';
    lbl.textContent=lang.toUpperCase();
    var btn=document.createElement('button');btn.className='code-copy-btn';btn.textContent='COPY';
    btn.onclick=function(){
      navigator.clipboard.writeText(code.innerText).then(function(){
        btn.textContent='COPIED!';btn.classList.add('copied');
        setTimeout(function(){btn.textContent='COPY';btn.classList.remove('copied');},2000);
      });
    };
    pre.insertBefore(lbl,pre.firstChild);pre.insertBefore(btn,lbl.nextSibling);
  });
  if(!window.hljs){
    var css=document.createElement('link');css.rel='stylesheet';
    css.href='%s';document.head.appendChild(css);
    var js=document.createElement('script');js.src='%s';js.async=true;
    js.onload=function(){hljs.highlightAll();};document.head.appendChild(js);
  }
}

/* ── 4. Zen mode ── */
function updZ(){
  if(!document.body.classList.contains('zen-mode'))return;
  var sc=document.getElementById('main-scroll');
  var els=Array.from(document.querySelectorAll('.article-container > *'));
  var ctr=(sc?sc.scrollTop:window.scrollY)+(window.innerHeight/2)-100;
  var cls=null,minD=Infinity;
  els.forEach(function(el){
    var d=Math.abs(el.offsetTop-ctr);
    if(d<minD){minD=d;cls=el;}el.classList.remove('zen-focus');
  });
  if(cls)cls.classList.add('zen-focus');
}
document.addEventListener('keydown',function(e){
  if(!e.target.matches('input,textarea')&&e.key==='z'){
    document.body.classList.toggle('zen-mode');
    if(document.body.classList.contains('zen-mode'))updZ();
  }
});
(document.getElementById('main-scroll')||window).addEventListener(
  'scroll',function(){if(document.body.classList.contains('zen-mode'))updZ();},{passive:true});

/* ── 5. Reading progress ── */
function initReadingProgress(){
  var co=document.getElementById('content');
  var h1=co?co.querySelector('h1.title'):null;
  if(co&&h1){
    var min=Math.max(1,Math.ceil(co.textContent.length/400));
    var bdg=document.createElement('div');bdg.className='read-time-badge';
    bdg.textContent='⏱️ Est. Reading / '+min+' min';
    h1.parentNode.insertBefore(bdg,h1.nextSibling);
  }
  var pbC=document.createElement('div');pbC.className='reading-progress-container';
  var pbB=document.createElement('div');pbB.className='reading-progress-bar';
  pbC.appendChild(pbB);document.body.appendChild(pbC);
  var sc=document.getElementById('main-scroll')||window;
  sc.addEventListener('scroll',function(){
    var st=sc.scrollTop||window.scrollY;
    var sh=(sc.scrollHeight||document.documentElement.scrollHeight)
           -(sc.clientHeight||window.innerHeight);
    pbB.style.width=(sh>0?(st/sh)*100:0)+'%%';
  },{passive:true});
}

/* ── 6. Link tooltip ── */
function initLinkTooltip(){
  var tt=document.createElement('div');tt.id='org-museum-link-tooltip';
  document.body.appendChild(tt);
  document.querySelectorAll('.org-museum-link,.article-container a').forEach(function(l){
    l.addEventListener('mouseenter',function(e){
      var hr=l.getAttribute('href')||'';
      if(hr.startsWith('#'))return;
      var r=l.getBoundingClientRect();
      tt.innerHTML='<strong>'+l.textContent+'</strong><span>'+hr+'</span>';
      tt.style.left=r.left+'px';tt.style.top=(r.bottom+10)+'px';
      tt.classList.add('visible');
    });
    l.addEventListener('mouseleave',function(){tt.classList.remove('visible');});
  });
}

/* ── 7. Image lightbox ── */
function initLightbox(){
  var ol=document.createElement('div');ol.id='image-lightbox-overlay';
  var oli=document.createElement('img');ol.appendChild(oli);document.body.appendChild(ol);
  ol.addEventListener('click',function(){ol.classList.remove('visible');});
  document.querySelectorAll('.article-container img').forEach(function(img){
    img.addEventListener('click',function(){oli.src=img.src;ol.classList.add('visible');});
  });
}

/* ── 8. Tufte margin notes ── */
function initMarginNotes(){
  if(window.innerWidth<=1400)return;
  document.querySelectorAll('.footref').forEach(function(ref){
    var nid=ref.getAttribute('href'),ne=document.querySelector(nid);if(!ne)return;
    var nc=document.createElement('div');nc.className='tufte-margin-note';
    nc.innerHTML=ne.innerHTML.replace(/^<sup[^>]*>.*?<\\/sup>\\s*/,'');
    var p=ref.closest('p');
    if(p){p.style.position='relative';
          nc.style.top=Math.max(0,ref.offsetTop-p.offsetTop)+'px';
          nc.style.right='-250px';p.appendChild(nc);}
  });
}

/* ── 9. CJK spacing ── */
function initCJKSpacing(){
  var cn=document.getElementById('content');if(!cn)return;
  var w=document.createTreeWalker(cn,NodeFilter.SHOW_TEXT,null,false),n;
  while((n=w.nextNode())){
    var t=n.nodeValue,nt=t
      .replace(/([\\u4e00-\\u9fa5])([a-zA-Z0-9@#%%$])/g,'$1 $2')
      .replace(/([a-zA-Z0-9@#%%$])([\\u4e00-\\u9fa5])/g,'$1 $2');
    if(t!==nt)n.nodeValue=nt;
  }
}

/* ── 10. Magnetic buttons ── */
function initMagneticButtons(){
  document.querySelectorAll('.hud-btn,.desktop-sidebar-btn,.code-copy-btn').forEach(function(b){
    b.addEventListener('mousemove',function(e){
      var r=b.getBoundingClientRect(),
          x=e.clientX-r.left-r.width/2,y=e.clientY-r.top-r.height/2;
      b.style.transform='translate('+(x*0.2)+'px,'+(y*0.2)+'px)';
    });
    b.addEventListener('mouseleave',function(){b.style.transform='';});
  });
}

/* ── 11. Nav aura ── */
function initNavAura(){
  var sb=document.getElementById('org-museum-sidebar');if(!sb)return;
  var au=document.createElement('div');au.id='nav-aura';sb.appendChild(au);
  sb.addEventListener('mousemove',function(e){
    var r=sb.getBoundingClientRect();
    au.style.transform='translateY('+(e.clientY-r.top-16)+'px)';au.style.opacity='1';
  });
  sb.addEventListener('mouseleave',function(){au.style.opacity='0';});
}

/* ── 12. Desktop sidebar toggle ── */
function initDesktopSidebarToggle(){
  if(window.innerWidth<=1200)return;
  var btn=document.createElement('div');btn.className='desktop-sidebar-btn';btn.textContent='‹';
  document.body.appendChild(btn);
  btn.addEventListener('click',function(){
    var cl=document.body.classList.toggle('desktop-sidebar-closed');
    btn.textContent=cl?'›':'‹';
  });
}

window.addEventListener('load',function(){
  initScrollSpy();
  initCodeBlocks();
  initReadingProgress();
  initLinkTooltip();
  initLightbox();
  initMarginNotes();
  initCJKSpacing();
  initMagneticButtons();
  initNavAura();
  initDesktopSidebarToggle();
});

})();
</script>\n"
   org-museum--hljs-css-cdn
   org-museum--hljs-js-cdn))

;; ============================================================
;; §25  SCRIPT: BACKGROUND EFFECTS  [Fix-10]
;; ============================================================

(defun org-museum--script-effects ()
  "Return the background-effects script block.
[Fix-10] The Tubes effect's mousemove handler `orgMuseumTubesMoveHandler'
is promoted to a module-level named reference so that stp() can
unconditionally remove it regardless of whether `tc' was set.
This prevents listener leak when the user switches effects faster than
the Tubes animation initialises.
Applicable scope: sidebar effects switcher.
Known limitation: module-level var is scoped to the IIFE; safe from collision."
  "<script>
(function(){
function lsGet(k,d){try{return localStorage.getItem(k)||d;}catch(e){return d;}}
function lsSet(k,v){try{localStorage.setItem(k,v);}catch(e){}}

var fxc=document.getElementById('org-museum-fx-canvas');
var cfx=lsGet('org-museum-bg-fx','none');
var aid=null,tc=null;

/* [Fix-10] Named handler reference — allows unconditional removeEventListener */
var orgMuseumTubesMoveHandler=null;

function stp(){
  if(aid)cancelAnimationFrame(aid);aid=null;
  if(tc&&tc.destroy){tc.destroy();tc=null;}
  /* [Fix-10] Always remove the tubes mousemove listener, even if tc was never set */
  if(orgMuseumTubesMoveHandler){
    window.removeEventListener('mousemove',orgMuseumTubesMoveHandler);
    orgMuseumTubesMoveHandler=null;
  }
  if(fxc){var ctx=fxc.getContext('2d');if(ctx)ctx.clearRect(0,0,fxc.width,fxc.height);}
}
function rsz(){if(fxc){fxc.width=window.innerWidth;fxc.height=window.innerHeight;}}
window.addEventListener('resize',rsz);

function startMatrix(){
  if(!fxc)return;
  var ctx=fxc.getContext('2d'),w=fxc.width,h=fxc.height,fs=14,
      cols=Math.floor(w/fs),drps=[];
  for(var x=0;x<cols;x++)drps[x]=1;
  function draw(){
    ctx.fillStyle='rgba(39,40,34,0.05)';ctx.fillRect(0,0,w,h);
    ctx.fillStyle='#66d9ef';ctx.font=fs+'px monospace';
    for(var i=0;i<drps.length;i++){
      var txt=String.fromCharCode(Math.floor(Math.random()*128));
      ctx.fillText(txt,i*fs,drps[i]*fs);
      if(drps[i]*fs>h&&Math.random()>0.975)drps[i]=0;drps[i]++;
    }aid=requestAnimationFrame(draw);
  }draw();
}

function startParticles(){
  if(!fxc)return;
  var ctx=fxc.getContext('2d'),w=fxc.width,h=fxc.height,pts=[];
  for(var i=0;i<50;i++)pts.push({x:Math.random()*w,y:Math.random()*h,
    vx:(Math.random()-0.5)*0.5,vy:(Math.random()-0.5)*0.5,r:Math.random()*2+1});
  function draw(){
    ctx.clearRect(0,0,w,h);ctx.fillStyle='#a6e22e';
    pts.forEach(function(p){
      p.x+=p.vx;p.y+=p.vy;
      if(p.x<0||p.x>w)p.vx*=-1;if(p.y<0||p.y>h)p.vy*=-1;
      ctx.beginPath();ctx.arc(p.x,p.y,p.r,0,Math.PI*2);ctx.fill();
    });
    ctx.strokeStyle='rgba(166,226,46,0.1)';
    for(var i=0;i<pts.length;i++)for(var j=i+1;j<pts.length;j++){
      var dx=pts[i].x-pts[j].x,dy=pts[i].y-pts[j].y;
      if(dx*dx+dy*dy<10000){
        ctx.beginPath();ctx.moveTo(pts[i].x,pts[i].y);
        ctx.lineTo(pts[j].x,pts[j].y);ctx.stroke();}
    }aid=requestAnimationFrame(draw);
  }draw();
}

function startTubes(){
  if(!fxc)return;
  var ctx=fxc.getContext('2d'),w=fxc.width,h=fxc.height,max=50,
      m={x:w/2,y:h/2},pts=[];
  for(var i=0;i<max;i++)pts.push({x:m.x,y:m.y,vx:0,vy:0});

  /* [Fix-10] Assign to module-level named ref before addEventListener */
  orgMuseumTubesMoveHandler=function(e){m.x=e.clientX;m.y=e.clientY;};
  window.addEventListener('mousemove',orgMuseumTubesMoveHandler);

  function draw(){
    ctx.clearRect(0,0,w,h);ctx.lineCap='round';ctx.lineJoin='round';
    var ld=pts[0];ld.vx+=(m.x-ld.x)*0.25;ld.vy+=(m.y-ld.y)*0.25;
    ld.vx*=0.65;ld.vy*=0.65;ld.x+=ld.vx;ld.y+=ld.vy;
    for(var i=1;i<max;i++){
      var pt=pts[i],pr=pts[i-1];
      pt.vx+=(pr.x-pt.x)*0.35;pt.vy+=(pr.y-pt.y)*0.35;
      pt.vx*=0.65;pt.vy*=0.65;pt.x+=pt.vx;pt.y+=pt.vy;
    }
    ctx.beginPath();
    for(var j=0;j<max;j++){
      if(j===0)ctx.moveTo(pts[j].x,pts[j].y);
      else ctx.lineTo(pts[j].x,pts[j].y);
    }
    ctx.strokeStyle='#f92672';ctx.lineWidth=12;
    ctx.shadowBlur=30;ctx.shadowColor='#f92672';
    ctx.globalAlpha=0.4;ctx.stroke();
    ctx.lineWidth=6;ctx.globalAlpha=0.7;ctx.shadowBlur=10;ctx.stroke();
    ctx.strokeStyle='#fff';ctx.lineWidth=2;
    ctx.globalAlpha=1.0;ctx.shadowBlur=0;ctx.stroke();
    aid=requestAnimationFrame(draw);
  }draw();
  tc={destroy:function(){}};
}

function applyFx(fx){
  stp();
  var usesCanvas=['matrix','particles','tubes'].includes(fx);
  if(fxc)fxc.style.display=usesCanvas?'block':'none';
  if(usesCanvas)rsz();
  document.querySelectorAll('.fx-btn').forEach(function(b){
    b.classList.toggle('active',b.getAttribute('data-fx')===fx);
  });
  lsSet('org-museum-bg-fx',fx);
  if(fx==='matrix')        startMatrix();
  else if(fx==='particles')startParticles();
  else if(fx==='tubes')    startTubes();
}

function initFx(){
  var btns=document.querySelectorAll('.fx-btn');if(!btns.length)return;
  btns.forEach(function(b){
    b.addEventListener('click',function(){
      var fx=this.getAttribute('data-fx');if(fx)applyFx(fx);
    });
  });
  applyFx(cfx);
}
if(document.readyState==='loading')
  document.addEventListener('DOMContentLoaded',initFx);
else initFx();
})();
</script>\n")

;; ============================================================
;; §26  SCRIPT: TOC RELOCATION
;; ============================================================

(defun org-museum--script-toc-relocate ()
  "Return script that moves org-generated #table-of-contents to right sidebar."
  "<script>
(function(){
function moveTOC(){
  var toc=document.getElementById('table-of-contents');
  var target=document.getElementById('org-museum-right-sidebar');
  if(!target||!toc)return false;
  var ul=toc.querySelector('ul');
  if(!ul)return false;
  var header=target.querySelector('h4');
  target.innerHTML='';
  if(header)target.appendChild(header);
  target.appendChild(ul);
  if(toc.parentNode)toc.parentNode.removeChild(toc);
  return true;
}
if(!moveTOC()){
  var obs=new MutationObserver(function(muts,o){if(moveTOC())o.disconnect();});
  obs.observe(document.body,{childList:true,subtree:true});
  window.addEventListener('DOMContentLoaded',moveTOC);
}
})();
</script>\n")

;; ============================================================
;; §27  SCRIPT: SIDEBAR SEARCH
;; ============================================================

(defun org-museum--script-sidebar-search ()
  "Return sidebar search script."
  "<script>
(function(){
function init(){
  var inp=document.getElementById('org-museum-search-input');if(!inp)return;
  inp.addEventListener('input',function(){
    var t=this.value.toLowerCase().trim();
    document.querySelectorAll('#org-museum-sidebar .sidebar-category').forEach(function(c){
      var visible=false;
      c.querySelectorAll('li').forEach(function(li){
        var show=!t||li.textContent.toLowerCase().indexOf(t)>=0;
        li.style.display=show?'':'none';if(show)visible=true;
      });
      c.style.display=visible?'':'none';
    });
  });
}
if(document.readyState==='loading')
  document.addEventListener('DOMContentLoaded',init);
else init();
})();
</script>")

;; ============================================================
;; §28  STATUS & INTERACTIVE COMMANDS  [Fix-12]
;; ============================================================

(defun org-museum--index-health-report (pages)
  "Return a plist of health indicators for PAGES hash-table.
Keys:
  :ghost    — list of IDs whose file no longer exists on disk
  :broken   — list of (from-id . missing-target-id) pairs
  :isolated — list of published IDs with no links in or out
  :draft    — list of IDs with status=draft
Applicable scope: org-museum-status, org-museum-index-verify, CI checks."
  (let (ghost broken isolated draft)
    (maphash
     (lambda (id page)
       (unless (file-exists-p (org-museum-page-path page))
         (push id ghost))
       (dolist (target-id (org-museum-page-links-to page))
         (unless (gethash target-id pages)
           (push (cons id target-id) broken)))
       (when (and (string= (or (org-museum-page-status page) "published") "published")
                  (null (org-museum-page-links-to page))
                  (null (org-museum-page-linked-from page)))
         (push id isolated))
       (when (string= (or (org-museum-page-status page) "published") "draft")
         (push id draft)))
     pages)
    (list :ghost ghost :broken broken :isolated isolated :draft draft)))

;; Fix-12: count pages whose HTML is stale relative to their .org or the CSS.
(defun org-museum--count-stale-pages ()
  "Return the number of pages whose HTML output is older than source or CSS.
Uses `org-museum--needs-export-p' which includes the Fix-03 CSS mtime check.
Applicable scope: org-museum-status (Fix-12).
Known limitation: counts all pages in index regardless of status field."
  (let ((count 0))
    (when org-museum--index
      (maphash
       (lambda (_id page)
         (let* ((org-file  (org-museum-page-path page))
                (html-file (org-museum--export-filename org-file)))
           (when (and (file-exists-p org-file)
                      (org-museum--needs-export-p org-file html-file))
             (cl-incf count))))
       (org-museum-index-pages org-museum--index)))
    count))

(defun org-museum-index-verify ()
  "Verify the current index and repair inconsistencies in place.
Repairs performed:
  1. Remove ghost pages (file deleted from disk)
  2. Remove broken outgoing links
  3. Rebuild all linked-from fields from scratch
  4. Persist the repaired index
Applicable scope: post-migration cleanup, scheduled maintenance.
Known limitation: does not re-parse file content; metadata may be stale."
  (interactive)
  (org-museum--guard-init)
  (let* ((pages   (org-museum-index-pages org-museum--index))
         (health  (org-museum--index-health-report pages))
         (ghost   (plist-get health :ghost))
         (broken  (plist-get health :broken))
         (repairs 0))
    (dolist (id ghost)
      (when-let ((pg (gethash id pages)))
        (org-museum--index-remove-page id pg)
        (cl-incf repairs)))
    (dolist (pair broken)
      (when-let ((pg (gethash (car pair) pages)))
        (setf (org-museum-page-links-to pg)
              (delete (cdr pair) (org-museum-page-links-to pg)))
        (cl-incf repairs)))
    (maphash (lambda (_id pg)
               (setf (org-museum-page-linked-from pg) nil))
             pages)
    (maphash (lambda (id pg)
               (dolist (target-id (org-museum-page-links-to pg))
                 (when-let ((target (gethash target-id pages)))
                   (cl-pushnew id (org-museum-page-linked-from target)
                               :test #'equal))))
             pages)
    (org-museum--index-save org-museum--index (org-museum--index-file-path))
    (message "Org Museum [Index]: verify complete — %d repair(s). \
Ghost: %d, Broken links: %d"
             repairs (length ghost) (length broken))))

;;;###autoload
(defun org-museum-status ()
  "Display a structured Org Museum status report.
Sections: configuration, index summary, health metrics,
isolated pages, quick action links.
[Fix-12] Adds 'Stale Exports' count and export-all quick link."
  (interactive)
  (org-museum--guard-init)
  (let* ((pages  (org-museum-index-pages org-museum--index))
         (health (org-museum--index-health-report pages))
         (stale  (org-museum--count-stale-pages)))
    (with-current-buffer (get-buffer-create "*Org Museum Status*")
      (erase-buffer) (org-mode)
      (insert "#+TITLE: Org Museum Status Report\n")
      (insert (format "#+DATE: %s\n\n" (format-time-string "%Y-%m-%d %H:%M")))

      (insert "* Configuration\n\n")
      (insert (format "- Root Dir:    =%s=\n" org-museum-root-dir))
      (insert (format "- Pages Dir:   =%s=\n" (org-museum--pages-base-dir)))
      (insert (format "- CSS Source:  =%s= %s\n"
                      (org-museum--css-source-path)
                      (if (file-exists-p (org-museum--css-source-path)) "✓" "✗ MISSING")))
      (insert (format "- Export Dir:  =%s=\n" (org-museum--pages-root)))
      (insert (format "- Scan Dir:    =%s=\n" (org-museum--scan-root)))

      (insert "\n* Index Summary\n\n")
      (insert (format "- Total Pages:  %d\n" (hash-table-count pages)))
      (insert (format "- Categories:   %d\n"
                      (hash-table-count (org-museum-index-categories org-museum--index))))
      (insert (format "- Tags:         %d\n"
                      (hash-table-count (org-museum-index-tags org-museum--index))))

      (insert "\n* Index Health\n\n")
      (insert (format "- Ghost Pages:    %d  %s\n"
                      (length (plist-get health :ghost))
                      (if (plist-get health :ghost)
                          "⚠ [[elisp:(org-museum-index-verify)][Fix now]]" "✓")))
      (insert (format "- Broken Links:   %d  %s\n"
                      (length (plist-get health :broken))
                      (if (plist-get health :broken)
                          "⚠ [[elisp:(org-museum-check-links)][Check links]]" "✓")))
      (insert (format "- Isolated Pages: %d\n"
                      (length (plist-get health :isolated))))
      (insert (format "- Draft Pages:    %d\n"
                      (length (plist-get health :draft))))
      (insert (format "- Stale Exports:  %d  %s\n"
                      stale
                      (if (> stale 0)
                          "[[elisp:(org-museum-export-all)][Export now]]"
                        "✓ All up to date")))

      (when (plist-get health :ghost)
        (insert "\n** Ghost Pages\n\n")
        (dolist (id (plist-get health :ghost))
          (insert (format "- =%s=\n" id))))

      (when (plist-get health :broken)
        (insert "\n** Broken Links\n\n")
        (dolist (item (plist-get health :broken))
          (insert (format "- [[museum:%s][%s]] → ==%s== missing\n"
                          (car item) (car item) (cdr item)))))

      (when (plist-get health :isolated)
        (insert "\n** Isolated Published Pages\n\n")
        (dolist (id (plist-get health :isolated))
          (when-let ((p (gethash id pages)))
            (insert (format "- [[museum:%s][%s]]\n"
                            id (org-museum-page-title p))))))

      (insert "\n* Quick Actions\n\n")
      (insert "- [[elisp:(org-museum-export-graph)][Generate Knowledge Graph]]\n")
      (insert "- [[elisp:(org-museum-index-build t)][Force Rebuild Index]]\n")
      (insert "- [[elisp:(org-museum-index-verify)][Verify & Repair Index]]\n")
      (insert "- [[elisp:(org-museum-check-links)][Check All Links]]\n")
      (insert "- [[elisp:(org-museum-export-all)][Export All Pages]]\n")

      (display-buffer (current-buffer)))))

;;;###autoload
(defun org-museum-init (root-dir)
  "Initialise an Org Museum workspace at ROOT-DIR."
  (interactive "DSelect Org Museum Root: ")
  (setq org-museum-root-dir (expand-file-name root-dir))
  (dolist (dir (list "pages" "themes" "exports/html" "exports/html/resources"
                     org-museum-pages-subdir))
    (make-directory (expand-file-name dir org-museum-root-dir) t))
  (org-museum--ensure-css-deployed)
  (org-museum-index-build t)
  (message "Org Museum initialised: %s" org-museum-root-dir))

;; ============================================================
;; §29  MINOR MODE  [Fix-02 debounce + Fix-13 defvar]
;; ============================================================

(defun org-museum--dispatch-status-string ()
  "Return a one-line status string for the dispatch panel."
  (if org-museum--index
      (format "Index: %d pages | Root: %s"
              (hash-table-count (org-museum-index-pages org-museum--index))
              (abbreviate-file-name (or org-museum-root-dir "unset")))
    "Index: not loaded"))

(defun org-museum--dispatch-minibuffer ()
  "Command panel fallback using `completing-read'."
  (let* ((status (org-museum--dispatch-status-string))
         (cmds
          `(("n  Create Page"      . org-museum-create-page)
            ("f  Complete Link"    . org-museum-link-complete)
            ("e  Export This Page" . org-museum-export-page)
            ("E  Export All"       . org-museum-export-all)
            ("g  Export Graph"     . org-museum-export-graph)
            ("r  Rename Page"      . org-museum-rename-page)
            ("i  Rebuild Index"    . org-museum-index-build)
            ("v  Verify Index"     . org-museum-index-verify)
            ("l  Check Links"      . org-museum-check-links)
            ("s  Status Report"    . org-museum-status)
            ("I  Init Workspace"   . org-museum-init)))
         (choice (completing-read
                  (format "Org Museum [%s]: " status)
                  (mapcar #'car cmds) nil t)))
    (when-let ((fn (cdr (assoc choice cmds))))
      (call-interactively fn))))

;;;###autoload
(defun org-museum-dispatch ()
  "Show the Org Museum command panel.
Uses `transient' when available, otherwise falls back to `completing-read'.
Applicable scope: daily editing workflow, discoverability."
  (interactive)
  (if (fboundp 'transient-define-prefix)
      (org-museum--dispatch-transient)
    (org-museum--dispatch-minibuffer)))

;; Fix-13 (revised): transient-define-prefix is a macro; when byte-compiled
;; without transient present the compiler cannot expand it and treats it as a
;; plain function, producing (invalid-function transient-define-prefix) at
;; runtime.  Wrapping the call in (eval '(...) t) defers macro expansion to
;; runtime, after transient has been loaded.  declare-function tells the
;; byte-compiler the symbol will become a function, suppressing "not known to
;; be defined" warnings without creating a defvar that shadows the function
;; cell.
(declare-function org-museum--dispatch-transient "org-museum")

(with-eval-after-load 'transient
  (eval
   '(transient-define-prefix org-museum--dispatch-transient ()
      "Org Museum Command Panel."
      [:description
       (lambda () (format "Org Museum — %s"
                          (org-museum--dispatch-status-string)))
       ["Pages"
        ("n" "Create Page"      org-museum-create-page)
        ("r" "Rename Page"      org-museum-rename-page)
        ("f" "Complete Link"    org-museum-link-complete)]
       ["Export"
        ("e" "Export This Page" org-museum-export-page)
        ("E" "Export All"       org-museum-export-all)
        ("g" "Export Graph"     org-museum-export-graph)]
       ["Index"
        ("i" "Rebuild Index"    org-museum-index-build)
        ("v" "Verify & Repair"  org-museum-index-verify)
        ("l" "Check Links"      org-museum-check-links)]
       ["Workspace"
        ("s" "Status Report"    org-museum-status)
        ("I" "Init Workspace"   org-museum-init)]])
   t))

(defvar org-museum-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c w n")   #'org-museum-create-page)
    (define-key map (kbd "C-c w f")   #'org-museum-link-complete)
    (define-key map (kbd "C-c w e")   #'org-museum-export-page)
    (define-key map (kbd "C-c w E")   #'org-museum-export-all)
    (define-key map (kbd "C-c w g")   #'org-museum-export-graph)
    (define-key map (kbd "C-c w r")   #'org-museum-rename-page)
    (define-key map (kbd "C-c w i")   #'org-museum-index-build)
    (define-key map (kbd "C-c w v")   #'org-museum-index-verify)
    (define-key map (kbd "C-c w l")   #'org-museum-check-links)
    (define-key map (kbd "C-c w s")   #'org-museum-status)
    (define-key map (kbd "C-c w SPC") #'org-museum-dispatch)
    map)
  "Keymap for `org-museum-mode'.")

;;;###autoload
(define-minor-mode org-museum-mode
  "Minor mode for managing an Org Museum wiki."
  :lighter " OrgMuseum"
  :keymap org-museum-mode-map
  (if org-museum-mode
      (progn
        (when org-museum-root-dir
          (unless org-museum--index (org-museum-index-build)))
        (add-hook 'after-save-hook #'org-museum--on-save nil t))
    (remove-hook 'after-save-hook #'org-museum--on-save t)))

;; Fix-02: debounced on-save via run-with-idle-timer.
(defun org-museum--on-save ()
  "Incremental index update on buffer save.
[Fix-02] Uses `run-with-idle-timer' to debounce rapid consecutive saves.
Multiple saves within `org-museum-save-debounce-seconds' are coalesced into
a single index update + flush, reducing unnecessary IO.
Guards:
  - org-museum-mode must be active
  - org-museum-root-dir must be set
  - File must be inside project root (G-1)
  - File must have .org extension
Known limitation: timer is per-buffer; simultaneous saves of different
  project files each start their own timer.  Cross-file coalescing would
  require a global timer, which is a future improvement."
  (when (and org-museum-mode
             org-museum-root-dir
             (buffer-file-name)
             (org-museum--file-in-project-p (buffer-file-name))
             (string-suffix-p ".org" (buffer-file-name)))
    (when (timerp org-museum--save-timer)
      (cancel-timer org-museum--save-timer)
      (setq org-museum--save-timer nil))
    (let ((file (buffer-file-name)))
      (setq org-museum--save-timer
            (run-with-idle-timer
             org-museum-save-debounce-seconds nil
             (lambda ()
               (setq org-museum--save-timer nil)
               (org-museum--on-save-flush file)))))))

(defun org-museum--on-save-flush (file)
  "Perform the actual index update for FILE after the debounce delay.
[Fix-02] Called by the idle timer set up in `org-museum--on-save'.
Applicable scope: debounced save-hook (Fix-02).
Known limitation: ID-change detection uses a simple regex; see on-save
  docstring for the full list of edge cases."
  (let* ((pages  (when org-museum--index
                   (org-museum-index-pages org-museum--index)))
         (old-pg (when pages
                   (org-museum--find-page-by-path file pages)))
         (old-id (when old-pg (org-museum-page-id old-pg)))
         (new-id (with-temp-buffer
                   (insert-file-contents file)
                   (goto-char (point-min))
                   (if (re-search-forward
                        "^#\\+WIKI_ID:\\s-*\\(\\S-+\\)\\s-*$" nil t)
                       (string-trim (match-string 1))
                     (org-museum--generate-id file)))))
    (when (and old-id new-id
               (not (string= old-id new-id))
               pages)
      (if (gethash new-id pages)
          (message "Org Museum [Index]: ID [%s] already occupied — \
rename aborted" new-id)
        (when (yes-or-no-p
               (format "Org Museum: WIKI_ID changed %s → %s; \
update all cross-links? " old-id new-id))
          (let ((count (org-museum--update-links-globally old-id new-id)))
            (message "Org Museum [Index]: updated %d file(s)." count)))))
    (org-museum--index-update-file file)))

(provide 'org-museum)

;;; org-museum.el ends here
