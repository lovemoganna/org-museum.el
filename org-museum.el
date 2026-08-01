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
(require 'subr-x)
(require 'url-util)

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

(defconst org-museum--hljs-lisp-js-cdn
  "https://cdn.staticfile.net/highlight.js/11.10.0/languages/lisp.min.js"
  "Highlight.js Lisp language module CDN URL.")

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

(defcustom org-museum-clean-stale-html-on-full-export nil
  "When non-nil, delete stale page HTML after a successful full export.
Only regular, non-symlinked .html files below the configured pages export
root are eligible.  Empty indexes and failed exports always skip cleanup."
  :type 'boolean
  :group 'org-museum)

(defcustom org-museum-category-label-alist nil
  "Display labels for category names without changing Org metadata.
Each entry is (RAW . DISPLAY), for example ((\"Sql\" . \"SQL\"))."
  :type '(alist :key-type string :value-type string)
  :group 'org-museum)

(defcustom org-museum-local-graph-neighbour-limit 12
  "Maximum neighbours shown in local per-page graph.
Nodes beyond this limit are folded into a virtual _overflow node.
Applicable scope: org-museum--generate-local-graph-data (Fix-08)."
  :type 'integer
  :group 'org-museum)

(defcustom org-museum-graph-exclude-tags '("no-graph")
  "List of tag strings to exclude from the exported global graph.

This is the primary noise-control lever for Org Museum's graph.html.
Any page whose FILETAGS contains one of these tags will be omitted from:
- nodes list
- links list (links touching excluded nodes are removed)

Recommended usage:
- Add :no-graph: to low-value / one-off / dashboard pages you still want to
  keep as HTML pages but do not want to surface in the graph.
- Do not exclude broad workflow tags by default. A tagged page can still be a
  graph hub, and filtering it would remove every edge connected to it."
  :type '(repeat string)
  :group 'org-museum)

(defcustom org-museum-graph-exclude-orphans t
  "When non-nil, exclude orphan nodes (degree == 0) from the global graph.

Orphans are typically low-context pages that are not linked from or to any
other page, which adds noise and dilutes meaningful clusters."
  :type 'boolean
  :group 'org-museum)

(defcustom org-museum-graph-exclude-id-regexp nil
  "Optional regexp; when non-nil, exclude pages whose ID matches it.

This is a secondary filter useful for excluding systematic one-off pages
when tags are not reliable yet."
  :type '(choice (const nil) regexp)
  :group 'org-museum)

(defcustom org-museum-save-debounce-seconds 0.5
  "Idle seconds to wait before flushing the index after a save.
Applicable scope: org-museum--on-save debounce (Fix-02).
Known limitation: timer is per-buffer; rapid cross-buffer saves
still trigger multiple flushes."
  :type 'number
  :group 'org-museum)

(defcustom org-museum-code-highlight-method 'hljs
  "Code highlighting method for HTML export.
'hljs        — Use Highlight.js (client-side, recommended).
               Code blocks are exported plain; hljs runs in the browser.
               Provides broad language coverage (SQL, Python, Rust, etc.)
               and a consistent look regardless of Emacs theme.
'inline-css  — Use htmlize with inline CSS (server-side).
               Emacs theme colours are baked into each <span style=\"...\">,
               so SQL keywords match exactly what the Emacs buffer shows.
'css-classes — Use htmlize with CSS class names.
               Generates <span class=\"org-keyword\"> and an accompanying
               <style> block.  Useful when you supply a custom stylesheet."
  :type '(choice (const :tag "Highlight.js (推荐)" hljs)
                 (const :tag "Emacs 内联样式" inline-css)
                 (const :tag "CSS 类名 + 样式表" css-classes))
  :group 'org-museum)

(defcustom org-museum-latex-code-highlight 'minted
  "Code highlighting method for LaTeX/PDF export.
'minted   — Use the minted package (requires Python + Pygments).
            Produces high-quality coloured output with many languages.
'listings — Use the listings package (pure LaTeX, no external deps).
nil       — No code highlighting in PDF exports."
  :type '(choice (const :tag "minted (推荐)" minted)
                 (const :tag "listings" listings)
                 (const nil))
  :group 'org-museum)

;; ============================================================
;; Graph noise control helpers
;; ============================================================

(defun org-museum--graph-page-excluded-p (id page)
  "Return non-nil if PAGE (with ID) should be excluded from global graph."
  (let* ((tags (org-museum-page-tags page))
         (has-excluded-tag
          (and org-museum-graph-exclude-tags
               (cl-some (lambda (tag) (member tag org-museum-graph-exclude-tags)) tags)))
         (id-matches
          (and org-museum-graph-exclude-id-regexp
               (string-match-p org-museum-graph-exclude-id-regexp id))))
    (or has-excluded-tag id-matches)))

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
  id title path tags category modified links-to linked-from theme status description)

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
            (let* ((load-dir (when load-file-name
                               (file-name-directory load-file-name)))
                   (lib-dir  (when-let ((lib (locate-library "org-museum")))
                               (file-name-directory lib)))
                   (repos    (expand-file-name "straight/repos/org-museum.el/"
                                               user-emacs-directory))
                   (links    (expand-file-name "straight/links/org-museum/"
                                               user-emacs-directory))
                   (roam     (expand-file-name "org-roam/" user-emacs-directory))
                   (dirs     (delq nil (list load-dir lib-dir links repos roam))))
              (or (cl-find-if
                   (lambda (dir)
                     (file-exists-p
                      (expand-file-name org-museum-css-file dir)))
                   dirs)
                  load-dir
                  lib-dir
                  default-directory)))))

(defun org-museum--d3-resource-path ()
  "Absolute path to the bundled D3.js file under shared export resources."
  (expand-file-name "resources/d3.v7.min.js" (org-museum--shared-root)))

(defun org-museum--hljs-css-resource-path ()
  "Absolute path to the bundled Highlight.js CSS file."
  (expand-file-name "resources/highlight.monokai.min.css"
                    (org-museum--shared-root)))

(defun org-museum--hljs-js-resource-path ()
  "Absolute path to the bundled Highlight.js script file."
  (expand-file-name "resources/highlight.min.js"
                    (org-museum--shared-root)))

(defun org-museum--hljs-lisp-js-resource-path ()
  "Absolute path to the bundled Highlight.js Lisp language module."
  (expand-file-name "resources/highlight-lisp.min.js"
                    (org-museum--shared-root)))

(defun org-museum--files-have-same-content-p (left right)
  "Return non-nil when existing files LEFT and RIGHT have identical contents."
  (and (file-exists-p left)
       (file-exists-p right)
       (= (file-attribute-size (file-attributes left))
          (file-attribute-size (file-attributes right)))
       (cl-labels
           ((digest
             (file)
             (with-temp-buffer
               (set-buffer-multibyte nil)
               (insert-file-contents-literally file)
               (secure-hash 'sha256 (current-buffer)))))
         (string= (digest left) (digest right)))))

(defun org-museum--resolve-resource-source (path)
  "Resolve PATH through a Windows Straight plain-text link placeholder.
Straight may represent package link-tree files as a short file whose complete
contents are the absolute repository path.  Browsers cannot follow that
representation, so deployment must copy the referenced bytes instead."
  (let ((source (expand-file-name path)))
    (if (and (file-regular-p source)
             (< (file-attribute-size (file-attributes source)) 4096))
        (let ((pointer
               (with-temp-buffer
                 (insert-file-contents source)
                 (string-trim (buffer-string)))))
          (if (and (file-name-absolute-p pointer)
                   (not (equal (org-museum--normalised-path pointer)
                               (org-museum--normalised-path source)))
                   (file-regular-p pointer))
              (expand-file-name pointer)
            source))
      source)))

(defun org-museum--ensure-url-resource (url dest label)
  "Copy a bundled asset or download URL to DEST, returning DEST when it exists.
The package-local resource with the same basename is preferred so a fresh
export remains offline-capable.  LABEL is used only for diagnostics."
  (let ((bundled
         (org-museum--resolve-resource-source
          (expand-file-name
           (concat "resources/" (file-name-nondirectory dest))
           (org-museum--plugin-dir)))))
    (make-directory (file-name-directory dest) t)
    (cond
     ((and (file-exists-p bundled)
           (not (equal (expand-file-name bundled)
                       (expand-file-name dest))))
      (unless (org-museum--files-have-same-content-p bundled dest)
        (copy-file bundled dest t)))
     ((not (file-exists-p dest))
        (require 'url)
        (condition-case err
            (url-copy-file url dest t)
          (error
           (message "Org Museum [Export]: failed to fetch %s: %s"
                    label (error-message-string err)))))))
  (when (file-exists-p dest)
    dest))

(defun org-museum--ensure-d3-deployed ()
  "Ensure D3.js is available locally under shared export resources."
  (org-museum--ensure-url-resource
   org-museum--d3-cdn (org-museum--d3-resource-path) "D3.js"))

(defun org-museum--ensure-hljs-deployed ()
  "Ensure Highlight.js assets are available locally when possible."
  (list
   :css (org-museum--ensure-url-resource
         org-museum--hljs-css-cdn
         (org-museum--hljs-css-resource-path)
         "Highlight.js CSS")
   :js  (org-museum--ensure-url-resource
         org-museum--hljs-js-cdn
         (org-museum--hljs-js-resource-path)
         "Highlight.js script")
   :lisp-js (org-museum--ensure-url-resource
             org-museum--hljs-lisp-js-cdn
             (org-museum--hljs-lisp-js-resource-path)
             "Highlight.js Lisp language module")))

(defun org-museum--hljs-css-src (out-file)
  "Return Highlight.js CSS URL relative to OUT-FILE, falling back to CDN."
  (or (when-let ((path (plist-get (org-museum--ensure-hljs-deployed) :css)))
        (org-museum--relative-path path out-file))
      org-museum--hljs-css-cdn))

(defun org-museum--hljs-js-src (out-file)
  "Return Highlight.js script URL relative to OUT-FILE, falling back to CDN."
  (or (when-let ((path (plist-get (org-museum--ensure-hljs-deployed) :js)))
        (org-museum--relative-path path out-file))
      org-museum--hljs-js-cdn))

(defun org-museum--hljs-lisp-js-src (out-file)
  "Return Highlight.js Lisp module URL relative to OUT-FILE, falling back to CDN."
  (or (when-let ((path (plist-get (org-museum--ensure-hljs-deployed) :lisp-js)))
        (org-museum--relative-path path out-file))
      org-museum--hljs-lisp-js-cdn))

(defun org-museum--d3-js-src (out-file)
  "Return a URL (usually relative) to D3.js suitable for OUT-FILE HTML."
  (let ((local (org-museum--ensure-d3-deployed)))
    (if (and out-file local (file-exists-p local))
        (org-museum--relative-path local out-file)
      org-museum--d3-cdn)))

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
  (org-museum--resolve-resource-source
   (expand-file-name org-museum-css-file (org-museum--plugin-dir))))

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

(defconst org-museum--favicon-link-tag
  "<link rel=\"icon\" href=\"data:,\">"
  "Empty data favicon that prevents a spurious offline favicon request.")

(defun org-museum--html-escape (value &optional attribute)
  "Return VALUE escaped for HTML text, or for an ATTRIBUTE when non-nil."
  (let ((escaped (org-html-encode-plain-text (format "%s" (or value "")))))
    (if attribute
        (replace-regexp-in-string
         "'" "&#39;"
         (replace-regexp-in-string "\"" "&quot;" escaped t t)
         t t)
      escaped)))

(defun org-museum--normalised-path (path)
  "Return a comparison-safe absolute representation of PATH."
  (let ((value (replace-regexp-in-string
                "\\\\" "/" (expand-file-name (or path "")) t t)))
    (if (eq system-type 'windows-nt) (downcase value) value)))

(defun org-museum--find-page-by-expanded-path (path pages-table)
  "Find the page in PAGES-TABLE whose expanded path equals PATH."
  (let ((needle (org-museum--normalised-path path)) result)
    (maphash
     (lambda (_id page)
       (when (equal needle
                    (org-museum--normalised-path (org-museum-page-path page)))
         (setq result page)))
     pages-table)
    result))

(defun org-museum--path-to-file-url (path)
  "Return a properly escaped file URL for absolute PATH."
  (let* ((normal (replace-regexp-in-string
                  "\\\\" "/" (expand-file-name path) t t))
         (encoded (mapconcat #'url-hexify-string
                             (split-string normal "/" nil) "/")))
    (setq encoded (replace-regexp-in-string "%3A" ":" encoded t t))
    (if (string-prefix-p "/" encoded)
        (concat "file://" encoded)
      (concat "file:///" encoded))))

(defun org-museum--file-url-to-path (url)
  "Decode a file URL produced by `org-museum--path-to-file-url'."
  (when (string-match "\\`file:/+\\(.*\\)\\'" (or url ""))
    (let ((path (url-unhex-string (match-string 1 url))))
      (if (and (eq system-type 'windows-nt)
               (string-match-p "\\`[[:alpha:]]:/" path))
          path
        (concat "/" path)))))

(defun org-museum--json-for-html (value)
  "Encode VALUE as JSON safe to embed inside an HTML script element."
  (let ((json-encoding-pretty-print nil)
        (encoded (json-encode value)))
    (dolist (pair '(("<" . "\\u003c")
                    (">" . "\\u003e")
                    ("&" . "\\u0026")
                    ("\u2028" . "\\u2028")
                    ("\u2029" . "\\u2029")))
      (setq encoded
            (replace-regexp-in-string
             (regexp-quote (car pair)) (cdr pair) encoded t t)))
    encoded))

(defun org-museum--page-modified-number (page)
  "Return PAGE modified time as a sortable number."
  (let ((value (org-museum-page-modified page)))
    (if (numberp value) value 0)))

(defun org-museum--sort-pages-by-modified (pages)
  "Return a fresh copy of PAGES sorted newest first."
  (sort (copy-sequence pages)
        (lambda (a b)
          (> (org-museum--page-modified-number a)
             (org-museum--page-modified-number b)))))

(defun org-museum--format-page-date (page &optional dotted)
  "Return PAGE modified date.
When DOTTED is non-nil, use YYYY.MM.DD; otherwise use YYYY-MM-DD."
  (format-time-string
   (if dotted "%Y.%m.%d" "%Y-%m-%d")
   (seconds-to-time (org-museum--page-modified-number page))))

(defun org-museum--published-page-p (page)
  "Return non-nil when PAGE should be visible in the exported index."
  (not (string= (downcase (or (org-museum-page-status page) "published"))
                "draft")))

(defun org-museum--pages-from-categories (cats)
  "Return all unique pages collected from CATS."
  (let ((seen (make-hash-table :test 'equal))
        pages)
    (dolist (entry cats)
      (dolist (page (cdr entry))
        (let ((id (org-museum-page-id page)))
          (when (not (gethash id seen))
            (puthash id t seen)
            (push page pages)))))
    (nreverse pages)))

(defun org-museum--category-label (category)
  "Return the configured display label for CATEGORY."
  (or (cdr (assoc-string category org-museum-category-label-alist t))
      category))

(defun org-museum--strip-html (value)
  "Return VALUE with simple HTML markup removed and entities decoded."
  (let ((text (replace-regexp-in-string "<[^>]+>" "" (or value ""))))
    (setq text (replace-regexp-in-string "&nbsp;" " " text t t))
    (setq text (replace-regexp-in-string "&amp;" "&" text t t))
    (setq text (replace-regexp-in-string "&lt;" "<" text t t))
    (setq text (replace-regexp-in-string "&gt;" ">" text t t))
    (string-trim text)))

(defun org-museum--source-headings (page)
  "Return fallback heading metadata parsed from PAGE's Org source."
  (let ((file (org-museum-page-path page))
        headings)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (org-mode)
        (org-with-wide-buffer
         (org-map-entries
          (lambda ()
            (let ((level (org-current-level)))
              (when (and level (<= level 4))
                (let* ((title (org-get-heading t t t t))
                       (custom (or (org-entry-get nil "CUSTOM_ID")
                                   (org-entry-get nil "ID")))
                       (id (or custom
                               (concat "heading-"
                                       (substring
                                        (secure-hash 'sha1
                                                     (format "%s:%s"
                                                             (org-museum-page-id page)
                                                             title))
                                        0 10)))))
                  (push `((id . ,id) (title . ,title) (level . ,level))
                        headings)))))
          nil nil))))
    (nreverse headings)))

(defun org-museum--exported-headings (page)
  "Return exact exported heading metadata for PAGE when its HTML exists."
  (let ((html-file (ignore-errors
                     (org-museum--export-filename
                      (org-museum-page-path page))))
        headings)
    (when (and html-file (file-readable-p html-file))
      (with-temp-buffer
        (insert-file-contents html-file)
        (goto-char (point-min))
        (while (re-search-forward
                "<h\\([2-4]\\) id=\"\\([^\"]+\\)\"[^>]*>\\(.*?\\)</h[2-4]>"
                nil t)
          (push `((id . ,(match-string-no-properties 2))
                  (title . ,(org-museum--strip-html
                             (match-string-no-properties 3)))
                  (level . ,(string-to-number
                             (match-string-no-properties 1))))
                headings))))
    (nreverse headings)))

(defun org-museum--page-headings (page)
  "Return searchable headings for PAGE with exact exported anchors if possible."
  (or (org-museum--exported-headings page)
      (org-museum--source-headings page)))

(defun org-museum--page-index-alist (page out-file)
  "Return a browser-facing metadata alist for PAGE relative to OUT-FILE."
  `((pageId . ,(org-museum-page-id page))
    (title . ,(org-museum-page-title page))
    (category . ,(org-museum-page-category page))
    (categoryLabel . ,(org-museum--category-label
                       (org-museum-page-category page)))
    (tags . ,(vconcat (org-museum-page-tags page)))
    (status . ,(downcase (or (org-museum-page-status page) "published")))
    (headings . ,(vconcat (org-museum--page-headings page)))
    (modified . ,(org-museum--page-modified-number page))
    (modifiedDate . ,(org-museum--format-page-date page))
    (href . ,(org-museum--page-href (org-museum-page-id page) out-file))))

(defun org-museum--index-data-alist (pages out-file)
  "Return embedded browser index data for PAGES relative to OUT-FILE."
  `((schemaVersion . 2)
    (generatedAt . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
    (pages . ,(vconcat
               (mapcar (lambda (page)
                         (org-museum--page-index-alist page out-file))
                       pages)))))

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
           (status (or (gethash "WIKI_STATUS" kw) "published"))
           (description (gethash "DESCRIPTION" kw)))
      (make-org-museum-page
       :id id :title title :path file :tags tags :category cat
       :modified (org-museum--file-mtime file)
       :links-to nil :linked-from nil :theme theme :status status
       :description description))))

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
  "Return canonical page IDs linked from FILE.
Recognises wiki:, museum:, id:, and file: links.  Org-roam id links are
resolved through every page's :ID: properties, so [[id:UUID][Title]] links
connect to the exported Org Museum page even when the page ID is a slug or
WIKI_ID rather than the Org-roam UUID."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((links '())
          (dir   (file-name-directory file))
          (aliases (org-museum--build-page-id-aliases pages-table)))
      (goto-char (point-min))
      (while (re-search-forward
              "\\[\\[\\(?:wiki\\|museum\\):\\([^]\n]+\\)\\]\\(?:\\[[^]]*\\]\\)?\\]" nil t)
        (when-let ((id (org-museum--resolve-page-link-id
                        (match-string 1) pages-table aliases)))
          (cl-pushnew id links :test #'equal)))
      (goto-char (point-min))
      (while (re-search-forward
              "\\[\\[id:\\([^]\n]+\\)\\]\\(?:\\[[^]]*\\]\\)?\\]" nil t)
        (when-let ((id (org-museum--resolve-page-link-id
                        (match-string 1) pages-table aliases)))
          (cl-pushnew id links :test #'equal)))
      (goto-char (point-min))
      (while (re-search-forward
              "\\[\\[file:\\([^]\n]+\\.org\\)\\]\\(?:\\[[^]]*\\]\\)?\\]" nil t)
        (let* ((target-file (expand-file-name (match-string 1) dir))
               (target-page (org-museum--find-page-by-path target-file pages-table)))
          (when target-page
            (cl-pushnew (org-museum-page-id target-page) links :test #'equal))))
      (dolist (id (org-museum--org-roam-db-linked-page-ids file pages-table aliases))
        (cl-pushnew id links :test #'equal))
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
    (status      . ,(or (org-museum-page-status page) "published"))
    (description . ,(org-museum-page-description page))))

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
                     :status      (org-museum--json-get plist 'status)
                     :description (let ((value (cdr (assq 'description plist))))
                                    (and (stringp value)
                                         (not (string-empty-p value))
                                         value)))))
         (when (and id (not (string-empty-p id)))
           (org-museum--index-register-page index page))))
     (cdr (assq 'pages data)))
    index))

(defun org-museum--index-save (index path)
  "Write INDEX to JSON at PATH."
  (let ((coding-system-for-write 'utf-8))
    (with-temp-file path
      (let ((json-encoding-pretty-print nil))
        (insert (json-encode (org-museum--index-to-alist index)))))))

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
      (org-museum--export-with-theme file out-file))
    (org-museum--delete-legacy-source-html file out-file)))
;; Fix-03: CSS mtime now included in staleness check.
(defun org-museum--needs-export-p (org-file html-file)
  "Return non-nil when export inputs are newer than HTML-FILE.
Checks (in order):
  1. HTML-FILE does not exist
  2. ORG-FILE mtime > HTML-FILE mtime
  3. [Fix-03] CSS output file mtime > HTML-FILE mtime
  4. org-museum.el mtime > HTML-FILE mtime
Applicable scope: org-museum-export-page, org-museum--count-stale-pages.
Known limitation: does not track every transitive template dependency."
  (or (not (file-exists-p html-file))
      (> (org-museum--file-mtime org-file) (org-museum--file-mtime html-file))
      (let ((css-out (org-museum--css-output-path)))
        (and (file-exists-p css-out)
             (> (org-museum--file-mtime css-out)
                (org-museum--file-mtime html-file))))
      (let ((exporter-file (or load-file-name (locate-library "org-museum"))))
        (and exporter-file
             (file-exists-p exporter-file)
             (> (org-museum--file-mtime exporter-file)
                (org-museum--file-mtime html-file))))))

(defconst org-museum--cjk-emphasis-before-chars
  '(#x3001 #x3002 #xff0c #xff1b #xff1a #xff01 #xff1f
    #xff09 #x3011 #x300b #x300d #x300f)
  "CJK punctuation that can appear before Org inline markup during export.")

(defconst org-museum--cjk-emphasis-after-chars
  '(#x3001 #x3002 #xff0c #xff1b #xff1a #xff01 #xff1f
    #xff09 #x3011 #x300b #x300d #x300f)
  "CJK punctuation that can appear after Org inline markup during export.")

(defun org-museum--parse-generic-emphasis-cjk (mark type)
  "Parse Org emphasis like `org-element--parse-generic-emphasis', with CJK punctuation.

Org's built-in parser only accepts ASCII punctuation around inline markup.
This makes tokens such as =ox-skills= followed by CJK punctuation stay plain
text.  Org Museum uses this parser only while exporting, so source buffers and
user Org settings remain untouched."
  (save-excursion
    (let ((origin (point)))
      (unless (bolp) (forward-char -1))
      (let ((opening-re
             (rx-to-string
              `(seq (or line-start
                        (any space ?- ?\( ?' ?\" ?\{
                             ,@org-museum--cjk-emphasis-before-chars))
                    ,mark
                    (not space)))))
        (when (looking-at-p opening-re)
          (goto-char (1+ origin))
          (let ((closing-re
                 (rx-to-string
                  `(seq
                    (not space)
                    (group ,mark)
                    (or (any space ?- ?. ?, ?\; ?: ?! ?? ?' ?\" ?\) ?\}
                             ?\\ ?\[
                             ,@org-museum--cjk-emphasis-after-chars)
                        line-end)))))
            (when (re-search-forward closing-re nil t)
              (let ((closing (match-end 1)))
                (goto-char closing)
                (let* ((post-blank (skip-chars-forward " \t"))
                       (contents-begin (1+ origin))
                       (contents-end (1- closing)))
                  (org-element-create
                   type
                   (append
                    (list :begin origin
                          :end (point)
                          :post-blank post-blank)
                    (if (memq type '(code verbatim))
                        (list :value
                              (org-element-deferred-create
                               t #'org-element--substring
                               (- contents-begin origin)
                               (- contents-end origin)))
                      (list :contents-begin contents-begin
                            :contents-end contents-end)))))))))))))

(defmacro org-museum--with-cjk-emphasis-export (&rest body)
  "Evaluate BODY with CJK punctuation accepted around Org inline markup."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'org-element--parse-generic-emphasis)
              #'org-museum--parse-generic-emphasis-cjk))
     ,@body))

(defun org-museum--export-with-theme (org-file out-file)
  "Export ORG-FILE to OUT-FILE with CSS, link-rewriting, and post-processing."
  (let ((tmp (make-temp-file "org-museum-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert-file-contents org-file)
            (org-mode)
            (org-museum--strip-drawers)
            (org-museum--rewrite-org-museum-links
             (current-buffer) out-file org-file)
            (goto-char (point-min))
            (insert (format "#+HTML_HEAD: %s\n#+HTML_HEAD: %s\n"
                            (org-museum--css-link-tag out-file)
                            org-museum--favicon-link-tag))
            (write-region (point-min) (point-max) tmp))
          (let ((export-buf (find-file-noselect tmp)))
            (unwind-protect
                (with-current-buffer export-buf
                  (let* ((use-htmlize-p (memq org-museum-code-highlight-method
                                              '(inline-css css-classes)))
                         (htmlize-type (pcase org-museum-code-highlight-method
                                        ('inline-css  'inline-css)
                                        ('css-classes 'css)
                                        (_            nil)))
                         (org-src-fontify-natively    use-htmlize-p)
                         (org-export-with-toc                 t)
                         (org-html-doctype                    "html5")
                         (org-html-head-include-default-style nil)
                         (org-html-preamble                   nil)
                         (org-html-postamble                  nil)
                         (org-export-with-broken-links        'mark)
                         (org-export-with-drawers             nil)
                         (org-export-with-properties          nil)
                         (org-export-with-sub-superscripts    nil)
                         (org-export-use-babel                nil)
                         (org-html-htmlize-output-type
                          (if (and use-htmlize-p
                                   (locate-library "htmlize"))
                              htmlize-type nil))
                         (coding-system-for-write             'utf-8))
                    (org-museum--with-cjk-emphasis-export
                      (org-export-to-file 'html out-file))))
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
    (org-museum--pp-inject-hljs-language-classes)
    (org-museum--pp-inject-page-attributes org-file)
    (org-museum--pp-annotate-local-file-links)
    (org-museum--pp-wrap-tables)
    (if (not (org-museum--pp-wrap-content-div out-file org-file))
        (progn
          (message "Org Museum [Export]: aborting post-processing for %s \
(#content div not found)" out-file)
          nil)
      (org-museum--pp-append-nav-and-graph out-file org-file)
      (org-museum--pp-inject-sidebars-and-scripts out-file)
      (write-region (point-min) (point-max) out-file)
      t)))

(defun org-museum--pp-wrap-tables ()
  "Wrap exported tables in an independently scrollable container."
  (goto-char (point-min))
  (while (re-search-forward "<table\\(?:[[:space:]][^>]*\\)?>" nil t)
    (let ((open-start (match-beginning 0)))
      (unless (save-excursion
                (goto-char open-start)
                (looking-back
                 "<div class=\"museum-table-scroll\">[[:space:]]*"
                 (max (point-min) (- open-start 80))))
        (goto-char open-start)
        (insert "<div class=\"museum-table-scroll\" tabindex=\"0\" "
                "role=\"region\" aria-label=\"可横向滚动的表格\">")
        (when (re-search-forward "</table>" nil t)
          (insert "</div>"))))))

(defun org-museum--page-for-file (org-file)
  "Return the indexed page matching ORG-FILE."
  (when org-museum--index
    (org-museum--find-page-by-path
     org-file (org-museum-index-pages org-museum--index))))

(defun org-museum--source-reading-minutes (org-file)
  "Estimate compact reading time for ORG-FILE."
  (if (not (file-readable-p org-file))
      1
    (with-temp-buffer
      (insert-file-contents org-file)
      (max 1 (ceiling (/ (float (buffer-size)) 500))))))

(defun org-museum--article-meta-html (page out-file org-file)
  "Return the article metadata rail for PAGE."
  (let* ((shared-root (org-museum--shared-root))
         (home-href (org-museum--relative-path
                     (expand-file-name "index.html" shared-root) out-file))
         (tags (org-museum-page-tags page)))
    (format
     (concat
      "<aside class=\"museum-article-meta\" aria-label=\"文章元数据\">\n"
      "  <a class=\"article-category\" href=\"%s?category=%s#recent-updates\">%s</a>%s\n"
      "  <dl>\n"
      "    <div><dt>修改日期</dt><dd><time datetime=\"%s\">%s</time></dd></div>\n"
      "    <div><dt>阅读时间</dt><dd>约 %d 分钟</dd></div>\n"
      "    <div><dt>标签</dt><dd>%s</dd></div>\n"
      "  </dl>\n"
      "  <nav class=\"article-back-nav\" aria-label=\"文章返回导航\">\n"
      "    <a href=\"%s#recent-updates\">← 全部笔记</a>\n"
      "    <a href=\"%s\">返回索引</a>\n"
      "  </nav>\n"
      "</aside>\n")
     (org-museum--html-escape home-href t)
     (url-hexify-string (org-museum-page-category page))
     (org-museum--html-escape
      (org-museum--category-label (org-museum-page-category page)))
     (if (org-museum--published-page-p page)
         ""
       "<span class=\"museum-status-badge\">草稿</span>")
     (org-museum--format-page-date page)
     (org-museum--format-page-date page)
     (org-museum--source-reading-minutes org-file)
     (if tags
         (mapconcat #'org-museum--html-escape tags " · ")
       "—")
     (org-museum--html-escape home-href t)
     (org-museum--html-escape home-href t))))

(defun org-museum--article-identity-html (page out-file)
  "Return the compact sticky identity bar for PAGE relative to OUT-FILE."
  (let* ((home-href (org-museum--relative-path
                     (expand-file-name "index.html" (org-museum--shared-root))
                     out-file))
         (status (downcase (or (org-museum-page-status page) "published"))))
    (format
     (concat
      "<div id=\"museum-article-identity\" class=\"museum-article-identity\" hidden>"
      "<a href=\"%s\" class=\"museum-identity-title\">%s</a>"
      "<span class=\"museum-identity-meta\">%s%s</span>"
      "<span class=\"museum-identity-divider\" aria-hidden=\"true\">·</span>"
      "<span class=\"museum-identity-section\" data-current-section "
      "aria-live=\"polite\">文章开头</span></div>\n")
     (org-museum--html-escape home-href t)
     (org-museum--html-escape (org-museum-page-title page))
     (org-museum--html-escape
      (org-museum--category-label (org-museum-page-category page)))
     (if (string= status "draft") " · 草稿" ""))))

(defun org-museum--pp-inject-page-attributes (org-file)
  "Add stable page metadata attributes to the current HTML buffer."
  (when-let ((page (org-museum--page-for-file org-file)))
    (goto-char (point-min))
    (when (re-search-forward "<body\\([^>]*\\)>" nil t)
      (let ((existing (match-string 1)))
        (replace-match
         (format
          (concat "<body%s class=\"org-museum-page\" data-page-kind=\"article\" "
                  "data-page-id=\"%s\" data-page-title=\"%s\" "
                  "data-page-category=\"%s\" data-page-tags=\"%s\" "
                  "data-page-status=\"%s\" data-page-modified=\"%s\">")
          existing
          (org-museum--html-escape (org-museum-page-id page) t)
          (org-museum--html-escape (org-museum-page-title page) t)
          (org-museum--html-escape (org-museum-page-category page) t)
          (org-museum--html-escape
           (mapconcat #'identity (org-museum-page-tags page) ",") t)
          (org-museum--html-escape
           (downcase (or (org-museum-page-status page) "published")) t)
          (org-museum--format-page-date page))
         t t)))))

(defun org-museum--pp-remove-inline-styles ()
  "Conditionally strip <style>…</style> blocks from current buffer.
In 'hljs mode, removes all Org-generated <style> blocks to keep the HTML
clean (hljs handles highlighting via its own CSS).  In 'inline-css and
'css-classes modes, the <style> blocks are preserved because they contain
the htmlize colour definitions that make code highlighting work."
  (when (eq org-museum-code-highlight-method 'hljs)
    (goto-char (point-min))
    (while (re-search-forward "<style[^>]*>" nil t)
      (let ((beg (match-beginning 0)))
        (when (re-search-forward "</style>" nil t)
          (delete-region beg (point)))))))

(defun org-museum--hljs-language-for-org (lang)
  "Return Highlight.js language name for Org source language LANG."
  (let ((name (downcase (or lang ""))))
    (pcase name
      ((or "emacs-lisp" "elisp" "lisp-data") "lisp")
      ((or "sh" "shell" "bash" "zsh") "bash")
      ((or "duckdb" "sqlite" "postgres" "postgresql") "sql")
      ("js" "javascript")
      ("ts" "typescript")
      ("py" "python")
      ((or "example" "text") "plaintext")
      (_ name))))

(defun org-museum--html-attr-value (tag attr)
  "Return ATTR value from HTML TAG, or nil when absent."
  (when (string-match
         (format "\\b%s=[\"']\\([^\"']+\\)[\"']" (regexp-quote attr))
         tag)
    (match-string 1 tag)))

(defun org-museum--html-tag-add-class (tag class)
  "Return HTML TAG with CLASS appended to its class attribute."
  (let ((existing (org-museum--html-attr-value tag "class")))
    (cond
     ((and existing (member class (split-string existing " " t)))
      tag)
     (existing
      (replace-regexp-in-string
       "\\bclass=\\([\"']\\)\\([^\"']*\\)\\1"
       (lambda (_)
         (format "class=\"%s %s\"" existing class))
       tag t t))
     (t
      (replace-regexp-in-string
       "\\s-*/?>\\'"
       (lambda (end)
         (concat " class=\"" class "\"" end))
       tag t t)))))

(defun org-museum--pp-inject-hljs-language-classes ()
  "Rewrite Org src blocks to add hljs-compatible language class attributes.
Org exports code blocks as:
  <pre class=\"src src-sql\"><code>...</code></pre>
but Highlight.js requires:
  <pre class=\"src src-sql\"><code class=\"language-sql\">...</code></pre>
This function adds the missing language-xxx class to <code> elements inside
src blocks, enabling reliable hljs auto-detection.
Only runs when `org-museum-code-highlight-method' is 'hljs."
  (when (eq org-museum-code-highlight-method 'hljs)
    (goto-char (point-min))
    (while (re-search-forward "<pre\\b[^>]*>" nil t)
      (let* ((pre-end-pos (match-end 0))
             (pre-tag (match-string 0))
             (pre-class (or (org-museum--html-attr-value pre-tag "class") ""))
             (org-lang
              (cond
               ((string-match "\\bsrc-\\([^[:space:]]+\\)" pre-class)
                (match-string 1 pre-class))
               ((member "example" (split-string pre-class " " t))
                "plaintext")))
             (hljs-lang (and org-lang
                             (org-museum--hljs-language-for-org org-lang)))
             (pre-close (save-excursion
                          (when (re-search-forward "</pre>" nil t)
                            (match-beginning 0)))))
        (when (and hljs-lang pre-close)
          (save-excursion
            (goto-char pre-end-pos)
            (if (re-search-forward "<code\\b[^>]*>" pre-close t)
                (replace-match
                 (org-museum--html-tag-add-class
                  (match-string 0)
                  (concat "language-" hljs-lang))
                 t t)
              (goto-char pre-close)
              (insert "</code>")
              (goto-char pre-end-pos)
              (insert (format "<code class=\"language-%s\">" hljs-lang)))))))))

;; Fix-05: now returns t on success, nil on failure.
(defun org-museum--pp-wrap-content-div (out-file org-file)
  "Wrap #content with scroll/article containers in current buffer.
Returns t on success, nil when #content is not found.
[Fix-05] Callers must check the return value and short-circuit on nil.
Applicable scope: org-museum--postprocess-html."
  (goto-char (point-min))
  (if (re-search-forward "<div id=\"content\"[^>]*>" nil t)
      (let* ((page (org-museum--page-for-file org-file))
             (meta (if page
                       (org-museum--article-meta-html page out-file org-file)
                     "<aside class=\"museum-article-meta\"></aside>\n"))
             (identity (if page
                           (org-museum--article-identity-html page out-file)
                         ""))
             (article-attrs
              (if page
                  (format
                   (concat " data-page-id=\"%s\" data-page-title=\"%s\" "
                           "data-page-category=\"%s\"")
                   (org-museum--html-escape (org-museum-page-id page) t)
                   (org-museum--html-escape (org-museum-page-title page) t)
                   (org-museum--html-escape (org-museum-page-category page) t))
                "")))
        (replace-match
         (concat
          "<main id=\"main-scroll\">" identity
          "<div id=\"content\" class=\"museum-article-layout\">"
          meta
          "<article class=\"article-container\"" article-attrs ">")
         t t)
        t)
    (message "Org Museum [PostProcess]: #content not found in %s — \
check org-export output for this file" out-file)
    nil))

(defun org-museum--toc-sidebar-html ()
  "Return the shared searchable article TOC sidebar markup."
  (concat
   "<aside id=\"org-museum-right-sidebar\" aria-label=\"本文目录\">"
   "<div class=\"toc-sidebar-header\"><h4>本文目录</h4>"
   "<span data-toc-count role=\"status\" aria-live=\"polite\">/ 00</span>"
   "<button type=\"button\" data-toc-close aria-label=\"关闭本文目录\">关闭</button></div>"
   "<div class=\"toc-search-tools\"><label class=\"toc-search\">"
   "<span class=\"sr-only\">搜索目录</span>"
   "<input type=\"search\" data-toc-search placeholder=\"搜索目录…\" "
   "aria-label=\"搜索目录\"></label>"
   "<button type=\"button\" data-toc-clear hidden>清除</button></div>"
   "<p class=\"toc-empty\" data-toc-empty hidden>没有匹配的章节。</p>"
   "</aside>\n"))

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
                       (org-museum--generate-local-graph-html page out-file)))
         (appended  (concat (or nav-html "") (or graph-html ""))))
    (goto-char (point-max))
    (cond
     ((re-search-backward "</div>\\([\n\r\t ]*\\)</body>" nil t)
      (replace-match
       (concat
        appended
        "\n</article>\n"
        (org-museum--toc-sidebar-html)
        "</div></main>\\1</body>")))
     (t
      (when (re-search-backward "</div>" nil t)
        (replace-match
         (concat
          appended "\n</article>" (org-museum--toc-sidebar-html)
          "</div></main>")))))))

(defun org-museum--pp-inject-sidebars-and-scripts (out-file)
  "Inject sidebar, TOC, and script HTML before </body>."
  (goto-char (point-min))
  (when (re-search-forward "<body[^>]*>" nil t)
    (insert "\n" (org-museum--build-topbar out-file 'article)))
  (goto-char (point-max))
  (when (re-search-backward "</body>" nil t)
    (insert (org-museum--build-sidebar-injection out-file))
    (insert "\n")))

;; ============================================================
;; §13  PROJECT EXPORT
;; ============================================================

(defun org-museum--export-manifest-path ()
  "Return the absolute full-export manifest path."
  (expand-file-name ".org-museum-manifest.json" (org-museum--shared-root)))

(defun org-museum--expected-page-html-files ()
  "Return absolute HTML files expected by the current non-empty index."
  (unless (and org-museum--index
               (> (hash-table-count
                   (org-museum-index-pages org-museum--index)) 0))
    (user-error "Org Museum refuses stale cleanup with an empty index"))
  (let (files)
    (maphash
     (lambda (_id page)
       (push (expand-file-name
              (org-museum--export-filename (org-museum-page-path page)))
             files))
     (org-museum-index-pages org-museum--index))
    (sort files #'string<)))

(defun org-museum--safe-page-html-p (file pages-root)
  "Return non-nil when FILE is a deletable page HTML below PAGES-ROOT."
  (and (file-exists-p file)
       (file-regular-p file)
       (not (file-symlink-p file))
       (string= (downcase (or (file-name-extension file) "")) "html")
       (file-in-directory-p (file-truename file)
                            (file-name-as-directory
                             (file-truename pages-root)))))

(defun org-museum--validated-cleanup-pages-root ()
  "Return a cleanup-safe pages root or signal `user-error'."
  (let* ((project-root (file-name-as-directory
                        (file-truename (expand-file-name
                                        org-museum-root-dir))))
         (pages-root (expand-file-name (org-museum--pages-root)))
         (existing-parent
          (if (file-exists-p pages-root)
              pages-root
            (file-name-directory (directory-file-name pages-root)))))
    (unless (and existing-parent (file-exists-p existing-parent))
      (user-error "Org Museum cleanup pages root has no existing parent"))
    (when (file-symlink-p pages-root)
      (user-error "Org Museum refuses cleanup through a symlinked pages root"))
    (unless (file-in-directory-p
             (file-truename existing-parent) project-root)
      (user-error "Org Museum refuses cleanup outside the museum root"))
    pages-root))

;;;###autoload
(defun org-museum-preview-stale-exports ()
  "Return stale page HTML files without modifying the export directory.
When called interactively, display the exact files that a successful full
export would remove."
  (interactive)
  (let* ((pages-root (org-museum--validated-cleanup-pages-root))
         (expected (org-museum--expected-page-html-files))
         (expected-table (make-hash-table :test 'equal))
         stale)
    (dolist (file expected)
      (puthash (downcase (expand-file-name file)) t expected-table))
    (when (file-directory-p pages-root)
      (dolist (file (directory-files-recursively pages-root "\\.html\\'" nil))
        (when (and (org-museum--safe-page-html-p file pages-root)
                   (not (gethash (downcase (expand-file-name file))
                                 expected-table)))
          (push (expand-file-name file) stale))))
    (setq stale (sort stale #'string<))
    (when (called-interactively-p 'interactive)
      (with-current-buffer (get-buffer-create "*Org Museum Stale Exports*")
        (erase-buffer)
        (insert (format "* Stale exports preview (%d)\n\n" (length stale)))
        (if stale
            (dolist (file stale) (insert "- " file "\n"))
          (insert "No stale page HTML files.\n"))
        (goto-char (point-min))
        (display-buffer (current-buffer))))
    stale))

(defun org-museum--write-export-manifest ()
  "Write the current expected page set to the full-export manifest."
  (let* ((pages-root (file-name-as-directory
                      (expand-file-name (org-museum--pages-root))))
         (files (org-museum--expected-page-html-files))
         (relative
          (mapcar
           (lambda (file)
             (replace-regexp-in-string
              "\\\\" "/" (file-relative-name file pages-root)))
           files))
         (manifest (org-museum--export-manifest-path))
         (coding-system-for-write 'utf-8))
    (make-directory (file-name-directory manifest) t)
    (with-temp-file manifest
      (insert
       (org-museum--json-for-html
        `((schemaVersion . 1)
          (generatedAt . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
          (pagesRoot . ,(replace-regexp-in-string "\\\\" "/" pages-root))
          (pages . ,(vconcat relative))))))
    manifest))

(defun org-museum--clean-stale-exports ()
  "Delete safely previewed stale page HTML and return the deletion count."
  (let ((stale (org-museum-preview-stale-exports))
        (deleted 0))
    (dolist (file stale)
      (when (org-museum--safe-page-html-p file (org-museum--pages-root))
        (delete-file file)
        (cl-incf deleted)))
    (message "Org Museum stale cleanup: %d page HTML file%s deleted"
             deleted (if (= deleted 1) "" "s"))
    deleted))

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
    (let ((graph-file (org-museum-export-graph :silent t))
          (cleaned 0))
      (when (and (null failed) (= success total) (> total 0))
        (org-museum--write-export-manifest)
        (when org-museum-clean-stale-html-on-full-export
          (setq cleaned (org-museum--clean-stale-exports))))
      (message "Export complete: %d/%d pages, %d failed"
               success total (length failed))
      (when (> cleaned 0)
        (message "Org Museum removed %d stale page HTML files" cleaned))
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

(defun org-museum--build-index-html-legacy (cats graph-href out-file)
  "Return full index.html string for CATS, with GRAPH-HREF link."
  (concat
   "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n"
   "  <meta charset=\"utf-8\">\n"
   "  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
   "  <title>Org Museum</title>\n"
   (format "  %s\n" (org-museum--css-link-tag out-file))
   (format "  %s\n" org-museum--favicon-link-tag)
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

(defun org-museum--build-topbar (out-file &optional kind)
  "Return the shared top navigation for OUT-FILE.
KIND is one of `home', `article', or `graph'."
  (let* ((shared-root (org-museum--shared-root))
         (home-href (org-museum--relative-path
                     (expand-file-name "index.html" shared-root) out-file))
         (graph-href (org-museum--relative-path
                      (expand-file-name "graph.html" shared-root) out-file))
         (placeholder (pcase kind
                        ('article "搜索此 Wiki…")
                        ('graph "搜索节点…")
                        (_ "搜索标题、分类或标签…"))))
    (format
     (concat
      "<header class=\"museum-topbar\" data-home-href=\"%s\">\n"
      "  <a class=\"museum-wordmark\" href=\"%s\">ORG MUSEUM</a>\n"
      "  <time class=\"museum-today\" datetime=\"%s\" title=\"导出于 %s\" aria-label=\"导出于 %s\">%s</time>\n"
      "  <label class=\"museum-search-line\" for=\"org-museum-global-search\">\n"
      "    <span class=\"sr-only\">全局搜索</span>\n"
      "    <input id=\"org-museum-global-search\" type=\"search\" "
      "placeholder=\"%s\" autocomplete=\"off\" spellcheck=\"false\" "
      "aria-label=\"全局搜索\" aria-keyshortcuts=\"/\">\n"
      "    <kbd aria-hidden=\"true\">/</kbd>\n"
      "  </label>\n"
      "  <nav class=\"museum-top-links\" aria-label=\"Wiki 导航\">\n"
      "    <a href=\"%s\"%s>%s</a>\n"
      "    <a href=\"%s\">%s</a>\n"
      "  </nav>\n"
      "</header>\n")
     (org-museum--html-escape home-href t)
     (org-museum--html-escape home-href t)
     (format-time-string "%Y-%m-%d")
     (format-time-string "%Y.%m.%d")
     (format-time-string "%Y年%m月%d日")
     (format-time-string "%Y.%m.%d")
     placeholder
     (if (eq kind 'home) "#recent-updates"
       (org-museum--html-escape home-href t))
     (if (eq kind 'home) " data-index-reset" "")
     (if (eq kind 'home) "全部笔记" "首页")
     (if (eq kind 'graph)
         (concat (org-museum--html-escape home-href t) "#recent-updates")
       (org-museum--html-escape graph-href t))
     (if (eq kind 'graph) "全部笔记" "知识图谱"))))

(defun org-museum--build-topic-index-html (cats)
  "Return topic index controls for CATS."
  (if (null cats)
      "<p class=\"museum-empty-copy\">当前还没有可展示的主题。</p>\n"
    (mapconcat
     (lambda (entry)
       (format
        (concat "<button type=\"button\" class=\"topic-filter\" "
                "data-category=\"%s\" aria-pressed=\"false\"><span>%s</span><strong>%02d</strong></button>")
        (org-museum--html-escape (car entry) t)
        (org-museum--html-escape (org-museum--category-label (car entry)))
        (length (cdr entry))))
     cats "\n")))

(defun org-museum--build-index-entry-html (page out-file index)
  "Return one recent index entry for PAGE relative to OUT-FILE at INDEX."
  (format
   (concat
    "<article class=\"museum-index-entry\" data-page-id=\"%s\" "
    "data-category=\"%s\" data-status=\"%s\">\n"
    "  <div class=\"museum-entry-meta\"><span>%02d</span><time datetime=\"%s\">%s</time></div>\n"
    "  <h3><a href=\"%s\">%s</a>%s</h3>\n"
    "  <a class=\"museum-entry-category\" href=\"?category=%s#recent-updates\" "
    "data-category-link=\"%s\" aria-pressed=\"false\">%s</a>\n"
   "</article>\n")
   (org-museum--html-escape (org-museum-page-id page) t)
   (org-museum--html-escape (org-museum-page-category page) t)
   (org-museum--html-escape
    (downcase (or (org-museum-page-status page) "published")) t)
   index
   (org-museum--format-page-date page)
   (org-museum--format-page-date page)
   (org-museum--html-escape
    (org-museum--page-href (org-museum-page-id page) out-file) t)
   (org-museum--html-escape (org-museum-page-title page))
   (if (org-museum--published-page-p page)
       ""
     "<span class=\"museum-status-badge\">草稿</span>")
   (url-hexify-string (org-museum-page-category page))
   (org-museum--html-escape (org-museum-page-category page) t)
   (org-museum--html-escape
    (org-museum--category-label (org-museum-page-category page)))))

(defun org-museum--script-index-legacy ()
  "Return schema-v2 homepage search, filters, and continuation behavior."
  "<script>
(function(){
'use strict';
var dataEl=document.getElementById('org-museum-index-data');
var data={schemaVersion:2,pages:[]};
try{data=JSON.parse(dataEl?dataEl.textContent:'{\"pages\":[]}');}catch(_error){}
var pages=Array.isArray(data.pages)?data.pages:[];
var search=document.getElementById('org-museum-global-search');
var results=document.getElementById('index-search-results');
var resultList=document.getElementById('index-search-list');
var recent=document.getElementById('recent-updates');
var resume=document.getElementById('continue-reading');
var resumeList=document.getElementById('continue-reading-list');
var resumeCount=document.getElementById('continue-reading-count');
var statusFilter='all';
var collator=new Intl.Collator('zh-CN',{sensitivity:'base'});
function count(value){return String(value).padStart(2,'0');}
function allowed(page){return statusFilter==='all'||page.status===statusFilter;}
function pageHaystack(page){
  return [page.title,page.category,page.categoryLabel].concat(page.tags||[])
    .concat((page.headings||[]).map(function(heading){return heading.title;}))
    .join(' ').toLowerCase();
}
function bestMatch(page,q){
  if((page.title||'').toLowerCase().indexOf(q)>=0)
    return {page:page,score:100,href:page.href,context:''};
  var heading=(page.headings||[]).find(function(item){
    return (item.title||'').toLowerCase().indexOf(q)>=0;
  });
  if(heading)return {page:page,score:80,
    href:page.href.split('#')[0]+'#'+encodeURIComponent(heading.id),
    context:'章节 · '+heading.title};
  return {page:page,score:40,href:page.href,context:''};
}
function makeResult(item){
  var page=item.page||item;
  var row=document.createElement('a');
  row.className='museum-search-result';row.href=item.href||page.href;
  var title=document.createElement('span');title.textContent=page.title;
  var meta=document.createElement('small');
  meta.textContent=(item.context?item.context+' · ':'')+
    (page.modifiedDate||'')+' · '+(page.categoryLabel||page.category||'未分类')+
    (page.status==='draft'?' · 草稿':'');
  row.appendChild(title);row.appendChild(meta);return row;
}
function showPages(matched,label){
  if(!results||!resultList)return;
  resultList.textContent='';
  var heading=results.querySelector('h2 span');
  if(heading)heading.textContent=label;
  matched.forEach(function(item){resultList.appendChild(makeResult(item));});
  var empty=results.querySelector('.museum-search-empty');
  if(empty)empty.hidden=matched.length>0;
  results.hidden=false;if(recent)recent.hidden=true;
}
function clearResults(){if(results)results.hidden=true;if(recent)recent.hidden=false;}
function runSearch(raw){
  var q=(raw||'').trim().toLowerCase();
  if(!q){clearResults();return;}
  var matched=pages.filter(function(page){return allowed(page)&&pageHaystack(page).indexOf(q)>=0;})
    .map(function(page){return bestMatch(page,q);})
    .sort(function(a,b){return b.score-a.score||
      (b.page.modified||0)-(a.page.modified||0)||
      collator.compare(a.page.title,b.page.title);});
  showPages(matched,'搜索结果 / '+count(matched.length));
}
if(search){
  search.addEventListener('input',function(){runSearch(search.value);});
  search.addEventListener('keydown',function(event){
    if(event.key==='Escape'){search.value='';clearResults();search.blur();}
  });
}
document.addEventListener('keydown',function(event){
  if(event.key==='/'&&!event.metaKey&&!event.ctrlKey&&!event.altKey&&
     !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)){
    event.preventDefault();if(search)search.focus();
  }
});
document.querySelectorAll('[data-category],[data-category-link]').forEach(function(control){
  control.addEventListener('click',function(event){
    event.preventDefault();
    var category=control.getAttribute('data-category')||
                 control.getAttribute('data-category-link');
    var matched=pages.filter(function(page){return allowed(page)&&page.category===category;})
      .sort(function(a,b){return (b.modified||0)-(a.modified||0);});
    showPages(matched,(matched[0]?(matched[0].categoryLabel||category):category)+' / '+count(matched.length));
  });
});
document.querySelectorAll('[data-status-filter]').forEach(function(control){
  control.addEventListener('click',function(){
    statusFilter=control.dataset.statusFilter;
    document.querySelectorAll('[data-status-filter]').forEach(function(button){
      var active=button===control;
      button.classList.toggle('is-active',active);
      button.setAttribute('aria-pressed',active?'true':'false');
    });
    document.querySelectorAll('.museum-index-entry').forEach(function(entry){
      entry.hidden=statusFilter!=='all'&&entry.dataset.status!==statusFilter;
    });
    if(search&&search.value.trim())runSearch(search.value);
  });
});
function openReadingDb(){
  return new Promise(function(resolve,reject){
    if(!window.indexedDB){reject(new Error('IndexedDB unavailable'));return;}
    var request=indexedDB.open('org-museum',1);
    request.onupgradeneeded=function(){
      var db=request.result;
      var store=db.objectStoreNames.contains('readingState')
        ?request.transaction.objectStore('readingState')
        :db.createObjectStore('readingState',{keyPath:'pageId'});
      if(!store.indexNames.contains('lastVisitedAt'))
        store.createIndex('lastVisitedAt','lastVisitedAt',{unique:false});
    };
    request.onsuccess=function(){resolve(request.result);};
    request.onerror=function(){reject(request.error||new Error('IndexedDB failed'));};
    request.onblocked=function(){reject(new Error('IndexedDB blocked'));};
  });
}
function loadRecentRecords(db){
  return new Promise(function(resolve,reject){
    var records=[];
    var tx=db.transaction('readingState','readwrite');
    var store=tx.objectStore('readingState');
    var request=store.index('lastVisitedAt').openCursor(null,'prev');
    request.onsuccess=function(){
      var cursor=request.result;
      if(!cursor){resolve(records);return;}
      var record=cursor.value;
      var page=pages.find(function(item){return item.pageId===record.pageId;});
      var progress=Number(record.progress||record.scrollRatio||0);
      var qualified=Boolean(record.qualifiedAt)||
        Number(record.engagedMs||0)>=30000||progress>=0.03;
      if(!page||!qualified)cursor.delete();
      else if(records.length<6){
        record.href=page.href;record.title=page.title;
        record.category=page.categoryLabel||page.category;
        if(record.lastHeadingId&&!(page.headings||[]).some(function(heading){
          return heading.id===record.lastHeadingId;
        }))record.lastHeadingId='';
        records.push(record);
      }
      cursor.continue();
    };
    request.onerror=function(){reject(request.error);};
  });
}
function resumeHref(record){
  var href=record.href||record.url||'#';
  if(record.lastHeadingId)href=href.split('#')[0]+'#'+encodeURIComponent(record.lastHeadingId);
  return href;
}
function renderResume(records){
  if(!resume||!resumeList)return;
  resumeList.textContent='';
  if(resumeCount)resumeCount.textContent='/ '+count(records.length);
  if(!records.length){
    var empty=document.createElement('div');empty.className='resume-empty-state';
    var title=document.createElement('strong');title.textContent='还没有有效阅读轨迹';
    var copy=document.createElement('small');
    copy.textContent='停留 30 秒或阅读超过 3% 后，才会保存最近位置。';
    empty.appendChild(title);empty.appendChild(copy);
    if(pages.length){var start=document.createElement('a');
      start.href=pages.slice().sort(function(a,b){return (b.modified||0)-(a.modified||0);})[0].href;
      start.textContent='从最近更新开始 →';empty.appendChild(start);}
    resumeList.appendChild(empty);resume.hidden=false;return;
  }
  records.forEach(function(record,index){
    var link=document.createElement('a');
    link.className='resume-record'+(index===0?' resume-record-primary':'');
    link.href=resumeHref(record);
    var number=document.createElement('span');number.className='resume-number';number.textContent=count(index+1);
    var body=document.createElement('span');body.className='resume-copy';
    var title=document.createElement('strong');title.textContent=record.title||record.pageId;
    var detail=document.createElement('small');
    detail.textContent=(record.lastHeadingTitle||'上次阅读位置')+' · '+
      Math.round((record.progress||record.scrollRatio||0)*100)+'%';
    body.appendChild(title);body.appendChild(detail);
    var meter=document.createElement('span');meter.className='resume-meter';
    var fill=document.createElement('i');
    fill.style.width=Math.round((record.progress||record.scrollRatio||0)*100)+'%';
    meter.appendChild(fill);link.appendChild(number);link.appendChild(body);link.appendChild(meter);
    resumeList.appendChild(link);
  });
  resume.hidden=false;
}
openReadingDb().then(function(db){
  return loadRecentRecords(db).finally(function(){db.close();});
}).then(renderResume).catch(function(){if(resume)resume.hidden=true;});
var params=new URLSearchParams(location.search);
if(params.has('q')&&search){search.value=params.get('q');runSearch(search.value);}
})();
</script>\n")

(defun org-museum--script-index ()
  "Return schema-v2 homepage behavior with one URL-backed filter state."
  "<script>
(function(){
'use strict';
var dataEl=document.getElementById('org-museum-index-data');
var data={schemaVersion:2,pages:[]};
try{data=JSON.parse(dataEl?dataEl.textContent:'{\"pages\":[]}');}catch(_error){}
var pages=Array.isArray(data.pages)?data.pages:[];
var search=document.getElementById('org-museum-global-search');
var matrix=document.querySelector('.museum-index-matrix');
var entries=Array.from(document.querySelectorAll('.museum-index-entry'));
var resultList=document.getElementById('index-search-list');
var empty=document.getElementById('index-search-empty');
var heading=document.getElementById('index-results-heading');
var visibleCount=document.getElementById('index-visible-count');
var summary=document.getElementById('index-filter-summary');
var summaryText=document.getElementById('index-filter-summary-text');
var clearButton=document.querySelector('[data-clear-index-filters]');
var live=document.getElementById('index-results-live');
var resetLink=document.querySelector('[data-index-reset]');
var resume=document.getElementById('continue-reading');
var resumeList=document.getElementById('continue-reading-list');
var resumeCount=document.getElementById('continue-reading-count');
var state={query:'',category:'',status:'all'};
var collator=new Intl.Collator('zh-CN',{sensitivity:'base'});
function count(value){return String(value).padStart(2,'0');}
function categoryLabel(value){
  var page=pages.find(function(item){return item.category===value;});
  return page?(page.categoryLabel||page.category):value;
}
function pageHaystack(page){
  return [page.title,page.category,page.categoryLabel].concat(page.tags||[])
    .concat((page.headings||[]).map(function(item){return item.title;}))
    .join(' ').toLowerCase();
}
function bestMatch(page,q){
  if(!q)return {page:page,score:40,href:page.href,context:''};
  if((page.title||'').toLowerCase().indexOf(q)>=0)
    return {page:page,score:100,href:page.href,context:''};
  var headingMatch=(page.headings||[]).find(function(item){
    return (item.title||'').toLowerCase().indexOf(q)>=0;
  });
  if(headingMatch)return {page:page,score:80,
    href:page.href.split('#')[0]+'#'+encodeURIComponent(headingMatch.id),
    context:'章节 · '+headingMatch.title};
  return {page:page,score:40,href:page.href,context:''};
}
function matches(page){
  var statusOk=state.status==='all'||page.status===state.status;
  var categoryOk=!state.category||page.category===state.category;
  var query=state.query.trim().toLowerCase();
  return statusOk&&categoryOk&&(!query||pageHaystack(page).indexOf(query)>=0);
}
function makeResult(item){
  var page=item.page;
  var row=document.createElement('a');row.className='museum-search-result';row.href=item.href;
  var title=document.createElement('span');title.textContent=page.title;
  var meta=document.createElement('small');
  meta.textContent=(item.context?item.context+' · ':'')+(page.modifiedDate||'')+' · '+
    (page.categoryLabel||page.category||'未分类')+(page.status==='draft'?' · 草稿':'');
  row.appendChild(title);row.appendChild(meta);return row;
}
function readUrl(){
  var params=new URLSearchParams(location.search);
  state.query=params.get('q')||'';
  state.category=params.get('category')||'';
  var status=params.get('status')||'all';
  state.status=['published','draft'].indexOf(status)>=0?status:'all';
}
function writeUrl(mode){
  var url=new URL(location.href);
  ['q','category','status'].forEach(function(key){url.searchParams.delete(key);});
  if(state.query)url.searchParams.set('q',state.query);
  if(state.category)url.searchParams.set('category',state.category);
  if(state.status!=='all')url.searchParams.set('status',state.status);
  if(mode==='push')history.pushState({},'',url.pathname+url.search+url.hash);
  else history.replaceState({},'',url.pathname+url.search+url.hash);
}
function syncControls(){
  if(search&&search.value!==state.query)search.value=state.query;
  document.querySelectorAll('[data-status-filter]').forEach(function(button){
    var active=button.dataset.statusFilter===state.status;
    button.classList.toggle('is-active',active);
    button.setAttribute('aria-pressed',active?'true':'false');
  });
  document.querySelectorAll('[data-category],[data-category-link]').forEach(function(control){
    var value=control.getAttribute('data-category')||control.getAttribute('data-category-link');
    var active=Boolean(state.category)&&value===state.category;
    control.classList.toggle('is-active',active);
    control.setAttribute('aria-pressed',active?'true':'false');
  });
}
function updateSummary(){
  var tokens=[];
  if(state.query)tokens.push('搜索 “'+state.query+'”');
  if(state.category)tokens.push('主题 '+categoryLabel(state.category));
  if(state.status==='published')tokens.push('已发布');
  if(state.status==='draft')tokens.push('草稿');
  if(summaryText)summaryText.textContent=tokens.join(' · ');
  if(summary)summary.hidden=tokens.length===0;
}
function applyState(options){
  options=options||{};syncControls();updateSummary();
  var query=state.query.trim().toLowerCase();
  var matched=pages.filter(matches).map(function(page){return bestMatch(page,query);})
    .sort(function(a,b){return b.score-a.score||
      (b.page.modified||0)-(a.page.modified||0)||
      collator.compare(a.page.title,b.page.title);});
  var listMode=Boolean(query||state.category);
  if(matrix){
    matrix.hidden=listMode;
    if(!listMode)entries.forEach(function(entry){
      entry.hidden=state.status!=='all'&&entry.dataset.status!==state.status;
    });
  }
  if(resultList){
    resultList.textContent='';resultList.hidden=!listMode;
    if(listMode)matched.forEach(function(item){resultList.appendChild(makeResult(item));});
  }
  if(empty)empty.hidden=matched.length>0;
  var label='全部笔记 · 按更新时间';
  if(state.category)label=categoryLabel(state.category)+' · 主题笔记';
  else if(query)label='搜索结果';
  else if(state.status==='published')label='已发布 · 按更新时间';
  else if(state.status==='draft')label='草稿 · 按更新时间';
  if(heading)heading.textContent=label;
  if(visibleCount)visibleCount.textContent='/ '+count(matched.length);
  if(live)live.textContent='显示 '+matched.length+' 篇笔记';
  if(options.focus&&heading)requestAnimationFrame(function(){heading.focus();});
}
function update(patch,historyMode,focus){
  Object.keys(patch).forEach(function(key){state[key]=patch[key];});
  writeUrl(historyMode||'push');applyState({focus:Boolean(focus)});
}
if(search){
  search.addEventListener('input',function(){
    update({query:search.value},'replace',false);
  });
  search.addEventListener('keydown',function(event){
    if(event.key==='Escape'){
      event.preventDefault();update({query:''},'replace',false);search.blur();
    }
  });
}
document.addEventListener('keydown',function(event){
  if(event.key==='/'&&!event.metaKey&&!event.ctrlKey&&!event.altKey&&
     !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)){
    event.preventDefault();if(search)search.focus();
  }
});
document.querySelectorAll('[data-category],[data-category-link]').forEach(function(control){
  control.addEventListener('click',function(event){
    event.preventDefault();var value=control.getAttribute('data-category')||
      control.getAttribute('data-category-link');
    update({category:state.category===value?'':value},'push',true);
  });
});
document.querySelectorAll('[data-status-filter]').forEach(function(control){
  control.addEventListener('click',function(){
    update({status:control.dataset.statusFilter||'all'},'push',true);
  });
});
if(clearButton)clearButton.addEventListener('click',function(){
  update({query:'',category:'',status:'all'},'push',true);
});
if(resetLink)resetLink.addEventListener('click',function(event){
  event.preventDefault();update({query:'',category:'',status:'all'},'push',false);
  var target=document.getElementById('recent-updates');if(target)target.scrollIntoView({block:'start'});
});
window.addEventListener('popstate',function(){readUrl();applyState();});
function openReadingDb(){
  return new Promise(function(resolve,reject){
    if(!window.indexedDB){reject(new Error('IndexedDB unavailable'));return;}
    var request=indexedDB.open('org-museum',1);
    request.onupgradeneeded=function(){
      var db=request.result;
      var store=db.objectStoreNames.contains('readingState')
        ?request.transaction.objectStore('readingState')
        :db.createObjectStore('readingState',{keyPath:'pageId'});
      if(!store.indexNames.contains('lastVisitedAt'))
        store.createIndex('lastVisitedAt','lastVisitedAt',{unique:false});
    };
    request.onsuccess=function(){resolve(request.result);};
    request.onerror=function(){reject(request.error||new Error('IndexedDB failed'));};
    request.onblocked=function(){reject(new Error('IndexedDB blocked'));};
  });
}
function loadRecentRecords(db){
  return new Promise(function(resolve,reject){
    var records=[];var tx=db.transaction('readingState','readwrite');
    var store=tx.objectStore('readingState');
    var request=store.index('lastVisitedAt').openCursor(null,'prev');
    request.onsuccess=function(){
      var cursor=request.result;if(!cursor){resolve(records);return;}
      var record=cursor.value;
      var page=pages.find(function(item){return item.pageId===record.pageId;});
      var progress=Number(record.progress||record.scrollRatio||0);
      var qualified=Boolean(record.qualifiedAt)||Number(record.engagedMs||0)>=30000||progress>=0.03;
      if(!page||!qualified)cursor.delete();
      else if(records.length<6){
        record.href=page.href;record.title=page.title;
        record.category=page.categoryLabel||page.category;
        if(record.lastHeadingId&&!(page.headings||[]).some(function(item){
          return item.id===record.lastHeadingId;
        }))record.lastHeadingId='';
        records.push(record);
      }
      cursor.continue();
    };
    request.onerror=function(){reject(request.error);};
  });
}
function resumeHref(record){
  var href=record.href||record.url||'#';
  if(record.lastHeadingId)href=href.split('#')[0]+'#'+encodeURIComponent(record.lastHeadingId);
  return href;
}
function renderResume(records){
  if(!resume||!resumeList)return;resumeList.textContent='';
  if(resumeCount)resumeCount.textContent='/ '+count(records.length);
  if(!records.length){
    var box=document.createElement('div');box.className='resume-empty-state';
    var title=document.createElement('strong');title.textContent='还没有有效阅读轨迹';
    var copy=document.createElement('small');
    copy.textContent='停留 30 秒或阅读超过 3% 后，才会保存最近位置。';
    box.appendChild(title);box.appendChild(copy);
    if(pages.length){var start=document.createElement('a');
      start.href=pages.slice().sort(function(a,b){return (b.modified||0)-(a.modified||0);})[0].href;
      start.textContent='从全部笔记开始 →';box.appendChild(start);}
    resumeList.appendChild(box);resume.hidden=false;return;
  }
  records.forEach(function(record,index){
    var link=document.createElement('a');
    link.className='resume-record'+(index===0?' resume-record-primary':'');
    link.href=resumeHref(record);
    var number=document.createElement('span');number.className='resume-number';number.textContent=count(index+1);
    var body=document.createElement('span');body.className='resume-copy';
    var title=document.createElement('strong');title.textContent=record.title||record.pageId;
    var detail=document.createElement('small');detail.textContent=(record.lastHeadingTitle||'上次阅读位置')+
      ' · '+Math.round((record.progress||record.scrollRatio||0)*100)+'%';
    body.appendChild(title);body.appendChild(detail);
    var meter=document.createElement('span');meter.className='resume-meter';
    var fill=document.createElement('i');fill.style.width=
      Math.round((record.progress||record.scrollRatio||0)*100)+'%';
    meter.appendChild(fill);link.appendChild(number);link.appendChild(body);link.appendChild(meter);
    resumeList.appendChild(link);
  });
  resume.hidden=false;
}
readUrl();applyState();
openReadingDb().then(function(db){
  return loadRecentRecords(db).finally(function(){db.close();});
}).then(renderResume).catch(function(){if(resume)resume.hidden=true;});
})();
</script>\n")

(defun org-museum--build-index-html (cats graph-href out-file)
  "Return the complete index.html for CATS and GRAPH-HREF."
  (ignore graph-href)
  (let* ((pages (org-museum--sort-pages-by-modified
                 (org-museum--pages-from-categories cats)))
         (published-count (cl-count-if #'org-museum--published-page-p pages))
         (draft-count (- (length pages) published-count))
         (recent pages)
         (index-data (org-museum--index-data-alist pages out-file))
         (recent-html
          (if recent
              (let ((n 0))
                (mapconcat
                 (lambda (page)
                   (setq n (1+ n))
                   (org-museum--build-index-entry-html page out-file n))
                 recent ""))
            "<p class=\"museum-empty-copy\">索引为空。导出笔记后，全部笔记会出现在这里。</p>")))
    (concat
     "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n"
     "  <meta charset=\"utf-8\">\n"
     "  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
     "  <meta name=\"color-scheme\" content=\"dark\">\n"
     "  <title>Org Museum</title>\n"
     (format "  %s\n" (org-museum--css-link-tag out-file))
     (format "  %s\n" org-museum--favicon-link-tag)
     "</head>\n<body class=\"org-museum-home\" data-page-kind=\"home\">\n"
     (org-museum--build-topbar out-file 'home)
     "<main class=\"museum-index-shell\">\n"
     "  <section class=\"museum-home-upper\">\n"
     "    <section id=\"continue-reading\" class=\"museum-resume\" hidden>\n"
     "      <div class=\"museum-section-heading\"><h2>继续阅读</h2><span id=\"continue-reading-count\">/ 00</span></div>\n"
     "      <div id=\"continue-reading-list\"></div>\n"
     "    </section>\n"
     "    <section class=\"museum-topic-index\">\n"
     "      <div class=\"museum-section-heading\"><h2>主题索引</h2><span>/ "
     (format "%02d" (length cats))
     "</span></div>\n"
     "      <div class=\"museum-topic-grid\">\n"
     (org-museum--build-topic-index-html cats)
     "\n      </div>\n"
     "    </section>\n"
     "  </section>\n"
     "  <section id=\"recent-updates\" class=\"museum-recent\">\n"
     "    <div class=\"museum-index-toolbar\">\n"
     "      <div class=\"museum-section-heading museum-section-rule\">"
     "<h2 id=\"index-results-heading\" tabindex=\"-1\">全部笔记 · 按更新时间</h2>"
     "<span id=\"index-visible-count\" role=\"status\" aria-live=\"polite\">/ "
     (format "%02d" (length recent))
     "</span></div>\n"
     "      <div class=\"museum-status-filters\" role=\"group\" aria-label=\"按发布状态筛选\">\n"
     (format
      (concat
       "        <button type=\"button\" class=\"is-active\" data-status-filter=\"all\" "
       "aria-pressed=\"true\">全部 <b>%02d</b></button>\n"
       "        <button type=\"button\" data-status-filter=\"published\" "
       "aria-pressed=\"false\">已发布 <b>%02d</b></button>\n"
       "        <button type=\"button\" data-status-filter=\"draft\" "
       "aria-pressed=\"false\">草稿 <b>%02d</b></button>\n")
      (length pages) published-count draft-count)
     "      </div>\n"
     "    </div>\n"
     "    <div id=\"index-filter-summary\" class=\"museum-filter-summary\" hidden>\n"
     "      <span id=\"index-filter-summary-text\"></span>\n"
     "      <button type=\"button\" data-clear-index-filters>清除筛选</button>\n"
     "    </div>\n"
     "    <div class=\"museum-index-matrix\">\n"
     recent-html
     "    </div>\n"
     "    <div id=\"index-search-list\" hidden></div>\n"
     "    <p id=\"index-search-empty\" class=\"museum-search-empty\" hidden>"
     "没有匹配的笔记。可以清除筛选，或换一个标题、章节、标签或分类词。</p>\n"
     "    <p id=\"index-results-live\" class=\"sr-only\" role=\"status\" "
     "aria-live=\"polite\"></p>\n"
     "  </section>\n"
     "  <footer class=\"museum-index-footer\">"
     (format "%d 篇索引 · 本地静态 Wiki" (length pages))
     "</footer>\n"
     "</main>\n"
     "<script type=\"application/json\" id=\"org-museum-index-data\">"
     (org-museum--json-for-html index-data)
     "</script>\n"
     (org-museum--script-index)
     "</body>\n</html>\n")))

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
         (data-json   (org-museum--generate-graph-json))
         (d3-src      (org-museum--d3-js-src graph-html)))
    (make-directory shared-root t)
    (with-temp-file graph-html
      (insert (org-museum--build-graph-html data-json css-href d3-src)))
    (unless silent
      (browse-url (concat "file:///" (replace-regexp-in-string "\\\\" "/" graph-html)))
      (message "Graph generated: %s" graph-html))
    graph-html))

(defun org-museum--generate-graph-json ()
  "Return JSON string of all nodes and links, with performance tier metadata.
[Fix-06] Includes pre-ticks in meta for large/medium tiers."
  (let* ((pages    (org-museum-index-pages org-museum--index))
         (nodes    '())
         (links    '())
         (degree   (make-hash-table :test 'equal))
         (excluded (make-hash-table :test 'equal)))
    ;; Phase 1: exclude-by-tag / exclude-by-id-regexp
    (maphash
     (lambda (id page)
       (when (org-museum--graph-page-excluded-p id page)
         (puthash id t excluded)))
     pages)
    ;; Phase 2: build links and degrees, skipping excluded endpoints
    (maphash
     (lambda (id page)
       (unless (gethash id excluded)
         (dolist (target (org-museum-page-links-to page))
           (unless (gethash target excluded)
             (cl-incf (gethash id     degree 0))
             (cl-incf (gethash target degree 0))
             (push `((source . ,id) (target . ,target) (value . 1)) links)))))
     pages)
    ;; Phase 3: optionally exclude orphans after filtering links, but never
    ;; collapse the whole graph to an empty canvas.
    (when org-museum-graph-exclude-orphans
      (let ((has-linked-node nil))
        (maphash
         (lambda (id _page)
           (when (and (not (gethash id excluded))
                      (> (gethash id degree 0) 0))
             (setq has-linked-node t)))
         pages)
        (when has-linked-node
          (maphash
           (lambda (id _page)
             (when (and (not (gethash id excluded))
                        (= (gethash id degree 0) 0))
               (puthash id t excluded)))
           pages))))
    ;; Phase 4: build nodes list from remaining pages
    (maphash
     (lambda (id page)
       (unless (gethash id excluded)
         (push `((id     . ,id)
                 (name   . ,(org-museum-page-title page))
                 (group  . ,(org-museum--category-label
                             (org-museum-page-category page)))
                 (tags   . ,(vconcat (org-museum-page-tags page)))
                 (status . ,(downcase
                             (or (org-museum-page-status page) "published")))
                 (degree . ,(gethash id degree 0))
                 (url    . ,(org-museum--page-href id nil)))
               nodes)))
     pages)
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
  Valid    - target page exists in index
  Missing  - target ID not in index (similarity suggestions provided)
  Absolute - file: links with absolute paths (portability risk)
Applicable scope: pre-publish review, CI validation.
Known limitation: only scans wiki:/museum:/id:/file: link types."
  (interactive)
  (org-museum--guard-init)
  (let* ((pages (org-museum-index-pages org-museum--index))
         (aliases (org-museum--build-page-id-aliases pages))
         valid-links missing-links absolute-links)
    (maphash
     (lambda (_id page)
       (let ((file (org-museum-page-path page)))
         (when (file-exists-p file)
           (with-temp-buffer
             (insert-file-contents file)
             (goto-char (point-min))
             (while (re-search-forward
                     "\\[\\[\\(?:wiki\\|museum\\|id\\):\\([^]\n]+\\)\\]\\(?:\\[[^]]*\\]\\)?\\]" nil t)
               (let* ((raw-target (match-string 1))
                      (target (org-museum--resolve-page-link-id raw-target pages aliases)))
                 (if target
                     (push (list :from (org-museum-page-id page)
                                 :to target) valid-links)
                   (push (list :from (org-museum-page-id page)
                               :to raw-target
                               :suggestions
                               (org-museum--suggest-similar-ids raw-target pages))
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
          (insert (format "- [[museum:%s][%s]] -> ==%s== not found\n"
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
          (insert (format "- [[museum:%s][%s]] -> =%s=\n"
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

;; Fix-04: rewrites file: links relative to their real Org source location.
(defun org-museum--file-link-parts (raw)
  "Return (PATH . SEARCH) parsed from RAW Org file-link target."
  (if (string-match "\\`\\(.*?\\)::\\(.*\\)\\'" (or raw ""))
      (cons (match-string 1 raw) (match-string 2 raw))
    (cons raw nil)))

(defun org-museum--asset-file-p (path)
  "Return non-nil when PATH is a directly rendered or downloaded asset."
  (member (downcase (or (file-name-extension path) ""))
          '("png" "jpg" "jpeg" "gif" "webp" "svg" "pdf" "txt" "zip")))

(defun org-museum--file-link-fragment (page search)
  "Resolve SEARCH to an exported heading fragment for PAGE."
  (when (and page search (not (string-empty-p search)))
    (cond
     ((string-prefix-p "#" search) (substring search 1))
     (t
      (let* ((title (string-trim-left search "\\*+[[:space:]]*"))
             (heading (cl-find-if
                       (lambda (item)
                         (string= title (or (cdr (assq 'title item)) "")))
                       (org-museum--page-headings page))))
        (and heading (cdr (assq 'id heading))))))))

(defun org-museum--rewrite-org-museum-links (buf out-file &optional source-file)
  "Rewrite Wiki and file links in BUF for OUT-FILE.
Relative file links are resolved from SOURCE-FILE, never from the temporary
export buffer.  Indexed Org targets become exported page links.  Existing
assets retain relative export paths; other local files become absolute paths
that Org exports as file URLs for local opening and copy-path fallback."
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
    ;; file: links — resolve from the original source path before export.
    (goto-char (point-min))
    (while (re-search-forward
            "\\[\\[file:\\([^]\n]+\\)\\]\\(?:\\[\\([^]]*\\)\\]\\)?\\]"
            nil t)
      (let* ((raw (match-string 1))
             (desc (match-string 2))
             (parts (org-museum--file-link-parts raw))
             (link-path (url-unhex-string (car parts)))
             (search (cdr parts))
             (source (or source-file (buffer-file-name buf)))
             (source-dir (if source (file-name-directory source)
                           default-directory))
             (full-path (expand-file-name link-path source-dir))
             (page (and org-museum--index
                        (org-museum--find-page-by-expanded-path
                         full-path (org-museum-index-pages org-museum--index))))
             (fragment (org-museum--file-link-fragment page search))
             (destination
              (cond
               (page
                (concat (org-museum--page-href
                         (org-museum-page-id page) out-file)
                        (if fragment (concat "#" fragment) "")))
               ((org-museum--asset-file-p full-path)
                (org-museum--relative-path full-path out-file))
               (t
                (replace-regexp-in-string "\\\\" "/" full-path t t))))
             (description (if desc (format "[%s]" desc) "")))
        (replace-match (format "[[file:%s]%s]" destination description) t t)))))

(defun org-museum--pp-annotate-local-file-links ()
  "Mark exported absolute local-file anchors and add copy-path fallback UI."
  (goto-char (point-min))
  (while (re-search-forward
          "<a\\([^>]*\\)href=\"\\(file:/+[^\"]+\\)\"\\([^>]*\\)>\\(.*?\\)</a>"
          nil t)
    (let* ((match-start (match-beginning 0))
           (match-end (match-end 0))
           (before (match-string 1))
           (href (match-string 2))
           (after (match-string 3))
           (label (match-string 4))
           (exported-path (org-museum--file-url-to-path href))
           (org-source-path
            (and exported-path
                 (string= (downcase (or (file-name-extension exported-path) ""))
                          "html")
                 (concat (file-name-sans-extension exported-path) ".org")))
           (path (if (and org-source-path (file-exists-p org-source-path))
                     org-source-path
                   exported-path)))
      (when (and path (not (string-match-p "<img\\b" label)))
        (let* ((exists (file-exists-p path))
               (state (if exists "existing" "missing"))
               (escaped-path (org-museum--html-escape path t))
               (escaped-href (org-museum--html-escape
                              (org-museum--path-to-file-url path) t))
               (anchor
                (if exists
                    (format "<a%s href=\"%s\"%s>%s</a>"
                            before escaped-href after label)
                  (format "<span class=\"museum-local-file-label\" aria-disabled=\"true\">%s</span>"
                          label))))
          (let ((replacement
                 (format
                  (concat "<span class=\"museum-local-file museum-local-file-%s\" "
                          "data-museum-local-file=\"%s\" data-local-path=\"%s\">"
                          "%s<span class=\"museum-local-file-badge\">%s</span>"
                          "<button type=\"button\" data-copy-local-path=\"%s\">复制路径</button>"
                          "</span>")
                  state state escaped-path anchor
                  (if exists "本地文件" "文件缺失") escaped-path)))
            (goto-char match-start)
            (delete-region match-start match-end)
            (insert replacement)))))))

(defun org-museum--generated-html-file-p (file)
  "Return non-nil when FILE looks like an Org Museum generated HTML file."
  (and (file-exists-p file)
       (with-temp-buffer
         (insert-file-contents file)
         (goto-char (point-min))
         (re-search-forward
          "org-museum-sidebar\\|local-graph-container\\|Org Museum" nil t))))

(defun org-museum--delete-legacy-source-html (org-file out-file)
  "Delete the old source-directory HTML for ORG-FILE after exporting to OUT-FILE."
  (let ((legacy (expand-file-name
                 (concat (file-name-base org-file) ".html")
                 (file-name-directory (expand-file-name org-file)))))
    (when (and (file-exists-p legacy)
               (not (file-equal-p legacy out-file))
               (org-museum--generated-html-file-p legacy))
      (delete-file legacy))))
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
The output mirrors page files under the per-page export root."
  (let* ((file      (expand-file-name org-file))
         (pages-dir (file-name-as-directory (expand-file-name (org-museum--pages-base-dir))))
         (base-dir  (if (string-prefix-p (file-truename pages-dir)
                                         (file-truename file))
                        pages-dir
                      (file-name-as-directory (org-museum--scan-root))))
         (rel-dir   (file-relative-name (file-name-directory file) base-dir))
         (out-root  (org-museum--pages-root))
         (out-dir   (if (string= rel-dir ".")
                        out-root
                      (expand-file-name rel-dir out-root))))
    (expand-file-name (concat (file-name-base file) ".html") out-dir)))
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

(defun org-museum--page-node-ids (page)
  "Return all Org-roam/Org node IDs declared inside PAGE's file."
  (let ((ids (list (org-museum-page-id page))))
    (when (file-exists-p (org-museum-page-path page))
      (with-temp-buffer
        (insert-file-contents (org-museum-page-path page))
        (goto-char (point-min))
        (while (re-search-forward "^[ \\t]*:ID:[ \\t]+\\(.+?\\)[ \\t]*$" nil t)
          (let ((id (string-trim (match-string 1))))
            (unless (string-empty-p id)
              (cl-pushnew id ids :test #'equal))))
        (goto-char (point-min))
        (while (re-search-forward "^#\\+ID:[ \\t]*\\(.+?\\)[ \\t]*$" nil t)
          (let ((id (string-trim (match-string 1))))
            (unless (string-empty-p id)
              (cl-pushnew id ids :test #'equal))))))
    ids))

(defun org-museum--read-db-string (value)
  "Return VALUE as a plain string, unquoting org-roam DB text when needed."
  (cond
   ((not (stringp value)) value)
   ((and (> (length value) 1)
         (string-prefix-p "\"" value)
         (string-suffix-p "\"" value))
    (condition-case nil
        (let ((read-value (read value)))
          (if (stringp read-value) read-value value))
      (error value)))
   (t value)))

(defun org-museum--org-roam-db-linked-page-ids (file pages-table aliases)
  "Return canonical page IDs linked from FILE according to org-roam.db."
  (let ((db-path (expand-file-name "org-roam.db" org-museum-root-dir))
        (result '()))
    (when (and (fboundp 'sqlite-open)
               (file-exists-p db-path))
      (let ((db (sqlite-open db-path)))
        (unwind-protect
            (dolist (source-id (org-museum--page-node-ids
                                (org-museum--find-page-by-path file pages-table)))
              (dolist (source (list source-id (format "%S" source-id)))
                (dolist (row (sqlite-select db
                                            "select dest from links where source = ?"
                                            (vector source)))
                  (let* ((dest (org-museum--read-db-string (car row)))
                         (page-id (org-museum--resolve-page-link-id
                                   dest pages-table aliases)))
                    (when page-id
                      (cl-pushnew page-id result :test #'equal))))))
          (sqlite-close db))))
    result))
(defun org-museum--org-roam-db-related-page-ids (file pages-table aliases)
  "Return canonical page IDs adjacent to FILE according to org-roam.db."
  (let ((db-path (expand-file-name "org-roam.db" org-museum-root-dir))
        (page (org-museum--find-page-by-path file pages-table))
        (result '()))
    (when (and page
               (fboundp 'sqlite-open)
               (file-exists-p db-path))
      (let ((db (sqlite-open db-path)))
        (unwind-protect
            (dolist (node-id (org-museum--page-node-ids page))
              (dolist (db-id (list node-id (format "%S" node-id)))
                (dolist (row (sqlite-select db
                                            "select source, dest from links where source = ? or dest = ?"
                                            (vector db-id db-id)))
                  (let* ((source (org-museum--read-db-string (nth 0 row)))
                         (dest (org-museum--read-db-string (nth 1 row)))
                         (other (if (equal source node-id) dest source))
                         (page-id (org-museum--resolve-page-link-id
                                   other pages-table aliases)))
                    (when (and page-id
                               (not (equal page-id (org-museum-page-id page))))
                      (cl-pushnew page-id result :test #'equal))))))
          (sqlite-close db))))
    result))
(defun org-museum--build-page-id-aliases (pages-table)
  "Return a hash table mapping Org IDs and page IDs to canonical page IDs."
  (let ((aliases (make-hash-table :test 'equal)))
    (maphash
     (lambda (id page)
       (puthash id id aliases)
       (dolist (alias (org-museum--page-node-ids page))
         (unless (gethash alias aliases)
           (puthash alias id aliases))))
     pages-table)
    aliases))

(defun org-museum--resolve-page-link-id (raw-id pages-table &optional aliases)
  "Resolve RAW-ID to a canonical Org Museum page ID using PAGES-TABLE."
  (let* ((id (string-trim (or raw-id "")))
         (alias-table (or aliases (org-museum--build-page-id-aliases pages-table))))
    (or (gethash id alias-table)
        (and (gethash id pages-table) id))))
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

(defun org-museum--script-shell ()
  "Return accessible drawer, mobile TOC, and article search behavior."
  "<script>
(function(){
'use strict';
var drawer=document.getElementById('org-museum-sidebar');
var toc=document.getElementById('org-museum-right-sidebar');
var backdrop=document.getElementById('museum-drawer-backdrop');
var tocDrawerMedia=matchMedia('(max-width:1120px)');
var tocAnchor=null;
var lastFocus=null;
if(toc&&toc.parentNode){
  tocAnchor=document.createComment('org-museum-toc-anchor');
  toc.parentNode.insertBefore(tocAnchor,toc);
}
function placeToc(){
  if(!toc)return;
  if(tocDrawerMedia.matches){
    if(toc.parentNode!==document.body)document.body.appendChild(toc);
  }else if(tocAnchor&&tocAnchor.parentNode){
    tocAnchor.parentNode.insertBefore(toc,tocAnchor.nextSibling);
  }
}
placeToc();
function controls(selector,open){
  document.querySelectorAll(selector).forEach(function(button){
    button.setAttribute('aria-expanded',open?'true':'false');
  });
}
function focusFirst(container){
  var item=container&&container.querySelector(
    'button:not([disabled]),a[href],input:not([disabled]),[tabindex=\"0\"]');
  if(item)item.focus();
}
function closeAll(restore){
  document.body.classList.remove('museum-drawer-open','museum-toc-open');
  if(drawer)drawer.setAttribute('aria-hidden','true');
  if(toc&&matchMedia('(max-width:1120px)').matches)toc.setAttribute('aria-hidden','true');
  controls('[data-drawer-toggle]',false);controls('[data-toc-toggle]',false);
  if(restore&&lastFocus&&document.contains(lastFocus))lastFocus.focus();
  lastFocus=null;
}
function openPanel(kind,trigger){
  closeAll(false);lastFocus=trigger||document.activeElement;
  var isDrawer=kind==='drawer';
  document.body.classList.add(isDrawer?'museum-drawer-open':'museum-toc-open');
  var panel=isDrawer?drawer:toc;
  if(panel)panel.setAttribute('aria-hidden','false');
  controls(isDrawer?'[data-drawer-toggle]':'[data-toc-toggle]',true);
  focusFirst(panel);
}
document.querySelectorAll('[data-drawer-toggle]').forEach(function(button){
  button.addEventListener('click',function(){
    if(document.body.classList.contains('museum-drawer-open'))closeAll(true);
    else openPanel('drawer',button);
  });
});
document.querySelectorAll('[data-toc-toggle]').forEach(function(button){
  button.addEventListener('click',function(){
    if(document.body.classList.contains('museum-toc-open'))closeAll(true);
    else openPanel('toc',button);
  });
});
document.querySelectorAll('[data-drawer-close],[data-toc-close]').forEach(function(button){
  button.addEventListener('click',function(){closeAll(true);});
});
if(backdrop)backdrop.addEventListener('click',function(){closeAll(true);});
document.addEventListener('keydown',function(event){
  if(event.key==='Escape'&&(document.body.classList.contains('museum-drawer-open')||
     document.body.classList.contains('museum-toc-open'))){
    event.preventDefault();closeAll(true);return;
  }
  if(event.key==='Tab'){
    var panel=document.body.classList.contains('museum-drawer-open')?drawer:
      (document.body.classList.contains('museum-toc-open')?toc:null);
    if(!panel)return;
    var items=Array.from(panel.querySelectorAll(
      'button:not([disabled]),a[href],input:not([disabled]),[tabindex=\"0\"]'));
    if(!items.length)return;
    var first=items[0],last=items[items.length-1];
    if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}
    else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}
  }
});
var search=document.getElementById('org-museum-global-search');
if(search&&document.body.dataset.pageKind==='article'){
  search.addEventListener('keydown',function(event){
    if(event.key==='Enter'&&search.value.trim()){
      var top=document.querySelector('.museum-topbar');
      var home=top?top.getAttribute('data-home-href'):'index.html';
      location.href=home+'?q='+encodeURIComponent(search.value.trim());
    }
  });
}
document.addEventListener('keydown',function(event){
  if(event.key==='/'&&!event.metaKey&&!event.ctrlKey&&!event.altKey&&
     !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)){
    event.preventDefault();if(search)search.focus();
  }
});
document.querySelectorAll('[data-drawer-toggle]').forEach(function(button){
  button.setAttribute('aria-controls','org-museum-sidebar');
  button.setAttribute('aria-expanded','false');
});
document.querySelectorAll('[data-toc-toggle]').forEach(function(button){
  button.setAttribute('aria-controls','org-museum-right-sidebar');
  button.setAttribute('aria-expanded','false');
});
if(toc&&tocDrawerMedia.matches)toc.setAttribute('aria-hidden','true');
if(!toc||!toc.querySelector('ul'))document.body.classList.add('museum-no-toc');
var onTocDrawerChange=function(){closeAll(false);placeToc();};
if(tocDrawerMedia.addEventListener)tocDrawerMedia.addEventListener('change',onTocDrawerChange);
else if(tocDrawerMedia.addListener)tocDrawerMedia.addListener(onTocDrawerChange);
var identity=document.getElementById('museum-article-identity');
var articleTitle=document.querySelector('.article-container > .title');
var articleScroller=document.getElementById('main-scroll')||window;
var identityHeadings=Array.from(document.querySelectorAll(
  '.article-container h2[id],.article-container h3[id],.article-container h4[id]'));
var identityFrame=0;
function updateArticleIdentity(){
  identityFrame=0;if(!identity||!articleTitle)return;
  var topbar=document.querySelector('.museum-topbar');
  var threshold=topbar?topbar.getBoundingClientRect().bottom+8:8;
  var current=null;
  identityHeadings.forEach(function(item){
    if(item.getBoundingClientRect().top<=threshold+36)current=item;
  });
  var show=articleTitle.getBoundingClientRect().bottom<=threshold;
  identity.hidden=!show;
  var section=identity.querySelector('[data-current-section]');
  if(section)section.textContent=current?current.textContent.trim():'文章开头';
}
function scheduleArticleIdentity(){
  if(identityFrame)return;identityFrame=requestAnimationFrame(updateArticleIdentity);
}
if(identity){
  articleScroller.addEventListener('scroll',scheduleArticleIdentity,{passive:true});
  window.addEventListener('load',scheduleArticleIdentity);
  window.addEventListener('hashchange',scheduleArticleIdentity);
  scheduleArticleIdentity();
}
var articleStatus=document.getElementById('museum-article-live-status');
function announceArticle(message){if(articleStatus)articleStatus.textContent=message;}
function copyArticleText(value,button){
  function done(){announceArticle('路径已复制');button.textContent='已复制';
    setTimeout(function(){button.textContent='复制路径';},1400);}
  function fallback(){
    var area=document.createElement('textarea');area.value=value;
    area.setAttribute('readonly','');area.style.position='fixed';area.style.left='-9999px';
    document.body.appendChild(area);area.select();
    try{if(document.execCommand('copy'))done();else announceArticle('复制失败，请手动复制路径');}
    catch(_error){announceArticle('复制失败，请手动复制路径');}
    document.body.removeChild(area);
  }
  if(navigator.clipboard&&navigator.clipboard.writeText)
    navigator.clipboard.writeText(value).then(done,fallback);
  else fallback();
}
document.querySelectorAll('[data-copy-local-path]').forEach(function(button){
  button.addEventListener('click',function(){
    copyArticleText(button.getAttribute('data-copy-local-path')||'',button);
  });
});
})();
</script>\n")

(defun org-museum--script-reading-state ()
  "Return qualified article reading-state persistence behavior."
  "<script>
(function(){
'use strict';
if(document.body.dataset.pageKind!=='article')return;
var pageId=document.body.dataset.pageId;if(!pageId)return;
var scroller=document.getElementById('main-scroll')||document.scrollingElement;
var article=document.querySelector('.article-container');
var headings=article?Array.from(article.querySelectorAll('h2[id],h3[id],h4[id]')):[];
var activeHeading=null,dbPromise=null,restored=false,timer=null;
var engagedTotalMs=0,qualifiedAt=0;
function readingActive(){
  return document.visibilityState==='visible'&&document.hasFocus();
}
var activeSince=readingActive()?Date.now():0;
function updateEngagement(){
  var now=Date.now();
  if(activeSince){engagedTotalMs+=now-activeSince;activeSince=0;}
  if(readingActive())activeSince=now;
  return engagedTotalMs;
}
function currentEngagedMs(){
  return engagedTotalMs+(activeSince?Date.now()-activeSince:0);
}
function openDb(){
  if(dbPromise)return dbPromise;
  dbPromise=new Promise(function(resolve,reject){
    if(!window.indexedDB){reject(new Error('IndexedDB unavailable'));return;}
    var request=indexedDB.open('org-museum',1);
    request.onupgradeneeded=function(){
      var db=request.result;
      var store=db.objectStoreNames.contains('readingState')
        ?request.transaction.objectStore('readingState')
        :db.createObjectStore('readingState',{keyPath:'pageId'});
      if(!store.indexNames.contains('lastVisitedAt'))
        store.createIndex('lastVisitedAt','lastVisitedAt',{unique:false});
    };
    request.onsuccess=function(){resolve(request.result);};
    request.onerror=function(){reject(request.error||new Error('IndexedDB failed'));};
    request.onblocked=function(){reject(new Error('IndexedDB blocked'));};
  });return dbPromise;
}
function metrics(){
  var top=scroller===window?window.scrollY:scroller.scrollTop;
  var height=scroller===window?document.documentElement.scrollHeight-window.innerHeight:
    scroller.scrollHeight-scroller.clientHeight;
  return {top:top,height:height,ratio:height>0?Math.max(0,Math.min(1,top/height)):0};
}
function updateActiveHeading(){
  var current=null;
  headings.forEach(function(heading){if(heading.getBoundingClientRect().top<=150)current=heading;});
  activeHeading=current;
}
function record(){
  updateActiveHeading();
  updateEngagement();
  var state=metrics(),engagedMs=currentEngagedMs(),progress=state.ratio;
  if(!qualifiedAt&&(progress>=0.03||engagedMs>=30000))qualifiedAt=Date.now();
  return {
    pageId:pageId,href:location.pathname+location.search,url:location.pathname+location.search,
    title:document.body.dataset.pageTitle||document.title,
    category:document.body.dataset.pageCategory||'未分类',lastVisitedAt:Date.now(),
    lastHeadingId:activeHeading?activeHeading.id:'',
    lastHeadingTitle:activeHeading?activeHeading.textContent.trim():'',
    scrollRatio:progress,progress:progress,engagedMs:engagedMs,
    qualifiedAt:qualifiedAt||undefined
  };
}
function save(){
  var value=record();
  if(!value.qualifiedAt)return;
  openDb().then(function(db){
    db.transaction('readingState','readwrite').objectStore('readingState').put(value);
  }).catch(function(){});
}
function schedule(){
  var state=metrics();
  document.documentElement.style.setProperty('--reading-progress',(state.ratio*100)+'%');
  if(timer)return;
  timer=setTimeout(function(){timer=null;save();},800);
}
function restore(){
  openDb().then(function(db){return new Promise(function(resolve,reject){
    var request=db.transaction('readingState','readonly').objectStore('readingState').get(pageId);
    request.onsuccess=function(){resolve(request.result);};
    request.onerror=function(){reject(request.error);};
  });}).then(function(saved){
    if(restored||!saved)return;restored=true;
    var hash=decodeURIComponent(location.hash.replace(/^#/,''));
    var target=hash?document.getElementById(hash):null;
    if(!target&&saved.lastHeadingId)target=document.getElementById(saved.lastHeadingId);
    if(target)target.scrollIntoView({block:'start'});
    else if(saved.scrollRatio>0)requestAnimationFrame(function(){
      var top=saved.scrollRatio*metrics().height;
      if(scroller===window)window.scrollTo(0,top);else scroller.scrollTop=top;
    });
  }).catch(function(){});
}
scroller.addEventListener('scroll',schedule,{passive:true});
document.addEventListener('visibilitychange',updateEngagement);
window.addEventListener('focus',updateEngagement);
window.addEventListener('blur',updateEngagement);
window.addEventListener('pagehide',function(){if(timer)clearTimeout(timer);save();});
window.addEventListener('load',function(){
  restore();schedule();
  setInterval(function(){save();},5000);
});
})();
</script>\n")

(defun org-museum--build-sidebar-injection (out-file)
  "Return the full sidebar+script HTML string to inject before </body>."
  (concat
   "<div id=\"mobile-hud\" aria-label=\"移动导航\">\n"
   "  <button type=\"button\" class=\"hud-btn\" data-drawer-toggle>全部笔记</button>\n"
   "  <button type=\"button\" class=\"hud-btn\" data-toc-toggle>本文目录</button>\n"
   "</div>\n"
   "<button type=\"button\" id=\"museum-drawer-backdrop\" aria-label=\"关闭抽屉\"></button>\n"
   "<p id=\"museum-article-live-status\" class=\"sr-only\" role=\"status\" aria-live=\"polite\"></p>\n"
   "<div id=\"zen-mask\"></div>\n"
   "<canvas id=\"org-museum-fx-canvas\" aria-hidden=\"true\"></canvas>\n"
   (org-museum--generate-sidebar-html out-file)
   (org-museum--script-ui-core out-file)
   (org-museum--script-effects)
   (org-museum--script-toc-relocate)
   (org-museum--script-shell)
   (org-museum--script-reading-state)))

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
      (princ "<aside id=\"org-museum-sidebar\" aria-hidden=\"true\" aria-label=\"全部笔记\">\n")
      (princ "  <div class=\"sidebar-header\"><strong>全部笔记</strong>")
      (princ "<button type=\"button\" data-drawer-close>关闭</button></div>\n")
      (princ (format "  <a class=\"sidebar-nav-btn\" href=\"%s\">返回首页</a>\n"
                     (replace-regexp-in-string "\\\\" "/" home-href)))
      (princ (format "  <a class=\"sidebar-nav-btn graph\" href=\"%s\">知识图谱</a>\n"
                     (replace-regexp-in-string "\\\\" "/" graph-href)))
      (princ "  <div class=\"sidebar-search\">\n")
      (princ "    <input type=\"search\" id=\"org-museum-search-input\" placeholder=\"筛选标题…\" aria-label=\"筛选页面\">\n")
      (princ "  </div>\n")
      (princ (org-museum--sidebar-fx-controls))
      (if (null cats)
          (princ "  <p class=\"sidebar-empty\">索引为空。请先运行 org-museum-index-build。</p>\n")
        (dolist (cat-entry cats)
          (princ "  <div class=\"sidebar-category\">\n")
          (princ (format "    <div class=\"sidebar-cat-label\">%s <span>%02d</span></div>\n"
                         (org-museum--html-escape
                          (org-museum--category-label (car cat-entry)))
                         (length (cdr cat-entry))))
          (princ "    <ul>\n")
          (dolist (p (cdr cat-entry))
            (princ (format "      <li><a href=\"%s\">%s</a></li>\n"
                           (org-museum--html-escape
                            (org-museum--page-href
                             (org-museum-page-id p) out-file) t)
                           (org-museum--html-escape
                            (org-museum-page-title p)))))
          (princ "    </ul>\n")
          (princ "  </div>\n")))
      (princ "</aside>\n")
      (princ (org-museum--script-sidebar-search)))))

(defun org-museum--sidebar-fx-controls ()
  "Return HTML for the background-effects control panel."
  (concat
   "  <div class=\"sidebar-fx-controls\">\n"
   "    <div class=\"fx-label\">背景效果</div>\n"
   "    <div class=\"fx-buttons\">\n"
   "      <button class=\"fx-btn\" data-fx=\"none\">关闭</button>\n"
   "      <button class=\"fx-btn\" data-fx=\"tubes\">轨迹</button>\n"
   "      <button class=\"fx-btn\" data-fx=\"matrix\">矩阵</button>\n"
   "      <button class=\"fx-btn\" data-fx=\"particles\">微粒</button>\n"
   "    </div>\n"
   "  </div>\n"))

;; ============================================================
;; §21  WIKI NAVIGATION
;; ============================================================

(defun org-museum--build-nav-html (links backs out-file)
  "Generate nav HTML for LINKS (outgoing) and BACKS (incoming)."
  (concat
   "<nav class=\"org-museum-nav\" aria-label=\"文章关系\">\n"
   (when links
     (concat
      "<div class=\"org-museum-nav-links\">"
      "<span class=\"org-museum-nav-label\">链接到 / "
      (format "%02d" (length links))
      "</span>"
      (mapconcat (lambda (id)
                   (let* ((p (gethash id (org-museum-index-pages org-museum--index)))
                          (title (if p (org-museum-page-title p) id)))
                     (format "<a href=\"%s\" class=\"org-museum-link\">%s</a>"
                             (org-museum--html-escape
                              (org-museum--page-href id out-file) t)
                             (org-museum--html-escape title))))
                 links "\n")
      "</div>\n"))
   (when backs
     (concat
      "<div class=\"org-museum-nav-backlinks\">"
      "<span class=\"org-museum-nav-label\">反向链接 / "
      (format "%02d" (length backs))
      "</span>"
      (mapconcat (lambda (id)
                   (let* ((p (gethash id (org-museum-index-pages org-museum--index)))
                          (title (if p (org-museum-page-title p) id)))
                     (format "<a href=\"%s\" class=\"org-museum-link\">%s</a>"
                             (org-museum--html-escape
                              (org-museum--page-href id out-file) t)
                             (org-museum--html-escape title))))
                 backs "\n")
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
  function catCol(c){return pal[cats.indexOf(c)%%(pal.length)]||'#75715e';}
  function nCol(d){return (%s)?catCol(d.group):(d.center?'%s':'%s');}
  function nR(d){return d.center?9:Math.max(5,Math.min(18,5+(d.degree||0)*1.8));}
  var el=document.getElementById('%s');
  if(!el||!(%s).nodes||(%s).nodes.length<1)return;
  var W=el.clientWidth||400,H=%d;
  var svg=d3.select('#%s').append('svg')
    .attr('width','100%%').attr('height',H).attr('viewBox','0 0 '+W+' '+H);
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
  var nodeEnter=g.append('g').selectAll('g').data((%s).nodes).enter();
  var node=(%s)
    ? nodeEnter.append('a')
        .attr('href',function(d){return d.url||(d.id+'.html');})
        .attr('xlink:href',function(d){return d.url||(d.id+'.html');})
        .attr('target','_self')
        .style('cursor','pointer')
    : nodeEnter.append('g');
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
            l-col arrows cid dv nav
            labels fsize nav)))

;; Fix-08: neighbour capping with _overflow virtual node.
(defun org-museum--generate-local-graph-data (page &optional out-file)
  "Return JSON-compatible alist for a local graph centred on PAGE.
[Fix-08] When total neighbour count exceeds `org-museum-local-graph-neighbour-limit',
neighbours are sorted by degree descending; excess nodes are folded into a
virtual overflow node that links back to the
page's entry in graph.html.
Applicable scope: org-museum--generate-local-graph-html."
  (let* ((center-id  (org-museum-page-id page))
         (limit      org-museum-local-graph-neighbour-limit)
         (pages      (org-museum-index-pages org-museum--index))
         (aliases    (org-museum--build-page-id-aliases pages))
         (indexed-nbrs (cl-union (org-museum-page-links-to page)
                                 (org-museum-page-linked-from page)
                                 :test #'equal))
         (db-nbrs    (org-museum--org-roam-db-related-page-ids
                      (org-museum-page-path page) pages aliases))
         (all-nbrs   (cl-union indexed-nbrs db-nbrs :test #'equal))
         (sorted-nbrs
          (sort (copy-sequence all-nbrs)
                (lambda (a b)
                  (let ((pa (gethash a pages))
                        (pb (gethash b pages)))
                    (> (if pa (length (org-museum-page-links-to pa)) 0)
                       (if pb (length (org-museum-page-links-to pb)) 0))))))
         (capped     (seq-take sorted-nbrs limit))
         (overflow   (- (length all-nbrs) (length capped)))
         (nodes      (list `((id . ,center-id)
                             (name . ,(org-museum-page-title page))
                             (center . t)
                             (degree . 0)
                             (url . ,(org-museum--page-href center-id out-file)))))
         (links      '()))
    (dolist (nid capped)
      (when-let ((p (gethash nid pages)))
        (push `((id . ,nid)
                (name . ,(org-museum-page-title p))
                (degree . ,(length (org-museum-page-links-to p)))
                (url . ,(org-museum--page-href nid out-file)))
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
(defun org-museum--generate-local-graph-html-legacy (page &optional out-file)
  "Return HTML+JS for a local D3 graph around PAGE.
[Fix-07] Passes :link-arrow t to the shared renderer.
[Fix-08] Neighbour count is capped via generate-local-graph-data."
  (let* ((data   (org-museum--generate-local-graph-data page out-file))
         (json   (json-encode data))
         (nodes  (append (cdr (assq 'nodes data)) nil))
         (related
          (cl-remove-if
           (lambda (node)
             (or (cdr (assq 'center node))
                 (string= (or (cdr (assq 'id node)) "") "_overflow")))
           nodes))
         (related-html
          (if related
              (concat
               "<ul class=\"org-museum-related-list\">\n"
               (mapconcat
                (lambda (node)
                  (format "<li><a href=\"%s\">%s</a></li>"
                          (org-html-encode-plain-text
                           (or (cdr (assq 'url node)) "#"))
                          (org-html-encode-plain-text
                           (or (cdr (assq 'name node))
                               (cdr (assq 'id node))
                               "Untitled"))))
                related "\n")
               "\n</ul>")
            "<p class=\"org-museum-related-empty\">No linked Org-roam pages found yet.</p>"))
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
  %s
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
            related-html json render (org-museum--d3-js-src out-file))))
(defun org-museum--generate-local-graph-html (page &optional out-file)
  "Return the compact local relationship section for PAGE."
  (let* ((data (org-museum--generate-local-graph-data page out-file))
         (nodes (append (cdr (assq 'nodes data)) nil))
         (related
          (cl-remove-if
           (lambda (node)
             (or (cdr (assq 'center node))
                 (string= (or (cdr (assq 'id node)) "") "_overflow")))
           nodes))
         (graph-file (expand-file-name "graph.html" (org-museum--shared-root)))
         (graph-href
          (concat (org-museum--relative-path graph-file out-file)
                  "?focus="
                  (url-hexify-string (org-museum-page-id page)))))
    (concat
     "<section id=\"local-graph-container\" aria-labelledby=\"local-graph-heading\">\n"
     (format "<h3 id=\"local-graph-heading\">局部关系 / %02d</h3>\n" (length related))
     (if related
         (concat
          "<ul class=\"org-museum-related-list\">\n"
          (mapconcat
           (lambda (node)
             (format "<li><a href=\"%s\">%s</a></li>"
                     (org-museum--html-escape
                      (or (cdr (assq 'url node)) "#") t)
                     (org-museum--html-escape
                      (or (cdr (assq 'name node))
                          (cdr (assq 'id node))
                          "未命名"))))
           related "\n")
          "\n</ul>\n")
       "<p class=\"org-museum-related-empty\">这篇笔记还没有可导出的关联页面。</p>\n")
     (format "<a class=\"local-graph-link\" href=\"%s\">查看局部关系 →</a>\n"
             (org-museum--html-escape graph-href t))
     "</section>\n")))

(defun org-museum--build-graph-html-legacy (json-data css-href &optional d3-src)
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
  <link rel=\"icon\" href=\"data:,\">
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
      <input id=\"graph-search\" type=\"text\" placeholder=\"Search nodes…\" aria-label=\"Search graph nodes\">\n
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
          (or d3-src org-museum--d3-cdn)
          json-data
          (json-encode org-museum--graph-palette)))

;; ============================================================
;; §24  SCRIPT: UI CORE  [Fix-09]
;; ============================================================

(defun org-museum--build-graph-html (json-data css-href &optional d3-src)
  "Return the unified Monokai graph page for JSON-DATA."
  (let* ((graph-file (expand-file-name "graph.html" (org-museum--shared-root)))
         (topbar (org-museum--build-topbar graph-file 'graph))
         (safe-json json-data))
    (dolist (pair '(("<" . "\\u003c")
                    (">" . "\\u003e")
                    ("&" . "\\u0026")))
      (setq safe-json
            (replace-regexp-in-string
             (regexp-quote (car pair)) (cdr pair) safe-json t t)))
    (format
     "<!DOCTYPE html>
<html lang=\"zh-CN\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
  <meta name=\"color-scheme\" content=\"dark\">
  <title>Org Museum · 知识图谱</title>
  <link rel=\"stylesheet\" href=\"%s\">
  <link rel=\"icon\" href=\"data:,\">
  <script src=\"%s\"></script>
</head>
<body class=\"graph-page\" data-page-kind=\"graph\">
%s
<main class=\"museum-graph-shell\">
  <aside class=\"museum-graph-rail\">
    <div class=\"museum-section-heading\"><h1>知识图谱</h1><span id=\"graph-heading-count\">/ 00</span></div>
    <details class=\"graph-filter-summary\" open>
      <summary>统计与主题筛选</summary>
      <dl class=\"graph-counts\">
        <div><dt>笔记</dt><dd id=\"stat-nodes\">00</dd></div>
        <div><dt>连线</dt><dd id=\"stat-links\">00</dd></div>
        <div><dt>主题</dt><dd id=\"stat-cats\">00</dd></div>
      </dl>
      <div class=\"graph-filter-block\">
        <h2>主题筛选</h2>
        <div id=\"graph-category-filters\"></div>
      </div>
    </details>
    <div class=\"graph-view-controls\">
      <button type=\"button\" id=\"btn-reset\">重置视图</button>
      <button type=\"button\" id=\"btn-freeze\">冻结布局</button>
      <small>拖动画布 · 滚轮缩放</small>
    </div>
  </aside>
  <section class=\"museum-graph-workspace\" aria-label=\"知识关系画布\">
    <div id=\"graph-canvas\"></div>
    <div id=\"graph-empty-state\" hidden>
      <h2>尚未形成知识连线</h2>
      <p>不推断关系。当前按主题整理孤立笔记；复制链接写回 Org 后，下次导出会恢复真实关系图。</p>
      <div id=\"graph-zero-clusters\" class=\"graph-zero-clusters\"></div>
      <div class=\"graph-isolated-heading\"><h3>孤立笔记</h3><span id=\"graph-isolated-count\">00</span></div>
      <div id=\"graph-isolated-list\" class=\"graph-isolated-list\"></div>
      <p id=\"graph-copy-status\" class=\"sr-only\" role=\"status\" aria-live=\"polite\"></p>
    </div>
    <div id=\"graph-tooltip\" role=\"status\" aria-live=\"polite\">
      <strong id=\"tt-title\"></strong><span id=\"tt-meta\"></span>
    </div>
    <div class=\"graph-workspace-footer\">
      <div id=\"graph-selected-detail\"><span>—</span><a href=\"index.html\">打开笔记 →</a></div>
      <div id=\"graph-legend\" aria-label=\"主题图例\"></div>
    </div>
  </section>
</main>
<script>
(function(){
'use strict';
var raw=%s;
var nodes=(raw.nodes||[]).map(function(node){return Object.assign({},node);});
var links=(raw.links||[]).map(function(link){return Object.assign({},link);});
var meta=raw.meta||{};
var palette=%s;
var search=document.getElementById('org-museum-global-search');
var canvas=document.getElementById('graph-canvas');
var empty=document.getElementById('graph-empty-state');
var selectedDetail=document.getElementById('graph-selected-detail');
var cats=Array.from(new Set(nodes.map(function(node){return node.group||'未分类';}))).sort();
var focusId=new URLSearchParams(location.search).get('focus')||'';
var focusNeighbors=new Set(focusId?[focusId]:[]);
links.forEach(function(link){
  if(link.source===focusId)focusNeighbors.add(link.target);
  if(link.target===focusId)focusNeighbors.add(link.source);
});
var category='*';
var query='';
var selected=nodes.find(function(node){return node.id===focusId;})||nodes[0]||null;
var simulation=null;
var frozen=false;
var charge=Number(meta.charge);
var alphaDecay=Number(meta['alpha-decay']);
var tickLimit=meta['tick-limit']===false?0:Number(meta['tick-limit']);
var preTicks=meta['pre-ticks']===false?0:Number(meta['pre-ticks']);
var tickCount=0;
if(!Number.isFinite(charge))charge=-240;
if(!Number.isFinite(alphaDecay)||alphaDecay<=0)alphaDecay=0.0228;
if(!Number.isFinite(tickLimit)||tickLimit<0)tickLimit=0;
if(!Number.isFinite(preTicks)||preTicks<0)preTicks=0;

function count(value){return String(value).padStart(2,'0');}
document.getElementById('stat-nodes').textContent=count(nodes.length);
document.getElementById('stat-links').textContent=count(links.length);
document.getElementById('stat-cats').textContent=count(cats.length);
document.getElementById('graph-heading-count').textContent='/ '+count(nodes.length);
if(empty)empty.hidden=links.length!==0;
if(canvas)canvas.hidden=links.length===0;
document.body.classList.toggle('graph-zero-mode',links.length===0);
var viewControls=document.querySelector('.graph-view-controls');
if(viewControls)viewControls.hidden=links.length===0;
var filterSummary=document.querySelector('.graph-filter-summary');
if(filterSummary&&links.length===0&&matchMedia('(max-width:620px)').matches)
  filterSummary.open=false;

function color(group){
  var index=Math.max(0,cats.indexOf(group));
  return palette[index%%palette.length]||'#a29e8e';
}
function matches(node){
  var catOk=category==='*'||node.group===category;
  var hay=[node.name,node.group].concat(node.tags||[]).join(' ').toLowerCase();
  var focusOk=!focusId||query||category!=='*'||focusNeighbors.has(node.id);
  return catOk&&focusOk&&(!query||hay.indexOf(query)>=0);
}
function copyWikiLink(value,button){
  var status=document.getElementById('graph-copy-status');
  function report(message){if(status)status.textContent=message;}
  function done(){button.textContent='已复制';report('Wiki 链接已复制');
    setTimeout(function(){button.textContent='复制链接';},1400);}
  function fallback(){
    var area=document.createElement('textarea');
    area.value=value;area.setAttribute('readonly','');
    area.style.position='fixed';area.style.left='-9999px';
    document.body.appendChild(area);area.select();
    try{
      if(document.execCommand('copy'))done();
      else {button.textContent='复制失败，请手动复制';report('复制失败，请手动复制');}
    }catch(_error){button.textContent='复制失败，请手动复制';report('复制失败，请手动复制');}
    document.body.removeChild(area);
  }
  if(navigator.clipboard&&navigator.clipboard.writeText)
    navigator.clipboard.writeText(value).then(done,fallback);
  else fallback();
}
function renderZeroState(){
  if(links.length!==0)return;
  var clusterRoot=document.getElementById('graph-zero-clusters');
  var listRoot=document.getElementById('graph-isolated-list');
  var visible=nodes.filter(matches);
  if(clusterRoot){
    clusterRoot.textContent='';
    cats.forEach(function(cat){
      var catNodes=visible.filter(function(node){return node.group===cat;});
      if(!catNodes.length)return;
      var group=document.createElement('button');group.type='button';
      group.className='graph-cluster-filter';group.dataset.graphCategory=cat;
      group.setAttribute('aria-pressed',category===cat?'true':'false');
      var heading=document.createElement('h3');heading.textContent=cat;
      var total=document.createElement('span');total.textContent=count(catNodes.length);
      group.addEventListener('click',function(){setCategory(category===cat?'*':cat);});
      group.appendChild(heading);group.appendChild(total);clusterRoot.appendChild(group);
    });
  }
  if(listRoot){
    listRoot.textContent='';
    visible.forEach(function(node){
      var row=document.createElement('article');row.dataset.status=node.status||'published';
      var link=document.createElement('a');link.href=node.url||'index.html';link.textContent=node.name;
      var meta=document.createElement('small');
      meta.textContent=(node.group||'未分类')+(node.status==='draft'?' · 草稿':'');
      var literal=document.createElement('code');literal.className='graph-wiki-literal';
      literal.textContent='[[wiki:'+node.id+']['+node.name+']]';
      var copy=document.createElement('button');copy.type='button';
      copy.textContent='复制链接';
      copy.addEventListener('click',function(){
        var value='[[wiki:'+node.id+']['+node.name+']]';
        copyWikiLink(value,copy);
      });
      row.appendChild(link);row.appendChild(meta);row.appendChild(literal);
      row.appendChild(copy);listRoot.appendChild(row);
    });
  }
  var total=document.getElementById('graph-isolated-count');
  if(total)total.textContent=count(visible.length);
}
function syncGraphCategoryControls(){
  document.querySelectorAll('[data-graph-category]').forEach(function(entry){
    var active=entry.dataset.graphCategory===category;
    entry.classList.toggle('is-active',active);
    entry.setAttribute('aria-pressed',active?'true':'false');
  });
}
function setCategory(value){
  category=value||'*';syncGraphCategoryControls();
  if(links.length===0)renderZeroState();else applyFilter();
}
function renderFilters(){
  var root=document.getElementById('graph-category-filters');
  var items=[{name:'*',label:'全部',count:nodes.length}].concat(
    cats.map(function(cat){return {
      name:cat,label:cat,count:nodes.filter(function(node){return node.group===cat;}).length
    };})
  );
  items.forEach(function(item){
    var button=document.createElement('button');
    button.type='button';button.dataset.graphCategory=item.name;
    button.innerHTML='<span></span><b></b>';
    button.querySelector('span').textContent=item.label;
    button.querySelector('b').textContent=count(item.count);
    button.setAttribute('aria-pressed',item.name===category?'true':'false');
    if(item.name===category)button.classList.add('is-active');
    button.addEventListener('click',function(){setCategory(item.name);});
    root.appendChild(button);
  });
}
function renderLegend(){
  var root=document.getElementById('graph-legend');
  cats.forEach(function(cat){
    var item=document.createElement('span');
    var dot=document.createElement('i');dot.style.background=color(cat);
    item.appendChild(dot);item.appendChild(document.createTextNode(cat));
    root.appendChild(item);
  });
}
function selectNode(node){
  selected=node;
  nodeSelection.select('circle').classed('is-selected',function(entry){return entry.id===node.id;});
  selectedDetail.querySelector('span').textContent=
    String(nodes.indexOf(node)+1).padStart(2,'0')+' / '+(node.group||'未分类')+
    ' / '+count(node.degree||0)+' 条关系';
  selectedDetail.querySelector('a').href=node.url||'index.html';
}

renderFilters();renderLegend();
document.addEventListener('keydown',function(event){
  if(event.key==='/'&&!event.metaKey&&!event.ctrlKey&&!event.altKey&&
     !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)){
    event.preventDefault();if(search)search.focus();
  }
});
if(links.length===0){
  renderZeroState();
  if(search)search.addEventListener('input',function(){
    query=search.value.trim().toLowerCase();renderZeroState();
  });
  return;
}
if(typeof d3==='undefined'||!canvas){
  canvas.innerHTML='<p class=\"museum-empty-copy\">图谱运行资源不可用，仍可通过首页索引打开笔记。</p>';
  return;
}
var width=canvas.clientWidth||900;
var height=canvas.clientHeight||760;
var svg=d3.select(canvas).append('svg')
  .attr('viewBox','0 0 '+width+' '+height)
  .attr('role','img')
  .attr('aria-label','Org Museum 知识图谱');
var layer=svg.append('g');
var zoom=d3.zoom().scaleExtent([0.35,5]).on('zoom',function(event){
  layer.attr('transform',event.transform);
});
svg.call(zoom);
var linkSelection=layer.append('g').attr('class','graph-links')
  .selectAll('line').data(links).enter().append('line');
var nodeSelection=layer.append('g').attr('class','graph-nodes')
  .selectAll('g').data(nodes).enter().append('g')
  .attr('tabindex',0).attr('role','link');
nodeSelection.append('circle').attr('r',function(node){return node.degree?7:6;})
  .attr('fill',function(node){return color(node.group);});
nodeSelection.append('text').attr('x',14).attr('y',4)
  .text(function(node){
    var name=node.name||'未命名';
    var limit=width<600?16:22;
    return name.length>limit?name.slice(0,limit)+'…':name;
  });

function positionNodeLabels(){
  nodeSelection.select('text')
    .attr('x',function(node){return width<600?14:(node.x>width/2?-14:14);})
    .attr('text-anchor',function(node){return width<600?'start':(node.x>width/2?'end':'start');});
}
function positionIsolated(){
  if(width<600){
    var split=Math.ceil(nodes.length/2);
    nodes.forEach(function(node,index){
      node.x=28;
      node.y=index<split?60+index*70:height-60-(nodes.length-1-index)*70;
    });
    nodeSelection.attr('transform',function(node){return 'translate('+node.x+','+node.y+')';});
    positionNodeLabels();
    return;
  }
  var cols=2;
  nodes.forEach(function(node,index){
    var col=index%%cols,row=Math.floor(index/cols);
    node.x=90+col*(width-220);
    node.y=100+row*Math.max(150,(height-190)/Math.max(1,Math.ceil(nodes.length/cols)-1));
  });
  nodeSelection.attr('transform',function(node){return 'translate('+node.x+','+node.y+')';});
  positionNodeLabels();
}
function renderTick(){
  linkSelection
    .attr('x1',function(link){return link.source.x;})
    .attr('y1',function(link){return link.source.y;})
    .attr('x2',function(link){return link.target.x;})
    .attr('y2',function(link){return link.target.y;});
  nodeSelection.attr('transform',function(node){return 'translate('+node.x+','+node.y+')';});
  positionNodeLabels();
}
if(links.length){
  simulation=d3.forceSimulation(nodes)
    .force('link',d3.forceLink(links).id(function(node){return node.id;}).distance(130))
    .force('charge',d3.forceManyBody().strength(charge))
    .force('center',d3.forceCenter(width/2,height/2))
    .force('collide',d3.forceCollide(58))
    .alphaDecay(alphaDecay)
    .stop();
  for(var warmTick=0;warmTick<preTicks;warmTick+=1)simulation.tick();
  renderTick();
  simulation.on('tick',function(){
    renderTick();tickCount+=1;
    if(tickLimit&&tickCount>=tickLimit)simulation.stop();
  }).restart();
  nodeSelection.call(d3.drag()
    .on('start',function(event,node){if(!event.active){tickCount=0;simulation.alphaTarget(.25).restart();}node.fx=node.x;node.fy=node.y;})
    .on('drag',function(event,node){node.fx=event.x;node.fy=event.y;})
    .on('end',function(event,node){if(!event.active)simulation.alphaTarget(0);node.fx=null;node.fy=null;}));
}else positionIsolated();

function applyFilter(){
  nodeSelection.classed('is-dimmed',function(node){return !matches(node);});
  linkSelection.classed('is-dimmed',function(link){
    var source=link.source.id?link.source:nodes.find(function(node){return node.id===link.source;});
    var target=link.target.id?link.target:nodes.find(function(node){return node.id===link.target;});
    return !source||!target||!matches(source)||!matches(target);
  });
}
var tooltip=document.getElementById('graph-tooltip');
nodeSelection
  .on('mouseenter',function(event,node){
    document.getElementById('tt-title').textContent=node.name;
    document.getElementById('tt-meta').textContent=(node.group||'未分类')+' · '+count(node.degree||0)+' 条关系';
    tooltip.classList.add('is-visible');
  })
  .on('mousemove',function(event){
    tooltip.style.left=(event.clientX+16)+'px';tooltip.style.top=(event.clientY+16)+'px';
  })
  .on('mouseleave',function(){tooltip.classList.remove('is-visible');})
  .on('click',function(_event,node){selectNode(node);})
  .on('dblclick',function(_event,node){location.href=node.url||'index.html';})
  .on('keydown',function(event,node){
    if(event.key==='Enter'){event.preventDefault();location.href=node.url||'index.html';}
  });

document.getElementById('btn-reset').addEventListener('click',function(){
  svg.transition().duration(350).call(zoom.transform,d3.zoomIdentity);
});
document.getElementById('btn-freeze').addEventListener('click',function(){
  frozen=!frozen;this.textContent=frozen?'继续布局':'冻结布局';
  if(simulation){if(frozen)simulation.stop();else {tickCount=0;simulation.alpha(.35).restart();}}
});
if(search)search.addEventListener('input',function(){query=search.value.trim().toLowerCase();applyFilter();});
applyFilter();if(selected)selectNode(selected);
})();
</script>
</body>
</html>"
     css-href
     (or d3-src org-museum--d3-cdn)
     topbar
     safe-json
     (json-encode org-museum--graph-palette))))

(defun org-museum--script-ui-core (out-file)
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
        var activeLink=null;
        tl.forEach(function(l){
          var isActive=l.getAttribute('href')==='#'+activeId;
          l.classList.toggle('toc-active',isActive);
          if(isActive)activeLink=l;
        });
        if(activeLink)activeLink.dispatchEvent(
          new CustomEvent('museum:toc-active',{bubbles:true}));
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
  var blocks=document.querySelectorAll('pre.src, pre.example');
  if(!blocks.length)return;
  var langMap={
    \"emacs-lisp\":\"lisp\",\"elisp\":\"lisp\",\"lisp-data\":\"lisp\",
    \"shell\":\"bash\",\"sh\":\"bash\",\"bash\":\"bash\",\"zsh\":\"bash\",
    \"js\":\"javascript\",\"ts\":\"typescript\",\"py\":\"python\",
    \"duckdb\":\"sql\",\"sqlite\":\"sql\",\"postgres\":\"sql\",\"postgresql\":\"sql\",
    \"conf\":\"ini\",\"text\":\"plaintext\",\"example\":\"plaintext\"
  };
  var codes=[];
  function detectLang(pre){
    if(pre.classList.contains('example'))return 'plaintext';
    var m=pre.className.match(/(?:^|\\s)src-([^\\s]+)/);
    return langMap[m?m[1]:'text']||(m?m[1]:'plaintext');
  }
  function copyText(text,done){
    if(navigator.clipboard&&navigator.clipboard.writeText){
      navigator.clipboard.writeText(text).then(done,function(){fallback();});
    }else{fallback();}
    function fallback(){
      var ta=document.createElement('textarea');
      ta.value=text;ta.setAttribute('readonly','');
      ta.style.position='fixed';ta.style.left='-9999px';
      document.body.appendChild(ta);ta.select();
      try{document.execCommand('copy');}catch(e){}
      document.body.removeChild(ta);done();
    }
  }
  blocks.forEach(function(pre){
    if(pre.dataset.orgMuseumCodeReady==='1')return;
    pre.dataset.orgMuseumCodeReady='1';
    pre.classList.add('org-museum-code-block','org-museum-code-collapsed');
    var lang=detectLang(pre);
    var code=null;
    Array.prototype.some.call(pre.children,function(el){
      if(el.tagName&&el.tagName.toLowerCase()==='code'){code=el;return true;}
      return false;
    });
    if(!code){
      code=document.createElement('code');
      code.innerHTML=pre.innerHTML;
      pre.innerHTML='';
      pre.appendChild(code);
    }
    code.classList.add('org-museum-code','language-'+lang);
    code.setAttribute('data-language',lang);
    if(lang!=='plaintext')codes.push(code);
    var lbl=document.createElement('span');lbl.className='code-lang-label';
    lbl.textContent=(lang==='plaintext'?'TEXT':lang).toUpperCase();
    var toggle=document.createElement('button');
    toggle.className='code-copy-btn code-toggle-btn';
    toggle.type='button';
    toggle.textContent='EXPAND';
    toggle.setAttribute('aria-expanded','false');
    toggle.onclick=function(){
      var expanded=pre.classList.toggle('org-museum-code-expanded');
      pre.classList.toggle('org-museum-code-collapsed',!expanded);
      toggle.textContent=expanded?'COLLAPSE':'EXPAND';
      toggle.setAttribute('aria-expanded',expanded?'true':'false');
    };
    var btn=document.createElement('button');btn.className='code-copy-btn';btn.textContent='COPY';
    btn.type='button';
    btn.onclick=function(){
      copyText(code.innerText||code.textContent,function(){
        btn.textContent='COPIED!';btn.classList.add('copied');
        setTimeout(function(){btn.textContent='COPY';btn.classList.remove('copied');},2000);
      });
    };
    pre.insertBefore(lbl,pre.firstChild);
    pre.insertBefore(toggle,lbl.nextSibling);
    pre.insertBefore(btn,toggle.nextSibling);
  });
  function runHighlight(){
    if(!window.hljs)return;
    codes.forEach(function(code){
      var lang=code.getAttribute('data-language')||'';
      if(!code.dataset.highlighted&&(!lang||hljs.getLanguage(lang))){
        hljs.highlightElement(code);
      }else if(lang&&!hljs.getLanguage(lang)){
        code.classList.add('no-highlight');
      }
    });
  }
  function loadScript(src,done,fail){
    var js=document.createElement('script');
    js.src=src;js.async=true;js.onload=done;
    js.onerror=fail||function(){document.body.classList.add('org-museum-no-code-highlight');};
    document.head.appendChild(js);
  }
  function runAfterLanguageModules(){
    if(window.hljs&&hljs.getLanguage('lisp'))runHighlight();
    else loadScript('%s',runHighlight,runHighlight);
  }
  if(window.hljs){runAfterLanguageModules();}
  else{
    var css=document.createElement('link');css.rel='stylesheet';
    css.href='%s';document.head.appendChild(css);
    loadScript('%s',runAfterLanguageModules);
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
  var btn=document.createElement('div');
  btn.className='desktop-sidebar-btn';
  btn.textContent='‹';
  btn.setAttribute('role','button');
  btn.setAttribute('tabindex','0');
  btn.setAttribute('aria-label','Toggle Sidebar');
  document.body.appendChild(btn);
  btn.addEventListener('keydown',function(e){
    if(e.key===' '||e.key==='Enter'){
      e.preventDefault();
      btn.click();
    }
  });
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
   (org-museum--hljs-lisp-js-src out-file)
   (org-museum--hljs-css-src out-file)
   (org-museum--hljs-js-src out-file)
   (org-museum--hljs-lisp-js-src out-file)))

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
  "Return script that moves, collapses, and filters the article TOC."
  "<script>
(function(){
function moveTOC(){
  var toc=document.getElementById('table-of-contents');
  var target=document.getElementById('org-museum-right-sidebar');
  if(!target||!toc)return false;
  var ul=toc.querySelector('ul');
  if(!ul)return false;
  var header=target.querySelector('.toc-sidebar-header');
  var tools=target.querySelector('.toc-search-tools');
  var empty=target.querySelector('[data-toc-empty]');
  Array.from(target.children).forEach(function(child){
    if(child!==header&&child!==tools&&child!==empty)child.remove();
  });
  target.appendChild(ul);
  ul.classList.add('museum-toc-tree');
  if(toc.parentNode)toc.parentNode.removeChild(toc);
  function openActiveBranch(active){
    target.querySelectorAll('li').forEach(function(item){item.classList.remove('toc-branch-open');});
    var item=active?active.closest('li'):null;
    while(item){item.classList.add('toc-branch-open');item=item.parentElement.closest('li');}
  }
  target.addEventListener('click',function(event){
    var link=event.target.closest('a[href^=\"#\"]');
    if(link)openActiveBranch(link);
  });
  target.addEventListener('museum:toc-active',function(event){
    openActiveBranch(event.target);
  });
  var input=target.querySelector('[data-toc-search]');
  var clear=target.querySelector('[data-toc-clear]');
  var countEl=target.querySelector('[data-toc-count]');
  function filterToc(){
    var query=input.value.trim().toLowerCase();
    target.classList.toggle('toc-is-searching',Boolean(query));
    var matches=0;
    target.querySelectorAll('.museum-toc-tree li').forEach(function(item){
      var own=Array.from(item.children).find(function(child){return child.tagName==='A';});
      var match=!query||(own&&own.textContent.toLowerCase().indexOf(query)>=0);
      item.classList.toggle('toc-search-match',Boolean(match&&query));
      item.hidden=Boolean(query)&&!match;
      if(own&&match)matches+=1;
    });
    if(query)target.querySelectorAll('li.toc-search-match').forEach(function(item){
      var parent=item.parentElement.closest('li');
      while(parent){parent.hidden=false;parent.classList.add('toc-branch-open');
        parent=parent.parentElement.closest('li');}
    });
    if(countEl)countEl.textContent='/ '+String(matches).padStart(2,'0');
    if(clear)clear.hidden=!query;
    if(empty)empty.hidden=matches>0;
  }
  if(input)input.addEventListener('input',filterToc);
  if(clear)clear.addEventListener('click',function(){
    input.value='';filterToc();input.focus();
  });
  openActiveBranch(target.querySelector('a.toc-active')||target.querySelector('a'));
  filterToc();
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
      c.querySelectorAll('li a').forEach(function(a){
        if(!a.dataset.origText) a.dataset.origText = a.textContent;
        var txt = a.dataset.origText;
        var idx = txt.toLowerCase().indexOf(t);
        var show = !t || idx >= 0;
        a.parentElement.style.display = show ? '' : 'none';
        if(show){
          visible=true;
          if(t){
            var pre = txt.substring(0, idx);
            var hl = txt.substring(idx, idx+t.length);
            var post = txt.substring(idx+t.length);
            a.innerHTML = pre + '<span class=\"search-highlight\">' + hl + '</span>' + post;
          }else{
            a.textContent = txt;
          }
        }
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

(defun org-museum--page-local-file-links (page pages)
  "Return external local file-link records found in PAGE.
PAGES is used to exclude links that resolve to another indexed Wiki page."
  (let ((source (org-museum-page-path page)) records)
    (when (file-readable-p source)
      (with-temp-buffer
        (insert-file-contents source)
        (org-mode)
        (let ((ast (org-element-parse-buffer)))
          (org-element-map ast 'link
            (lambda (link)
              (when (string= (org-element-property :type link) "file")
                (let* ((raw (or (org-element-property :path link) ""))
                       (path (url-unhex-string
                              (car (org-museum--file-link-parts raw))))
                       (target (expand-file-name
                                path (file-name-directory source)))
                       (internal (org-museum--find-page-by-expanded-path
                                  target pages)))
                  (unless internal
                    (push (list :page-id (org-museum-page-id page)
                                :source source
                                :raw raw
                                :path target
                                :exists (file-exists-p target))
                          records)))))))))
    (nreverse records)))

(defun org-museum--index-health-report (pages)
  "Return a plist of health indicators for PAGES hash-table.
Keys:
  :ghost    — list of IDs whose file no longer exists on disk
  :broken   — list of (from-id . missing-target-id) pairs
  :isolated — list of all IDs with no links in or out
  :draft    — list of IDs with status=draft
Applicable scope: org-museum-status, org-museum-index-verify, CI checks."
  (let (ghost broken isolated isolated-published isolated-draft draft
              missing-description local-external local-missing)
    (maphash
     (lambda (id page)
       (unless (file-exists-p (org-museum-page-path page))
         (push id ghost))
       (dolist (target-id (org-museum-page-links-to page))
         (unless (gethash target-id pages)
           (push (cons id target-id) broken)))
       (when (and (null (org-museum-page-links-to page))
                  (null (org-museum-page-linked-from page)))
         (push id isolated)
         (if (string= (downcase (or (org-museum-page-status page) "published"))
                      "draft")
             (push id isolated-draft)
           (push id isolated-published)))
       (when (string= (downcase (or (org-museum-page-status page) "published"))
                      "draft")
         (push id draft))
       (when (string-empty-p (string-trim
                              (or (org-museum-page-description page) "")))
         (push id missing-description))
       (dolist (record (org-museum--page-local-file-links page pages))
         (push record local-external)
         (unless (plist-get record :exists)
           (push record local-missing))))
     pages)
    (list :ghost ghost :broken broken :isolated isolated
          :isolated-published isolated-published
          :isolated-draft isolated-draft
          :draft draft
          :missing-description missing-description
          :local-external local-external
          :local-missing local-missing)))

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
      (insert (format "- Isolated Pages: %d  (published %d / draft %d)\n"
                      (length (plist-get health :isolated))
                      (length (plist-get health :isolated-published))
                      (length (plist-get health :isolated-draft))))
      (insert (format "- Draft Pages:    %d\n"
                      (length (plist-get health :draft))))
      (insert (format "- Missing Descriptions: %d\n"
                      (length (plist-get health :missing-description))))
      (insert (format "- External Local Files: %d\n"
                      (length (plist-get health :local-external))))
      (insert (format "- Missing Local Files:  %d\n"
                      (length (plist-get health :local-missing))))
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
        (insert "\n** Isolated Pages\n\n")
        (dolist (id (plist-get health :isolated))
          (when-let ((p (gethash id pages)))
            (insert (format "- [[museum:%s][%s]] (%s)\n"
                            id (org-museum-page-title p)
                            (or (org-museum-page-status p) "published"))))))

      (when (plist-get health :missing-description)
        (insert "\n** Missing Descriptions\n\n")
        (dolist (id (plist-get health :missing-description))
          (when-let ((p (gethash id pages)))
            (insert (format "- [[museum:%s][%s]] — add #+DESCRIPTION when useful\n"
                            id (org-museum-page-title p))))))

      (when (plist-get health :local-external)
        (insert "\n** External Local Files\n\n")
        (dolist (record (plist-get health :local-external))
          (insert (format "- =%s= → =%s= %s\n"
                          (plist-get record :page-id)
                          (plist-get record :path)
                          (if (plist-get record :exists) "✓" "✗ MISSING")))))

      (insert "\n* Quick Actions\n\n")
      (insert "- [[elisp:(org-museum-export-graph)][Generate Knowledge Graph]]\n")
      (insert "- [[elisp:(org-museum-index-build t)][Force Rebuild Index]]\n")
      (insert "- [[elisp:(org-museum-index-verify)][Verify & Repair Index]]\n")
      (insert "- [[elisp:(org-museum-check-links)][Check All Links]]\n")
      (insert "- [[elisp:(org-museum-export-all)][Export All Pages]]\n")

      (display-buffer (current-buffer)))))

;;;###autoload
;; ============================================================
;; §30  LATEX / PDF CODE HIGHLIGHTING
;; ============================================================

(defun org-museum--setup-latex-export ()
  "Configure ox-latex for code highlighting based on user preference.
Must be called after `org-museum-latex-code-highlight' is set.

When 'minted:
  - Sets `org-latex-listings' to 'minted
  - Adds the minted package to `org-latex-packages-alist'
  - Ensures -shell-escape is in the compilation command chain

When 'listings:
  - Sets `org-latex-listings' to t
  - Adds the listings and color packages

When nil:
  - Sets `org-latex-listings' to nil (verbatim output)"
  (require 'ox-latex)
  (pcase org-museum-latex-code-highlight
    ('minted
     (setq org-latex-listings 'minted)
     (cl-pushnew '("" "minted" t) org-latex-packages-alist :test #'equal)
     ;; Ensure -shell-escape in every PDF compilation step
     (setq org-latex-pdf-process
           (mapcar (lambda (cmd)
                     (if (string-match-p "-shell-escape" cmd)
                         cmd
                       (replace-regexp-in-string
                        "%latex " "%latex -shell-escape " cmd)))
                   (or org-latex-pdf-process
                       '("%latex -interaction nonstopmode -output-directory %o %f"
                         "%latex -interaction nonstopmode -output-directory %o %f"
                         "%latex -interaction nonstopmode -output-directory %o %f"))))
     (message "Org Museum [LaTeX]: minted highlighting configured"))
    ('listings
     (setq org-latex-listings t)
     (cl-pushnew '("" "listings" nil) org-latex-packages-alist :test #'equal)
     (cl-pushnew '("" "color" nil)    org-latex-packages-alist :test #'equal)
     (message "Org Museum [LaTeX]: listings highlighting configured"))
    (_
     (setq org-latex-listings nil)
     (message "Org Museum [LaTeX]: no code highlighting"))))

(defun org-museum-init (root-dir)
  "Initialise an Org Museum workspace at ROOT-DIR."
  (interactive "DSelect Org Museum Root: ")
  (setq org-museum-root-dir (expand-file-name root-dir))
  (dolist (dir (list "pages" "themes" "exports/html" "exports/html/resources"
                     org-museum-pages-subdir))
    (make-directory (expand-file-name dir org-museum-root-dir) t))
  (org-museum--ensure-css-deployed)
  (org-museum--setup-latex-export)
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
