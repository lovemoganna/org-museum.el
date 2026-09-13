;;; org-museum.el --- Org Mode Wiki Generator -*- lexical-binding: t -*-

;; Copyright (C) 2026
;; Version: 2.4.2
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
(require 'seq)
(require 'subr-x)
(require 'url-util)

;; ============================================================
;; §1  CONSTANTS
;; ============================================================

(defconst org-museum--graph-palette
  ["var(--museum-category-1)" "var(--museum-category-2)"
   "var(--museum-category-3)" "var(--museum-category-4)"
   "var(--museum-category-5)" "var(--museum-category-6)"
   "var(--museum-category-7)"]
  "Shared semantic category colours for every reading view.")

(defconst org-museum--index-schema-version 5
  "Version of the persisted index and parsing/link-resolution rules.")

(defconst org-museum--publish-manifest-name
  ".org-museum-publish-manifest.json"
  "Relative manifest name used to track files managed in a publish checkout.")

(defconst org-museum--publish-status-name
  ".org-museum-publish-status.json"
  "Relative status file that gates deployment of a publish checkout.")

(defconst org-museum--publish-privacy-buffer
  "*Org Museum Privacy Report*"
  "Buffer used for local-only publish privacy findings.")

(defconst org-museum--publish-full-preview-buffer
  "*Org Museum Full Sync Preview*"
  "Buffer used to review a configurable raw publication mirror.")

(defconst org-museum--publish-full-confirmation "COPY PRIVATE EXPORTS"
  "Exact confirmation required before installing a raw publication mirror.")

(define-error 'org-museum-publish-error
  "Org Museum publish stopped"
  'user-error)

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

(defcustom org-museum-publish-directory nil
  "Local Git working directory used to publish the exported static site.
This directory must be outside `org-museum-root-dir' and its export tree."
  :type '(choice (const :tag "Not configured" nil) directory)
  :group 'org-museum)

(defcustom org-museum-publish-repository nil
  "GitHub repository receiving the published site, as OWNER/REPOSITORY."
  :type '(choice (const :tag "Not configured" nil) string)
  :group 'org-museum)

(defcustom org-museum-publish-branch "main"
  "Git branch used as the GitHub Pages publishing source."
  :type 'string
  :group 'org-museum)

(defcustom org-museum-publish-remote "origin"
  "Git remote used by `org-museum-publish-deploy'."
  :type 'string
  :group 'org-museum)

(defcustom org-museum-publish-policy-file
  (expand-file-name "org-museum-publish-policy.json" user-emacs-directory)
  "Local JSON policy controlling full-sync scope and explicit authorisations.
This file is never copied into the publish checkout."
  :type 'file
  :group 'org-museum)

(defcustom org-museum-scan-dir nil
  "Subdirectory to scan for .org files.  nil means entire root."
  :type '(choice (const nil) string)
  :group 'org-museum)

(defcustom org-museum-curation-mode 'protocol
  "How trusted local exports hand curation requests back to Emacs.
`protocol' opens a review buffer through org-protocol.  `loopback' enables
the authenticated local preview/apply API after the server is started.
nil disables web curation entirely."
  :type '(choice (const :tag "Disabled" nil)
                 (const :tag "org-protocol review" protocol)
                 (const :tag "Authenticated loopback API" loopback))
  :group 'org-museum)

(defcustom org-museum-curation-port 0
  "Preferred loopback curation port, or 0 to choose a random free port."
  :type 'integer
  :group 'org-museum)

(defcustom org-museum-curation-backup-directory
  (expand-file-name "org-museum-curation-backups" user-emacs-directory)
  "Persistent backup directory used before an approved curation write.
The resolved directory must be outside `org-museum-root-dir'."
  :type 'directory
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
  "When non-nil, open the selected page after a successful full export."
  :type 'boolean
  :group 'org-museum)

(defcustom org-museum-open-page-after-export 'index
  "Page to open after a successful full export.
This setting is consulted only when
`org-museum-open-browser-after-export' is non-nil."
  :type '(choice (const :tag "Wiki index" index)
                 (const :tag "Chronological reading" timeline)
                 (const :tag "Knowledge graph" graph)
                 (const :tag "Do not open a page" nil))
  :group 'org-museum)

(defcustom org-museum-auto-reload-before-export t
  "Whether export commands reload a newer authoritative package source.
The comparison uses SHA-256 content digests, so timestamp-only changes do not
reload the package.  A failed reload aborts before export state is changed."
  :type 'boolean
  :group 'org-museum)

(defcustom org-museum-default-language "zh-CN"
  "Default HTML language for pages without an explicit #+LANGUAGE keyword."
  :type 'string
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

(defcustom org-museum-article-max-width 960
  "Maximum desktop article width in CSS pixels.
The exporter writes this value as a page-local CSS custom property so the
bundled responsive layout can preserve the configured reading measure."
  :type 'integer
  :group 'org-museum)

(defcustom org-museum-background-effects-enabled t
  "When non-nil, export the optional background-effects controls.
Effects still start disabled and must be enabled explicitly by the reader."
  :type 'boolean
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

(defcustom org-museum-graph-exclude-orphans nil
  "When non-nil, exclude orphan nodes (degree == 0) from the global graph.

The default is nil so every indexed page remains discoverable.  Set this to
non-nil only when a deliberately relationship-only graph is preferred;
individual low-value pages can instead use an explicit `:no-graph:' tag."
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
Applicable scope: project-wide `org-museum--on-save' debounce."
  :type 'number
  :group 'org-museum)

(defcustom org-museum-code-highlight-method 'hljs
  "Code highlighting method for HTML export.
`hljs'        — Use Highlight.js (client-side, recommended).
               Code blocks are exported plain; hljs runs in the browser.
               Provides broad language coverage (SQL, Python, Rust, etc.)
               and a consistent look regardless of Emacs theme.
`inline-css'  — Use htmlize with inline CSS (server-side).
               Emacs theme colours are baked into each <span style=\"...\">,
               so SQL keywords match exactly what the Emacs buffer shows.
`css-classes' — Use htmlize with CSS class names.
               Generates <span class=\"org-keyword\"> and an accompanying
               <style> block.  Useful when you supply a custom stylesheet."
  :type '(choice (const :tag "Highlight.js (推荐)" hljs)
                 (const :tag "Emacs 内联样式" inline-css)
                 (const :tag "CSS 类名 + 样式表" css-classes))
  :group 'org-museum)

(defcustom org-museum-latex-code-highlight 'minted
  "Code highlighting method for LaTeX/PDF export.
`minted'   — Use the minted package (requires Python + Pygments).
            Produces high-quality coloured output with many languages.
`listings' — Use the listings package (pure LaTeX, no external deps).
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

(defvar org-museum--loaded-source-path nil
  "Source file whose definitions are currently loaded.")

(defvar org-museum--loaded-source-hash nil
  "SHA-256 digest captured when `org-museum--loaded-source-path' was loaded.")

(defvar org-museum--runtime-refresh-in-progress nil
  "Non-nil while an export command is re-entered after a runtime refresh.")

(defvar org-museum--full-export-in-progress nil
  "Non-nil while a full export defers shared relationship and timeline
regeneration.")

(setq org-museum--loaded-source-path
      (let* ((loaded (or load-file-name (locate-library "org-museum")))
             (source (and loaded
                          (if (string-suffix-p ".elc" loaded)
                              (concat (file-name-sans-extension loaded) ".el")
                            loaded))))
        (and source (expand-file-name source))))

;; Reloads can move the authoritative runtime from a Straight cache to a
;; workspace checkout.  Do not retain the resource directory cached by the
;; previously loaded copy.
(setq org-museum--plugin-dir
      (and org-museum--loaded-source-path
           (file-name-directory org-museum--loaded-source-path)))

(defvar org-museum--project-save-timer nil
  "Single debounce timer shared by saves in the active Museum project.")

(defvar org-museum--project-save-retry-used nil
  "Non-nil after the current pending save batch used its one automatic retry.")

(defvar org-museum--pending-save-files (make-hash-table :test #'equal)
  "Set of Org files awaiting one transactional index flush.")

(defvar org-museum--org-roam-db-connection nil
  "Dynamically bound read-only Org-roam SQLite connection for an index batch.")

;; ============================================================
;; §4  DATA STRUCTURES
;; ============================================================

(cl-defstruct org-museum-page
  "Single wiki page."
  id title path tags category created date-source modified
  links-to linked-from relation-types relation-diagnostics
  theme status description)

(cl-defstruct org-museum-index
  "Full wiki index."
  pages        ; hash-table id -> page
  tags         ; hash-table tag -> (id ...)
  categories   ; hash-table cat -> (id ...)
  graph)       ; hash-table (reserved)

(cl-defstruct org-museum-publish-finding
  "One local-only privacy finding in an exported publication candidate."
  file relative source line column kind match excerpt suggestion)

(cl-defstruct org-museum-publish-candidate
  "A sanitised publication candidate ready for transactional installation."
  files blocked state)

(define-error 'org-museum-duplicate-page-id
  "Duplicate Org Museum page ID")
(define-error 'org-museum-index-scan-failed
  "Org Museum index scan failed")
(define-error 'org-museum-export-failed
  "Org Museum full export failed")
(define-error 'org-museum-invalid-page-status
  "Invalid Org Museum page status")

;; ============================================================
;; §5  PATH HELPERS
;; ============================================================

(defun org-museum--plugin-dir ()
  "Return the directory containing org-museum.el."
  (or org-museum--plugin-dir
      (setq org-museum--plugin-dir
            (let* ((load-dir (when load-file-name
                               (file-name-directory load-file-name)))
                   (lib-dir  (when-let* ((lib (locate-library "org-museum")))
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

(defun org-museum--theme-resource-path ()
  "Absolute path to the shared blocking theme bootstrap."
  (expand-file-name "resources/org-museum-theme.js"
                    (org-museum--shared-root)))

(defun org-museum--related-data-resource-path ()
  "Return the generated offline relationship-reading data path."
  (expand-file-name "resources/org-museum-related-data.js"
                    (org-museum--shared-root)))

(defun org-museum--related-output-path ()
  "Return the public relationship-reading page path."
  (expand-file-name "related.html" (org-museum--shared-root)))

(defun org-museum--timeline-output-path ()
  "Return the public chronological-reading page path."
  (expand-file-name "timeline.html" (org-museum--shared-root)))

(defconst org-museum--font-resources
  '(("NotoSansCJKsc-VF-v2.004.woff2" . "Noto Sans SC 2.004 variable font")
    ("NotoSerifCJKsc-VF.woff2" . "Noto Serif CJK SC variable font")
    ("VictorMono-Roman-v1.564.woff2" . "Victor Mono 1.564 variable Roman")
    ("VictorMono-Italic-v1.564.woff2" . "Victor Mono 1.564 variable Italic")
    ("OFL-Noto-Sans-CJK.txt" . "Noto Sans CJK OFL license")
    ("OFL-Victor-Mono.txt" . "Victor Mono OFL license")
    ("SHA256SUMS" . "font SHA-256 manifest")
    ("SOURCES.md" . "font provenance record"))
  "Bundled font files required for every offline export.")

(defconst org-museum--icon-resources
  '("book-open.svg" "clock.svg" "file-text.svg" "graph.svg" "list.svg"
    "magnifying-glass.svg" "moon.svg" "sun.svg" "plus.svg" "minus.svg"
    "corners-out.svg" "crosshair.svg" "rows.svg" "LICENSE")
  "Phosphor icon files required for the offline reading shell.")

(defun org-museum--font-resource-path (name)
  "Return the deployed font resource path for NAME."
  (expand-file-name (concat "resources/fonts/" name)
                    (org-museum--shared-root)))

(defun org-museum--icon-resource-path (name)
  "Return the deployed icon resource path for NAME."
  (expand-file-name (concat "resources/icons/" name)
                    (org-museum--shared-root)))

(defun org-museum--file-content-hash (file)
  "Return the SHA-256 digest of regular FILE, or nil when unavailable."
  (when (and file (file-regular-p file))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (secure-hash 'sha256 (current-buffer)))))

(setq org-museum--loaded-source-hash
      (org-museum--file-content-hash org-museum--loaded-source-path))

(defun org-museum--files-have-same-content-p (left right)
  "Return non-nil when existing files LEFT and RIGHT have identical contents."
  (and (file-exists-p left)
       (file-exists-p right)
       (= (file-attribute-size (file-attributes left))
          (file-attribute-size (file-attributes right)))
       (string= (org-museum--file-content-hash left)
                (org-museum--file-content-hash right))))

(defun org-museum--versioned-resource-href (path out-file)
  "Return PATH relative to OUT-FILE with a content-version query.
The stable digest makes refreshed exports visible in an already-open browser
without sacrificing file:// or offline operation."
  (when-let* ((digest (and path (org-museum--file-content-hash path))))
    (format "%s?v=%s"
            (org-museum--relative-path path out-file)
            (substring digest 0 12))))

(defun org-museum--runtime-resource-path (kind)
  "Return the exported shared runtime path for page KIND."
  (expand-file-name
   (format "resources/org-museum-%s.js" (symbol-name kind))
   (org-museum--shared-root)))

(defun org-museum--write-content-if-changed (file content)
  "Write CONTENT to FILE only when its bytes differ."
  (let ((current
         (when (file-regular-p file)
           (with-temp-buffer
             (insert-file-contents file)
             (buffer-string)))))
    (unless (equal current content)
      (make-directory (file-name-directory file) t)
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-file file (insert content))))
    file))

(defun org-museum--externalize-page-runtime (html out-file kind)
  "Move executable inline scripts in HTML to KIND's shared runtime asset.
Structured JSON data and already external scripts remain in HTML.  Return the
rewritten document with a content-versioned local script reference."
  (with-temp-buffer
    (insert html)
    (goto-char (point-min))
    (let (chunks)
      (while (re-search-forward
              (rx "<script" (group (* (not ?>))) ?>) nil t)
        (let ((attrs (match-string-no-properties 1))
              (open-beg (match-beginning 0))
              (content-beg (match-end 0)))
          (when (search-forward "</script>" nil t)
            (let ((close-end (point))
                  (content-end (match-beginning 0)))
              (unless (or (string-match-p
                           "[[:space:]]src[[:space:]]*=" attrs)
                          (string-match-p "application/json" attrs))
                (push (buffer-substring-no-properties content-beg content-end)
                      chunks)
                (delete-region open-beg close-end)
                (goto-char open-beg))))))
      (when chunks
        (let* ((runtime (org-museum--runtime-resource-path kind))
               (content (concat
                         "/* Generated by Org Museum; shared by exported pages. */\n"
                         (mapconcat #'identity (nreverse chunks) "\n;\n")
                         "\n")))
          (org-museum--write-content-if-changed runtime content)
          (goto-char (point-max))
          (unless (re-search-backward "</body>" nil t)
            (error "Org Museum cannot attach the %s runtime: </body> missing"
                   kind))
          (insert
           (format "<script defer src=\"%s\"></script>\n"
                   (org-museum--html-escape
                    (org-museum--versioned-resource-href runtime out-file) t)))))
      (buffer-string))))

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
                   (equal (file-name-nondirectory pointer)
                          (file-name-nondirectory source))
                   (not (equal (org-museum--normalised-path pointer)
                               (org-museum--normalised-path source))))
              (when (file-regular-p pointer)
                (expand-file-name pointer))
            source))
      source)))

(defun org-museum--canonical-elisp-source-path ()
  "Return the authoritative org-museum.el source file.
Manual installations keep their loaded workspace authoritative.  When the
loaded file belongs to Straight's repository, link tree, or build tree, prefer
the repository and link-tree sources over the generated build copy."
  (let* ((repo (expand-file-name
                "straight/repos/org-museum.el/org-museum.el"
                user-emacs-directory))
         (links (expand-file-name
                 "straight/links/org-museum/org-museum.el"
                 user-emacs-directory))
         (build (expand-file-name
                 "straight/build/org-museum/org-museum.el"
                 user-emacs-directory))
         (loaded org-museum--loaded-source-path)
         (straight-managed-p
          (and loaded
               (cl-some
                (lambda (dir) (file-in-directory-p loaded dir))
                (list (file-name-directory repo)
                      (file-name-directory links)
                      (file-name-directory build)))))
         (candidates (delete-dups
                       (delq nil
                             (if straight-managed-p
                                 (list repo links build loaded)
                               (list loaded repo links build)))))
         resolved)
    (while (and candidates (not resolved))
      (let ((candidate
             (org-museum--resolve-resource-source (pop candidates))))
        (when (and candidate (file-regular-p candidate))
          (setq resolved (expand-file-name candidate)))))
    resolved))

(defun org-museum--runtime-source-status ()
  "Return loaded and authoritative runtime source provenance."
  (let* ((canonical (org-museum--canonical-elisp-source-path))
         (canonical-hash (org-museum--file-content-hash canonical))
         (loaded-hash org-museum--loaded-source-hash))
    (list :loaded org-museum--loaded-source-path
          :loaded-hash loaded-hash
          :canonical canonical
          :canonical-hash canonical-hash
          :in-sync (and loaded-hash canonical-hash
                        (string= loaded-hash canonical-hash)))))

;;;###autoload
(defun org-museum-reload ()
  "Reload the authoritative org-museum.el source and verify its digest."
  (interactive)
  (let* ((before (org-museum--runtime-source-status))
         (source (plist-get before :canonical))
         (expected (plist-get before :canonical-hash)))
    (unless (and source expected)
      (error "Org Museum runtime source is missing"))
    (load source nil t t)
    (let ((after (org-museum--runtime-source-status)))
      (unless (and (plist-get after :in-sync)
                   (string= expected (plist-get after :loaded-hash)))
        (error "Org Museum runtime reload verification failed"))
      (message "Org Museum runtime reloaded: %s" source)
      t)))

(defun org-museum--run-with-current-runtime (command args thunk)
  "Run THUNK or refresh the runtime and re-enter COMMAND with ARGS."
  (let ((status (org-museum--runtime-source-status)))
    (if (and org-museum-auto-reload-before-export
             (not org-museum--runtime-refresh-in-progress)
             (not (plist-get status :in-sync)))
        (let ((org-museum--runtime-refresh-in-progress t))
          (org-museum-reload)
          (apply command args))
      (funcall thunk))))

(defun org-museum--resource-source-path (relative-path)
  "Return the authoritative package resource for RELATIVE-PATH.
When Straight keeps both a repository checkout and a stale build copy, the
repository wins.  Link-tree placeholders are dereferenced before testing the
candidate.  A manually loaded workspace remains authoritative; legacy roam
locations remain fallbacks for other non-Straight installations."
  (let* ((repo-dir (expand-file-name "straight/repos/org-museum.el/"
                                    user-emacs-directory))
         (links-dir (expand-file-name "straight/links/org-museum/"
                                     user-emacs-directory))
         (build-dir (expand-file-name "straight/build/org-museum/"
                                     user-emacs-directory))
         (plugin-dir (org-museum--plugin-dir))
         (roam-dir (expand-file-name "org-roam/" user-emacs-directory))
         (managed-plugin-p
          (cl-some (lambda (dir)
                     (file-in-directory-p (expand-file-name plugin-dir)
                                          (expand-file-name dir)))
                   (list repo-dir links-dir build-dir)))
         (candidates (delete-dups
                      (delq nil
                            (if managed-plugin-p
                                (list repo-dir links-dir plugin-dir build-dir roam-dir)
                              (list plugin-dir repo-dir links-dir build-dir roam-dir)))))
         resolved)
    (while (and candidates (not resolved))
      (let ((candidate
             (org-museum--resolve-resource-source
              (expand-file-name relative-path (pop candidates)))))
        (when (and candidate (file-regular-p candidate))
          (setq resolved candidate))))
    (or resolved
        (org-museum--resolve-resource-source
         (expand-file-name relative-path plugin-dir)))))

(defun org-museum--deploy-bundled-resource (relative-path dest label)
  "Deploy bundled RELATIVE-PATH to DEST and return DEST.
LABEL names the asset in diagnostics.  Missing assets fail closed; Org Museum
never downloads runtime code during export."
  (let ((bundled (org-museum--resource-source-path relative-path)))
    (unless (and bundled (file-regular-p bundled))
      (error "Org Museum bundled resource missing: %s (%s)"
             label relative-path))
    (make-directory (file-name-directory dest) t)
    (unless (or (equal (expand-file-name bundled) (expand-file-name dest))
                (org-museum--files-have-same-content-p bundled dest))
      (copy-file bundled dest t))
    dest))

(defun org-museum--ensure-d3-deployed ()
  "Ensure D3.js is available locally under shared export resources."
  (org-museum--deploy-bundled-resource
   "resources/d3.v7.min.js" (org-museum--d3-resource-path) "D3.js"))

(defun org-museum--ensure-theme-deployed ()
  "Ensure the shared theme bootstrap is available locally."
  (org-museum--deploy-bundled-resource
   "resources/org-museum-theme.js"
   (org-museum--theme-resource-path)
   "theme bootstrap"))

(defvar org-museum--resource-deployment-cache nil
  "Dynamically bound per-export cache for deployed static resources.")

(defun org-museum--ensure-fonts-deployed ()
  "Deploy every licensed offline font resource, failing closed if one is absent."
  (let ((deploy
         (lambda ()
           (mapcar
            (lambda (entry)
              (org-museum--deploy-bundled-resource
               (concat "resources/fonts/" (car entry))
               (org-museum--font-resource-path (car entry))
               (cdr entry)))
            org-museum--font-resources))))
    (if (not (hash-table-p org-museum--resource-deployment-cache))
        (funcall deploy)
      (let* ((missing (make-symbol "missing"))
             (cached (gethash 'fonts org-museum--resource-deployment-cache
                              missing)))
        (if (not (eq cached missing))
            cached
          (let ((assets (funcall deploy)))
            (puthash 'fonts assets org-museum--resource-deployment-cache)
            assets))))))

(defun org-museum--ensure-icons-deployed ()
  "Deploy the licensed Phosphor subset used by the shared shell."
  (mapcar
   (lambda (name)
     (org-museum--deploy-bundled-resource
      (concat "resources/icons/" name)
      (org-museum--icon-resource-path name)
      (format "Phosphor icon %s" name)))
   org-museum--icon-resources))

(defun org-museum--ensure-hljs-deployed ()
  "Ensure bundled Highlight.js assets are available locally."
  (list
   :css (org-museum--deploy-bundled-resource
         "resources/highlight.monokai.min.css"
         (org-museum--hljs-css-resource-path)
         "Highlight.js CSS")
   :js  (org-museum--deploy-bundled-resource
         "resources/highlight.min.js"
         (org-museum--hljs-js-resource-path)
         "Highlight.js script")
   :lisp-js (org-museum--deploy-bundled-resource
             "resources/highlight-lisp.min.js"
              (org-museum--hljs-lisp-js-resource-path)
              "Highlight.js Lisp language module")))

(defun org-museum--hljs-assets ()
  "Return deployed Highlight.js assets, cached within a full export batch."
  (if (not (hash-table-p org-museum--resource-deployment-cache))
      (org-museum--ensure-hljs-deployed)
    (let* ((missing (make-symbol "missing"))
           (cached (gethash 'highlight-js
                            org-museum--resource-deployment-cache missing)))
      (if (not (eq cached missing))
          cached
        (let ((assets (org-museum--ensure-hljs-deployed)))
          (puthash 'highlight-js assets org-museum--resource-deployment-cache)
          assets)))))

(defun org-museum--hljs-src-from-assets (assets key out-file)
  "Return versioned KEY from deployed Highlight.js ASSETS for OUT-FILE."
  (when-let* ((path (plist-get assets key)))
    (org-museum--versioned-resource-href path out-file)))

(defun org-museum--hljs-css-src (out-file)
  "Return the deployed Highlight.js CSS path relative to OUT-FILE.
Return nil instead of emitting a remote URL when deployment is unavailable."
  (org-museum--hljs-src-from-assets
   (org-museum--hljs-assets) :css out-file))

(defun org-museum--hljs-js-src (out-file)
  "Return the deployed Highlight.js script path relative to OUT-FILE.
Return nil instead of emitting a remote URL when deployment is unavailable."
  (org-museum--hljs-src-from-assets
   (org-museum--hljs-assets) :js out-file))

(defun org-museum--hljs-lisp-js-src (out-file)
  "Return the deployed Highlight.js Lisp module path relative to OUT-FILE.
Return nil instead of emitting a remote URL when deployment is unavailable."
  (org-museum--hljs-src-from-assets
   (org-museum--hljs-assets) :lisp-js out-file))

(defun org-museum--d3-js-src (out-file)
  "Return the deployed D3.js path relative to OUT-FILE, or nil.
Exported pages never fall back to a remote resource."
  (let ((local (org-museum--ensure-d3-deployed)))
    (when (and out-file local (file-exists-p local))
      (org-museum--versioned-resource-href local out-file))))

(defun org-museum--theme-script-tag (out-file)
  "Return the blocking, content-versioned theme script tag for OUT-FILE."
  (let ((local (org-museum--ensure-theme-deployed)))
    (format "<script src=\"%s\"></script>"
            (org-museum--html-escape
             (org-museum--versioned-resource-href local out-file) t))))

(defun org-museum--shared-root ()
  "Absolute path to shared export root."
  (expand-file-name org-museum-shared-export-dir org-museum-root-dir))
(defun org-museum--pages-root ()
  "Absolute path to per-page export root."
  (expand-file-name org-museum-export-dir org-museum-root-dir))

(defun org-museum--scan-root ()
  "Absolute path to the .org scan root."
  (expand-file-name (or org-museum-scan-dir "") org-museum-root-dir))

(defun org-museum--scan-files ()
  "Return the complete, de-duplicated set of Org files used by the index."
  (let* ((scan-root (file-name-as-directory (org-museum--scan-root)))
         (project-root (file-name-as-directory
                        (expand-file-name org-museum-root-dir)))
         (dirs (cond
                ((file-in-directory-p scan-root project-root)
                 (list project-root))
                ((file-in-directory-p project-root scan-root)
                 (list scan-root))
                (t (list scan-root project-root))))
        (seen (make-hash-table :test #'equal))
        files)
    (dolist (dir dirs)
      (when (file-directory-p dir)
        (dolist (file (directory-files-recursively dir "\\.org\\'"))
          (let ((key (org-museum--normalised-path file)))
            (unless (gethash key seen)
              (puthash key t seen)
              (push (expand-file-name file) files))))))
    (sort files #'string-lessp)))

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
  (org-museum--resource-source-path org-museum-css-file))

(defun org-museum--css-output-path ()
  "Absolute path of the deployed CSS file."
  (expand-file-name org-museum-css-file (org-museum--shared-root)))

(defun org-museum--css-deployment-status ()
  "Return source/output paths and SHA-256 deployment state for the CSS."
  (let* ((source (org-museum--css-source-path))
         (output (org-museum--css-output-path))
         (source-hash (org-museum--file-content-hash source))
         (output-hash (org-museum--file-content-hash output)))
    (list :source source
          :output output
          :source-hash source-hash
          :output-hash output-hash
          :in-sync (and source-hash output-hash
                        (string= source-hash output-hash)))))

(defun org-museum--relative-path (target from-file)
  "Return TARGET path relative to the directory of FROM-FILE, forward-slashed."
  (replace-regexp-in-string
   "\\\\" "/"
   (file-relative-name (expand-file-name target)
                       (file-name-directory (expand-file-name from-file)))))

(defun org-museum--css-link-tag (from-out-file)
  "Return <link> tag for CSS, relative to FROM-OUT-FILE."
  (let ((path (org-museum--css-output-path)))
    (format "<link rel=\"stylesheet\" href=\"%s\">"
            (or (org-museum--versioned-resource-href path from-out-file)
                (org-museum--relative-path path from-out-file)))))

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

(defun org-museum--page-created-number (page)
  "Return PAGE creation time as a sortable number."
  (let ((value (org-museum-page-created page)))
    (if (numberp value) value (org-museum--page-modified-number page))))

(defun org-museum--format-page-created-date (page &optional dotted)
  "Return PAGE creation date in ISO or DOTTED form."
  (format-time-string
   (if dotted "%Y.%m.%d" "%Y-%m-%d")
   (seconds-to-time (org-museum--page-created-number page))))

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

(defun org-museum--fallback-selected-headlines (ast info)
  "Return export-selected headlines using stable Org element data."
  (let* ((select-tags (cl-mapcan (lambda (tag) (org-tags-expand tag t))
                                 (plist-get info :select-tags)))
           (filetags (plist-get info :filetags))
           (all (org-element-map ast 'headline #'identity))
           selected)
    (cond
     ((cl-some (lambda (tag) (member tag select-tags)) filetags) all)
     (t
      (dolist (headline all)
        (when (cl-some (lambda (tag) (member tag select-tags))
                       (org-element-property :tags headline))
          (dolist (datum (cons headline (org-element-lineage headline)))
            (when (eq (org-element-type datum) 'headline)
              (cl-pushnew datum selected :test #'eq)))
          (org-element-map headline 'headline
            (lambda (child) (cl-pushnew child selected :test #'eq)))))
      selected))))

(defun org-museum--export-selected-headlines (ast info)
  "Return selected export headlines from AST using a compatibility boundary."
  (if (fboundp 'org-export--selected-trees)
      (condition-case nil
          (org-export--selected-trees ast info)
        (wrong-number-of-arguments
         (org-museum--fallback-selected-headlines ast info)))
    (org-museum--fallback-selected-headlines ast info)))

(defun org-museum--fallback-skip-headline-p (headline info selected excluded)
  "Compatibility implementation of Org headline export exclusion."
  (let ((tags (org-export-get-tags headline info nil t))
          (with-tasks (plist-get info :with-tasks))
          (todo (org-element-property :todo-keyword headline))
          (todo-type (org-element-property :todo-type headline)))
    (or (cl-some (lambda (tag) (member tag excluded)) tags)
        (and selected (not (memq headline selected)))
        (org-element-property :commentedp headline)
        (and (not (plist-get info :with-archived-trees))
             (org-element-property :archivedp headline))
        (and todo
             (or (not with-tasks)
                 (and (memq with-tasks '(todo done))
                      (not (eq todo-type with-tasks)))
                 (and (consp with-tasks)
                      (not (member todo with-tasks))))))))

(defun org-museum--export-skip-headline-p (headline info selected excluded)
  "Return non-nil when HEADLINE should be omitted from export.
Private Org exporter behavior is isolated here; the fallback covers the public
headline options used by supported bundled Org versions."
  (if (fboundp 'org-export--skip-p)
      (condition-case nil
          (org-export--skip-p headline info selected excluded)
        (wrong-number-of-arguments
         (org-museum--fallback-skip-headline-p
          headline info selected excluded)))
    (org-museum--fallback-skip-headline-p
     headline info selected excluded)))

(defun org-museum--exportable-headline-p (headline info selected excluded)
  "Return non-nil when HEADLINE and its ancestors survive Org export."
  (cl-every
   (lambda (datum)
     (or (not (eq (org-element-type datum) 'headline))
         (not (org-museum--export-skip-headline-p
               datum info selected excluded))))
   (cons headline (org-element-lineage headline))))

(defun org-museum--source-heading-inventory (page)
  "Return canonical export-aware H2--H4 heading records for PAGE."
  (let ((file (org-museum-page-path page))
        (occurrences (make-hash-table :test 'equal))
        inventory)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (delay-mode-hooks (org-mode))
        (let* ((ast (org-element-parse-buffer))
               (info (org-export-get-environment 'html))
               (selected (org-museum--export-selected-headlines ast info))
               (excluded (plist-get info :exclude-tags)))
          (org-element-map ast 'headline
            (lambda (headline)
              (let ((level (org-element-property :level headline)))
                (when (and (<= level 3)
                           (org-museum--exportable-headline-p
                            headline info selected excluded))
                  (goto-char (org-element-property :begin headline))
                  (let* ((title (org-get-heading t t t t))
                         (custom (or (org-entry-get nil "CUSTOM_ID")
                                     (org-entry-get nil "ID")))
                         (path (org-get-outline-path t t))
                         (path-key (mapconcat #'identity path "\0"))
                         (occurrence
                          (1+ (gethash path-key occurrences 0)))
                         (id (or custom
                                 (concat "section-"
                                         (substring
                                          (secure-hash
                                           'sha1
                                           (format "%s\0%s\0%d"
                                                   (org-museum-page-id page)
                                                   path-key occurrence))
                                          0 12)))))
                    (puthash path-key occurrence occurrences)
                    (push (list :id id :title title :level (1+ level)
                                :path (mapconcat #'identity path " / ")
                                :occurrence occurrence)
                          inventory))))))))
    (nreverse inventory))))

(defun org-museum--source-headings (page)
  "Return public heading metadata parsed from PAGE's exportable Org source."
  (mapcar (lambda (heading)
            `((id . ,(plist-get heading :id))
              (title . ,(plist-get heading :title))
              (level . ,(plist-get heading :level))))
          (org-museum--source-heading-inventory page)))

(defun org-museum--pp-stabilize-heading-anchors (org-file)
  "Replace transient Org heading anchors using ORG-FILE metadata.
Only exported H2--H4 headings are rewritten.  Same-document fragment links and
Org outline-container IDs follow the stable heading ID."
  (when-let* ((page (org-museum--page-for-file org-file))
              (headings (org-museum--source-headings page)))
    (let (rewrites)
      (goto-char (point-min))
      (while (and headings
                  (re-search-forward
                   "<h[2-4][^>]*\\bid=\"\\([^\"]+\\)\"" nil t))
        (let* ((old-id (match-string-no-properties 1))
               (heading (pop headings))
               (stable-id (alist-get 'id heading)))
          (unless (equal old-id stable-id)
            (replace-match stable-id t t nil 1)
            (push (cons old-id stable-id) rewrites))))
      (dolist (rewrite rewrites)
        (let ((old-id (car rewrite))
              (stable-id (cdr rewrite)))
          (dolist (pair
                   (list
                    (cons (concat "href=\"#" old-id)
                          (concat "href=\"#" stable-id))
                    (cons (concat "id=\"outline-container-" old-id)
                          (concat "id=\"outline-container-" stable-id))))
            (goto-char (point-min))
            (while (search-forward (car pair) nil t)
              (replace-match (cdr pair) t t))))))))

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
    (description . ,(or (org-museum-page-description page) ""))
    (tags . ,(vconcat (org-museum-page-tags page)))
    (status . ,(downcase (or (org-museum-page-status page) "published")))
    (headings . ,(vconcat (org-museum--page-headings page)))
    (created . ,(org-museum--page-created-number page))
    (createdDate . ,(org-museum--format-page-created-date page))
    (dateSource . ,(symbol-name (or (org-museum-page-date-source page)
                                    'modified-fallback)))
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
  "Copy source CSS to the export directory when its content differs."
  (org-museum--ensure-fonts-deployed)
  (org-museum--ensure-icons-deployed)
  (let ((src (org-museum--css-source-path))
        (dst (org-museum--css-output-path)))
    (when (and src (file-exists-p src))
      (make-directory (file-name-directory dst) t)
      (when (or (not (file-exists-p dst))
                (not (org-museum--files-have-same-content-p src dst)))
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
  (let (failures)
    (dolist (file (org-museum--scan-files))
      (condition-case err
          (when-let* ((page (org-museum--parse-page-metadata file)))
            (org-museum--index-register-page index page))
        (org-museum-duplicate-page-id
         (signal (car err) (cdr err)))
        (error
         (push (list file (error-message-string err)) failures))))
    (when failures
      (signal
       'org-museum-index-scan-failed
       (list
        (mapconcat
         (lambda (failure)
           (format "%s: %s" (car failure) (cadr failure)))
         (nreverse failures) "; "))))))

(defun org-museum--index-register-page (index page)
  "Add PAGE to INDEX, updating tag/category tables."
  (let* ((id (org-museum-page-id page))
         (pages (org-museum-index-pages index))
         (existing (gethash id pages)))
    (when (and existing
               (not (equal
                     (org-museum--normalised-path
                      (org-museum-page-path existing))
                     (org-museum--normalised-path
                      (org-museum-page-path page)))))
      (signal
       'org-museum-duplicate-page-id
       (list
        (format "ID '%s' is used by both %s and %s"
                id
                (org-museum-page-path existing)
                (org-museum-page-path page)))))
    (puthash id page pages))
  (dolist (tag (org-museum-page-tags page))
    (org-museum--adjoin-to-list (org-museum-index-tags index) tag
                                (org-museum-page-id page)))
  (org-museum--adjoin-to-list (org-museum-index-categories index)
                              (org-museum-page-category page)
                              (org-museum-page-id page)))

(defun org-museum--parse-created-date (value modified)
  "Return (TIMESTAMP SOURCE) for Org DATE VALUE, falling back to MODIFIED.
Only the first ISO calendar date in VALUE is used.  SOURCE is `org-date' for
a valid Org date and `modified-fallback' when VALUE is absent or invalid."
  (let ((trimmed (and (stringp value) (string-trim value))))
    (if (and trimmed
             (string-match
              "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)"
              trimmed))
        (condition-case nil
            (let* ((year (string-to-number (match-string 1 trimmed)))
                   (month (string-to-number (match-string 2 trimmed)))
                   (day (string-to-number (match-string 3 trimmed)))
                   (time (encode-time 0 0 0 day month year))
                   (decoded (decode-time time)))
              (if (and (= year (decoded-time-year decoded))
                       (= month (decoded-time-month decoded))
                       (= day (decoded-time-day decoded)))
                  (list (float-time time) 'org-date)
                (list modified 'modified-fallback)))
          (error (list modified 'modified-fallback)))
      (list modified 'modified-fallback))))

(defun org-museum--parse-relation-annotations (ast)
  "Return (TYPES DIAGNOSTICS) from repeated MUSEUM_RELATION keywords in AST.
TYPES is an ordered alist of raw target IDs to author-provided labels.  The
first annotation for a target wins; later duplicates are diagnosed."
  (let ((seen (make-hash-table :test 'equal)) types diagnostics)
    (org-element-map ast 'keyword
      (lambda (keyword)
        (when (string= (upcase (or (org-element-property :key keyword) ""))
                       "MUSEUM_RELATION")
          (let ((raw (string-trim (or (org-element-property :value keyword) ""))))
            (if (not (string-match
                      "\\`\\([^|\n]+?\\)[[:space:]]*|[[:space:]]*\\(.+?\\)\\'"
                      raw))
                (push (format "invalid relation annotation: %s" raw) diagnostics)
              (let ((target (string-trim (match-string 1 raw)))
                    (label (string-trim (match-string 2 raw))))
                (cond
                 ((or (string-empty-p target) (string-empty-p label))
                  (push (format "invalid relation annotation: %s" raw) diagnostics))
                 ((gethash target seen)
                  (push (format "conflicting relation annotation for %s" target)
                        diagnostics))
                 (t
                  (puthash target t seen)
                  (push (cons target label) types)))))))))
    (list (nreverse types) (nreverse diagnostics))))

(defun org-museum--resolve-relation-annotations (page outgoing pages aliases)
  "Canonicalise PAGE relation annotations against explicit OUTGOING links.
PAGES and ALIASES use the same resolution rules as ordinary Org links."
  (let ((seen (make-hash-table :test 'equal))
        (diagnostics (copy-sequence
                      (org-museum-page-relation-diagnostics page)))
        resolved)
    (dolist (annotation (org-museum-page-relation-types page))
      (let* ((raw-target (car annotation))
             (target (org-museum--resolve-page-link-id
                      raw-target pages aliases))
             (label (cdr annotation)))
        (cond
         ((not target)
          (push (format "unknown relation annotation target: %s" raw-target)
                diagnostics))
         ((not (member target outgoing))
          (push (format "relation annotation has no explicit outgoing link: %s"
                        target)
                diagnostics))
         ((gethash target seen)
          (push (format "conflicting relation annotation for %s" target)
                diagnostics))
         (t
          (puthash target t seen)
          (push (cons target label) resolved)))))
    (setf (org-museum-page-relation-types page) (nreverse resolved)
          (org-museum-page-relation-diagnostics page) (nreverse diagnostics))))

(defun org-museum--page-relation-type (page target-id)
  "Return PAGE's author label for TARGET-ID, or the factual fallback label."
  (or (cdr (assoc target-id (org-museum-page-relation-types page)))
      "显式链接"))

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
           (status (downcase (string-trim
                              (or (gethash "WIKI_STATUS" kw) "published"))))
           (description (gethash "DESCRIPTION" kw))
           (relation-result (org-museum--parse-relation-annotations ast))
           (modified (org-museum--file-mtime file))
           (created-result
            (org-museum--parse-created-date (gethash "DATE" kw) modified)))
      (unless (member status '("draft" "published"))
        (signal 'org-museum-invalid-page-status
                (list (format "%s uses unsupported WIKI_STATUS %S; expected draft or published"
                              file status))))
      (make-org-museum-page
       :id id :title title :path file :tags tags :category cat
       :created (car created-result) :date-source (cadr created-result)
       :modified modified
       :links-to nil :linked-from nil
       :relation-types (car relation-result)
       :relation-diagnostics (cadr relation-result)
       :theme theme :status status
       :description description))))

(defun org-museum--scan-resolve-links (index)
  "Resolve and record bidirectional links for all pages in INDEX."
  (let* ((pages (org-museum-index-pages index))
         (aliases (org-museum--build-page-id-aliases pages))
         (db-path (org-museum--org-roam-db-path))
         (org-museum--org-roam-db-connection
          (and (fboundp 'sqlite-open) db-path (sqlite-open db-path))))
    (unwind-protect
        (maphash
         (lambda (id page)
           (let ((outgoing (org-museum--extract-links-from-file
                            (org-museum-page-path page) pages aliases)))
             (setf (org-museum-page-links-to page) outgoing)
             (org-museum--resolve-relation-annotations
              page outgoing pages aliases)
             (dolist (target-id outgoing)
               (when-let* ((target (gethash target-id pages)))
                 (cl-pushnew id (org-museum-page-linked-from target)
                             :test #'equal)))))
         pages)
      (when org-museum--org-roam-db-connection
        (sqlite-close org-museum--org-roam-db-connection)))))

(defun org-museum--extract-links-from-file (file pages-table &optional aliases)
  "Return canonical page IDs linked from FILE.
Recognises wiki:, museum:, id:, and file: links.  Org-roam id links are
resolved through every page's :ID: properties, so [[id:UUID][Title]] links
connect to the exported Org Museum page even when the page ID is a slug or
WIKI_ID rather than the Org-roam UUID."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((links '())
          (dir   (file-name-directory file))
          (aliases (or aliases (org-museum--build-page-id-aliases pages-table)))
          (source-page (org-museum--find-page-by-path file pages-table)))
      (goto-char (point-min))
      (while (re-search-forward
              "\\[\\[\\(?:wiki\\|museum\\):\\([^]\n]+\\)\\]\\(?:\\[[^]]*\\]\\)?\\]" nil t)
        (when-let* ((id (org-museum--resolve-page-link-id
                        (match-string 1) pages-table aliases)))
          (unless (and source-page (equal id (org-museum-page-id source-page)))
            (cl-pushnew id links :test #'equal))))
      (goto-char (point-min))
      (while (re-search-forward
              "\\[\\[id:\\([^]\n]+\\)\\]\\(?:\\[[^]]*\\]\\)?\\]" nil t)
        (when-let* ((id (org-museum--resolve-page-link-id
                        (match-string 1) pages-table aliases)))
          (unless (and source-page (equal id (org-museum-page-id source-page)))
            (cl-pushnew id links :test #'equal))))
      (goto-char (point-min))
      (while (re-search-forward
              "\\[\\[file:\\([^]\n]+\\)\\]\\(?:\\[[^]]*\\]\\)?\\]" nil t)
        (let* ((parts (org-museum--file-link-parts (match-string 1)))
               (path (url-unhex-string (car parts)))
               (target-file (expand-file-name path dir))
               (target-page (org-museum--find-page-by-path target-file pages-table)))
          (when (and target-page
                     (or (null source-page)
                         (not (equal (org-museum-page-id target-page)
                                     (org-museum-page-id source-page)))))
            (cl-pushnew (org-museum-page-id target-page) links :test #'equal))))
      (dolist (id (org-museum--org-roam-db-linked-page-ids file pages-table aliases))
        (unless (and source-page (equal id (org-museum-page-id source-page)))
          (cl-pushnew id links :test #'equal)))
      links)))
;; ============================================================
;; §8  INDEX FRESHNESS
;; ============================================================

(defun org-museum--index-fresh-p (index-path)
  "Return non-nil when INDEX-PATH is newer than every .org file."
  (let ((index-mtime (org-museum--file-mtime index-path)))
    (and (file-directory-p (org-museum--scan-root))
         (condition-case nil
             (let ((json-object-type 'alist)
                   (json-key-type 'symbol))
               (= org-museum--index-schema-version
                  (or (cdr (assq 'schema-version
                                 (json-read-file index-path))) -1)))
           (error nil))
         (not (cl-some (lambda (f) (> (org-museum--file-mtime f) index-mtime))
                       (org-museum--scan-files)))
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
      (when-let* ((linked (gethash link-id pages)))
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

(defun org-museum--index-update-file-in-place (file)
  "Update the dynamically bound index for FILE without saving it.
Callers must provide rollback semantics around this mutating operation."
  (let* ((pages      (org-museum-index-pages org-museum--index))
         (old-pg     (org-museum--find-page-by-path file pages))
         (old-id     (when old-pg (org-museum-page-id old-pg))))
    (when old-id
      (org-museum--index-remove-page old-id old-pg))
    (when-let* ((new-pg (org-museum--parse-page-metadata file)))
      (org-museum--index-register-page org-museum--index new-pg)
      (let* ((aliases    (org-museum--build-page-id-aliases pages))
             (new-links  (org-museum--extract-links-from-file
                          file pages aliases))
             (new-id     (org-museum-page-id new-pg)))
        (setf (org-museum-page-links-to new-pg) new-links)
        (org-museum--resolve-relation-annotations
         new-pg new-links pages aliases)
        ;; Removing the old page cleared its ID from every former target.
        ;; Re-add the current ID to every current target, including links that
        ;; stayed unchanged and links whose source page ID was renamed.
        (dolist (target-id new-links)
          (when-let* ((target (gethash target-id pages)))
            (cl-pushnew new-id (org-museum-page-linked-from target)
                        :test #'equal)))
        (org-museum--verify-linked-from-for-page new-id)))
    org-museum--index))

(defun org-museum--index-update-file (file)
  "Transactionally update the index for FILE with link repair.
Steps:
  1. Guard: skip out-of-project or non-.org files
  2. Clone the current index as a private working copy
  3. Re-parse, register, and repair links only in the working copy
  4. Persist the complete working copy
  5. Commit it to `org-museum--index' only after every prior step succeeds
  6. [Fix-01] Rebuild linked-from for the new page via full inbound scan,
     correcting stale entries left by third-party page edits
Applicable scope: after-save-hook, single-file refresh.
Known limitation: cloning and inbound verification are O(n); acceptable for
wikis up to roughly 5000 pages."
  (cl-block org-museum--index-update-file
    (unless (org-museum--file-in-project-p file)
      (message "Org Museum [Index]: skipping out-of-project file %s" file)
      (cl-return-from org-museum--index-update-file nil))

    (unless org-museum--index
      (condition-case err
          (org-museum-index-build)
        (error
         (message "Org Museum [Index]: build failed: %s" (error-message-string err))
         (cl-return-from org-museum--index-update-file nil))))

    (let ((working (org-museum--alist-to-index
                    (org-museum--index-to-alist org-museum--index)))
          committed)
      (let ((org-museum--index working))
        (condition-case err
            (progn
              (org-museum--index-update-file-in-place file)
              (org-museum--index-save org-museum--index
                                      (org-museum--index-file-path))
              (setq committed org-museum--index))
          (error
           (message "Org Museum [Index]: incremental update failed for %s: %s"
                    file (error-message-string err)))))
      (when committed
        (setq org-museum--index committed))
      (and committed t))))

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
    (created     . ,(org-museum-page-created page))
    (date-source . ,(symbol-name (or (org-museum-page-date-source page)
                                     'modified-fallback)))
    (modified    . ,(org-museum-page-modified page))
    (links-to    . ,(vconcat (org-museum-page-links-to page)))
    (linked-from . ,(vconcat (org-museum-page-linked-from page)))
    (relation-types . ,(vconcat
                        (mapcar (lambda (entry)
                                  `((target . ,(car entry))
                                    (type . ,(cdr entry))))
                                (org-museum-page-relation-types page))))
    (relation-diagnostics . ,(vconcat
                              (org-museum-page-relation-diagnostics page)))
    (theme       . ,(or (org-museum-page-theme page) ""))
    (status      . ,(or (org-museum-page-status page) "published"))
    (description . ,(org-museum-page-description page))))

(defun org-museum--index-to-alist (index)
  "Serialise INDEX to JSON-compatible alist."
  (let (pages-list)
    (maphash (lambda (_id page) (push (org-museum--page-to-alist page) pages-list))
             (org-museum-index-pages index))
    `((schema-version . ,org-museum--index-schema-version)
      (pages . ,(vconcat pages-list)))))

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

(defun org-museum--json-relation-types (plist)
  "Read relation type records from cached page PLIST."
  (let ((raw (cdr (assq 'relation-types plist))) result)
    (dolist (record (cond ((vectorp raw) (append raw nil))
                          ((listp raw) raw)
                          (t nil))
                    (nreverse result))
      (let ((target (org-museum--json-get record 'target))
            (label (org-museum--json-get record 'type)))
        (when (and (not (string-empty-p target))
                   (not (string-empty-p label)))
          (push (cons target label) result))))))

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
                     :created     (let ((value (cdr (assq 'created plist))))
                                    (if (numberp value)
                                        value
                                      (cdr (assq 'modified plist))))
                     :date-source (let ((value (org-museum--json-get
                                                plist 'date-source)))
                                    (if (string= value "org-date")
                                        'org-date
                                      'modified-fallback))
                     :modified    (cdr (assq 'modified plist))
                     :links-to    (org-museum--json-get plist 'links-to   :as-list)
                     :linked-from (org-museum--json-get plist 'linked-from :as-list)
                     :relation-types (org-museum--json-relation-types plist)
                     :relation-diagnostics
                     (org-museum--json-get plist 'relation-diagnostics :as-list)
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
  "Atomically write INDEX as JSON at PATH.
The previous cache remains intact when serialization or disk writing fails."
  (let* ((target (expand-file-name path))
         (directory (file-name-directory target))
         (temporary (make-temp-file
                     (expand-file-name ".org-museum-index-" directory)
                     nil ".json"))
         (coding-system-for-write 'utf-8))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (let ((json-encoding-pretty-print nil))
              (insert (json-encode (org-museum--index-to-alist index)))))
          (rename-file temporary target t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

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
  (org-museum--run-with-current-runtime
   'org-museum-export-page (list file force)
   (lambda () (org-museum--export-page-current file force))))

(defun org-museum--export-page-current (file &optional force)
  "Export FILE using the currently loaded runtime."
  (org-museum--guard-init)
  (org-museum--ensure-css-deployed)
  (org-museum--hljs-assets)
  (let ((out-file (org-museum--export-filename file)))
    (if (and (not force) (not (org-museum--needs-export-p file out-file)))
        (message "Skipping unchanged page: %s" (file-name-nondirectory file))
      (make-directory (file-name-directory out-file) t)
      (org-museum--export-with-theme file out-file))
    (org-museum--delete-legacy-source-html file out-file)
    (unless org-museum--full-export-in-progress
      (org-museum--export-related-reading-current)
      (org-museum--export-timeline-current))))
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
  "Parse Org emphasis with MARK and TYPE around CJK punctuation.

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
            (insert
             (format
              (concat "#+HTML_HEAD: <meta name=\"color-scheme\" content=\"dark light\">\n"
                      "#+HTML_HEAD: %s\n#+HTML_HEAD: %s\n#+HTML_HEAD: %s\n")
              (org-museum--theme-script-tag out-file)
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
    (org-museum--pp-set-document-language org-file)
    (org-museum--pp-fix-exported-entities)
    (org-museum--pp-remove-inline-styles)
    (org-museum--pp-inject-hljs-language-classes)
    (org-museum--pp-normalize-plain-results)
    (org-museum--pp-inject-page-attributes org-file out-file)
    (org-museum--pp-annotate-local-file-links)
    (org-museum--pp-stabilize-heading-anchors org-file)
    (org-museum--pp-wrap-tables)
    (if (not (org-museum--pp-wrap-content-div out-file org-file))
        (progn
          (message "Org Museum [Export]: aborting post-processing for %s \
(#content div not found)" out-file)
          nil)
      (org-museum--pp-append-nav-and-graph out-file org-file)
      (org-museum--pp-inject-sidebars-and-scripts out-file)
      (let ((rewritten (org-museum--externalize-page-runtime
                        (buffer-string) out-file 'article)))
        (erase-buffer)
        (insert rewritten))
      (write-region (point-min) (point-max) out-file)
      t)))

(defun org-museum--source-language (org-file)
  "Return the language declared by ORG-FILE, or the configured default."
  (with-temp-buffer
    (insert-file-contents org-file)
    (goto-char (point-min))
    (let ((case-fold-search t))
      (if (re-search-forward
           (rx line-start (* (any " \t")) "#+LANGUAGE:"
               (* (any " \t")) (group (+ (not (any " \t\r\n")))))
           nil t)
          (string-trim (match-string-no-properties 1))
        org-museum-default-language))))

(defun org-museum--pp-set-document-language (org-file)
  "Set the current HTML buffer language from ORG-FILE."
  (goto-char (point-min))
  (when (re-search-forward (rx "<html" (* (not ?>)) ?>) nil t)
    (let* ((tag-begin (match-beginning 0))
           (tag-end (match-end 0))
           (tag (match-string-no-properties 0))
           (language (org-museum--html-escape
                      (org-museum--source-language org-file) t))
           (replacement
            (if (string-match "[ \t]lang=[\"'][^\"']*[\"']" tag)
                (replace-regexp-in-string
                 "[ \t]lang=[\"'][^\"']*[\"']"
                 (concat " lang=\"" language "\"") tag t t)
              (replace-regexp-in-string
               ">$" (concat " lang=\"" language "\">") tag t t))))
      (delete-region tag-begin tag-end)
      (goto-char tag-begin)
      (insert replacement))))

(defun org-museum--pp-fix-exported-entities ()
  "Repair malformed Org HTML tag separators in the current buffer.
Org 9.8 emits the final non-breaking-space entity before a tag span without
its semicolon.  Keep the workaround local to exported HTML."
  (goto-char (point-min))
  (while (search-forward "&nbsp;&nbsp;&nbsp<span class=\"tag\"" nil t)
    (replace-match "&nbsp;&nbsp;&nbsp;<span class=\"tag\"" t t)))

(defun org-museum--pp-wrap-tables ()
  "Wrap exported tables in an independently scrollable container."
  (goto-char (point-min))
  (let ((table-index 0))
    (while (re-search-forward "<table\\(?:[[:space:]][^>]*\\)?>" nil t)
      (let ((open-start (match-beginning 0)))
        (unless (save-excursion
                  (goto-char open-start)
                  (looking-back
                   "<section class=\"museum-table-scroll\"[^>]*>[[:space:]]*"
                   (max (point-min) (- open-start 180))))
          (setq table-index (1+ table-index))
          (goto-char open-start)
          (insert (format
                   (concat "<section class=\"museum-table-scroll\" tabindex=\"0\" "
                           "aria-label=\"可横向滚动的表格 %d\">")
                   table-index))
          (when (re-search-forward "</table>" nil t)
            (insert "</section>")))))))

(defun org-museum--pp-normalize-plain-results ()
  "Preserve line breaks in plain Org results blocks.
Only single-paragraph results are rewritten.  Rich results such as exported
tables retain their native markup."
  (goto-char (point-min))
  (let ((case-fold-search t)
        (pattern
         (concat
          "\\(<div class=\\\"results\\\"[^>]*>\\)"
          "[[:space:]]*<p>[[:space:]]*"
          "\\([^<]*\\)"
          "[[:space:]]*</p>[[:space:]]*</div>")))
    (while (re-search-forward pattern nil t)
      (let ((begin (match-beginning 0))
            (end (match-end 0))
            (opening-tag (match-string-no-properties 1))
            (result-text (string-trim (match-string-no-properties 2))))
        (delete-region begin end)
        (goto-char begin)
        (insert opening-tag
                "<pre class=\"org-museum-results\" tabindex=\"0\" "
                "aria-label=\"代码运行结果\"><code>"
                result-text
                "</code></pre></div>")))))

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
      "<details class=\"museum-article-meta-disclosure\" open>\n"
      "  <summary>文章信息</summary>\n"
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
      "</aside>\n"
      "</details>\n")
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
      "aria-live=\"polite\">文章开头</span>"
      "<button type=\"button\" class=\"museum-identity-toc\" data-toc-toggle "
      "aria-label=\"打开本文目录\">目录</button></div>\n")
     (org-museum--html-escape home-href t)
     (org-museum--html-escape (org-museum-page-title page))
     (org-museum--html-escape
      (org-museum--category-label (org-museum-page-category page)))
     (if (string= status "draft") " · 草稿" ""))))

(defun org-museum--pp-find-body-tag ()
  "Move point after the real body start tag and return non-nil.
Start after </head> when present so body-like text inside exporter comments or
scripts in the document head cannot be mistaken for the page body."
  (goto-char (point-min))
  (let ((body-search-start
         (if (re-search-forward "</head[[:space:]]*>" nil t)
             (point)
           (point-min))))
    (goto-char body-search-start)
    (re-search-forward "<body\\([[:space:]][^>]*\\)?>" nil t)))

(defun org-museum--pp-inject-page-attributes (org-file &optional out-file)
  "Add stable page metadata attributes to the current HTML buffer."
  (when-let* ((page (org-museum--page-for-file org-file)))
    (when (org-museum--pp-find-body-tag)
      ;; Capture the target before metadata/resource helpers run: some of them
      ;; legitimately use regexp matching and therefore replace match-data.
      (let* ((tag-begin (match-beginning 0))
             (tag-end (match-end 0))
             (existing (or (match-string-no-properties 1) ""))
             (replacement
              (format
               (concat "<body%s class=\"org-museum-page\" data-page-kind=\"article\" "
                       "data-page-id=\"%s\" data-page-title=\"%s\" "
                       "data-page-category=\"%s\" data-page-tags=\"%s\" "
                       "data-page-status=\"%s\" data-page-modified=\"%s\" "
                       "data-hljs-css=\"%s\" data-hljs-js=\"%s\" "
                       "data-hljs-lisp=\"%s\">")
               existing
               (org-museum--html-escape (org-museum-page-id page) t)
               (org-museum--html-escape (org-museum-page-title page) t)
               (org-museum--html-escape (org-museum-page-category page) t)
               (org-museum--html-escape
                (mapconcat #'identity (org-museum-page-tags page) ",") t)
               (org-museum--html-escape
                (downcase (or (org-museum-page-status page) "published")) t)
               (org-museum--format-page-date page)
               (org-museum--html-escape
                (or (and out-file (org-museum--hljs-css-src out-file)) "") t)
               (org-museum--html-escape
                (or (and out-file (org-museum--hljs-js-src out-file)) "") t)
               (org-museum--html-escape
                (or (and out-file (org-museum--hljs-lisp-js-src out-file)) "") t))))
        (delete-region tag-begin tag-end)
        (goto-char tag-begin)
        (insert replacement)))))

(defun org-museum--pp-remove-inline-styles ()
  "Conditionally strip <style>…</style> blocks from current buffer.
In `hljs' mode, removes all Org-generated <style> blocks to keep the HTML
clean (hljs handles highlighting via its own CSS).  In `inline-css' and
`css-classes' modes, the <style> blocks are preserved because they contain
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
      ("x++" "axapta")
      ("cmake.in" "cmake")
      ((or "c++" "h++") "cpp")
      ((or "c#" "cs") "csharp")
      ((or "f#" "fs") "fsharp")
      ((or "html.hbs" "html.handlebars") "handlebars")
      ((or "obj-c++" "objective-c++") "objectivec")
      ("pf.conf" "pf")
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
Only runs when `org-museum-code-highlight-method' is `hljs'."
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
      (let* ((content-beg (match-beginning 0))
             (content-end (match-end 0))
             (page (org-museum--page-for-file org-file))
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
        (goto-char content-beg)
        (delete-region content-beg content-end)
        (insert
         (concat
          "<main id=\"main-scroll\"><span id=\"main-content\" class=\"museum-main-anchor\" tabindex=\"-1\"></span>" identity
          (format
           "<div id=\"content\" class=\"museum-article-layout\" style=\"--museum-article-max-width: %dpx\">"
           (max 640 org-museum-article-max-width))
          "<article class=\"article-container\"" article-attrs ">"
          "<button type=\"button\" class=\"museum-article-toc-trigger\" "
          "data-toc-toggle>打开目录</button>"
          meta))
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
                      (org-museum--build-nav-html
                       links backs out-file (org-museum-page-id page))))
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
  (when (org-museum--pp-find-body-tag)
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

(defun org-museum--existing-safe-page-html-files ()
  "Return every existing cleanup-safe page HTML file."
  (let ((candidate (expand-file-name (org-museum--pages-root)))
        files)
    (when (file-exists-p candidate)
      (let ((pages-root (org-museum--validated-cleanup-pages-root)))
        (when (file-directory-p pages-root)
          (dolist (file (directory-files-recursively
                         pages-root "\\.html\\'" nil))
            (when (org-museum--safe-page-html-p file pages-root)
              (push (expand-file-name file) files))))))
    (sort files #'string<)))

;;;###autoload
(defun org-museum-preview-stale-exports ()
  "Return stale page HTML files without modifying the export directory.
When called interactively, display the exact files that a successful full
export would remove."
  (interactive)
  (let* ((expected (org-museum--expected-page-html-files))
         (expected-table (make-hash-table :test 'equal))
         stale)
    (dolist (file expected)
      (puthash (downcase (expand-file-name file)) t expected-table))
    (dolist (file (org-museum--existing-safe-page-html-files))
      (when (not (gethash (downcase (expand-file-name file)) expected-table))
        (push (expand-file-name file) stale)))
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

(defun org-museum--clean-stale-exports-if-safe ()
  "Clean stale exports, or warn and skip when safety validation refuses.
Only `user-error' safety refusals are non-fatal.  Unexpected filesystem
errors still propagate so the full-export transaction can roll back."
  (condition-case err
      (org-museum--clean-stale-exports)
    (user-error
     (display-warning
      'org-museum
      (format "Stale cleanup skipped: %s\nMuseum root: %s\nPages root: %s"
              (error-message-string err)
              (expand-file-name org-museum-root-dir)
              (expand-file-name (org-museum--pages-root)))
      :warning)
     0)))

;;;###autoload
(defun org-museum-export-all ()
  "Export the entire Org Museum as a static HTML site."
  (interactive)
  (org-museum--run-with-current-runtime
   'org-museum-export-all nil #'org-museum--export-all-current))

(defun org-museum--publish-normalise-relative-path (path)
  "Return PATH with portable separators, or nil when it is unsafe."
  (let ((normalised (replace-regexp-in-string "\\\\" "/" path)))
    (when (and (not (file-name-absolute-p path))
               (not (string-prefix-p "/" normalised))
               (not (member ".." (split-string normalised "/" t))))
      normalised)))

(defun org-museum--publish-managed-relative-path-p (path)
  "Return non-nil when relative PATH is owned by Org Museum publishing."
  (when-let* ((relative (org-museum--publish-normalise-relative-path path)))
    (or (member relative
                (list "index.html" "timeline.html" "graph.html" "related.html" ".nojekyll"
                      org-museum--publish-status-name))
        (string-prefix-p "pages/" relative)
        (string-prefix-p "resources/" relative))))

(defun org-museum--publish-path-key (path)
  "Return a comparison key for absolute PATH on the current platform."
  (let ((key (file-name-as-directory (expand-file-name path))))
    (if (memq system-type '(windows-nt ms-dos cygwin))
        (downcase key)
      key)))

(defun org-museum--publish-validate-directories ()
  "Validate and return (EXPORT-ROOT PUBLISH-ROOT)."
  (unless (and org-museum-publish-directory
               (not (string-empty-p org-museum-publish-directory)))
    (signal 'org-museum-publish-error
            '("org-museum-publish-directory is not configured")))
  (let* ((export-root (file-name-as-directory
                       (expand-file-name (org-museum--shared-root))))
         (publish-root (file-name-as-directory
                        (expand-file-name org-museum-publish-directory)))
         (root-key (org-museum--publish-path-key org-museum-root-dir))
         (export-key (org-museum--publish-path-key export-root))
         (publish-key (org-museum--publish-path-key publish-root))
         (true-root-key
          (org-museum--publish-path-key (file-truename org-museum-root-dir)))
         (true-export-key
          (org-museum--publish-path-key (file-truename export-root)))
         (true-publish-key
          (org-museum--publish-path-key (file-truename publish-root))))
    (unless (file-directory-p export-root)
      (signal 'org-museum-publish-error
              (list (format "Export directory does not exist: %s" export-root))))
    (when (or (string-prefix-p root-key publish-key)
              (string-prefix-p publish-key root-key)
              (string-prefix-p export-key publish-key)
              (string-prefix-p publish-key export-key)
              (string-prefix-p true-root-key true-publish-key)
              (string-prefix-p true-publish-key true-root-key)
              (string-prefix-p true-export-key true-publish-key)
              (string-prefix-p true-publish-key true-export-key))
      (signal 'org-museum-publish-error
              (list "Publish directory must not overlap the wiki or export directory")))
    (list export-root publish-root)))

(defun org-museum--publish-tree-files (root relative)
  "Return regular files below ROOT/RELATIVE, rejecting symbolic links."
  (let ((start (expand-file-name relative root))
        files)
    (when (or (file-symlink-p start)
              (and (file-exists-p start)
                   (not (equal (org-museum--publish-path-key start)
                               (org-museum--publish-path-key
                                (file-truename start))))))
      (signal 'org-museum-publish-error
              (list (format "Linked export directory cannot be published: %s"
                            start))))
    (unless (file-directory-p start)
      (signal 'org-museum-publish-error
              (list (format "Required export directory is missing: %s" start))))
    (cl-labels
        ((walk
          (directory)
          (dolist (entry (directory-files directory t nil t))
            (unless (member (file-name-nondirectory entry) '("." ".."))
              (when (file-symlink-p entry)
                (signal 'org-museum-publish-error
                        (list (format "Symbolic links cannot be published: %s"
                                      entry))))
              (cond
               ((file-directory-p entry) (walk entry))
               ((file-regular-p entry) (push entry files))
               (t
                (signal 'org-museum-publish-error
                        (list (format "Unsupported export entry: %s" entry)))))))))
      (walk start))
    (nreverse files)))

(defun org-museum--publish-source-files (export-root)
  "Return the complete public file set below EXPORT-ROOT."
  (when (or (file-symlink-p export-root)
            (not (equal (org-museum--publish-path-key export-root)
                        (org-museum--publish-path-key
                         (file-truename export-root)))))
    (signal 'org-museum-publish-error
            (list (format "Linked export root cannot be published: %s"
                          export-root))))
  (let ((required (mapcar (lambda (name) (expand-file-name name export-root))
                          '("index.html" "timeline.html" "graph.html" "related.html"))))
    (dolist (file required)
      (when (or (file-symlink-p file) (not (file-regular-p file)))
        (signal 'org-museum-publish-error
                (list (format "Required export file is missing or unsafe: %s"
                              file)))))
    (append required
            (org-museum--publish-tree-files export-root "pages")
            (org-museum--publish-tree-files export-root "resources"))))

(defun org-museum--publish-text-file-p (file)
  "Return non-nil when FILE should be scanned for local paths."
  (member (downcase (or (file-name-extension file) ""))
          '("html" "htm" "css" "js" "json" "xml" "svg" "txt" "map")))

(defun org-museum--publish-source-for-relative (relative)
  "Return the indexed Org source that exports to RELATIVE, if any."
  (when org-museum--index
    (let (source)
      (maphash
       (lambda (_id page)
         (let ((output-relative
                (org-museum--publish-normalise-relative-path
                 (file-relative-name
                  (org-museum--export-filename (org-museum-page-path page))
                  (org-museum--shared-root)))))
           (when (equal relative output-relative)
             (setq source (org-museum-page-path page)))))
       (org-museum-index-pages org-museum--index))
      source)))

(defun org-museum--publish-path-from-match (value)
  "Return a comparison-ready local path extracted from matched VALUE."
  (let ((path (or value "")))
    (setq path
          (cond
           ((string-match "\\`file://\\([^/]+\\)/\\(.*\\)" path)
            (concat "//" (match-string 1 path) "/" (match-string 2 path)))
           ((string-match "\\`file:\\(////+\\)\\(.*\\)" path)
            (concat "//" (match-string 2 path)))
           (t (replace-regexp-in-string "\\`file:/+" "" path t t))))
    (setq path (replace-regexp-in-string
                "\\`data-local-path=\\\"\\|\\\"\\'" "" path t))
    (dolist (entity '(("&amp;" . "&") ("&quot;" . "\"")
                      ("&#39;" . "'") ("&lt;" . "<") ("&gt;" . ">")))
      (setq path (replace-regexp-in-string
                  (regexp-quote (car entity)) (cdr entity) path t t)))
    (url-unhex-string path)))

(defun org-museum--publish-source-locations (source matched)
  "Locate every occurrence of MATCHED in SOURCE and return attribution plists."
  (when (and source (file-regular-p source))
    (with-temp-buffer
      (insert-file-contents source)
      (let* ((case-fold-search t)
             (needle (org-museum--publish-path-from-match matched))
             (normal-needle (org-museum--normalised-path needle))
             locations)
        (cl-labels
            ((record (position kind)
               (save-excursion
                 (goto-char position)
                 (push (list :line (line-number-at-pos)
                             :column (current-column)
                             :kind kind
                             :excerpt
                             (string-trim
                              (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position))))
                       locations))))
          ;; Prefer source file links when an absolute path is also literal
          ;; text inside that same Org link.
          (goto-char (point-min))
          (while (re-search-forward
                  "\\[\\[file:\\([^]\n]+\\)\\]\\(?:\\[[^]]*\\]\\)?\\]"
                  nil t)
            (let* ((parts (org-museum--file-link-parts (match-string 1)))
                   (target (url-unhex-string (car parts)))
                   (expanded (expand-file-name
                              target (file-name-directory source))))
              (when (equal normal-needle
                           (org-museum--normalised-path expanded))
                (record (match-beginning 0) 'local-file-link))))
          (goto-char (point-min))
          (while (search-forward needle nil t)
            (record (match-beginning 0) 'absolute-path)))
        (nreverse locations)))))

(defun org-museum--publish-finding-suggestion (kind)
  "Return an actionable source-edit suggestion for finding KIND."
  (pcase kind
    ('local-file-link
     "Remove the local file link, publish the target as a managed resource, or replace it with a public URL.")
    ('absolute-path
     "Use user-emacs-directory, a relative example, or a portable placeholder instead of a machine-specific path.")
    (_
     "Inspect the exporter that generated this path; generated public output must use relative links.")))

(defun org-museum--publish-file-privacy-matches (file &optional detectors)
  "Return local-path and supplemental DETECTORS matches in text FILE."
  (let ((specs
         '((file-unc-url
            "file:////+[^/[:space:]\"']+/[^<>\"'\n\r]+" 0)
           (file-unc-authority
            "file://[^/[:space:]\"']+/[^<>\"'\n\r]+" 0)
           (data-unc-path
            "data-local-path=\\\"\\(//[^/[:space:]\"']+/[^\"\n\r]+\\)\\\"" 1)
           (file-url
            "file:///[[:alpha:]]:[/\\\\][^<>\"'\n\r]+" 0)
           (data-local-path
            "data-local-path=\\\"\\([[:alpha:]]:[^\"\n\r]+\\)\\\"" 1)
           (windows-path
            "\\(?:\\`\\|[^[:alnum:]?]\\)\\([[:alpha:]]:[/\\\\][^<>:\"/\\\\|?*\n\r][^<>\"'\n\r[:space:]]*\\)" 1)
           (unc-path
            "\\(?:\\`\\|[^\\\\]\\)\\(\\\\\\\\[[:alnum:]][[:alnum:]._-]+\\\\[[:alnum:]][^\\\\/[:space:]\"']*\\)" 1)))
        candidates selected)
    (dolist (detector detectors)
      (let* ((name (alist-get 'name detector))
             (kind (intern
                    (concat "custom-"
                            (replace-regexp-in-string
                             "[^[:alnum:]-]+" "-" (downcase name)))))
             (regexp (alist-get 'regexp detector))
             (group (or (alist-get 'group detector) 0))
             (suggestion (or (alist-get 'suggestion detector)
                             "Edit or exclude this policy-defined sensitive content.")))
        (setq specs
              (append specs (list (list kind regexp group suggestion))))))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((case-fold-search t))
        (dolist (spec specs)
          (goto-char (point-min))
          (while (re-search-forward (nth 1 spec) nil t)
            (let ((group (nth 2 spec)))
              (push (list :begin (match-beginning group)
                          :end (match-end group)
                          :kind (car spec)
                          :match (match-string-no-properties group)
                          :suggestion (nth 3 spec))
                    candidates))))))
    (dolist (candidate
             (sort candidates
                   (lambda (left right)
                     (if (= (plist-get left :begin) (plist-get right :begin))
                         (> (- (plist-get left :end) (plist-get left :begin))
                            (- (plist-get right :end) (plist-get right :begin)))
                       (< (plist-get left :begin) (plist-get right :begin))))))
      (unless (cl-some
               (lambda (chosen)
                 (and (< (plist-get candidate :begin) (plist-get chosen :end))
                      (> (plist-get candidate :end) (plist-get chosen :begin))))
               selected)
        (push candidate selected)))
    (nreverse selected)))

(defun org-museum--publish-privacy-findings (files export-root &optional detectors)
  "Return structured findings for FILES, including supplemental DETECTORS."
  (let (findings)
    (dolist (file files)
      (when (org-museum--publish-text-file-p file)
        (let* ((relative (org-museum--publish-normalise-relative-path
                          (file-relative-name file export-root)))
               (source (and relative
                            (org-museum--publish-source-for-relative relative))))
          (dolist (match (org-museum--publish-file-privacy-matches
                          file detectors))
            (let* ((matched (plist-get match :match))
                   (locations (org-museum--publish-source-locations
                               source matched)))
              (dolist (location (or locations (list nil)))
                (let ((kind (if (string-prefix-p
                                 "custom-"
                                 (symbol-name (plist-get match :kind)))
                                (plist-get match :kind)
                              (or (plist-get location :kind)
                                  'generated-output))))
                  (push
                   (make-org-museum-publish-finding
                    :file file
                    :relative relative
                    :source source
                    :line (plist-get location :line)
                    :column (plist-get location :column)
                    :kind kind
                    :match matched
                    :excerpt (plist-get location :excerpt)
                    :suggestion (or (plist-get match :suggestion)
                                    (org-museum--publish-finding-suggestion kind)))
                   findings))))))))
    (let ((seen (make-hash-table :test #'equal)) unique)
      (dolist (finding (nreverse findings) (nreverse unique))
        (let* ((source (org-museum-publish-finding-source finding))
               (line (org-museum-publish-finding-line finding))
               (path (downcase
                      (replace-regexp-in-string
                       "\\\\" "/"
                       (org-museum--publish-path-from-match
                        (org-museum-publish-finding-match finding))
                       t t)))
               (key (list (or source
                              (org-museum-publish-finding-relative finding))
                          line path)))
          (unless (gethash key seen)
            (puthash key t seen)
            (push finding unique)))))))

(defun org-museum--publish-privacy-violations (files)
  "Return FILES containing user paths, Windows paths, or local file URLs."
  (let ((root (file-name-directory (car files))))
    (delete-dups
     (mapcar #'org-museum-publish-finding-file
             (org-museum--publish-privacy-findings files root)))))

(defun org-museum--publish-open-source-button (button)
  "Visit the source location stored on privacy report BUTTON."
  (let ((source (button-get button 'org-museum-source))
        (line (button-get button 'org-museum-line)))
    (find-file source)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun org-museum--publish-rerun-sync-button (_button)
  "Rerun the interactive publish sync from a privacy report button."
  (call-interactively #'org-museum-publish-sync))

(defun org-museum--publish-render-privacy-report (findings)
  "Render local-only privacy FINDINGS and return the report buffer."
  (let ((buffer (get-buffer-create org-museum--publish-privacy-buffer))
        (pages (delete-dups
                (delq nil (mapcar #'org-museum-publish-finding-relative
                                  findings)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-text-button
         "[重新运行同步]"
         'follow-link t
         'action #'org-museum--publish-rerun-sync-button)
        (insert "\n\nOrg Museum 隐私报告\n\n")
        (if (null findings)
            (insert "未发现隐私材料；当前发布候选可以部署。\n")
          (insert (format "当前不可部署：发现 %d 项问题，涉及 %d 个文件。\n\n"
                          (length findings) (length pages)))
          (cl-loop for finding in findings
                   for number from 1 do
                   (let ((source (org-museum-publish-finding-source finding))
                         (line (org-museum-publish-finding-line finding)))
                     (insert (format "%d. 发布文件：%s\n"
                                     number
                                     (org-museum-publish-finding-relative finding)))
                     (if (and source line)
                         (progn
                           (insert "   来源：")
                           (insert-text-button
                            (format "%s:%d" source line)
                            'follow-link t
                            'org-museum-source source
                            'org-museum-line line
                            'action #'org-museum--publish-open-source-button)
                           (insert "\n"))
                       (insert "   来源：导出器生成内容\n"))
                     (insert (format "   类型：%s\n   内容：%s\n"
                                     (org-museum-publish-finding-kind finding)
                                     (org-museum-publish-finding-match finding)))
                     (when-let* ((excerpt
                                 (org-museum-publish-finding-excerpt finding)))
                       (insert (format "   原文：%s\n" excerpt)))
                     (insert (format "   建议：%s\n\n"
                                     (org-museum-publish-finding-suggestion
                                      finding))))))
        (goto-char (point-min)))
      (special-mode))
    buffer))

(defun org-museum--publish-default-policy ()
  "Return the default local full-sync sharing policy."
  (list :include '("index.html" "timeline.html" "graph.html" "related.html"
                   "pages/**" "resources/**")
        :exclude nil
        :authorizations nil
        :detectors nil))

(defun org-museum--publish-policy-pattern-p (pattern)
  "Return non-nil when relative glob PATTERN is safe for publish selection."
  (and (stringp pattern)
       (not (string-empty-p pattern))
       (not (file-name-absolute-p pattern))
       (not (string-prefix-p "/" pattern))
       (not (member ".." (split-string
                           (replace-regexp-in-string "\\\\" "/" pattern)
                           "/" t)))))

(defun org-museum--publish-policy-detector-p (detector)
  "Return non-nil when DETECTOR is a valid supplemental scan rule."
  (let ((name (alist-get 'name detector))
        (regexp (alist-get 'regexp detector))
        (group (or (alist-get 'group detector) 0))
        (suggestion (alist-get 'suggestion detector)))
    (and (stringp name) (not (string-empty-p name))
         (stringp regexp) (not (string-empty-p regexp))
         (condition-case nil (progn (string-match-p regexp "") t)
           (invalid-regexp nil))
         (integerp group) (>= group 0)
         (or (null suggestion) (stringp suggestion)))))

(defun org-museum--publish-policy-authorization-p (entry)
  "Return non-nil when authorisation ENTRY contains only safe metadata."
  (let ((fingerprint (alist-get 'fingerprint entry))
        (source (alist-get 'source entry))
        (published (alist-get 'published entry))
        (risk-type (alist-get 'riskType entry))
        (reason (alist-get 'reason entry))
        (approved-at (alist-get 'approvedAt entry)))
    (and (stringp fingerprint)
         (string-match-p "\\`[[:xdigit:]]\\{64\\}\\'" fingerprint)
         (stringp source)
         (or (string-empty-p source)
             (org-museum--publish-normalise-relative-path source))
         (stringp published)
         (org-museum--publish-managed-relative-path-p published)
         (stringp risk-type)
         (stringp reason) (not (string-empty-p reason))
         (stringp approved-at))))

(defun org-museum--publish-read-policy ()
  "Read and validate the local sharing policy, or return safe defaults."
  (if (not (file-exists-p org-museum-publish-policy-file))
      (org-museum--publish-default-policy)
    (condition-case err
        (let ((json-object-type 'alist)
              (json-array-type 'list)
              (json-key-type 'symbol))
          (with-temp-buffer
            (insert-file-contents org-museum-publish-policy-file)
            (goto-char (point-min))
            (let* ((data (json-read))
                   (include (alist-get 'include data))
                   (exclude (alist-get 'exclude data))
                   (authorizations (alist-get 'authorizations data))
                   (detectors (alist-get 'detectors data)))
              (unless (and (= (or (alist-get 'schemaVersion data) 0) 1)
                           (listp include) include
                           (listp exclude)
                           (cl-every #'org-museum--publish-policy-pattern-p
                                     (append include exclude))
                           (listp authorizations)
                           (cl-every
                            #'org-museum--publish-policy-authorization-p
                            authorizations)
                           (listp detectors)
                           (cl-every #'org-museum--publish-policy-detector-p
                                     detectors))
                (signal 'org-museum-publish-error
                        '("Publish sharing policy is invalid")))
              (list :include include :exclude exclude
                    :authorizations authorizations :detectors detectors))))
      (org-museum-publish-error (signal (car err) (cdr err)))
      (error
       (signal 'org-museum-publish-error
               (list (format "Cannot read publish sharing policy: %s"
                             (error-message-string err))))))))

(defun org-museum--publish-policy-pattern-match-p (pattern relative)
  "Return non-nil when relative publish path RELATIVE matches glob PATTERN."
  (string-match-p (wildcard-to-regexp
                   (replace-regexp-in-string "\\\\" "/" pattern))
                  relative))

(defun org-museum--publish-policy-selected-p (policy relative)
  "Return non-nil when POLICY selects publish path RELATIVE."
  (and (cl-some (lambda (pattern)
                  (org-museum--publish-policy-pattern-match-p pattern relative))
                (plist-get policy :include))
       (not (cl-some
             (lambda (pattern)
               (org-museum--publish-policy-pattern-match-p pattern relative))
             (plist-get policy :exclude)))))

(defun org-museum--publish-policy-json (policy)
  "Return canonical local JSON for sharing POLICY."
  (concat
   (json-encode
    `((schemaVersion . 1)
      (include . ,(vconcat (plist-get policy :include)))
      (exclude . ,(vconcat (plist-get policy :exclude)))
      (authorizations . ,(vconcat (plist-get policy :authorizations)))
      (detectors . ,(vconcat (plist-get policy :detectors)))))
   "\n"))

(defun org-museum--publish-policy-digest (policy)
  "Return a stable digest of the effective local sharing POLICY."
  (secure-hash 'sha256 (org-museum--publish-policy-json policy)))

(defun org-museum--publish-candidate-digest (root files)
  "Return a stable path-and-content digest for relative FILES below ROOT."
  (secure-hash
   'sha256
   (mapconcat
    (lambda (relative)
      (format "%s\0%s" relative
              (org-museum--publish-file-sha256
               (expand-file-name relative root))))
    (sort (copy-sequence files) #'string<)
    "\0")))

(defun org-museum--publish-write-policy (policy)
  "Atomically write local sharing POLICY outside the publish checkout."
  (let* ((target (expand-file-name org-museum-publish-policy-file))
         (directory (file-name-directory target)))
    (make-directory directory t)
    (let ((temporary (make-temp-file
                      (expand-file-name ".org-museum-policy-" directory))))
      (unwind-protect
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file temporary
              (insert (org-museum--publish-policy-json policy)))
            (rename-file temporary target t))
        (when (file-exists-p temporary) (delete-file temporary))))
    target))

(defun org-museum--publish-validate-policy-location (export-root publish-root)
  "Ensure the local policy cannot enter EXPORT-ROOT or PUBLISH-ROOT."
  (let* ((policy (expand-file-name org-museum-publish-policy-file))
         (policy-key (org-museum--publish-path-key policy))
         (export-key (org-museum--publish-path-key export-root))
         (publish-key (org-museum--publish-path-key publish-root)))
    (when (or (string-prefix-p export-key policy-key)
              (string-prefix-p publish-key policy-key))
      (signal 'org-museum-publish-error
              '("Publish policy must stay outside export and publish directories")))))

(defun org-museum--publish-finding-source-relative (finding)
  "Return FINDING's source path relative to the museum root, or nil."
  (when-let* ((source (org-museum-publish-finding-source finding)))
    (org-museum--publish-normalise-relative-path
     (file-relative-name source org-museum-root-dir))))

(defun org-museum--publish-finding-records (findings policy excluded)
  "Return stable policy-evaluation records for FINDINGS.
POLICY supplies exact fingerprint authorisations and EXCLUDED lists candidate
paths outside the effective sharing scope."
  (let ((counts (make-hash-table :test #'equal)) records)
    (dolist (finding findings (nreverse records))
      (let* ((source (or (org-museum--publish-finding-source-relative finding)
                         ""))
             (relative (org-museum-publish-finding-relative finding))
             (kind (symbol-name (org-museum-publish-finding-kind finding)))
             (match (org-museum--publish-path-from-match
                     (org-museum-publish-finding-match finding)))
             (excerpt (or (org-museum-publish-finding-excerpt finding) ""))
             (base (mapconcat #'identity
                              (list source relative kind match excerpt) "\0"))
             (occurrence (1+ (gethash base counts 0)))
             (fingerprint (secure-hash
                           'sha256 (format "%s\0%d" base occurrence)))
             (authorized
              (cl-some
               (lambda (entry)
                 (equal fingerprint (alist-get 'fingerprint entry)))
               (plist-get policy :authorizations)))
             (status (cond
                      ((member relative excluded) 'excluded)
                      (authorized 'authorized)
                      (t 'unresolved))))
        (puthash base occurrence counts)
        (push (list :finding finding :fingerprint fingerprint :status status)
              records)))))

(defun org-museum--publish-policy-authorize-button (button)
  "Add BUTTON's exact finding fingerprint to the local sharing policy."
  (let* ((policy (org-museum--publish-read-policy))
         (fingerprint (button-get button 'org-museum-fingerprint))
         (finding (button-get button 'org-museum-finding))
         (reason (string-trim
                  (read-string "Why is this exact content safe to share? "))))
    (when (string-empty-p reason)
      (signal 'org-museum-publish-error
              '("An authorisation reason is required")))
    (unless (cl-some
             (lambda (entry)
               (equal fingerprint (alist-get 'fingerprint entry)))
             (plist-get policy :authorizations))
      (setf (plist-get policy :authorizations)
            (append
             (plist-get policy :authorizations)
             (list
              `((fingerprint . ,fingerprint)
                (source . ,(or (org-museum--publish-finding-source-relative
                                finding) ""))
                (published . ,(org-museum-publish-finding-relative finding))
                (riskType . ,(symbol-name
                              (org-museum-publish-finding-kind finding)))
                (reason . ,reason)
                (approvedAt . ,(format-time-string "%FT%T%z"))))))
      (org-museum--publish-write-policy policy))
    (message "Org Museum authorised this exact finding; rerun full sync")))

(defun org-museum--publish-policy-revoke-button (button)
  "Remove BUTTON's exact finding authorisation from the local policy."
  (let* ((policy (org-museum--publish-read-policy))
         (fingerprint (button-get button 'org-museum-fingerprint)))
    (setf (plist-get policy :authorizations)
          (cl-remove-if
           (lambda (entry)
             (equal fingerprint (alist-get 'fingerprint entry)))
           (plist-get policy :authorizations)))
    (org-museum--publish-write-policy policy)
    (message "Org Museum revoked this exact authorisation; rerun full sync")))

(defun org-museum--publish-policy-exclude-button (button)
  "Add BUTTON's exact published path to the local policy exclusions."
  (let* ((policy (org-museum--publish-read-policy))
         (relative (button-get button 'org-museum-relative)))
    (unless (member relative (plist-get policy :exclude))
      (setf (plist-get policy :exclude)
            (append (plist-get policy :exclude) (list relative)))
      (org-museum--publish-write-policy policy))
    (message "Org Museum excluded %s; rerun full sync" relative)))

(defun org-museum--publish-policy-edit-button (_button)
  "Create the default policy when necessary, then visit it."
  (unless (file-exists-p org-museum-publish-policy-file)
    (org-museum--publish-write-policy (org-museum--publish-default-policy)))
  (find-file org-museum-publish-policy-file))

(defun org-museum--publish-full-rerun-button (_button)
  "Rerun the interactive full-sync review workflow."
  (call-interactively #'org-museum-publish-sync-full))

(defun org-museum--publish-render-full-preview
    (policy records selected excluded state &optional change-plan)
  "Render full-sync POLICY, FINDINGS and selected paths before installation."
  (let ((buffer (get-buffer-create org-museum--publish-full-preview-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Org Museum Full Sync / Review Sharing\n\n")
        (insert "WARNING: selected exports are copied byte-for-byte, including "
                "local paths and other private material.\n"
                "The detailed report remains in Emacs; the policy stays local.\n\n")
        (insert-text-button "Edit sharing policy"
                            'follow-link t
                            'action #'org-museum--publish-policy-edit-button)
        (insert "    ")
        (insert-text-button "Rerun full sync"
                            'follow-link t
                            'action #'org-museum--publish-full-rerun-button)
        (insert "\n\n")
        (insert (format "Result state: %s\nSelected files: %d\nExcluded files: %d\nPrivacy findings: %d\n\n"
                        state (length selected) (length excluded)
                        (length records)))
        (insert "Effective include patterns:\n")
        (dolist (pattern (plist-get policy :include))
          (insert (format "  + %s\n" pattern)))
        (insert "Effective exclude patterns:\n")
        (if (plist-get policy :exclude)
            (dolist (pattern (plist-get policy :exclude))
              (insert (format "  - %s\n" pattern)))
          (insert "  (none)\n"))
        (when excluded
          (insert "\nExcluded candidate files:\n")
          (dolist (relative excluded) (insert (format "  - %s\n" relative))))
        (when change-plan
          (insert "\nMirror change preview:\n")
          (dolist (category '((:create . "Add")
                              (:overwrite . "Overwrite")
                              (:delete . "Delete")
                              (:unknown . "Baseline unknown")
                              (:conflicts . "CONFLICT")))
            (let ((paths (plist-get change-plan (car category))))
              (insert (format "  %s: %d\n" (cdr category) (length paths)))
              (dolist (relative paths)
                (insert (format "    - %s\n" relative))))))
        (when records
          (insert "\nFinding decisions:\n")
          (dolist (record records)
            (let* ((finding (plist-get record :finding))
                   (fingerprint (plist-get record :fingerprint))
                   (status (plist-get record :status)))
              (insert (format "\n  %s  %s\n"
                              status
                              (org-museum-publish-finding-relative finding)))
              (when (and (org-museum-publish-finding-source finding)
                         (org-museum-publish-finding-line finding))
                (insert "    ")
                (insert-text-button
                 "Open source note"
                 'follow-link t
                 'org-museum-source
                 (org-museum-publish-finding-source finding)
                 'org-museum-line (org-museum-publish-finding-line finding)
                 'action #'org-museum--publish-open-source-button)
                (insert "\n"))
              (insert (format "    Risk: %s\n    Suggested change: %s\n"
                              (org-museum-publish-finding-kind finding)
                              (org-museum-publish-finding-suggestion finding)))
              (when (org-museum-publish-finding-line finding)
                (insert (format "    Source line: %d\n"
                                (org-museum-publish-finding-line finding))))
              (insert (format "    Matched content: %s\n"
                              (org-museum-publish-finding-match finding)))
              (unless (eq status 'excluded)
                (insert "    ")
                (insert-text-button
                 "Exclude this published file"
                 'follow-link t
                 'org-museum-policy-action 'exclude
                 'org-museum-relative
                 (org-museum-publish-finding-relative finding)
                 'action #'org-museum--publish-policy-exclude-button)
                (insert "\n"))
              (unless (eq status 'excluded)
                (insert "    ")
                (insert-text-button
                 (if (eq status 'authorized)
                     "Revoke exact authorisation"
                   "Authorise this exact content")
                 'follow-link t
                 'org-museum-policy-action
                 (if (eq status 'authorized) 'revoke 'authorize)
                 'org-museum-fingerprint fingerprint
                 'org-museum-finding finding
                 'action (if (eq status 'authorized)
                             #'org-museum--publish-policy-revoke-button
                           #'org-museum--publish-policy-authorize-button))
                (insert "\n")))))
        (let ((current-fingerprints
               (mapcar (lambda (record) (plist-get record :fingerprint))
                       records)))
          (dolist (entry (plist-get policy :authorizations))
            (unless (member (alist-get 'fingerprint entry)
                            current-fingerprints)
              (insert (format
                       "\n  fixed  %s\n    The authorised finding is no longer present after export.\n    "
                       (alist-get 'published entry)))
              (insert-text-button
               "Revoke stale authorisation"
               'follow-link t
               'org-museum-policy-action 'revoke
               'org-museum-fingerprint (alist-get 'fingerprint entry)
               'action #'org-museum--publish-policy-revoke-button)
              (insert "\n"))))
        (insert (format "\nTo install this local raw mirror, enter exactly: %s\n"
                        org-museum--publish-full-confirmation))
        (goto-char (point-min)))
      (special-mode))
    buffer))

(defun org-museum--publish-file-sha256 (file)
  "Return the SHA-256 of FILE's literal bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun org-museum--publish-manifest-data-from-string (contents context)
  "Return validated manifest data from JSON CONTENTS labelled by CONTEXT."
  (condition-case err
      (let ((json-object-type 'alist)
            (json-array-type 'list)
            (json-key-type 'symbol))
        (with-temp-buffer
          (insert contents)
          (goto-char (point-min))
          (let* ((data (json-read))
                 (schema (or (alist-get 'schemaVersion data) 0))
                 (files (alist-get 'files data))
                 (hash-records (alist-get 'hashes data))
                 hashes)
            (unless (and (memq schema '(1 2))
                         (listp files)
                         (cl-every #'stringp files)
                         (cl-every #'org-museum--publish-managed-relative-path-p
                                   files)
                         (or (= schema 1) (listp hash-records)))
              (signal 'org-museum-publish-error
                      (list (format "%s contains unsafe entries" context))))
            (when (= schema 2)
              (dolist (record hash-records)
                (let ((path (alist-get 'path record))
                      (hash (alist-get 'sha256 record)))
                  (unless (and (stringp path)
                               (member path files)
                               (org-museum--publish-managed-relative-path-p path)
                               (stringp hash)
                               (string-match-p
                                "\\`[[:xdigit:]]\\{64\\}\\'" hash)
                               (not (assoc path hashes)))
                    (signal 'org-museum-publish-error
                            (list (format "%s contains invalid hashes"
                                          context))))
                  (push (cons path (downcase hash)) hashes)))
              (unless (= (length hashes) (length files))
                (signal 'org-museum-publish-error
                        (list (format "%s has incomplete hashes" context)))))
            (list :schema schema :files files :hashes (nreverse hashes)))))
    (error
     (if (eq (car err) 'org-museum-publish-error)
         (signal (car err) (cdr err))
       (signal 'org-museum-publish-error
               (list (format "Cannot parse %s: %s"
                             context (error-message-string err))))))))

(defun org-museum--publish-read-manifest (publish-root)
  "Read validated manifest data from PUBLISH-ROOT, or an empty baseline."
  (let ((manifest (expand-file-name org-museum--publish-manifest-name
                                    publish-root)))
    (if (not (file-regular-p manifest))
        (list :schema 0 :files nil :hashes nil)
      (condition-case err
          (with-temp-buffer
            (insert-file-contents manifest)
            (org-museum--publish-manifest-data-from-string
             (buffer-string) "Publish manifest"))
        (error
         (signal 'org-museum-publish-error
                 (list (format "Cannot read publish manifest: %s"
                               (error-message-string err)))))))))

(defun org-museum--publish-read-managed-files (publish-root)
  "Read safe managed relative paths from PUBLISH-ROOT's manifest."
  (plist-get (org-museum--publish-read-manifest publish-root) :files))

(defun org-museum--publish-write-manifest (publish-root files)
  "Write relative managed FILES and their hashes under PUBLISH-ROOT."
  (let ((manifest (expand-file-name org-museum--publish-manifest-name
                                    publish-root))
        (coding-system-for-write 'utf-8-unix)
        hashes)
    (dolist (relative files)
      (let ((file (expand-file-name relative publish-root)))
        (unless (and (file-regular-p file) (not (file-symlink-p file)))
          (signal 'org-museum-publish-error
                  (list (format "Cannot hash managed publish file: %s"
                                relative))))
        (push `((path . ,relative)
                (sha256 . ,(org-museum--publish-file-sha256 file)))
              hashes)))
    (with-temp-file manifest
      (insert (json-encode
               `((schemaVersion . 2)
                 (files . ,(vconcat (sort (copy-sequence files) #'string<)))
                 (hashes . ,(vconcat
                              (sort hashes
                                    (lambda (left right)
                                      (string< (alist-get 'path left)
                                               (alist-get 'path right)))))))))
      (insert "\n"))))

(defun org-museum--publish-full-change-plan
    (staging-root publish-root relative-files manifest)
  "Classify full-sync changes and conflicts against MANIFEST's hash baseline."
  (let* ((incoming (cons ".nojekyll" relative-files))
         (old-files (plist-get manifest :files))
         (baseline (plist-get manifest :hashes))
         (stale (cl-set-difference old-files incoming :test #'equal))
         create overwrite delete unchanged unknown conflicts)
    (dolist (relative incoming)
      (let* ((source (unless (equal relative ".nojekyll")
                       (expand-file-name relative staging-root)))
             (destination (expand-file-name relative publish-root))
             (incoming-hash (if source
                                (org-museum--publish-file-sha256 source)
                              (secure-hash 'sha256 "")))
             (baseline-hash (cdr (assoc relative baseline)))
             (destination-hash
              (and (file-regular-p destination)
                   (not (file-symlink-p destination))
                   (org-museum--publish-file-sha256 destination))))
        (cond
         ((and baseline-hash (not destination-hash))
          (push relative conflicts))
         ((and baseline-hash
               destination-hash
               (not (equal baseline-hash destination-hash)))
          (push relative conflicts))
         ((not destination-hash) (push relative create))
         ((equal incoming-hash destination-hash) (push relative unchanged))
         ((not baseline-hash) (push relative unknown))
         (t (push relative overwrite)))))
    (dolist (relative stale)
      (let* ((destination (expand-file-name relative publish-root))
             (baseline-hash (cdr (assoc relative baseline)))
             (destination-hash
              (and (file-regular-p destination)
                   (not (file-symlink-p destination))
                   (org-museum--publish-file-sha256 destination))))
        (cond
         ((not destination-hash) (push relative unchanged))
         ((and baseline-hash (not (equal baseline-hash destination-hash)))
          (push relative conflicts))
         ((not baseline-hash) (push relative unknown))
         (t (push relative delete)))))
    (list :create (sort create #'string<)
          :overwrite (sort overwrite #'string<)
          :delete (sort delete #'string<)
          :unchanged (sort unchanged #'string<)
          :unknown (sort unknown #'string<)
          :conflicts (sort (delete-dups conflicts) #'string<))))

(defun org-museum--publish-write-status
    (root state blocked-pages &optional mode policy-digest candidate-digest)
  "Write safe publication STATE and relative BLOCKED-PAGES below ROOT."
  (setq mode (or mode 'safe))
  (unless (and (memq state '(ready blocked review-required))
               (memq mode '(safe full))
               (listp blocked-pages)
               (cl-every #'org-museum--publish-managed-relative-path-p
                         blocked-pages)
               (if (eq state 'ready) (null blocked-pages) blocked-pages)
               (if (eq mode 'full)
                   (and (stringp policy-digest)
                        (string-match-p
                         "\\`[[:xdigit:]]\\{64\\}\\'" policy-digest)
                        (stringp candidate-digest)
                        (string-match-p
                         "\\`[[:xdigit:]]\\{64\\}\\'" candidate-digest))
                 (and (null policy-digest) (null candidate-digest))))
    (signal 'org-museum-publish-error
            '("Invalid publish privacy status")))
  (let ((status-file (expand-file-name org-museum--publish-status-name root))
        (coding-system-for-write 'utf-8-unix))
    (with-temp-file status-file
      (insert
       (json-encode
        `((schemaVersion . 2)
          (state . ,(symbol-name state))
          (mode . ,(symbol-name mode))
          (generatedAt . ,(format-time-string "%FT%T%z"))
          (policyDigest . ,policy-digest)
          (candidateDigest . ,candidate-digest)
          (blockedPages . ,(vconcat
                            (sort (copy-sequence blocked-pages) #'string<))))))
      (insert "\n"))
    status-file))

(defun org-museum--publish-read-status (root)
  "Read and validate the safe publication status below ROOT."
  (let ((status-file (expand-file-name org-museum--publish-status-name root)))
    (unless (file-regular-p status-file)
      (signal 'org-museum-publish-error
              '("Publish status is missing; rerun org-museum-publish-sync")))
    (condition-case err
        (let ((json-object-type 'alist)
              (json-array-type 'list)
              (json-key-type 'symbol))
          (with-temp-buffer
            (insert-file-contents status-file)
            (goto-char (point-min))
            (let* ((data (json-read))
                   (state-value (alist-get 'state data))
                   (state (and (stringp state-value)
                               (intern-soft state-value)))
                   (blocked (alist-get 'blockedPages data))
                   (schema (or (alist-get 'schemaVersion data) 0))
                   (mode-value (alist-get 'mode data))
                   (mode (if (= schema 1) 'safe
                           (and (stringp mode-value)
                                (intern-soft mode-value))))
                   (policy-digest (alist-get 'policyDigest data))
                   (candidate-digest (alist-get 'candidateDigest data)))
              (unless (and (memq schema '(1 2))
                           (memq state '(ready blocked review-required))
                           (memq mode '(safe full))
                           (listp blocked)
                           (cl-every #'stringp blocked)
                           (cl-every
                            #'org-museum--publish-managed-relative-path-p
                            blocked)
                           (if (eq state 'ready) (null blocked) blocked)
                           (if (eq mode 'full)
                               (and (= schema 2)
                                    (stringp policy-digest)
                                    (string-match-p
                                     "\\`[[:xdigit:]]\\{64\\}\\'"
                                     policy-digest)
                                    (stringp candidate-digest)
                                    (string-match-p
                                     "\\`[[:xdigit:]]\\{64\\}\\'"
                                     candidate-digest))
                             t))
                (signal 'org-museum-publish-error
                        '("Publish status is invalid; rerun publish sync")))
              (list :schema schema :state state :mode mode
                    :blocked-pages blocked
                    :policy-digest policy-digest
                    :candidate-digest candidate-digest))))
      (org-museum-publish-error (signal (car err) (cdr err)))
      (error
       (signal 'org-museum-publish-error
               (list (format "Cannot read publish status: %s"
                             (error-message-string err))))))))

(defun org-museum--publish-validate-ready-candidate (root managed-files)
  "Revalidate READY content in ROOT named by MANAGED-FILES before deployment."
  (let* ((root-files
          (cl-loop for relative in
                (list "index.html" "timeline.html" "graph.html" "related.html" ".nojekyll"
                         org-museum--publish-status-name)
                   for file = (expand-file-name relative root)
                   when (or (file-exists-p file) (file-symlink-p file))
                   collect relative))
         (tree-files
          (cl-loop for relative in '("pages" "resources")
                   for tree = (expand-file-name relative root)
                   when (or (file-exists-p tree) (file-symlink-p tree))
                   append
                   (mapcar
                    (lambda (file)
                      (org-museum--publish-normalise-relative-path
                       (file-relative-name file root)))
                    (org-museum--publish-tree-files root relative))))
         (namespace-files (append root-files tree-files))
         (omitted (cl-set-difference namespace-files managed-files
                                     :test #'equal))
         files placeholders)
    (when omitted
      (signal 'org-museum-publish-error
              (list (format
                     "Publish manifest omits managed candidate files: %s; rerun publish sync"
                     (mapconcat #'identity (sort omitted #'string<) ", ")))))
    (dolist (relative managed-files)
      (let ((file (expand-file-name relative root)))
        (unless (and (file-regular-p file) (not (file-symlink-p file)))
          (signal 'org-museum-publish-error
                  (list (format "Managed publish file is missing or unsafe: %s"
                                relative))))
        (push file files)
        (when (member (downcase (or (file-name-extension file) ""))
                      '("html" "htm"))
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (when (search-forward
                   "name=\"org-museum-privacy-placeholder\"" nil t)
              (push relative placeholders))))))
    (when placeholders
      (signal 'org-museum-publish-error
              (list (format
                     "Publish candidate still contains privacy placeholders: %s"
                     (mapconcat #'identity (nreverse placeholders) ", ")))))
    (let ((findings (org-museum--publish-privacy-findings
                     (nreverse files) root)))
      (when findings
        (signal 'org-museum-publish-error
                (list (format
                       "Publish candidate contains local paths in: %s; rerun publish sync"
                       (mapconcat
                        #'identity
                        (delete-dups
                         (mapcar #'org-museum-publish-finding-relative findings))
                        ", "))))))
    t))

(defun org-museum--publish-managed-namespace-files (root)
  "Return every existing file in ROOT's managed publishing namespaces."
  (let (relative-files)
    (dolist (relative (list "index.html" "timeline.html" "graph.html" "related.html" ".nojekyll"
                            org-museum--publish-status-name))
      (let ((file (expand-file-name relative root)))
        (when (or (file-exists-p file) (file-symlink-p file))
          (unless (and (file-regular-p file) (not (file-symlink-p file)))
            (signal 'org-museum-publish-error
                    (list (format "Unsafe managed publish entry: %s" relative))))
          (push relative relative-files))))
    (dolist (tree '("pages" "resources"))
      (let ((directory (expand-file-name tree root)))
        (when (or (file-exists-p directory) (file-symlink-p directory))
          (dolist (file (org-museum--publish-tree-files root tree))
            (push (org-museum--publish-normalise-relative-path
                   (file-relative-name file root))
                  relative-files)))))
    (sort (delete-dups relative-files) #'string<)))

(defun org-museum--publish-validate-manifest-integrity (root manifest)
  "Reject hash changes and unlisted managed namespace files below ROOT."
  (let ((files (sort (copy-sequence (plist-get manifest :files)) #'string<))
        (hashes (plist-get manifest :hashes)))
    (unless (equal files (org-museum--publish-managed-namespace-files root))
      (signal 'org-museum-publish-error
              '("Managed publish namespace differs from its manifest; rerun sync")))
    (when (= (plist-get manifest :schema) 2)
      (dolist (relative files)
        (let ((expected (cdr (assoc relative hashes)))
              (file (expand-file-name relative root)))
          (unless (and expected
                       (file-regular-p file)
                       (equal expected
                              (org-museum--publish-file-sha256 file)))
            (signal 'org-museum-publish-error
                    (list (format
                           "Managed publish file changed after sync: %s"
                           relative)))))))))

(defun org-museum--publish-validate-full-ready-candidate
    (root manifest status)
  "Re-evaluate full-sync policy, hashes, scope and authorisations in ROOT."
  (unless (= (plist-get manifest :schema) 2)
    (signal 'org-museum-publish-error
            '("Full-sync hash baseline is missing; rerun full sync")))
  (let* ((policy (org-museum--publish-read-policy))
         (policy-digest (org-museum--publish-policy-digest policy))
         (content-files
          (cl-remove-if
           (lambda (relative)
             (member relative
                     (list ".nojekyll" org-museum--publish-status-name)))
           (plist-get manifest :files))))
    (unless (equal policy-digest (plist-get status :policy-digest))
      (signal 'org-museum-publish-error
              '("Sharing policy changed after sync; rerun full sync")))
    (dolist (relative content-files)
      (unless (org-museum--publish-policy-selected-p policy relative)
        (signal 'org-museum-publish-error
                (list (format
                       "Excluded publish file is still present: %s; rerun full sync"
                       relative)))))
    (unless (equal
             (org-museum--publish-candidate-digest root content-files)
             (plist-get status :candidate-digest))
      (signal 'org-museum-publish-error
              '("Full-sync candidate changed after review; rerun full sync")))
    (let* ((files (mapcar (lambda (relative)
                            (expand-file-name relative root))
                          content-files))
           (findings (org-museum--publish-privacy-findings
                      files root (plist-get policy :detectors)))
           (records (org-museum--publish-finding-records findings policy nil))
           (unresolved
            (cl-remove-if
             (lambda (record)
               (eq (plist-get record :status) 'authorized))
             records)))
      (when unresolved
        (signal 'org-museum-publish-error
                '("Full-sync authorisation is missing or stale; rerun full sync"))))))

(defun org-museum--publish-write-placeholder (file)
  "Replace staged HTML FILE with a privacy-safe preview placeholder."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file file
      (insert
       "<!doctype html>\n"
       "<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
       "<meta name=\"robots\" content=\"noindex,nofollow\">"
       "<meta name=\"org-museum-privacy-placeholder\" content=\"blocked\">"
       "<title>Org Museum privacy review</title></head>"
       "<body><main><h1>Org Museum privacy review</h1>"
       "<p>本页包含仅适用于本机的引用，已在发布候选中安全隐藏。</p>"
       "<p>请返回 Emacs 查看 Org Museum Privacy Report 并修正源笔记。</p>"
       "</main></body></html>\n"))))

(defun org-museum--publish-sanitise-staging
    (staging-root relative-files findings)
  "Make FINDINGS safe and return a named candidate for STAGING-ROOT."
  (let ((blocked (delete-dups
                  (delq nil (mapcar #'org-museum-publish-finding-relative
                                    findings))))
        (retained (copy-sequence relative-files)))
    (dolist (relative blocked)
      (let ((file (expand-file-name relative staging-root)))
        (if (member (downcase (or (file-name-extension file) ""))
                    '("html" "htm"))
            (org-museum--publish-write-placeholder file)
          (when (file-exists-p file)
            (delete-file file))
          (setq retained (delete relative retained)))))
    (make-org-museum-publish-candidate
     :files retained
     :blocked (sort blocked #'string<)
     :state (if findings 'blocked 'ready))))

(defun org-museum--publish-copy-to-staging (files export-root staging-root)
  "Copy public FILES from EXPORT-ROOT into STAGING-ROOT and return relatives."
  (let (relative-files)
    (dolist (source files (nreverse relative-files))
      (let* ((relative (org-museum--publish-normalise-relative-path
                        (file-relative-name source export-root)))
             (destination (and relative
                               (expand-file-name relative staging-root))))
        (unless (and relative
                     (org-museum--publish-managed-relative-path-p relative)
                     (file-in-directory-p source export-root))
          (signal 'org-museum-publish-error
                  (list (format "Export file escapes the public tree: %s" source))))
        (make-directory (file-name-directory destination) t)
        (copy-file source destination t t t)
        (push relative relative-files)))))

(defun org-museum--publish-validate-root-ancestors (publish-root)
  "Reject linked or dangling ancestors of PUBLISH-ROOT before creation."
  (let ((probe (directory-file-name
                (file-name-as-directory (expand-file-name publish-root)))))
    ;; Validate every existing ancestor before creating the checkout.  This
    ;; also catches a dangling link, for which `file-exists-p' is nil.
    (while (and probe (not (file-exists-p probe)))
      (when (file-symlink-p probe)
        (signal 'org-museum-publish-error
                (list (format "Publish path contains a dangling link: %s"
                              probe))))
      (let ((parent (directory-file-name (file-name-directory probe))))
        (setq probe (unless (equal parent probe) parent))))
    (when (and probe
               (or (file-symlink-p probe)
                   (not (equal (org-museum--publish-path-key probe)
                               (org-museum--publish-path-key
                                (file-truename probe))))))
      (signal 'org-museum-publish-error
              (list (format "Publish directory resolves through a link: %s"
                            publish-root))))))

(defun org-museum--publish-validate-destination-paths (publish-root targets)
  "Reject links and paths escaping PUBLISH-ROOT among TARGETS."
  (let ((root (file-name-as-directory (expand-file-name publish-root))))
    (org-museum--publish-validate-root-ancestors root)
    (unless (file-directory-p root)
      (signal 'org-museum-publish-error
              (list (format "Publish directory is not ready: %s" root))))
    (let ((true-root (file-name-as-directory (file-truename root))))
      (dolist (target targets)
        (let ((cursor (expand-file-name target)))
          (unless (file-in-directory-p cursor root)
            (signal 'org-museum-publish-error
                    (list (format "Publish destination escapes checkout: %s"
                                  cursor))))
          (while (and (file-in-directory-p cursor root)
                      (not (equal (org-museum--publish-path-key cursor)
                                  (org-museum--publish-path-key root))))
            (when (file-symlink-p cursor)
              (signal 'org-museum-publish-error
                      (list (format "Linked publish destination is unsafe: %s"
                                    cursor))))
            (when (file-exists-p cursor)
              (let ((true-cursor (file-truename cursor)))
                (unless (or (equal (org-museum--publish-path-key true-cursor)
                                   (org-museum--publish-path-key true-root))
                            (file-in-directory-p true-cursor true-root))
                  (signal 'org-museum-publish-error
                          (list (format
                                 "Publish destination resolves outside checkout: %s"
                                 cursor))))))
            (setq cursor
                  (directory-file-name (file-name-directory cursor)))))))))

(defun org-museum--publish-apply-staging
    (staging-root publish-root relative-files old-files)
  "Transactionally install RELATIVE-FILES and remove stale OLD-FILES."
  (let* ((managed-files (cons ".nojekyll" relative-files))
         (stale (cl-set-difference old-files managed-files :test #'equal))
         (manifest-relative org-museum--publish-manifest-name)
         (targets
          (delete-dups
           (mapcar (lambda (relative) (expand-file-name relative publish-root))
                   (append managed-files stale (list manifest-relative)))))
         (root-existed (file-directory-p publish-root))
         snapshots preexisting preexisting-directories)
    (org-museum--publish-validate-root-ancestors publish-root)
    (condition-case err
        (progn
          (make-directory publish-root t)
          (org-museum--publish-validate-destination-paths publish-root targets)
          (setq snapshots (org-museum--snapshot-files targets)
                preexisting
                (mapcar (lambda (file) (cons file (file-exists-p file)))
                        targets)
                preexisting-directories
                (mapcar
                 (lambda (directory)
                   (cons directory (file-directory-p directory)))
                 (sort
                  (delete-dups
                   (cl-loop for target in targets
                            append
                            (let ((cursor (directory-file-name
                                           (file-name-directory target)))
                                  directories)
                              (while (and (file-in-directory-p cursor publish-root)
                                          (not (equal
                                                (org-museum--publish-path-key cursor)
                                                (org-museum--publish-path-key
                                                 publish-root))))
                                (push cursor directories)
                                (setq cursor
                                      (directory-file-name
                                       (file-name-directory cursor))))
                              directories)))
                  (lambda (left right) (> (length left) (length right))))))
          (dolist (relative relative-files)
            (let ((source (expand-file-name relative staging-root))
                  (destination (expand-file-name relative publish-root)))
              (make-directory (file-name-directory destination) t)
              (copy-file source destination t t t)))
          (with-temp-file (expand-file-name ".nojekyll" publish-root))
          (dolist (relative stale)
            (let ((file (expand-file-name relative publish-root)))
              (when (and (org-museum--publish-managed-relative-path-p relative)
                         (file-regular-p file)
                         (not (file-symlink-p file)))
                (delete-file file))))
          (org-museum--publish-write-manifest publish-root managed-files)
          managed-files)
      ((error quit)
       (org-museum--restore-file-snapshots snapshots)
       (dolist (entry preexisting)
         (when (and (not (cdr entry)) (file-regular-p (car entry)))
           (delete-file (car entry))))
       (dolist (entry preexisting-directories)
         (when (and (not (cdr entry)) (file-directory-p (car entry)))
           (ignore-errors (delete-directory (car entry)))))
       (unless root-existed
         (when (file-directory-p publish-root)
           (delete-directory publish-root t)))
       (signal 'org-museum-publish-error
               (list (format "Publish sync rolled back: %s"
                             (error-message-string err))))))))

;;;###autoload
(defun org-museum-publish-sync ()
  "Export the site and safely mirror a ready or privacy-blocked preview."
  (interactive)
  (org-museum-export-all)
  (pcase-let* ((`(,export-root ,publish-root)
                (org-museum--publish-validate-directories))
               (source-files (org-museum--publish-source-files export-root))
               (old-files (org-museum--publish-read-managed-files publish-root))
               (staging-root (make-temp-file "org-museum-publish-" t)))
    (unwind-protect
        (let ((relative-files
               (org-museum--publish-copy-to-staging
                source-files export-root staging-root)))
          (let* ((staged-files
                  (mapcar (lambda (relative)
                            (expand-file-name relative staging-root))
                          relative-files))
                 (findings
                  (org-museum--publish-privacy-findings
                   staged-files staging-root))
                 (candidate
                  (org-museum--publish-sanitise-staging
                   staging-root relative-files findings))
                 (retained (org-museum-publish-candidate-files candidate))
                 (blocked (org-museum-publish-candidate-blocked candidate))
                 (state (org-museum-publish-candidate-state candidate)))
            (org-museum--publish-write-status staging-root state blocked)
            (setq retained (append retained
                                   (list org-museum--publish-status-name)))
            (let* ((safe-files
                    (mapcar (lambda (relative)
                              (expand-file-name relative staging-root))
                            retained))
                   (residual
                    (org-museum--publish-privacy-findings
                     safe-files staging-root)))
              (when residual
                (signal 'org-museum-publish-error
                        '("Privacy-safe preview generation left local paths"))))
            (org-museum--publish-apply-staging
             staging-root publish-root retained old-files)
            (let ((report
                   (org-museum--publish-render-privacy-report findings)))
              (if findings
                  (progn
                    (when (called-interactively-p 'interactive)
                      (pop-to-buffer report))
                    (message
                     "Org Museum safe preview updated; deploy blocked by %d privacy findings"
                     (length findings))
                    nil)
                (message "Org Museum publish sync complete: %s" publish-root)
                publish-root))))
      (when (file-directory-p staging-root)
        (delete-directory staging-root t)))))

;;;###autoload
(defun org-museum-publish-sync-full (&optional interactive-invocation)
  "Interactively install a configurable byte-for-byte local publish mirror.
Unlike `org-museum-publish-sync', this command does not replace or remove
selected files merely because privacy findings remain.  It always previews the
effective sharing scope and requires the exact high-risk confirmation phrase.
Unresolved findings produce a `review-required' state that cannot be deployed."
  (interactive (list t))
  (unless interactive-invocation
    (signal 'org-museum-publish-error
            '("Full publish sync must be invoked interactively")))
  (org-museum-export-all)
  (pcase-let* ((`(,export-root ,publish-root)
                (org-museum--publish-validate-directories))
               (_policy-location
                (org-museum--publish-validate-policy-location
                 export-root publish-root))
               (policy (org-museum--publish-read-policy))
               (source-files (org-museum--publish-source-files export-root))
               (inventory
                (mapcar
                 (lambda (file)
                   (cons (org-museum--publish-normalise-relative-path
                          (file-relative-name file export-root))
                         file))
                 source-files))
               (selected
                (cl-remove-if-not
                 (lambda (entry)
                   (org-museum--publish-policy-selected-p policy (car entry)))
                 inventory))
               (excluded (mapcar #'car
                                 (cl-set-difference inventory selected
                                                    :test #'equal)))
               (findings (org-museum--publish-privacy-findings
                          source-files export-root
                          (plist-get policy :detectors)))
               (records (org-museum--publish-finding-records
                         findings policy excluded))
               (unresolved
                (cl-remove-if
                 (lambda (record)
                   (not (eq (plist-get record :status) 'unresolved)))
                 records))
               (blocked (sort
                         (delete-dups
                          (mapcar
                           (lambda (record)
                             (org-museum-publish-finding-relative
                              (plist-get record :finding)))
                           unresolved))
                         #'string<))
               (state (if unresolved 'review-required 'ready))
               (old-manifest (org-museum--publish-read-manifest publish-root))
               (old-files (plist-get old-manifest :files))
               (staging-root (make-temp-file "org-museum-publish-full-" t)))
    (unless selected
      (signal 'org-museum-publish-error
              '("Publish sharing policy selects no exported files")))
    (unwind-protect
        (let* ((relative-files
                (org-museum--publish-copy-to-staging
                 (mapcar #'cdr selected) export-root staging-root))
               change-plan)
          (org-museum--publish-write-status
           staging-root state blocked 'full
           (org-museum--publish-policy-digest policy)
           (org-museum--publish-candidate-digest
            staging-root relative-files))
          (setq relative-files
                (append relative-files (list org-museum--publish-status-name)))
          (org-museum--publish-render-privacy-report findings)
          (setq change-plan
                (org-museum--publish-full-change-plan
                 staging-root publish-root relative-files old-manifest))
          (let ((preview
                  (org-museum--publish-render-full-preview
                   policy records (mapcar #'car selected) excluded state
                   change-plan)))
            (pop-to-buffer preview))
          (when (plist-get change-plan :conflicts)
            (signal
             'org-museum-publish-error
             (list
              (format
               "Full sync stopped before confirmation: managed files were edited after the last sync: %s"
               (mapconcat #'identity
                          (plist-get change-plan :conflicts) ", ")))))
          (unless (equal (read-string
                          (format "Type %s to continue: "
                                  org-museum--publish-full-confirmation))
                         org-museum--publish-full-confirmation)
            (signal 'org-museum-publish-error
                    '("Full publish sync confirmation did not match; no files changed")))
          (org-museum--publish-apply-staging
           staging-root publish-root relative-files old-files)
          (message "Org Museum full mirror updated: %s (%s)"
                   publish-root state)
          publish-root)
      (when (file-directory-p staging-root)
        (delete-directory staging-root t)))))

(defun org-museum--publish-redact-command-output (output)
  "Remove credentials and token-shaped secrets from process OUTPUT."
  (let ((redacted (replace-regexp-in-string
                   "\\(https?://\\)[^/@[:space:]]+@" "\\1***@" output t)))
    (setq redacted
          (replace-regexp-in-string
           "\\(?:gh[opsu]_[[:alnum:]_]+\\|github_pat_[[:alnum:]_]+\\)"
           "[REDACTED]" redacted t))
    (replace-regexp-in-string
     "\\([Aa]uthorization:[[:space:]]*\\(?:[Bb]earer[[:space:]]+\\)?\\)[^[:space:]]+"
     "\\1[REDACTED]" redacted t)))

(defun org-museum--publish-run (program arguments &optional accepted-statuses)
  "Run PROGRAM with ARGUMENTS in the publish directory.
Return (STATUS . OUTPUT).  Signal unless STATUS is in ACCEPTED-STATUSES,
which defaults to (0)."
  (unless (executable-find program)
    (signal 'org-museum-publish-error
            (list (format "Required executable was not found: %s" program))))
  (let* ((default-directory
          (file-name-as-directory (expand-file-name org-museum-publish-directory)))
         (buffer (get-buffer-create "*Org Museum Publish*"))
         (process-buffer (generate-new-buffer " *Org Museum Publish Process*"))
         (accepted (or accepted-statuses '(0)))
         status raw-output log-output)
    (unwind-protect
        (progn
          ;; Git and GitHub CLI emit UTF-8 paths.  On Windows, leaving process
          ;; decoding implicit can preserve those bytes as a unibyte string,
          ;; so managed Chinese paths no longer compare equal to JSON paths.
          ;; Command-line arguments, however, must use the Windows locale so
          ;; the same paths can be passed back to Git for staging.
          (let ((coding-system-for-read 'utf-8)
                (coding-system-for-write locale-coding-system))
            (setq status
                  (apply #'process-file program nil process-buffer t arguments)))
          (with-current-buffer process-buffer
            (setq raw-output (buffer-string)
                  log-output
                  (org-museum--publish-redact-command-output raw-output)))
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert (org-museum--publish-redact-command-output
                     (format "\n$ %s %s\n" program
                             (mapconcat #'shell-quote-argument arguments " "))))
            (insert log-output)))
      (kill-buffer process-buffer))
    (unless (memq status accepted)
      (signal 'org-museum-publish-error
              (list (format "%s failed (%s): %s"
                            program status (string-trim log-output)))))
    (cons status raw-output)))

(defun org-museum--publish-manifest-files-from-string (contents context)
  "Return validated managed paths from JSON CONTENTS, labelled by CONTEXT."
  (plist-get (org-museum--publish-manifest-data-from-string contents context)
             :files))

(defun org-museum--publish-head-managed-files ()
  "Return managed files recorded by the current Git HEAD, if any."
  (pcase-let ((`(,status . ,output)
               (org-museum--publish-run
                "git" (list "show" (concat "HEAD:" org-museum--publish-manifest-name))
                '(0 128))))
    (if (= status 0)
        (org-museum--publish-manifest-files-from-string output "HEAD publish manifest")
      nil)))

(defun org-museum--publish-git-status-paths ()
  "Return changed paths from porcelain Git status without shell parsing."
  (let* ((result (org-museum--publish-run
                  "git" '("status" "--porcelain=v1" "-z"
                          "--untracked-files=all")))
         (records (split-string (cdr result) "\0" t))
         paths)
    (while records
      (let* ((record (pop records))
             (status (substring record 0 (min 2 (length record))))
             (path (if (> (length record) 3) (substring record 3) "")))
        (when (or (member (substring status 0 1) '("R" "C"))
                  (and (> (length status) 1)
                       (member (substring status 1 2) '("R" "C"))))
          (when records (push (pop records) paths)))
        (unless (string-empty-p path)
          (push path paths))))
    (delete-dups (nreverse paths))))

(defun org-museum--publish-validate-dirty-paths (paths current previous)
  "Reject PATHS not owned by CURRENT or PREVIOUS publish manifests."
  (let* ((allowed (delete-dups
                   (append current previous
                           (list org-museum--publish-manifest-name))))
         (unexpected
          (cl-remove-if
           (lambda (path)
             (member (org-museum--publish-normalise-relative-path path)
                     allowed))
           paths)))
    (when unexpected
      (signal 'org-museum-publish-error
              (list (format "Unmanaged repository changes must be resolved: %s"
                            (mapconcat #'identity unexpected ", ")))))))

(defun org-museum--publish-repository-config ()
  "Validate publishing configuration and return (DIRECTORY REPOSITORY BRANCH)."
  (unless (and org-museum-publish-directory
               (file-directory-p org-museum-publish-directory))
    (signal 'org-museum-publish-error
            '("Run org-museum-publish-sync before deploying")))
  (unless (and (stringp org-museum-publish-repository)
               (string-match-p
                "\\`[[:alnum:]_.-]+/[[:alnum:]_.-]+\\'"
                org-museum-publish-repository))
    (signal 'org-museum-publish-error
            '("org-museum-publish-repository must be OWNER/REPOSITORY")))
  (unless (and (stringp org-museum-publish-branch)
               (not (string-empty-p org-museum-publish-branch)))
    (signal 'org-museum-publish-error '("Publish branch is not configured")))
  (unless (and (stringp org-museum-publish-remote)
               (not (string-empty-p org-museum-publish-remote)))
    (signal 'org-museum-publish-error '("Publish remote is not configured")))
  (list (file-name-as-directory
         (expand-file-name org-museum-publish-directory))
        org-museum-publish-repository
        org-museum-publish-branch))

(defun org-museum--publish-confirm-bootstrap (repository directory)
  "Confirm creation of public REPOSITORY backed by DIRECTORY."
  (y-or-n-p
   (format "Create PUBLIC GitHub repository %s from %s? " repository directory)))

(defun org-museum--publish-bootstrap-repository (directory repository branch)
  "Initialise DIRECTORY and create public GitHub REPOSITORY on BRANCH."
  (unless (org-museum--publish-confirm-bootstrap repository directory)
    (signal 'org-museum-publish-error '("GitHub repository creation cancelled")))
  (org-museum--publish-run "git" (list "init" "-b" branch))
  (org-museum--publish-run
   "gh" (list "repo" "create" repository "--public"
              "--description" "Org Museum published notes"
              "--source" directory "--remote" org-museum-publish-remote)))

(defun org-museum--publish-remote-url-valid-p (url repository)
  "Return non-nil when GitHub URL canonically names REPOSITORY."
  (let ((trimmed (string-trim url))
        (repo (regexp-quote repository)))
    (or (string-match-p
         (concat "\\`https://github\\.com/" repo "\\(?:\\.git\\)?\\'")
         trimmed)
        (string-match-p
         (concat "\\`git@github\\.com:" repo "\\(?:\\.git\\)?\\'")
         trimmed)
        (string-match-p
         (concat "\\`ssh://git@github\\.com/" repo "\\(?:\\.git\\)?\\'")
         trimmed))))

(defun org-museum--publish-ensure-remote (repository)
  "Verify that the configured remote targets REPOSITORY."
  (pcase-let ((`(,status . ,output)
               (org-museum--publish-run
                "git" (list "remote" "get-url" org-museum-publish-remote)
                '(0 2))))
    (unless (and (= status 0)
                 (org-museum--publish-remote-url-valid-p output repository))
      (signal 'org-museum-publish-error
              (list (format "Remote %s does not target %s"
                            org-museum-publish-remote repository))))))

(defun org-museum--publish-ensure-current-branch (branch)
  "Refuse to publish unless the checked-out Git branch is BRANCH."
  (let ((current
         (string-trim
          (cdr (org-museum--publish-run
                "git" '("symbolic-ref" "--quiet" "--short" "HEAD"))))))
    (unless (equal current branch)
      (signal 'org-museum-publish-error
              (list (format "Publish checkout is on %s, expected %s"
                            (if (string-empty-p current) "detached HEAD" current)
                            branch))))))

(defun org-museum--publish-check-remote-history (branch)
  "Fetch BRANCH and refuse remote-ahead or diverged history."
  (pcase-let ((`(,remote-status . ,_)
               (org-museum--publish-run
                "git" (list "ls-remote" "--exit-code" "--heads"
                            org-museum-publish-remote branch)
                '(0 2))))
    (when (= remote-status 0)
      (org-museum--publish-run
       "git" (list "fetch" org-museum-publish-remote branch))
      (pcase-let ((`(,head-status . ,_)
                   (org-museum--publish-run
                    "git" '("rev-parse" "--verify" "HEAD") '(0 128))))
        (when (or (/= head-status 0)
                  (/= 0 (car (org-museum--publish-run
                              "git"
                              (list "merge-base" "--is-ancestor"
                                    (format "%s/%s"
                                            org-museum-publish-remote branch)
                                    "HEAD")
                              '(0 1)))))
          (signal 'org-museum-publish-error
                  '("Remote branch is ahead or diverged; resolve it manually")))))))

(defun org-museum--publish-stage-and-commit (paths)
  "Stage validated PATHS and commit them; return non-nil when committed."
  (when paths
    (org-museum--publish-run "git" (append '("add" "-A" "--") paths)))
  (let ((diff-status
         (car (org-museum--publish-run
               "git" '("diff" "--cached" "--quiet") '(0 1)))))
    (when (= diff-status 1)
      (org-museum--publish-run
       "git" (list "commit" "-m"
                   (format-time-string "Publish Org Museum %Y-%m-%d %H:%M")))
      t)))

(defun org-museum--publish-configure-pages (repository branch)
  "Create or correct GitHub Pages for REPOSITORY on BRANCH root."
  (pcase-let ((`(,status . ,output)
               (org-museum--publish-run
                "gh" (list "api" (format "repos/%s/pages" repository))
                '(0 1))))
    (when (and (= status 1)
               (not (string-match-p "\\(?:404\\|[Nn]ot [Ff]ound\\)" output)))
      (signal 'org-museum-publish-error
              (list (format "Cannot inspect GitHub Pages: %s"
                            (string-trim output)))))
    (org-museum--publish-run
     "gh" (append
           (list "api" "-X" (if (= status 0) "PUT" "POST")
                 (format "repos/%s/pages" repository)
                 "-f" "build_type=legacy"
                 "-f" (format "source[branch]=%s" branch)
                 "-f" "source[path]=/")))))

;;;###autoload
(defun org-museum-publish-deploy ()
  "Commit the managed publish mirror, push it, and configure GitHub Pages."
  (interactive)
  (pcase-let* ((`(,directory ,repository ,branch)
                (org-museum--publish-repository-config))
               (manifest (org-museum--publish-read-manifest directory))
               (current (plist-get manifest :files))
               (status (org-museum--publish-read-status directory)))
    (unless current
      (signal 'org-museum-publish-error
              '("Publish manifest is missing or empty; run publish sync")))
    (when (memq (plist-get status :state) '(blocked review-required))
      (when (and (called-interactively-p 'interactive)
                 (get-buffer org-museum--publish-privacy-buffer))
        (pop-to-buffer org-museum--publish-privacy-buffer))
      (signal
       'org-museum-publish-error
       (list
        (if (eq (plist-get status :state) 'review-required)
            (format
             "Full-sync sharing review is incomplete for: %s. Resolve, exclude, or explicitly authorise every finding, then rerun full sync"
             (mapconcat #'identity (plist-get status :blocked-pages) ", "))
          (format
           "Publish privacy review is blocked for: %s. Rerun org-museum-publish-sync after fixing the source notes"
           (mapconcat #'identity (plist-get status :blocked-pages) ", "))))))
    (org-museum--publish-validate-manifest-integrity directory manifest)
    (if (eq (plist-get status :mode) 'full)
        (org-museum--publish-validate-full-ready-candidate
         directory manifest status)
      (org-museum--publish-validate-ready-candidate directory current))
    (unless (file-directory-p (expand-file-name ".git" directory))
      (org-museum--publish-run "gh" '("auth" "status"))
      (org-museum--publish-bootstrap-repository directory repository branch))
    (let* ((previous (org-museum--publish-head-managed-files))
           (dirty (org-museum--publish-git-status-paths)))
      (org-museum--publish-validate-dirty-paths dirty current previous)
      (org-museum--publish-run "gh" '("auth" "status"))
      (org-museum--publish-ensure-remote repository)
      (org-museum--publish-ensure-current-branch branch)
      (org-museum--publish-check-remote-history branch)
      (let ((committed (org-museum--publish-stage-and-commit dirty)))
        ;; Always push: this also safely retries a commit left ahead after a
        ;; previous network failure.  Git is a no-op when both sides match.
        (org-museum--publish-run
         "git" (list "push" "-u" org-museum-publish-remote branch))
        (org-museum--publish-configure-pages repository branch)
        (let* ((sha (string-trim
                     (cdr (org-museum--publish-run
                           "git" '("rev-parse" "HEAD")))))
               (repository-url (format "https://github.com/%s" repository))
               (owner-and-repo (split-string repository "/" t))
               (url (format "https://%s.github.io/%s/"
                            (car owner-and-repo) (cadr owner-and-repo))))
          (with-current-buffer (get-buffer-create "*Org Museum Publish*")
            (goto-char (point-max))
            (insert (format
                     "\nDeploy complete%s\nCommit: %s\nRepository: %s\nSite: %s\n"
                     (if committed "" " (no content changes)")
                     sha repository-url url)))
          (message "Org Museum deploy complete%s: %s (%s)"
                   (if committed "" " (no content changes)") url sha)
          url)))))

(defun org-museum--export-all-current ()
  "Transactionally export the complete site using the current runtime."
  (let* ((static-targets
          (append
           (list (org-museum--css-output-path)
                 (org-museum--d3-resource-path)
                 (org-museum--hljs-css-resource-path)
                 (org-museum--hljs-js-resource-path)
                 (org-museum--hljs-lisp-js-resource-path)
                 (org-museum--theme-resource-path)
                 (expand-file-name "index.html" (org-museum--shared-root))
                 (org-museum--timeline-output-path)
                 (expand-file-name "graph.html" (org-museum--shared-root))
                 (org-museum--related-output-path)
                 (org-museum--related-data-resource-path)
                 (org-museum--runtime-resource-path 'related)
                 (org-museum--runtime-resource-path 'timeline)
                 (org-museum--export-manifest-path)
                 (org-museum--index-file-path))
           (mapcar (lambda (entry)
                     (org-museum--font-resource-path (car entry)))
                   org-museum--font-resources)
           (mapcar #'org-museum--icon-resource-path
                   org-museum--icon-resources)))
         (page-targets
          (mapcar #'org-museum--export-filename (org-museum--scan-files)))
         (cleanup-targets
          (when org-museum-clean-stale-html-on-full-export
            (org-museum--existing-safe-page-html-files)))
         (targets (delete-dups
                   (append static-targets page-targets cleanup-targets)))
         (snapshots (org-museum--snapshot-files targets))
         (preexisting (make-hash-table :test #'equal))
         (original-index org-museum--index))
    (dolist (file targets)
      (puthash file (file-exists-p file) preexisting))
    (condition-case err
        (org-museum--export-all-transaction)
      (error
       (setq org-museum--index original-index)
       (org-museum--restore-file-snapshots snapshots)
       (dolist (file targets)
         (when (and (not (gethash file preexisting))
                    (file-regular-p file))
           (delete-file file)))
       (if (eq (car err) 'org-museum-export-failed)
           (signal (car err) (cdr err))
         (signal 'org-museum-export-failed
                 (list (error-message-string err) err)))))))

(defun org-museum--export-all-transaction ()
  "Export the complete site using the currently loaded runtime."
  (let ((org-museum--resource-deployment-cache (make-hash-table :test 'eq))
        (org-museum--full-export-in-progress t)
        (total   0)
        (success 0)
        (failed  '())
        timings (stage-start (float-time)))
    (org-museum--ensure-css-deployed)
    (org-museum--hljs-assets)
    (org-museum--ensure-d3-deployed)
    (push (cons 'resources (- (float-time) stage-start)) timings)
    (setq stage-start (float-time))
    (org-museum-index-build t)
    (push (cons 'index (- (float-time) stage-start)) timings)
    (setq total (hash-table-count (org-museum-index-pages org-museum--index)))
    (setq stage-start (float-time))
    (maphash
     (lambda (_id page)
       (condition-case err
           (progn (org-museum-export-page (org-museum-page-path page) t)
                  (cl-incf success))
         (error (push (list (org-museum-page-id page) (error-message-string err)
                            (org-museum-page-path page))
                      failed))))
     (org-museum-index-pages org-museum--index))
    (push (cons 'pages (- (float-time) stage-start)) timings)
    (let ((graph-file nil)
          (cleaned 0)
          (complete (and (null failed) (= success total))))
      (when complete
        (condition-case err
            (progn
              (setq stage-start (float-time))
              (org-museum--generate-index-page)
              (push (cons 'homepage (- (float-time) stage-start)) timings)
              (setq stage-start (float-time))
              (setq graph-file (org-museum-export-graph :silent t))
              (push (cons 'graph (- (float-time) stage-start)) timings)
              (setq stage-start (float-time))
              (org-museum--export-related-reading-current)
              (push (cons 'related (- (float-time) stage-start)) timings)
              (setq stage-start (float-time))
              (org-museum--export-timeline-current)
              (push (cons 'timeline (- (float-time) stage-start)) timings)
              (when (> total 0)
                (org-museum--write-export-manifest)
                (when org-museum-clean-stale-html-on-full-export
                  (setq cleaned
                        (org-museum--clean-stale-exports-if-safe)))))
          (error
           (push (list "site-finalization" (error-message-string err) nil)
                 failed))))
      (message "Export complete: %d/%d pages, %d failed"
               success total (length failed))
      (message "Org Museum timings: %s"
               (mapconcat (lambda (entry)
                            (format "%s=%.3fs" (car entry) (cdr entry)))
                          (nreverse timings) ", "))
      (when (> cleaned 0)
        (message "Org Museum removed %d stale page HTML files" cleaned))
      (when failed
        (org-museum--report-failures failed))
      (when (and org-museum-open-browser-after-export
                 org-museum-open-page-after-export
                 (null failed)
                 graph-file)
        (let ((open-file
               (pcase org-museum-open-page-after-export
                 ('timeline (org-museum--timeline-output-path))
                 ('graph graph-file)
                 (_ (expand-file-name "index.html"
                                      (org-museum--shared-root))))))
          (browse-url
           (concat "file:///"
                   (replace-regexp-in-string "\\\\" "/" open-file)))))
      (when failed
        (signal 'org-museum-export-failed
                (list (format "%d/%d pages exported; %d failed"
                              success total (length failed))
                      (nreverse failed)))))))

(defun org-museum--report-failures (failed)
  "Show FAILED export items in a buffer."
  (with-current-buffer (get-buffer-create "*Org Museum Failures*")
    (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "* Export Failures\n\n")
    (dolist (item failed)
      (let ((path (caddr item)))
        (insert (format "- %s :: %s\n  " (car item) (cadr item)))
        (when path
          (insert-text-button
           "打开源文件" 'follow-link t
           'action (lambda (_button) (find-file path)))
          (insert "  ")
          (insert-text-button
           "重试此页" 'follow-link t
           'action (lambda (_button) (org-museum-export-page path t))))
        (insert "\n")))
    (special-mode))
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
      (insert (org-museum--externalize-page-runtime
               (org-museum--build-index-html cats graph-href index-html)
               index-html 'index)))))

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


(defun org-museum--build-topbar (out-file &optional kind)
  "Return the shared top navigation for OUT-FILE.
KIND is one of `home', `article', `timeline', `graph', or `related'."
  (let* ((shared-root (org-museum--shared-root))
         (home-href (org-museum--relative-path
                     (expand-file-name "index.html" shared-root) out-file))
         (graph-href (org-museum--relative-path
                     (expand-file-name "graph.html" shared-root) out-file))
         (timeline-href (org-museum--relative-path
                         (org-museum--timeline-output-path) out-file))
         (related-href (org-museum--relative-path
                        (org-museum--related-output-path) out-file))
         (placeholder (pcase kind
                        ('article "搜索此 Wiki…")
                        ('timeline "搜索时间轴…")
                        ('graph "搜索节点…")
                        (_ "搜索标题、分类或标签…")))
         (search-label (pcase kind
                         ('graph "搜索图谱节点")
                         ('timeline "搜索时间轴")
                         (_ "全局搜索")))
         (drawer-control
          (concat
           "    <button type=\"button\" class=\"museum-drawer-toggle\" "
            "data-drawer-toggle aria-expanded=\"false\" aria-controls=\"org-museum-sidebar\" "
            "aria-label=\"打开全部笔记\">书架</button>\n")))
    (format
     (concat
      "<header class=\"museum-topbar\" data-home-href=\"%s\">\n"
      "  <a class=\"museum-skip-link\" href=\"#main-content\">跳到正文</a>\n"
      "  <a class=\"museum-wordmark museum-topbar-link\" href=\"%s\">ORG MUSEUM<span>.el</span></a>\n"
      "  <time class=\"museum-today\" datetime=\"%s\" title=\"导出于 %s\">%s</time>\n"
      "  <label class=\"museum-search-line\">\n"
      "    <span class=\"sr-only\">%s</span>\n"
      "    <input id=\"org-museum-global-search\" type=\"search\" "
      "placeholder=\"%s\" autocomplete=\"off\" spellcheck=\"false\" "
      "aria-label=\"%s\" aria-keyshortcuts=\"/\">\n"
      "    <kbd aria-hidden=\"true\">/</kbd>\n"
      "  </label>\n"
      "  <nav class=\"museum-top-links\" aria-label=\"Wiki 导航\">\n"
      "    <a class=\"museum-topbar-link museum-nav-timeline%s\" href=\"%s\"%s>时间</a>\n"
      "    <a class=\"museum-topbar-link museum-nav-graph%s\" href=\"%s\"%s>图谱</a>\n"
      "    <a class=\"museum-topbar-link museum-nav-related%s\" href=\"%s\"%s>关联阅读</a>\n"
      "    <a class=\"museum-topbar-link museum-nav-all%s\" href=\"%s\"%s>索引</a>\n"
      "%s"
      "    <button type=\"button\" class=\"museum-theme-toggle\" "
      "data-theme-toggle aria-label=\"切换为深色主题\">"
      "<span aria-hidden=\"true\" data-theme-icon data-theme-icon-state=\"moon\"></span>"
      "<span data-theme-label>深色</span></button>\n"
      "  </nav>\n"
      "</header>\n")
     (org-museum--html-escape home-href t)
     (org-museum--html-escape home-href t)
     (format-time-string "%Y-%m-%d")
     (format-time-string "%Y.%m.%d")
     (format-time-string "%Y.%m.%d")
     search-label
     placeholder
     search-label
     (if (eq kind 'timeline) " is-active" "")
     (org-museum--html-escape timeline-href t)
     (if (eq kind 'timeline) " aria-current=\"page\"" "")
     (if (eq kind 'graph) " is-active" "")
     (org-museum--html-escape graph-href t)
     (if (eq kind 'graph) " aria-current=\"page\"" "")
     (if (eq kind 'related) " is-active" "")
     (org-museum--html-escape related-href t)
     (if (eq kind 'related) " aria-current=\"page\"" "")
     (if (eq kind 'home) " is-active" "")
     (if (eq kind 'home) "#recent-updates"
       (concat (org-museum--html-escape home-href t) "#recent-updates"))
     (if (eq kind 'home) " data-index-reset aria-current=\"page\"" "")
     drawer-control)))

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
    "  <button type=\"button\" class=\"museum-entry-category\" "
    "data-category-link=\"%s\" aria-pressed=\"false\">%s</button>\n"
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
   (org-museum--html-escape (org-museum-page-category page) t)
   (org-museum--html-escape
    (org-museum--category-label (org-museum-page-category page)))))


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
pages.forEach(function(page){
  page._searchText=[page.title,page.description,page.category,page.categoryLabel]
    .concat(page.tags||[])
    .concat((page.headings||[]).map(function(item){return item.title;}))
    .join(' ').toLowerCase();
});
function count(value){return String(value).padStart(2,'0');}
function categoryLabel(value){
  var page=pages.find(function(item){return item.category===value;});
  return page?(page.categoryLabel||page.category):value;
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
  if((page.description||'').toLowerCase().indexOf(q)>=0)
    return {page:page,score:60,href:page.href,context:'摘要 · '+page.description};
  return {page:page,score:40,href:page.href,context:''};
}
function matches(page){
  var statusOk=state.status==='all'||page.status===state.status;
  var categoryOk=!state.category||page.category===state.category;
  var query=state.query.trim().toLowerCase();
  return statusOk&&categoryOk&&(!query||page._searchText.indexOf(query)>=0);
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
  document.querySelectorAll('.topic-filter[data-category],[data-category-link]').forEach(function(control){
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
  var listMode=Boolean(query||state.category||state.status!=='all');
  document.body.classList.toggle('museum-index-filtering',listMode);
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
document.querySelectorAll('.topic-filter[data-category],[data-category-link]').forEach(function(control){
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
function normalizeHeadingTitle(value){
  return String(value||'').replace(/\s+/g,' ').trim();
}
function recoverHeading(page,record){
  var wanted=normalizeHeadingTitle(record.lastHeadingTitle);
  if(!wanted)return null;
  var matches=(page.headings||[]).filter(function(item){
    return normalizeHeadingTitle(item.title)===wanted;
  });
  return matches.length===1?matches[0]:null;
}
function loadRecentRecords(db){
  return new Promise(function(resolve,reject){
    var records=[];var tx=db.transaction('readingState','readwrite');
    var store=tx.objectStore('readingState');
    var request=store.indexNames.contains('lastVisitedAt')
      ?store.index('lastVisitedAt').openCursor(null,'prev')
      :store.openCursor();
    request.onsuccess=function(){
      var cursor=request.result;
      if(!cursor){
        records.sort(function(a,b){return (b.lastVisitedAt||0)-(a.lastVisitedAt||0);});
        resolve(records.slice(0,6));return;
      }
      var record=cursor.value;
      var page=pages.find(function(item){return item.pageId===record.pageId;});
      var parsed=Number(record.progress||record.scrollRatio||0);
      var progress=Number.isFinite(parsed)?Math.min(1,Math.max(0,parsed)):0;
      record.progress=progress;record.scrollRatio=progress;
      var qualified=Boolean(record.qualifiedAt)||Number(record.engagedMs||0)>=30000||progress>=0.03;
      if(!page||!qualified)cursor.delete();
      else {
        record.href=page.href;record.title=page.title;
        record.category=page.categoryLabel||page.category;
        var headingValid=Boolean(record.lastHeadingId)&&(page.headings||[]).some(function(item){
          return item.id===record.lastHeadingId;
        });
        if(!headingValid){
          var recovered=recoverHeading(page,record);
          record.lastHeadingId=recovered?recovered.id:'';
          if(recovered)record.lastHeadingTitle=recovered.title;
        }
        cursor.update(record);
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
  resume.setAttribute('aria-busy','false');
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
    var row=document.createElement('div');row.className='resume-record-row';
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
    var remove=document.createElement('button');remove.type='button';
    remove.className='resume-remove';remove.textContent='移除';
    remove.setAttribute('aria-label','移除 '+(record.title||record.pageId)+' 的阅读记录');
    remove.addEventListener('click',function(){
      openReadingDb().then(function(db){
        return new Promise(function(resolve,reject){
          var request=db.transaction('readingState','readwrite')
            .objectStore('readingState').delete(record.pageId);
          request.onsuccess=resolve;request.onerror=function(){reject(request.error);};
        }).finally(function(){db.close();});
       }).then(function(){row.remove();
         var remaining=resumeList.querySelectorAll('.resume-record-row').length;
         if(!remaining)renderResume([]);
         else if(resumeCount)resumeCount.textContent='/ '+count(remaining);
       });
    });
    row.appendChild(link);row.appendChild(remove);resumeList.appendChild(row);
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
     "  <meta name=\"color-scheme\" content=\"dark light\">\n"
     "  <title>Org Museum</title>\n"
     (format "  %s\n" (org-museum--theme-script-tag out-file))
     (format "  %s\n" (org-museum--css-link-tag out-file))
     (format "  %s\n" org-museum--favicon-link-tag)
     "</head>\n<body class=\"org-museum-home\" data-page-kind=\"home\">\n"
     (org-museum--build-topbar out-file 'home)
     (org-museum--generate-sidebar-html out-file)
     "<main id=\"main-content\" class=\"museum-index-shell\" tabindex=\"-1\">\n"
     "  <h1 class=\"sr-only\">Org Museum</h1>\n"
     "  <section class=\"museum-home-upper\">\n"
     "    <section id=\"continue-reading\" class=\"museum-resume\" hidden aria-busy=\"true\">\n"
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
     (org-museum--script-shell)
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
  (org-museum--run-with-current-runtime
   'org-museum-export-graph (when silent (list :silent t))
   (lambda () (org-museum--export-graph-current :silent silent))))

(cl-defun org-museum--export-graph-current (&key silent)
  "Generate graph.html using the currently loaded runtime."
  (org-museum--guard-init)
  (org-museum--ensure-css-deployed)
  (let* ((shared-root (org-museum--shared-root))
         (graph-html  (expand-file-name "graph.html" shared-root))
         (css-path    (org-museum--css-output-path))
         (css-href    (or (org-museum--versioned-resource-href css-path graph-html)
                          (org-museum--relative-path css-path graph-html)))
         (data-json   (org-museum--generate-graph-json))
         (d3-src      (org-museum--d3-js-src graph-html)))
    (make-directory shared-root t)
    (with-temp-file graph-html
      (insert (org-museum--externalize-page-runtime
               (org-museum--build-graph-html data-json css-href d3-src)
               graph-html 'graph)))
    (unless silent
      (browse-url (concat "file:///" (replace-regexp-in-string "\\\\" "/" graph-html)))
      (message "Graph generated: %s" graph-html))
    graph-html))

(defun org-museum--generate-graph-json ()
  "Return directed graph JSON with factual relation labels and tier metadata."
  (let* ((pages    (org-museum-index-pages org-museum--index))
         (nodes    '())
         (links    '())
         (degree   (make-hash-table :test 'equal))
         (directed (make-hash-table :test 'equal))
         (seen-neighbours (make-hash-table :test 'equal))
         (excluded (make-hash-table :test 'equal)))
    ;; Phase 1: exclude-by-tag / exclude-by-id-regexp
    (maphash
     (lambda (id page)
       (when (org-museum--graph-page-excluded-p id page)
         (puthash id t excluded)))
     pages)
    ;; Phase 2: collect every explicit direction and unique neighbour degree.
    (maphash
     (lambda (id page)
       (unless (gethash id excluded)
         (dolist (target (org-museum-page-links-to page))
           (when (and (gethash target pages) (not (gethash target excluded)))
             (puthash (concat id "\0" target)
                      (org-museum--page-relation-type page target)
                      directed)
             (let* ((left (if (string< id target) id target))
                    (right (if (string< id target) target id))
                    (neighbour-key (concat left "\0" right)))
               (unless (gethash neighbour-key seen-neighbours)
                 (puthash neighbour-key t seen-neighbours)
                 (cl-incf (gethash left degree 0))
                 (cl-incf (gethash right degree 0))))))))
     pages)
    ;; Same-type reciprocal links share one bidirectional curve.  Differently
    ;; labelled reciprocal links remain separate directed facts.
    (let ((processed (make-hash-table :test 'equal))
          (keys (sort (hash-table-keys directed) #'string<)))
      (dolist (key keys)
        (unless (gethash key processed)
          (let* ((parts (split-string key "\0"))
                 (source (car parts))
                 (target (cadr parts))
                 (label (gethash key directed))
                 (reverse-key (concat target "\0" source))
                 (reverse-label (gethash reverse-key directed)))
            (if (and reverse-label (equal label reverse-label))
                (let ((left (if (string< source target) source target))
                      (right (if (string< source target) target source)))
                  (push `((source . ,left) (target . ,right)
                          (type . ,label) (bidirectional . t) (value . 1))
                        links)
                  (puthash reverse-key t processed))
              (push `((source . ,source) (target . ,target)
                      (type . ,label) (bidirectional . :json-false)
                      (value . 1))
                    links))
            (puthash key t processed)))))
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
                 (description . ,(or (org-museum-page-description page) ""))
                 (created . ,(org-museum-page-created page))
                 (modified . ,(org-museum-page-modified page))
                 (linksTo . ,(vconcat (org-museum-page-links-to page)))
                 (linkedFrom . ,(vconcat (org-museum-page-linked-from page)))
                 (url    . ,(org-museum--page-href id nil)))
               nodes)))
     pages)
    (let* ((n-count   (length nodes))
           (tier      (org-museum--graph-performance-tier n-count))
           (pre-ticks (plist-get tier :pre-ticks))
           (relation-types
            (sort (delete-dups
                   (mapcar (lambda (edge) (cdr (assq 'type edge))) links))
                  #'string<)))
      (json-encode
       `((nodes . ,(vconcat (nreverse nodes)))
         (links . ,(vconcat (nreverse links)))
         (meta  . ((node-count  . ,n-count)
                   (tier        . ,(symbol-name (plist-get tier :tier)))
                   (tier-label  . ,(plist-get tier :label))
                   (charge      . ,(plist-get tier :charge))
                   (alpha-decay . ,(plist-get tier :alpha-decay))
                   (tick-limit  . ,(or (plist-get tier :tick-limit) :false))
                   (pre-ticks   . ,(or pre-ticks :false))
                   (relation-types . ,(vconcat relation-types)))))))))

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
  (if-let* ((page (org-museum--find-page id)))
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

(defun org-museum--path-component-safe-p (value)
  "Return non-nil when VALUE is a portable single path component."
  (and (stringp value)
       (not (string-empty-p value))
       (string= value (string-trim value))
       (not (member value '("." "..")))
       (not (string-suffix-p "." value))
       (not (string-match-p "[[:cntrl:]<>:\"/\\\\|?*]" value))
       (let ((case-fold-search t))
         (not (string-match-p
               "\\`\\(?:con\\|prn\\|aux\\|nul\\|com[1-9]\\|lpt[1-9]\\)\\(?:\\..*\\)?\\'"
               value)))))

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

    ;; A punctuation-only title normalises to "-", which is not a meaningful
    ;; page identity and is almost impossible to recognise in links or search.
    (unless (string-match-p "[a-z0-9一-鿿]" id)
      (error "Org Museum [Create]: title must contain a letter, digit, or CJK character"))
    (unless (org-museum--path-component-safe-p id)
      (error "Org Museum [Create]: title produces a reserved page path"))
    (when (string-empty-p cat-dir)
      (error "Org Museum [Create]: category must contain a letter, digit, or CJK character"))
    (unless (org-museum--path-component-safe-p cat-dir)
      (error "Org Museum [Create]: category produces a reserved directory path"))

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
    (let ((original-index org-museum--index)
          (target-dir-existed (file-directory-p target-dir))
          created-buffer)
      (condition-case error-data
          (progn
            (make-directory target-dir t)
            (find-file filepath)
            (setq created-buffer (current-buffer))
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

            ;; The index scans files on disk.  Persist the initial template
            ;; before rebuilding so the page itself is indexed.
            (save-buffer)

            ;; ── Rebuild index + confirm ───────────────────────────
            (org-museum-index-build t)
            (message "Org Museum [Create]: '%s' → %s"
                     title
                     (file-relative-name filepath org-museum-root-dir)))
        (error
         (setq org-museum--index original-index)
         (when (buffer-live-p created-buffer)
           (with-current-buffer created-buffer
             (set-buffer-modified-p nil))
           (kill-buffer created-buffer))
         (when (file-exists-p filepath)
           (delete-file filepath))
         (when (and (not target-dir-existed)
                    (file-directory-p target-dir)
                    (directory-empty-p target-dir))
           (delete-directory target-dir))
         (signal (car error-data) (cdr error-data)))))))

(defun org-museum--rename-link-pattern (old-id)
  "Return a regexp matching supported links to OLD-ID."
  (format "\\[\\[\\(wiki\\|museum\\|id\\):%s\\(\\]\\|\\[\\)"
          (regexp-quote old-id)))

(defun org-museum--rename-relation-pattern (old-id)
  "Return a regexp matching a MUSEUM_RELATION target OLD-ID."
  (format "^#\\+MUSEUM_RELATION:[[:space:]]*\\(%s\\)\\([[:space:]]*|\\)"
          (regexp-quote old-id)))

(defun org-museum--rename-reference-search-pattern (old-id)
  "Return a regexp matching any supported reference to OLD-ID."
  (concat "\\(?:" (org-museum--rename-link-pattern old-id)
          "\\|" (org-museum--rename-relation-pattern old-id) "\\)"))

(defun org-museum--modified-link-buffer (old-id)
  "Return a modified Wiki buffer containing a supported link to OLD-ID."
  (let ((root (file-name-as-directory (expand-file-name (org-museum--scan-root))))
        (pattern (org-museum--rename-reference-search-pattern old-id)))
    (seq-find
     (lambda (buffer)
       (with-current-buffer buffer
         (and buffer-file-name
              (buffer-modified-p)
              (string-match-p "\\.org\\'" buffer-file-name)
              (file-in-directory-p (expand-file-name buffer-file-name) root)
              (save-excursion
                (save-restriction
                  (widen)
                  (goto-char (point-min))
                  (re-search-forward pattern nil t))))))
     (buffer-list))))

(defun org-museum--modified-file-link-buffer (target-file)
  "Return a modified Org buffer containing a file link to TARGET-FILE."
  (seq-find
   (lambda (buffer)
     (with-current-buffer buffer
       (and buffer-file-name
            (buffer-modified-p)
            (string-match-p "\\.org\\'" buffer-file-name)
            (save-excursion
              (save-restriction
                (widen)
                (goto-char (point-min))
                (let (found)
                  (while (and (not found)
                              (re-search-forward "\\[\\[file:\\([^]\n]+\\)\\]" nil t))
                    (setq found
                          (org-museum--file-link-refers-to-p
                           (match-string 1) buffer-file-name target-file)))
                  found))))))
   (buffer-list)))

(defun org-museum--rename-link-files (old-id)
  "Return Org files containing links or relation annotations to OLD-ID."
  (let ((pattern (org-museum--rename-reference-search-pattern old-id))
        matches)
    (dolist (file (directory-files-recursively (org-museum--scan-root) "\\.org$")
                  (nreverse matches))
      (when (with-temp-buffer
              (insert-file-contents file)
              (re-search-forward pattern nil t))
        (push file matches)))))

(defun org-museum--file-link-refers-to-p (raw source-file target-file)
  "Return non-nil when RAW file link in SOURCE-FILE resolves to TARGET-FILE."
  (let* ((parts (org-museum--file-link-parts raw))
         (decoded (url-unhex-string (car parts)))
         (resolved (expand-file-name decoded (file-name-directory source-file))))
    (equal (org-museum--normalised-path resolved)
           (org-museum--normalised-path target-file))))

(defun org-museum--files-linking-to-path (target-file)
  "Return scanned Org files containing a file link to TARGET-FILE."
  (let (matches)
    (dolist (file (org-museum--scan-files) (nreverse matches))
      (when (with-temp-buffer
              (insert-file-contents file)
              (let (found)
                (while (and (not found)
                            (re-search-forward "\\[\\[file:\\([^]\n]+\\)\\]" nil t))
                  (setq found (org-museum--file-link-refers-to-p
                               (match-string 1) file target-file)))
                found))
        (push file matches)))))

(defun org-museum--update-file-links-for-rename (old-path new-path &optional files)
  "Rewrite file links from OLD-PATH to NEW-PATH in FILES; return file count."
  (let ((count 0))
    (dolist (file (or files (org-museum--scan-files)))
      (with-temp-buffer
        (insert-file-contents file)
        (let (modified)
          (goto-char (point-min))
          (while (re-search-forward "\\[\\[file:\\([^]\n]+\\)\\]" nil t)
            (let* ((raw (match-string 1))
                   (target-start (match-beginning 1))
                   (target-end (match-end 1))
                   (parts (org-museum--file-link-parts raw)))
              (when (org-museum--file-link-refers-to-p raw file old-path)
                (let* ((relative (replace-regexp-in-string
                                  "\\\\" "/"
                                  (file-relative-name new-path
                                                      (file-name-directory file))))
                       (path (if (string-match-p "%[[:xdigit:]][[:xdigit:]]" (car parts))
                                 (replace-regexp-in-string
                                  "%2F" "/" (url-hexify-string relative) t t)
                               relative))
                       (replacement (concat path
                                            (when (cdr parts)
                                              (concat "::" (cdr parts))))))
                  (goto-char target-start)
                  (delete-region target-start target-end)
                  (insert replacement)
                  (setq modified t)))))
          (when modified
            (write-region (point-min) (point-max) file nil 'silent)
            (cl-incf count)))))
    count))

(defun org-museum--snapshot-files (files)
  "Return byte-for-byte snapshots of regular FILES."
  (let (snapshots)
    (dolist (file (delete-dups (copy-sequence files)) (nreverse snapshots))
      (when (file-regular-p file)
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally file)
          (push (list file (buffer-string) (file-modes file)) snapshots))))))

(defun org-museum--restore-file-snapshots (snapshots)
  "Restore byte-for-byte file SNAPSHOTS created for a page rename."
  (dolist (snapshot snapshots)
    (pcase-let ((`(,file ,contents ,modes) snapshot))
      (make-directory (file-name-directory file) t)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert contents)
        (let ((coding-system-for-write 'no-conversion))
          (write-region (point-min) (point-max) file nil 'silent)))
      (when modes
        (set-file-modes file modes)))))

(defun org-museum--rewrite-page-id (file new-id)
  "Rewrite FILE's WIKI_ID to NEW-ID without creating a visiting buffer."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (if (re-search-forward "^#\\+WIKI_ID:\\s-.*$" nil t)
        (replace-match (format "#+WIKI_ID: %s" new-id))
      (goto-char (point-min))
      (insert (format "#+WIKI_ID: %s\n" new-id)))
    (write-region (point-min) (point-max) file nil 'silent)))

;;;###autoload
(defun org-museum-rename-page (old-id new-id)
  "Rename page OLD-ID to NEW-ID and update all cross-links.
[Fix-11] Now also rewrites [[id:OLD-ID]] org-id format links.
Known limitation: does not handle custom_id property links."
  (interactive
   (let* ((ids (hash-table-keys (org-museum-index-pages org-museum--index)))
          (old (completing-read "Page ID to rename: " ids nil t)))
     (list old (read-string (format "New ID (was: %s): " old) old))))
  (unless (org-museum--path-component-safe-p new-id)
    (error "Org Museum [Rename]: new ID must be one non-empty path-safe name"))
  (let* ((page     (or (gethash old-id (org-museum-index-pages org-museum--index))
                       (error "Page not found: %s" old-id)))
         (old-path (expand-file-name (org-museum-page-path page)))
         (new-path (expand-file-name
                    (concat new-id ".org") (file-name-directory old-path)))
         (page-buffer (get-file-buffer old-path))
         (original-index org-museum--index))
    (when (gethash new-id (org-museum-index-pages org-museum--index))
      (error "ID already exists: %s" new-id))
    (when (file-exists-p new-path)
      (error "Org Museum [Rename]: target file already exists: %s" new-path))
    (when (get-file-buffer new-path)
      (error "Org Museum [Rename]: target path is already visited: %s" new-path))
    (when (and (buffer-live-p page-buffer)
               (buffer-modified-p page-buffer))
      (error "Org Museum [Rename]: save the page before renaming"))
    (when-let* ((modified-referrer
                (org-museum--modified-link-buffer old-id)))
      (error "Org Museum [Rename]: save referring page before renaming: %s"
             (buffer-file-name modified-referrer)))
    (when-let* ((modified-referrer
                (org-museum--modified-file-link-buffer old-path)))
      (error "Org Museum [Rename]: save referring page before renaming: %s"
             (buffer-file-name modified-referrer)))
    (let* ((file-link-files (org-museum--files-linking-to-path old-path))
           (link-files (delete-dups
                        (append (org-museum--rename-link-files old-id)
                                file-link-files)))
           (referrer-buffers
            (delq nil (mapcar #'get-file-buffer
                              (delete old-path (copy-sequence link-files)))))
           (snapshots (org-museum--snapshot-files (cons old-path link-files)))
           (index-path (org-museum--index-file-path))
           (index-existed (file-exists-p index-path))
           (index-snapshot (org-museum--snapshot-files (list index-path)))
           (update-files
            (mapcar (lambda (file)
                      (if (equal file old-path) new-path file))
                    link-files))
           moved-p)
      (condition-case error-data
          (progn
            (rename-file old-path new-path)
            (setq moved-p t)
            (org-museum--rewrite-page-id new-path new-id)
            (let ((count (org-museum--update-links-globally
                          old-id new-id update-files)))
              (cl-incf count
                        (org-museum--update-file-links-for-rename
                         old-path new-path
                         (mapcar (lambda (file)
                                   (if (equal file old-path) new-path file))
                                 file-link-files)))
              (org-museum-index-build t)
              (when (buffer-live-p page-buffer)
                (with-current-buffer page-buffer
                  (set-visited-file-name new-path t)
                  (revert-buffer t t)))
              (dolist (buffer referrer-buffers)
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (revert-buffer t t))))
              (message "Renamed %s → %s; %d files updated."
                       old-id new-id count)))
        (error
         (setq org-museum--index original-index)
         (when (and moved-p (file-exists-p new-path))
           (delete-file new-path))
         (org-museum--restore-file-snapshots snapshots)
         (cond
          (index-snapshot
           (org-museum--restore-file-snapshots index-snapshot))
          ((and (not index-existed) (file-regular-p index-path))
           (delete-file index-path)))
         (when (buffer-live-p page-buffer)
           (with-current-buffer page-buffer
             (condition-case nil
                 (progn
                   (unless (equal (buffer-file-name) old-path)
                     (set-visited-file-name old-path t))
                   (revert-buffer t t))
               (error nil))))
         (dolist (buffer referrer-buffers)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (condition-case nil
                   (revert-buffer t t)
                 (error nil)))))
         (signal (car error-data) (cdr error-data)))))))

;; Fix-11: now handles wiki:, museum:, id:, and relation annotations.
(defun org-museum--update-links-globally (old-id new-id &optional files)
  "Replace links and relation annotations to OLD-ID with NEW-ID; return file count.
[Fix-11] Three link formats are handled:
  [[wiki:OLD-ID]]    → [[wiki:NEW-ID]]
  [[museum:OLD-ID]]  → [[museum:NEW-ID]]
  [[id:OLD-ID]]      → [[id:NEW-ID]]
Applicable scope: org-museum-rename-page, on-save ID change detection.
Known limitation: CUSTOM_ID property links are not rewritten."
  (let ((count 0)
        (pattern (org-museum--rename-link-pattern old-id))
        (relation-pattern (org-museum--rename-relation-pattern old-id)))
    (dolist (file (or files
                      (directory-files-recursively
                       (org-museum--scan-root) "\\.org$")))
      (with-temp-buffer
        (insert-file-contents file)
        (let (modified)
          (goto-char (point-min))
          (while (re-search-forward pattern nil t)
            (replace-match (format "[[\\1:%s\\2" new-id) t)
            (setq modified t))
          (goto-char (point-min))
          (while (re-search-forward relation-pattern nil t)
            (replace-match new-id t t nil 1)
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
                       (org-museum--source-headings page))))
        (and heading (cdr (assq 'id heading))))))))

(defun org-museum--rewrite-org-museum-links (buf out-file &optional source-file)
  "Rewrite Wiki and file links in BUF for OUT-FILE.
Relative file links are resolved from SOURCE-FILE, never from the temporary
export buffer.  Indexed Org targets become exported page links.  Existing
assets retain relative export paths; other local files become absolute paths
that Org exports as file URLs for local opening and copy-path fallback."
  (with-current-buffer buf
    ;; Resolve only file links that existed in the source.  Wiki and id links
    ;; are rewritten afterwards so their generated relative HTML links cannot
    ;; be mistaken for source-relative local files.
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
        (replace-match (format "[[file:%s]%s]" destination description) t t)))
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
         t t)))))

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
  (if-let* ((page (org-museum--find-page id)))
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

(defun org-museum--org-roam-db-path ()
  "Return the existing Org-roam database path used for graph relationships."
  (let ((configured (and (boundp 'org-roam-db-location)
                         (stringp org-roam-db-location)
                         (expand-file-name org-roam-db-location))))
    (cond
     ((and configured (file-regular-p configured)) configured)
     ((file-regular-p (expand-file-name "org-roam.db" org-museum-root-dir))
      (expand-file-name "org-roam.db" org-museum-root-dir)))))

(defun org-museum--with-org-roam-db (function)
  "Call FUNCTION with the shared or a temporary Org-roam database connection."
  (if org-museum--org-roam-db-connection
      (funcall function org-museum--org-roam-db-connection)
    (when-let* ((db-path (org-museum--org-roam-db-path)))
      (when (fboundp 'sqlite-open)
        (let ((db (sqlite-open db-path)))
          (unwind-protect (funcall function db)
            (sqlite-close db)))))))

(defun org-museum--org-roam-db-linked-page-ids (file pages-table aliases)
  "Return canonical page IDs linked from FILE according to org-roam.db."
  (let ((result '()))
    (org-museum--with-org-roam-db
     (lambda (db)
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
                 (cl-pushnew page-id result :test #'equal))))))))
    result))
(defun org-museum--org-roam-db-related-page-ids (file pages-table aliases)
  "Return canonical page IDs adjacent to FILE according to org-roam.db."
  (let ((page (org-museum--find-page-by-path file pages-table))
        (result '()))
    (when page
      (org-museum--with-org-roam-db
       (lambda (db)
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
                   (cl-pushnew page-id result :test #'equal)))))))))
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
var tocDrawerMedia=matchMedia('(max-width:1360px)');
var metaMedia=matchMedia('(max-width:820px)');
var metaDisclosure=document.querySelector('.museum-article-meta-disclosure');
var tocAnchor=null;
var lastFocus=null;
var panelBackground=[];
var panelScroll=null;
if(!backdrop){
  backdrop=document.createElement('button');backdrop.type='button';
  backdrop.id='museum-drawer-backdrop';backdrop.tabIndex=-1;
  backdrop.setAttribute('aria-label','关闭抽屉');document.body.appendChild(backdrop);
}
if(drawer){
  drawer.setAttribute('role','dialog');
  drawer.querySelectorAll('a[href]').forEach(function(link){
    var target=new URL(link.getAttribute('href'),location.href);
    if(target.pathname===location.pathname)link.setAttribute('aria-current','page');
  });
}
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
function syncMetaDisclosure(){
  if(!metaDisclosure)return;
  if(!metaMedia.matches)metaDisclosure.open=true;
  else if(!metaDisclosure.dataset.mobileReady){
    metaDisclosure.open=false;metaDisclosure.dataset.mobileReady='true';
  }
}
syncMetaDisclosure();
function controls(selector,open){
  document.querySelectorAll(selector).forEach(function(button){
    button.setAttribute('aria-expanded',open?'true':'false');
    if(selector==='[data-drawer-toggle]')
      button.setAttribute('aria-label',open?'关闭全部笔记':'打开全部笔记');
    else if(selector==='[data-toc-toggle]')
      button.setAttribute('aria-label',open?'关闭目录':'打开目录');
  });
}
function setPanelAvailable(panel,available){
  if(!panel)return;
  panel.inert=!available;
  if(available)panel.removeAttribute('aria-hidden');
  else panel.setAttribute('aria-hidden','true');
}
function focusFirst(container){
  var item=container&&container.querySelector(
    'button:not([disabled]),a[href],input:not([disabled]),[tabindex=\"0\"]');
  if(item)item.focus({preventScroll:true});
}
function releasePanelBackground(){
  panelBackground.forEach(function(entry){entry.element.inert=entry.inert;});
  panelBackground=[];
  document.documentElement.classList.remove('museum-panel-open');
  if(panelScroll){
    window.scrollTo({left:panelScroll.x,top:panelScroll.y,behavior:'instant'});
    if(panelScroll.scroller)panelScroll.scroller.scrollTop=panelScroll.top;
    panelScroll=null;
  }
}
function lockPanelBackground(panel){
  var scroller=document.getElementById('main-scroll');
  panelScroll={x:scrollX,y:scrollY,scroller:scroller,top:scroller?scroller.scrollTop:0};
  Array.from(document.body.children).forEach(function(element){
    if(element===panel||element===backdrop||element.contains(panel)||
       /^(SCRIPT|STYLE|LINK)$/.test(element.tagName))return;
    panelBackground.push({element:element,inert:element.inert});element.inert=true;
  });
  document.documentElement.classList.add('museum-panel-open');
}
function closeAll(restore){
  releasePanelBackground();
  document.body.classList.remove('museum-drawer-open','museum-toc-open');
  setPanelAvailable(drawer,false);
  if(drawer)drawer.removeAttribute('aria-modal');
  setPanelAvailable(toc,!tocDrawerMedia.matches);
  controls('[data-drawer-toggle]',false);controls('[data-toc-toggle]',false);
  if(restore&&lastFocus&&document.contains(lastFocus))lastFocus.focus({preventScroll:true});
  lastFocus=null;
}
function openPanel(kind,trigger){
  closeAll(false);lastFocus=trigger||document.activeElement;
  var isDrawer=kind==='drawer';
  document.body.classList.add(isDrawer?'museum-drawer-open':'museum-toc-open');
  var panel=isDrawer?drawer:toc;
  if(!panel)return;
  setPanelAvailable(panel,true);
  if(isDrawer)drawer.setAttribute('aria-modal','true');
  lockPanelBackground(panel);
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
    event.preventDefault();event.stopImmediatePropagation();closeAll(true);return;
  }
  if(event.key==='Tab'){
    var panel=document.body.classList.contains('museum-drawer-open')?drawer:
      (document.body.classList.contains('museum-toc-open')?toc:null);
    if(!panel)return;
    var items=Array.from(panel.querySelectorAll(
      'button:not([disabled]),a[href],input:not([disabled]),[tabindex=\"0\"]'));
    if(!items.length)return;
    var first=items[0],last=items[items.length-1];
    if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus({preventScroll:true});}
    else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus({preventScroll:true});}
  }
},true);
var search=document.getElementById('org-museum-global-search');
if(search&&document.body.dataset.pageKind==='article'){
  search.addEventListener('keydown',function(event){
    if(event.key==='Enter'&&search.value.trim()){
      var top=document.querySelector('.museum-topbar');
      var home=top?top.getAttribute('data-home-href'):'index.html';
      var destination=home+'?q='+encodeURIComponent(search.value.trim());
      location.href=window.orgMuseumThemeUrl?
        window.orgMuseumThemeUrl(destination):destination;
    }
  });
}
document.addEventListener('keydown',function(event){
  if(event.key==='/'&&!event.metaKey&&!event.ctrlKey&&!event.altKey&&
     !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)){
    event.preventDefault();
    var target=document.body.classList.contains('museum-drawer-open')?
      document.getElementById('org-museum-search-input'):search;
    if(target)target.focus({preventScroll:true});
  }
});
document.querySelectorAll('[data-drawer-toggle]').forEach(function(button){
  button.setAttribute('aria-controls','org-museum-sidebar');
});
document.querySelectorAll('[data-toc-toggle]').forEach(function(button){
  button.setAttribute('aria-controls','org-museum-right-sidebar');
});
controls('[data-drawer-toggle]',false);
controls('[data-toc-toggle]',false);
setPanelAvailable(drawer,false);
setPanelAvailable(toc,!tocDrawerMedia.matches);
if(!toc||!toc.querySelector('ul'))document.body.classList.add('museum-no-toc');
var onTocDrawerChange=function(){
  if(document.body.classList.contains('museum-toc-open'))closeAll(true);
  placeToc();
};
if(tocDrawerMedia.addEventListener)tocDrawerMedia.addEventListener('change',onTocDrawerChange);
else if(tocDrawerMedia.addListener)tocDrawerMedia.addListener(onTocDrawerChange);
if(metaMedia.addEventListener)metaMedia.addEventListener('change',syncMetaDisclosure);
else if(metaMedia.addListener)metaMedia.addListener(syncMetaDisclosure);
var identity=document.getElementById('museum-article-identity');
var articleTitle=document.querySelector('.article-container > .title');
var articleScroller=document.getElementById('main-scroll')||window;
var identityFrame=0;
var identityHeading=window.orgMuseumActiveHeading||null;
function updateIdentitySection(detail){
  if(detail)identityHeading=detail;
  if(!identity)return;
  var section=identity.querySelector('[data-current-section]');
  if(section)section.textContent=identityHeading?identityHeading.title:'文章开头';
}
function updateArticleIdentity(){
  identityFrame=0;if(!identity||!articleTitle)return;
  var topbar=document.querySelector('.museum-topbar');
  var threshold=topbar?topbar.getBoundingClientRect().bottom+8:8;
  var show=articleTitle.getBoundingClientRect().bottom<=threshold;
  identity.hidden=!show;
  updateIdentitySection(window.orgMuseumActiveHeading||identityHeading);
}
function scheduleArticleIdentity(){
  if(identityFrame)return;identityFrame=requestAnimationFrame(updateArticleIdentity);
}
if(identity){
  document.addEventListener('museum:active-heading',function(event){
    updateIdentitySection(event.detail);scheduleArticleIdentity();
  });
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
var activeHeading=window.orgMuseumActiveHeading||null,dbPromise=null,restored=false,timer=null;
var restoreStarted=false;
var saveInterval=null;
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
function normalizeHeadingTitle(value){
  return String(value||'').replace(/\\s+/g,' ').trim();
}
function headingByTitle(title){
  var wanted=normalizeHeadingTitle(title);
  if(!wanted)return null;
  var matches=Array.from(article.querySelectorAll('h2[id],h3[id],h4[id]'))
    .filter(function(heading){
      return normalizeHeadingTitle(heading.textContent)===wanted;
    });
  return matches.length===1?matches[0]:null;
}
function persistRecoveredHeading(db,saved,target){
  saved.lastHeadingId=target.id;
  saved.lastHeadingTitle=normalizeHeadingTitle(target.textContent);
  try{
    db.transaction('readingState','readwrite')
      .objectStore('readingState').put(saved);
  }catch(_error){}
}
function showRestoreNotice(){
  if(location.hash)return;
  var notice=document.createElement('div');notice.className='reading-restore-notice';
  notice.setAttribute('role','status');notice.setAttribute('aria-live','polite');
  var copy=document.createElement('span');copy.className='reading-restore-copy';
  copy.textContent='已恢复上次阅读位置';notice.appendChild(copy);
  var topButton=document.createElement('button');topButton.type='button';
  topButton.textContent='回到开头';topButton.addEventListener('click',function(){
    if(scroller===window)window.scrollTo({top:0,behavior:'smooth'});
    else scroller.scrollTo({top:0,behavior:'smooth'});notice.remove();
  });
  var closeButton=document.createElement('button');closeButton.type='button';
  closeButton.className='reading-restore-close';closeButton.textContent='关闭';
  closeButton.setAttribute('aria-label','关闭阅读位置提示');
  closeButton.addEventListener('click',function(){notice.remove();});
  notice.appendChild(topButton);notice.appendChild(closeButton);document.body.appendChild(notice);
  setTimeout(function(){notice.remove();},8000);
}
function record(){
  updateEngagement();
  var state=metrics(),engagedMs=currentEngagedMs(),progress=state.ratio;
  if(!qualifiedAt&&(progress>=0.03||engagedMs>=30000))qualifiedAt=Date.now();
  return {
    pageId:pageId,href:location.pathname+location.search,url:location.pathname+location.search,
    title:document.body.dataset.pageTitle||document.title,
    category:document.body.dataset.pageCategory||'未分类',lastVisitedAt:Date.now(),
    lastHeadingId:activeHeading?activeHeading.id:'',
    lastHeadingTitle:activeHeading?(activeHeading.title||''):'',
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
function startPeriodicSave(){
  if(saveInterval)return;
  saveInterval=setInterval(function(){save();},5000);
}
function stopPeriodicSave(){
  if(!saveInterval)return;
  clearInterval(saveInterval);saveInterval=null;
}
function schedule(){
  var state=metrics();
  document.documentElement.style.setProperty('--reading-progress',(state.ratio*100)+'%');
  if(timer)return;
  timer=setTimeout(function(){timer=null;save();},800);
}
function restore(){
  if(restoreStarted)return;restoreStarted=true;
  openDb().then(function(db){return new Promise(function(resolve,reject){
    var request=db.transaction('readingState','readonly').objectStore('readingState').get(pageId);
    request.onsuccess=function(){resolve({db:db,saved:request.result});};
    request.onerror=function(){reject(request.error);};
  });}).then(function(result){
    var db=result.db,saved=result.saved;
    if(restored||!saved)return;restored=true;
    var raw=location.hash.replace(/^#/,'');
    var hash=(function(){try{return decodeURIComponent(raw);}catch(_error){return raw;}})();
    var target=hash?document.getElementById(hash):null;
    if(!target&&saved.lastHeadingId)target=document.getElementById(saved.lastHeadingId);
    if(!target&&saved.lastHeadingTitle){
      target=headingByTitle(saved.lastHeadingTitle);
      if(target)persistRecoveredHeading(db,saved,target);
    }
    if(target){target.scrollIntoView({block:'start'});showRestoreNotice();}
    else if(saved.scrollRatio>0)requestAnimationFrame(function(){
      var top=saved.scrollRatio*metrics().height;
      if(scroller===window)window.scrollTo(0,top);else scroller.scrollTop=top;
      showRestoreNotice();
    });
  }).catch(function(){});
}
scroller.addEventListener('scroll',schedule,{passive:true});
document.addEventListener('museum:active-heading',function(event){
  activeHeading=event.detail||null;
});
document.addEventListener('visibilitychange',function(){
  updateEngagement();
  if(document.visibilityState==='hidden')save();
});
window.addEventListener('focus',updateEngagement);
window.addEventListener('blur',updateEngagement);
window.addEventListener('pagehide',function(){
  if(timer){clearTimeout(timer);timer=null;}
  stopPeriodicSave();save();
});
function startReadingSession(){restore();schedule();startPeriodicSave();}
window.addEventListener('load',startReadingSession);
window.addEventListener('pageshow',startReadingSession);
})();
</script>\n")

(defun org-museum--build-sidebar-injection (out-file)
  "Return the full sidebar+script HTML string to inject before </body>."
  (concat
   "<button type=\"button\" id=\"museum-drawer-backdrop\" aria-label=\"关闭抽屉\"></button>\n"
   "<p id=\"museum-article-live-status\" class=\"sr-only\" role=\"status\" aria-live=\"polite\"></p>\n"
   "<div id=\"zen-mask\"></div>\n"
   (when org-museum-background-effects-enabled
     "<canvas id=\"org-museum-fx-canvas\" aria-hidden=\"true\"></canvas>\n")
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
         (timeline-href (org-museum--relative-path
                         (org-museum--timeline-output-path) out-file))
         (related-href (org-museum--relative-path
                        (org-museum--related-output-path) out-file))
         (cats        (org-museum--sorted-categories)))
    (with-output-to-string
      (princ "<aside id=\"org-museum-sidebar\" aria-hidden=\"true\" inert aria-label=\"全部笔记\">\n")
      (princ "  <div class=\"sidebar-header\"><strong>全部笔记</strong>")
      (princ "<button type=\"button\" data-drawer-close>关闭</button></div>\n")
      (princ (format "  <a class=\"sidebar-nav-btn\" href=\"%s\">返回首页</a>\n"
                     (replace-regexp-in-string "\\\\" "/" home-href)))
      (princ (format "  <a class=\"sidebar-nav-btn graph\" href=\"%s\">知识图谱</a>\n"
                     (replace-regexp-in-string "\\\\" "/" graph-href)))
      (princ (format "  <a class=\"sidebar-nav-btn timeline\" href=\"%s\">时间阅读</a>\n"
                     (replace-regexp-in-string "\\\\" "/" timeline-href)))
      (princ (format "  <a class=\"sidebar-nav-btn related\" href=\"%s\">关联阅读</a>\n"
                     (replace-regexp-in-string "\\\\" "/" related-href)))
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
  (if (not org-museum-background-effects-enabled)
      ""
    (concat
     "  <details class=\"sidebar-fx-controls\">\n"
     "    <summary class=\"fx-label\">背景效果</summary>\n"
     "    <div class=\"fx-buttons\">\n"
     "      <button type=\"button\" class=\"fx-btn\" data-fx=\"none\">关闭</button>\n"
     "      <button type=\"button\" class=\"fx-btn\" data-fx=\"tubes\">轨迹</button>\n"
     "      <button type=\"button\" class=\"fx-btn\" data-fx=\"matrix\">矩阵</button>\n"
     "      <button type=\"button\" class=\"fx-btn\" data-fx=\"particles\">微粒</button>\n"
     "    </div>\n"
     "  </details>\n")))

;; ============================================================
;; §21  WIKI NAVIGATION
;; ============================================================

(defun org-museum--related-href (source-id target-id out-file &optional mode)
  "Return an offline relationship-reading URL relative to OUT-FILE."
  (let ((base (org-museum--relative-path
               (org-museum--related-output-path) out-file)))
    (format "%s?source=%s&target=%s%s"
            base
            (url-hexify-string (or source-id ""))
            (url-hexify-string (or target-id ""))
            (if mode (format "&mode=%s" (url-hexify-string mode)) ""))))

(defun org-museum--build-nav-html (links backs out-file &optional current-id)
  "Generate nav HTML for LINKS and BACKS relative to CURRENT-ID."
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
                     (format (concat "<span class=\"org-museum-relation-row\">"
                                     "<a href=\"%s\" class=\"org-museum-link\">%s</a>"
                                     "<a href=\"%s\" class=\"org-museum-compare-link\" "
                                     "aria-label=\"关联阅读：%s\">对读</a></span>")
                             (org-museum--html-escape
                              (org-museum--page-href id out-file) t)
                             (org-museum--html-escape title)
                             (org-museum--html-escape
                              (org-museum--related-href
                               (or current-id "") id out-file) t)
                             (org-museum--html-escape title t))))
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
                     (format (concat "<span class=\"org-museum-relation-row\">"
                                     "<a href=\"%s\" class=\"org-museum-link\">%s</a>"
                                     "<a href=\"%s\" class=\"org-museum-compare-link\" "
                                     "aria-label=\"关联阅读：%s\">对读</a></span>")
                             (org-museum--html-escape
                              (org-museum--page-href id out-file) t)
                             (org-museum--html-escape title)
                             (org-museum--html-escape
                              (org-museum--related-href
                               id (or current-id "") out-file) t)
                             (org-museum--html-escape title t))))
                 backs "\n")
      "</div>\n"))
   "</nav>\n"))

;; ============================================================
;; §21a  RELATIONSHIP READING
;; ============================================================

(defun org-museum--related-pages ()
  "Return published indexed pages in stable title order."
  (let (pages)
    (when org-museum--index
      (maphash (lambda (_id page)
                 (when (org-museum--published-page-p page)
                   (push page pages)))
               (org-museum-index-pages org-museum--index)))
    (sort pages (lambda (left right)
                  (string-lessp (org-museum-page-title left)
                                (org-museum-page-title right))))))

(defun org-museum--related-clean-fragment (html)
  "Remove page chrome and executable content from article HTML fragment."
  (with-temp-buffer
    (insert (or html ""))
    (goto-char (point-min))
    (while (re-search-forward
            "<script\\b[^>]*>\\(?:.\\|\n\\)*?</script[[:space:]]*>" nil t)
      (replace-match "" t t))
    (goto-char (point-min))
    (while (re-search-forward
            "<button\\b[^>]*museum-article-toc-trigger[^>]*>\\(?:.\\|\n\\)*?</button[[:space:]]*>"
            nil t)
      (replace-match "" t t))
    (goto-char (point-min))
    (while (re-search-forward
            "<details\\b[^>]*museum-article-meta-disclosure[^>]*>\\(?:.\\|\n\\)*?</details[[:space:]]*>"
            nil t)
      (replace-match "" t t))
    (goto-char (point-min))
    (while (re-search-forward
            "<aside\\b[^>]*museum-article-meta[^>]*>\\(?:.\\|\n\\)*?</aside[[:space:]]*>"
            nil t)
      (replace-match "" t t))
    (goto-char (point-min))
    (when (re-search-forward
           "<h1\\b[^>]*class=\"[^\"]*title[^\"]*\"[^>]*>\\(?:.\\|\n\\)*?</h1[[:space:]]*>"
           nil t)
      (replace-match "" t t))
    (string-trim (buffer-string))))

(defun org-museum--related-article-fragment (page)
  "Return PAGE's final exported article content without surrounding chrome."
  (let ((file (org-museum--export-filename (org-museum-page-path page))))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (when (re-search-forward
               "<article\\b[^>]*class=\"[^\"]*article-container[^\"]*\"[^>]*>"
               nil t)
          (let ((begin (point)) end)
            (setq end
                  (apply
                   #'min
                   (delq
                    nil
                    (mapcar
                     (lambda (regexp)
                       (save-excursion
                         (goto-char begin)
                         (when (re-search-forward regexp nil t)
                           (match-beginning 0))))
                     '("<nav\\b[^>]*class=\"[^\"]*org-museum-nav"
                       "<section\\b[^>]*id=\"local-graph-container\""
                       "</article[[:space:]]*>"
                       "\\'")))))
            (org-museum--related-clean-fragment
             (buffer-substring-no-properties begin end))))))))

(defun org-museum--related-url-absolute-p (url)
  "Return non-nil when URL must not be rebased."
  (or (string-empty-p (or url ""))
      (string-prefix-p "//" url)
      (string-prefix-p "/" url)
      (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" url)))

(defun org-museum--related-rebase-fragment (html page out-file)
  "Rebase links in HTML from PAGE output to OUT-FILE and prefix fragment IDs."
  (let* ((page-file (org-museum--export-filename (org-museum-page-path page)))
         (prefix (concat "related-" (org-museum-page-id page) "-")))
    (with-temp-buffer
      (insert (or html ""))
      (goto-char (point-min))
      (while (re-search-forward "\\(href\\|src\\)=\"\\([^\"]+\\)\"" nil t)
        (let* ((attribute (match-string-no-properties 1))
               (url (match-string-no-properties 2))
               (replacement
                (cond
                 ((string-prefix-p "#" url) (concat "#" prefix (substring url 1)))
                 ((org-museum--related-url-absolute-p url) url)
                 (t
                  (let* ((split (or (string-match "[?#]" url) (length url)))
                         (path (substring url 0 split))
                         (suffix (substring url split)))
                    (concat
                     (org-museum--relative-path
                      (expand-file-name path (file-name-directory page-file))
                      out-file)
                     suffix))))))
          (replace-match
           (format "%s=\"%s\"" attribute
                   (org-museum--html-escape replacement t)) t t)))
      (goto-char (point-min))
      (while (re-search-forward "\\bid=\"\\([^\"]+\\)\"" nil t)
        (replace-match
         (format "id=\"%s%s\"" prefix (match-string-no-properties 1)) t t))
      (buffer-string))))

(defun org-museum--related-paragraphs (html &optional limit)
  "Return up to LIMIT readable paragraph strings extracted from HTML."
  (let (paragraphs)
    (with-temp-buffer
      (insert (or html ""))
      (goto-char (point-min))
      (while (and (or (null limit) (< (length paragraphs) limit))
                  (re-search-forward "<p\\b[^>]*>\\(\\(?:.\\|\n\\)*?\\)</p>" nil t))
        (let ((text (string-trim
                     (org-museum--strip-html
                      (match-string-no-properties 1)))))
          (unless (or (string-empty-p text)
                      (string-match-p "\\`:[[:alnum:]_-]+:" text))
            (push text paragraphs)))))
    (nreverse paragraphs)))

(defun org-museum--related-page-alist (page out-file)
  "Return browser-facing relationship data for PAGE relative to OUT-FILE."
  (let* ((raw (or (org-museum--related-article-fragment page) ""))
         (paragraphs (org-museum--related-paragraphs raw 3))
         (description (string-trim (or (org-museum-page-description page) "")))
         (summary (if (string-empty-p description)
                      (or (car paragraphs) "暂无可用摘要。")
                    description))
         (headings
          (seq-take
           (cl-remove-if-not
            (lambda (heading) (= (or (cdr (assq 'level heading)) 0) 2))
            (org-museum--page-headings page))
           6)))
    `((id . ,(org-museum-page-id page))
      (title . ,(org-museum-page-title page))
      (category . ,(org-museum-page-category page))
      (categoryLabel . ,(org-museum--category-label
                         (org-museum-page-category page)))
      (modifiedDate . ,(org-museum--format-page-date page))
      (status . ,(downcase (or (org-museum-page-status page) "published")))
      (tags . ,(vconcat (org-museum-page-tags page)))
      (description . ,summary)
      (headings . ,(vconcat headings))
      (excerpts . ,(vconcat (seq-take (cdr paragraphs) 2)))
      (href . ,(org-museum--page-href (org-museum-page-id page) out-file))
      (linksTo . ,(vconcat (org-museum-page-links-to page)))
      (linkedFrom . ,(vconcat (org-museum-page-linked-from page)))
      (contentHtml . ,(org-museum--related-rebase-fragment raw page out-file)))))

(defun org-museum--related-data-alist (out-file)
  "Return complete offline relationship-reading data relative to OUT-FILE."
  (let ((pages (org-museum--related-pages))
        (seen (make-hash-table :test #'equal))
        edges)
    (dolist (page pages)
      (dolist (target (org-museum-page-links-to page))
        (when-let* ((target-page
                    (gethash target (org-museum-index-pages org-museum--index)))
                    ((org-museum--published-page-p target-page)))
          (let* ((source (org-museum-page-id page))
                 (key (mapconcat #'identity (sort (list source target)
                                                  #'string-lessp) "\0")))
            (unless (gethash key seen)
              (puthash key t seen)
              (push `((source . ,source)
                      (target . ,target)
                      (bidirectional . ,(if (member source
                                                    (org-museum-page-links-to
                                                     target-page))
                                             t :json-false)))
                    edges))))))
    `((schemaVersion . 1)
      (generatedAt . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
      (pages . ,(vconcat (mapcar (lambda (page)
                                   (org-museum--related-page-alist page out-file))
                                 pages)))
      (edges . ,(vconcat (nreverse edges))))))

(defun org-museum--write-related-data (out-file)
  "Write content-versioned offline relationship data for OUT-FILE."
  (let ((path (org-museum--related-data-resource-path)))
    (org-museum--write-content-if-changed
     path
     (concat "/* Generated by Org Museum; no network access required. */\n"
             "window.ORG_MUSEUM_RELATED_DATA="
             (org-museum--json-for-html (org-museum--related-data-alist out-file))
             ";\n"))
    path))

(defun org-museum--script-related-reading ()
  "Return the offline relationship-reading page behavior."
  "<script>
(function(){
'use strict';
var data=window.ORG_MUSEUM_RELATED_DATA||{pages:[],edges:[]};
var pages=new Map((data.pages||[]).map(function(page){return [page.id,page];}));
var params=new URLSearchParams(location.search);
var source=pages.get(params.get('source')||'');
var target=pages.get(params.get('target')||'');
var mode=params.get('mode')==='full'?'full':'summary';
var detail=document.getElementById('related-detail');
var index=document.getElementById('related-index');
var empty=document.getElementById('related-empty');
var search=document.getElementById('org-museum-global-search');
var positions={summary:[0,0],full:[0,0]};
var activePane='source',syncScroll=false,syncingScroll=false;

function themed(href){return window.orgMuseumThemeUrl?window.orgMuseumThemeUrl(href):href;}
function links(from,to){return !!from&&Array.isArray(from.linksTo)&&from.linksTo.includes(to.id);}
function relationValid(){return source&&target&&source.id!==target.id&&(links(source,target)||links(target,source));}
function setUrl(nextMode){
  var url=new URL(location.href);url.searchParams.set('source',source.id);
  url.searchParams.set('target',target.id);url.searchParams.set('mode',nextMode);
  history.pushState({},'',url.pathname+url.search+url.hash);
}
function element(tag,className,text){
  var node=document.createElement(tag);if(className)node.className=className;
  if(text!==undefined)node.textContent=text;return node;
}
function pageMeta(page){
  var meta=element('div','related-page-meta');
  meta.appendChild(element('span','related-category',page.categoryLabel||page.category||'未分类'));
  meta.appendChild(element('time','',page.modifiedDate||''));
  (page.tags||[]).forEach(function(tag){meta.appendChild(element('span','related-tag','#'+tag));});
  return meta;
}
function summaryContent(page){
  var root=element('div','related-summary');
  var summary=element('section','related-summary-block');
  summary.appendChild(element('h2','', '摘要'));
  summary.appendChild(element('p','',page.description||'暂无可用摘要。'));root.appendChild(summary);
  var outline=element('section','related-summary-block');outline.appendChild(element('h2','','大纲'));
  var list=element('ol','related-outline');
  (page.headings||[]).forEach(function(item){list.appendChild(element('li','',item.title||''));});
  if(!(page.headings||[]).length)list.appendChild(element('li','related-muted','暂无章节标题'));
  outline.appendChild(list);root.appendChild(outline);
  var excerpts=element('section','related-summary-block');excerpts.appendChild(element('h2','','内容摘录'));
  (page.excerpts||[]).forEach(function(text){excerpts.appendChild(element('p','',text));});
  if(!(page.excerpts||[]).length)excerpts.appendChild(element('p','related-muted','暂无更多摘录。'));
  root.appendChild(excerpts);return root;
}
function updatePanelProgress(panel){
  var bar=panel.querySelector('.related-reading-progress span');
  var max=Math.max(1,panel.scrollHeight-panel.clientHeight);
  var ratio=Math.max(0,Math.min(1,panel.scrollTop/max));
  if(bar)bar.style.transform='scaleX('+ratio+')';
}
function bindPanelScroll(panel,index){
  updatePanelProgress(panel);
  panel.addEventListener('scroll',function(){
    positions[mode][index]=panel.scrollTop;updatePanelProgress(panel);
    if(!syncScroll||mode!=='full'||innerWidth<=820||syncingScroll)return;
    var peers=Array.from(document.querySelectorAll('.related-paper'));
    var other=peers[index===0?1:0];if(!other)return;
    var max=Math.max(1,panel.scrollHeight-panel.clientHeight);
    syncingScroll=true;other.scrollTop=(panel.scrollTop/max)*Math.max(0,other.scrollHeight-other.clientHeight);
    updatePanelProgress(other);requestAnimationFrame(function(){syncingScroll=false;});
  },{passive:true});
}
function setActivePane(value){
  activePane=value==='relation'?'relation':value==='target'?'target':'source';
  document.body.dataset.relatedPane=activePane;
  document.querySelectorAll('[data-related-pane]').forEach(function(button){
    var active=button.dataset.relatedPane===activePane;
    button.classList.toggle('is-active',active);button.setAttribute('aria-pressed',active?'true':'false');
  });
}
function renderPanel(side,page){
  var panel=document.querySelector('[data-related-panel=\"'+side+'\"]');panel.textContent='';
  var progress=element('div','related-reading-progress');progress.setAttribute('aria-hidden','true');
  progress.appendChild(element('span',''));panel.appendChild(progress);
  var badge=element('span','related-role',side==='source'?'源笔记（出链）':'目标笔记（入链）');
  var heading=element('div','related-paper-heading');heading.appendChild(badge);
  heading.appendChild(element('h1','related-page-title',page.title));panel.appendChild(heading);
  panel.appendChild(pageMeta(page));
  if(mode==='full'){
    var full=element('div','related-full article-container');full.innerHTML=page.contentHtml||'';
    panel.appendChild(full);
  }else panel.appendChild(summaryContent(page));
  var open=element('a','related-open','打开完整笔记');open.href=themed(page.href);panel.appendChild(open);
  bindPanelScroll(panel,side==='source'?0:1);
}
function updateMode(nextMode,push){
  document.querySelectorAll('.related-paper').forEach(function(panel,index){positions[mode][index]=panel.scrollTop;});
  mode=nextMode;document.body.dataset.relatedMode=mode;
  document.querySelectorAll('[data-related-mode]').forEach(function(button){
    var active=button.dataset.relatedMode===mode;button.classList.toggle('is-active',active);
    button.setAttribute('aria-pressed',active?'true':'false');
  });
  renderPanel('source',source);renderPanel('target',target);
  document.querySelectorAll('.related-paper').forEach(function(panel,index){panel.scrollTop=positions[mode][index]||0;});
  setActivePane(activePane);
  if(window.hljs)document.querySelectorAll('.related-full pre code').forEach(function(code){window.hljs.highlightElement(code);});
  if(push)setUrl(mode);
}
function renderDetail(){
  if(!links(source,target)&&links(target,source)){var swap=source;source=target;target=swap;}
  index.hidden=true;empty.hidden=true;detail.hidden=false;
  document.getElementById('related-open-source').href=themed(source.href);
  document.getElementById('related-open-target').href=themed(target.href);
  var both=links(source,target)&&links(target,source);
  document.getElementById('related-kind').textContent=both?'显式 Org 双向链接':'显式 Org 链接';
  document.getElementById('related-direction').textContent=both?'源 ↔ 目标':'源 → 目标';
  var swapButton=document.getElementById('related-swap');
  swapButton.hidden=!both;swapButton.addEventListener('click',function(){
    var value=source;source=target;target=value;setUrl(mode);
    document.getElementById('related-open-source').href=themed(source.href);
    document.getElementById('related-open-target').href=themed(target.href);
    renderPanel('source',source);renderPanel('target',target);
    setActivePane(activePane);
  });
  document.querySelectorAll('[data-related-mode]').forEach(function(button){
    button.addEventListener('click',function(){updateMode(button.dataset.relatedMode,true);});
  });
  document.querySelectorAll('[data-related-pane]').forEach(function(button){
    button.addEventListener('click',function(){setActivePane(button.dataset.relatedPane);});
  });
  var syncButton=document.querySelector('[data-related-sync]');
  if(syncButton)syncButton.addEventListener('click',function(){
    syncScroll=!syncScroll;syncButton.classList.toggle('is-active',syncScroll);
    syncButton.setAttribute('aria-pressed',syncScroll?'true':'false');
    syncButton.textContent=syncScroll?'同步滚动：开':'同步滚动：关';
  });
  updateMode(mode,false);
}
function renderIndex(){
  detail.hidden=true;index.hidden=false;empty.hidden=(data.edges||[]).length>0;
  var list=document.getElementById('related-index-list');list.textContent='';
  (data.edges||[]).forEach(function(edge,position){
    var from=pages.get(edge.source),to=pages.get(edge.target);if(!from||!to)return;
    var link=element('a','related-index-row');
    link.href=themed('related.html?source='+encodeURIComponent(from.id)+'&target='+encodeURIComponent(to.id)+'&mode=summary');
    link.dataset.search=[from.title,to.title,from.categoryLabel,to.categoryLabel].join(' ').toLowerCase();
    link.appendChild(element('span','related-index-number',String(position+1).padStart(2,'0')));
    link.appendChild(element('strong','',from.title));
    link.appendChild(element('span','related-index-arrow',edge.bidirectional?'↔':'→'));
    link.appendChild(element('strong','',to.title));
    link.appendChild(element('small','',edge.bidirectional?'双向显式链接':'显式链接'));
    list.appendChild(link);
  });
  if(search)search.addEventListener('input',function(){
    var query=search.value.trim().toLowerCase();
    list.querySelectorAll('.related-index-row').forEach(function(row){row.hidden=!!query&&!row.dataset.search.includes(query);});
  });
}
document.addEventListener('click',function(event){
  var link=event.target.closest('a[href]');if(!link||link.href.startsWith('javascript:'))return;
  var raw=link.getAttribute('href')||'';if(raw.startsWith('#'))return;
  link.href=themed(raw);
});
window.addEventListener('popstate',function(){location.reload();});
if(relationValid())renderDetail();else renderIndex();
})();
</script>")

(defun org-museum--build-related-html (out-file data-file)
  "Return the complete relationship-reading HTML for OUT-FILE and DATA-FILE."
  (let ((data-src (org-museum--versioned-resource-href data-file out-file))
        (hljs-css (org-museum--hljs-css-src out-file))
        (hljs-js (org-museum--hljs-js-src out-file)))
    (concat
     "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n"
     "  <meta charset=\"utf-8\">\n"
     "  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
     "  <meta name=\"color-scheme\" content=\"dark light\">\n"
     "  <title>Org Museum · 关联阅读</title>\n"
     "  " (org-museum--theme-script-tag out-file) "\n"
     "  " (org-museum--css-link-tag out-file) "\n"
     (if hljs-css (format "  <link rel=\"stylesheet\" href=\"%s\">\n"
                            (org-museum--html-escape hljs-css t)) "")
     "  " org-museum--favicon-link-tag "\n</head>\n"
     "<body class=\"related-page\" data-page-kind=\"related\">\n"
     (org-museum--build-topbar out-file 'related)
     (org-museum--generate-sidebar-html out-file)
     "<main id=\"main-content\" class=\"museum-related-shell\" tabindex=\"-1\">\n"
     "  <section id=\"related-index\" class=\"related-index\">\n"
     "    <header><p>关系书架</p><h1>显式 Org 关联阅读</h1>"
     "<span>只展示笔记中真实存在的出链与入链。</span></header>\n"
     "    <div id=\"related-index-list\" class=\"related-index-list\"></div>\n"
     "    <p id=\"related-empty\" class=\"museum-empty-copy\" hidden>当前还没有可对读的显式关系。</p>\n"
     "  </section>\n"
     "  <section id=\"related-detail\" class=\"related-detail\" hidden>\n"
     "    <div class=\"related-modebar\" role=\"group\" aria-label=\"对读内容密度\">"
     "<button type=\"button\" data-related-mode=\"summary\" aria-pressed=\"true\">摘要对读</button>"
     "<button type=\"button\" data-related-mode=\"full\" aria-pressed=\"false\">完整正文</button>"
     "<button type=\"button\" data-related-sync aria-pressed=\"false\">同步滚动：关</button>"
     "<a id=\"related-open-source\" href=\"#\">打开源笔记</a>"
     "<a href=\"graph.html\">返回知识图谱</a>"
     "<a id=\"related-open-target\" href=\"#\">打开目标笔记</a>"
     "<span class=\"related-mobile-segments\" role=\"group\" aria-label=\"移动端对读区域\">"
     "<button type=\"button\" data-related-pane=\"source\" aria-pressed=\"true\">源笔记</button>"
     "<button type=\"button\" data-related-pane=\"relation\" aria-pressed=\"false\">关系</button>"
     "<button type=\"button\" data-related-pane=\"target\" aria-pressed=\"false\">目标笔记</button></span></div>\n"
     "    <div class=\"related-reading-grid\">\n"
     "      <article class=\"related-paper\" data-related-panel=\"source\" aria-label=\"源笔记\"></article>\n"
     "      <aside class=\"related-bridge\" aria-label=\"关系方向\">"
     "<strong id=\"related-kind\">显式 Org 链接</strong><span aria-hidden=\"true\">→</span>"
     "<p id=\"related-direction\">源 → 目标</p>"
     "<button type=\"button\" id=\"related-swap\" hidden>交换方向</button>"
     "<a href=\"graph.html\">返回知识图谱</a></aside>\n"
     "      <article class=\"related-paper\" data-related-panel=\"target\" aria-label=\"目标笔记\"></article>\n"
     "    </div>\n"
     "  </section>\n</main>\n"
     (format "<script src=\"%s\"></script>\n" (org-museum--html-escape data-src t))
     (if hljs-js (format "<script src=\"%s\"></script>\n"
                          (org-museum--html-escape hljs-js t)) "")
     (org-museum--script-related-reading)
     (org-museum--script-shell)
     "</body>\n</html>\n")))

(defun org-museum--export-related-reading-current ()
  "Generate the relationship-reading page using the current runtime."
  (org-museum--guard-init)
  (org-museum--ensure-css-deployed)
  (org-museum--hljs-assets)
  (unless org-museum--index (org-museum-index-build))
  (let* ((out-file (org-museum--related-output-path))
         (data-file (org-museum--write-related-data out-file))
         (html (org-museum--build-related-html out-file data-file)))
    (org-museum--write-content-if-changed
     out-file (org-museum--externalize-page-runtime html out-file 'related))
    out-file))

;;;###autoload
(defun org-museum-export-related-reading ()
  "Generate the offline relationship-reading center."
  (interactive)
  (org-museum--run-with-current-runtime
   'org-museum-export-related-reading nil
   #'org-museum--export-related-reading-current))

;; ============================================================
;; §21b  CHRONOLOGICAL READING
;; ============================================================

(defun org-museum--timeline-pages ()
  "Return indexed pages in stable creation-time order."
  (sort (copy-sequence (org-museum--related-pages))
        (lambda (left right)
          (let ((left-time (org-museum--page-created-number left))
                (right-time (org-museum--page-created-number right)))
            (if (= left-time right-time)
                (string-lessp (org-museum-page-title left)
                              (org-museum-page-title right))
              (< left-time right-time))))))

(defun org-museum--timeline-page-alist (page out-file)
  "Return browser-facing chronological data for PAGE relative to OUT-FILE."
  (let* ((description (string-trim
                       (or (org-museum-page-description page) "")))
         (fallback
          (when (string-empty-p description)
            (car (org-museum--related-paragraphs
                  (or (org-museum--related-article-fragment page) "") 1)))))
    `((id . ,(org-museum-page-id page))
      (title . ,(org-museum-page-title page))
      (category . ,(org-museum-page-category page))
      (categoryLabel . ,(org-museum--category-label
                         (org-museum-page-category page)))
      (tags . ,(vconcat (org-museum-page-tags page)))
      (status . ,(downcase (or (org-museum-page-status page) "published")))
      (description . ,(if (string-empty-p description)
                          (or fallback "暂无可用简介。")
                        description))
      (created . ,(org-museum--page-created-number page))
      (createdDate . ,(org-museum--format-page-created-date page))
      (dateSource . ,(symbol-name (or (org-museum-page-date-source page)
                                      'modified-fallback)))
      (modified . ,(org-museum--page-modified-number page))
      (modifiedDate . ,(org-museum--format-page-date page))
      (ageDays . ,(max 0 (- (time-to-days
                             (seconds-to-time
                              (org-museum--page-modified-number page)))
                            (time-to-days
                             (seconds-to-time
                              (org-museum--page-created-number page))))))
      (linksTo . ,(vconcat (org-museum-page-links-to page)))
      (linkedFrom . ,(vconcat (org-museum-page-linked-from page)))
      (href . ,(org-museum--page-href (org-museum-page-id page) out-file)))))

(defun org-museum--timeline-data-alist (out-file)
  "Return complete offline timeline data relative to OUT-FILE."
  (let* ((pages (org-museum--timeline-pages))
         (related (org-museum--related-data-alist out-file)))
    `((schemaVersion . 1)
      (generatedAt . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
      (today . ,(format-time-string "%Y-%m-%d"))
      (pages . ,(vconcat
                 (mapcar (lambda (page)
                           (org-museum--timeline-page-alist page out-file))
                         pages)))
      (edges . ,(cdr (assq 'edges related))))))

(defun org-museum--script-timeline ()
  "Return the offline chronological-reading page behavior."
  "<script>
(function(){
'use strict';
var raw=JSON.parse(document.getElementById('timeline-data').textContent);
var pages=(raw.pages||[]).slice().sort(function(a,b){return a.created-b.created||a.title.localeCompare(b.title,'zh-CN');});
var edges=raw.edges||[],palette=raw.palette||[];
var pageMap=new Map(pages.map(function(page){return [page.id,page];}));
var search=document.getElementById('org-museum-global-search');
var canvas=document.getElementById('timeline-canvas');
var svgHost=document.getElementById('timeline-svg');
var mobileList=document.getElementById('timeline-mobile-list');
var focusCard=document.getElementById('timeline-focus-card');
var timelineLayout=document.querySelector('.timeline-layout');
var tooltip=document.getElementById('timeline-tooltip');
var categoryRoot=document.getElementById('timeline-category-filters');
var statusRoot=document.getElementById('timeline-status-filters');
var matchStatus=document.getElementById('timeline-match-status');
var scopeSummary=document.getElementById('timeline-scope-summary');
var scopeBar=document.querySelector('.timeline-scope-bar');
var filterToggle=document.getElementById('timeline-filter-toggle');
var filterSheet=document.getElementById('timeline-filter-sheet');
var filterClose=document.getElementById('timeline-filter-close');
var filterBackdrop=document.getElementById('timeline-filter-backdrop');
var filterResult=document.getElementById('timeline-filter-result');
var isolatedList=document.getElementById('timeline-isolated-list');
var params=new URLSearchParams(location.search);
if('scrollRestoration' in history)history.scrollRestoration='manual';
history.replaceState({scrollY:scrollY},'',location.href);
var state={query:(params.get('q')||'').trim().toLowerCase(),category:params.get('category')||'*',status:params.get('status')||'all',focus:params.get('focus')||''};
var categories=Array.from(new Set(pages.map(function(page){return page.categoryLabel||page.category||'未分类';}))).sort();
var desktop=null,filterOpen=false,restoreScroll=null,filterScroll=null,filterTrigger=null,lastViewportWidth=innerWidth,lastMobile=innerWidth<=820;
var mobileItems=new Map(),mobileListSignature='',mobileDetail=element('div','timeline-mobile-detail');
var coordinator={frame:0,geometryFrame:0,scrollFocus:false,focusControl:false,inputMode:'pointer'};
var focusCardBody=element('div','timeline-focus-card-body');
focusCard.appendChild(focusCardBody);mobileDetail.hidden=true;
if(!categories.includes(state.category))state.category='*';
if(!['all','published','draft'].includes(state.status))state.status='all';
if(!pageMap.has(state.focus))state.focus='';
if(search)search.value=state.query;

function themed(href){return window.orgMuseumThemeUrl?window.orgMuseumThemeUrl(href):href;}
function color(page){var label=page.categoryLabel||page.category||'未分类';return window.orgMuseumCategoryColor?window.orgMuseumCategoryColor(label):palette[Math.max(0,categories.indexOf(label))%palette.length]||'var(--museum-ink-muted)';}
function element(tag,className,text){var node=document.createElement(tag);if(className)node.className=className;if(text!==undefined)node.textContent=text;return node;}
function relationCount(page){return new Set([].concat(page.linksTo||[],page.linkedFrom||[])).size;}
function matches(page){var hay=[page.title,page.categoryLabel,page.category].concat(page.tags||[]).join(' ').toLowerCase();return (state.category==='*'||(page.categoryLabel||page.category)===state.category)&&(state.status==='all'||page.status===state.status)&&(!state.query||hay.includes(state.query));}
function visiblePages(){return pages.filter(matches);}
function writeUrl(mode){var url=new URL(location.href),currentScroll=filterOpen&&filterScroll!==null?filterScroll:scrollY;['q','category','status','focus'].forEach(function(key){url.searchParams.delete(key);});if(state.query)url.searchParams.set('q',state.query);if(state.category!=='*')url.searchParams.set('category',state.category);if(state.status!=='all')url.searchParams.set('status',state.status);if(state.focus)url.searchParams.set('focus',state.focus);if(mode==='push'){history.replaceState({scrollY:currentScroll},'',location.href);history.pushState({scrollY:currentScroll},'',url.pathname+url.search+url.hash);}else history.replaceState({scrollY:currentScroll},'',url.pathname+url.search+url.hash);}
function daysBetween(page){if(Number.isFinite(page.ageDays))return Math.max(0,page.ageDays);var created=Date.parse(page.createdDate+'T00:00:00Z'),modified=Date.parse(page.modifiedDate+'T00:00:00Z');if(Number.isFinite(created)&&Number.isFinite(modified))return Math.max(0,Math.round((modified-created)/86400000));return Math.max(0,Math.floor((page.modified-page.created)/86400));}
function intervalText(page){var days=daysBetween(page);return page.createdDate===page.modifiedDate?'创建当日完成更新':'创建后 '+days+' 天更新';}
function relatedHref(page){var outgoing=(page.linksTo||[])[0],incoming=(page.linkedFrom||[])[0];if(!outgoing&&!incoming)return '';return themed('related.html?source='+encodeURIComponent(outgoing?page.id:incoming)+'&target='+encodeURIComponent(outgoing?outgoing:page.id)+'&mode=summary');}
function visibleIndex(page,list){return list.findIndex(function(item){return item.id===page.id;});}
function reducedMotion(){return matchMedia('(prefers-reduced-motion: reduce)').matches;}
function motionBehavior(){return reducedMotion()?'auto':'smooth';}
function scrollToPosition(target){target=Math.max(0,target);cancelAnimationFrame(coordinator.scrollAnimation||0);if(reducedMotion()){window.scrollTo(0,target);return;}var start=scrollY,change=target-start,began=performance.now();if(Math.abs(change)<2)return;function step(now){var progress=Math.min(1,(now-began)/180),eased=1-Math.pow(1-progress,3);window.scrollTo(0,start+change*eased);if(progress<1)coordinator.scrollAnimation=requestAnimationFrame(step);}coordinator.scrollAnimation=requestAnimationFrame(step);}
function safeViewportTop(){if(innerWidth<=820&&scopeBar)return scopeBar.getBoundingClientRect().height+12;var topbar=document.querySelector('.museum-topbar');return Math.max(12,topbar&&getComputedStyle(topbar).position==='fixed'?topbar.getBoundingClientRect().bottom+12:12);}
function revealWithinViewport(node,mobile){if(!node)return;var rect=node.getBoundingClientRect(),safeTop=safeViewportTop(),safeBottom=innerHeight-16,delta=0;if(mobile)delta=rect.top-safeTop;else if(rect.top<safeTop)delta=rect.top-safeTop;else if(rect.bottom>safeBottom)delta=rect.bottom-safeBottom;if(Math.abs(delta)<2)return;scrollToPosition(scrollY+delta);}
function relationshipList(page){var root=element('div','timeline-focus-relations');var ids=new Set([].concat(page.linksTo||[],page.linkedFrom||[]));if(!ids.size){root.appendChild(element('p','timeline-focus-empty','暂无显式 Org 链接'));return root;}ids.forEach(function(id){var other=pageMap.get(id);if(!other)return;var out=(page.linksTo||[]).includes(id),back=(page.linkedFrom||[]).includes(id);var row=element('div','timeline-focus-relation');row.appendChild(element('span','',out&&back?'双向':out?'出链':'入链'));row.appendChild(element('b','',other.title));root.appendChild(row);});return root;}
function detailContent(page,compact){var list=visiblePages(),at=visibleIndex(page,list),root=element('div',compact?'timeline-mobile-detail-content':'timeline-focus-content');root.appendChild(element('p','timeline-preview-kicker',intervalText(page)));root.appendChild(element('h2','',page.title));var meta=element('dl','timeline-preview-meta');[['主题',page.categoryLabel||page.category||'未分类'],['状态',page.status==='draft'?'草稿':'已发布'],['创建',page.createdDate],['更新',page.modifiedDate]].forEach(function(row){var wrap=element('div','');wrap.appendChild(element('dt','',row[0]));wrap.appendChild(element('dd','',row[1]));meta.appendChild(wrap);});root.appendChild(meta);root.appendChild(element('p','timeline-preview-summary',page.description||'暂无可用简介。'));var tags=element('div','timeline-preview-tags');(page.tags||[]).forEach(function(tag){tags.appendChild(element('span','','#'+tag));});root.appendChild(tags);root.appendChild(relationshipList(page));var nav=element('div','timeline-focus-nav');var previous=element('button','timeline-previous','上一篇');previous.type='button';previous.disabled=at<=0;previous.addEventListener('click',function(){navigateRelative(-1);});var next=element('button','timeline-next','下一篇');next.type='button';next.disabled=at<0||at>=list.length-1;next.addEventListener('click',function(){navigateRelative(1);});var close=element('button','timeline-return',compact?'收起详情':'返回时间线');close.type='button';close.addEventListener('click',clearFocus);nav.appendChild(previous);nav.appendChild(next);nav.appendChild(close);root.appendChild(nav);var actions=element('div','timeline-preview-actions');var open=element('a','timeline-open-note','打开笔记');open.href=themed(page.href);actions.appendChild(open);var href=relatedHref(page);if(href){var related=element('a','','关联阅读');related.href=href;actions.appendChild(related);}root.appendChild(actions);return root;}
function focusButton(id){if(innerWidth<=820||timelineListMode){var entry=mobileItems.get(id);return entry&&entry.button;}return desktop&&desktop.groups.filter(function(page){return page.id===id;}).node();}
function scheduleTimelineUpdate(options){options=options||{};coordinator.scrollFocus=coordinator.scrollFocus||!!options.scrollFocus;coordinator.focusControl=coordinator.focusControl||!!options.focusControl;if(coordinator.frame)return;coordinator.frame=requestAnimationFrame(function(){coordinator.frame=0;var page=pageMap.get(state.focus);applyFocus();applyMobileFocus(page);var node=page&&focusButton(page.id);if(coordinator.focusControl&&node&&typeof node.focus==='function')node.focus({preventScroll:true});if(coordinator.scrollFocus&&page){if(innerWidth<=820||timelineListMode)revealWithinViewport(node,true);else if(!focusCard.hidden)revealWithinViewport(focusCard,false);}coordinator.scrollFocus=false;coordinator.focusControl=false;});}
function clearFocus(){var old=state.focus;if(!old)return;state.focus='';writeUrl('push');tooltip.hidden=true;if(coordinator.inputMode!=='keyboard'&&document.activeElement&&typeof document.activeElement.blur==='function')document.activeElement.blur();scheduleTimelineUpdate();var node=focusButton(old);if(coordinator.inputMode==='keyboard'&&node&&typeof node.focus==='function')node.focus({preventScroll:true});if(restoreScroll!==null&&innerWidth<=820){var target=restoreScroll;restoreScroll=null;requestAnimationFrame(function(){scrollToPosition(target);});}}
function setFocus(page,push,fromNavigation){if(!page)return clearFocus();if(state.focus===page.id){if(fromNavigation){var current=focusButton(page.id);if(current)current.focus({preventScroll:true});}return;}if(!state.focus&&innerWidth<=820)restoreScroll=scrollY;state.focus=page.id;writeUrl(push?'push':'replace');scheduleTimelineUpdate({scrollFocus:true,focusControl:fromNavigation});}
function navigateRelative(offset){var list=visiblePages(),page=pageMap.get(state.focus),at=visibleIndex(page,list),next=list[at+offset];if(next)setFocus(next,true,true);}
function restoreFilterFocus(root,value){requestAnimationFrame(function(){var active=root.querySelector('[data-value=\"'+CSS.escape(value)+'\"]');if(active)active.focus({preventScroll:true});});}
function renderFilters(){categoryRoot.textContent='';[['*','全部']].concat(categories.map(function(value){return [value,value];})).forEach(function(item){var matching=pages.filter(function(page){return item[0]==='*'||(page.categoryLabel||page.category)===item[0];});var button=element('button',state.category===item[0]?'is-active':'',item[1]+' '+String(matching.length).padStart(2,'0'));button.type='button';button.dataset.value=item[0];button.style.setProperty('--timeline-color',item[0]==='*'?'var(--museum-accent)':color(matching[0]));button.setAttribute('aria-pressed',state.category===item[0]?'true':'false');button.addEventListener('click',function(){state.category=item[0];writeUrl('push');render();restoreFilterFocus(categoryRoot,item[0]);});categoryRoot.appendChild(button);});statusRoot.textContent='';[['all','全部'],['published','已发布'],['draft','草稿']].forEach(function(item){var count=pages.filter(function(page){return item[0]==='all'||page.status===item[0];}).length;var button=element('button',state.status===item[0]?'is-active':'',item[1]+' '+String(count).padStart(2,'0'));button.type='button';button.dataset.value=item[0];button.setAttribute('aria-pressed',state.status===item[0]?'true':'false');button.addEventListener('click',function(){state.status=item[0];writeUrl('push');render();restoreFilterFocus(statusRoot,item[0]);});statusRoot.appendChild(button);});}
function renderIsolated(){isolatedList.textContent='';var isolated=visiblePages().filter(function(page){return relationCount(page)===0;});isolated.forEach(function(page){var button=element('button','',page.title);button.type='button';button.style.setProperty('--timeline-color',color(page));button.addEventListener('click',function(){setFocus(page,true);});isolatedList.appendChild(button);});document.getElementById('timeline-isolated-count').textContent=String(isolated.length).padStart(2,'0');}
function buildMobileList(list){var signature=list.map(function(page){return page.id;}).join('|');if(signature===mobileListSignature){applyMobileFocus(pageMap.get(state.focus));return;}mobileListSignature=signature;mobileItems.clear();mobileList.textContent='';var month='',date='';list.forEach(function(page){var currentMonth=page.createdDate.slice(0,7);if(currentMonth!==month){month=currentMonth;var monthHeading=element('li','timeline-mobile-month',currentMonth.replace('-',' / '));monthHeading.setAttribute('aria-hidden','true');mobileList.appendChild(monthHeading);date='';}if(page.createdDate!==date){date=page.createdDate;var dateHeading=element('li','timeline-mobile-date',page.createdDate.slice(5).replace('-',' / '));dateHeading.setAttribute('aria-hidden','true');mobileList.appendChild(dateHeading);}var item=element('li','timeline-mobile-item');item.style.setProperty('--timeline-color',color(page));var button=element('button','timeline-mobile-node');button.type='button';button.dataset.pageId=page.id;button.setAttribute('aria-label',page.createdDate+' '+page.title+' '+(page.categoryLabel||page.category||'未分类'));button.appendChild(element('strong','',page.title));button.appendChild(element('span','',page.categoryLabel||page.category||'未分类'));button.addEventListener('click',function(){setFocus(page,true);});button.addEventListener('dblclick',function(){location.href=themed(page.href);});button.addEventListener('keydown',function(event){var listNow=visiblePages(),next;if(event.key==='Enter'){event.preventDefault();location.href=themed(page.href);}else if(event.key===' '){event.preventDefault();setFocus(page,true);}else if(event.key==='ArrowLeft'||event.key==='ArrowRight'){var at=visibleIndex(page,listNow);next=listNow[at+(event.key==='ArrowRight'?1:-1)];}else if(event.key==='ArrowUp'||event.key==='ArrowDown'){var peers=sameDateGroup(page,listNow),peerAt=visibleIndex(page,peers);next=peers[peerAt+(event.key==='ArrowDown'?1:-1)];}if(next){event.preventDefault();setFocus(next,true,true);}});item.appendChild(button);mobileItems.set(page.id,{item:item,button:button});mobileList.appendChild(item);});applyMobileFocus(pageMap.get(state.focus));}
function applyMobileFocus(page){mobileItems.forEach(function(entry,id){entry.button.setAttribute('aria-pressed',page&&id===page.id?'true':'false');entry.item.classList.toggle('is-selected',!!page&&id===page.id);});if(!page||(innerWidth>820&&!timelineListMode)){mobileDetail.hidden=true;return;}var entry=mobileItems.get(page.id);if(!entry){mobileDetail.hidden=true;return;}if(mobileDetail.dataset.pageId!==page.id||mobileDetail.dataset.list!==mobileListSignature){mobileDetail.dataset.pageId=page.id;mobileDetail.dataset.list=mobileListSignature;mobileDetail.replaceChildren(detailContent(page,true));}entry.item.appendChild(mobileDetail);mobileDetail.hidden=false;}
function sameDateGroup(page,list){return list.filter(function(item){return item.createdDate===page.createdDate;});}
var timelineListMode=false;
function renderDesktop(){svgHost.textContent='';desktop=null;timelineListMode=false;document.body.classList.remove('timeline-dense-list');if(!pages.length){svgHost.appendChild(element('p','museum-empty-copy','还没有可展示的时间节点。'));return;}if(typeof d3==='undefined'){svgHost.appendChild(element('p','museum-empty-copy','时间轴绘制资源不可用，请使用下方时间列表。'));return;}var width=Math.max(canvas.clientWidth||760,640),height=Math.max(canvas.clientHeight||500,500),pad=54,axisY=Math.round(height*.52);var day=86400000;var min=d3.min(pages,function(page){return page.created*1000;})-7*day;var max=d3.max(pages,function(page){return Math.max(page.created,page.modified)*1000;})+7*day;if(max<=min)max=min+14*day;var scale=d3.scaleTime().domain([new Date(min),new Date(max)]).range([pad,width-pad]);var svg=d3.select(svgHost).append('svg').attr('viewBox','0 0 '+width+' '+height).attr('role','group').attr('aria-label','知识时间轴');var defs=svg.append('defs');defs.append('marker').attr('id','timeline-arrow').attr('viewBox','0 -4 8 8').attr('refX',7).attr('refY',0).attr('markerWidth',7).attr('markerHeight',7).attr('orient','auto-start-reverse').append('path').attr('d','M0,-4L8,0L0,4Z');var layer=svg.append('g');var monthAxis=d3.axisTop(scale).ticks(Math.max(2,Math.floor(width/120))).tickFormat(d3.timeFormat('%Y / %m')).tickSize(-(height-90));layer.append('g').attr('class','timeline-month-axis').attr('transform','translate(0,'+(axisY-12)+')').call(monthAxis);layer.append('line').attr('class','timeline-axis-line').attr('x1',pad).attr('x2',width-pad).attr('y1',axisY).attr('y2',axisY);
var seenMonths=new Set();layer.selectAll('.timeline-month-axis .tick').filter(function(tick){var key=tick.getFullYear()+'-'+tick.getMonth();if(seenMonths.has(key))return true;seenMonths.add(key);return false;}).remove();
var today=new Date((raw.today||'')+'T00:00:00');if(Number.isFinite(today.getTime())&&today>=new Date(min)&&today<=new Date(max)){var tx=scale(today);layer.append('line').attr('class','timeline-today-line').attr('x1',tx).attr('x2',tx).attr('y1',axisY-170).attr('y2',axisY+170);layer.append('text').attr('class','timeline-today-label').attr('x',tx).attr('y',axisY+28).attr('text-anchor','middle').text(d3.timeFormat('%m / %d')(today));}
var relationLayer=layer.append('g').attr('class','timeline-relation-layer');var updateLayer=layer.append('g').attr('class','timeline-update-layer');var laneLast=[],nodeLayout=new Map(),lastDateX=-Infinity;pages.forEach(function(page){var x=scale(new Date(page.created*1000)),lane=0;while(lane<laneLast.length&&x-laneLast[lane]<140)lane+=1;if(lane===laneLast.length)laneLast.push(x);else laneLast[lane]=x;nodeLayout.set(page.id,{x:x,lane:lane,above:lane%2===0,y:axisY+(lane%2===0?-1:1)*(54+Math.floor(lane/2)*34),showDate:x-lastDateX>=44});if(x-lastDateX>=44)lastDateX=x;});if(laneLast.length>12){timelineListMode=true;document.body.classList.add('timeline-dense-list');svgHost.textContent='';applyMobileFocus(pageMap.get(state.focus));return;}var groups=layer.append('g').attr('class','timeline-nodes').selectAll('g').data(pages).enter().append('g').attr('class','timeline-node').attr('tabindex',0).attr('role','button').attr('aria-label',function(page){return page.title+'，创建于 '+page.createdDate+'，Space 选择，Enter 打开';});groups.each(function(page){var item=nodeLayout.get(page.id),group=d3.select(this).attr('transform','translate('+item.x+',0)').style('--timeline-color',color(page));group.append('line').attr('class','timeline-node-stem').attr('y1',axisY).attr('y2',item.y);group.append('circle').attr('class','timeline-node-dot').attr('cy',axisY).attr('r',5);group.append('circle').attr('class','timeline-node-category').attr('cy',item.y).attr('r',4);var text=group.append('text').attr('class','timeline-node-title').attr('text-anchor','middle').attr('y',item.above?item.y-12:item.y+20);var title=page.title||'未命名';group.append('title').text(page.createdDate+' '+title);text.text(title.length>10?title.slice(0,10)+'…':title);if(item.showDate)group.append('text').attr('class','timeline-node-date').attr('text-anchor','middle').attr('y',axisY+24).text(page.createdDate.slice(5).replace('-',' / '));});groups.on('click',function(event,page){event.stopPropagation();setFocus(page,true);}).on('dblclick',function(event,page){event.stopPropagation();location.href=themed(page.href);}).on('mouseenter',function(event,page){tooltip.textContent=page.createdDate+' · '+page.title;tooltip.hidden=false;var rect=canvas.getBoundingClientRect();tooltip.style.left=Math.min(rect.width-220,Math.max(12,event.clientX-rect.left+12))+'px';tooltip.style.top=Math.max(10,event.clientY-rect.top-42)+'px';}).on('mouseleave',function(){tooltip.hidden=true;}).on('blur',function(){tooltip.hidden=true;}).on('keydown',function(event,page){var list=visiblePages(),active=pageMap.get(state.focus),current=active&&matches(active)?active:page,at=visibleIndex(current,list),next;if(event.key==='Enter'){event.preventDefault();location.href=themed(current.href);}else if(event.key===' '){event.preventDefault();setFocus(current,true);}else if(event.key==='ArrowLeft'||event.key==='ArrowRight'){next=list[at+(event.key==='ArrowRight'?1:-1)];}else if(event.key==='ArrowUp'||event.key==='ArrowDown'){var peers=sameDateGroup(current,list),peerAt=visibleIndex(current,peers);next=peers[peerAt+(event.key==='ArrowDown'?1:-1)];}if(next){event.preventDefault();setFocus(next,true,true);}});svg.on('click',function(event){if(event.target===svg.node())clearFocus();});desktop={width:width,height:height,axisY:axisY,scale:scale,groups:groups,nodeLayout:nodeLayout,relationLayer:relationLayer,updateLayer:updateLayer};applyVisibility();applyFocus();}
function scheduleDesktopGeometry(){if(innerWidth<=820||timelineListMode||!desktop)return;cancelAnimationFrame(coordinator.geometryFrame);coordinator.geometryFrame=requestAnimationFrame(function(){coordinator.geometryFrame=0;var nextWidth=Math.max(canvas.clientWidth||760,640),nextHeight=Math.max(canvas.clientHeight||500,500);if(Math.abs(nextWidth-desktop.width)<1&&Math.abs(nextHeight-desktop.height)<1)return;renderDesktop();bindDesktopKeyboard();});}
function bindDesktopKeyboard(){if(!desktop)return;desktop.groups.on('keydown',function(event,page){var list=visiblePages(),at=visibleIndex(page,list),next;if(event.key==='Enter'){event.preventDefault();location.href=themed(page.href);}else if(event.key===' '){event.preventDefault();setFocus(page,true);}else if(event.key==='ArrowLeft'||event.key==='ArrowRight'){next=list[at+(event.key==='ArrowRight'?1:-1)];}else if(event.key==='ArrowUp'||event.key==='ArrowDown'){var peers=sameDateGroup(page,list),peerAt=visibleIndex(page,peers);next=peers[peerAt+(event.key==='ArrowDown'?1:-1)];}if(next){event.preventDefault();setFocus(next,true,true);}});var svg=desktop.groups.node()&&desktop.groups.node().ownerSVGElement;if(svg)d3.select(svg).on('click',function(event){if(!event.target.closest||!event.target.closest('.timeline-node'))clearFocus();});}
function drawRelations(page){if(!desktop)return;desktop.relationLayer.selectAll('*').remove();if(!page)return;var visibleIds=new Set(visiblePages().map(function(item){return item.id;}));edges.filter(function(edge){return visibleIds.has(edge.source)&&visibleIds.has(edge.target)&&(edge.source===page.id||edge.target===page.id);}).forEach(function(edge,index){var source=pageMap.get(edge.source),target=pageMap.get(edge.target),x1=desktop.scale(new Date(source.created*1000)),x2=desktop.scale(new Date(target.created*1000)),span=Math.abs(x2-x1),lift=58+Math.min(110,span*.22)+index*10;var path=span<12?'M'+(x1-5)+','+desktop.axisY+' C'+(x1-64)+','+(desktop.axisY-122)+' '+(x1+64)+','+(desktop.axisY-122)+' '+(x2+5)+','+desktop.axisY:'M'+x1+','+desktop.axisY+' Q'+((x1+x2)/2)+','+(desktop.axisY-lift)+' '+x2+','+desktop.axisY;desktop.relationLayer.append('path').attr('class','timeline-relation-arc').attr('d',path).attr('marker-end','url(#timeline-arrow)').attr('marker-start',edge.bidirectional?'url(#timeline-arrow)':null);});}
function drawUpdate(page){if(!desktop)return;desktop.updateLayer.selectAll('*').remove();if(!page)return;var cx=desktop.scale(new Date(page.created*1000)),mx=desktop.scale(new Date(page.modified*1000));desktop.updateLayer.append('line').attr('class','timeline-update-span').attr('x1',cx).attr('x2',mx).attr('y1',desktop.axisY).attr('y2',desktop.axisY);desktop.updateLayer.append('circle').attr('class','timeline-update-dot').attr('cx',mx).attr('cy',desktop.axisY).attr('r',6);desktop.updateLayer.append('text').attr('class','timeline-update-label').attr('x',mx).attr('y',desktop.axisY+44).attr('text-anchor','middle').text(page.createdDate===page.modifiedDate?'同日更新':'更新 '+page.modifiedDate.slice(5).replace('-',' / '));}
function applyFocus(){var page=pageMap.get(state.focus),visible=visiblePages(),at=page?visibleIndex(page,visible):-1,nearIds=new Set(at<0?[]:visible.slice(Math.max(0,at-1),at+2).map(function(item){return item.id;})),relatedIds=new Set(page?[].concat(page.linksTo||[],page.linkedFrom||[]):[]);if(desktop){desktop.groups.classed('is-selected',function(item){return !!page&&item.id===page.id;}).classed('is-related',function(item){return relatedIds.has(item.id);}).classed('is-near',function(item){return !!page&&item.id!==page.id&&nearIds.has(item.id);}).classed('is-muted',function(item){return !!page&&item.id!==page.id&&!relatedIds.has(item.id)&&!nearIds.has(item.id);}).attr('aria-pressed',function(item){return page&&item.id===page.id?'true':'false';});drawRelations(page);drawUpdate(page);}focusCard.removeAttribute('data-page-id');var showInspector=!!page&&innerWidth>820&&!timelineListMode;if(timelineLayout)timelineLayout.classList.toggle('has-focus',showInspector);scheduleDesktopGeometry();if(!showInspector){focusCard.hidden=true;return;}var changed=focusCardBody.dataset.pageId!==page.id;focusCard.dataset.pageId=page.id;focusCard.setAttribute('aria-label','当前笔记：'+page.title);if(changed){focusCard.classList.add('is-changing');focusCardBody.dataset.pageId=page.id;focusCardBody.replaceChildren(detailContent(page,false));focusCard.scrollTop=0;requestAnimationFrame(function(){focusCard.classList.remove('is-changing');});}focusCard.hidden=false;}
function applyVisibility(){var list=visiblePages(),ids=new Set(list.map(function(page){return page.id;}));if(desktop)desktop.groups.classed('is-filtered',function(page){return !ids.has(page.id);}).attr('aria-hidden',function(page){return ids.has(page.id)?null:'true';}).attr('tabindex',function(page){return ids.has(page.id)?0:-1;});var labels=[];if(state.category!=='*')labels.push(state.category);if(state.status!=='all')labels.push(state.status==='published'?'已发布':'草稿');if(state.query)labels.push('“'+state.query+'”');scopeSummary.textContent=labels.length?labels.join(' · '):'全部笔记';}
function announce(message,notice){var list=visiblePages(),text=message||list.length+' 个时间节点';matchStatus.textContent=text;if(filterResult)filterResult.textContent=text;scopeBar.classList.toggle('has-notice',!!notice);clearTimeout(window.__museumTimelineNotice);if(notice)window.__museumTimelineNotice=setTimeout(function(){scopeBar.classList.remove('has-notice');matchStatus.textContent=list.length+' 个时间节点';},2200);}
function render(message){var selected=pageMap.get(state.focus),notice=message||'';if(selected&&!matches(selected)){state.focus='';writeUrl('replace');notice='筛选后已清除原选择';selected=null;}var list=visiblePages();focusCardBody.dataset.pageId='';mobileDetail.dataset.pageId='';renderFilters();applyVisibility();buildMobileList(list);bindDesktopKeyboard();applyFocus();applyMobileFocus(selected);renderIsolated();document.getElementById('timeline-total').textContent=String(pages.length).padStart(2,'0');announce(notice,!!notice);}
function setFilterOpen(open,returnFocus){var mobile=innerWidth<=820,nextOpen=mobile&&open;if(nextOpen&&!filterOpen){filterScroll=scrollY;filterTrigger=document.activeElement;document.body.style.position='fixed';document.body.style.top=-filterScroll+'px';document.body.style.width='100%';}filterOpen=nextOpen;filterSheet.dataset.open=filterOpen?'true':'false';filterSheet.setAttribute('role',mobile?'dialog':'region');filterSheet.setAttribute('aria-hidden',mobile&&!filterOpen?'true':'false');filterSheet.setAttribute('aria-modal',filterOpen?'true':'false');filterSheet.inert=mobile&&!filterOpen;filterToggle.setAttribute('aria-expanded',filterOpen?'true':'false');filterBackdrop.hidden=!filterOpen;document.documentElement.classList.toggle('timeline-filter-open',filterOpen);if(filterOpen){var active=filterSheet.querySelector('.is-active');requestAnimationFrame(function(){(active||filterSheet).focus({preventScroll:true});});}else if(filterScroll!==null){var target=filterScroll;filterScroll=null;document.body.style.position='';document.body.style.top='';document.body.style.width='';window.scrollTo(0,target);requestAnimationFrame(function(){if(returnFocus!==false&&(filterTrigger||filterToggle))(filterTrigger||filterToggle).focus({preventScroll:true});filterTrigger=null;});}}
function filterTabTrap(event){if(!filterOpen||event.key!=='Tab')return;var controls=Array.from(filterSheet.querySelectorAll('button:not([disabled]),a[href],input:not([disabled]),[tabindex]:not([tabindex=\"-1\"])'));if(!controls.length)return;var first=controls[0],last=controls[controls.length-1];if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus({preventScroll:true});}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus({preventScroll:true});}}
if(filterToggle)filterToggle.addEventListener('click',function(){setFilterOpen(!filterOpen,true);});if(filterClose)filterClose.addEventListener('click',function(){setFilterOpen(false,true);});if(filterBackdrop)filterBackdrop.addEventListener('click',function(){setFilterOpen(false,true);});
if(search)search.addEventListener('input',function(){state.query=search.value.trim().toLowerCase();writeUrl('replace');render();});
document.addEventListener('pointerdown',function(){coordinator.inputMode='pointer';},true);
document.addEventListener('keydown',function(event){coordinator.inputMode='keyboard';filterTabTrap(event);if(event.defaultPrevented)return;if(event.key==='Escape'){if(filterOpen){setFilterOpen(false,true);return;}if(state.focus){clearFocus();return;}}if(event.key==='/'&&!event.metaKey&&!event.ctrlKey&&!event.altKey&&!/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)){event.preventDefault();if(search)search.focus();}});
document.addEventListener('keydown',function(event){if(event.defaultPrevented||filterOpen||!state.focus||!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(event.key)||/^(INPUT|TEXTAREA|SELECT|BUTTON|A)$/.test(document.activeElement.tagName))return;var list=visiblePages(),current=pageMap.get(state.focus),next;if(event.key==='ArrowLeft'||event.key==='ArrowRight'){var at=visibleIndex(current,list);next=list[at+(event.key==='ArrowRight'?1:-1)];}else{var peers=sameDateGroup(current,list),peerAt=visibleIndex(current,peers);next=peers[peerAt+(event.key==='ArrowDown'?1:-1)];}if(next){event.preventDefault();setFocus(next,true,true);}});
window.addEventListener('resize',function(){clearTimeout(window.__museumTimelineResize);window.__museumTimelineResize=setTimeout(function(){var nextMobile=innerWidth<=820;if(innerWidth===lastViewportWidth&&nextMobile===lastMobile)return;lastViewportWidth=innerWidth;lastMobile=nextMobile;var hadFocus=!!state.focus;if(filterOpen)setFilterOpen(false,false);renderDesktop();buildMobileList(visiblePages());bindDesktopKeyboard();applyFocus();applyMobileFocus(pageMap.get(state.focus));if(hadFocus)scheduleTimelineUpdate({scrollFocus:true});},140);});
window.addEventListener('popstate',function(event){var next=new URLSearchParams(location.search);state.query=(next.get('q')||'').trim().toLowerCase();state.category=next.get('category')||'*';state.status=next.get('status')||'all';state.focus=next.get('focus')||'';if(!categories.includes(state.category))state.category='*';if(!['all','published','draft'].includes(state.status))state.status='all';if(!pageMap.has(state.focus))state.focus='';if(search)search.value=state.query;render();if(state.focus)scheduleTimelineUpdate({scrollFocus:true,focusControl:true});else if(event.state&&Number.isFinite(event.state.scrollY))requestAnimationFrame(function(){scrollToPosition(event.state.scrollY);});});
renderFilters();renderDesktop();render();setFilterOpen(false,false);if(state.focus){scheduleTimelineUpdate({scrollFocus:true});window.addEventListener('load',function(){setTimeout(function(){scheduleTimelineUpdate({scrollFocus:true});},80);},{once:true});}
})();
</script>")

(defun org-museum--build-timeline-html (out-file json-data &optional d3-src)
  "Return the complete chronological-reading HTML for OUT-FILE."
  (concat
   "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n"
   "  <meta charset=\"utf-8\">\n"
   "  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
   "  <meta name=\"color-scheme\" content=\"dark light\">\n"
   "  <title>Org Museum · 知识时间轴</title>\n"
   "  " (org-museum--theme-script-tag out-file) "\n"
   "  " (org-museum--css-link-tag out-file) "\n"
   "  " org-museum--favicon-link-tag "\n</head>\n"
   "<body class=\"timeline-page\" data-page-kind=\"timeline\">\n"
   (org-museum--build-topbar out-file 'timeline)
   (org-museum--generate-sidebar-html out-file)
   "<main id=\"main-content\" class=\"museum-timeline-shell\" tabindex=\"-1\">\n"
   "  <header class=\"timeline-hero\"><p>TIME READING</p><h1>知识的长河</h1><span>按创建时间浏览，在选择中展开知识的更新轨迹</span></header>\n"
   "  <section class=\"timeline-scope-bar\" aria-label=\"当前时间范围\"><button id=\"timeline-filter-toggle\" class=\"timeline-filter-toggle\" type=\"button\" aria-expanded=\"false\" aria-controls=\"timeline-filter-sheet\">筛选</button><strong class=\"timeline-scope-label\">时间范围</strong><span id=\"timeline-scope-summary\">全部笔记</span><span>/ <b id=\"timeline-total\">00</b></span><p id=\"timeline-match-status\" role=\"status\" aria-live=\"polite\">0 个时间节点</p></section>\n"
   "  <div id=\"timeline-filter-backdrop\" class=\"timeline-filter-backdrop\" hidden></div>\n"
   "  <aside id=\"timeline-filter-sheet\" class=\"timeline-filter-sheet\" aria-label=\"时间轴筛选\" aria-modal=\"false\" data-open=\"false\" role=\"dialog\" tabindex=\"-1\"><div class=\"timeline-filter-sheet-head\"><div><strong>筛选时间轨迹</strong><span id=\"timeline-filter-result\" role=\"status\" aria-live=\"polite\">0 个时间节点</span></div><button id=\"timeline-filter-close\" class=\"timeline-filter-close\" type=\"button\">完成</button></div><section><h3>主题</h3><div id=\"timeline-category-filters\" class=\"timeline-filter-list\"></div></section><section><h3>状态</h3><div id=\"timeline-status-filters\" class=\"timeline-filter-list\"></div></section></aside>\n"
   "  <div class=\"timeline-layout\">\n"
   "    <section class=\"timeline-workspace\" aria-label=\"知识时间轴\">\n"
   "      <div class=\"timeline-legend\"><span>● 创建</span><span>○ 选择后显示更新</span><span>↗ 显式 Org 链接</span></div>\n"
   "      <div id=\"timeline-canvas\"><div id=\"timeline-svg\"></div><div id=\"timeline-tooltip\" role=\"tooltip\" hidden></div></div>\n"
   "      <ol id=\"timeline-mobile-list\"></ol>\n"
   "      <details class=\"timeline-isolated\"><summary>孤立笔记 <span id=\"timeline-isolated-count\">00</span></summary><div id=\"timeline-isolated-list\"></div></details>\n"
   "    </section>\n"
   "    <aside id=\"timeline-focus-card\" class=\"timeline-focus-card\" aria-label=\"当前笔记\" tabindex=\"-1\" hidden></aside>\n"
   "  </div>\n</main>\n"
   (if d3-src (format "<script src=\"%s\"></script>\n"
                       (org-museum--html-escape d3-src t)) "")
   "<script type=\"application/json\" id=\"timeline-data\">"
   json-data "</script>\n"
   (org-museum--script-timeline)
   (org-museum--script-shell)
   "</body>\n</html>\n"))

(defun org-museum--export-timeline-current ()
  "Generate timeline.html using the current runtime."
  (org-museum--guard-init)
  (org-museum--ensure-css-deployed)
  (org-museum--ensure-d3-deployed)
  (unless org-museum--index (org-museum-index-build))
  (let* ((out-file (org-museum--timeline-output-path))
         (json-data
          (org-museum--json-for-html
           (append (org-museum--timeline-data-alist out-file)
                   `((palette . ,org-museum--graph-palette)))))
         (html (org-museum--build-timeline-html
                out-file json-data (org-museum--d3-js-src out-file))))
    (org-museum--write-content-if-changed
     out-file (org-museum--externalize-page-runtime html out-file 'timeline))
    out-file))

;;;###autoload
(defun org-museum-export-timeline ()
  "Generate the offline chronological-reading page."
  (interactive)
  (org-museum--run-with-current-runtime
   'org-museum-export-timeline nil #'org-museum--export-timeline-current))

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
         (c-col    (or (plist-get config :center-color) "var(--museum-primary)"))
         (n-col    (or (plist-get config :node-color)   "var(--museum-category-1)"))
         (l-col    (or (plist-get config :link-color)   "var(--museum-relation-default)"))
         (fsize    (or (plist-get config :font-size)    "11px"))
         (nav      (if (plist-get config :nav-on-click)       "true" "false"))
         (labels   (if (plist-get config :show-labels)        "true" "false"))
         (use-cat  (if (plist-get config :use-category-color) "true" "false"))
         (arrows   (if (plist-get config :link-arrow)         "true" "false"))
         (palette  (json-encode org-museum--graph-palette)))
    (format "
  var pal=%s;
  var cats=Array.from(new Set((%s).nodes.map(function(d){return d.group||'';})));
  function catCol(c){return window.orgMuseumCategoryColor?window.orgMuseumCategoryColor(c):pal[cats.indexOf(c)%%(pal.length)]||'var(--museum-ink-muted)';}
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
      .style('font-size','%s').style('fill','var(--museum-ink)')
      .style('font-family','var(--font-ui)');
  }
  if(%s){node.on('click',function(e,d){
    var target=d.url||(d.id+'.html');
    window.location.href=window.orgMuseumThemeUrl?
      window.orgMuseumThemeUrl(target):target;
  });}
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
[Fix-08] Sort excessive neighbours by degree, then fold overflow nodes into a
virtual node linked to the page's entry in graph.html.
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
                             (degree . ,(length
                                         (cl-union
                                          (org-museum-page-links-to page)
                                          (org-museum-page-linked-from page)
                                          :test #'equal)))
                             (url . ,(org-museum--page-href center-id out-file)))))
         (links      '()))
    (dolist (nid capped)
      (when-let* ((p (gethash nid pages)))
        (push `((id . ,nid)
                (name . ,(org-museum-page-title p))
                (degree . ,(length
                            (cl-union (org-museum-page-links-to p)
                                      (org-museum-page-linked-from p)
                                      :test #'equal)))
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


(defun org-museum--build-graph-html (json-data css-href &optional d3-src)
  "Return the unified Monokai graph page for JSON-DATA."
  (let* ((graph-file (expand-file-name "graph.html" (org-museum--shared-root)))
         (topbar (org-museum--build-topbar graph-file 'graph))
         (theme-tag (org-museum--theme-script-tag graph-file))
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
  <meta name=\"color-scheme\" content=\"dark light\">
  <title>Org Museum · 知识图谱</title>
  %s
  <link rel=\"stylesheet\" href=\"%s\">
  <link rel=\"icon\" href=\"data:,\">
  %s
</head>
<body class=\"graph-page\" data-page-kind=\"graph\">
%s
%s
<main id=\"main-content\" class=\"museum-graph-shell\" tabindex=\"-1\">
  <header class=\"graph-commandbar\">
    <div class=\"graph-commandbar-title\">
      <div class=\"museum-section-heading\"><h1>知识图谱</h1><span id=\"graph-heading-count\">/ 00</span></div>
      <p>沿真实链接阅读，或整理尚未连接的笔记。</p>
    </div>
    <nav class=\"graph-mode-tabs\" aria-label=\"图谱工作模式\">
      <button type=\"button\" data-graph-view=\"relations\" aria-pressed=\"true\">关系阅读 <b id=\"graph-relation-count\">00</b></button>
      <button type=\"button\" data-graph-view=\"triage\" aria-pressed=\"false\">待连接 <b id=\"graph-triage-count\">00</b></button>
    </nav>
    <details class=\"graph-filter-summary\">
      <summary>范围 <span id=\"graph-filter-label\">全部主题</span></summary>
      <div id=\"graph-category-filters\"></div>
    </details>
    <dl class=\"graph-counts\" aria-label=\"图谱统计\">
      <div><dt>笔记</dt><dd id=\"stat-nodes\">00</dd></div>
      <div><dt>连线</dt><dd id=\"stat-links\">00</dd></div>
      <div><dt>主题</dt><dd id=\"stat-cats\">00</dd></div>
    </dl>
    <div class=\"graph-view-controls\" aria-label=\"画布控制\">
      <div class=\"graph-control-grid\">
        <button type=\"button\" id=\"btn-zoom-in\" aria-label=\"放大图谱\"><i data-graph-icon=\"plus\"></i><span>放大</span></button>
        <button type=\"button\" id=\"btn-zoom-out\" aria-label=\"缩小图谱\"><i data-graph-icon=\"minus\"></i><span>缩小</span></button>
        <button type=\"button\" id=\"btn-reset\" aria-label=\"适配全部关系\"><i data-graph-icon=\"corners-out\"></i><span>适配</span></button>
        <button type=\"button\" id=\"btn-center\" aria-label=\"居中当前节点\"><i data-graph-icon=\"crosshair\"></i><span>居中</span></button>
      </div>
      <button type=\"button\" id=\"btn-layout\" aria-label=\"切换图谱布局方向，当前从左到右\" aria-pressed=\"false\"><i data-graph-icon=\"rows\"></i><span>从左到右</span></button>
    </div>
    <p id=\"graph-match-status\" role=\"status\" aria-live=\"polite\">匹配 00 个节点</p>
  </header>
  <section class=\"museum-graph-workspace\" aria-label=\"知识关系画布\">
    <div class=\"graph-canvas-stage\">
      <div id=\"graph-canvas\" tabindex=\"-1\"></div>
      <aside class=\"graph-relation-legend\" aria-label=\"关系类型图例\">
        <strong>关系类型</strong><ul id=\"graph-relation-legend\"></ul>
      </aside>
      <svg id=\"graph-minimap\" aria-label=\"图谱缩略导航\" role=\"button\" tabindex=\"0\"></svg>
    </div>
    <div id=\"graph-zero-notice\" hidden>
      <strong>尚未形成知识连线</strong>
      <span>在笔记中加入 <code>[[wiki:笔记ID][标题]]</code> 即可创建关系。</span>
      <button type=\"button\" id=\"graph-zero-copy\">复制第一条 Wiki 链接</button>
    </div>
    <section id=\"graph-triage-panel\" class=\"graph-triage-panel\" data-legacy-hook=\"graph-isolated-fallback\" hidden aria-label=\"待连接笔记\">
      <header><div><strong>待连接笔记</strong><span>按主题审核并补充真实链接，不生成推测关系。</span></div><b id=\"graph-isolated-count\">00</b></header>
      <div id=\"graph-isolated-list\" class=\"graph-isolated-list\"></div>
      <p id=\"graph-copy-status\" class=\"sr-only\" role=\"status\" aria-live=\"polite\"></p>
    </section>
    <div id=\"graph-tooltip\" role=\"status\" aria-live=\"polite\">
      <strong id=\"tt-title\"></strong><span id=\"tt-meta\"></span>
    </div>
    <div class=\"graph-workspace-footer\" aria-live=\"polite\">
      <div id=\"graph-selection-prompt\">
        <strong>从一条真实关系开始阅读</strong>
        <span>单击节点在原地理解，双击或 Enter 打开文章。</span>
      </div>
      <article id=\"graph-selected-detail\" hidden>
        <header class=\"graph-inspector-header\">
          <div><span id=\"graph-selected-meta\">等待选择</span><h2 id=\"graph-selected-title\">尚未选择笔记</h2><div id=\"graph-selected-tags\"></div></div>
          <button type=\"button\" id=\"btn-clear-selection\" aria-label=\"关闭笔记详情\">关闭</button>
        </header>
        <div class=\"graph-inspector-grid\">
          <section><h3>内容摘要</h3><p id=\"graph-selected-description\"></p><dl id=\"graph-selected-facts\"></dl></section>
          <section><h3>关系脉络</h3><div id=\"graph-neighbours\"></div></section>
        </div>
        <nav class=\"graph-inspector-actions\" aria-label=\"连续阅读操作\">
          <button type=\"button\" id=\"graph-previous\">上一篇</button>
          <button type=\"button\" id=\"graph-next\">下一篇</button>
          <a id=\"graph-open-link\" href=\"index.html\">打开笔记</a>
          <a id=\"graph-related-link\" href=\"related.html\" hidden>关联阅读</a>
          <a id=\"graph-timeline-link\" href=\"timeline.html\">时间线</a>
        </nav>
      </article>
      <ul id=\"graph-legend\" aria-label=\"主题图例\"></ul>
    </div>
  </section>
</main>
<script type=\"application/json\" id=\"graph-data\">%s</script>
<script>
(function(){
'use strict';
var raw=JSON.parse(document.getElementById('graph-data').textContent);
var nodes=(raw.nodes||[]).map(function(node){return Object.assign({},node);});
var links=(raw.links||[]).map(function(link){return Object.assign({},link);});
var meta=raw.meta||{};
var palette=%s;
var search=document.getElementById('org-museum-global-search');
var canvas=document.getElementById('graph-canvas');
var zeroNotice=document.getElementById('graph-zero-notice');
var triagePanel=document.getElementById('graph-triage-panel');
var isolatedFallback=triagePanel;
var selectedDetail=document.getElementById('graph-selected-detail');
var selectionPrompt=document.getElementById('graph-selection-prompt');
var matchStatus=document.getElementById('graph-match-status');
var clearSelectionButton=document.getElementById('btn-clear-selection');
var graphRelatedLink=document.getElementById('graph-related-link');
var graphNeighbours=document.getElementById('graph-neighbours');
var graphOpenLink=document.getElementById('graph-open-link');
var graphTimelineLink=document.getElementById('graph-timeline-link');
var graphPrevious=document.getElementById('graph-previous');
var graphNext=document.getElementById('graph-next');
var graphSelectedMeta=document.getElementById('graph-selected-meta');
var graphSelectedTitle=document.getElementById('graph-selected-title');
var graphSelectedTags=document.getElementById('graph-selected-tags');
var graphSelectedDescription=document.getElementById('graph-selected-description');
var graphSelectedFacts=document.getElementById('graph-selected-facts');
var workspaceFooter=document.querySelector('.graph-workspace-footer');
var footerAnchor=document.createComment('graph-inspector-anchor');
if(workspaceFooter&&workspaceFooter.parentNode)workspaceFooter.parentNode.insertBefore(footerAnchor,workspaceFooter);
var relationLegend=document.getElementById('graph-relation-legend');
var minimap=document.getElementById('graph-minimap');
var cats=Array.from(new Set(nodes.map(function(node){return node.group||'未分类';}))).sort();
var relationTypes=Array.from(new Set(links.map(function(edge){return edge.type||'显式链接';}))).sort();
var graphParams=new URLSearchParams(location.search);
var focusId=graphParams.get('focus')||'';
var requestedCategory=graphParams.get('category')||'*';
var requestedView=graphParams.get('view')||'relations';
var focusIsValid=!focusId||nodes.some(function(node){return node.id===focusId;});
var categoryIsValid=requestedCategory==='*'||cats.indexOf(requestedCategory)>=0;
var viewIsValid=requestedView==='relations'||requestedView==='triage';
var graphUrlNeedsCleanup=!focusIsValid||!categoryIsValid||!viewIsValid;
var state={query:'',category:'*',view:viewIsValid?requestedView:'relations',selectedId:
  focusIsValid?focusId:''};
state.query=(graphParams.get('q')||'').trim().toLowerCase();
state.category=categoryIsValid?requestedCategory:'*';
var simulation=null;
var frozen=false;
var graphReady=false;
var isZeroLinkGraph=links.length===0;
var isolatedNodes=nodes.filter(function(node){return (node.degree||0)===0;});
var canvasNodes=isZeroLinkGraph?[]:nodes.filter(function(node){return (node.degree||0)>0;});
var compactRelationMode=canvasNodes.length>0&&canvasNodes.length<=4;
var hasIsolatedNodes=isolatedNodes.length>0;
if(focusId&&state.view==='relations'&&isolatedNodes.some(function(node){return node.id===focusId;}))state.view='triage';
var charge=Number(meta.charge);
var alphaDecay=Number(meta['alpha-decay']);
var tickLimit=meta['tick-limit']===false?0:Number(meta['tick-limit']);
var preTicks=meta['pre-ticks']===false?0:Number(meta['pre-ticks']);
var tickCount=0;
var motionQuery=window.matchMedia('(prefers-reduced-motion: reduce)');
var mobileGraphMedia=window.matchMedia('(max-width:820px)');
var reduceMotion=motionQuery.matches;
if(selectedDetail)selectedDetail.hidden=true;
if(!Number.isFinite(charge))charge=-240;
if(!Number.isFinite(alphaDecay)||alphaDecay<=0)alphaDecay=0.0228;
if(!Number.isFinite(tickLimit)||tickLimit<0)tickLimit=0;
if(!Number.isFinite(preTicks)||preTicks<0)preTicks=0;

function count(value){return String(value).padStart(2,'0');}
function categoryLabel(value){return value==='AIL'?'AI':value==='Sql'?'SQL':value;}
if(search)search.value=state.query;
function writeGraphUrl(mode){
  var url=new URL(location.href);
  ['q','category','focus','view'].forEach(function(key){url.searchParams.delete(key);});
  if(state.query)url.searchParams.set('q',state.query);
  if(state.category!=='*')url.searchParams.set('category',state.category);
  if(state.selectedId)url.searchParams.set('focus',state.selectedId);
  if(state.view==='triage')url.searchParams.set('view','triage');
  history[mode==='push'?'pushState':'replaceState'](
    {},'',url.pathname+url.search+url.hash);
}
if(graphUrlNeedsCleanup)writeGraphUrl('replace');
document.getElementById('stat-nodes').textContent=count(nodes.length);
document.getElementById('stat-links').textContent=count(links.length);
document.getElementById('stat-cats').textContent=count(cats.length);
document.getElementById('graph-heading-count').textContent='/ '+count(nodes.length);
document.getElementById('graph-relation-count').textContent=count(canvasNodes.length);
document.getElementById('graph-triage-count').textContent=count(isolatedNodes.length);
if(zeroNotice)zeroNotice.hidden=!isZeroLinkGraph;
if(canvas)canvas.hidden=false;
document.body.classList.toggle('graph-zero-mode',isZeroLinkGraph);
document.body.classList.toggle('graph-compact-relations',compactRelationMode);
document.body.classList.toggle('graph-single-relation-type',relationTypes.length<=1);
var viewControls=document.querySelector('.graph-view-controls');
if(viewControls)viewControls.hidden=false;
var filterSummary=document.querySelector('.graph-filter-summary');
function syncFilterSummary(event){
  if(event.matches&&filterSummary)filterSummary.open=false;
  var selected=nodes.find(function(node){return node.id===state.selectedId;});
  requestAnimationFrame(function(){placeGraphInspector(selected);});
}
syncFilterSummary(mobileGraphMedia);
if(mobileGraphMedia.addEventListener)
  mobileGraphMedia.addEventListener('change',syncFilterSummary);
else if(mobileGraphMedia.addListener)
  mobileGraphMedia.addListener(syncFilterSummary);

function color(group){
  var index=Math.max(0,cats.indexOf(group));
  return window.orgMuseumCategoryColor?window.orgMuseumCategoryColor(group):
    palette[index%%palette.length]||'var(--museum-ink-muted)';
}
function setGraphView(value,pushHistory){
  state.view=value==='triage'?'triage':'relations';
  if(state.view==='triage'&&state.selectedId)clearSelection(false,true);
  document.body.classList.toggle('graph-triage-mode',state.view==='triage');
  document.querySelectorAll('[data-graph-view]').forEach(function(button){
    var active=button.dataset.graphView===state.view;
    button.classList.toggle('is-active',active);
    button.setAttribute('aria-pressed',active?'true':'false');
  });
  if(triagePanel)triagePanel.hidden=state.view!=='triage';
  if(viewControls)viewControls.hidden=state.view==='triage';
  if(workspaceFooter)workspaceFooter.hidden=state.view==='triage';
  if(state.view==='triage')renderFallbackList();
  else placeGraphInspector(nodes.find(function(node){return node.id===state.selectedId;}));
  updateMatchStatus();
  if(pushHistory)writeGraphUrl('push');
}
function restoreGraphInspector(){
  if(workspaceFooter&&footerAnchor.parentNode)
    footerAnchor.parentNode.insertBefore(workspaceFooter,footerAnchor.nextSibling);
}
function placeGraphInspector(node){
  if(!workspaceFooter)return;
  document.querySelectorAll('#graph-isolated-list article').forEach(function(entry){
    var active=!!node&&entry.dataset.nodeId===node.id;
    entry.classList.toggle('is-selected',active);
    var button=entry.querySelector('[data-graph-select]');
    if(button)button.setAttribute('aria-pressed',active?'true':'false');
  });
  if(innerWidth<=820&&state.view==='triage'&&node){
    var row=Array.from(document.querySelectorAll('#graph-isolated-list article')).find(function(entry){return entry.dataset.nodeId===node.id;});
    if(row){row.insertAdjacentElement('afterend',workspaceFooter);return;}
  }
  restoreGraphInspector();
}
var relationPalette=['var(--museum-relation-1)','var(--museum-relation-2)',
  'var(--museum-relation-3)','var(--museum-relation-4)'];
var relationDashes=['','7 4','3 4'];
function stableHash(value){
  var hash=2166136261;
  Array.from(value||'').forEach(function(char){hash^=char.codePointAt(0);hash=Math.imul(hash,16777619);});
  return hash>>>0;
}
function relationStyle(label){
  if(!label||label==='显式链接')return {color:'var(--museum-relation-primary)',dash:''};
  var hash=stableHash(label||'显式链接');
  return {color:relationPalette[hash%%relationPalette.length],
    dash:relationDashes[Math.floor(hash/relationPalette.length)%%relationDashes.length]};
}
function themed(href){return window.orgMuseumThemeUrl?window.orgMuseumThemeUrl(href):href;}
function formatDate(seconds){
  if(!Number.isFinite(Number(seconds)))return '未记录';
  return new Date(Number(seconds)*1000).toLocaleDateString('zh-CN',{year:'numeric',month:'2-digit',day:'2-digit'});
}
function matches(node){
  var catOk=state.category==='*'||node.group===state.category;
  var hay=[node.name,node.group].concat(node.tags||[]).join(' ').toLowerCase();
  return catOk&&(!state.query||hay.indexOf(state.query)>=0);
}
function visibleModeNodes(){
  var source=state.view==='triage'?(isZeroLinkGraph?nodes:isolatedNodes):canvasNodes;
  return source.filter(matches);
}
var graphNotice='';
function updateMatchStatus(){
  var visible=visibleModeNodes();
  var label=state.view==='triage'?' 个待连接节点':' 个匹配关系节点';
  if(matchStatus)matchStatus.textContent=visible.length+label+(graphNotice?' · '+graphNotice:'');
}
function announceGraph(message){graphNotice=message;updateMatchStatus();}

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
function renderFallbackList(){
  var listRoot=document.getElementById('graph-isolated-list');
  if(workspaceFooter&&listRoot&&listRoot.contains(workspaceFooter))restoreGraphInspector();
  var candidates=(isZeroLinkGraph||typeof d3==='undefined')?nodes:isolatedNodes;
  var visible=candidates.filter(matches);
  if(listRoot){
    listRoot.textContent='';
    cats.forEach(function(cat){
      var groupNodes=visible.filter(function(node){return (node.group||'未分类')===cat;});
      if(!groupNodes.length)return;
      var section=document.createElement('section');section.className='graph-isolated-group';
      var heading=document.createElement('h3');heading.textContent=categoryLabel(cat)+' · '+count(groupNodes.length);
      var grid=document.createElement('div');grid.className='graph-isolated-grid';
      groupNodes.forEach(function(node){
        var row=document.createElement('article');row.dataset.status=node.status||'published';row.dataset.nodeId=node.id;
        var link=document.createElement('a');link.href=themed(node.url||'index.html');link.textContent=node.name;
        var meta=document.createElement('small');
        meta.textContent=categoryLabel(node.group||'未分类')+' · '+(node.status==='draft'?'草稿':'已发布')+' · 更新 '+formatDate(node.modified);
        var actions=document.createElement('div');actions.className='graph-isolated-actions';
        var summary=document.createElement('p');summary.className='graph-isolated-summary';summary.hidden=true;
        summary.textContent=(node.description||'').trim()||'这篇笔记尚未提供摘要。';
        var select=document.createElement('button');select.type='button';select.textContent='查看摘要';select.dataset.graphSelect=node.id;
        select.setAttribute('aria-expanded','false');
        select.addEventListener('click',function(){
          summary.hidden=!summary.hidden;select.setAttribute('aria-expanded',summary.hidden?'false':'true');
          select.textContent=summary.hidden?'查看摘要':'收起摘要';
        });
        var copy=document.createElement('button');copy.type='button';copy.textContent='复制链接';
        copy.addEventListener('click',function(){
          copyWikiLink('[[wiki:'+node.id+']['+node.name+']]',copy);
        });
        actions.appendChild(select);actions.appendChild(copy);
        if(window.orgMuseumCuration&&window.orgMuseumCuration.available){
          var connect=document.createElement('button');connect.type='button';connect.textContent='建立关系';
          connect.className='graph-curation-action';connect.addEventListener('click',function(){
            window.orgMuseumCuration.openRelation({sourceId:node.id,sourceTitle:node.name,
              targets:nodes.map(function(candidate){return {id:candidate.id,title:candidate.name,
                category:categoryLabel(candidate.group||'未分类')};})});
          });actions.appendChild(connect);
        }
        row.appendChild(link);row.appendChild(meta);row.appendChild(summary);row.appendChild(actions);grid.appendChild(row);
      });
      section.appendChild(heading);section.appendChild(grid);listRoot.appendChild(section);
    });
  }
  var total=document.getElementById('graph-isolated-count');
  if(total)total.textContent=count(visible.length);
  placeGraphInspector(nodes.find(function(node){return node.id===state.selectedId;}));
}
function syncGraphCategoryControls(){
  var filterLabel=document.getElementById('graph-filter-label');
  if(filterLabel)filterLabel.textContent=state.category==='*'?'全部主题':categoryLabel(state.category);
  document.querySelectorAll('[data-graph-category]').forEach(function(entry){
    var active=entry.dataset.graphCategory===state.category;
    entry.classList.toggle('is-active',active);
    entry.setAttribute('aria-pressed',active?'true':'false');
  });
}
function setCategory(value){
  state.category=value||'*';syncGraphCategoryControls();
  var selected=nodes.find(function(node){return node.id===state.selectedId;});
  if(selected&&!matches(selected)){clearSelection(false,true);graphNotice='筛选后已清除原选择';}else graphNotice='';
  writeGraphUrl('push');
  if(graphReady)applyFilter();
  if(hasIsolatedNodes||!graphReady)renderFallbackList();
}
function renderFilters(){
  var root=document.getElementById('graph-category-filters');
  var items=[{name:'*',label:'全部',count:nodes.length}].concat(
    cats.map(function(cat){return {
      name:cat,label:categoryLabel(cat),count:nodes.filter(function(node){return node.group===cat;}).length
    };})
  );
  items.forEach(function(item){
    var button=document.createElement('button');
    button.type='button';button.dataset.graphCategory=item.name;
    button.innerHTML='<span></span><b></b>';
    button.querySelector('span').textContent=item.label;
    button.querySelector('b').textContent=count(item.count);
    button.setAttribute('aria-pressed',item.name===state.category?'true':'false');
    if(item.name===state.category)button.classList.add('is-active');
    button.addEventListener('click',function(){setCategory(item.name);});
    root.appendChild(button);
  });
}
function renderLegend(){
  var root=document.getElementById('graph-legend');
  root.textContent='';
  cats.forEach(function(cat){
    var item=document.createElement('li');
    var dot=document.createElement('i');dot.style.background=color(cat);
    item.appendChild(dot);item.appendChild(document.createTextNode(categoryLabel(cat)));
    root.appendChild(item);
  });
  if(relationLegend){
    relationLegend.textContent='';
    (relationTypes.length?relationTypes:['显式链接']).forEach(function(label){
      var item=document.createElement('li');var line=document.createElement('i');
      var style=relationStyle(label);line.style.borderTopColor=style.color;
      line.style.borderTopStyle=style.dash?'dashed':'solid';
      item.appendChild(line);item.appendChild(document.createTextNode(label));
      relationLegend.appendChild(item);
    });
  }
}
function nodeHref(node){return node.url||'index.html';}
function openNode(node){
  var href=nodeHref(node);
  location.href=window.orgMuseumThemeUrl?window.orgMuseumThemeUrl(href):href;
}
function renderNeighbourList(node){
  if(!graphNeighbours)return;
  graphNeighbours.textContent='';graphNeighbours.hidden=false;
  [['出链 · 当前 → 目标',node.linksTo||[],true],
   ['入链 · 来源 → 当前',node.linkedFrom||[],false]]
    .forEach(function(group){
      var section=document.createElement('section');
      var heading=document.createElement('strong');heading.textContent=group[0];
      var list=document.createElement('ul');
      if(!group[1].length){
        var empty=document.createElement('li');empty.textContent='无';list.appendChild(empty);
      }
      group[1].forEach(function(id){
        var neighbour=nodes.find(function(item){return item.id===id;});
        if(!neighbour)return;
        var item=document.createElement('li');var choose=document.createElement('button');
        var edge=links.find(function(candidate){
          var source=candidate.source.id||candidate.source,target=candidate.target.id||candidate.target;
          if(candidate.bidirectional)
            return (source===node.id&&target===id)||(source===id&&target===node.id);
          return group[2]?(source===node.id&&target===id):
            (source===id&&target===node.id);
        });
        choose.type='button';choose.textContent=neighbour.name;
        choose.addEventListener('click',function(){selectNode(neighbour,true);});
        var badge=document.createElement('span');badge.className='graph-relation-badge';
        badge.textContent=edge&&edge.type?edge.type:'显式链接';
        item.appendChild(choose);item.appendChild(badge);list.appendChild(item);
      });
      section.appendChild(heading);section.appendChild(list);graphNeighbours.appendChild(section);
    });
}
function appendFact(term,value){
  var dt=document.createElement('dt'),dd=document.createElement('dd');
  dt.textContent=term;dd.textContent=value;graphSelectedFacts.appendChild(dt);graphSelectedFacts.appendChild(dd);
}
function readingOrder(){
  return nodes.filter(matches).slice().sort(function(a,b){
    return Number(a.created||0)-Number(b.created||0)||a.name.localeCompare(b.name,'zh-CN');
  });
}
function selectNode(node,pushHistory){
  if(!node)return;
  if(workspaceFooter)workspaceFooter.hidden=false;
  var changed=state.selectedId!==node.id;
  state.selectedId=node.id;
  activeNeighborhood=(node.degree||0)>0?neighborhood(node):null;applyFilter();
  if(nodeSelection)positionNodeLabels();
  if(nodeSelection){
    nodeSelection.classed('is-selected',function(entry){return entry.id===node.id;});
    nodeSelection.select('.graph-node-dot').classed('is-selected',function(entry){return entry.id===node.id;});
    nodeSelection.attr('aria-pressed',function(entry){return entry.id===node.id?'true':'false';});
  }
  if(selectedDetail)selectedDetail.hidden=false;
  if(selectionPrompt)selectionPrompt.hidden=true;
  placeGraphInspector(node);
  graphSelectedMeta.textContent=String(nodes.indexOf(node)+1).padStart(2,'0')+
    ' / '+categoryLabel(node.group||'未分类')+' / '+count(node.degree||0)+' 条关系';
  graphSelectedTitle.textContent=node.name||'未命名';
  graphSelectedDescription.textContent=(node.description||'').trim()||'这篇笔记尚未提供摘要，可打开正文继续阅读。';
  graphSelectedTags.textContent='';
  (node.tags||[]).forEach(function(tag){var chip=document.createElement('span');chip.textContent='#'+tag;graphSelectedTags.appendChild(chip);});
  graphSelectedFacts.textContent='';
  appendFact('创建',formatDate(node.created));appendFact('更新',formatDate(node.modified));
  appendFact('状态',node.status==='draft'?'草稿':'已发布');
  graphOpenLink.href=themed(nodeHref(node));
  graphTimelineLink.href=themed('timeline.html?focus='+encodeURIComponent(node.id));
  renderNeighbourList(node);
  var next=(node.linksTo||[])[0],previous=(node.linkedFrom||[])[0];
  if(graphRelatedLink){
    graphRelatedLink.hidden=!(next||previous);
    if(next)graphRelatedLink.href=themed('related.html?source='+encodeURIComponent(node.id)+'&target='+encodeURIComponent(next));
    else if(previous)graphRelatedLink.href=themed('related.html?source='+encodeURIComponent(previous)+'&target='+encodeURIComponent(node.id));
  }
  var order=readingOrder(),at=order.findIndex(function(entry){return entry.id===node.id;});
  graphPrevious.disabled=at<=0;graphNext.disabled=at<0||at>=order.length-1;
  graphPrevious.dataset.target=at>0?order[at-1].id:'';
  graphNext.dataset.target=at>=0&&at<order.length-1?order[at+1].id:'';
  if(pushHistory&&changed)writeGraphUrl('push');else writeGraphUrl('replace');
  if(innerWidth<=820&&changed)requestAnimationFrame(function(){
    var top=selectedDetail.getBoundingClientRect().top,bottom=selectedDetail.getBoundingClientRect().bottom;
    if(top<118||bottom>innerHeight)selectedDetail.scrollIntoView({block:'nearest',behavior:reduceMotion?'auto':'smooth'});
  });
}
function previewNode(node){
  if(!node)return;
}
function clearPreview(){
  return;
}
function clearSelection(pushHistory,skipUrl){
  var previousId=state.selectedId,returnToObject=selectedDetail&&selectedDetail.contains(document.activeElement);
  state.selectedId='';activeNeighborhood=null;
  restoreGraphInspector();
  if(nodeSelection)positionNodeLabels();
  if(nodeSelection){
    nodeSelection.classed('is-selected',false);
    nodeSelection.select('.graph-node-dot').classed('is-selected',false);
    nodeSelection.attr('aria-pressed','false');
  }
  if(selectedDetail)selectedDetail.hidden=true;
  if(selectionPrompt)selectionPrompt.hidden=state.view==='triage';
  if(tooltip){tooltip.classList.remove('is-visible');tooltip.style.left='';tooltip.style.top='';}
  var active=document.activeElement;
  if(active&&canvas&&(canvas.contains(active)||(selectedDetail&&selectedDetail.contains(active)))){
    try{canvas.focus({preventScroll:true});}catch(_focusError){canvas.focus();}
  }
  if(graphReady)applyFilter();
  if(!skipUrl)writeGraphUrl(pushHistory?'push':'replace');
  if(returnToObject&&previousId)requestAnimationFrame(function(){
    var target=document.querySelector('[data-graph-select='+CSS.escape(previousId)+']');
    if(!target&&nodeSelection)nodeSelection.each(function(node){if(node.id===previousId&&matches(node))target=this;});
    if(target&&target.getClientRects().length)target.focus({preventScroll:true});
  });
}
function navigateReading(button){
  var node=nodes.find(function(entry){return entry.id===button.dataset.target;});
  if(node)selectNode(node,true);
}
if(clearSelectionButton)clearSelectionButton.addEventListener('click',function(){clearSelection(true);});
if(graphPrevious)graphPrevious.addEventListener('click',function(){navigateReading(graphPrevious);});
if(graphNext)graphNext.addEventListener('click',function(){navigateReading(graphNext);});

renderFilters();renderLegend();
if(hasIsolatedNodes)renderFallbackList();
document.querySelectorAll('[data-graph-view]').forEach(function(button){
  button.addEventListener('click',function(){setGraphView(button.dataset.graphView,true);});
});
if(isZeroLinkGraph)state.view='triage';
setGraphView(state.view,false);
document.addEventListener('keydown',function(event){
  if(event.key==='Escape'&&state.selectedId){clearSelection(true);return;}
  if(event.key==='/'&&!event.metaKey&&!event.ctrlKey&&!event.altKey&&
     !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)){
    event.preventDefault();if(search)search.focus();
  }
});
if(typeof d3==='undefined'||!canvas){
  if(canvas)canvas.innerHTML='<p class=\"museum-empty-copy\">图谱运行资源不可用，仍可通过首页索引打开笔记。</p>';
  if(triagePanel)triagePanel.hidden=false;
  if(zeroNotice)zeroNotice.hidden=true;
  if(viewControls)viewControls.hidden=true;
  renderFallbackList();
  if(search)search.addEventListener('input',function(){
    state.query=search.value.trim().toLowerCase();writeGraphUrl();renderFallbackList();
  });
  return;
}
if(isZeroLinkGraph){
  renderFallbackList();
  setGraphView('triage',false);
  var zeroCopy=document.getElementById('graph-zero-copy');
  if(zeroCopy&&nodes[0])zeroCopy.addEventListener('click',function(){
    copyWikiLink('[[wiki:'+nodes[0].id+']['+nodes[0].name+']]',zeroCopy);
  });
}
var width=canvas.clientWidth||900;
var height=canvas.clientHeight||760;
var svg=d3.select(canvas).append('svg')
  .attr('viewBox','0 0 '+width+' '+height)
  .attr('role','group')
  .attr('aria-label','Org Museum 知识图谱');
var layer=svg.append('g');
var defs=svg.append('defs');
defs.append('marker').attr('id','graph-arrow').attr('viewBox','0 -5 10 10')
  .attr('refX',18).attr('refY',0).attr('markerWidth',6).attr('markerHeight',6)
  .attr('orient','auto-start-reverse').append('path').attr('d','M0,-5L10,0L0,5').attr('fill','context-stroke');
var zoomScale=1;
var zoom=d3.zoom().scaleExtent([0.35,5]).on('zoom',function(event){
  zoomScale=event.transform.k;
  layer.attr('transform',event.transform);
  document.getElementById('btn-zoom-in').disabled=zoomScale>=4.999;
  document.getElementById('btn-zoom-out').disabled=zoomScale<=0.351;
  layer.classed('graph-labels-dense',event.transform.k>=0.9);
  // [UI-03] Keep graph-node pointer targets at least as large as the 44px UI baseline.
  if(nodeSelection)nodeSelection.select('.graph-node-hit-target').attr('r',26/zoomScale);
});
svg.call(zoom);
zoom.on('end.feedback',function(){announceGraph('缩放 '+Math.round(zoomScale*100)+'%%');});
function zoomBy(factor){
  var action=function(){svg.call(zoom.scaleBy,factor);};
  if(reduceMotion)action();else svg.transition().duration(180).call(zoom.scaleBy,factor);
}
document.getElementById('btn-zoom-in').addEventListener('click',function(){zoomBy(1.25);});
document.getElementById('btn-zoom-out').addEventListener('click',function(){zoomBy(0.8);});
layer.classed('graph-labels-dense',true);
var linkSelection=layer.append('g').attr('class','graph-links')
  .selectAll('path').data(links).enter().append('path')
  .attr('marker-end','url(#graph-arrow)')
  .attr('marker-start',function(edge){return edge.bidirectional?'url(#graph-arrow)':null;})
  .attr('stroke',function(edge){return relationStyle(edge.type).color;})
  .attr('stroke-dasharray',function(edge){return relationStyle(edge.type).dash||null;});
var linkLabelSelection=layer.append('g').attr('class','graph-link-labels')
  .selectAll('text').data(links).enter().append('text')
  .text(function(edge){return edge.type||'显式链接';});
var nodeSelection=layer.append('g').attr('class','graph-nodes')
  .selectAll('g').data(canvasNodes).enter().append('g')
  .classed('is-isolated',function(node){return (node.degree||0)===0;})
  .attr('tabindex',0).attr('role','button').attr('aria-pressed','false')
  .attr('aria-label',function(node){
    return (node.name||'未命名')+'，'+(node.group||'未分类')+'，'+
      count(node.degree||0)+' 条关系'+(node.status==='draft'?'，草稿':'')+
      '，单击或 Space 选择，双击或 Enter 打开笔记';
  });
graphReady=true;
// [UI-03] A 23px radius survives SVG scaling while preserving a 44px touch target.
nodeSelection.append('circle')
  .attr('class','graph-node-hit-target')
  .attr('r',26);
nodeSelection.append('circle')
  .attr('class',function(node){return 'graph-node-dot'+(node.status==='draft'?' is-draft':'');})
  .attr('r',function(node){return 9+Math.min(6,Math.sqrt(node.degree||0)*2.5);})
  .attr('fill','var(--museum-node-fill)');
nodeSelection.append('circle')
  .attr('class','graph-node-category-dot')
  .attr('cx',11).attr('cy',11).attr('r',4)
  .attr('fill',function(node){return color(node.group);});
function nodeLabelText(node){
  var name=node.name||'未命名';
  var limit=width<600?12:22;
  return name.length>limit?name.slice(0,limit)+'…':name;
}
nodeSelection.append('text').attr('x',14).attr('y',4)
  .attr('class','graph-node-title')
  .text(nodeLabelText);
nodeSelection.append('text').attr('x',14).attr('y',23)
  .attr('class','graph-node-category')
  .text(function(node){return categoryLabel(node.group||'未分类');});
function measureNodeLabels(){
  nodeSelection.select('text').text(nodeLabelText);
  nodeSelection.each(function(node){
    var label=this.querySelector('text');
    node.labelWidth=label?Math.ceil(label.getComputedTextLength()):0;
  });
}
measureNodeLabels();

function positionNodeLabels(){
  nodeSelection.select('.graph-node-title')
    .attr('x',function(node){return width<600?18:(node.x>width/2?-14:14);})
    .attr('y',function(node){
      if(width<600)return 4;
      if(state.selectedId===node.id)return -16;
      return 4;
    })
    .attr('text-anchor',function(node){return width<600?'start':(node.x>width/2?'end':'start');});
  nodeSelection.select('.graph-node-category')
    .attr('x',function(node){return width<600?18:(node.x>width/2?-14:14);})
    .attr('y',function(node){return width<600?22:22;})
    .attr('text-anchor',function(node){return width<600?'start':(node.x>width/2?'end':'start');});
}
function constrainNode(node){
  var labelHalf=width<600?0:(node.labelWidth||0)/2;
  var minX=width<600?32:Math.max(18,labelHalf+6);
  var maxX=width<600?Math.max(minX,width-(node.labelWidth||0)-26):Math.max(minX,width-minX);
  var minY=18,maxY=Math.max(minY,height-(width<600?30:18));
  node.x=Math.max(minX,Math.min(maxX,node.x));
  node.y=Math.max(minY,Math.min(maxY,node.y));
}
function renderTick(){
  canvasNodes.forEach(constrainNode);
  function edgePoints(edge){return {source:edge.source.id?edge.source:nodes.find(function(node){return node.id===edge.source;}),target:edge.target.id?edge.target:nodes.find(function(node){return node.id===edge.target;})};}
  function edgeOffset(edge,points){
    var reverse=links.some(function(other){var s=other.source.id||other.source,t=other.target.id||other.target;return s===points.target.id&&t===points.source.id&&other.type!==edge.type;});
    return reverse?(points.source.id<points.target.id?18:-18):0;
  }
  function curve(edge){
    var points=edgePoints(edge),dx=points.target.x-points.source.x,dy=points.target.y-points.source.y;
    var length=Math.max(1,Math.sqrt(dx*dx+dy*dy)),offset=edgeOffset(edge,points);
    var mx=(points.source.x+points.target.x)/2-dy/length*offset;
    var my=(points.source.y+points.target.y)/2+dx/length*offset;
    return 'M'+points.source.x+','+points.source.y+' Q'+mx+','+my+' '+points.target.x+','+points.target.y;
  }
  linkSelection
    .attr('d',curve);
  linkLabelSelection
    .attr('x',function(edge){var p=edgePoints(edge);return (p.source.x+p.target.x)/2;})
    .attr('y',function(edge){var p=edgePoints(edge);return (p.source.y+p.target.y)/2+(width<600?-6:-10)+edgeOffset(edge,p);});
  nodeSelection.attr('transform',function(node){return 'translate('+node.x+','+node.y+')';});
  positionNodeLabels();
  renderMinimap();
}
function renderMinimap(){
  if(!minimap||innerWidth<1200||canvasNodes.length<8){if(minimap)minimap.hidden=true;return;}
  minimap.hidden=false;
  var mini=d3.select(minimap),mw=118,mh=76,pad=8;
  mini.attr('viewBox','0 0 '+mw+' '+mh);mini.selectAll('*').remove();
  var xs=canvasNodes.map(function(node){return node.x||0;}),ys=canvasNodes.map(function(node){return node.y||0;});
  var x=d3.scaleLinear().domain([Math.min.apply(null,xs)-20,Math.max.apply(null,xs)+20]).range([pad,mw-pad]);
  var y=d3.scaleLinear().domain([Math.min.apply(null,ys)-20,Math.max.apply(null,ys)+20]).range([pad,mh-pad]);
  mini.append('g').selectAll('line').data(links).enter().append('line')
    .attr('x1',function(edge){return x((edge.source.x||0));}).attr('y1',function(edge){return y((edge.source.y||0));})
    .attr('x2',function(edge){return x((edge.target.x||0));}).attr('y2',function(edge){return y((edge.target.y||0));});
  mini.append('g').selectAll('circle').data(canvasNodes).enter().append('circle')
    .attr('cx',function(node){return x(node.x||0);}).attr('cy',function(node){return y(node.y||0);})
    .attr('r',function(node){return state.selectedId===node.id?4:2.5;})
    .attr('fill',function(node){return color(node.group);});
}
function applyAutoLayout(){
  if(!compactRelationMode)return false;
  var ordered=canvasNodes.slice();
  if(width<600){
    ordered.forEach(function(node,index){
      var ratio=ordered.length===1?0.5:index/(ordered.length-1);
      node.x=Math.min(62,width*.18);
      node.y=height*(0.14+0.72*ratio);
      node.fx=node.x;node.fy=node.y;
    });
    return true;
  }
  var span=Math.min(width*0.76,900),left=width/2-span/2;
  ordered.forEach(function(node,index){
    var ratio=ordered.length===1?0.5:index/(ordered.length-1);
    node.x=left+span*ratio;
    node.y=height/2+(ordered.length>2&&index%%2?42:-18);
    node.fx=node.x;node.fy=node.y;
  });
  return true;
}
function syncGraphViewport(){
  var nextWidth=canvas.clientWidth||width;
  var nextHeight=canvas.clientHeight||height;
  if(nextWidth===width&&nextHeight===height)return;
  var scaleX=width?nextWidth/width:1;
  var scaleY=height?nextHeight/height:1;
  canvasNodes.forEach(function(node){
    if(Number.isFinite(node.x))node.x*=scaleX;
    if(Number.isFinite(node.y))node.y*=scaleY;
    if(Number.isFinite(node.fx))node.fx*=scaleX;
    if(Number.isFinite(node.fy))node.fy*=scaleY;
  });
  width=nextWidth;height=nextHeight;
  svg.attr('viewBox','0 0 '+width+' '+height);
  measureNodeLabels();
  if(compactRelationMode){applyAutoLayout();renderTick();return;}
  if(simulation){
    simulation.force('center',d3.forceCenter(width/2,height/2));
    simulation.force('x',d3.forceX(width/2).strength(0.035));
    simulation.force('y',d3.forceY(height/2).strength(0.035));
    if(reduceMotion){
      simulation.alpha(.35).stop();
      for(var resizeTick=0;resizeTick<40;resizeTick+=1)simulation.tick();
      simulation.stop();
    }
  }
  renderTick();
}
simulation=d3.forceSimulation(canvasNodes)
    .force('charge',d3.forceManyBody().strength(charge))
    .force('center',d3.forceCenter(width/2,height/2))
    .force('x',d3.forceX(width/2).strength(0.035))
    .force('y',d3.forceY(height/2).strength(0.035))
    .force('collide',d3.forceCollide(links.length?58:42))
    .alphaDecay(alphaDecay)
    .stop();
if(links.length)
  simulation.force('link',d3.forceLink(links).id(function(node){return node.id;}).distance(130));
  if(!applyAutoLayout()){
    var layoutTicks=Math.max(preTicks,180);
    for(var warmTick=0;warmTick<layoutTicks;warmTick+=1)simulation.tick();
  }
  simulation.stop();frozen=true;
  renderTick();
  try{
    nodeSelection.call(d3.drag().clickDistance(4)
      .on('start',function(_event,node){node.fx=node.x;node.fy=node.y;})
      .on('drag',function(event,node){node.fx=event.x;node.fy=event.y;if(reduceMotion){node.x=event.x;node.y=event.y;renderTick();}})
      .on('drag.render',function(event,node){node.x=event.x;node.y=event.y;renderTick();})
      .on('end',function(_event,node){node.fx=node.x;node.fy=node.y;}));
  }catch(_dragError){canvas.classList.add('graph-drag-unavailable');}
try{
  if(window.ResizeObserver){
    var graphResizeObserver=new window.ResizeObserver(function(){syncGraphViewport();});
    graphResizeObserver.observe(canvas);
  }else window.addEventListener('resize',syncGraphViewport);
}catch(_resizeObserverError){window.addEventListener('resize',syncGraphViewport);}

var activeNeighborhood=null;
function neighborhood(node){
  var ids=new Set([node.id]);
  links.forEach(function(link){
    var source=link.source.id||link.source,target=link.target.id||link.target;
    if(source===node.id)ids.add(target);
    if(target===node.id)ids.add(source);
  });
  return ids;
}
function applyFilter(){
  updateMatchStatus();
  if(!nodeSelection)return;
  nodeSelection
    .classed('graph-node-neighbour',function(node){
      return !!activeNeighborhood&&activeNeighborhood.has(node.id);
    })
    .classed('is-context',function(node){
      return !!state.selectedId&&(!activeNeighborhood||!activeNeighborhood.has(node.id));
    })
    .classed('is-dimmed',function(node){return !matches(node);});
  function linkIsDimmed(link){
    var source=link.source.id?link.source:nodes.find(function(node){return node.id===link.source;});
    var target=link.target.id?link.target:nodes.find(function(node){return node.id===link.target;});
    return !source||!target||!matches(source)||!matches(target);
  }
  function linkIsFocused(link){
    var source=link.source.id||link.source,target=link.target.id||link.target;
    return !!state.selectedId&&(source===state.selectedId||target===state.selectedId);
  }
  linkSelection.classed('is-dimmed',linkIsDimmed)
    .classed('is-focused',linkIsFocused)
    .classed('is-context',function(link){return !!state.selectedId&&!linkIsFocused(link);});
  linkLabelSelection.classed('is-dimmed',linkIsDimmed)
    .classed('is-focused',linkIsFocused)
    .classed('is-context',function(link){return !!state.selectedId&&!linkIsFocused(link);});
}
var tooltip=document.getElementById('graph-tooltip');
nodeSelection
  .on('mouseenter',function(event,node){
    previewNode(node);
    document.getElementById('tt-title').textContent=node.name;
    document.getElementById('tt-meta').textContent=categoryLabel(node.group||'未分类')+' · '+count(node.degree||0)+' 条关系';
    tooltip.classList.add('is-visible');
  })
  .on('mousemove',function(event){
    tooltip.style.left=(event.clientX+16)+'px';tooltip.style.top=(event.clientY+16)+'px';
  })
  .on('mouseleave',function(){
    tooltip.classList.remove('is-visible');
    clearPreview();
  })
  .on('click',function(_event,node){selectNode(node,true);})
  .on('dblclick',function(_event,node){openNode(node);})
  .on('focus',function(_event,node){previewNode(node);})
  .on('blur',clearPreview)
  .on('keydown',function(event,node){
    if(event.key==='Enter'){event.preventDefault();openNode(node);}
    else if(event.key===' '){event.preventDefault();selectNode(node,true);}
  });
svg.on('click',function(event){if(event.target===svg.node()&&state.selectedId)clearSelection(true);});

document.getElementById('btn-reset').addEventListener('click',function(){
  if(reduceMotion)svg.call(zoom.transform,d3.zoomIdentity);
  else svg.transition().duration(180).call(zoom.transform,d3.zoomIdentity);
});
document.getElementById('btn-center').addEventListener('click',function(){
  var node=canvasNodes.find(function(entry){return entry.id===state.selectedId;});
  if(!node){document.getElementById('btn-reset').click();return;}
  var transform=d3.zoomIdentity.translate(width/2-node.x,height/2-node.y);
  if(reduceMotion)svg.call(zoom.transform,transform);else svg.transition().duration(180).call(zoom.transform,transform);
});
var linearLayout=false;
function applyLayout(){
  linearLayout=!linearLayout;
  var button=document.getElementById('btn-layout');button.setAttribute('aria-pressed',linearLayout?'true':'false');
  button.querySelector('span').textContent=linearLayout?'紧凑布局':'从左到右';
  if(!linearLayout){canvasNodes.forEach(function(node){node.fx=null;node.fy=null;});simulation.alpha(1).stop();for(var tick=0;tick<180;tick+=1)simulation.tick();renderTick();return;}
  var ordered=canvasNodes.slice().sort(function(a,b){return a.name.localeCompare(b.name,'zh-CN');});
  var columns=Math.max(2,Math.ceil(Math.sqrt(ordered.length))),rows=Math.ceil(ordered.length/columns);
  ordered.forEach(function(node,index){node.x=width*(index%%columns+.6)/columns;node.y=height*(Math.floor(index/columns)+.8)/(rows+.5);node.fx=node.x;node.fy=node.y;});
  renderTick();
}
document.getElementById('btn-layout').addEventListener('click',applyLayout);
if(minimap){
  var resetFromMinimap=function(){document.getElementById('btn-reset').click();};
  minimap.addEventListener('click',resetFromMinimap);
  minimap.addEventListener('keydown',function(event){if(event.key==='Enter'||event.key===' '){event.preventDefault();resetFromMinimap();}});
}
function syncMotionPreference(event){
  reduceMotion=event.matches;
  simulation.stop();frozen=true;
}
syncMotionPreference(motionQuery);
if(motionQuery.addEventListener)motionQuery.addEventListener('change',syncMotionPreference);
else if(motionQuery.addListener)motionQuery.addListener(syncMotionPreference);
if(search)search.addEventListener('input',function(){
  state.query=search.value.trim().toLowerCase();applyFilter();
  if(state.selectedId&&!matches(nodes.find(function(node){return node.id===state.selectedId;}))){clearSelection(false);graphNotice='筛选后已清除原选择';}else graphNotice='';
  updateMatchStatus();
  writeGraphUrl('replace');
  if(hasIsolatedNodes)renderFallbackList();
});
window.addEventListener('popstate',function(){
  var params=new URLSearchParams(location.search);
  state.query=(params.get('q')||'').trim().toLowerCase();
  var restoredCategory=params.get('category')||'*';
  state.category=restoredCategory==='*'||cats.indexOf(restoredCategory)>=0?
    restoredCategory:'*';
  state.view=params.get('view')==='triage'?'triage':'relations';
  state.selectedId=params.get('focus')||'';
  if(!nodes.some(function(node){return node.id===state.selectedId;}))state.selectedId='';
  if(search)search.value=state.query;syncGraphCategoryControls();setGraphView(state.view,false);applyFilter();
  if(hasIsolatedNodes)renderFallbackList();
  var selected=nodes.find(function(node){return node.id===state.selectedId;});
  if(selected&&matches(selected))selectNode(selected,false);else clearSelection(false);
});
applyFilter();
var initialSelectedNode=nodes.find(function(node){return node.id===state.selectedId;});
if(initialSelectedNode&&matches(initialSelectedNode))selectNode(initialSelectedNode,false);
else if(initialSelectedNode)clearSelection(false);
})();
</script>
%s
</body>
</html>"
     theme-tag
     css-href
     (if d3-src (format "<script src=\"%s\"></script>" d3-src) "")
     topbar
     (org-museum--generate-sidebar-html graph-file)
     safe-json
     (json-encode org-museum--graph-palette)
     (org-museum--script-shell))))

(defun org-museum--script-ui-core (&optional _out-file)
  "Return the main UI script block.
The shared section resolver publishes one active-heading state for the TOC,
sticky article identity and qualified reading-state persistence."
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

/* ── 2. Shared article section state ── */
function initScrollSpy(){
  var sc=document.getElementById('main-scroll');
  var tl=Array.from(document.querySelectorAll('#org-museum-right-sidebar a[href^=\"#\"]'));
  if(!tl.length)return;
  var headings=tl.map(function(link){
    return document.getElementById(link.getAttribute('href').slice(1));
  }).filter(Boolean);
  var activeId=null,sectionFrame=0,preferredId='',preferredUntil=0;
  var anchorLocked=false;
  function decodedHash(){
    var raw=location.hash.replace(/^#/,'');
    try{return decodeURIComponent(raw);}catch(_error){return raw;}
  }
  function activationLine(){
    var top=sc?sc.getBoundingClientRect().top:0;
    var height=sc?sc.clientHeight:window.innerHeight;
    return top+Math.min(120,Math.max(84,height*0.12));
  }
  function resolveActive(preferred){
    var target=preferred?document.getElementById(preferred):null;
    if(target&&headings.includes(target))return target;
    var current=null,line=activationLine();
    headings.forEach(function(heading){
      if(heading.getBoundingClientRect().top<=line)current=heading;
    });
    return current||headings[0]||null;
  }
  function publishActive(target,source){
    if(!target)return;
    var detail={id:target.id,title:target.textContent.trim(),
                level:Number(target.tagName.slice(1))||0,source:source};
    window.orgMuseumActiveHeading=detail;
    if(activeId===detail.id)return;
    activeId=detail.id;
    var activeLink=null;
    tl.forEach(function(link){
      var isActive=link.getAttribute('href')==='#'+activeId;
      link.classList.toggle('toc-active',isActive);
      if(isActive)activeLink=link;
    });
    if(activeLink)activeLink.dispatchEvent(
      new CustomEvent('museum:toc-active',{bubbles:true}));
    document.dispatchEvent(new CustomEvent('museum:active-heading',{detail:detail}));
  }
  function updateActive(source,preferred){
    publishActive(resolveActive(preferred),source);
  }
  function scheduleActive(){
    if(sectionFrame)return;
    sectionFrame=requestAnimationFrame(function(){
      sectionFrame=0;
      updateActive('scroll',anchorLocked||Date.now()<preferredUntil?preferredId:'');
    });
  }
  function unlockAnchor(){anchorLocked=false;preferredUntil=0;}
  ['wheel','touchstart','pointerdown'].forEach(function(type){
    (sc||window).addEventListener(type,unlockAnchor,{passive:true});
  });
  document.addEventListener('keydown',function(event){
    if(['ArrowUp','ArrowDown','PageUp','PageDown','Home','End',' ',
        'j','k','n','p'].includes(event.key))
      unlockAnchor();
  });
  tl.forEach(function(l){
    l.addEventListener('click',function(e){
      var tid=this.getAttribute('href').slice(1),te=document.getElementById(tid);
      if(!te)return;
      e.preventDefault();
      var iz=document.body.classList.contains('zen-mode');
      if(iz)document.body.classList.remove('zen-mode');
      preferredId=tid;preferredUntil=Date.now()+900;anchorLocked=true;
      publishActive(te,'toc');
      te.scrollIntoView({block:'start',behavior:'smooth'});
      if(iz)setTimeout(function(){document.body.classList.add('zen-mode');updZ();},800);
      history.pushState(null,null,'#'+tid);
    });
  });
  (sc||window).addEventListener('scroll',scheduleActive,{passive:true});
  window.addEventListener('hashchange',function(){
    preferredId=decodedHash();preferredUntil=Date.now()+300;anchorLocked=Boolean(preferredId);
    updateActive('hash',preferredId);
  });
  preferredId=decodedHash();preferredUntil=preferredId?Date.now()+300:0;
  anchorLocked=Boolean(preferredId);
  updateActive(preferredId?'hash':'initial',preferredId);
}

/* ── 3. Code blocks ── */
function initCodeBlocks(){
  var blocks=document.querySelectorAll('pre.src, pre.example');
  if(!blocks.length)return;
  var lispSrc=document.body.dataset.hljsLisp||'';
  var cssSrc=document.body.dataset.hljsCss||'';
  var jsSrc=document.body.dataset.hljsJs||'';
  var langMap={
    \"emacs-lisp\":\"lisp\",\"elisp\":\"lisp\",\"lisp-data\":\"lisp\",
    \"shell\":\"bash\",\"sh\":\"bash\",\"bash\":\"bash\",\"zsh\":\"bash\",
    \"js\":\"javascript\",\"ts\":\"typescript\",\"py\":\"python\",
    \"duckdb\":\"sql\",\"sqlite\":\"sql\",\"postgres\":\"sql\",\"postgresql\":\"sql\",
    \"x++\":\"axapta\",\"cmake.in\":\"cmake\",\"c++\":\"cpp\",\"h++\":\"cpp\",
    \"c#\":\"csharp\",\"cs\":\"csharp\",\"f#\":\"fsharp\",\"fs\":\"fsharp\",
    \"html.hbs\":\"handlebars\",\"html.handlebars\":\"handlebars\",
    \"obj-c++\":\"objectivec\",\"objective-c++\":\"objectivec\",\"pf.conf\":\"pf\",
    \"conf\":\"ini\",\"text\":\"plaintext\",\"example\":\"plaintext\"
  };
  var codes=[];
  var codeBlocks=[];
  function detectLang(pre){
    if(pre.classList.contains('example'))return 'plaintext';
    var m=pre.className.match(/(?:^|\\s)src-([^\\s]+)/);
    return langMap[m?m[1]:'text']||(m?m[1]:'plaintext');
  }
  function copyText(text,done,fail){
    if(navigator.clipboard&&navigator.clipboard.writeText){
      navigator.clipboard.writeText(text).then(done,function(){fallback();});
    }else{fallback();}
    function fallback(){
      var ta=document.createElement('textarea');
      ta.value=text;ta.setAttribute('readonly','');
      ta.style.position='fixed';ta.style.left='-9999px';
      document.body.appendChild(ta);ta.select();
      var copied=false;
      try{copied=document.execCommand('copy')===true;}catch(e){copied=false;}
      document.body.removeChild(ta);(copied?done:fail)();
    }
  }
  blocks.forEach(function(pre){
    if(pre.dataset.orgMuseumCodeReady==='1')return;
    pre.dataset.orgMuseumCodeReady='1';
    pre.classList.add('org-museum-code-block');
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
    codeBlocks.push(pre);
    if(lang!=='plaintext')codes.push(code);
    var lineCount=(code.textContent||'').replace(/\\r?\\n$/,'').split(/\\r?\\n/).length;
    var isLong=lineCount>18||code.getBoundingClientRect().height>320;
    var lbl=document.createElement('span');lbl.className='code-lang-label';
    lbl.textContent=(lang==='plaintext'?'TEXT':lang).toUpperCase();
    var btn=document.createElement('button');btn.className='code-copy-btn';btn.textContent='复制';
    btn.type='button';
    btn.setAttribute('aria-label','复制代码');
    btn.onclick=function(){
      copyText(code.innerText||code.textContent,function(){
        btn.textContent='已复制';btn.classList.add('copied');
        setTimeout(function(){btn.textContent='复制';btn.classList.remove('copied');},2000);
      },function(){
        btn.textContent='复制失败';btn.classList.remove('copied');
        setTimeout(function(){btn.textContent='复制';},2500);
      });
    };
    pre.insertBefore(lbl,pre.firstChild);
    if(isLong){
      pre.classList.add('org-museum-code-collapsed');
      var toggle=document.createElement('button');
      toggle.className='code-copy-btn code-toggle-btn';
      toggle.type='button';
      toggle.textContent='展开';
      toggle.setAttribute('aria-label','展开代码块');
      toggle.setAttribute('aria-expanded','false');
      toggle.onclick=function(){
        var expanded=pre.classList.toggle('org-museum-code-expanded');
        pre.classList.toggle('org-museum-code-collapsed',!expanded);
      toggle.textContent=expanded?'收起':'展开';
      toggle.setAttribute('aria-label',expanded?'收起代码块':'展开代码块');
      toggle.setAttribute('aria-expanded',expanded?'true':'false');
      scheduleCodeScrollAccess();
      };
      pre.insertBefore(toggle,lbl.nextSibling);
      pre.insertBefore(btn,toggle.nextSibling);
    }else pre.insertBefore(btn,lbl.nextSibling);
  });
  var codeAccessFrame=0;
  function syncCodeScrollAccess(){
    codeAccessFrame=0;
    codeBlocks.forEach(function(pre){
      var overflow=getComputedStyle(pre).overflowX;
      var scrollable=overflow!=='hidden'&&overflow!=='clip'&&
        pre.scrollWidth>pre.clientWidth+1;
      if(scrollable)pre.tabIndex=0;
      else pre.removeAttribute('tabindex');
    });
  }
  function scheduleCodeScrollAccess(){
    if(!codeAccessFrame)codeAccessFrame=requestAnimationFrame(syncCodeScrollAccess);
  }
  scheduleCodeScrollAccess();
  window.addEventListener('resize',scheduleCodeScrollAccess,{passive:true});
  function reportHighlightFailure(message){
    document.body.classList.add('org-museum-no-code-highlight');
    codeBlocks.forEach(function(pre){
      if(pre.querySelector('.code-highlight-status'))return;
      var status=document.createElement('span');status.className='code-highlight-status';
      status.setAttribute('role','status');status.textContent=message;
      pre.appendChild(status);
    });
  }
  function runHighlight(){
    if(!window.hljs){reportHighlightFailure('语法高亮不可用，代码内容仍可阅读');return;}
    try{
      codes.forEach(function(code){
        var lang=code.getAttribute('data-language')||'';
        if(!code.dataset.highlighted&&(!lang||hljs.getLanguage(lang))){
          hljs.highlightElement(code);
        }else if(lang&&!hljs.getLanguage(lang)){
          code.classList.add('no-highlight');
        }
      });
      scheduleCodeScrollAccess();
    }catch(_error){reportHighlightFailure('语法高亮执行失败，代码内容仍可阅读');}
  }
  function loadScript(src,done,fail){
    if(!src){(fail||function(){})();return;}
    var js=document.createElement('script');
    js.src=src;js.async=true;js.onload=done;
    js.onerror=fail||function(){reportHighlightFailure('语法高亮资源加载失败，代码内容仍可阅读');};
    document.head.appendChild(js);
  }
  function runAfterLanguageModules(){
    if(window.hljs&&hljs.getLanguage('lisp'))runHighlight();
    else loadScript(lispSrc,runHighlight,runHighlight);
  }
  if(window.hljs){runAfterLanguageModules();}
  else{
    if(cssSrc){var css=document.createElement('link');css.rel='stylesheet';
      css.href=cssSrc;document.head.appendChild(css);}
    loadScript(jsSrc,runAfterLanguageModules);
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
      var title=document.createElement('strong');title.textContent=l.textContent;
      var address=document.createElement('span');address.textContent=hr;
      tt.replaceChildren(title,address);
      tt.style.left=r.left+'px';tt.style.top=(r.bottom+10)+'px';
      tt.classList.add('visible');
    });
    l.addEventListener('mouseleave',function(){tt.classList.remove('visible');});
  });
}

/* ── 7. Image lightbox ── */
function initLightbox(){
  var ol=document.createElement('div');ol.id='image-lightbox-overlay';
  ol.setAttribute('role','dialog');ol.setAttribute('aria-modal','true');
  ol.setAttribute('aria-label','图片预览');ol.hidden=true;
  var oli=document.createElement('img');oli.alt='';
  var close=document.createElement('button');close.type='button';
  close.className='image-lightbox-close';close.textContent='关闭图片预览';
  var lastFocus=null;
  ol.appendChild(oli);ol.appendChild(close);document.body.appendChild(ol);
  function hideLightbox(){
    ol.classList.remove('visible');ol.hidden=true;
    if(lastFocus&&document.contains(lastFocus))lastFocus.focus();
  }
  function showLightbox(img){
    lastFocus=img;oli.src=img.currentSrc||img.src;oli.alt=img.alt||'';
    ol.hidden=false;ol.classList.add('visible');close.focus();
  }
  close.addEventListener('click',hideLightbox);
  ol.addEventListener('click',function(event){if(event.target===ol)hideLightbox();});
  ol.addEventListener('keydown',function(event){
    if(event.key==='Escape'){event.preventDefault();hideLightbox();}
    else if(event.key==='Tab'){event.preventDefault();close.focus();}
  });
  document.querySelectorAll('.article-container img').forEach(function(img){
    if(img.closest('a'))return;
    img.tabIndex=0;img.setAttribute('role','button');
    img.setAttribute('aria-label',(img.alt||'图片')+'，打开预览');
    img.addEventListener('click',function(){showLightbox(img);});
    img.addEventListener('keydown',function(event){
      if(event.key==='Enter'||event.key===' '){event.preventDefault();showLightbox(img);}
    });
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
    if(n.parentElement&&n.parentElement.closest(
      'pre,code,kbd,samp,script,style,textarea,[contenteditable]'))continue;
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
</script>\n")

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
  (if (not org-museum-background-effects-enabled)
      ""
    "<script>
(function(){
function lsGet(k,d){try{return localStorage.getItem(k)||d;}catch(e){return d;}}
function lsSet(k,v){try{localStorage.setItem(k,v);}catch(e){}}

var fxc=document.getElementById('org-museum-fx-canvas');
var motionQuery=window.matchMedia('(prefers-reduced-motion: reduce)');
var allowedFx=['none','matrix','particles','tubes'];
var cfx=lsGet('org-museum-bg-fx-v2','none');
if(!allowedFx.includes(cfx))cfx='none';
var aid=null,tc=null;
var fxButtons=[];
var zenObserver=null;

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
      codeFont=getComputedStyle(document.documentElement)
        .getPropertyValue('--font-code').trim(),
      cols=Math.floor(w/fs),drps=[];
  for(var x=0;x<cols;x++)drps[x]=1;
  function draw(){
    ctx.fillStyle='rgba(39,40,34,0.05)';ctx.fillRect(0,0,w,h);
    ctx.fillStyle='#66d9ef';ctx.font=fs+'px '+codeFont;
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

function applyFx(fx,persist){
  stp();
  var readingMode=document.body.classList.contains('zen-mode');
  var effectiveFx=(motionQuery.matches||document.hidden||readingMode)?'none':fx;
  var usesCanvas=['matrix','particles','tubes'].includes(effectiveFx);
  if(fxc)fxc.style.display=usesCanvas?'block':'none';
  if(usesCanvas)rsz();
  document.querySelectorAll('.fx-btn').forEach(function(b){
    b.disabled=motionQuery.matches&&b.getAttribute('data-fx')!=='none';
    b.classList.toggle('active',b.getAttribute('data-fx')===effectiveFx);
  });
  if(persist)lsSet('org-museum-bg-fx-v2',fx);
  if(effectiveFx==='matrix')        startMatrix();
  else if(effectiveFx==='particles')startParticles();
  else if(effectiveFx==='tubes')    startTubes();
}

function initFx(){
  fxButtons=Array.from(document.querySelectorAll('.fx-btn'));if(!fxButtons.length)return;
  fxButtons.forEach(function(b){
    b.orgMuseumFxClick=function(){
      var fx=this.getAttribute('data-fx');
      if(fx&&allowedFx.includes(fx)&&!this.disabled){cfx=fx;applyFx(fx,true);}
    };
    b.addEventListener('click',b.orgMuseumFxClick);
  });
  zenObserver=new MutationObserver(function(){applyFx(cfx,false);});
  zenObserver.observe(document.body,{attributes:true,attributeFilter:['class']});
  applyFx(cfx,false);
}
function onVisibilityChange(){applyFx(cfx,false);}
function onMotionChange(){applyFx(cfx,false);}
function onPageHide(){
  stp();window.removeEventListener('resize',rsz);
  document.removeEventListener('visibilitychange',onVisibilityChange);
  if(motionQuery.removeEventListener)motionQuery.removeEventListener('change',onMotionChange);
  else if(motionQuery.removeListener)motionQuery.removeListener(onMotionChange);
  if(zenObserver){zenObserver.disconnect();zenObserver=null;}
  fxButtons.forEach(function(b){b.removeEventListener('click',b.orgMuseumFxClick);});
  fxButtons=[];
}
document.addEventListener('visibilitychange',onVisibilityChange);
if(motionQuery.addEventListener)motionQuery.addEventListener('change',onMotionChange);
else if(motionQuery.addListener)motionQuery.addListener(onMotionChange);
window.addEventListener('pagehide',onPageHide,{once:true});
if(document.readyState==='loading')
  document.addEventListener('DOMContentLoaded',initFx);
else initFx();
})();
</script>\n"))

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
            var mark=document.createElement('span');
            mark.className='search-highlight';mark.textContent=hl;
            a.replaceChildren(document.createTextNode(pre),mark,document.createTextNode(post));
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
        (goto-char (point-min))
        ;; Health reporting only needs bracketed file-link targets.  Avoid a
        ;; full Org AST here: large notes made `org-museum-status' block Emacs
        ;; for minutes even when they contained no file links.
        (while (re-search-forward
                "\\[\\[file:\\([^]\n]+\\)\\]\\(?:\\[[^]\n]*\\]\\)?\\]"
                nil t)
          (let* ((raw (match-string-no-properties 1))
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
                    records))))))
    (nreverse records)))

(defun org-museum--page-self-links (page pages)
  "Return literal links in PAGE that resolve back to PAGE itself."
  (let ((source (org-museum-page-path page))
        (page-id (org-museum-page-id page))
        (aliases (org-museum--build-page-id-aliases pages))
        self-links)
    (when (file-readable-p source)
      (with-temp-buffer
        (insert-file-contents source)
        (goto-char (point-min))
        (while (re-search-forward
                "\\[\\[\\(?:wiki\\|museum\\|id\\):\\([^]\n]+\\)\\]" nil t)
          (when (equal page-id
                       (org-museum--resolve-page-link-id
                        (match-string-no-properties 1) pages aliases))
            (push (match-string-no-properties 0) self-links)))
        (goto-char (point-min))
        (while (re-search-forward "\\[\\[file:\\([^]\n]+\\)\\]" nil t)
          (when (org-museum--file-link-refers-to-p
                 (match-string-no-properties 1) source source)
            (push (match-string-no-properties 0) self-links)))))
    (nreverse self-links)))

(defun org-museum--health-heading-paths (page)
  "Return exportable H2--H4 outline paths for PAGE without building an AST.
Selection-tag exports and non-default task filtering fall back to the canonical
export inventory because those uncommon modes need the full exporter rules."
  (let ((file (org-museum-page-path page))
        (select-tags org-export-select-tags)
        (exclude-tags org-export-exclude-tags)
        selection-active paths)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (delay-mode-hooks (org-mode))
        (save-excursion
          (goto-char (point-min))
          (when (re-search-forward
                 "^[ \t]*#\\+SELECT_TAGS:[ \t]*\\(.*\\)$" nil t)
            (setq select-tags (split-string (match-string 1) nil t)))
          (goto-char (point-min))
          (when (re-search-forward
                 "^[ \t]*#\\+EXCLUDE_TAGS:[ \t]*\\(.*\\)$" nil t)
            (setq exclude-tags (split-string (match-string 1) nil t))))
        (goto-char (point-min))
        (while (re-search-forward org-heading-regexp nil t)
          (goto-char (line-beginning-position))
          (let ((local-tags (org-get-tags nil t)))
            (when (cl-intersection local-tags select-tags :test #'equal)
              (setq selection-active t)))
          (when (and (<= (org-outline-level) 3)
                     (not (org-in-commented-heading-p))
                     (or org-export-with-archived-trees
                         (not (org-in-archived-heading-p)))
                     (not (cl-intersection
                           (org-get-tags nil nil) exclude-tags :test #'equal)))
            (push (mapconcat #'identity
                             (org-get-outline-path t t) " / ")
                  paths))
          (forward-line 1))))
    (if (or selection-active (not (eq org-export-with-tasks t)))
        (mapcar (lambda (heading) (plist-get heading :path))
                (org-museum--source-heading-inventory page))
      (nreverse paths))))

(defun org-museum--page-duplicate-heading-paths (page)
  "Return duplicate H2--H4 outline paths found in PAGE's Org source.
Each path is reported once, in the order its second occurrence appears."
  (let ((occurrences (make-hash-table :test 'equal)) duplicates)
    (dolist (path (org-museum--health-heading-paths page))
      (let ((occurrence (1+ (gethash path occurrences 0))))
        (puthash path occurrence occurrences)
        (when (= occurrence 2) (push path duplicates))))
    (nreverse duplicates)))

(defun org-museum--page-legacy-heading-anchors (page)
  "Return transient Org-style H2--H4 anchors in PAGE's current HTML export."
  (let ((output (ignore-errors
                  (org-museum--export-filename
                   (org-museum-page-path page))))
        anchors)
    (when (and output (file-readable-p output))
      (with-temp-buffer
        (insert-file-contents output)
        (goto-char (point-min))
        (while (re-search-forward
                "<h[2-4]\\b[^>]*\\bid=\\\"\\(org[[:xdigit:]]+\\)\\\""
                nil t)
          (push (match-string-no-properties 1) anchors))))
    (nreverse anchors)))

(defun org-museum--index-health-report (pages)
  "Return a plist of health indicators for PAGES hash-table.
Keys:
  :ghost    — list of IDs whose file no longer exists on disk
  :broken   — list of (from-id . missing-target-id) pairs
  :isolated — list of all IDs with no links in or out
  :draft    — list of IDs with status=draft
  :date-fallback — IDs whose creation date fell back to file modification
  :duplicate-heading-paths — (page-id . outline-path) migration risks
  :legacy-anchors — (page-id . transient-anchor) entries in current HTML
Applicable scope: org-museum-status, org-museum-index-verify, CI checks."
  (let (ghost broken isolated isolated-published isolated-draft draft date-fallback
              missing-description local-external local-missing
              duplicate-heading-paths legacy-anchors case-conflicts self-links
              relation-annotations)
    (dolist (kind '(category tag))
      (let ((groups (make-hash-table :test #'equal)))
        (maphash
         (lambda (id page)
           (dolist (value (if (eq kind 'category)
                              (list (org-museum-page-category page))
                            (org-museum-page-tags page)))
             (let* ((key (downcase (or value "")))
                    (entry (gethash key groups)))
               (puthash key
                        (list (cl-adjoin value (car entry) :test #'equal)
                              (cl-adjoin id (cadr entry) :test #'equal))
                        groups))))
         pages)
        (maphash
         (lambda (_key entry)
           (when (> (length (car entry)) 1)
             (push (list :kind kind :values (car entry) :page-ids (cadr entry))
                   case-conflicts)))
         groups)))
    (maphash
     (lambda (id page)
       (unless (file-exists-p (org-museum-page-path page))
         (push id ghost))
       (dolist (target-id (org-museum-page-links-to page))
         (unless (gethash target-id pages)
           (push (cons id target-id) broken)))
       (dolist (diagnostic (org-museum-page-relation-diagnostics page))
         (push (cons id diagnostic) relation-annotations))
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
       (when (eq (org-museum-page-date-source page) 'modified-fallback)
         (push id date-fallback))
       (when (string-empty-p (string-trim
                              (or (org-museum-page-description page) "")))
         (push id missing-description))
       (dolist (literal (org-museum--page-self-links page pages))
         (push (cons id literal) self-links))
       (dolist (record (org-museum--page-local-file-links page pages))
         (push record local-external)
         (unless (plist-get record :exists)
           (push record local-missing)))
       (dolist (path (org-museum--page-duplicate-heading-paths page))
         (push (cons id path) duplicate-heading-paths))
       (dolist (anchor (org-museum--page-legacy-heading-anchors page))
         (push (cons id anchor) legacy-anchors)))
     pages)
    (list :ghost ghost :broken broken :isolated isolated
          :isolated-published isolated-published
          :isolated-draft isolated-draft
          :draft draft
          :date-fallback date-fallback
          :missing-description missing-description
          :local-external local-external
          :local-missing local-missing
          :case-conflicts (nreverse case-conflicts)
          :self-links (nreverse self-links)
          :relation-annotations (nreverse relation-annotations)
          :duplicate-heading-paths (nreverse duplicate-heading-paths)
          :legacy-anchors (nreverse legacy-anchors))))

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
      (when-let* ((pg (gethash id pages)))
        (org-museum--index-remove-page id pg)
        (cl-incf repairs)))
    (dolist (pair broken)
      (when-let* ((pg (gethash (car pair) pages)))
        (setf (org-museum-page-links-to pg)
              (delete (cdr pair) (org-museum-page-links-to pg)))
        (cl-incf repairs)))
    (maphash (lambda (_id pg)
               (setf (org-museum-page-linked-from pg) nil))
             pages)
    (maphash (lambda (id pg)
               (dolist (target-id (org-museum-page-links-to pg))
                 (when-let* ((target (gethash target-id pages)))
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
[Fix-12] Adds a `Stale Exports' count and export-all quick link."
  (interactive)
  (org-museum--guard-init)
  (let* ((pages  (org-museum-index-pages org-museum--index))
         (health (org-museum--index-health-report pages))
         (stale  (org-museum--count-stale-pages))
         (css-status (org-museum--css-deployment-status))
         (runtime-status (org-museum--runtime-source-status)))
    (with-current-buffer (get-buffer-create "*Org Museum Status*")
      (erase-buffer) (org-mode)
      (insert "#+TITLE: Org Museum Status Report\n")
      (insert (format "#+DATE: %s\n\n" (format-time-string "%Y-%m-%d %H:%M")))

      (insert "* Configuration\n\n")
      (insert (format "- Root Dir:    =%s=\n" org-museum-root-dir))
      (insert (format "- Pages Dir:   =%s=\n" (org-museum--pages-base-dir)))
      (insert (format "- CSS Source:  =%s= %s\n"
                      (plist-get css-status :source)
                      (if (plist-get css-status :source-hash) "✓" "✗ MISSING")))
      (insert (format "- CSS Source SHA-256: =%s=\n"
                      (or (plist-get css-status :source-hash) "missing")))
      (insert (format "- CSS Export:  =%s= %s\n"
                      (plist-get css-status :output)
                      (if (plist-get css-status :output-hash) "✓" "✗ MISSING")))
      (insert (format "- CSS Export SHA-256: =%s=\n"
                      (or (plist-get css-status :output-hash) "missing")))
      (insert (format "- CSS Sync:    %s\n"
                      (if (plist-get css-status :in-sync)
                          "✓ current"
                        "⚠ source/export mismatch")))
      (insert (format "- Export Dir:  =%s=\n" (org-museum--pages-root)))
      (insert (format "- Scan Dir:    =%s=\n" (org-museum--scan-root)))
      (insert (format "- Runtime Loaded: =%s=\n"
                      (or (plist-get runtime-status :loaded) "missing")))
      (insert (format "- Runtime Loaded SHA-256: =%s=\n"
                      (or (plist-get runtime-status :loaded-hash) "missing")))
      (insert (format "- Runtime Source: =%s=\n"
                      (or (plist-get runtime-status :canonical) "missing")))
      (insert (format "- Runtime Source SHA-256: =%s=\n"
                      (or (plist-get runtime-status :canonical-hash) "missing")))
      (insert (format "- Runtime Sync: %s\n"
                      (if (plist-get runtime-status :in-sync)
                          "current"
                        "source/loaded mismatch")))

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
      (insert (format "- Creation Date Fallbacks: %d\n"
                      (length (plist-get health :date-fallback))))
      (insert (format "- Missing Descriptions: %d\n"
                      (length (plist-get health :missing-description))))
      (insert (format "- Relation Annotation Warnings: %d\n"
                      (length (plist-get health :relation-annotations))))
      (insert (format "- Duplicate Heading Paths: %d\n"
                      (length (plist-get health :duplicate-heading-paths))))
      (insert (format "- Legacy Heading Anchors:  %d\n"
                      (length (plist-get health :legacy-anchors))))
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
          (when-let* ((p (gethash id pages)))
            (insert (format "- [[museum:%s][%s]] (%s)\n"
                            id (org-museum-page-title p)
                            (or (org-museum-page-status p) "published"))))))

      (when (plist-get health :missing-description)
        (insert "\n** Missing Descriptions\n\n")
        (dolist (id (plist-get health :missing-description))
          (when-let* ((p (gethash id pages)))
            (insert (format "- [[museum:%s][%s]] — add #+DESCRIPTION when useful\n"
                            id (org-museum-page-title p))))))

      (when (plist-get health :date-fallback)
        (insert "\n** Creation Date Fallbacks\n\n")
        (dolist (id (plist-get health :date-fallback))
          (when-let* ((p (gethash id pages)))
            (insert (format "- [[museum:%s][%s]] — missing or invalid #+DATE; using file modification time\n"
                            id (org-museum-page-title p))))))

      (when (plist-get health :relation-annotations)
        (insert "\n** Relation Annotation Warnings\n\n")
        (dolist (record (plist-get health :relation-annotations))
          (insert (format "- =%s= — %s\n" (car record) (cdr record)))))

      (when (plist-get health :duplicate-heading-paths)
        (insert "\n** Duplicate Heading Paths\n\n")
        (dolist (record (plist-get health :duplicate-heading-paths))
          (insert (format "- =%s= — =%s=; add CUSTOM_ID when a permanent public anchor is required\n"
                          (car record) (cdr record)))))

      (when (plist-get health :legacy-anchors)
        (insert "\n** Legacy Heading Anchors\n\n")
        (dolist (record (plist-get health :legacy-anchors))
          (insert (format "- =%s= — =%s=; run org-museum-export-all to migrate\n"
                          (car record) (cdr record)))))

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
      (unless (plist-get runtime-status :in-sync)
        (insert "- [[elisp:(org-museum-reload)][Reload Current Runtime]]\n"))
      (insert "- [[elisp:(org-museum-export-all)][Export All Pages]]\n")

      (display-buffer (current-buffer)))))

;;;###autoload
;; ============================================================
;; §30  LATEX / PDF CODE HIGHLIGHTING
;; ============================================================

(defun org-museum--set-latex-src-backend (backend)
  "Select BACKEND across current and pre-Org-9.6 ox-latex releases."
  (if (boundp 'org-latex-src-block-backend)
      (set 'org-latex-src-block-backend backend)
    (set (intern "org-latex-listings")
         (pcase backend
           ('minted 'minted)
           ('listings t)
           (_ nil)))))

(defun org-museum--setup-latex-export ()
  "Configure ox-latex for code highlighting based on user preference.
Must be called after `org-museum-latex-code-highlight' is set.

When `minted':
  - Selects the minted source-block backend
  - Adds the minted package to `org-latex-packages-alist'
  - Ensures -shell-escape is in the compilation command chain

When `listings':
  - Selects the listings source-block backend
  - Adds the listings and color packages

When nil:
  - Selects verbatim source-block output"
  (require 'ox-latex)
  (pcase org-museum-latex-code-highlight
    ('minted
     (org-museum--set-latex-src-backend 'minted)
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
     (org-museum--set-latex-src-backend 'listings)
     (cl-pushnew '("" "listings" nil) org-latex-packages-alist :test #'equal)
     (cl-pushnew '("" "color" nil)    org-latex-packages-alist :test #'equal)
     (message "Org Museum [LaTeX]: listings highlighting configured"))
    (_
     (org-museum--set-latex-src-backend 'verbatim)
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
            ("p  Sync Publish Site" . org-museum-publish-sync)
            ("!  Full Sync / Review Sharing" . org-museum-publish-sync-full)
            ("P  Deploy to GitHub"  . org-museum-publish-deploy)
            ("r  Rename Page"      . org-museum-rename-page)
            ("i  Rebuild Index"    . org-museum-index-build)
            ("v  Verify Index"     . org-museum-index-verify)
            ("l  Check Links"      . org-museum-check-links)
            ("c  Start Curation Server" . org-museum-curation-server-start)
            ("C  Stop Curation Server" . org-museum-curation-server-stop)
            ("s  Status Report"    . org-museum-status)
            ("I  Init Workspace"   . org-museum-init)))
         (choice (completing-read
                  (format "Org Museum [%s]: " status)
                  (mapcar #'car cmds) nil t)))
    (when-let* ((fn (cdr (assoc choice cmds))))
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
        ("g" "Export Graph"     org-museum-export-graph)
        ("p" "Sync Publish Site" org-museum-publish-sync)
        ("!" "Full Sync / Review Sharing" org-museum-publish-sync-full)
        ("P" "Deploy to GitHub"  org-museum-publish-deploy)]
       ["Index"
        ("i" "Rebuild Index"    org-museum-index-build)
        ("v" "Verify & Repair"  org-museum-index-verify)
        ("l" "Check Links"      org-museum-check-links)]
       ["Workspace"
        ("s" "Status Report"    org-museum-status)
        ("I" "Init Workspace"   org-museum-init)
        ("c" "Start Curation"   org-museum-curation-server-start)
        ("C" "Stop Curation"    org-museum-curation-server-stop)]])
   t))

(defvar org-museum-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c w n")   #'org-museum-create-page)
    (define-key map (kbd "C-c w f")   #'org-museum-link-complete)
    (define-key map (kbd "C-c w e")   #'org-museum-export-page)
    (define-key map (kbd "C-c w E")   #'org-museum-export-all)
    (define-key map (kbd "C-c w g")   #'org-museum-export-graph)
    (define-key map (kbd "C-c w p")   #'org-museum-publish-sync)
    (define-key map (kbd "C-c w P")   #'org-museum-publish-deploy)
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
[Fix-02] Uses one project-level idle timer to debounce consecutive saves.
Multiple buffers are coalesced into one transactional index persistence.
Guards:
  - org-museum-mode must be active
  - org-museum-root-dir must be set
  - File must be inside project root (G-1)
  - File must have .org extension"
  (when (and org-museum-mode
             org-museum-root-dir
             (buffer-file-name)
             (org-museum--file-in-project-p (buffer-file-name))
             (string-suffix-p ".org" (buffer-file-name)))
    (puthash (expand-file-name (buffer-file-name)) t
             org-museum--pending-save-files)
    (setq org-museum--project-save-retry-used nil)
    (when (timerp org-museum--project-save-timer)
      (cancel-timer org-museum--project-save-timer))
    (setq org-museum--project-save-timer
          (run-with-idle-timer
           org-museum-save-debounce-seconds nil
           #'org-museum--flush-pending-saves))))

(defun org-museum--flush-pending-saves ()
  "Apply all pending saves to one private index and persist it once."
  (setq org-museum--project-save-timer nil)
  (let (files)
    (maphash (lambda (file _value) (push file files))
             org-museum--pending-save-files)
    (when files
      (setq files (nreverse files))
      (unless org-museum--index (org-museum-index-build))
      (let* ((working (org-museum--alist-to-index
                       (org-museum--index-to-alist org-museum--index)))
             (source-snapshots
              (org-museum--snapshot-files (org-museum--scan-files)))
             (index-path (org-museum--index-file-path))
             (index-existed (file-exists-p index-path))
             (index-snapshot (org-museum--snapshot-files (list index-path)))
             committed)
        (condition-case err
            (let ((org-museum--index working))
              (dolist (file files)
                (org-museum--on-save-handle-id-change file)
                (org-museum--index-update-file-in-place file))
              (org-museum--index-save working index-path)
              (setq committed working))
          (error
           (org-museum--restore-file-snapshots source-snapshots)
           (cond
            (index-snapshot
             (org-museum--restore-file-snapshots index-snapshot))
            ((and (not index-existed) (file-regular-p index-path))
             (delete-file index-path)))
           (message "Org Museum [Index]: batched save update failed: %s"
                    (error-message-string err))
           (unless org-museum--project-save-retry-used
             (setq org-museum--project-save-retry-used t
                   org-museum--project-save-timer
                   (run-with-idle-timer
                    org-museum-save-debounce-seconds nil
                    #'org-museum--flush-pending-saves)))))
        (when committed
          (setq org-museum--project-save-retry-used nil)
          (setq org-museum--index committed)
          (dolist (file files)
            (remhash file org-museum--pending-save-files)))))))

(defun org-museum--on-save-handle-id-change (file)
  "Offer to update cross-links when FILE changed its WIKI_ID."
  (let* ((pages (and org-museum--index
                     (org-museum-index-pages org-museum--index)))
         (old-page (and pages (org-museum--find-page-by-path file pages)))
         (old-id (and old-page (org-museum-page-id old-page)))
         (new-id (with-temp-buffer
                   (insert-file-contents file)
                   (goto-char (point-min))
                   (if (re-search-forward
                        "^#\\+WIKI_ID:\\s-*\\(\\S-+\\)\\s-*$" nil t)
                       (string-trim (match-string 1))
                     (org-museum--generate-id file)))))
    (when (and old-id new-id (not (equal old-id new-id)) pages)
      (if (gethash new-id pages)
          (error "Org Museum [Index]: ID [%s] is already occupied" new-id)
        (when (yes-or-no-p
               (format "Org Museum: WIKI_ID changed %s → %s; update all cross-links? "
                       old-id new-id))
          (org-museum--update-links-globally old-id new-id))))))

(defun org-museum--on-save-flush (file)
  "Compatibility entry point: enqueue FILE and flush the project batch now."
  (puthash (expand-file-name file) t org-museum--pending-save-files)
  (setq org-museum--project-save-retry-used nil)
  (org-museum--flush-pending-saves))

;; ============================================================
;; §25  SAFE LOCAL CURATION
;; ============================================================

(define-error 'org-museum-curation-error
  "Org Museum curation request rejected"
  'user-error)

(defconst org-museum--curation-schema-version 1)
(defconst org-museum--curation-transaction-ttl 300)
(defconst org-museum--curation-max-request-bytes (* 64 1024))
(defconst org-museum--curation-fields
  '("title" "wikiId" "category" "status" "createdDate" "description" "tags" "path"))
(defconst org-museum--curation-relation-types
  '("属于" "相关" "前置依赖" "启发影响"))

(defvar org-museum--curation-transactions (make-hash-table :test #'equal))
(defvar org-museum--curation-server nil)
(defvar org-museum--curation-token nil)
(defvar org-museum--curation-server-port nil)
(defvar org-protocol-protocol-alist)

(defun org-museum--curation-value (key object)
  "Return KEY from JSON-style alist OBJECT."
  (or (alist-get key object nil nil #'equal)
      (alist-get (intern key) object)))

(defun org-museum--curation-keys (object)
  "Return string keys from JSON-style alist OBJECT."
  (mapcar (lambda (entry) (format "%s" (car entry))) object))

(defun org-museum--curation-reject-unknown (object allowed context)
  "Reject keys in OBJECT that are not in ALLOWED for CONTEXT."
  (dolist (key (org-museum--curation-keys object))
    (unless (member key allowed)
      (signal 'org-museum-curation-error
              (list (format "%s contains unknown field %S" context key))))))

(defun org-museum--curation-page (page-id)
  "Return indexed page PAGE-ID or reject the request."
  (unless org-museum--index (org-museum-index-build))
  (or (gethash page-id (org-museum-index-pages org-museum--index))
      (signal 'org-museum-curation-error
              (list (format "Unknown page ID %S" page-id)))))

(defun org-museum--curation-sha256 (file)
  "Return FILE's byte-level SHA-256 digest."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun org-museum--curation-clean-string (value field &optional limit allow-empty)
  "Validate VALUE as a short plain string for FIELD."
  (unless (stringp value)
    (signal 'org-museum-curation-error (list (format "%s must be a string" field))))
  (setq value (string-trim value))
  (when (and (not allow-empty) (string-empty-p value))
    (signal 'org-museum-curation-error (list (format "%s must not be empty" field))))
  (when (or (string-match-p "[\0\r\n]" value)
            (and limit (> (length value) limit)))
    (signal 'org-museum-curation-error (list (format "%s is invalid or too long" field))))
  value)

(defun org-museum--curation-valid-id-p (value)
  "Return non-nil when VALUE is a safe Wiki identity."
  (and (org-museum--path-component-safe-p value)
       (string-match-p "[[:alnum:]一-鿿]" value)))

(defun org-museum--curation-valid-tag-p (tag)
  "Return non-nil when TAG is safe for FILETAGS."
  (and (stringp tag) (<= (length tag) 48)
       (string-match-p "\\`[[:alnum:]_@#%+.-]+\\'" tag)))

(defun org-museum--curation-normalize-tags (tags)
  "Return validated, deduplicated TAGS."
  (unless (or (null tags) (listp tags) (vectorp tags))
    (signal 'org-museum-curation-error (list "tags must be an array")))
  (let (result)
    (dolist (tag (append tags nil) (nreverse result))
      (setq tag (org-museum--curation-clean-string tag "tag" 48))
      (unless (org-museum--curation-valid-tag-p tag)
        (signal 'org-museum-curation-error (list (format "Invalid tag %S" tag))))
      (unless (member tag result) (push tag result)))))

(defun org-museum--curation-safe-target-path (relative)
  "Resolve and validate RELATIVE page path under the pages directory."
  (setq relative (replace-regexp-in-string "\\\\" "/"
                                            (org-museum--curation-clean-string
                                             relative "path" 240)))
  (when (or (file-name-absolute-p relative)
            (not (string-suffix-p ".org" relative t)))
    (signal 'org-museum-curation-error (list "path must be a relative .org path")))
  (let* ((parts (split-string relative "/" t))
         (base (file-name-as-directory (expand-file-name (org-museum--pages-base-dir))))
         (target (expand-file-name relative base)))
    (unless (and parts (cl-every #'org-museum--path-component-safe-p parts)
                 (file-in-directory-p target base))
      (signal 'org-museum-curation-error (list "path escapes pages/ or uses a reserved name")))
    (let ((cursor base))
      (dolist (part (butlast parts))
        (setq cursor (expand-file-name part cursor))
        (when (file-symlink-p cursor)
          (signal 'org-museum-curation-error (list "path crosses a symbolic link")))))
    (when (and (file-exists-p target) (file-symlink-p target))
      (signal 'org-museum-curation-error (list "path resolves to a symbolic link")))
    target))

(defun org-museum--curation-replace-keyword (content keyword value)
  "Replace or insert Org KEYWORD with VALUE in CONTENT."
  (with-temp-buffer
    (insert content)
    (goto-char (point-min))
    (let ((case-fold-search t)
          (line (format "#+%s: %s" keyword value)))
      (if (re-search-forward (format "^#\\+%s:[^\n]*" (regexp-quote keyword)) nil t)
          (replace-match line t t)
        (goto-char (point-min))
        (insert line "\n")))
    (buffer-string)))

(defun org-museum--curation-remove-managed-section (content)
  "Remove Org Museum's marked Related Notes section from CONTENT."
  (with-temp-buffer
    (insert content)
    (goto-char (point-min))
    (let (start end)
      (while (and (not start) (re-search-forward "^\\(\\*+\\) Related Notes[[:space:]]*$" nil t))
        (let ((candidate (line-beginning-position))
              (level (length (match-string 1))))
          (save-excursion
            (let ((limit (or (and (re-search-forward
                                   (format "^\\*\\{1,%d\\} " level) nil t)
                                  (line-beginning-position))
                             (point-max))))
              (goto-char candidate)
              (when (re-search-forward
                     "^:ORG_MUSEUM_MANAGED:[[:space:]]+t[[:space:]]*$" limit t)
                (setq start candidate end limit))))))
      (when start (delete-region start end)))
    (string-trim-right (buffer-string))))

(defun org-museum--curation-normalize-relation (relation)
  "Validate and normalize one RELATION operation."
  (org-museum--curation-reject-unknown relation '("action" "targetId" "type") "relation")
  (let* ((action (org-museum--curation-value "action" relation))
         (target (org-museum--curation-clean-string
                  (org-museum--curation-value "targetId" relation) "targetId" 96))
         (type (org-museum--curation-clean-string
                (or (org-museum--curation-value "type" relation) "相关") "relation type" 32)))
    (unless (member action '("add" "remove"))
      (signal 'org-museum-curation-error (list "relation action must be add or remove")))
    (unless (org-museum--curation-valid-id-p target)
      (signal 'org-museum-curation-error (list "relation targetId is invalid")))
    (unless (or (member type org-museum--curation-relation-types)
                (string-match-p "\\`[^|[:cntrl:]]+\\'" type))
      (signal 'org-museum-curation-error (list "relation type is invalid")))
    (org-museum--curation-page target)
    `((action . ,action) (targetId . ,target) (type . ,type))))

(defun org-museum--curation-apply-relations (content relations)
  "Apply managed RELATIONS to CONTENT and return updated text."
  (let ((managed (make-hash-table :test #'equal)) managed-targets)
    (with-temp-buffer
      (insert content)
      (goto-char (point-min))
      (when (re-search-forward "^\\(\\*+\\) Related Notes[[:space:]]*$" nil t)
        (let* ((level (length (match-string 1)))
               (body-start (progn (forward-line 1) (point)))
               (end (or (and (re-search-forward (format "^\\*\\{1,%d\\} " level) nil t)
                              (line-beginning-position))
                        (point-max))))
          (goto-char body-start)
          (when (re-search-forward
                 "^:ORG_MUSEUM_MANAGED:[[:space:]]+t[[:space:]]*$" end t)
            (goto-char body-start)
            (while (re-search-forward
                    "^- \\[\\[wiki:\\([^]]+\\)\\]\\[[^]]*\\]\\] :: \\(.*\\)$" end t)
              (let ((target (match-string 1)))
                (puthash target (string-trim (match-string 2)) managed)
                (push target managed-targets)))))))
    (dolist (relation relations)
      (let ((target (org-museum--curation-value "targetId" relation))
            (action (org-museum--curation-value "action" relation))
            (type (org-museum--curation-value "type" relation)))
        (push target managed-targets)
        (if (equal action "remove") (remhash target managed)
          (puthash target type managed))))
    (setq content (org-museum--curation-remove-managed-section content))
    (with-temp-buffer
      (insert content)
      (dolist (target (delete-dups managed-targets))
        (goto-char (point-min))
        (while (re-search-forward
                (format "^#\\+MUSEUM_RELATION:[[:space:]]*%s[[:space:]]*|[^\n]*\n?"
                        (regexp-quote target)) nil t)
          (replace-match "" t t)))
      (setq content (string-trim-right (buffer-string))))
    (let (rows keywords)
      (maphash
       (lambda (target type)
         (let ((target-page (org-museum--curation-page target)))
           (push (format "- [[wiki:%s][%s]] :: %s"
                         target (org-museum-page-title target-page) type) rows)
           (push (format "#+MUSEUM_RELATION: %s | %s" target type) keywords)))
       managed)
      (when rows
        (setq content
              (concat (string-trim-right content) "\n\n"
                      (mapconcat #'identity (sort keywords #'string<) "\n")
                      "\n\n* Related Notes\n:PROPERTIES:\n:ORG_MUSEUM_MANAGED: t\n:END:\n"
                      (mapconcat #'identity (sort rows #'string<) "\n") "\n"))))
    content))

(defun org-museum--curation-plan (payload)
  "Validate PAYLOAD and return a normalized curation transaction."
  (org-museum--curation-reject-unknown
   payload '("schemaVersion" "pageId" "expectedSha256" "changes" "relations") "request")
  (unless (equal (org-museum--curation-value "schemaVersion" payload)
                 org-museum--curation-schema-version)
    (signal 'org-museum-curation-error (list "Unsupported schemaVersion")))
  (let* ((page-id (org-museum--curation-clean-string
                   (org-museum--curation-value "pageId" payload) "pageId" 96))
         (page (org-museum--curation-page page-id))
         (file (expand-file-name (org-museum-page-path page)))
         (expected (org-museum--curation-clean-string
                    (org-museum--curation-value "expectedSha256" payload)
                    "expectedSha256" 64))
         (current (org-museum--curation-sha256 file))
         (changes (or (org-museum--curation-value "changes" payload) '()))
         (relations-raw (or (org-museum--curation-value "relations" payload) '()))
         normalized-relations content target-path new-id)
    (unless (string= expected current)
      (signal 'org-museum-curation-error (list "Source changed since the page was loaded")))
    (unless (listp changes)
      (signal 'org-museum-curation-error (list "changes must be an object")))
    (org-museum--curation-reject-unknown changes org-museum--curation-fields "changes")
    (setq normalized-relations
          (mapcar #'org-museum--curation-normalize-relation (append relations-raw nil)))
    (with-temp-buffer (insert-file-contents file) (setq content (buffer-string)))
    (dolist (entry changes)
      (let ((key (format "%s" (car entry))) (value (cdr entry)))
        (pcase key
          ("title" (setq content (org-museum--curation-replace-keyword
                                  content "TITLE" (org-museum--curation-clean-string value key 180))))
          ("wikiId"
           (setq new-id (org-museum--curation-clean-string value key 96))
           (unless (org-museum--curation-valid-id-p new-id)
             (signal 'org-museum-curation-error (list "wikiId is invalid")))
           (when-let* ((occupied (gethash new-id (org-museum-index-pages org-museum--index))))
             (unless (equal (org-museum-page-path occupied) file)
               (signal 'org-museum-curation-error (list "wikiId is already in use"))))
           (setq content (org-museum--curation-replace-keyword content "WIKI_ID" new-id)))
          ("category" (setq content (org-museum--curation-replace-keyword
                                     content "CATEGORY" (org-museum--curation-clean-string value key 80))))
          ("status"
           (unless (member value '("draft" "published"))
             (signal 'org-museum-curation-error (list "status must be draft or published")))
           (setq content (org-museum--curation-replace-keyword content "WIKI_STATUS" value)))
          ("createdDate"
           (unless (and (stringp value) (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" value))
             (signal 'org-museum-curation-error (list "createdDate must be YYYY-MM-DD")))
           (setq content (org-museum--curation-replace-keyword content "DATE" value)))
          ("description" (setq content (org-museum--curation-replace-keyword
                                        content "DESCRIPTION"
                                        (org-museum--curation-clean-string value key 500 t))))
          ("tags" (setq content (org-museum--curation-replace-keyword
                                 content "FILETAGS"
                                 (concat ":" (mapconcat #'identity
                                                         (org-museum--curation-normalize-tags value) ":") ":"))))
          ("path" (setq target-path (org-museum--curation-safe-target-path value))))))
    (when normalized-relations
      (setq content (org-museum--curation-apply-relations content normalized-relations)))
    (setq target-path (or target-path file) new-id (or new-id page-id))
    (when (and (not (equal (org-museum--normalised-path target-path)
                           (org-museum--normalised-path file)))
               (file-exists-p target-path))
      (signal 'org-museum-curation-error (list "Target path already exists")))
    (list :id (secure-hash 'sha256 (format "%s%s%s" (float-time) page-id (random)))
          :created (float-time) :page-id page-id :new-id new-id :file file
          :target-path target-path :expected-sha256 expected :before
          (with-temp-buffer (insert-file-contents file) (buffer-string))
          :after content :relations normalized-relations
          :identity-change (or (not (equal page-id new-id))
                               (not (equal (org-museum--normalised-path file)
                                           (org-museum--normalised-path target-path)))))))

(defun org-museum-curation-preview (payload)
  "Validate PAYLOAD and return a short-lived preview transaction."
  (let ((transaction (org-museum--curation-plan payload)))
    (puthash (plist-get transaction :id) transaction org-museum--curation-transactions)
    transaction))

(defun org-museum--curation-modified-buffer (files)
  "Return the first modified visiting buffer among FILES."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and buffer-file-name (buffer-modified-p)
                     (member (org-museum--normalised-path buffer-file-name)
                             (mapcar #'org-museum--normalised-path files)))))
            (buffer-list)))

(defun org-museum--curation-persist-backups (files transaction-id)
  "Copy FILES into a persistent backup directory for TRANSACTION-ID."
  (let* ((root (file-name-as-directory (expand-file-name org-museum-root-dir)))
         (backup-root (file-name-as-directory
                       (expand-file-name org-museum-curation-backup-directory))))
    (when (or (file-in-directory-p backup-root root)
              (file-in-directory-p root backup-root))
      (signal 'org-museum-curation-error
              (list "Curation backup directory must be outside the Wiki root")))
    (let ((destination (expand-file-name
                        (format "%s-%s" (format-time-string "%Y%m%dT%H%M%S")
                                (substring transaction-id 0 10)) backup-root)))
      (dolist (file files destination)
        (when (file-regular-p file)
          (let ((copy (expand-file-name (file-relative-name file root) destination)))
            (make-directory (file-name-directory copy) t)
            (copy-file file copy t t t)))))))

(defun org-museum-curation-apply (transaction-id &optional confirm-identity)
  "Apply preview TRANSACTION-ID after safety checks.
CONFIRM-IDENTITY must be non-nil for WIKI_ID or path changes."
  (let* ((transaction (gethash transaction-id org-museum--curation-transactions))
         (file (and transaction (plist-get transaction :file)))
         (target (and transaction (plist-get transaction :target-path))))
    (unless transaction
      (signal 'org-museum-curation-error (list "Unknown or already-used transaction")))
    (when (> (- (float-time) (plist-get transaction :created))
             org-museum--curation-transaction-ttl)
      (remhash transaction-id org-museum--curation-transactions)
      (signal 'org-museum-curation-error (list "Curation transaction expired")))
    (when (and (plist-get transaction :identity-change) (not confirm-identity))
      (signal 'org-museum-curation-error (list "Identity or path change needs second confirmation")))
    (unless (string= (org-museum--curation-sha256 file)
                     (plist-get transaction :expected-sha256))
      (signal 'org-museum-curation-error (list "Source changed after preview")))
    (let* ((files (org-museum--scan-files))
           (modified (org-museum--curation-modified-buffer files))
           (snapshots (org-museum--snapshot-files files))
           (target-created (not (equal (org-museum--normalised-path file)
                                       (org-museum--normalised-path target)))))
      (when modified
        (signal 'org-museum-curation-error
                (list (format "Unsaved buffer blocks curation: %s" (buffer-name modified)))))
      (org-museum--curation-persist-backups files transaction-id)
      (condition-case error-data
          (progn
            (make-directory (file-name-directory target) t)
            (with-temp-buffer
              (insert (plist-get transaction :after))
              (write-region (point-min) (point-max) file nil 'silent))
            (unless (equal (org-museum--normalised-path file)
                           (org-museum--normalised-path target))
              (rename-file file target))
            (unless (equal (plist-get transaction :page-id)
                           (plist-get transaction :new-id))
              (org-museum--update-links-globally
               (plist-get transaction :page-id) (plist-get transaction :new-id)))
            (org-museum-index-build t)
            (let ((org-museum-open-browser-after-export nil))
              (org-museum-export-all))
            (when (fboundp 'org-roam-db-sync) (org-roam-db-sync))
            (remhash transaction-id org-museum--curation-transactions)
            target)
        (error
         (when (and target-created (file-exists-p target)) (delete-file target))
         (org-museum--restore-file-snapshots snapshots)
         (org-museum-index-build t)
         (signal (car error-data) (cdr error-data)))))))

(defun org-museum-curation-review (payload)
  "Open an Emacs diff review for curation PAYLOAD."
  (interactive)
  (let* ((transaction (org-museum-curation-preview payload))
         (buffer (get-buffer-create "*Org Museum Curation Review*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Org Museum 策展审阅\n\n"
                (format "页面：%s\n文件：%s\nSHA-256：%s\n\n"
                        (plist-get transaction :page-id)
                        (plist-get transaction :file)
                        (plist-get transaction :expected-sha256))
                "--- 当前内容\n" (plist-get transaction :before)
                "\n--- 建议内容\n" (plist-get transaction :after) "\n\n")
        (insert-text-button
         "确认应用"
         'follow-link t
         'action (lambda (_button)
                   (when (yes-or-no-p "Apply this reviewed curation change? ")
                     (when (or (not (plist-get transaction :identity-change))
                               (yes-or-no-p "Confirm identity/path change a second time? "))
                       (org-museum-curation-apply
                        (plist-get transaction :id) t)
                       (message "Org Museum curation applied")))))
        (insert "    ")
        (insert-text-button "取消" 'follow-link t
                            'action (lambda (_button) (kill-buffer buffer)))
        (special-mode)))
    (display-buffer buffer)
    transaction))

(defun org-museum--curation-json (object)
  "Encode OBJECT as compact UTF-8 JSON."
  (let ((json-encoding-pretty-print nil)) (json-encode object)))

(defun org-museum--curation-http-response (status body &optional type headers)
  "Return an HTTP response with STATUS, BODY, TYPE, and extra HEADERS."
  (let* ((payload (encode-coding-string (or body "") 'utf-8 t))
         (reason (pcase status (200 "OK") (201 "Created") (204 "No Content")
                        (400 "Bad Request") (401 "Unauthorized") (403 "Forbidden")
                        (404 "Not Found") (409 "Conflict") (413 "Payload Too Large")
                        (415 "Unsupported Media Type") (_ "Internal Server Error"))))
    (concat (format "HTTP/1.1 %d %s\r\n" status reason)
            (format "Content-Type: %s\r\n" (or type "application/json; charset=utf-8"))
            (format "Content-Length: %d\r\n" (string-bytes payload))
            "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
            "Referrer-Policy: no-referrer\r\nConnection: close\r\n"
            (mapconcat (lambda (header) (format "%s: %s\r\n" (car header) (cdr header))) headers "")
            "\r\n" payload)))

(defun org-museum--curation-http-error (status message)
  "Return a JSON error response with STATUS and MESSAGE."
  (org-museum--curation-http-response
   status (org-museum--curation-json `((ok . :json-false) (error . ,message)))))

(defun org-museum--curation-http-headers (text)
  "Parse HTTP header TEXT into a lowercase alist."
  (let (headers)
    (dolist (line (cdr (split-string text "\r\n" t)) (nreverse headers))
      (when (string-match "\\`\\([^:]+\\):[[:space:]]*\\(.*\\)\\'" line)
        (push (cons (downcase (match-string 1 line)) (match-string 2 line)) headers)))))

(defun org-museum--curation-authorized-p (headers)
  "Return non-nil when HEADERS authenticate this loopback session."
  (and org-museum--curation-token
       (equal (cdr (assoc "authorization" headers))
              (concat "Bearer " org-museum--curation-token))
       (equal (cdr (assoc "x-org-museum-curation" headers)) "1")
       (let ((origin (cdr (assoc "origin" headers))))
         (or (null origin)
             (member origin
                     (list (format "http://127.0.0.1:%d" org-museum--curation-server-port)
                           (format "http://localhost:%d" org-museum--curation-server-port)))))))

(defun org-museum--curation-json-read (body)
  "Decode BODY as a strict JSON object."
  (condition-case nil
      (let ((json-object-type 'alist) (json-array-type 'list)
            (json-key-type 'string) (json-null nil) (json-false :json-false))
        (json-read-from-string (decode-coding-string body 'utf-8 t)))
    (error (signal 'org-museum-curation-error (list "Malformed JSON request")))))

(defun org-museum--curation-page-json (page-id)
  "Return a safe page description for PAGE-ID."
  (let* ((page (org-museum--curation-page page-id))
         (file (org-museum-page-path page)))
    `((schemaVersion . ,org-museum--curation-schema-version)
      (pageId . ,(org-museum-page-id page))
      (title . ,(org-museum-page-title page))
      (category . ,(org-museum-page-category page))
      (status . ,(org-museum-page-status page))
      (createdDate . ,(format-time-string "%Y-%m-%d" (org-museum-page-created page)))
      (description . ,(or (org-museum-page-description page) ""))
      (tags . ,(vconcat (org-museum-page-tags page)))
      (path . ,(replace-regexp-in-string
                "\\\\" "/" (file-relative-name file (org-museum--pages-base-dir))))
      (sha256 . ,(org-museum--curation-sha256 file)))))

(defun org-museum--curation-static-file (request-path)
  "Resolve REQUEST-PATH beneath the shared export root, or nil."
  (let* ((raw (car (split-string request-path "?")))
         (decoded (url-unhex-string raw))
         (relative (if (member decoded '("" "/")) "index.html"
                     (string-remove-prefix "/" decoded)))
         (root (file-name-as-directory (expand-file-name (org-museum--shared-root))))
         (file (expand-file-name relative root)))
    (when (and (file-in-directory-p file root) (file-regular-p file)
               (not (file-symlink-p file))) file)))

(defun org-museum--curation-content-type (file)
  "Return a conservative response content type for FILE."
  (pcase (downcase (or (file-name-extension file) ""))
    ("html" "text/html; charset=utf-8") ("css" "text/css; charset=utf-8")
    ("js" "application/javascript; charset=utf-8") ("json" "application/json; charset=utf-8")
    ("svg" "image/svg+xml") ("png" "image/png") ("woff2" "font/woff2")
    (_ "application/octet-stream")))

(defun org-museum--curation-dispatch-http (method path headers body)
  "Dispatch one loopback METHOD PATH request with HEADERS and BODY."
  (condition-case error-data
      (if (string-prefix-p "/api/v1/" path)
          (progn
            (unless (org-museum--curation-authorized-p headers)
              (signal 'org-museum-curation-error (list "Unauthorized local session")))
            (pcase (list method (car (split-string path "?")))
              (`("GET" "/api/v1/session")
               (org-museum--curation-http-response
                200 (org-museum--curation-json
                     `((ok . t) (schemaVersion . ,org-museum--curation-schema-version)
                       (mode . "loopback")))))
              (`("GET" "/api/v1/page")
               (let* ((query (cadr (split-string path "?")))
                      (page-id (cadr (assoc "pageId" (url-parse-query-string (or query ""))))))
                 (unless page-id (signal 'org-museum-curation-error (list "pageId is required")))
                 (org-museum--curation-http-response
                  200 (org-museum--curation-json
                       (org-museum--curation-page-json (url-unhex-string page-id))))))
              (`("POST" "/api/v1/preview")
               (unless (string-prefix-p "application/json"
                                        (or (cdr (assoc "content-type" headers)) ""))
                 (signal 'org-museum-curation-error (list "Content-Type must be application/json")))
               (let ((transaction (org-museum-curation-preview
                                   (org-museum--curation-json-read body))))
                 (org-museum--curation-http-response
                  200 (org-museum--curation-json
                       `((ok . t) (schemaVersion . ,org-museum--curation-schema-version)
                         (transactionId . ,(plist-get transaction :id))
                         (expiresInSeconds . ,org-museum--curation-transaction-ttl)
                         (requiresSecondConfirmation . ,(if (plist-get transaction :identity-change) t :json-false))
                         (before . ,(plist-get transaction :before))
                         (after . ,(plist-get transaction :after)))))))
              (`("POST" "/api/v1/apply")
               (let ((request (org-museum--curation-json-read body)))
                 (org-museum--curation-reject-unknown
                  request '("schemaVersion" "transactionId" "confirmIdentity") "apply")
                 (unless (equal (org-museum--curation-value "schemaVersion" request)
                                org-museum--curation-schema-version)
                   (signal 'org-museum-curation-error (list "Unsupported schemaVersion")))
                 (let ((target (org-museum-curation-apply
                                (org-museum--curation-value "transactionId" request)
                                (eq (org-museum--curation-value "confirmIdentity" request) t))))
                   (org-museum--curation-http-response
                    200 (org-museum--curation-json
                         `((ok . t) (path . ,(file-relative-name target org-museum-root-dir))))))))
              (_ (org-museum--curation-http-error 404 "Unknown API endpoint"))))
        (cond
         ((equal (car (split-string path "?")) "/__org-museum-curation.js")
          (let ((runtime (expand-file-name "resources/org-museum-curation.js"
                                           (org-museum--plugin-dir))))
            (if (file-regular-p runtime)
                (with-temp-buffer
                  (insert-file-contents runtime)
                  (org-museum--curation-http-response
                   200 (buffer-string) "application/javascript; charset=utf-8"))
              (org-museum--curation-http-error 404 "Curation runtime not found"))))
         ((org-museum--curation-static-file path)
          (let ((file (org-museum--curation-static-file path)))
            (with-temp-buffer
              (set-buffer-multibyte nil) (insert-file-contents-literally file)
              (let ((contents (buffer-string)))
                (when (string-equal (downcase (or (file-name-extension file) "")) "html")
                  (setq contents
                        (replace-regexp-in-string
                         "</body>" "<script src=\"/__org-museum-curation.js\"></script></body>"
                         contents t t)))
                (org-museum--curation-http-response
                 200 contents (org-museum--curation-content-type file)
                 '(("Content-Security-Policy" . "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'")))))))
         (t (org-museum--curation-http-error 404 "Export not found"))))
    (org-museum-curation-error
     (org-museum--curation-http-error 409 (error-message-string error-data)))
    (error (org-museum--curation-http-error 500 (error-message-string error-data)))))

(defun org-museum--curation-server-filter (process chunk)
  "Collect and answer one bounded HTTP request from PROCESS using CHUNK."
  (let ((request (concat (or (process-get process 'request) "") chunk)))
    (process-put process 'request request)
    (when (> (string-bytes request) (+ org-museum--curation-max-request-bytes 8192))
      (process-send-string process (org-museum--curation-http-error 413 "Request too large"))
      (delete-process process))
    (when (and (process-live-p process) (string-match "\r\n\r\n" request))
      (let* ((header-end (match-end 0))
             (header-text (substring request 0 (- header-end 4)))
             (headers (org-museum--curation-http-headers header-text))
             (length (string-to-number (or (cdr (assoc "content-length" headers)) "0"))))
        (if (> length org-museum--curation-max-request-bytes)
            (progn (process-send-string process (org-museum--curation-http-error 413 "Request too large"))
                   (delete-process process))
          (when (>= (- (string-bytes request) header-end) length)
            (if (string-match "\\`\\([A-Z]+\\)[[:space:]]+\\([^[:space:]]+\\)[[:space:]]+HTTP/1\\.[01]" header-text)
                (process-send-string
                 process
                 (org-museum--curation-dispatch-http
                  (match-string 1 header-text) (match-string 2 header-text) headers
                  (substring request header-end (+ header-end length))))
              (process-send-string process (org-museum--curation-http-error 400 "Malformed request line")))
            (delete-process process)))))))

;;;###autoload
(defun org-museum-curation-server-start ()
  "Start the authenticated Org Museum loopback server and open the export."
  (interactive)
  (unless (eq org-museum-curation-mode 'loopback)
    (signal 'org-museum-curation-error
            (list "Set org-museum-curation-mode to loopback before starting the server")))
  (when (process-live-p org-museum--curation-server)
    (org-museum-curation-server-stop))
  (org-museum--guard-init)
  (unless (file-regular-p (expand-file-name "index.html" (org-museum--shared-root)))
    (let ((org-museum-open-browser-after-export nil)) (org-museum-export-all)))
  (setq org-museum--curation-token
        (secure-hash 'sha256 (format "%s:%s:%s:%s" (float-time) (emacs-pid) (random) (user-uid))))
  (setq org-museum--curation-server
        (make-network-process
         :name "org-museum-curation" :server t :host "127.0.0.1"
         :service org-museum-curation-port :family 'ipv4 :noquery t
         :coding 'binary :filter #'org-museum--curation-server-filter))
  (setq org-museum--curation-server-port
        (process-contact org-museum--curation-server :service))
  (let ((url (format "http://127.0.0.1:%d/#org-museum-curation-token=%s"
                     org-museum--curation-server-port org-museum--curation-token)))
    (browse-url url)
    (message "Org Museum curation server listening on 127.0.0.1:%d"
             org-museum--curation-server-port)
    url))

;;;###autoload
(defun org-museum-curation-server-stop ()
  "Stop the local curation server and invalidate its session token."
  (interactive)
  (when (process-live-p org-museum--curation-server)
    (delete-process org-museum--curation-server))
  (setq org-museum--curation-server nil
        org-museum--curation-token nil
        org-museum--curation-server-port nil)
  (clrhash org-museum--curation-transactions)
  (message "Org Museum curation server stopped"))

(defun org-museum--curation-protocol-handler (info)
  "Handle a short, local org-protocol curation request from INFO."
  (let* ((url (or (plist-get info :url) (plist-get info :link) ""))
         (query (car (last (split-string url "?"))))
         (params (url-parse-query-string query))
         (page-id (cadr (assoc "pageId" params)))
         (action (cadr (assoc "action" params)))
         (target-id (cadr (assoc "targetId" params)))
         (relation-type (cadr (assoc "type" params))))
    (unless page-id
      (signal 'org-museum-curation-error (list "Protocol request lacks pageId")))
    (let* ((page-id (url-unhex-string page-id))
           (page (org-museum--curation-page page-id))
           (file (org-museum-page-path page))
           (relations
            (if (and (equal action "add-relation") target-id relation-type)
                (list `((action . "add")
                        (targetId . ,(url-unhex-string target-id))
                        (type . ,(url-unhex-string relation-type))))
              '()))
           (payload `((schemaVersion . 1)
                      (pageId . ,(org-museum-page-id page))
                      (expectedSha256 . ,(org-museum--curation-sha256 file))
                      (changes . ()) (relations . ,relations))))
      (org-museum-curation-review payload)
      nil)))

(with-eval-after-load 'org-protocol
  (add-to-list 'org-protocol-protocol-alist
               '("Org Museum curation" :protocol "museum-curate"
                 :function org-museum--curation-protocol-handler :kill-client t)))

(defun org-museum-curation-protocol-install-command ()
  "Copy a Windows command that registers the org-protocol handler.
This command never modifies the registry itself."
  (interactive)
  (let ((command
         (concat "reg add HKCU\\Software\\Classes\\org-protocol /ve /d \"URL:Org Protocol\" /f && "
                 "reg add HKCU\\Software\\Classes\\org-protocol /v \"URL Protocol\" /d \"\" /f && "
                 "reg add HKCU\\Software\\Classes\\org-protocol\\shell\\open\\command /ve /d "
                 "\"\\\"C:\\v\\Emacs\\bin\\emacs.exe\\\" --no-splash --eval "
                 "\\\"(progn (require 'org-protocol) "
                 "(org-protocol-check-filename-for-protocol \\\\\\\"%%1\\\\\\\"))\\\"\" /f")))
    (kill-new command)
    (message "Registration command copied; inspect the existing handler before running it")))

(defun org-museum-curation-protocol-uninstall-command ()
  "Copy a Windows command that removes the org-protocol handler.
This command never modifies the registry itself."
  (interactive)
  (let ((command "reg delete HKCU\\Software\\Classes\\org-protocol /f"))
    (kill-new command)
    (message "Uninstall command copied; run it only after inspecting the registered handler")))

(provide 'org-museum)

;;; org-museum.el ends here
