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
(require 'org-attach)
(require 'ox-html)
(require 'ox-publish)
(require 'cl-lib)
(require 'json)
(require 'mailcap)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-http)
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
  "*Org Museum 隐私报告*"
  "Buffer used for local-only publish privacy findings.")

(defconst org-museum--publish-full-preview-buffer
  "*Org Museum 完整同步预览*"
  "Buffer used to review a configurable raw publication mirror.")

(defconst org-museum--publish-full-confirmation "COPY PRIVATE EXPORTS"
  "Exact confirmation required before installing a raw publication mirror.")

(define-error 'org-museum-publish-error
  "Org Museum 发布已停止"
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

(defcustom org-museum-export-dir "dist/pages"
  "HTML export directory for pages, relative to `org-museum-root-dir'."
  :type 'string
  :group 'org-museum)

(defcustom org-museum-shared-export-dir "dist"
  "Shared export directory (index.html, graph.html, resources/)."
  :type 'string
  :group 'org-museum)

(defcustom org-museum-assets-subdir "assets"
  "Asset directory below `org-museum-shared-export-dir'."
  :type 'string
  :group 'org-museum)

(defcustom org-museum-asset-cache-directory
  (expand-file-name ".cache/org-museum/assets/" user-emacs-directory)
  "Private content-addressed cache used for locked remote assets."
  :type 'directory
  :group 'org-museum)

(defcustom org-museum-asset-large-file-threshold (* 100 1024 1024)
  "Size in bytes above which an asset produces a build warning."
  :type 'integer
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

(defcustom org-museum-open-publish-directory-after-sync t
  "When non-nil, open the publish directory after a successful interactive sync."
  :type 'boolean
  :group 'org-museum)

(defcustom org-museum-publish-git-user-name nil
  "Fallback Git author name for the publish repository only.
When nil, deployment uses the authenticated GitHub login or repository owner.
An existing repository-local Git setting always takes precedence."
  :type '(choice (const :tag "Derive automatically" nil) string)
  :group 'org-museum)

(defcustom org-museum-publish-git-user-email nil
  "Fallback Git author email for the publish repository only.
When nil, deployment derives a GitHub noreply address.  This setting is never
written to the global Git configuration."
  :type '(choice (const :tag "Derive automatically" nil) string)
  :group 'org-museum)

(defcustom org-museum-background-emacs-program nil
  "Emacs executable used for background export and publish commands.
nil means use the executable that started the current Emacs instance."
  :type '(choice (const :tag "Current Emacs executable" nil) file)
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

(defcustom org-museum-article-max-width 1320
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

(cl-defstruct org-museum-asset
  "One resolved, content-addressed published asset."
  id filename mime kind size sha256 source-path published-url thumbnail
  width height duration filenames sources local-path)

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
(define-error 'org-museum-asset-error
  "Org Museum asset validation failed"
  'org-museum-export-failed)
(define-error 'org-museum-invalid-page-status
  "Invalid Org Museum page status")

(defvar org-museum--asset-registry nil
  "Dynamically bound hash table from content hash to `org-museum-asset'.")

(defvar org-museum--page-assets nil
  "Dynamically bound hash table from page id to ordered asset ids.")

(defvar org-museum--asset-warnings nil
  "Dynamically bound asset warning records for the current build.")

(defvar org-museum--asset-remote-results nil
  "Dynamically bound URL result cache for one build.")

(defvar org-museum--asset-created-files nil
  "Dynamically bound public asset files created by the current transaction.")

(defvar org-museum--asset-current-location nil
  "Dynamically bound source file and line for asset diagnostics.")

(defvar org-museum--build-time nil
  "Dynamically bound deterministic timestamp for one export transaction.")

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
      (let* ((directory (file-name-directory file))
             (temp nil))
        (make-directory directory t)
        (setq temp (make-temp-file
                    (expand-file-name ".org-museum-write-" directory)))
        (unwind-protect
            (progn
              (let ((coding-system-for-write 'utf-8-unix))
                (with-temp-file temp (insert content)))
              (rename-file temp file t)
              (setq temp nil))
          (when (and temp (file-exists-p temp))
            (delete-file temp)))))
    file))

(defun org-museum--copy-file-atomically (source target)
  "Copy binary SOURCE to TARGET through a same-directory temporary file."
  (let* ((directory (file-name-directory target))
         (temp nil))
    (make-directory directory t)
    (setq temp (make-temp-file
                (expand-file-name ".org-museum-copy-" directory)))
    (unwind-protect
        (progn
          (copy-file source temp t)
          (rename-file temp target t)
          (setq temp nil))
      (when (and temp (file-exists-p temp))
        (delete-file temp)))
    target))

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
            (error "Org Museum 无法附加 %s 运行脚本：缺少 </body>"
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
      (error "找不到 Org Museum 运行脚本源码"))
    (load source nil t t)
    (let ((after (org-museum--runtime-source-status)))
      (unless (and (plist-get after :in-sync)
                   (string= expected (plist-get after :loaded-hash)))
        (error "Org Museum 运行脚本重新加载后验证失败"))
      (message "Org Museum 运行环境已重新加载：%s" source)
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

(defconst org-museum--background-option-symbols
  '(org-museum-root-dir
    org-museum-export-dir
    org-museum-shared-export-dir
    org-museum-assets-subdir
    org-museum-asset-cache-directory
    org-museum-asset-large-file-threshold
    org-museum-publish-directory
    org-museum-publish-repository
    org-museum-publish-branch
    org-museum-publish-remote
    org-museum-publish-policy-file
    org-museum-publish-git-user-name
    org-museum-publish-git-user-email
    org-museum-scan-dir
    org-museum-scan-excluded-directories
    org-museum-curation-mode
    org-museum-curation-port
    org-museum-curation-backup-directory
    org-museum-pages-subdir
    org-museum-index-file
    org-museum-css-file
    org-museum-open-page-after-export
    org-museum-default-language
    org-museum-clean-stale-html-on-full-export
    org-museum-category-label-alist
    org-museum-article-max-width
    org-museum-background-effects-enabled
    org-museum-local-graph-neighbour-limit
    org-museum-graph-exclude-tags
    org-museum-graph-exclude-orphans
    org-museum-graph-exclude-id-regexp
    org-museum-code-highlight-method
    org-museum-latex-code-highlight)
  "Configuration copied into isolated background Emacs jobs.")

(defconst org-museum--background-buffer "*Org Museum 后台任务*"
  "Log buffer shared by the current background export or publish job.")

(defvar org-museum--background-process nil
  "Currently running Org Museum background process, or nil.")

(defvar org-museum--background-bootstrap-preapproved nil
  "Non-nil only in a background deploy whose repository creation was approved.")

(defvar org-museum--background-full-sync-preapproved nil
  "Non-nil only in a background full sync whose warning was approved.")

(defvar org-museum--background-worker-active nil
  "Non-nil while an isolated worker is executing an Org Museum job.")

(defun org-museum--background-emacs-executable ()
  "Return the executable used to run an isolated Org Museum job."
  (cl-labels
      ((path-candidates
        (path)
        (when path
          (if (and (eq system-type 'windows-nt)
                   (not (string-suffix-p ".exe" path t)))
              (list path (concat path ".exe"))
            (list path))))
       (first-executable
        (candidates)
        (seq-find (lambda (path)
                    (and (stringp path) (file-executable-p path)))
                  (delete-dups (delq nil candidates)))))
    (if org-museum-background-emacs-program
        (or (first-executable
             (path-candidates
              (expand-file-name org-museum-background-emacs-program)))
            (user-error
             "Configured Org Museum background Emacs is not executable: %s"
             org-museum-background-emacs-program))
      (let* ((invoked
              (and invocation-directory invocation-name
                   (expand-file-name invocation-name invocation-directory)))
             (program
              (first-executable
               (append
                (path-candidates invoked)
                (when invocation-directory
                  (list (expand-file-name "emacs.exe" invocation-directory)
                        (expand-file-name "runemacs.exe" invocation-directory)))
                (list (and invocation-name (executable-find invocation-name))
                      (executable-find "emacs")
                      (executable-find "emacs.exe"))))))
        (or program
            (user-error
             "Org Museum cannot find an Emacs executable for background jobs (invocation: %s)"
             (or invoked invocation-name "unknown")))))))

(defun org-museum--background-execute (action args)
  "Execute background ACTION with ARGS inside the isolated worker."
  (let ((org-museum-open-browser-after-export nil)
        (org-museum-auto-reload-before-export nil)
        (org-museum--background-worker-active t))
    (pcase action
      ('export-page (apply #'org-museum--export-page-current args))
      ('export-all (org-museum--export-all-current))
      ('export-graph (org-museum--export-graph-current :silent t))
      ('export-related-reading (org-museum--export-related-reading-current))
      ('export-timeline (org-museum--export-timeline-current))
      ('publish-sync (org-museum--publish-sync-current))
      ('publish-sync-full
       (let ((org-museum--background-full-sync-preapproved t))
         (org-museum--publish-sync-full-current t)))
      ('publish-deploy
       (let ((org-museum--background-bootstrap-preapproved (car args)))
         (org-museum--publish-deploy-current)))
      (_ (error "未知的 Org Museum 后台操作：%S" action)))))

(defun org-museum--background-script (source action args)
  "Return worker source loading SOURCE and executing ACTION with ARGS."
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";; Generated Org Museum background job.\n"
   "(setq load-prefer-newer t)\n"
   (format "(load %S nil nil t)\n" source)
   "(setq\n"
   (mapconcat
    (lambda (symbol)
      (format " %S (quote %S)" symbol (symbol-value symbol)))
    org-museum--background-option-symbols
    "\n")
   "\n org-museum-open-browser-after-export nil\n"
   " org-museum-auto-reload-before-export nil)\n"
   "(condition-case err\n"
   (format "    (let ((result (org-museum--background-execute (quote %S) (quote %S))))\n"
           action args)
   "      (when result (princ (format \"\\nResult: %s\\n\" result)))\n"
   "      (kill-emacs 0))\n"
   "  (error\n"
   "   (princ (format \"\\nOrg Museum background job failed: %s\\n\"\n"
   "                  (error-message-string err))\n"
   "          'external-debugging-output)\n"
   "   (kill-emacs 1)))\n"))

(defun org-museum--background-success-action (action)
  "Return the parent-Emacs success action for background ACTION."
  (pcase action
    ('export-all
     (when (and org-museum-open-browser-after-export
                org-museum-open-page-after-export)
       (let ((file
              (pcase org-museum-open-page-after-export
                ('timeline (org-museum--timeline-output-path))
                ('graph (expand-file-name "graph.html"
                                          (org-museum--shared-root)))
                (_ (expand-file-name "index.html"
                                     (org-museum--shared-root))))))
         (cons 'browse-url
               (concat "file:///"
                       (replace-regexp-in-string "\\\\" "/" file))))))
    ('publish-sync
     (when (and org-museum-open-publish-directory-after-sync
                (stringp org-museum-publish-directory)
                (not (string-empty-p org-museum-publish-directory)))
       (cons 'open-directory
             (file-name-as-directory
              (expand-file-name org-museum-publish-directory)))))))

(defun org-museum--open-directory (directory)
  "Open DIRECTORY in the platform file manager without changing Emacs windows."
  (let ((target (directory-file-name (expand-file-name directory))))
    (cond
     ((eq system-type 'windows-nt)
      (w32-shell-execute "open" (convert-standard-filename target)))
     ((eq system-type 'darwin)
      (start-process "org-museum-open-directory" nil "open" target))
     ((executable-find "xdg-open")
      (start-process "org-museum-open-directory" nil "xdg-open" target))
     (t (dired target)))))

(defun org-museum--open-background-success-action (success-action)
  "Perform SUCCESS-ACTION in the parent Emacs process."
  (pcase success-action
    (`(browse-url . ,url) (browse-url url))
    (`(open-directory . ,directory)
     (org-museum--open-directory directory))))

(defun org-museum--background-sentinel (process _event)
  "Clean up PROCESS and report its completion without changing window layout."
  (when (memq (process-status process) '(exit signal))
    (when-let* ((script (process-get process 'org-museum-script)))
      (ignore-errors (delete-file script)))
    (when (eq process org-museum--background-process)
      (setq org-museum--background-process nil))
    (let ((action (process-get process 'org-museum-action))
          (success-action
           (process-get process 'org-museum-success-action)))
      (if (and (eq (process-status process) 'exit)
               (= (process-exit-status process) 0))
          (progn
            (when success-action
              (condition-case err
                  (org-museum--open-background-success-action success-action)
                (error
                 (display-warning
                  'org-museum
                  (format "Background %s completed, but opening its result failed: %s"
                          action (error-message-string err))
                  :warning))))
            (message "Org Museum 后台任务已完成：%s" action))
        (display-warning
         'org-museum
         (format "Background %s failed; inspect %s" action
                 org-museum--background-buffer)
         :error)))))

(defun org-museum--start-background-job (action args)
  "Start isolated background ACTION with ARGS and return its process.
Only one exporter or publisher runs at a time so generated files cannot race."
  (when (process-live-p org-museum--background-process)
    (user-error "Org Museum 后台任务正在运行：%s"
                (process-get org-museum--background-process
                             'org-museum-action)))
  (let* ((source (org-museum--canonical-elisp-source-path))
         (script (make-temp-file "org-museum-background-" nil ".el"))
         (buffer (get-buffer-create org-museum--background-buffer))
         process)
    (unless (and source (file-regular-p source))
      (ignore-errors (delete-file script))
      (user-error "找不到 Org Museum 主源码"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Org Museum background action: %s\nSource: %s\n\n"
                        action source))))
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file script
        (insert (org-museum--background-script source action args))))
    (condition-case err
        (setq process
              (make-process
               :name (format "org-museum-%s" action)
               :buffer buffer
               :command (list (org-museum--background-emacs-executable)
                              "--quick" "--batch" "--load" script)
               :connection-type 'pipe
               :noquery t
               :sentinel #'org-museum--background-sentinel))
      (error
       (ignore-errors (delete-file script))
       (signal (car err) (cdr err))))
    (process-put process 'org-museum-script script)
    (process-put process 'org-museum-action action)
    (process-put process 'org-museum-success-action
                 (org-museum--background-success-action action))
    (setq org-museum--background-process process)
    (message "Org Museum 后台任务已启动：%s；Emacs 可继续使用" action)
    process))

;;;###autoload
(defun org-museum-background-status ()
  "Display the current background job log without waiting for completion."
  (interactive)
  (display-buffer (get-buffer-create org-museum--background-buffer))
  org-museum--background-process)

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
      (error "找不到 Org Museum 内置资源：%s（%s）"
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

;; ============================================================
;; §5A  CONTENT-ADDRESSED ARTICLE ASSETS
;; ============================================================

(defconst org-museum--asset-mime-fallbacks
  '(("png" . "image/png") ("jpg" . "image/jpeg")
    ("jpeg" . "image/jpeg") ("gif" . "image/gif")
    ("svg" . "image/svg+xml") ("webp" . "image/webp")
    ("mp4" . "video/mp4") ("webm" . "video/webm")
    ("mp3" . "audio/mpeg") ("wav" . "audio/wav")
    ("ogg" . "audio/ogg") ("m4a" . "audio/mp4")
    ("pdf" . "application/pdf")
    ("docx" . "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    ("pptx" . "application/vnd.openxmlformats-officedocument.presentationml.presentation")
    ("xlsx" . "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    ("csv" . "text/csv") ("json" . "application/json")
    ("parquet" . "application/vnd.apache.parquet")
    ("zip" . "application/zip") ("7z" . "application/x-7z-compressed")
    ("rar" . "application/vnd.rar") ("tar" . "application/x-tar")
    ("gz" . "application/gzip") ("xz" . "application/x-xz")
    ("bz2" . "application/x-bzip2")
    ;; Generic binary extensions are intentionally explicit.  Treating every
    ;; dotted URL as an asset misclassifies release pages such as /v4.7.0.
    ("bin" . "application/octet-stream") ("dat" . "application/octet-stream")
    ("sql" . "application/sql"))
  "Small MIME fallback table for formats missing from platform mailcap data.")

(defconst org-museum--asset-canonical-extensions
  '(("image/png" . "png") ("image/jpeg" . "jpg")
    ("image/webp" . "webp") ("image/svg+xml" . "svg")
    ("image/gif" . "gif") ("video/mp4" . "mp4")
    ("video/webm" . "webm") ("audio/mpeg" . "mp3")
    ("audio/x-mpeg" . "mp3")
    ("audio/wav" . "wav") ("audio/x-wav" . "wav")
    ("audio/ogg" . "ogg") ("audio/mp4" . "m4a")
    ("application/pdf" . "pdf")
    ("application/vnd.openxmlformats-officedocument.wordprocessingml.document" . "docx")
    ("application/vnd.openxmlformats-officedocument.presentationml.presentation" . "pptx")
    ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" . "xlsx")
    ("text/csv" . "csv") ("application/json" . "json")
    ("application/vnd.apache.parquet" . "parquet")
    ("application/zip" . "zip") ("application/x-7z-compressed" . "7z")
    ("application/vnd.rar" . "rar") ("application/x-tar" . "tar")
    ("application/gzip" . "gz") ("application/sql" . "sql"))
  "Canonical published extension for MIME types with reliable file semantics.")

(defconst org-museum--asset-document-mimes
  '("application/msword"
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    "application/vnd.ms-powerpoint"
    "application/vnd.openxmlformats-officedocument.presentationml.presentation")
  "MIME types rendered as document cards.")

(defconst org-museum--asset-spreadsheet-mimes
  '("application/vnd.ms-excel"
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    "text/csv" "application/csv" "application/json"
    "application/vnd.apache.parquet" "application/x-parquet")
  "MIME types rendered as spreadsheet or data cards.")

(defconst org-museum--asset-archive-mimes
  '("application/zip" "application/x-7z-compressed" "application/vnd.rar"
    "application/x-rar-compressed" "application/x-tar" "application/gzip"
    "application/x-xz" "application/x-bzip2")
  "MIME types rendered as archive download cards.")

(defun org-museum--assets-root ()
  "Return the absolute published article asset directory."
  (let* ((shared (file-name-as-directory
                  (expand-file-name (org-museum--shared-root))))
         (portable (replace-regexp-in-string
                    "\\\\" "/" (or org-museum-assets-subdir "")))
         (components (split-string portable "/" t))
         (root (expand-file-name portable shared)))
    (unless (and components
                 (not (file-name-absolute-p portable))
                 (not (member ".." components))
                 (not (member "." components))
                 (not (member (downcase (car components))
                              '("pages" "resources")))
                 (not (equal (downcase shared)
                             (downcase (file-name-as-directory root))))
                 (string-prefix-p
                  (downcase shared)
                  (downcase (file-name-as-directory root))))
      (signal 'org-museum-asset-error
              (list (format "Asset output must stay below the shared root: %s"
                            root))))
    (let ((cursor shared))
      (dolist (component components)
        (setq cursor (expand-file-name component cursor))
        (when (and (file-exists-p cursor)
                   (or (file-symlink-p cursor)
                       (not (equal
                             (downcase (file-name-as-directory
                                        (expand-file-name cursor)))
                             (downcase (file-name-as-directory
                                        (file-truename cursor)))))))
          (signal 'org-museum-asset-error
                  (list (format "Linked asset output component is unsafe: %s"
                                cursor))))))
    root))

(defun org-museum--assets-manifest-path ()
  "Return the absolute public asset manifest path."
  (expand-file-name "assets.json" (org-museum--shared-root)))

(defun org-museum--deterministic-build-time ()
  "Return SOURCE_DATE_EPOCH or the newest Org source timestamp."
  (let ((epoch (getenv "SOURCE_DATE_EPOCH")))
    (cond
     ((and epoch (string-match-p "\\`[0-9]+\\'" epoch))
      (seconds-to-time (string-to-number epoch)))
     (t
      (let ((latest 0))
        (dolist (file (ignore-errors (org-museum--scan-files)))
          (when (file-regular-p file)
            (setq latest
                  (max latest
                       (float-time
                        (file-attribute-modification-time
                         (file-attributes file)))))))
        (seconds-to-time latest))))))

(defun org-museum--build-time-string (format)
  "Format the current deterministic build time using FORMAT in UTC."
  (format-time-string format
                      (or org-museum--build-time
                          (org-museum--deterministic-build-time))
                      t))

(defun org-museum--call-preserving-source-mtime (file thunk)
  "Call THUNK and restore FILE's mtime when its content did not change.
This protects the Org source from libraries that touch the visited filename
while resolving links in a temporary export buffer.  A concurrent real edit
changes the content hash and therefore keeps its new timestamp."
  (let ((before-time (and (file-regular-p file)
                          (file-attribute-modification-time
                           (file-attributes file))))
        (before-hash (and (file-regular-p file)
                          (org-museum--file-content-hash file))))
    (unwind-protect
        (funcall thunk)
      (when (and before-time before-hash (file-regular-p file)
                 (string= before-hash (org-museum--file-content-hash file)))
        (set-file-times file before-time)))))

(defun org-museum--asset-mime-for-name (filename &optional supplied)
  "Return a normalized MIME type for FILENAME, preferring SUPPLIED."
  (let* ((header (and supplied (car (split-string supplied ";" t "[[:space:]]*"))))
         (extension (downcase (or (file-name-extension
                                   (car (split-string filename "[?#]"))) "")))
         (mailcap (and (not (string-empty-p extension))
                       (mailcap-extension-to-mime extension))))
    (downcase
     (or (and header (not (string-empty-p header)) header)
         (cdr (assoc extension org-museum--asset-mime-fallbacks)) mailcap
         "application/octet-stream"))))

(defun org-museum--asset-kind-for-mime (mime)
  "Return the renderer kind selected for MIME."
  (cond
   ((string-prefix-p "image/" mime) 'image)
   ((string-prefix-p "video/" mime) 'video)
   ((string-prefix-p "audio/" mime) 'audio)
   ((string= mime "application/pdf") 'pdf)
   ((member mime org-museum--asset-document-mimes) 'document)
   ((member mime org-museum--asset-spreadsheet-mimes) 'spreadsheet)
   ((member mime org-museum--asset-archive-mimes) 'archive)
   (t 'unknown)))

(defun org-museum--asset-published-name (sha mime)
  "Return the stable published filename for SHA and MIME."
  (format "%s.%s" sha
          (or (cdr (assoc mime org-museum--asset-canonical-extensions)) "bin")))

(defun org-museum--asset-image-dimensions (path)
  "Return pixel dimensions (WIDTH . HEIGHT) for PATH when Emacs can decode it."
  (condition-case nil
      (let ((size (image-size (create-image path) t)))
        (and (consp size) (integerp (car size)) (integerp (cdr size)) size))
    (error nil)))

(defun org-museum--asset-media-duration (path)
  "Return PATH duration in seconds when an optional ffprobe is available."
  (when-let* ((program (executable-find "ffprobe")))
    (with-temp-buffer
      (when (zerop
             (process-file program nil (current-buffer) nil
                           "-v" "error" "-show_entries" "format=duration"
                           "-of" "default=noprint_wrappers=1:nokey=1" path))
        (goto-char (point-min))
        (when (looking-at "[0-9]+\\(?:\\.[0-9]+\\)?")
          (string-to-number (match-string 0)))))))

(defun org-museum--asset-warning (kind source detail)
  "Record a KIND warning for SOURCE with DETAIL."
  (let ((record (list :kind kind :source source :detail detail
                      :location org-museum--asset-current-location)))
    (push record org-museum--asset-warnings)
    record))

(defun org-museum--asset-portable-source (source path)
  "Return a publish-safe SOURCE label for resolved PATH."
  (cond
   ((string-match-p "\\`https?://" source) source)
   ((string-prefix-p "attachment:" source) source)
   ((and path org-museum-root-dir
         (file-in-directory-p (expand-file-name path)
                              (file-name-as-directory
                               (expand-file-name org-museum-root-dir))))
    (concat "file:"
            (replace-regexp-in-string
             "\\\\" "/" (file-relative-name path org-museum-root-dir))))
   (t (concat "file:" (file-name-nondirectory (or path source))))))

(defun org-museum--asset-page-add (page-id asset-id)
  "Add ASSET-ID once to PAGE-ID while preserving reference order."
  (when (and page-id org-museum--page-assets)
    (let ((current (gethash page-id org-museum--page-assets)))
      (unless (member asset-id current)
        (puthash page-id (append current (list asset-id))
                 org-museum--page-assets)))))

(defun org-museum--asset-register-local
    (path source page-id _description alt-present &optional supplied-mime filename)
  "Validate and register local PATH referenced by SOURCE on PAGE-ID."
  (unless (and path (file-exists-p path))
    (signal 'org-museum-asset-error
            (list (format "Missing asset: %s (%s)" source path))))
  (unless (file-regular-p path)
    (signal 'org-museum-asset-error
            (list (format "Asset is not a regular file: %s" path))))
  (let ((size (file-attribute-size (file-attributes path))))
    (when (zerop size)
      (signal 'org-museum-asset-error
              (list (format "Empty asset: %s" path))))
    (let* ((display-name (or filename (file-name-nondirectory path)))
           (mime (org-museum--asset-mime-for-name display-name supplied-mime))
           (kind (org-museum--asset-kind-for-mime mime))
           (sha (org-museum--file-content-hash path))
           (portable (org-museum--asset-portable-source source path))
           (existing (and org-museum--asset-registry
                          (gethash sha org-museum--asset-registry)))
           (published (concat (string-remove-suffix
                               "/" (replace-regexp-in-string
                                    "\\\\" "/" org-museum-assets-subdir))
                              "/"
                              (org-museum--asset-published-name sha mime))))
      (when (> size org-museum-asset-large-file-threshold)
        (org-museum--asset-warning
         'large-file source
         (format "%s bytes exceeds %s" size org-museum-asset-large-file-threshold)))
      (when (and (string-match-p "\\`\\(?:file:\\)?[A-Za-z]:[/\\\\]" source)
                 (not (string-match-p "\\`https?://" source)))
        (org-museum--asset-warning
         'windows-absolute-path source "Use a relative file: or attachment: link"))
      (when (eq kind 'unknown)
        (org-museum--asset-warning
         'unsupported-mime source (format "Using generic attachment card for %s" mime)))
      (when (and (eq kind 'image) (not alt-present))
        (org-museum--asset-warning
         'missing-alt source "Add a non-empty Org link description for image alt text"))
      (if existing
          (progn
            (unless (member display-name (org-museum-asset-filenames existing))
              (setf (org-museum-asset-filenames existing)
                    (sort (cons display-name (org-museum-asset-filenames existing))
                          #'string<))
              (setf (org-museum-asset-filename existing)
                    (car (org-museum-asset-filenames existing))))
            (unless (member portable (org-museum-asset-sources existing))
              (setf (org-museum-asset-sources existing)
                    (sort (cons portable (org-museum-asset-sources existing))
                          #'string<))
              (setf (org-museum-asset-source-path existing)
                    (car (org-museum-asset-sources existing)))
              (org-museum--asset-warning
               'duplicate-resource source (format "Reuses content %s" sha)))
            (org-museum--asset-page-add page-id sha)
            existing)
        (let* ((dimensions (and (eq kind 'image)
                                (org-museum--asset-image-dimensions path)))
               (duration (and (memq kind '(video audio))
                              (org-museum--asset-media-duration path)))
               (asset (make-org-museum-asset
                      :id sha :filename display-name :mime mime :kind kind
                      :size size :sha256 sha :source-path portable
                      :published-url published
                      :thumbnail (and (eq kind 'image) published)
                      :width (car-safe dimensions) :height (cdr-safe dimensions)
                      :duration duration
                      :filenames (list display-name) :sources (list portable)
                      :local-path path)))
          (when (and (eq kind 'image) (null dimensions))
            (org-museum--asset-warning
             'metadata-unavailable source "Image dimensions could not be detected"))
          (when (and (memq kind '(video audio)) (null duration))
            (org-museum--asset-warning
             'metadata-unavailable source "Media duration could not be detected"))
          (unless org-museum--asset-registry
            (setq org-museum--asset-registry (make-hash-table :test #'equal)))
          (puthash sha asset org-museum--asset-registry)
          (org-museum--asset-page-add page-id sha)
          asset)))))

(defun org-museum--asset-cache-url-path (url)
  "Return metadata path for locked remote URL."
  (expand-file-name (concat "urls/" (secure-hash 'sha256 url) ".json")
                    org-museum-asset-cache-directory))

(defun org-museum--asset-cache-object-path (sha)
  "Return private cached object path for SHA."
  (expand-file-name (concat "objects/" sha) org-museum-asset-cache-directory))

(defun org-museum--asset-cache-read (url)
  "Return cached metadata for URL when its content object still exists."
  (let ((meta (org-museum--asset-cache-url-path url)))
    (when (file-regular-p meta)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents meta)
            (let* ((json-object-type 'alist)
                   (json-array-type 'list)
                   (data (json-read))
                   (sha (alist-get 'sha256 data))
                   (object (and sha (org-museum--asset-cache-object-path sha))))
              (and (stringp sha)
                   (string-match-p "\\`[0-9a-f]\\{64\\}\\'" sha)
                   object (file-regular-p object)
                   (string= sha (org-museum--file-content-hash object))
                   (list :path object :mime (alist-get 'mime data)
                         :filename (alist-get 'filename data)))))
        (error nil)))))

(defun org-museum--asset-download-remote (url)
  "Download URL once and return locked local cache metadata."
  (or (org-museum--asset-cache-read url)
      (let ((buffer (url-retrieve-synchronously url t t 30)))
        (unless buffer
          (signal 'org-museum-asset-error
                  (list (format "Remote asset download failed: %s" url))))
        (unwind-protect
            (with-current-buffer buffer
              (let* ((header-end (or (and (boundp 'url-http-end-of-headers)
                                          url-http-end-of-headers)
                                     (save-excursion
                                       (goto-char (point-min))
                                       (and (re-search-forward "\r?\n\r?\n" nil t)
                                            (point)))))
                     (status (and (boundp 'url-http-response-status)
                                  url-http-response-status))
                     (mime (save-excursion
                             (goto-char (point-min))
                             (and (re-search-forward
                                   "^Content-Type:[[:space:]]*\\([^;\r\n]+\\)" header-end t)
                                  (downcase (match-string 1)))))
                     (name (file-name-nondirectory
                            (or (url-filename (url-generic-parse-url url)) "asset")))
                     (name (car (split-string name "[?#]")))
                     (temp (make-temp-file "org-museum-remote-asset-")))
                (unless header-end
                  (signal 'org-museum-asset-error
                          (list (format "Invalid remote asset response: %s" url))))
                (when (and status (or (< status 200) (>= status 400)))
                  (signal 'org-museum-asset-error
                          (list (format "Remote asset HTTP %s: %s" status url))))
                (when (and mime (string-prefix-p "text/html" mime))
                  (signal 'org-museum-asset-error
                          (list (format "Remote asset returned HTML: %s" url))))
                (unwind-protect
                    (progn
                      (let ((coding-system-for-write 'no-conversion))
                        (write-region header-end (point-max) temp nil 'silent))
                      (when (zerop (file-attribute-size (file-attributes temp)))
                        (signal 'org-museum-asset-error
                                (list (format "Remote asset is empty: %s" url))))
                      (let* ((sha (org-museum--file-content-hash temp))
                             (object (org-museum--asset-cache-object-path sha))
                             (meta (org-museum--asset-cache-url-path url))
                             (resolved-mime (org-museum--asset-mime-for-name name mime)))
                        (make-directory (file-name-directory object) t)
                        (make-directory (file-name-directory meta) t)
                        (unless (file-exists-p object)
                          (org-museum--copy-file-atomically temp object))
                        (org-museum--write-content-if-changed
                         meta
                         (concat (json-encode
                                  `((url . ,url) (sha256 . ,sha)
                                    (mime . ,resolved-mime) (filename . ,name)))
                                 "\n"))
                        (list :path object :mime resolved-mime :filename name)))
                  (when (file-exists-p temp) (delete-file temp)))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun org-museum--remote-asset-candidate-p (url)
  "Return non-nil when URL names a downloadable asset rather than a web page."
  (let ((extension (downcase
                    (or (file-name-extension
                         (car (split-string
                               (url-filename (url-generic-parse-url url)) "[?#]"))) ""))))
    (and (not (string-empty-p extension))
         (assoc extension org-museum--asset-mime-fallbacks))))

(defun org-museum--asset-register-remote
    (url page-id description alt-present)
  "Register a remote asset, or retain its URL with a located warning."
  (let ((result (and org-museum--asset-remote-results
                     (gethash url org-museum--asset-remote-results))))
    (cond
     ((eq result :html) nil)
     ((and (consp result) (eq (car result) :unavailable))
      (org-museum--asset-warning 'remote-unavailable url (cdr result))
      nil)
     (t
      ;; Only download failures degrade to ordinary links.  Registration and
      ;; publication errors still fail, so local asset integrity is preserved.
      (let ((cached
             (condition-case err
                 (org-museum--asset-download-remote url)
               (error
                (let ((detail (error-message-string err)))
                  (if (string-match-p "Remote asset returned HTML:" detail)
                      (when org-museum--asset-remote-results
                        (puthash url :html org-museum--asset-remote-results))
                    (when org-museum--asset-remote-results
                      (puthash url (cons :unavailable detail)
                               org-museum--asset-remote-results))
                    (org-museum--asset-warning 'remote-unavailable url detail))
                  nil)))))
        (when cached
          (org-museum--asset-register-local
           (plist-get cached :path) url page-id description alt-present
           (plist-get cached :mime) (plist-get cached :filename))))))))

(defun org-museum--asset-href (asset out-file)
  "Return ASSET's published URL relative to OUT-FILE."
  (org-museum--relative-path
   (expand-file-name (org-museum-asset-published-url asset)
                     (org-museum--shared-root))
   out-file))

(defun org-museum--asset-render-html
    (asset out-file description &optional compact)
  "Render ASSET for OUT-FILE using DESCRIPTION and optional COMPACT card mode."
  (let* ((href (org-museum--html-escape
                (org-museum--asset-href asset out-file) t))
         (name (org-museum--html-escape
                (or description (org-museum-asset-filename asset))))
         (kind (org-museum-asset-kind asset))
         (mime (org-museum--html-escape (org-museum-asset-mime asset) t))
         (download-name (org-museum--html-escape
                         (org-museum-asset-filename asset) t))
         (download (format
                    (concat "<a class=\"museum-asset-card museum-asset-%s\" "
                            "data-asset-id=\"%s\" href=\"%s\" download=\"%s\">"
                            "<span class=\"museum-asset-kind\">%s</span>"
                            "<span class=\"museum-asset-name\">%s</span></a>")
                    kind (org-museum-asset-id asset) href download-name
                    (capitalize (symbol-name kind)) name)))
    (if compact download
      (pcase kind
        ('image
         (format (concat "<figure class=\"museum-asset museum-asset-image\" "
                         "data-asset-id=\"%s\"><img src=\"%s\" alt=\"%s\" "
                         "loading=\"lazy\" decoding=\"async\" data-lightbox></figure>")
                 (org-museum-asset-id asset) href name))
        ('video
         (format (concat "<figure class=\"museum-asset museum-asset-video\" "
                         "data-asset-id=\"%s\"><video controls preload=\"none\">"
                         "<source src=\"%s\" type=\"%s\">%s</video></figure>")
                 (org-museum-asset-id asset) href mime name))
        ('audio
         (format (concat "<figure class=\"museum-asset museum-asset-audio\" "
                         "data-asset-id=\"%s\"><audio controls preload=\"none\">"
                         "<source src=\"%s\" type=\"%s\">%s</audio></figure>")
                 (org-museum-asset-id asset) href mime name))
        ('pdf
         (format (concat "<div class=\"museum-asset museum-asset-pdf\">%s"
                         "<a class=\"museum-asset-preview\" href=\"%s\" "
                         "target=\"_blank\" rel=\"noopener noreferrer\">预览 PDF</a></div>")
                 download href))
        (_ download)))))

(defun org-museum--asset-description (link)
  "Return LINK's plain description, or nil."
  (when-let* ((begin (org-element-property :contents-begin link))
              (end (org-element-property :contents-end link)))
    (string-trim (buffer-substring-no-properties begin end))))

(defun org-museum--page-id-for-file (file)
  "Return indexed page id for FILE, falling back to its base name."
  (let ((page (and org-museum--index (org-museum--page-for-file file))))
    (if page (org-museum-page-id page) (file-name-base file))))

(defun org-museum--asset-link-exported-p (link)
  "Return non-nil if LINK is outside hidden Org headline trees."
  (not (cl-some
        (lambda (node)
          (and (eq (org-element-type node) 'headline)
               (or (org-element-property :commentedp node)
                   (org-element-property :archivedp node)
                   (member "noexport" (org-element-property :tags node)))))
        (org-element-lineage link))))

(defun org-museum--prepare-page-assets (buffer source-file out-file)
  "Resolve and replace asset links in BUFFER for SOURCE-FILE and OUT-FILE."
  (with-current-buffer buffer
    (let ((page-id (org-museum--page-id-for-file source-file)) replacements)
      (org-element-map (org-element-parse-buffer) 'link
        (lambda (link)
          (when (org-museum--asset-link-exported-p link)
          (let* ((type (org-element-property :type link))
                 (raw (org-element-property :raw-link link))
                 (path (org-element-property :path link))
                 (description (org-museum--asset-description link))
                 (alt-present (and description (not (string-empty-p description))))
                 asset)
            (let ((org-museum--asset-current-location
                   (format "%s:%d" source-file
                           (line-number-at-pos (org-element-property :begin link)))))
              (condition-case err
                  (progn
                    (cond
                     ((string= type "attachment")
                      (save-excursion
                        (goto-char (org-element-property :begin link))
                        (setq asset
                              (org-museum--asset-register-local
                               (org-attach-expand path) raw page-id
                               description alt-present))))
                     ((and (string= type "file")
                           (not (string= (downcase
                                          (or (file-name-extension path) ""))
                                         "org")))
                      (let ((resolved (expand-file-name
                                       (url-unhex-string
                                        (car (org-museum--file-link-parts path)))
                                       (file-name-directory source-file))))
                        (setq asset
                              (org-museum--asset-register-local
                               resolved raw page-id description alt-present))))
                     ((and (member type '("http" "https"))
                           (org-museum--remote-asset-candidate-p raw))
                      (setq asset
                            (org-museum--asset-register-remote
                             raw page-id description alt-present))))
                    (when asset
                      (push (list (org-element-property :begin link)
                                  (org-element-property :end link)
                                  (concat "@@html:"
                                          (org-museum--asset-render-html
                                           asset out-file description nil)
                                          "@@"))
                            replacements)))
                (org-museum-asset-error
                 (signal 'org-museum-asset-error
                         (list (format "%s: %s"
                                       org-museum--asset-current-location
                                        (error-message-string err)))))))))))
      (dolist (replacement (sort replacements
                                 (lambda (left right) (> (car left) (car right)))))
        (goto-char (nth 0 replacement))
        (delete-region (nth 0 replacement) (nth 1 replacement))
        (insert (nth 2 replacement))))))

(defun org-museum--preflight-page-assets (source-file)
  "Resolve every asset in SOURCE-FILE without writing public output."
  (org-museum--call-preserving-source-mtime
   source-file
   (lambda ()
     (with-temp-buffer
       (insert-file-contents source-file)
       (setq buffer-file-name source-file)
       ;; Asset discovery only needs Org syntax and link context.  Running the
       ;; user's full `org-mode-hook' here can start unrelated integrations once
       ;; per page and make a build appear to hang before its transaction writes
       ;; any output.
       (delay-mode-hooks (org-mode))
       (org-museum--prepare-page-assets
        (current-buffer) source-file
        (org-museum--export-filename source-file))))))

(defun org-museum--publish-assets (&optional cleanup)
  "Copy registered assets into the public tree; remove stale files with CLEANUP."
  (let ((root (org-museum--assets-root)) expected)
    (when (file-symlink-p root)
      (signal 'org-museum-asset-error
              (list (format "Refusing linked asset output directory: %s" root))))
    (make-directory root t)
    (when org-museum--asset-registry
      (maphash
       (lambda (_id asset)
         (let ((target (expand-file-name
                        (file-name-nondirectory
                         (org-museum-asset-published-url asset)) root)))
           (push (downcase (expand-file-name target)) expected)
           (unless (and (file-regular-p target)
                        (org-museum--files-have-same-content-p
                         (org-museum-asset-local-path asset) target))
             (unless (file-exists-p target)
               (push target org-museum--asset-created-files))
             (org-museum--copy-file-atomically
              (org-museum-asset-local-path asset) target))))
       org-museum--asset-registry))
    (when cleanup
      (dolist (file (directory-files root t "^[^.].*" t))
        (when (and (file-regular-p file)
                   (not (member (downcase (expand-file-name file)) expected)))
          (delete-file file))))
    root))

(defun org-museum--asset-to-alist (asset)
  "Return public deterministic JSON data for ASSET."
  `((id . ,(org-museum-asset-id asset))
    (filename . ,(org-museum-asset-filename asset))
    (mime . ,(org-museum-asset-mime asset))
    (kind . ,(symbol-name (org-museum-asset-kind asset)))
    (size . ,(org-museum-asset-size asset))
    (sha256 . ,(org-museum-asset-sha256 asset))
    (source_path . ,(org-museum-asset-source-path asset))
    (published_url . ,(org-museum-asset-published-url asset))
    (thumbnail . ,(org-museum-asset-thumbnail asset))
    (width . ,(org-museum-asset-width asset))
    (height . ,(org-museum-asset-height asset))
    (duration . ,(org-museum-asset-duration asset))
    (filenames . ,(vconcat (org-museum-asset-filenames asset)))
    (sources . ,(vconcat (org-museum-asset-sources asset)))))

(defun org-museum--write-assets-manifest ()
  "Write stable assets.json for the current registry and page map."
  (let (assets pages)
    (when org-museum--asset-registry
      (maphash (lambda (_id asset) (push asset assets))
               org-museum--asset-registry))
    (setq assets (sort assets (lambda (left right)
                               (string< (org-museum-asset-id left)
                                        (org-museum-asset-id right)))))
    (when org-museum--page-assets
      (maphash (lambda (page-id ids)
                 (when ids
                   (push (cons page-id (vconcat ids)) pages)))
               org-museum--page-assets))
    (setq pages (sort pages (lambda (left right) (string< (car left) (car right)))))
    (make-directory (org-museum--shared-root) t)
    (org-museum--write-content-if-changed
     (org-museum--assets-manifest-path)
     (let ((json-encoding-pretty-print nil))
       (concat (json-encode
                `((schema_version . 1)
                  (assets . ,(vconcat (mapcar #'org-museum--asset-to-alist assets)))
                  (pages . ,pages)))
               "\n")))))

(defun org-museum--load-assets-manifest ()
  "Merge an existing public assets.json into the dynamically bound registries."
  (let ((manifest (org-museum--assets-manifest-path)))
    (when (file-regular-p manifest)
      (with-temp-buffer
        (insert-file-contents manifest)
        (let* ((json-object-type 'alist)
               (json-array-type 'list)
               (json-key-type 'string)
               (data (json-read))
               (assets (alist-get "assets" data nil nil #'string=))
               (pages (alist-get "pages" data nil nil #'string=)))
          (dolist (record assets)
            (let* ((id (alist-get "id" record nil nil #'string=))
                   (sha (alist-get "sha256" record nil nil #'string=))
                   (published (alist-get "published_url" record nil nil #'string=))
                   (local (and published
                               (expand-file-name published
                                                 (org-museum--shared-root))))
                   (assets-root (org-museum--assets-root))
                   (assets-prefix
                    (concat
                     (string-remove-suffix
                      "/" (replace-regexp-in-string
                           "\\\\" "/" org-museum-assets-subdir))
                     "/"))
                   (valid
                    (and (stringp id)
                         (string-match-p "\\`[0-9a-f]\\{64\\}\\'" id)
                         (equal id sha)
                         (stringp published)
                         (string-prefix-p assets-prefix published)
                         (string-match-p
                          (format "\\`%s%s\\.[a-z0-9]+\\'"
                                  (regexp-quote assets-prefix)
                                  (regexp-quote id))
                          published)
                         local (file-regular-p local)
                         (file-in-directory-p local assets-root)
                         (string= id (org-museum--file-content-hash local)))))
              (unless valid
                (signal 'org-museum-asset-error
                        (list (format "Unsafe or corrupt assets.json record: %S"
                                      published))))
              (when valid
                (puthash
                 id
                 (make-org-museum-asset
                  :id id
                  :filename (alist-get "filename" record nil nil #'string=)
                  :mime (alist-get "mime" record nil nil #'string=)
                  :kind (intern (alist-get "kind" record nil nil #'string=))
                  :size (alist-get "size" record nil nil #'string=)
                  :sha256 sha
                  :source-path (alist-get "source_path" record nil nil #'string=)
                  :published-url published
                  :thumbnail (alist-get "thumbnail" record nil nil #'string=)
                  :width (alist-get "width" record nil nil #'string=)
                  :height (alist-get "height" record nil nil #'string=)
                  :duration (alist-get "duration" record nil nil #'string=)
                  :filenames (alist-get "filenames" record nil nil #'string=)
                  :sources (alist-get "sources" record nil nil #'string=)
                  :local-path local)
                 org-museum--asset-registry))))
          (dolist (entry pages)
            (puthash (car entry) (append (cdr entry) nil)
                     org-museum--page-assets)))))))

(defun org-museum--prune-unreferenced-assets ()
  "Remove manifest records not referenced by any page, retaining public files."
  (let ((referenced (make-hash-table :test #'equal)) stale)
    (when org-museum--page-assets
      (maphash (lambda (_page ids)
                 (dolist (id ids) (puthash id t referenced)))
               org-museum--page-assets))
    (when org-museum--asset-registry
      (maphash (lambda (id _asset)
                 (unless (gethash id referenced)
                   (push id stale)))
               org-museum--asset-registry)
      (dolist (id stale)
        (remhash id org-museum--asset-registry)))))

(defun org-museum--report-asset-warnings ()
  "Display all collected asset warnings without hiding build success."
  (when org-museum--asset-warnings
    (let* ((records (nreverse (copy-sequence org-museum--asset-warnings)))
           (count (length records))
           (report
            (concat
             (format "* Asset warnings (%d)\n\n" count)
             (mapconcat
              (lambda (warning)
                (format "- [%s] %s\n  %s\n  %s"
                        (plist-get warning :kind)
                        (plist-get warning :source)
                        (or (plist-get warning :location) "unknown location")
                        (plist-get warning :detail)))
              records "\n"))))
      (with-current-buffer (get-buffer-create "*Org Museum 资源警告*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert report "\n")))
      (when noninteractive
        (princ (concat "\n" report "\n") 'external-debugging-output))
      (message "Org Museum 有 %d 项资源警告，请查看 *Org Museum 资源警告*"
               count))))

(defun org-museum--page-assets-html (page out-file)
  "Return the compact resource section for PAGE relative to OUT-FILE."
  (let ((ids (and page org-museum--page-assets
                  (seq-filter
                   (lambda (id)
                     (when-let* ((asset (gethash id org-museum--asset-registry)))
                       (memq (org-museum-asset-kind asset) '(image video audio))))
                   (gethash (org-museum-page-id page) org-museum--page-assets)))))
    (when ids
      (concat
       "<section class=\"museum-page-assets\" aria-labelledby=\"museum-page-assets-title\">"
       "<div class=\"museum-section-heading\"><p class=\"eyebrow\">资源</p>"
       "<h2 id=\"museum-page-assets-title\">资源</h2></div>"
       "<div class=\"museum-asset-list\">"
       (mapconcat
        (lambda (id)
          (when-let* ((asset (gethash id org-museum--asset-registry)))
            (org-museum--asset-render-html asset out-file nil t)))
        ids "")
       "</div></section>"))))

;;;###autoload
(defun org-museum-refresh-remote-assets (&optional url)
  "Forget the locked remote asset mapping for URL, or all mappings when nil."
  (interactive
   (list (let ((value (read-string "远程资源地址（留空则全部刷新）：")))
           (unless (string-empty-p value) value))))
  (let ((directory (expand-file-name "urls" org-museum-asset-cache-directory))
        (removed 0))
    (if url
        (let ((file (org-museum--asset-cache-url-path url)))
          (when (file-regular-p file) (delete-file file) (setq removed 1)))
      (when (file-directory-p directory)
        (dolist (file (directory-files directory t "\\.json\\'" t))
          (when (file-regular-p file) (delete-file file) (cl-incf removed)))))
    (message "Org Museum 已更新 %d 项远程资源映射" removed)
    removed))

(defun org-museum--scan-root ()
  "Absolute path to the .org scan root."
  (expand-file-name (or org-museum-scan-dir "") org-museum-root-dir))

(defcustom org-museum-scan-excluded-directories
  '(".git" ".cache" "node_modules" "output")
  "Directories relative to the project root omitted from note discovery.
Export directories are always omitted.  Remove an entry if it intentionally
contains source notes; ordinary notes outside the pages directory remain valid."
  :type '(repeat directory)
  :group 'org-museum)

(defun org-museum--scan-files ()
  "Return the complete, de-duplicated set of Org files used by the index."
  (let* ((scan-root (file-name-as-directory (org-museum--scan-root)))
         (project-root (file-name-as-directory
                        (expand-file-name org-museum-root-dir)))
         (excluded
          (cl-remove-if
           (lambda (dir) (or (equal dir project-root) (equal dir scan-root)))
           (mapcar
            (lambda (dir) (file-name-as-directory (expand-file-name dir project-root)))
            (append org-museum-scan-excluded-directories
                    (list org-museum-export-dir org-museum-shared-export-dir)))))
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
        (dolist (file (directory-files-recursively
                      dir "\\.org\\'" nil
                      (lambda (candidate)
                        (not (seq-some
                              (lambda (excluded-dir)
                                (or (equal (file-name-as-directory candidate) excluded-dir)
                                    (file-in-directory-p candidate excluded-dir)))
                              excluded)))))
          (let ((key (org-museum--normalised-path file)))
            (unless (or (string-prefix-p ".#" (file-name-nondirectory file))
                        (gethash key seen))
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
      ;; Org HTML treats a percent-encoded Windows drive colon as a relative
      ;; file URL and prefixes the current drive, producing paths such as
      ;; c:/c:/Users/example/note.md.  A colon cannot name a Windows path
      ;; component, so the leading drive is necessarily exporter noise.
      (when (and (eq system-type 'windows-nt)
                 (string-match
                  "\\`[[:alpha:]]:/\\([[:alpha:]]:/.*\\)\\'" path))
        (setq path (match-string 1 path)))
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
      (and (equal category "uncategorized") "其他笔记")
      category))

(defun org-museum--graph-semantic-category (page)
  "Return a meaningful graph category for PAGE, or the empty string.
An internal fallback category is never exposed as a graph topic."
  (let ((category (string-trim (or (org-museum-page-category page) ""))))
    (cond
     ((and (not (string-empty-p category))
           (not (member (downcase category) '("uncategorized" "未分类"))))
      (org-museum--category-label category))
     (t
      (let* ((relative (file-relative-name
                        (org-museum-page-path page)
                        (expand-file-name org-museum-pages-subdir
                                          org-museum-root-dir)))
             (parts (split-string (or (file-name-directory relative) "") "[/\\\\]" t))
             (folder (car parts)))
        (if (and folder (not (member (downcase folder)
                                     '("uncategorized" "未分类" "pages"))))
            (org-museum--category-label folder)
          ""))))))

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
                         (path (org-get-outline-path t))
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

(defun org-museum--pp-stabilize-generated-anchors (org-file)
  "Replace remaining transient Org-generated anchors for ORG-FILE.
Org assigns process-random `orgXXXXXXX' IDs to items such as descriptive
lists.  Preserve references while deriving replacements from the page and
document order so clean builds are byte-identical."
  (let ((page-key (if-let* ((page (org-museum--page-for-file org-file)))
                      (org-museum-page-id page)
                    (file-name-base org-file)))
        (seen (make-hash-table :test #'equal))
        (ordinal 0)
        rewrites)
    (goto-char (point-min))
    (while (re-search-forward
            "\\bid=\"\\(org[[:xdigit:]]\\{7,\\}\\)\"" nil t)
      (let ((old-id (match-string-no-properties 1)))
        (unless (gethash old-id seen)
          (setq ordinal (1+ ordinal))
          (puthash old-id t seen)
          (push
           (cons old-id
                 (concat "org-museum-ref-"
                         (substring
                          (secure-hash 'sha256
                                       (format "%s\0%d" page-key ordinal))
                          0 12)))
           rewrites))))
    (dolist (rewrite rewrites)
      (goto-char (point-min))
      (while (search-forward (car rewrite) nil t)
        (replace-match (cdr rewrite) t t)))))

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
    (generatedAt . ,(org-museum--build-time-string "%Y-%m-%dT%H:%M:%S+0000"))
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
  (dolist (name '("resources/vendor/markdown-it.umd.min.js"
                  "resources/vendor/markdown-it.LICENSE"
                  "resources/org-museum-markdown.js"
                  "resources/org-museum-ai.js"
                  "resources/org-museum-ai-browser.js"
                  "resources/org-museum-ai-workspace.js"
                  "resources/org-museum-org-view.js"
                  "resources/org-museum-graph-layout.js"
                  "resources/org-museum-graph-edges.js"
                  "resources/org-museum-graph-network.js"))
    (let ((source (expand-file-name name (org-museum--plugin-dir)))
          (target (expand-file-name name (org-museum--shared-root))))
      (when (and (file-regular-p source)
                 (not (org-museum--files-have-same-content-p source target)))
        (make-directory (file-name-directory target) t)
        (copy-file source target t))))
  (let ((src (org-museum--css-source-path))
        (dst (org-museum--css-output-path)))
    (when (and src (file-exists-p src))
      (make-directory (file-name-directory dst) t)
      (when (or (not (file-exists-p dst))
                (not (org-museum--files-have-same-content-p src dst)))
        (copy-file src dst t)
        (message "Org Museum 样式已更新：%s" dst)))))

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
      (message "正在建立 Org Museum 索引…")
      (setq org-museum--index (org-museum--index-scan))
      (org-museum--index-save org-museum--index index-path)
      (message "Org Museum 索引已建立：%d 篇笔记"
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
  "Return non-nil when INDEX-PATH covers exactly the current source files."
  (let ((index-mtime (org-museum--file-mtime index-path))
        (files (org-museum--scan-files)))
    (and (file-directory-p (org-museum--scan-root))
         (condition-case nil
             (let* ((json-object-type 'alist)
                    (json-array-type 'list)
                    (json-key-type 'symbol)
                    (data (json-read-file index-path))
                    (cached (mapcar (lambda (page)
                                      (org-museum--normalised-path (alist-get 'path page)))
                                    (alist-get 'pages data))))
               (and (= org-museum--index-schema-version
                       (or (alist-get 'schema-version data) -1))
                    (equal (sort cached #'string-lessp)
                           (sort (mapcar #'org-museum--normalised-path files)
                                 #'string-lessp))))
           (error nil))
         (not (cl-some (lambda (f) (> (org-museum--file-mtime f) index-mtime))
                       files))
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
      (message "Org Museum 索引：已跳过知识库外文件 %s" file)
      (cl-return-from org-museum--index-update-file nil))

    (unless org-museum--index
      (condition-case err
          (org-museum-index-build)
        (error
         (message "Org Museum 索引建立失败：%s" (error-message-string err))
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
           (message "Org Museum 索引增量更新失败：%s：%s"
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
  "Export a single Org Museum FILE to HTML.
Interactive calls run in an isolated background Emacs process."
  (interactive (list (buffer-file-name) current-prefix-arg))
  (if (called-interactively-p 'interactive)
      (org-museum--start-background-job 'export-page (list file force))
    (org-museum--run-with-current-runtime
     'org-museum-export-page (list file force)
     (lambda () (org-museum--export-page-current file force)))))

(defun org-museum--export-page-current (file &optional force)
  "Export FILE using the currently loaded runtime."
  (let* ((own-assets (null org-museum--asset-registry))
        (org-museum--asset-registry
         (or org-museum--asset-registry (make-hash-table :test #'equal)))
        (org-museum--page-assets
         (or org-museum--page-assets (make-hash-table :test #'equal)))
        (org-museum--asset-warnings
         (if own-assets nil org-museum--asset-warnings))
        (org-museum--asset-remote-results
         (or org-museum--asset-remote-results
             (make-hash-table :test #'equal)))
        (org-museum--build-time
         (or org-museum--build-time (org-museum--deterministic-build-time))))
    (org-museum--guard-init)
    (when own-assets
      (org-museum--load-assets-manifest))
    (let* ((page-id (org-museum--page-id-for-file file))
           (old-assets (and own-assets
                            (copy-sequence
                             (gethash page-id org-museum--page-assets))))
           asset-changed)
      (when own-assets
        (puthash page-id nil org-museum--page-assets)
        (org-museum--preflight-page-assets file)
        (setq asset-changed
              (not (equal old-assets
                          (gethash page-id org-museum--page-assets)))))
      (org-museum--ensure-css-deployed)
      (org-museum--hljs-assets)
      (let ((out-file (org-museum--export-filename file)))
      (org-museum--ensure-output-path-case out-file (org-museum--pages-root))
      (if (and (not force) (not asset-changed)
               (not (org-museum--needs-export-p file out-file)))
          (message "已跳过未变化的笔记：%s" (file-name-nondirectory file))
        (make-directory (file-name-directory out-file) t)
        (org-museum--export-with-theme file out-file))
      (org-museum--delete-legacy-source-html file out-file)
      (unless org-museum--full-export-in-progress
        (when own-assets
          (org-museum--prune-unreferenced-assets)
          (org-museum--publish-assets nil)
          (org-museum--write-assets-manifest)
          (org-museum--report-asset-warnings))
        (org-museum--export-related-reading-current)
        (org-museum--export-timeline-current))))))
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
  (org-museum--call-preserving-source-mtime
   org-file
   (lambda ()
     (let ((tmp (make-temp-file "org-museum-" nil ".org")))
       (unwind-protect
           (progn
          (with-temp-buffer
            (insert-file-contents org-file)
            (setq buffer-file-name org-file)
            (org-mode)
            (org-museum--prepare-page-assets
             (current-buffer) org-file out-file)
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
                         ;; Org's default exporter comment embeds the wall
                         ;; clock to minute precision and makes otherwise
                         ;; identical clean builds byte-different.
                         (org-export-time-stamp-file          nil)
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
         (when (file-exists-p tmp) (delete-file tmp)))))))

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
    (org-museum--pp-stabilize-generated-anchors org-file)
    (org-museum--pp-wrap-tables)
    (if (not (org-museum--pp-wrap-content-div out-file org-file))
        (progn
          (message "Org Museum 已停止处理 %s：找不到 #content 元素" out-file)
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
      "    <div class=\"museum-meta-tags-item%s\"><dt>标签</dt><dd class=\"museum-meta-tags\">%s</dd></div>\n"
      "  </dl>\n"
      "  <nav class=\"article-back-nav\" aria-label=\"文章返回导航\">\n"
      "    <a data-reading-return href=\"%s#recent-updates\">← 全部笔记</a>\n"
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
     (if tags "" " is-empty")
     (if tags
         (mapconcat
          (lambda (tag)
            (format "<a class=\"museum-tag-chip\" href=\"%s?tag=%s#recent-updates\" data-tag=\"%s\" title=\"查看包含标签 #%s 的笔记\"><span class=\"museum-tag-hash\" aria-hidden=\"true\">#</span><span class=\"museum-tag-name\">%s</span></a>"
                    (org-museum--html-escape home-href t)
                    (url-hexify-string tag)
                    (org-museum--html-escape tag t)
                    (org-museum--html-escape tag t)
                    (org-museum--html-escape tag)))
          tags "")
       "<span class=\"museum-tag-empty\">—</span>")
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
(defun org-museum--org-source-html (org-file)
  "Return the exportable body of ORG-FILE, highlighted by Org font-lock.
Use the Org exporter first so excluded headings, drawers and private export
content cannot leak through the syntax view.  Do not evaluate source blocks."
  (require 'ox-org)
  (let ((source
         (with-temp-buffer
           (insert-file-contents org-file)
           (delay-mode-hooks (org-mode))
           (let ((org-export-use-babel nil))
             (org-export-as 'org nil nil t
                            '(:with-toc nil :with-properties nil :with-drawers nil)))))
        lines)
    (with-temp-buffer
      (insert source)
      (delay-mode-hooks (org-mode))
      (setq-local org-src-fontify-natively t org-hide-leading-stars nil)
      (font-lock-ensure)
      (goto-char (point-min))
      (let (lines (in-block nil))
        (while (< (point) (point-max))
          (let* ((end (line-end-position))
                 (line-class
                  (cond
                   ((looking-at "^\\(\\*+\\)[ \t]")
                    (setq in-block nil)
                    (format "museum-org-line museum-org-heading museum-org-heading-%d"
                            (min 8 (- (match-end 1) (match-beginning 1)))))
                   ((looking-at "^[ \t]*#\\+begin_")
                    (setq in-block t)
                    "museum-org-line museum-org-block-delimiter")
                   ((looking-at "^[ \t]*#\\+end_")
                    (setq in-block nil)
                    "museum-org-line museum-org-block-delimiter")
                   (in-block
                    "museum-org-line museum-org-block-line")
                   ((looking-at "^[ \t]*|")
                    "museum-org-line museum-org-table-line")
                   ((looking-at "^[ \t]*#\\+")
                    "museum-org-line museum-org-meta-line")
                   ((looking-at "^[ \t]*:[A-Z_]+:[ \t]*$")
                    "museum-org-line museum-org-drawer-line")
                   (t "museum-org-line")))
                 fragments)
            (while (< (point) end)
              (let* ((begin (point))
                     (next (next-property-change begin nil end))
                     (face (or (get-text-property begin 'face)
                               (get-text-property begin 'font-lock-face)))
                     (faces (seq-filter #'symbolp (if (listp face) face (list face))))
                     (classes (mapconcat
                               (lambda (item) (concat "org-face-" (replace-regexp-in-string
                                               "[^a-zA-Z0-9_-]" "-" (symbol-name item))))
                               (delq nil faces) " "))
                     (text (org-museum--html-escape (buffer-substring-no-properties begin next))))
                (push (if (string-empty-p classes) text
                        (format "<span class=\"%s\">%s</span>" classes text)) fragments)
                (goto-char next)))
            (push (concat "<span class=\"" line-class "\">"
                          (if fragments
                              (apply #'concat (nreverse fragments))
                            "&nbsp;")
                          "</span>\n") lines)
            (forward-line 1)))
        (concat (format "<section class=\"museum-org-view\" hidden aria-label=\"Org Mode 正文\" data-source-hash=\"%s\">"
                        (org-museum-knowledge--file-hash org-file))
              "<pre class=\"museum-org-source\" tabindex=\"0\"><code>"
              (apply #'concat (nreverse lines)) "</code></pre></section>")))))

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
          meta
          (when (file-readable-p org-file)
            (concat
             "<div class=\"museum-article-view-toolbar\" role=\"group\" aria-label=\"正文显示方式\">"
             "<button type=\"button\" data-article-syntax aria-pressed=\"false\">切换为 Org Mode</button>"
             "<button type=\"button\" data-org-copy hidden>复制 Org 正文</button>"
             "<button type=\"button\" data-org-toggle-blocks aria-pressed=\"false\" hidden>展开全部代码</button>"
             "<button type=\"button\" data-org-wrap aria-pressed=\"true\" hidden>自动换行</button>"
             "<span data-org-view-status role=\"status\" aria-live=\"polite\"></span></div>"
             (org-museum--org-source-html org-file)))))
        t)
    (message "Org Museum 后处理：%s 中找不到 #content，请检查 Org 导出结果" out-file)
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
         (assets-html (when page
                        (org-museum--page-assets-html page out-file)))
         (knowledge-html (when (fboundp 'org-museum-knowledge--page-html)
                           (org-museum-knowledge--page-html page out-file)))
         (appended  (concat (or knowledge-html "") (or assets-html "")
                            (or nav-html "") (or graph-html ""))))
    (goto-char (point-max))
    (cond
     ((re-search-backward "</div>\\([\n\r\t ]*\\)</body>" nil t)
      (replace-match
       (concat
        appended
        "\n</article>\n"
        (org-museum--toc-sidebar-html)
        (org-museum-ai-web--article-panel-html page)
        "</div></main>\\1</body>")))
     (t
      (when (re-search-backward "</div>" nil t)
        (replace-match
         (concat
          appended "\n</article>" (org-museum--toc-sidebar-html)
          (org-museum-ai-web--article-panel-html page)
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
    (user-error "索引为空，无法清理过期页面"))
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
      (user-error "页面目录的上级目录不存在，无法清理"))
    (when (file-symlink-p pages-root)
      (user-error "页面目录是符号链接，无法清理"))
    (unless (file-in-directory-p
             (file-truename existing-parent) project-root)
      (user-error "无法清理知识库目录外的页面"))
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
      (with-current-buffer (get-buffer-create "*Org Museum 过期导出*")
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
          (generatedAt . ,(org-museum--build-time-string "%Y-%m-%dT%H:%M:%S+0000"))
          (pagesRoot . ,(replace-regexp-in-string
                         "\\\\" "/"
                         (file-relative-name pages-root
                                             (org-museum--shared-root))))
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
    (message "Org Museum 已清理 %d 个过期页面" deleted)
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
  "Export the entire Org Museum as a static HTML site.
Interactive calls run in an isolated background Emacs process."
  (interactive)
  (if (called-interactively-p 'interactive)
      (org-museum--start-background-job 'export-all nil)
    (org-museum--run-with-current-runtime
     'org-museum-export-all nil #'org-museum--export-all-current)))

(defun org-museum--publish-normalise-relative-path (path)
  "Return PATH with portable separators, or nil when it is unsafe."
  (let ((normalised (replace-regexp-in-string "\\\\" "/" path)))
    (when (and (not (file-name-absolute-p path))
               (not (string-prefix-p "/" normalised))
               (not (member ".." (split-string normalised "/" t))))
      normalised)))

(defun org-museum--ensure-output-path-case (file root)
  "Preserve FILE's exact spelling below ROOT on case-insensitive Windows.
Existing directories retain their old spelling when merely overwritten.
Rename through a temporary sibling so exported URLs work on Linux hosts."
  (when (eq system-type 'windows-nt)
    (unless (string-prefix-p
             (file-name-as-directory (org-museum--normalised-path root))
             (org-museum--normalised-path file))
      (signal 'org-museum-publish-error '("Output path escapes its root")))
    (let ((parent (file-name-as-directory (expand-file-name root))))
      (dolist (component (split-string (file-relative-name file parent) "/" t))
        (when (file-directory-p parent)
          (let* ((entries (directory-files parent nil nil t))
                 (actual (cl-find component entries :test #'string-equal-ignore-case)))
            (when (and actual (not (equal actual component)))
              (let ((old (expand-file-name actual parent))
                    (desired (expand-file-name component parent))
                    (temporary (make-temp-name (expand-file-name ".museum-case-" parent))))
                (when (file-symlink-p old)
                  (signal 'org-museum-publish-error '("Linked output path cannot be renamed")))
                (rename-file old temporary)
                (condition-case err
                    (rename-file temporary desired)
                  (error (rename-file temporary old) (signal (car err) (cdr err))))))))
        (setq parent (file-name-as-directory (expand-file-name component parent)))))))

(defun org-museum--publish-managed-relative-path-p (path)
  "Return non-nil when relative PATH is owned by Org Museum publishing."
  (when-let* ((relative (org-museum--publish-normalise-relative-path path)))
    (or (member relative
                (list "index.html" "timeline.html" "graph.html" "related.html"
                      "ai-center.html" "ai-public.json"
                      "assets.json" ".nojekyll"
                      org-museum--publish-status-name))
        (string-prefix-p "pages/" relative)
        (string-prefix-p "resources/" relative)
        (when-let* ((assets
                     (org-museum--publish-normalise-relative-path
                      org-museum-assets-subdir)))
          (string-prefix-p (concat (string-remove-suffix "/" assets) "/")
                           relative)))))

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
  (let* ((required (mapcar (lambda (name) (expand-file-name name export-root))
                           '("index.html" "timeline.html" "graph.html" "related.html")))
         (ai-files (mapcar (lambda (name) (expand-file-name name export-root))
                           '("ai-center.html" "ai-public.json"))))
    (dolist (file required)
      (when (or (file-symlink-p file) (not (file-regular-p file)))
        (signal 'org-museum-publish-error
                (list (format "Required export file is missing or unsafe: %s"
                              file)))))
    (when (cl-some #'file-exists-p ai-files)
      (unless (cl-every (lambda (file)
                          (and (file-regular-p file) (not (file-symlink-p file))))
                        ai-files)
        (signal 'org-museum-publish-error
                '("AI Center export is incomplete; export the site again"))))
    (append required (when (cl-every #'file-regular-p ai-files) ai-files)
            (let ((manifest (expand-file-name "assets.json" export-root)))
              (when (file-regular-p manifest) (list manifest)))
            (org-museum--publish-tree-files export-root "pages")
            (org-museum--publish-tree-files export-root "resources")
            (let ((assets-relative
                   (org-museum--publish-normalise-relative-path
                    org-museum-assets-subdir)))
              (when (and assets-relative
                         (file-directory-p
                          (expand-file-name assets-relative export-root)))
                (org-museum--publish-tree-files
                 export-root assets-relative))))))

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
          ;; Org also autolinks bare file URLs embedded in imported Markdown-
          ;; style or tool-reference text.  Attribute those URLs to their real
          ;; source line instead of reporting the exported anchor as generated.
          (goto-char (point-min))
          (while (re-search-forward
                  "file:/+[^][()<>\"'[:space:]\n\r]+" nil t)
            (let ((position (match-beginning 0))
                  (target (org-museum--file-url-to-path (match-string 0))))
              (when (and target
                         (equal normal-needle
                                (org-museum--normalised-path target)))
                (record position 'local-file-link))))
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
            "file:///[A-Za-z]:[/\\\\][^<>\"'\n\r]+" 0)
           (data-local-path
            "data-local-path=\\\"\\([A-Za-z]:[^\"\n\r]+\\)\\\"" 1)
           (windows-path
            "\\(?:\\`\\|[^[:alnum:]?]\\)\\([A-Za-z]:[/\\\\][^<>:\"/\\\\|?*\n\r][^<>\"'\n\r[:space:]]*\\)" 1)
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
                   "ai-center.html" "ai-public.json"
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
                  (read-string "这项内容为何可以公开？"))))
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
    (message "Org Museum 已允许这项检查结果；请重新完整同步")))

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
    (message "Org Museum 已撤销这项允许；请重新完整同步")))

(defun org-museum--publish-policy-exclude-button (button)
  "Add BUTTON's exact published path to the local policy exclusions."
  (let* ((policy (org-museum--publish-read-policy))
         (relative (button-get button 'org-museum-relative)))
    (unless (member relative (plist-get policy :exclude))
      (setf (plist-get policy :exclude)
            (append (plist-get policy :exclude) (list relative)))
      (org-museum--publish-write-policy policy))
    (message "Org Museum 已排除 %s；请重新完整同步" relative)))

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
            '("发布隐私检查状态无效")))
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
                (list "index.html" "timeline.html" "graph.html" "related.html"
                      "ai-center.html" "ai-public.json" "assets.json" ".nojekyll"
                         org-museum--publish-status-name)
                   for file = (expand-file-name relative root)
                   when (or (file-exists-p file) (file-symlink-p file))
                   collect relative))
         (tree-files
          (cl-loop for relative in (delete-dups (list "pages" "resources" org-museum-assets-subdir))
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

(defun org-museum--publish-validate-page-links (root managed-files)
  "Reject local HTML links absent from the exact-case public file set.
Do not use Windows file existence checks: the deployment host is case-sensitive."
  (dolist (relative managed-files)
    (when (string-suffix-p ".html" relative)
      (let ((file (expand-file-name relative root)))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (re-search-forward "\\(?:href\\|src\\)=[\"']\\([^\"']+\\)[\"']" nil t)
            (let ((href (match-string-no-properties 1)))
              (when (and (not (string-match-p "\\`\\(?:[a-zA-Z][a-zA-Z0-9+.-]*:\\|//\\|#\\)" href))
                         (string-match-p "\\.html\\(?:[?#].*\\)?\\'" href))
                (let* ((path (car (split-string href "[?#]")))
                       (decoded (decode-coding-string (url-unhex-string path) 'utf-8))
                       (target (expand-file-name decoded (file-name-directory file)))
                       (target-relative (file-relative-name target root)))
                  (unless (and (file-in-directory-p target root)
                               (member target-relative managed-files))
                    (signal 'org-museum-publish-error
                            (list (format "Broken or case-mismatched page link: %s -> %s"
                                          relative href)))))))))))))

(defun org-museum--publish-managed-namespace-files (root)
  "Return every existing file in ROOT's managed publishing namespaces."
  (let (relative-files)
    (dolist (relative (list "index.html" "timeline.html" "graph.html" "related.html"
                            "ai-center.html" "ai-public.json" "assets.json" ".nojekyll"
                            org-museum--publish-status-name))
      (let ((file (expand-file-name relative root)))
        (when (or (file-exists-p file) (file-symlink-p file))
          (unless (and (file-regular-p file) (not (file-symlink-p file)))
            (signal 'org-museum-publish-error
                    (list (format "Unsafe managed publish entry: %s" relative))))
          (push relative relative-files))))
    (dolist (tree (delete-dups (list "pages" "resources" org-museum-assets-subdir)))
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
       "<title>Org Museum 公开检查</title></head>"
       "<body><main><h1>Org Museum 公开检查</h1>"
       "<p>本页包含仅适用于本机的引用，已在发布候选中安全隐藏。</p>"
       "<p>请返回 Emacs 查看 Org Museum 隐私报告，并修正源笔记。</p>"
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
         (stale (cl-remove-if
                 (lambda (old)
                   (cl-some (lambda (current)
                              (equal (org-museum--publish-path-key old)
                                     (org-museum--publish-path-key current)))
                            managed-files))
                 old-files))
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
          (dolist (relative managed-files)
            (org-museum--ensure-output-path-case
             (expand-file-name relative publish-root) publish-root))
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
  "Export and safely mirror a ready or privacy-blocked preview.
Interactive calls run in an isolated background Emacs process."
  (interactive)
  (if (called-interactively-p 'interactive)
      (org-museum--start-background-job 'publish-sync nil)
    (org-museum--publish-sync-current)))

(defun org-museum--publish-sync-current ()
  "Synchronously build the privacy-checked publish mirror."
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
                    (when org-museum--background-worker-active
                      (with-current-buffer report
                        (princ (concat "\n" (buffer-string) "\n"))))
                    (message
                     "Org Museum 安全预览已更新；有 %d 项隐私检查结果阻止部署"
                     (length findings))
                    nil)
                (message "Org Museum 发布同步完成：%s" publish-root)
                publish-root))))
      (when (file-directory-p staging-root)
        (delete-directory staging-root t)))))

;;;###autoload
(defun org-museum-publish-sync-full (&optional interactive-invocation)
  "Queue a configurable byte-for-byte local publish mirror.
Unlike `org-museum-publish-sync', this command does not replace or remove
selected files merely because privacy findings remain.  It always previews the
effective sharing scope and requires the exact high-risk confirmation phrase.
Unresolved findings produce a `review-required' state that cannot be deployed.
Interactive calls run in an isolated background Emacs process."
  (interactive (list t))
  (if (called-interactively-p 'interactive)
      (progn
        (unless (equal (read-string
                        (format "Type %s to queue full sync: "
                                org-museum--publish-full-confirmation))
                       org-museum--publish-full-confirmation)
          (signal 'org-museum-publish-error
                  '("完整同步确认口令不匹配，任务未启动")))
        (org-museum--start-background-job 'publish-sync-full nil))
    (org-museum--publish-sync-full-current interactive-invocation)))

(defun org-museum--publish-sync-full-current (&optional interactive-invocation)
  "Synchronously install the configurable full publish mirror."
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
            (if org-museum--background-worker-active
                (with-current-buffer preview
                  (princ (concat "\n" (buffer-string) "\n")))
              (pop-to-buffer preview)))
          (when (plist-get change-plan :conflicts)
            (signal
             'org-museum-publish-error
             (list
              (format
               "Full sync stopped before confirmation: managed files were edited after the last sync: %s"
               (mapconcat #'identity
                          (plist-get change-plan :conflicts) ", ")))))
          (unless (or org-museum--background-full-sync-preapproved
                      (equal (read-string
                              (format "请输入 %s 以继续："
                                      org-museum--publish-full-confirmation))
                             org-museum--publish-full-confirmation))
            (signal 'org-museum-publish-error
                    '("完整同步确认口令不匹配，文件未变更")))
          (org-museum--publish-apply-staging
           staging-root publish-root relative-files old-files)
          (message "Org Museum 完整镜像已更新：%s（%s）"
                   publish-root
                   (pcase state
                     ('ready "可发布")
                     ('review-required "需复核")
                     (_ "待处理")))
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
         (buffer (get-buffer-create "*Org Museum 发布*"))
         (process-buffer (generate-new-buffer " *Org Museum 发布进程*"))
         (accepted (or accepted-statuses '(0)))
         status raw-output log-output)
    (unwind-protect
        (progn
          ;; Git and GitHub CLI emit UTF-8 paths.  On Windows, leaving process
          ;; decoding implicit can preserve those bytes as a unibyte string,
          ;; so managed Chinese paths no longer compare equal to JSON paths.
          ;; On Windows, child arguments need the ANSI code page.  The
          ;; console locale can be UTF-8 while Git still decodes argv as ANSI.
          (let ((coding-system-for-read 'utf-8)
                (coding-system-for-write
                 (if (and (eq system-type 'windows-nt)
                          (boundp 'w32-ansi-code-page))
                     (intern (format "cp%d" w32-ansi-code-page))
                   locale-coding-system)))
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

(defun org-museum--publish-push (branch)
  "Push BRANCH, retrying one known transient GitHub ref failure.
Other Git failures remain fatal on the first attempt."
  (let* ((arguments (list "push" "-u" org-museum-publish-remote branch))
         (result (org-museum--publish-run "git" arguments '(0 1)))
         (status (car result))
         (output (cdr result)))
    (cond
     ((zerop status) result)
     ((string-match-p "remote: fatal error in commit_refs" output)
      (message "GitHub 未能提交远端引用，正在重试推送一次…")
      ;; Deploy normally runs in an isolated background Emacs process, so this
      ;; brief backoff never stalls the user's editing session.
      (sleep-for 2)
      (org-museum--publish-run "git" arguments))
     (t
      (signal 'org-museum-publish-error
              (list (format "git failed (%s): %s"
                            status
                            (string-trim
                             (org-museum--publish-redact-command-output
                              output)))))))))

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
  (or org-museum--background-bootstrap-preapproved
      (y-or-n-p
       (format "Create PUBLIC GitHub repository %s from %s? "
               repository directory))))

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

(defun org-museum--publish-local-git-config (key)
  "Return repository-local Git configuration KEY, or nil when unset."
  (pcase-let ((`(,status . ,output)
               (org-museum--publish-run
                "git" (list "config" "--local" "--get" key) '(0 1))))
    (when (= status 0)
      (let ((value (string-trim output)))
        (unless (string-empty-p value) value)))))

(defun org-museum--publish-github-identity ()
  "Return authenticated GitHub (ID LOGIN), or nil when unavailable."
  (pcase-let ((`(,status . ,output)
               (org-museum--publish-run
                "gh" '("api" "user" "--jq" "[.id, .login] | @tsv") '(0 1))))
    (when (= status 0)
      (let ((parts (split-string (string-trim output) "[\t\r\n]+" t)))
        (when (and (= (length parts) 2)
                   (string-match-p "\\`[0-9]+\\'" (car parts))
                   (string-match-p "\\`[[:alnum:]_.-]+\\'" (cadr parts)))
          parts)))))

(defun org-museum--publish-ensure-git-identity (repository)
  "Ensure REPOSITORY can commit using repository-local Git identity.
Existing local values are preserved.  Missing values are derived from the
configured fallbacks, authenticated GitHub account, or repository owner."
  (let* ((owner (car (split-string repository "/" t)))
         (local-name (org-museum--publish-local-git-config "user.name"))
         (local-email (org-museum--publish-local-git-config "user.email"))
         (configured-name
          (and (stringp org-museum-publish-git-user-name)
               (not (string-empty-p org-museum-publish-git-user-name))
               org-museum-publish-git-user-name))
         (configured-email
          (and (stringp org-museum-publish-git-user-email)
               (not (string-empty-p org-museum-publish-git-user-email))
               org-museum-publish-git-user-email))
         (github (unless (and (or local-name configured-name)
                              (or local-email configured-email))
                   (org-museum--publish-github-identity)))
         (github-id (car github))
         (github-login (cadr github))
         (name (or local-name configured-name github-login owner))
         (email (or local-email configured-email
                    (and github-id github-login
                         (format "%s+%s@users.noreply.github.com"
                                 github-id github-login))
                    (format "%s@users.noreply.github.com" owner))))
    (unless local-name
      (org-museum--publish-run
       "git" (list "config" "--local" "user.name" name)))
    (unless local-email
      (org-museum--publish-run
       "git" (list "config" "--local" "user.email" email)))
    (cons name email)))

(defun org-museum--publish-stage-and-commit (paths)
  "Stage validated PATHS and commit them; return non-nil when committed."
  (when paths
    (let ((current (org-museum--publish-read-managed-files org-museum-publish-directory)))
      (when (eq system-type 'windows-nt)
        (let ((tracked (split-string
                        (cdr (org-museum--publish-run "git" '("ls-files" "-z"))) "\0" t))
              aliases replacements)
          (dolist (old tracked)
            (when-let* ((desired (cl-find old current :test #'string-equal-ignore-case)))
              (unless (equal old desired)
                (push old aliases)
                (push desired replacements))))
          (when aliases
            ;; Remove only the obsolete index spelling, keeping all disk files.
            (org-museum--publish-run
             "git" (append '("update-index" "--force-remove" "--") aliases))
            (setq paths (append (cl-set-difference paths aliases :test #'equal)
                                replacements)))))
      (org-museum--publish-run "git" (append '("--literal-pathspecs" "add" "-A" "--") paths))
      (when (eq system-type 'windows-nt)
        (let* ((tracked (split-string
                         (cdr (org-museum--publish-run "git" '("ls-files" "-z"))) "\0" t))
               (missing (cl-set-difference current tracked :test #'equal)))
          (when missing
            (signal 'org-museum-publish-error
                    (list (format "Git index does not preserve publish path spelling: %s"
                                  (mapconcat #'identity missing ", ")))))))))
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
  "Commit, push, and configure the managed GitHub Pages mirror.
Interactive calls run in an isolated background Emacs process."
  (interactive)
  (if (called-interactively-p 'interactive)
      (pcase-let* ((`(,directory ,repository ,_branch)
                    (org-museum--publish-repository-config))
                   (needs-bootstrap
                    (not (file-directory-p (expand-file-name ".git" directory))))
                   (approved
                    (and needs-bootstrap
                         (org-museum--publish-confirm-bootstrap
                          repository directory))))
        (when (and needs-bootstrap (not approved))
          (signal 'org-museum-publish-error
                  '("已取消创建 GitHub 仓库")))
        (org-museum--start-background-job 'publish-deploy (list approved)))
    (org-museum--publish-deploy-current)))

(defun org-museum--publish-deploy-current ()
  "Synchronously deploy the validated publish mirror."
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
             "完整同步的公开检查尚未完成：%s。请处理、排除或明确允许每项检查结果，然后重新同步"
             (mapconcat #'identity (plist-get status :blocked-pages) ", "))
          (format
           "发布隐私检查未通过：%s。修正源笔记后，请重新运行 org-museum-publish-sync"
           (mapconcat #'identity (plist-get status :blocked-pages) ", "))))))
    (org-museum--publish-validate-manifest-integrity directory manifest)
    (org-museum--publish-validate-page-links directory current)
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
      (org-museum--publish-ensure-git-identity repository)
      (let ((committed (org-museum--publish-stage-and-commit dirty)))
        ;; Always push: this also safely retries a commit left ahead after a
        ;; previous network failure.  Git is a no-op when both sides match.
        (org-museum--publish-push branch)
        (org-museum--publish-configure-pages repository branch)
        (let* ((sha (string-trim
                     (cdr (org-museum--publish-run
                           "git" '("rev-parse" "HEAD")))))
               (repository-url (format "https://github.com/%s" repository))
               (owner-and-repo (split-string repository "/" t))
               (url (format "https://%s.github.io/%s/"
                            (car owner-and-repo) (cadr owner-and-repo))))
          (with-current-buffer (get-buffer-create "*Org Museum 发布*")
            (goto-char (point-max))
            (insert (format
                     "\nDeploy complete%s\nCommit: %s\nRepository: %s\nSite: %s\n"
                     (if committed "" " (no content changes)")
                     sha repository-url url)))
          (message "Org Museum 部署完成%s：%s（%s）"
                   (if committed "" "（内容未变化）") url sha)
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
                 (expand-file-name "resources/vendor/markdown-it.umd.min.js" (org-museum--shared-root))
                 (expand-file-name "resources/vendor/markdown-it.LICENSE" (org-museum--shared-root))
                 (expand-file-name "resources/org-museum-markdown.js" (org-museum--shared-root))
                 (expand-file-name "resources/org-museum-ai.js" (org-museum--shared-root))
                 (expand-file-name "index.html" (org-museum--shared-root))
                 (expand-file-name "ai-center.html" (org-museum--shared-root))
                 (expand-file-name "ai-public.json" (org-museum--shared-root))
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
         (asset-targets
          (cons (org-museum--assets-manifest-path)
                (when (file-directory-p (org-museum--assets-root))
                  (directory-files-recursively
                   (org-museum--assets-root) "." nil))))
         (cleanup-targets
          (when org-museum-clean-stale-html-on-full-export
            (org-museum--existing-safe-page-html-files)))
         (targets (delete-dups
                   (append static-targets page-targets asset-targets
                           cleanup-targets)))
         (snapshots (org-museum--snapshot-files targets))
         (preexisting (make-hash-table :test #'equal))
         (original-index org-museum--index)
         (org-museum--asset-created-files nil))
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
       (dolist (file org-museum--asset-created-files)
         (when (file-regular-p file) (delete-file file)))
       (if (eq (car err) 'org-museum-export-failed)
           (signal (car err) (cdr err))
         (signal 'org-museum-export-failed
                 (list (error-message-string err) err)))))))

(defun org-museum--export-all-transaction ()
  "Export the complete site using the currently loaded runtime."
  (let ((org-museum--resource-deployment-cache (make-hash-table :test 'eq))
        (org-museum--full-export-in-progress t)
        (org-museum--asset-registry (make-hash-table :test #'equal))
        (org-museum--page-assets (make-hash-table :test #'equal))
        (org-museum--asset-warnings nil)
        (org-museum--asset-remote-results (make-hash-table :test #'equal))
        (org-museum--build-time (org-museum--deterministic-build-time))
        (total   0)
        (success 0)
        (failed  '())
        timings (stage-start (float-time)))
    (org-museum-index-build t)
    (push (cons 'index (- (float-time) stage-start)) timings)
    (setq stage-start (float-time))
    (let (asset-errors)
      (dolist (file (sort (copy-sequence (org-museum--scan-files)) #'string<))
        (condition-case err
            (org-museum--preflight-page-assets file)
          (org-museum-asset-error
           (push (error-message-string err) asset-errors))))
      (when asset-errors
        (signal
         'org-museum-asset-error
         (list
          (format "Asset checks failed (%d):\n%s"
                  (length asset-errors)
                  (mapconcat (lambda (message) (concat "- " message))
                             (nreverse asset-errors) "\n"))))))
    (push (cons 'asset-check (- (float-time) stage-start)) timings)
    (setq stage-start (float-time))
    (org-museum--ensure-css-deployed)
    (org-museum--hljs-assets)
    (org-museum--ensure-d3-deployed)
    (push (cons 'resources (- (float-time) stage-start)) timings)
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
              (org-museum-ai-web--export-center)
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
              (setq stage-start (float-time))
              (org-museum--publish-assets t)
              (org-museum--write-assets-manifest)
              (org-museum--report-asset-warnings)
              (push (cons 'assets (- (float-time) stage-start)) timings)
              (when (> total 0)
                (org-museum--write-export-manifest)
                (when org-museum-clean-stale-html-on-full-export
                  (setq cleaned
                        (org-museum--clean-stale-exports-if-safe)))))
          (error
           (push (list "site-finalization" (error-message-string err) nil)
                 failed))))
      (message "导出完成：%d/%d 篇笔记，%d 篇失败"
               success total (length failed))
      (message "Org Museum 耗时：%s"
               (mapconcat (lambda (entry)
                            (format "%s=%.3fs" (car entry) (cdr entry)))
                          (nreverse timings) ", "))
      (when (> cleaned 0)
        (message "Org Museum 已清理 %d 个过期页面文件" cleaned))
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
  (with-current-buffer (get-buffer-create "*Org Museum 导出失败*")
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
           'action
           (lambda (_button)
             (org-museum--start-background-job
              'export-page (list path t)))))
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
         (ai-href (org-museum--relative-path
                   (expand-file-name "ai-center.html" shared-root) out-file))
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
           "aria-label=\"打开全部笔记\">书架</button>\n"))
          (settings-ai-section
           (if (eq kind 'ai)
               (concat
                "        <div class=\"museum-settings-section museum-settings-ai-section\">\n"
                "          <div class=\"museum-settings-section-title\">模型设置</div>\n"
                "          <form data-browser-config class=\"museum-settings-config-form\">\n"
                "            <div class=\"museum-settings-field\">\n"
                "              <label>接入方式<select name=\"provider\">\n"
                "                <option value=\"compatible\">兼容 OpenAI 的 API / LM Studio</option>\n"
                "                <option value=\"ollama\">Ollama</option>\n"
                "              </select></label>\n"
                "            </div>\n"
                "            <div class=\"museum-settings-field\">\n"
                "              <label>服务地址<input name=\"endpoint\" type=\"url\" required placeholder=\"http://127.0.0.1:1234/v1\"></label>\n"
                "            </div>\n"
                "            <div class=\"museum-settings-field\">\n"
                "              <label>API 密钥（本机服务可留空）<input name=\"key\" type=\"password\" autocomplete=\"off\" spellcheck=\"false\" placeholder=\"留空或输入密钥\"></label>\n"
                "              <small class=\"museum-settings-note\">密钥仅在当前页面有效，不写入笔记。</small>\n"
                "            </div>\n"
                "            <div class=\"museum-ai-action-row\"><button type=\"submit\" data-browser-models>读取模型列表</button></div>\n"
                "            <div class=\"museum-settings-field\">\n"
                "              <label>模型<input name=\"model\" list=\"museum-browser-model-list\" placeholder=\"选择已加载模型或输入模型 ID\" required></label>\n"
                "              <datalist id=\"museum-browser-model-list\"></datalist>\n"
                "            </div>\n"
                "            <div class=\"museum-ai-action-row\">\n"
                "              <button type=\"button\" data-browser-load>加载并测试模型</button>\n"
                "              <button type=\"button\" data-browser-cancel-load hidden>取消加载</button>\n"
                "            </div>\n"
                "            <div class=\"museum-settings-status-box\">\n"
                "              <span class=\"museum-settings-status-indicator\" aria-hidden=\"true\"></span>\n"
                "              <p data-browser-connection role=\"status\" aria-live=\"polite\">尚未连接模型</p>\n"
                "            </div>\n"
                "            <details class=\"museum-settings-details\">\n"
                "              <summary>回答偏好设置</summary>\n"
                "              <div class=\"museum-settings-field\">\n"
                "                <label>系统提示词<textarea name=\"system\" rows=\"3\">依据提供的资料回答，引用笔记标题，区分原文事实与推断；资料不足时明确说明。使用中文。</textarea></label>\n"
                "              </div>\n"
                "            </details>\n"
                "          </form>\n"
                "          <details class=\"museum-settings-details museum-ai-local-tools\">\n"
                "            <summary>本地保存与同步</summary>\n"
                "            <p class=\"museum-settings-note\">会话与结论保存在此浏览器；确认后可同步到 Emacs。</p>\n"
                "            <div class=\"museum-ai-action-row\">\n"
                "              <button type=\"button\" data-browser-backup>导出知识库</button>\n"
                "              <button type=\"button\" data-browser-org-export>导出 Org</button>\n"
                "              <button type=\"button\" data-browser-sync-preview>预览同步</button>\n"
                "            </div>\n"
                "            <label class=\"museum-settings-file-label\">导入知识库备份<input type=\"file\" data-browser-import accept=\"application/json,.json\"></label>\n"
                "            <div data-browser-sync-result></div>\n"
                "          </details>\n"
                "        </div>\n")
             ""))
          (settings-control
           (concat
            "    <details class=\"museum-theme-menu museum-settings-menu\"><summary aria-label=\"设置与外观\" title=\"设置与外观\">"
            "<span class=\"museum-settings-icon\" aria-hidden=\"true\"></span>"
            "<span class=\"museum-settings-label\">设置</span>"
            "</summary>"
            (format "<div class=\"museum-settings-panel%s\">\n" (if (eq kind 'ai) " has-ai" ""))
            "        <div class=\"museum-settings-section\">\n"
            "          <div class=\"museum-settings-section-title\">外观主题</div>\n"
            "          <div class=\"museum-theme-segmented\" role=\"group\">\n"
            "            <button type=\"button\" class=\"museum-theme-segment-btn\" data-theme-system aria-pressed=\"true\">跟随系统</button>\n"
            "            <button type=\"button\" class=\"museum-theme-segment-btn museum-theme-toggle\" "
            "data-theme-toggle aria-label=\"切换为深色主题\">\n"
            "              <span aria-hidden=\"true\" data-theme-icon data-theme-icon-state=\"moon\"></span>\n"
            "              <span data-theme-label>深色</span></button>\n"
            "          </div>\n"
            "        </div>\n"
            settings-ai-section
            "    </div></details>\n")))
    (format
     (concat
      "<header class=\"museum-topbar\" data-home-href=\"%s\">\n"
      "  <a class=\"museum-skip-link\" href=\"#main-content\">跳到正文</a>\n"
      "  <a class=\"museum-wordmark museum-topbar-link\" href=\"%s\">ORG MUSEUM<span>.el</span></a>\n"
      "  <time class=\"museum-today\" datetime=\"%s\" title=\"导出于 %s\">%s</time>\n"
      "%s"
      "  <nav class=\"museum-top-links\" aria-label=\"Wiki 导航\">\n"
      "    <a class=\"museum-topbar-link museum-nav-timeline%s\" href=\"%s\"%s>时间</a>\n"
      "    <a class=\"museum-topbar-link museum-nav-graph%s\" href=\"%s\"%s>图谱</a>\n"
      "    <a class=\"museum-topbar-link museum-nav-related%s\" href=\"%s\"%s>关联阅读</a>\n"
      "    <a class=\"museum-topbar-link museum-nav-ai%s\" href=\"%s\"%s>AI 中心</a>\n"
      "    <a class=\"museum-topbar-link museum-nav-all%s\" href=\"%s\"%s>索引</a>\n"
      "%s"
      "%s"
      "  </nav>\n"
      "</header>\n")
     (org-museum--html-escape home-href t)
     (org-museum--html-escape home-href t)
     (org-museum--build-time-string "%Y-%m-%d")
     (org-museum--build-time-string "%Y.%m.%d")
     (org-museum--build-time-string "%Y.%m.%d")
     (if (eq kind 'home) ""
       (format
        (concat "  <label class=\"museum-search-line\">\n"
                "    <span class=\"sr-only\">%s</span>\n"
                "    <input id=\"org-museum-global-search\" type=\"search\" "
                "placeholder=\"%s\" autocomplete=\"off\" spellcheck=\"false\" "
                "aria-label=\"%s\" aria-keyshortcuts=\"/\">\n"
                "    <kbd aria-hidden=\"true\">/</kbd>\n"
                "  </label>\n")
        search-label placeholder search-label))
     (if (eq kind 'timeline) " is-active" "")
     (org-museum--html-escape timeline-href t)
     (if (eq kind 'timeline) " aria-current=\"page\"" "")
     (if (eq kind 'graph) " is-active" "")
     (org-museum--html-escape graph-href t)
     (if (eq kind 'graph) " aria-current=\"page\"" "")
     (if (eq kind 'related) " is-active" "")
     (org-museum--html-escape related-href t)
     (if (eq kind 'related) " aria-current=\"page\"" "")
     (if (eq kind 'ai) " is-active" "")
     (org-museum--html-escape ai-href t)
     (if (eq kind 'ai) " aria-current=\"page\"" "")
     (if (eq kind 'home) " is-active" "")
     (if (eq kind 'home) "#recent-updates"
       (concat (org-museum--html-escape home-href t) "#recent-updates"))
     (if (eq kind 'home) " data-index-reset aria-current=\"page\"" "")
     drawer-control
     settings-control)))

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
  (let ((tags (org-museum-page-tags page)))
    (format
     (concat
      "<article class=\"museum-index-entry\" data-page-id=\"%s\" "
      "data-category=\"%s\" data-status=\"%s\">\n"
      "  <div class=\"museum-entry-meta\"><span>%02d</span><time datetime=\"%s\">%s</time>%s</div>\n"
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
     (if tags
         (concat
          "<div class=\"museum-entry-tags\">"
          (mapconcat
           (lambda (tag)
             (format
              "<span class=\"museum-tag-chip\"><span class=\"museum-tag-hash\">#</span><span class=\"museum-tag-name\">%s</span></span>"
              (org-museum--html-escape tag)))
           tags "")
          "</div>")
       "")
     (org-museum--html-escape
      (org-museum--page-href (org-museum-page-id page) out-file) t)
     (org-museum--html-escape (org-museum-page-title page))
     (if (org-museum--published-page-p page)
         ""
       "<span class=\"museum-status-badge\">草稿</span>")
     (org-museum--html-escape (org-museum-page-category page) t)
     (org-museum--html-escape
      (org-museum--category-label (org-museum-page-category page))))))


(defun org-museum--script-index ()
  "Return the index dashboard runtime from the bundled local script."
  (let ((path (expand-file-name
               "resources/org-museum-index-dashboard.js" org-museum--plugin-dir)))
    (unless (file-readable-p path)
      (error "找不到 Org Museum 索引运行文件：%s" path))
    (concat "<script>\n"
            (with-temp-buffer
              (insert-file-contents path)
              (buffer-string))
            "</script>\n")))

(defun org-museum--build-index-html (cats graph-href out-file)
  "Return the complete index.html for CATS and GRAPH-HREF."
  (ignore graph-href)
  (let* ((pages (org-museum--sort-pages-by-modified
                 (org-museum--pages-from-categories cats)))
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
     "  <div class=\"museum-index-intro\">\n"
     "    <div><p class=\"museum-index-kicker\">ORG MUSEUM / 索引</p>"
     "<h1>内容索引</h1><p>搜索、筛选与图表联动，逐步缩小笔记范围。</p></div>\n"
     "  </div>\n"
     "  <label class=\"museum-index-search\">"
     "<span class=\"sr-only\">搜索索引</span>"
     "<input id=\"org-museum-global-search\" type=\"search\" "
     "placeholder=\"搜索标题、章节、标签或主题…\" autocomplete=\"off\" "
     "spellcheck=\"false\" aria-label=\"搜索索引\" aria-keyshortcuts=\"/\">"
     "<kbd aria-hidden=\"true\">/</kbd></label>\n"
     "  <section class=\"dashboard-metrics\" aria-label=\"当前结果概览\">"
     "<div><span>当前笔记</span><strong data-dashboard-metric=\"total\">—</strong></div>"
     "<div><span data-dashboard-metric-label=\"recent-created\">近 30 天新增</span><strong data-dashboard-metric=\"recent-created\">—</strong></div>"
     "<div><span data-dashboard-metric-label=\"recent-updated\">近 30 天更新</span><strong data-dashboard-metric=\"recent-updated\">—</strong></div>"
     "</section>\n"
     "  <div class=\"museum-index-dashboard\">\n"
     "  <details class=\"dashboard-filter-panel\" aria-label=\"筛选笔记\" open>\n"
     "    <summary class=\"dashboard-filter-head\"><h2>筛选笔记</h2>"
     "<span>选择条件后，图表与结果同步更新</span></summary>\n"
     "    <div id=\"index-dynamic-filters\" class=\"dashboard-filter-groups\"></div>\n"
     "    <section class=\"dashboard-date-filter\" aria-label=\"按新增或更新时间筛选\">\n"
     "      <h3>新增 / 更新时间</h3>\n"
     "      <div class=\"dashboard-date-shortcuts\" role=\"group\" aria-label=\"快捷时间范围\">\n"
     "        <button type=\"button\" class=\"dashboard-date-shortcut\" id=\"index-recent-7\" data-range-days=\"7\" aria-pressed=\"false\">近 7 天</button>\n"
     "        <button type=\"button\" class=\"dashboard-date-shortcut\" id=\"index-recent-30\" data-range-days=\"30\" aria-pressed=\"false\">近 30 天</button>\n"
     "        <button type=\"button\" class=\"dashboard-date-shortcut\" id=\"index-recent-90\" data-range-days=\"90\" aria-pressed=\"false\">近 90 天</button>\n"
     "        <button type=\"button\" class=\"dashboard-date-shortcut\" id=\"index-recent-180\" data-range-days=\"180\" aria-pressed=\"false\">近半年</button>\n"
     "        <button type=\"button\" class=\"dashboard-date-shortcut\" id=\"index-recent-365\" data-range-days=\"365\" aria-pressed=\"false\">近 1 年</button>\n"
     "      </div>\n"
     "      <div class=\"dashboard-date-fields\"><label>从<input type=\"date\" id=\"index-date-start\"></label>\n"
     "      <label>到<input type=\"date\" id=\"index-date-end\" aria-describedby=\"index-date-feedback\"></label></div>\n"
     "      <p id=\"index-date-feedback\" class=\"dashboard-date-feedback\" role=\"alert\" hidden></p>\n"
     "      <button type=\"button\" id=\"index-date-clear\" hidden>清除时间范围</button>\n"
     "    </section>\n"
     "  </details>\n"
     "  <section id=\"recent-updates\" class=\"museum-recent\">\n"
     "    <div class=\"dashboard-chart-grid\">"
     "<section class=\"dashboard-chart-panel\" aria-labelledby=\"index-type-title\">"
     "<div class=\"dashboard-chart-head\"><h2 id=\"index-type-title\">主题分布</h2>"
     "<span id=\"index-type-caption\">点击主题筛选</span></div><div id=\"index-type-chart\" class=\"dashboard-type-chart\"></div>"
     "<button type=\"button\" id=\"index-type-expand\" hidden>查看全部主题</button>"
     "</section>"
     "<section class=\"dashboard-chart-panel\" aria-labelledby=\"index-trend-title\">"
     "<div class=\"dashboard-chart-head\"><h2 id=\"index-trend-title\">新增 / 更新趋势</h2>"
     "<span id=\"index-trend-caption\">点击时间筛选</span></div>"
     "<div class=\"dashboard-trend-legend\"><span><i class=\"dashboard-legend-created\"></i>新增</span>"
     "<span><i class=\"dashboard-legend-updated\"></i>更新</span></div>"
     "<div class=\"dashboard-trend-body\"><div id=\"index-trend-axis\" class=\"dashboard-trend-axis\" "
     "aria-hidden=\"true\"></div><div id=\"index-trend-chart\" class=\"dashboard-trend-chart\"></div></div>"
     "</section></div>\n"
     "    <div id=\"index-filter-summary\" class=\"museum-filter-summary\">\n"
     "      <span>当前筛选</span><div id=\"index-filter-chips\"></div>\n"
     "      <button type=\"button\" data-clear-index-filters hidden>清除全部</button>\n"
     "    </div>\n"
     "    <div class=\"museum-index-toolbar\">\n"
     "      <div class=\"museum-section-heading museum-section-rule\">"
     "<h2 id=\"index-results-heading\" tabindex=\"-1\">全部笔记 · 按更新时间</h2>"
     "<span id=\"index-visible-count\" role=\"status\" aria-live=\"polite\">"
     (format "%d" (length recent))
     "</span></div>\n"
     "      <label class=\"dashboard-sort\">排序 <select id=\"index-sort\">"
     "<option value=\"modified-desc\">最近更新</option>"
     "<option value=\"created-desc\">最近新增</option>"
     "<option value=\"title-asc\">标题</option>"
     "</select></label>\n"
     "    </div>\n"
     "    <div class=\"museum-index-matrix\">\n"
     recent-html
     "    </div>\n"
     "    <div id=\"index-search-list\" hidden></div>\n"
     "    <p id=\"index-search-empty\" class=\"museum-search-empty\" hidden>"
     "当前条件没有匹配笔记。可以逐项移除条件，或清除全部筛选。</p>\n"
     "    <p id=\"index-results-live\" class=\"sr-only\" role=\"status\" "
     "aria-live=\"polite\"></p>\n"
     "  </section>\n"
     "    <section id=\"continue-reading\" class=\"museum-resume\" aria-busy=\"true\">\n"
     "      <div class=\"museum-section-heading\"><h2>继续阅读</h2><span id=\"continue-reading-count\">/ 00</span></div>\n"
     "      <div id=\"continue-reading-list\"><div class=\"resume-empty-state\">"
     "<strong>继续探索</strong><small>阅读位置会保存在当前浏览器。</small>"
     "<a href=\"#recent-updates\">从全部笔记开始 →</a></div></div>\n"
     "    </section>\n"
     "  </div>\n"
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
  "Generate graph.html in the shared export root.
Interactive calls run in an isolated background Emacs process."
  (interactive)
  (if (called-interactively-p 'interactive)
      (org-museum--start-background-job 'export-graph nil)
    (org-museum--run-with-current-runtime
     'org-museum-export-graph (when silent (list :silent t))
     (lambda () (org-museum--export-graph-current :silent silent)))))

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
    (message "知识图谱已生成：%s" graph-html))
    graph-html))

(defun org-museum--graph-edge-records (file)
  "Read validated MUSEUM_GRAPH_EDGE records directly from Org FILE."
  (let (records)
    (when (and (stringp file) (file-regular-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((case-fold-search t))
          (while (re-search-forward "^#\\+MUSEUM_GRAPH_EDGE:[[:space:]]*\\(.*\\)$" nil t)
            (let ((record (condition-case nil
                              (let ((json-object-type 'alist)
                                    (json-key-type 'string))
                                (json-read-from-string (match-string-no-properties 1)))
                            (error nil))))
              (when (and (listp record)
                         (stringp (cdr (assoc "targetId" record)))
                         (member (cdr (assoc "state" record)) '("active" "deleted"))
                         (or (equal (cdr (assoc "state" record)) "deleted")
                             (and (stringp (cdr (assoc "type" record)))
                                  (stringp (cdr (assoc "label" record)))
                                  (member (cdr (assoc "direction" record))
                                          '("forward" "reverse" "both"))
                                  (numberp (cdr (assoc "weight" record)))
                                  (member (cdr (assoc "style" record))
                                          '("solid" "dashed" "dotted")))))
                (push record records)))))))
    (nreverse records)))

(defun org-museum--generate-graph-json ()
  "Return the current Org-backed graph as one node and edge snapshot."
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
    ;; Org files also own user-edited graph relations.  An override replaces
    ;; the visual meaning of an existing link, or creates a graph-only edge.
    ;; A tombstone removes an edge from the graph without editing prose links.
    (maphash
     (lambda (id page)
       (unless (gethash id excluded)
         (dolist (record (org-museum--graph-edge-records (org-museum-page-path page)))
           (let* ((target (cdr (assoc "targetId" record)))
                  (key (and (stringp target) (concat id "\0" target))))
             (when (and key (not (equal id target))
                        (gethash target pages) (not (gethash target excluded)))
               (if (equal (cdr (assoc "state" record)) "deleted")
                   (remhash key directed)
                 (puthash key record directed)))))))
     pages)
    (setq degree (make-hash-table :test 'equal)
          seen-neighbours (make-hash-table :test 'equal))
    (dolist (key (sort (hash-table-keys directed) #'string<))
      (let* ((parts (split-string key "\0"))
             (owner (car parts)) (target-id (cadr parts))
             (record (gethash key directed))
             (_key-check (unless (and (stringp owner) (stringp target-id))
                           (error "Malformed graph key %S (%S)" key parts)))
             (type (if (stringp record) record
                     (or (cdr (assoc "type" record)) "显式链接")))
             (label (if (stringp record) type
                      (or (cdr (assoc "label" record)) type)))
             (direction (if (stringp record) "forward"
                          (or (cdr (assoc "direction" record)) "forward")))
             (weight (if (stringp record) 1
                       (or (cdr (assoc "weight" record)) 1)))
             (style (if (stringp record) "solid"
                      (or (cdr (assoc "style" record)) "solid")))
             (source (if (equal direction "reverse") target-id owner))
             (target (if (equal direction "reverse") owner target-id))
             (neighbour-key (if (string< owner target-id)
                                (concat owner "\0" target-id)
                              (concat target-id "\0" owner))))
        (unless (gethash neighbour-key seen-neighbours)
          (puthash neighbour-key t seen-neighbours)
          (cl-incf (gethash owner degree 0))
          (cl-incf (gethash target-id degree 0)))
        (push `((id . ,key) (ownerId . ,owner) (targetId . ,target-id)
                (source . ,source) (target . ,target)
                (type . ,type) (label . ,label)
                (direction . ,direction) (weight . ,weight) (value . ,weight)
                (style . ,style)
                (bidirectional . ,(if (equal direction "both") t :json-false)))
              links)))
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
                 (group  . ,(org-museum--graph-semantic-category page))
                 (tags   . ,(vconcat (org-museum-page-tags page)))
                 (status . ,(downcase
                             (or (org-museum-page-status page) "published")))
                 (degree . ,(gethash id degree 0))
                 (description . ,(or (org-museum-page-description page) ""))
                 (created . ,(org-museum-page-created page))
                 (modified . ,(org-museum-page-modified page))
                 (linksTo . ,(vconcat
                              (delete-dups
                               (mapcar (lambda (edge) (cdr (assq 'target edge)))
                                       (seq-filter (lambda (edge)
                                                     (equal id (cdr (assq 'source edge))))
                                                   links)))))
                 (linkedFrom . ,(vconcat
                                 (delete-dups
                                  (mapcar (lambda (edge) (cdr (assq 'source edge)))
                                          (seq-filter (lambda (edge)
                                                        (equal id (cdr (assq 'target edge))))
                                                      links)))))
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
          (completing-read "选择 Org Museum 笔记："
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
    (let ((raw (string-trim (read-string "笔记标题："))))
      (when (string-empty-p raw)
        (error "新笔记标题不能为空"))
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
      (error "标题须包含字母、数字或汉字"))
    (unless (org-museum--path-component-safe-p id)
      (error "该标题会生成保留的页面路径"))
    (when (string-empty-p cat-dir)
      (error "分类须包含字母、数字或汉字"))
    (unless (org-museum--path-component-safe-p cat-dir)
      (error "该分类会生成保留的目录路径"))

    ;; ── Guard 1: file path collision ─────────────────────────────
    (when (file-exists-p filepath)
      (error "新笔记文件已存在：%s"
             (file-relative-name filepath org-museum-root-dir)))

    ;; ── Guard 2: ID collision across all categories ───────────────
    (when (and org-museum--index
               (gethash id (org-museum-index-pages org-museum--index)))
      (error "新笔记 ID '%s' 已在索引中，可能与其他分类的标题重复" id))

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
            (message "Org Museum 已创建笔记：'%s' → %s"
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
          (old (completing-read "要更名的笔记 ID：" ids nil t)))
     (list old (read-string (format "New ID (was: %s): " old) old))))
  (unless (org-museum--path-component-safe-p new-id)
    (error "新 ID 不能为空，且须能安全用作文件路径"))
  (let* ((page     (or (gethash old-id (org-museum-index-pages org-museum--index))
                       (error "找不到笔记：%s" old-id)))
         (old-path (expand-file-name (org-museum-page-path page)))
         (new-path (expand-file-name
                    (concat new-id ".org") (file-name-directory old-path)))
         (page-buffer (get-file-buffer old-path))
         (original-index org-museum--index))
    (when (gethash new-id (org-museum-index-pages org-museum--index))
      (error "ID 已存在：%s" new-id))
    (when (file-exists-p new-path)
      (error "更名目标文件已存在：%s" new-path))
    (when (get-file-buffer new-path)
      (error "更名目标文件已在 Emacs 中打开：%s" new-path))
    (when (and (buffer-live-p page-buffer)
               (buffer-modified-p page-buffer))
      (error "请先保存当前笔记，再更名"))
    (when-let* ((modified-referrer
                (org-museum--modified-link-buffer old-id)))
      (error "请先保存引用这篇笔记的页面，再更名：%s"
             (buffer-file-name modified-referrer)))
    (when-let* ((modified-referrer
                (org-museum--modified-file-link-buffer old-path)))
      (error "请先保存引用这篇笔记的页面，再更名：%s"
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
              (message "已将 %s 更名为 %s，并更新 %d 个文件。"
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
    (with-current-buffer (get-buffer-create "*Org Museum 链接检查*")
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
    (message "Org Museum 链接检查：%d 条有效、%d 条缺失、%d 条绝对路径"
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
    (error "尚未设置 org-museum-root-dir，请运行 M-x org-museum-init"))
  (unless (file-directory-p org-museum-root-dir)
    (error "Org Museum 根目录不存在：%s"
           org-museum-root-dir))
  (dolist (dir (list (org-museum--shared-root) (org-museum--scan-root)))
    (condition-case nil
        (make-directory dir t)
      (error
       (error "无法创建导出目录：%s" dir)))
    (unless (file-writable-p dir)
      (error "导出目录不可写：%s" dir)))
  (let ((css-src (org-museum--css-source-path)))
    (unless (file-exists-p css-src)
      (error "找不到源样式文件 %s；请检查 org-museum-css-file 配置" css-src)))
  (unless org-museum--index
    (condition-case err
        (org-museum-index-build)
      (error
      (error "Org Museum 索引建立失败：%s"
              (error-message-string err))))))

(defun org-museum--guard-quick ()
  "Lightweight guard: verify root-dir and index only."
  (unless org-museum-root-dir
    (error "尚未设置 org-museum-root-dir"))
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
      (let ((replacement
             (save-match-data
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
                 (format "[[file:%s]%s]" destination description)))))
        (replace-match replacement t t)))
    ;; wiki:/museum: wiki page links
    (goto-char (point-min))
    (while (re-search-forward
            "\\[\\[\\(?:wiki\\|museum\\):\\([^]]+\\)\\]\\(\\[\\([^]]+\\)\\]\\)?\\]" nil t)
      (let ((replacement
             (save-match-data
               (let* ((raw-id (match-string 1))
                      (original (match-string 0))
                      (desc (match-string 3))
                      (direct-page (org-museum--find-page raw-id))
                      (id (if (or direct-page
                                  (not (string-suffix-p ".org" raw-id t)))
                              raw-id
                            (substring raw-id 0 -4)))
                      (page (or direct-page (org-museum--find-page id)))
                      (href (org-museum--page-href id out-file)))
                 (if page
                     (format "[[file:%s]%s]" href
                             (if desc (format "[%s]" desc) ""))
                   original)))))
        (replace-match replacement t t)))
    ;; id: org-id links
    (goto-char (point-min))
    (while (re-search-forward
            "\\[\\[id:\\([^]]+\\)\\]\\(\\[\\([^]]+\\)\\]\\)?\\]" nil t)
      (let ((replacement
             (save-match-data
               (let* ((id (match-string 1))
                      (original (match-string 0))
                      (desc (match-string 3))
                      (page (org-museum--find-page id))
                      (href (org-museum--page-href id out-file)))
                 (if page
                     (format "[[file:%s]%s]" href
                             (if desc (format "[%s]" desc) ""))
                   original)))))
        (replace-match replacement t t)))))

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
               (display-label (if (string= label href)
                                  escaped-href
                                label))
               (anchor
                (if exists
                    (format "<a%s href=\"%s\"%s>%s</a>"
                            before escaped-href after display-label)
                  (format "<span class=\"museum-local-file-label\" aria-disabled=\"true\">%s</span>"
                          display-label))))
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
var tocDrawerMedia=matchMedia('(max-width:1439px)');
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
    if(!tocDrawerMedia.matches){
      var open=!document.body.classList.contains('museum-toc-hover');
      document.body.classList.toggle('museum-toc-hover',open);
      controls('[data-toc-toggle]',open);
      if(open)focusFirst(toc);
      return;
    }
    if(document.body.classList.contains('museum-toc-open'))closeAll(true);
    else openPanel('toc',button);
  });
});
document.querySelectorAll('[data-drawer-close],[data-toc-close]').forEach(function(button){
  button.addEventListener('click',function(){
    if(!tocDrawerMedia.matches&&button.hasAttribute('data-toc-close')){
      document.body.classList.remove('museum-toc-hover');
      controls('[data-toc-toggle]',false);
    }else closeAll(true);
  });
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
      'button:not([disabled]),a[href],input:not([disabled]),[tabindex=\"0\"]')).filter(function(item){return item.getClientRects().length>0;});
    if(!items.length)return;
    var first=items[0],last=items[items.length-1];
    if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus({preventScroll:true});}
    else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus({preventScroll:true});}
  }
},true);
var search=document.getElementById('org-museum-global-search');
if(search&&['article','ai','timeline','related'].includes(document.body.dataset.pageKind)){
  search.addEventListener('keydown',function(event){
    if(event.key==='Enter'&&!event.isComposing&&search.value.trim()){
      var top=document.querySelector('.museum-topbar');
      var home=top?top.getAttribute('data-home-href'):'index.html';
      var destination=home+'?q='+encodeURIComponent(search.value.trim());
      location.href=window.orgMuseumThemeUrl?
        window.orgMuseumThemeUrl(destination):destination;
    }
  });
}
document.addEventListener('keydown',function(event){
  if(event.defaultPrevented||event.isComposing||document.activeElement.isContentEditable||
     document.querySelector('dialog[open],#image-lightbox-overlay.visible'))return;
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
   (org-museum--script-reading-state)
   (org-museum--script-ai-markdown out-file)
   (format "<script defer src=\"%s\"></script>\n"
           (org-museum--html-escape
            (org-museum--versioned-resource-href
             (expand-file-name "resources/org-museum-org-view.js"
                               (org-museum--shared-root)) out-file) t))
   (format "<script defer src=\"%s\"></script>\n"
           (org-museum--html-escape
            (org-museum--versioned-resource-href
             (expand-file-name "resources/org-museum-ai.js"
                               (org-museum--shared-root)) out-file) t))))

;; ============================================================
;; §20  LEFT SIDEBAR HTML
;; ============================================================

(defun org-museum--script-ai-markdown (out-file)
  "Load the local Markdown parser and safe AI renderer for OUT-FILE."
  (mapconcat
   (lambda (name)
     (format "<script defer src=\"%s\"></script>\n"
             (org-museum--html-escape
              (org-museum--versioned-resource-href
               (expand-file-name name (org-museum--shared-root)) out-file)
              t)))
   '("resources/vendor/markdown-it.umd.min.js"
     "resources/org-museum-markdown.js") ""))

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
                         (if (equal (downcase (car cat-entry)) "uncategorized")
                             "其他笔记"
                           (org-museum--category-label (car cat-entry))))
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

(defun org-museum--related-localize-generated-toc (language)
  "Localize Org's generated table-of-contents heading for LANGUAGE."
  (when (string-prefix-p "zh" (downcase (or language "")))
    (goto-char (point-min))
    (when (re-search-forward
           "<div\\b[^>]*\\bid=\"table-of-contents\"[^>]*>" nil t)
      (let ((limit (min (point-max) (+ (point) 512))))
        (when (re-search-forward
               "\\(<h2\\b[^>]*>\\)Table of Contents\\(</h2>\\)" limit t)
          (replace-match "\\1本文目录\\2" t nil))))))

(defun org-museum--related-rebase-fragment (html page out-file)
  "Rebase links in HTML from PAGE output to OUT-FILE and prefix fragment IDs."
  (let* ((page-file (org-museum--export-filename (org-museum-page-path page)))
         (prefix (concat "related-" (org-museum-page-id page) "-")))
    (with-temp-buffer
      (insert (or html ""))
      (org-museum--related-localize-generated-toc
       (let ((source (org-museum-page-path page)))
         (if (and source (file-readable-p source))
             (org-museum--source-language source)
           org-museum-default-language)))
      (goto-char (point-min))
      (while (re-search-forward "\\(href\\|src\\)=\"\\([^\"]+\\)\"" nil t)
        (let ((replacement
               (save-match-data
                 (let* ((attribute (match-string-no-properties 1))
                        (url (match-string-no-properties 2))
                        (rebased
                         (cond
                          ((string-prefix-p "#" url)
                           (concat "#" prefix (substring url 1)))
                          ((org-museum--related-url-absolute-p url) url)
                          (t
                           (let* ((split (or (string-match "[?#]" url)
                                             (length url)))
                                  (path (substring url 0 split))
                                  (suffix (substring url split)))
                             (concat
                              (org-museum--relative-path
                               (expand-file-name
                                path (file-name-directory page-file))
                               out-file)
                              suffix))))))
                   (format "%s=\"%s\"" attribute
                           (org-museum--html-escape rebased t))))))
          (replace-match replacement t t)))
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
      (generatedAt . ,(org-museum--build-time-string "%Y-%m-%dT%H:%M:%S+0000"))
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
  if(window.hljs)document.querySelectorAll('.related-full pre code').forEach(function(code){
    var languageClass=Array.from(code.classList).find(function(className){return className.indexOf('language-')===0;});
    var lang=languageClass?languageClass.slice(9):'';
    if(!code.dataset.highlighted&&(!lang||hljs.getLanguage(lang)))hljs.highlightElement(code);
    else if(lang&&!hljs.getLanguage(lang))code.classList.add('no-highlight');
  });
  if(push)setUrl(mode);
}
function renderDetail(){
  if(!links(source,target)&&links(target,source)){var swap=source;source=target;target=swap;}
  index.hidden=true;empty.hidden=true;detail.hidden=false;
  document.getElementById('related-open-source').href=themed(source.href);
  document.getElementById('related-open-target').href=themed(target.href);
  var backShelf=document.getElementById('related-back-shelf');
  if(backShelf){
    backShelf.href=themed('related.html');
    backShelf.onclick=function(e){
      e.preventDefault();
      var url=new URL(location.href);
      url.searchParams.delete('source');url.searchParams.delete('target');url.searchParams.delete('mode');
      history.pushState({},'',url.pathname+url.search+url.hash);
      source=null;target=null;
      renderIndex();
    };
  }
  var bridgeBack=document.getElementById('related-bridge-back');
  if(bridgeBack){
    bridgeBack.href=themed('related.html');
    bridgeBack.onclick=function(e){
      e.preventDefault();
      var url=new URL(location.href);
      url.searchParams.delete('source');url.searchParams.delete('target');url.searchParams.delete('mode');
      history.pushState({},'',url.pathname+url.search+url.hash);
      source=null;target=null;
      renderIndex();
    };
  }
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
    link.addEventListener('click',function(e){
      e.preventDefault();
      source=from;target=to;mode='summary';
      setUrl(mode);
      renderDetail();
    });
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
window.addEventListener('popstate',function(){
  var p=new URLSearchParams(location.search);
  source=pages.get(p.get('source')||'');
  target=pages.get(p.get('target')||'');
  mode=p.get('mode')==='full'?'full':'summary';
  if(relationValid())renderDetail();else renderIndex();
});
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
     "<a id=\"related-back-shelf\" href=\"related.html\">← 关系书架</a>"
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
     "<a id=\"related-bridge-back\" href=\"related.html\">← 关系书架</a>"
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
  "Generate the offline relationship-reading center.
Interactive calls run in an isolated background Emacs process."
  (interactive)
  (if (called-interactively-p 'interactive)
      (org-museum--start-background-job 'export-related-reading nil)
    (org-museum--run-with-current-runtime
     'org-museum-export-related-reading nil
     #'org-museum--export-related-reading-current)))

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
      (generatedAt . ,(org-museum--build-time-string "%Y-%m-%dT%H:%M:%S+0000"))
      (today . ,(org-museum--build-time-string "%Y-%m-%d"))
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
// The timeline payload is intentionally limited to published notes. Keep
// legacy URLs harmless, but do not expose a draft filter that can never match.
state.status='all';
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
function activeTimelineFocusId(){var active=document.activeElement;if(!active||!active.closest)return '';var node=active.closest('.timeline-node,.timeline-mobile-node');if(!node)return '';var page=node.__data__||pageMap.get(node.dataset.pageId);return page?page.id:'';}
function scheduleTimelineUpdate(options){options=options||{};coordinator.scrollFocus=coordinator.scrollFocus||!!options.scrollFocus;coordinator.focusControl=coordinator.focusControl||!!options.focusControl;if(coordinator.frame)return;coordinator.frame=requestAnimationFrame(function(){coordinator.frame=0;var page=pageMap.get(state.focus);applyFocus();applyMobileFocus(page);var node=page&&focusButton(page.id);if(coordinator.focusControl&&node&&typeof node.focus==='function')node.focus({preventScroll:true});if(coordinator.scrollFocus&&page){if(innerWidth<=820||timelineListMode)revealWithinViewport(node,true);else if(!focusCard.hidden)revealWithinViewport(focusCard,false);}coordinator.scrollFocus=false;coordinator.focusControl=false;});}
function clearFocus(){var old=state.focus;if(!old)return;state.focus='';writeUrl('push');tooltip.hidden=true;if(coordinator.inputMode!=='keyboard'&&document.activeElement&&typeof document.activeElement.blur==='function')document.activeElement.blur();scheduleTimelineUpdate();var node=focusButton(old);if(coordinator.inputMode==='keyboard'&&node&&typeof node.focus==='function')node.focus({preventScroll:true});if(restoreScroll!==null&&innerWidth<=820){var target=restoreScroll;restoreScroll=null;requestAnimationFrame(function(){scrollToPosition(target);});}}
function setFocus(page,push,fromNavigation){if(!page)return clearFocus();if(state.focus===page.id){if(fromNavigation){var current=focusButton(page.id);if(current)current.focus({preventScroll:true});}return;}if(!state.focus&&innerWidth<=820)restoreScroll=scrollY;state.focus=page.id;writeUrl(push?'push':'replace');scheduleTimelineUpdate({scrollFocus:true,focusControl:fromNavigation});}
function navigateRelative(offset){var list=visiblePages(),page=pageMap.get(state.focus),at=visibleIndex(page,list),next=list[at+offset];if(next)setFocus(next,true,true);}
function restoreFilterFocus(root,value){requestAnimationFrame(function(){var active=root.querySelector('[data-value=\"'+CSS.escape(value)+'\"]');if(active)active.focus({preventScroll:true});});}
function renderFilters(){categoryRoot.textContent='';[['*','全部']].concat(categories.map(function(value){return [value,value];})).forEach(function(item){var matching=pages.filter(function(page){return item[0]==='*'||(page.categoryLabel||page.category)===item[0];});var button=element('button',state.category===item[0]?'is-active':'',item[1]+' '+String(matching.length).padStart(2,'0'));button.type='button';button.dataset.value=item[0];button.style.setProperty('--timeline-color',item[0]==='*'?'var(--museum-accent)':color(matching[0]));button.setAttribute('aria-pressed',state.category===item[0]?'true':'false');button.addEventListener('click',function(){state.category=item[0];writeUrl('push');render();restoreFilterFocus(categoryRoot,item[0]);});categoryRoot.appendChild(button);});if(statusRoot)statusRoot.textContent='当前时间轴仅展示已发布笔记。';}
function renderIsolated(){isolatedList.textContent='';var isolated=visiblePages().filter(function(page){return relationCount(page)===0;});isolated.forEach(function(page){var button=element('button','',page.title);button.type='button';button.style.setProperty('--timeline-color',color(page));button.addEventListener('click',function(){setFocus(page,true);});isolatedList.appendChild(button);});document.getElementById('timeline-isolated-count').textContent=String(isolated.length).padStart(2,'0');}
function buildMobileList(list){var signature=list.map(function(page){return page.id;}).join('|');if(signature===mobileListSignature){applyMobileFocus(pageMap.get(state.focus));return;}mobileListSignature=signature;mobileItems.clear();mobileList.textContent='';var month='',date='';list.forEach(function(page){var currentMonth=page.createdDate.slice(0,7);if(currentMonth!==month){month=currentMonth;var monthHeading=element('li','timeline-mobile-month',currentMonth.replace('-',' / '));monthHeading.setAttribute('aria-hidden','true');mobileList.appendChild(monthHeading);date='';}if(page.createdDate!==date){date=page.createdDate;var dateHeading=element('li','timeline-mobile-date',page.createdDate.slice(5).replace('-',' / '));dateHeading.setAttribute('aria-hidden','true');mobileList.appendChild(dateHeading);}var item=element('li','timeline-mobile-item');item.style.setProperty('--timeline-color',color(page));var button=element('button','timeline-mobile-node');button.type='button';button.dataset.pageId=page.id;button.setAttribute('aria-label',page.createdDate+' '+page.title+' '+(page.categoryLabel||page.category||'未分类'));button.appendChild(element('strong','',page.title));button.appendChild(element('span','',page.categoryLabel||page.category||'未分类'));button.addEventListener('click',function(){setFocus(page,true);});button.addEventListener('dblclick',function(){location.href=themed(page.href);});button.addEventListener('keydown',function(event){var listNow=visiblePages(),next;if(event.key==='Enter'){event.preventDefault();location.href=themed(page.href);}else if(event.key===' '){event.preventDefault();setFocus(page,true);}else if(event.key==='ArrowLeft'||event.key==='ArrowRight'){var at=visibleIndex(page,listNow);next=listNow[at+(event.key==='ArrowRight'?1:-1)];}else if(event.key==='ArrowUp'||event.key==='ArrowDown'){var peers=sameDateGroup(page,listNow),peerAt=visibleIndex(page,peers);next=peers[peerAt+(event.key==='ArrowDown'?1:-1)];}if(next){event.preventDefault();setFocus(next,true,true);}});item.appendChild(button);mobileItems.set(page.id,{item:item,button:button});mobileList.appendChild(item);});applyMobileFocus(pageMap.get(state.focus));}
function applyMobileFocus(page){mobileItems.forEach(function(entry,id){entry.button.setAttribute('aria-pressed',page&&id===page.id?'true':'false');entry.item.classList.toggle('is-selected',!!page&&id===page.id);});if(!page||(innerWidth>820&&!timelineListMode)){mobileDetail.hidden=true;return;}var entry=mobileItems.get(page.id);if(!entry){mobileDetail.hidden=true;return;}if(mobileDetail.dataset.pageId!==page.id||mobileDetail.dataset.list!==mobileListSignature){mobileDetail.dataset.pageId=page.id;mobileDetail.dataset.list=mobileListSignature;mobileDetail.replaceChildren(detailContent(page,true));}entry.item.appendChild(mobileDetail);mobileDetail.hidden=false;}
function sameDateGroup(page,list){return list.filter(function(item){return item.createdDate===page.createdDate;});}
var timelineListMode=false;
function renderDesktop(){svgHost.textContent='';desktop=null;timelineListMode=false;document.body.classList.remove('timeline-dense-list');if(!pages.length){svgHost.appendChild(element('p','museum-empty-copy','还没有可展示的时间节点。'));return;}if(typeof d3==='undefined'){svgHost.appendChild(element('p','museum-empty-copy','时间轴绘制资源不可用，请使用下方时间列表。'));return;}var width=Math.max(canvas.clientWidth||760,640),height=Math.max(canvas.clientHeight||500,500),pad=54,axisY=Math.round(height*.52);var day=86400000;var min=d3.min(pages,function(page){return page.created*1000;})-7*day;var max=d3.max(pages,function(page){return Math.max(page.created,page.modified)*1000;})+7*day;if(max<=min)max=min+14*day;var scale=d3.scaleTime().domain([new Date(min),new Date(max)]).range([pad,width-pad]);var svg=d3.select(svgHost).append('svg').attr('viewBox','0 0 '+width+' '+height).attr('role','group').attr('aria-label','知识时间轴');var defs=svg.append('defs');defs.append('marker').attr('id','timeline-arrow').attr('viewBox','0 -4 8 8').attr('refX',7).attr('refY',0).attr('markerWidth',7).attr('markerHeight',7).attr('orient','auto-start-reverse').append('path').attr('d','M0,-4L8,0L0,4Z');var layer=svg.append('g');var monthAxis=d3.axisTop(scale).ticks(Math.max(2,Math.floor(width/120))).tickFormat(d3.timeFormat('%Y / %m')).tickSize(-(height-90));layer.append('g').attr('class','timeline-month-axis').attr('transform','translate(0,'+(axisY-12)+')').call(monthAxis);layer.append('line').attr('class','timeline-axis-line').attr('x1',pad).attr('x2',width-pad).attr('y1',axisY).attr('y2',axisY);
var seenMonths=new Set();layer.selectAll('.timeline-month-axis .tick').filter(function(tick){var key=tick.getFullYear()+'-'+tick.getMonth();if(seenMonths.has(key))return true;seenMonths.add(key);return false;}).remove();
var today=new Date((raw.today||'')+'T00:00:00');if(Number.isFinite(today.getTime())&&today>=new Date(min)&&today<=new Date(max)){var tx=scale(today);layer.append('line').attr('class','timeline-today-line').attr('x1',tx).attr('x2',tx).attr('y1',axisY-170).attr('y2',axisY+170);layer.append('text').attr('class','timeline-today-label').attr('x',tx).attr('y',axisY+28).attr('text-anchor','middle').text(d3.timeFormat('%m / %d')(today));}
var relationLayer=layer.append('g').attr('class','timeline-relation-layer');var updateLayer=layer.append('g').attr('class','timeline-update-layer');var laneLast=[],nodeLayout=new Map(),lastDateX=-Infinity;pages.forEach(function(page){var x=scale(new Date(page.created*1000)),lane=0;while(lane<laneLast.length&&x-laneLast[lane]<140)lane+=1;if(lane===laneLast.length)laneLast.push(x);else laneLast[lane]=x;nodeLayout.set(page.id,{x:x,lane:lane,above:lane%2===0,y:axisY+(lane%2===0?-1:1)*(54+Math.floor(lane/2)*34),showDate:x-lastDateX>=44});if(x-lastDateX>=44)lastDateX=x;});if(laneLast.length>12){timelineListMode=true;document.body.classList.add('timeline-dense-list');svgHost.textContent='';applyMobileFocus(pageMap.get(state.focus));return;}var groups=layer.append('g').attr('class','timeline-nodes').selectAll('g').data(pages).enter().append('g').attr('class','timeline-node').attr('tabindex',0).attr('role','button').attr('aria-label',function(page){return page.title+'，创建于 '+page.createdDate+'，Space 选择，Enter 打开';});groups.each(function(page){var item=nodeLayout.get(page.id),group=d3.select(this).attr('transform','translate('+item.x+',0)').style('--timeline-color',color(page));group.append('line').attr('class','timeline-node-stem').attr('y1',axisY).attr('y2',item.y);group.append('circle').attr('class','timeline-node-dot').attr('cy',axisY).attr('r',5);group.append('circle').attr('class','timeline-node-category').attr('cy',item.y).attr('r',4);var text=group.append('text').attr('class','timeline-node-title').attr('text-anchor','middle').attr('y',item.above?item.y-12:item.y+20);var title=page.title||'未命名';group.append('title').text(page.createdDate+' '+title);text.text(title.length>10?title.slice(0,10)+'…':title);if(item.showDate)group.append('text').attr('class','timeline-node-date').attr('text-anchor','middle').attr('y',axisY+24).text(page.createdDate.slice(5).replace('-',' / '));});groups.on('click',function(event,page){event.stopPropagation();setFocus(page,true);}).on('dblclick',function(event,page){event.stopPropagation();location.href=themed(page.href);}).on('mouseenter',function(event,page){tooltip.textContent=page.createdDate+' · '+page.title;tooltip.hidden=false;var rect=canvas.getBoundingClientRect();tooltip.style.left=Math.min(rect.width-220,Math.max(12,event.clientX-rect.left+12))+'px';tooltip.style.top=Math.max(10,event.clientY-rect.top-42)+'px';}).on('mouseleave',function(){tooltip.hidden=true;}).on('blur',function(){tooltip.hidden=true;}).on('keydown',function(event,page){var list=visiblePages(),active=pageMap.get(state.focus),current=active&&matches(active)?active:page,at=visibleIndex(current,list),next;if(event.key==='Enter'){event.preventDefault();location.href=themed(current.href);}else if(event.key===' '){event.preventDefault();setFocus(current,true);}else if(event.key==='ArrowLeft'||event.key==='ArrowRight'){next=list[at+(event.key==='ArrowRight'?1:-1)];}else if(event.key==='ArrowUp'||event.key==='ArrowDown'){var peers=sameDateGroup(current,list),peerAt=visibleIndex(current,peers);next=peers[peerAt+(event.key==='ArrowDown'?1:-1)];}if(next){event.preventDefault();setFocus(next,true,true);}});svg.on('click',function(event){if(event.target===svg.node())clearFocus();});desktop={width:width,height:height,axisY:axisY,scale:scale,groups:groups,nodeLayout:nodeLayout,relationLayer:relationLayer,updateLayer:updateLayer};applyVisibility();applyFocus();}
function scheduleDesktopGeometry(){if(innerWidth<=820||timelineListMode||!desktop)return;cancelAnimationFrame(coordinator.geometryFrame);coordinator.geometryFrame=requestAnimationFrame(function(){coordinator.geometryFrame=0;var nextWidth=Math.max(canvas.clientWidth||760,640),nextHeight=Math.max(canvas.clientHeight||500,500);if(Math.abs(nextWidth-desktop.width)<1&&Math.abs(nextHeight-desktop.height)<1)return;var activeId=activeTimelineFocusId();renderDesktop();bindDesktopKeyboard();var activeNode=activeId&&focusButton(activeId);if(activeNode)activeNode.focus({preventScroll:true});});}
function bindDesktopKeyboard(){if(!desktop)return;desktop.groups.on('keydown',function(event,page){var list=visiblePages(),at=visibleIndex(page,list),next;if(event.key==='Enter'){event.preventDefault();location.href=themed(page.href);}else if(event.key===' '){event.preventDefault();setFocus(page,true);}else if(event.key==='ArrowLeft'||event.key==='ArrowRight'){next=list[at+(event.key==='ArrowRight'?1:-1)];}else if(event.key==='ArrowUp'||event.key==='ArrowDown'){var peers=sameDateGroup(page,list),peerAt=visibleIndex(page,peers);next=peers[peerAt+(event.key==='ArrowDown'?1:-1)];}if(next){event.preventDefault();setFocus(next,true,true);}});var svg=desktop.groups.node()&&desktop.groups.node().ownerSVGElement;if(svg)d3.select(svg).on('click',function(event){if(!event.target.closest||!event.target.closest('.timeline-node'))clearFocus();});}
function drawRelations(page){if(!desktop)return;desktop.relationLayer.selectAll('*').remove();if(!page)return;var visibleIds=new Set(visiblePages().map(function(item){return item.id;}));edges.filter(function(edge){return visibleIds.has(edge.source)&&visibleIds.has(edge.target)&&(edge.source===page.id||edge.target===page.id);}).forEach(function(edge,index){var source=pageMap.get(edge.source),target=pageMap.get(edge.target),x1=desktop.scale(new Date(source.created*1000)),x2=desktop.scale(new Date(target.created*1000)),span=Math.abs(x2-x1),lift=58+Math.min(110,span*.22)+index*10;var path=span<12?'M'+(x1-5)+','+desktop.axisY+' C'+(x1-64)+','+(desktop.axisY-122)+' '+(x1+64)+','+(desktop.axisY-122)+' '+(x2+5)+','+desktop.axisY:'M'+x1+','+desktop.axisY+' Q'+((x1+x2)/2)+','+(desktop.axisY-lift)+' '+x2+','+desktop.axisY;desktop.relationLayer.append('path').attr('class','timeline-relation-arc').attr('d',path).attr('marker-end','url(#timeline-arrow)').attr('marker-start',edge.bidirectional?'url(#timeline-arrow)':null);});}
function drawUpdate(page){if(!desktop)return;desktop.updateLayer.selectAll('*').remove();if(!page)return;var cx=desktop.scale(new Date(page.created*1000)),mx=desktop.scale(new Date(page.modified*1000));desktop.updateLayer.append('line').attr('class','timeline-update-span').attr('x1',cx).attr('x2',mx).attr('y1',desktop.axisY).attr('y2',desktop.axisY);desktop.updateLayer.append('circle').attr('class','timeline-update-dot').attr('cx',mx).attr('cy',desktop.axisY).attr('r',6);desktop.updateLayer.append('text').attr('class','timeline-update-label').attr('x',mx).attr('y',desktop.axisY+44).attr('text-anchor','middle').text(page.createdDate===page.modifiedDate?'同日更新':'更新 '+page.modifiedDate.slice(5).replace('-',' / '));}
function applyFocus(){var page=pageMap.get(state.focus),visible=visiblePages(),at=page?visibleIndex(page,visible):-1,nearIds=new Set(at<0?[]:visible.slice(Math.max(0,at-1),at+2).map(function(item){return item.id;})),relatedIds=new Set(page?[].concat(page.linksTo||[],page.linkedFrom||[]):[]);if(desktop){desktop.groups.classed('is-selected',function(item){return !!page&&item.id===page.id;}).classed('is-related',function(item){return relatedIds.has(item.id);}).classed('is-near',function(item){return !!page&&item.id!==page.id&&nearIds.has(item.id);}).classed('is-muted',function(item){return !!page&&item.id!==page.id&&!relatedIds.has(item.id)&&!nearIds.has(item.id);}).attr('aria-pressed',function(item){return page&&item.id===page.id?'true':'false';});drawRelations(page);drawUpdate(page);}focusCard.removeAttribute('data-page-id');var showInspector=!!page&&innerWidth>820&&!timelineListMode;if(timelineLayout)timelineLayout.classList.toggle('has-focus',showInspector);scheduleDesktopGeometry();if(!showInspector){focusCard.hidden=true;return;}var changed=focusCardBody.dataset.pageId!==page.id;focusCard.dataset.pageId=page.id;focusCard.setAttribute('aria-label','当前笔记：'+page.title);if(changed){focusCard.classList.add('is-changing');focusCardBody.dataset.pageId=page.id;focusCardBody.replaceChildren(detailContent(page,false));focusCard.scrollTop=0;requestAnimationFrame(function(){focusCard.classList.remove('is-changing');});}focusCard.hidden=false;}
function applyVisibility(){var list=visiblePages(),ids=new Set(list.map(function(page){return page.id;}));if(desktop)desktop.groups.classed('is-filtered',function(page){return !ids.has(page.id);}).attr('aria-hidden',function(page){return ids.has(page.id)?null:'true';}).attr('tabindex',function(page){return ids.has(page.id)?0:-1;});var labels=[];if(state.category!=='*')labels.push(state.category);if(state.query)labels.push('“'+state.query+'”');scopeSummary.textContent=labels.length?labels.join(' · '):'已发布笔记';}
function announce(message,notice){var list=visiblePages(),text=message||list.length+' 个时间节点';matchStatus.textContent=text;if(filterResult)filterResult.textContent=text;scopeBar.classList.toggle('has-notice',!!notice);clearTimeout(window.__museumTimelineNotice);if(notice)window.__museumTimelineNotice=setTimeout(function(){scopeBar.classList.remove('has-notice');matchStatus.textContent=list.length+' 个时间节点';},2200);}
function render(message){var selected=pageMap.get(state.focus),notice=message||'';if(selected&&!matches(selected)){state.focus='';writeUrl('replace');notice='筛选后已清除原选择';selected=null;}var list=visiblePages();focusCardBody.dataset.pageId='';mobileDetail.dataset.pageId='';renderFilters();applyVisibility();buildMobileList(list);bindDesktopKeyboard();applyFocus();applyMobileFocus(selected);renderIsolated();document.getElementById('timeline-total').textContent=String(pages.length).padStart(2,'0');announce(notice,!!notice);}
function setFilterOpen(open,returnFocus){var mobile=innerWidth<=820,nextOpen=mobile&&open;if(nextOpen&&!filterOpen){filterScroll=scrollY;filterTrigger=document.activeElement;document.body.style.position='fixed';document.body.style.top=-filterScroll+'px';document.body.style.width='100%';}filterOpen=nextOpen;filterSheet.dataset.open=filterOpen?'true':'false';filterSheet.setAttribute('role',mobile?'dialog':'region');filterSheet.setAttribute('aria-hidden',mobile&&!filterOpen?'true':'false');filterSheet.setAttribute('aria-modal',filterOpen?'true':'false');filterSheet.inert=mobile&&!filterOpen;filterToggle.setAttribute('aria-expanded',filterOpen?'true':'false');filterBackdrop.hidden=!filterOpen;document.documentElement.classList.toggle('timeline-filter-open',filterOpen);if(filterOpen){var active=filterSheet.querySelector('.is-active');requestAnimationFrame(function(){(active||filterSheet).focus({preventScroll:true});});}else if(filterScroll!==null){var target=filterScroll;filterScroll=null;document.body.style.position='';document.body.style.top='';document.body.style.width='';window.scrollTo(0,target);requestAnimationFrame(function(){if(returnFocus!==false&&(filterTrigger||filterToggle))(filterTrigger||filterToggle).focus({preventScroll:true});filterTrigger=null;});}}
function filterTabTrap(event){if(!filterOpen||event.key!=='Tab')return;var controls=Array.from(filterSheet.querySelectorAll('button:not([disabled]),a[href],input:not([disabled]),[tabindex]:not([tabindex=\"-1\"])'));if(!controls.length)return;var first=controls[0],last=controls[controls.length-1];if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus({preventScroll:true});}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus({preventScroll:true});}}
if(filterToggle)filterToggle.addEventListener('click',function(){setFilterOpen(!filterOpen,true);});if(filterClose)filterClose.addEventListener('click',function(){setFilterOpen(false,true);});if(filterBackdrop)filterBackdrop.addEventListener('click',function(){setFilterOpen(false,true);});
if(search)search.addEventListener('input',function(){state.query=search.value.trim().toLowerCase();writeUrl('replace');render();});
document.addEventListener('pointerdown',function(){coordinator.inputMode='pointer';},true);
document.addEventListener('keydown',function(event){coordinator.inputMode='keyboard';filterTabTrap(event);if(event.defaultPrevented)return;if(event.key==='Escape'){if(filterOpen){setFilterOpen(false,true);return;}if(state.focus){clearFocus();return;}}if(event.key==='/'&&!event.metaKey&&!event.ctrlKey&&!event.altKey&&!/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)){event.preventDefault();if(search)search.focus();}});
document.addEventListener('keydown',function(event){if(event.defaultPrevented||filterOpen||!state.focus||!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(event.key)||/^(INPUT|TEXTAREA|SELECT|BUTTON|A)$/.test(document.activeElement.tagName))return;var list=visiblePages(),current=pageMap.get(state.focus),next;if(event.key==='ArrowLeft'||event.key==='ArrowRight'){var at=visibleIndex(current,list);next=list[at+(event.key==='ArrowRight'?1:-1)];}else{var peers=sameDateGroup(current,list),peerAt=visibleIndex(current,peers);next=peers[peerAt+(event.key==='ArrowDown'?1:-1)];}if(next){event.preventDefault();setFocus(next,true,true);}});
window.addEventListener('resize',function(){clearTimeout(window.__museumTimelineResize);window.__museumTimelineResize=setTimeout(function(){var nextMobile=innerWidth<=820;if(innerWidth===lastViewportWidth&&nextMobile===lastMobile)return;lastViewportWidth=innerWidth;lastMobile=nextMobile;var hadFocus=!!state.focus,focusedId=activeTimelineFocusId();if(filterOpen)setFilterOpen(false,false);renderDesktop();buildMobileList(visiblePages());bindDesktopKeyboard();applyFocus();applyMobileFocus(pageMap.get(state.focus));if(hadFocus)scheduleTimelineUpdate({scrollFocus:true,focusControl:focusedId===state.focus});},140);});
window.addEventListener('popstate',function(event){var next=new URLSearchParams(location.search);state.query=(next.get('q')||'').trim().toLowerCase();state.category=next.get('category')||'*';state.status='all';state.focus=next.get('focus')||'';if(!categories.includes(state.category))state.category='*';if(!pageMap.has(state.focus))state.focus='';if(search)search.value=state.query;render();if(state.focus)scheduleTimelineUpdate({scrollFocus:true,focusControl:true});else if(event.state&&Number.isFinite(event.state.scrollY))requestAnimationFrame(function(){scrollToPosition(event.state.scrollY);});});
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
   "  <header class=\"timeline-hero\"><p>时间阅读</p><h1>知识的长河</h1><span>按创建时间浏览已发布笔记，在选择中展开知识的更新轨迹</span></header>\n"
   "  <section class=\"timeline-scope-bar\" aria-label=\"当前时间范围\"><button id=\"timeline-filter-toggle\" class=\"timeline-filter-toggle\" type=\"button\" aria-expanded=\"false\" aria-controls=\"timeline-filter-sheet\">筛选</button><strong class=\"timeline-scope-label\">时间范围</strong><span id=\"timeline-scope-summary\">已发布笔记</span><span>/ <b id=\"timeline-total\">00</b></span><p id=\"timeline-match-status\" role=\"status\" aria-live=\"polite\">0 个时间节点</p></section>\n"
   "  <div id=\"timeline-filter-backdrop\" class=\"timeline-filter-backdrop\" hidden></div>\n"
   "  <aside id=\"timeline-filter-sheet\" class=\"timeline-filter-sheet\" aria-label=\"时间轴筛选\" aria-modal=\"false\" data-open=\"false\" role=\"dialog\" tabindex=\"-1\"><div class=\"timeline-filter-sheet-head\"><div><strong>筛选时间轨迹</strong><span id=\"timeline-filter-result\" role=\"status\" aria-live=\"polite\">0 个时间节点</span></div><button id=\"timeline-filter-close\" class=\"timeline-filter-close\" type=\"button\">完成</button></div><section><h3>主题</h3><div id=\"timeline-category-filters\" class=\"timeline-filter-list\"></div></section><section><h3>数据边界</h3><p id=\"timeline-status-filters\" class=\"timeline-filter-note\">当前时间轴仅展示已发布笔记。</p></section></aside>\n"
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
  "Generate the offline chronological-reading page.
Interactive calls run in an isolated background Emacs process."
  (interactive)
  (if (called-interactively-p 'interactive)
      (org-museum--start-background-job 'export-timeline nil)
    (org-museum--run-with-current-runtime
     'org-museum-export-timeline nil #'org-museum--export-timeline-current)))

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
      <p>从笔记出发，沿真实关系继续阅读。</p>
    </div>
    <nav class=\"graph-mode-tabs\" aria-label=\"图谱工作模式\">
      <button type=\"button\" data-graph-view=\"relations\" aria-pressed=\"true\">关系阅读 <b id=\"graph-relation-count\">00</b></button>
      <button type=\"button\" data-graph-view=\"triage\" aria-pressed=\"false\">待连接 <b id=\"graph-triage-count\">00</b></button>
    </nav>
    <details class=\"graph-filter-summary\">
      <summary>范围 <span id=\"graph-filter-label\">全部主题</span></summary>
      <div id=\"graph-category-filters\"></div>
    </details>
    <label class=\"graph-relation-filter\">关系
      <select id=\"graph-relation-filter\" aria-label=\"筛选关系类型\"><option value=\"*\">全部关系</option></select>
    </label>
    <details class=\"graph-layout-menu\">
      <summary><i data-graph-icon=\"rows\"></i><span id=\"graph-layout-label\">拓扑语义层级流</span></summary>
      <div class=\"graph-layout-panel\" aria-label=\"选择拓扑布局\">
        <div class=\"graph-layout-panel-head\"><strong>拓扑布局</strong><small>选择一种结构，重新整理画布</small></div>
        <label class=\"graph-layout-search-label\">搜索布局<input id=\"graph-layout-search\" type=\"search\" placeholder=\"搜索布局名称、用途…\" autocomplete=\"off\"></label>
        <div id=\"graph-layout-categories\" class=\"graph-layout-categories\" aria-label=\"布局类别\"></div>
        <div id=\"graph-layout-options\" class=\"graph-layout-options\"></div>
      </div>
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
      </div>
      <button type=\"button\" id=\"btn-layout\" aria-label=\"随机切换布局\"><i data-graph-icon=\"rows\"></i><span>随机切换布局</span></button>
    </div>
    <p id=\"graph-match-status\" role=\"status\" aria-live=\"polite\">匹配 00 个节点</p>
  </header>
  <section class=\"museum-graph-workspace\" aria-label=\"知识关系画布\">
    <div class=\"graph-canvas-stage\">
      <div id=\"graph-canvas\" tabindex=\"-1\"></div>
      <aside class=\"graph-relation-legend\" aria-label=\"关系类型图例\">
        <strong>关系类型</strong><ul id=\"graph-relation-legend\"></ul>
      </aside>
    </div>
    <div id=\"graph-zero-notice\" hidden>
      <strong>尚未形成知识连线</strong>
      <span>选择一篇笔记，可在详情中新增关系；正文里的 Wiki 链接也会自动进入图谱。</span>
      <button type=\"button\" id=\"graph-zero-copy\">选择笔记</button>
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
          <section><h3>阅读路径与依据</h3><div id=\"graph-neighbours\"></div></section>
        </div>
        <nav class=\"graph-inspector-actions\" aria-label=\"连续阅读操作\">
          <a id=\"graph-open-link\" href=\"index.html\">打开笔记</a>
          <a id=\"graph-related-link\" href=\"related.html\" hidden>关联阅读</a>
        </nav>
      </article>
      <ul id=\"graph-legend\" aria-label=\"主题图例\"></ul>
    </div>
  </section>
</main>
<script type=\"application/json\" id=\"graph-data\">%s</script>
<script src=\"%s\"></script>
<script src=\"%s\"></script>
<script src=\"%s\"></script>
<script>
(function(){
'use strict';
if(window.orgMuseumGraphNetwork)return;
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
var graphSelectedMeta=document.getElementById('graph-selected-meta');
var graphSelectedTitle=document.getElementById('graph-selected-title');
var graphSelectedTags=document.getElementById('graph-selected-tags');
var graphSelectedDescription=document.getElementById('graph-selected-description');
var graphSelectedFacts=document.getElementById('graph-selected-facts');
var workspaceFooter=document.querySelector('.graph-workspace-footer');
var footerAnchor=document.createComment('graph-inspector-anchor');
if(workspaceFooter&&workspaceFooter.parentNode)workspaceFooter.parentNode.insertBefore(footerAnchor,workspaceFooter);
var relationLegend=document.getElementById('graph-relation-legend');
var relationFilter=document.getElementById('graph-relation-filter');
var layoutMenu=document.getElementById('graph-layout-options');
var layoutLabel=document.getElementById('graph-layout-label');
var layoutSearch=document.getElementById('graph-layout-search');
var layoutCategories=document.getElementById('graph-layout-categories');
var cats=Array.from(new Set(nodes.map(function(node){return node.group||'';}).filter(Boolean))).sort();
var relationTypes=Array.from(new Set(links.map(function(edge){return edge.type||'显式链接';}))).sort();
var graphParams=new URLSearchParams(location.search);
var focusId=graphParams.get('focus')||'';
var requestedCategory=graphParams.get('category')||'*';
var requestedRelation=graphParams.get('relation')||'*';
var layoutModes={
  semantic:{label:'拓扑语义层级流',category:'hierarchical',hint:'按有向关系分层，适合依赖与知识演进'},
  dagre:{label:'Dagre 严格分层',category:'hierarchical',hint:'按前置关系分层并调整行序，减少交叉'},
  treeVertical:{label:'纵向层级树',category:'hierarchical',hint:'从上到下展开主干和分支'},
  treeHorizontal:{label:'横向层级树',category:'hierarchical',hint:'从左到右阅读长链路'},
  organic:{label:'有机力导向',category:'network',hint:'引力与斥力呈现自然关系网络'},
  clusteredForce:{label:'社区重心极坐标',category:'network',hint:'按关联社群聚拢，社群沿环分布'},
  groupedCircular:{label:'分组环形',category:'network',hint:'按笔记主题形成多个关系环'},
  concentric:{label:'同心圆同轴径向',category:'radial',hint:'核心节点居中，关系距离向外展开'},
  starburst:{label:'星系辐射',category:'radial',hint:'从关系枢纽向周围发散'},
  dandelion:{label:'蒲公英扇形径向',category:'radial',hint:'按主题分扇区，从核心向外展开'},
  spoke:{label:'轮辐辐射骨架',category:'radial',hint:'均匀分布直接分支和外围节点'},
  grid:{label:'同质正交网格',category:'grid',hint:'规则排列，适合均匀扫描笔记'}
};
var layoutCategoryNames={hierarchical:'层级结构',network:'网状结构',radial:'辐射结构',grid:'网格结构'};
var storedLayout='semantic';
try{storedLayout=localStorage.getItem('org-museum-graph-layout')||'semantic';}catch(_layoutModeError){}
if(!layoutModes[storedLayout])storedLayout='semantic';
var requestedView=graphParams.get('view')||'relations';
var focusIsValid=!focusId||nodes.some(function(node){return node.id===focusId;});
var categoryIsValid=requestedCategory==='*'||cats.indexOf(requestedCategory)>=0;
var relationIsValid=requestedRelation==='*'||relationTypes.indexOf(requestedRelation)>=0;
var viewIsValid=requestedView==='relations'||requestedView==='triage';
var graphUrlNeedsCleanup=!focusIsValid||!categoryIsValid||!relationIsValid||!viewIsValid;
var state={query:'',category:'*',relation:relationIsValid?requestedRelation:'*',layout:storedLayout,
  view:viewIsValid?requestedView:'relations',selectedId:
  focusIsValid?focusId:''};
state.query=(graphParams.get('q')||'').trim().toLowerCase();
state.category=categoryIsValid?requestedCategory:'*';
var graphReady=false;
var isZeroLinkGraph=links.length===0;
var isolatedNodes=nodes.filter(function(node){return (node.degree||0)===0;});
var canvasNodes=isZeroLinkGraph?[]:nodes.filter(function(node){return (node.degree||0)>0;});
var compactRelationMode=canvasNodes.length>0&&canvasNodes.length<=4;
var hasIsolatedNodes=isolatedNodes.length>0;
if(focusId&&state.view==='relations'&&isolatedNodes.some(function(node){return node.id===focusId;}))state.view='triage';
var motionQuery=window.matchMedia('(prefers-reduced-motion: reduce)');
var mobileGraphMedia=window.matchMedia('(max-width:820px)');
var reduceMotion=motionQuery.matches;
if(selectedDetail)selectedDetail.hidden=true;

function count(value){return String(value).padStart(2,'0');}
function categoryLabel(value){return value==='AIL'?'AI':value==='Sql'?'SQL':(value||'');}
if(search)search.value=state.query;
function writeGraphUrl(mode){
  var url=new URL(location.href);
  ['q','category','relation','focus','view'].forEach(function(key){url.searchParams.delete(key);});
  if(state.query)url.searchParams.set('q',state.query);
  if(state.category!=='*')url.searchParams.set('category',state.category);
  if(state.relation!=='*')url.searchParams.set('relation',state.relation);
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
  if(!group)return 'var(--museum-ink-muted)';
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
  if(!node)return false;
  var catOk=state.category==='*'||node.group===state.category;
  var hay=[node.name,node.group].concat(node.tags||[]).join(' ').toLowerCase();
  var relationOk=state.relation==='*'||links.some(function(edge){
    return edge.type===state.relation&&
      ((edge.source.id||edge.source)===node.id||(edge.target.id||edge.target)===node.id);
  });
  return catOk&&relationOk&&(!state.query||hay.indexOf(state.query)>=0);
}
function visibleEdge(edge){
  if(state.relation!=='*'&&edge.type!==state.relation)return false;
  var source=nodes.find(function(node){return node.id===(edge.source.id||edge.source);});
  var target=nodes.find(function(node){return node.id===(edge.target.id||edge.target);});
  return matches(source)&&matches(target);
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
    cats.concat(visible.some(function(node){return !node.group;})?['']:[]).forEach(function(cat){
      var groupNodes=visible.filter(function(node){return (node.group||'')===cat;});
      if(!groupNodes.length)return;
      var section=document.createElement('section');section.className='graph-isolated-group';
      var heading=document.createElement('h3');
      heading.textContent=cat?categoryLabel(cat)+' · '+count(groupNodes.length):'';
      if(!cat)heading.hidden=true;
      var grid=document.createElement('div');grid.className='graph-isolated-grid';
      groupNodes.forEach(function(node){
        var row=document.createElement('article');row.dataset.status=node.status||'published';row.dataset.nodeId=node.id;
        var link=document.createElement('a');link.href=themed(node.url||'index.html');link.textContent=node.name;
        var meta=document.createElement('small');
        meta.textContent=(node.group?categoryLabel(node.group)+' · ':'')+
          (node.status==='draft'?'草稿':'已发布')+' · 更新 '+formatDate(node.modified);
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
                category:categoryLabel(candidate.group)};})});
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
if(relationFilter){
  relationTypes.forEach(function(type){
    var option=document.createElement('option');option.value=type;option.textContent=type;
    relationFilter.appendChild(option);
  });
  relationFilter.value=state.relation;
  relationFilter.addEventListener('change',function(){
    state.relation=relationFilter.value;
    if(state.selectedId&&!matches(nodes.find(function(node){return node.id===state.selectedId;})))
      clearSelection(false,true);
    writeGraphUrl('push');
    if(graphReady)applyFilter();
    if(hasIsolatedNodes)renderFallbackList();
  });
}
var layoutCategory='*';
function renderLayoutOptions(){
  if(!layoutMenu)return;
  var query=layoutSearch?layoutSearch.value.trim().toLowerCase():'';
  layoutMenu.textContent='';
  if(layoutCategories){
    layoutCategories.textContent='';
    ['*','hierarchical','network','radial','grid'].forEach(function(category){
      var button=document.createElement('button');
      var count=category==='*'?Object.keys(layoutModes).length:Object.keys(layoutModes).filter(function(key){return layoutModes[key].category===category;}).length;
      button.type='button';button.textContent=(layoutCategoryNames[category]||'全部')+' '+count;
      button.setAttribute('aria-pressed',category===layoutCategory?'true':'false');
      button.addEventListener('click',function(){layoutCategory=category;renderLayoutOptions();});
      layoutCategories.appendChild(button);
    });
  }
  var matchesLayout=Object.keys(layoutModes).filter(function(key){
    var mode=layoutModes[key];
    return (layoutCategory==='*'||mode.category===layoutCategory)&&
      (!query||(mode.label+' '+mode.hint+' '+layoutCategoryNames[mode.category]).toLowerCase().includes(query));
  });
  matchesLayout.forEach(function(key){
    var mode=layoutModes[key],button=document.createElement('button');
    button.type='button';button.dataset.layout=key;
    button.setAttribute('aria-pressed',key===state.layout?'true':'false');
    var caption=document.createElement('span');caption.className='graph-layout-caption';
    var title=document.createElement('strong');title.textContent=mode.label;
    var group=document.createElement('em');group.textContent=layoutCategoryNames[mode.category];
    var hint=document.createElement('small');hint.textContent=mode.hint;
    caption.appendChild(title);caption.appendChild(group);button.appendChild(caption);button.appendChild(hint);
    button.addEventListener('click',function(){setLayoutMode(key);});
    layoutMenu.appendChild(button);
  });
  if(!matchesLayout.length){var empty=document.createElement('p');empty.textContent='没有匹配的布局';layoutMenu.appendChild(empty);}
  if(layoutLabel)layoutLabel.textContent=layoutModes[state.layout].label;
}
if(layoutSearch)layoutSearch.addEventListener('input',renderLayoutOptions);
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
  var groups=[['前置 / 基础',[]],['延伸阅读',[]],['反向链接',[]],['相互关联',[]]];
  links.forEach(function(edge){
    var source=edge.source.id||edge.source,target=edge.target.id||edge.target;
    if(source!==node.id&&target!==node.id)return;
    var outgoing=source===node.id,otherId=outgoing?target:source;
    var other=nodes.find(function(entry){return entry.id===otherId;});
    if(!other)return;
    var label=edge.type||'显式链接';
    var prerequisite=/(前置|先修|基础|依赖|prereq|requires)/i.test(label);
    var group=edge.bidirectional?groups[3]:prerequisite?groups[0]:outgoing?groups[1]:groups[2];
    group[1].push({other:other,label:label,outgoing:outgoing});
  });
  groups.forEach(function(group){
    var section=document.createElement('section');section.className='graph-reading-group';
    var heading=document.createElement('h4');heading.textContent=group[0]+' · '+group[1].length;
    section.appendChild(heading);
    if(!group[1].length){
      var empty=document.createElement('p');empty.className='graph-reading-empty';
      empty.textContent='暂无已记录关系';section.appendChild(empty);
    }
    group[1].sort(function(a,b){return a.other.name.localeCompare(b.other.name,'zh-CN');});
    group[1].forEach(function(item){
      var row=document.createElement('div');row.className='graph-reading-row';
      var choose=document.createElement('button');choose.type='button';
      choose.textContent=item.other.name;
      choose.addEventListener('click',function(){selectNode(item.other,true);});
      var open=document.createElement('a');open.href=themed(nodeHref(item.other));
      open.textContent='打开正文';open.setAttribute('aria-label','打开'+item.other.name+'正文');
      var evidence=document.createElement('small');
      evidence.textContent=(item.outgoing?'本篇指向对方':'对方指向本篇')+
        ' · '+(item.label==='显式链接'?'正文中的真实链接':'关系标注：'+item.label);
      row.appendChild(choose);row.appendChild(open);row.appendChild(evidence);
      section.appendChild(row);
    });
    graphNeighbours.appendChild(section);
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
  if(!matches(node)){
    state.query='';state.category='*';state.relation='*';
    if(search)search.value='';if(relationFilter)relationFilter.value='*';
    syncGraphCategoryControls();
  }
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
  graphSelectedMeta.textContent=(node.group?categoryLabel(node.group)+' · ':'')+
    count(node.degree||0)+' 条直接关系';
  graphSelectedTitle.textContent=node.name||'未命名';
  graphSelectedDescription.textContent=(node.description||'').trim()||'这篇笔记尚未提供摘要，可打开正文继续阅读。';
  graphSelectedTags.textContent='';
  (node.tags||[]).forEach(function(tag){var chip=document.createElement('span');chip.textContent='#'+tag;graphSelectedTags.appendChild(chip);});
  graphSelectedFacts.textContent='';
  appendFact('创建',formatDate(node.created));appendFact('更新',formatDate(node.modified));
  appendFact('状态',node.status==='draft'?'草稿':'已发布');
  appendFact('来源',node.id);
  graphOpenLink.href=themed(nodeHref(node));
  renderNeighbourList(node);
  var next=(node.linksTo||[])[0],previous=(node.linkedFrom||[])[0];
  if(graphRelatedLink){
    graphRelatedLink.hidden=!(next||previous);
    if(next)graphRelatedLink.href=themed('related.html?source='+encodeURIComponent(node.id)+'&target='+encodeURIComponent(next));
    else if(previous)graphRelatedLink.href=themed('related.html?source='+encodeURIComponent(previous)+'&target='+encodeURIComponent(node.id));
  }
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

renderFilters();renderLegend();renderLayoutOptions();
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
  .attr('aria-label','Org Museum 知识图谱')
  .style('display','block')
  .style('width','100%%')
  .style('height','100%%')
  .style('pointer-events','all')
  .style('cursor','grab');
var bgCatcher=svg.append('rect')
  .attr('class','graph-canvas-catcher')
  .attr('width','100%%')
  .attr('height','100%%')
  .attr('fill','transparent')
  .style('pointer-events','all')
  .style('cursor','grab');
var layer=svg.append('g');
var defs=svg.append('defs');
defs.append('marker').attr('id','graph-arrow').attr('viewBox','0 -5 10 10')
  .attr('refX',18).attr('refY',0).attr('markerWidth',6).attr('markerHeight',6)
  .attr('orient','auto-start-reverse').append('path').attr('d','M0,-5L10,0L0,5').attr('fill','context-stroke');
var zoomScale=1;
var zoom=d3.zoom().scaleExtent([0.1,5])
  .wheelDelta(function(event){
    return -event.deltaY * (event.deltaMode === 1 ? 0.05 : event.deltaMode ? 1 : 0.002);
  })
  .filter(function(event){
    if(event.button === 2) return false;
    if(event.type === 'wheel') return true;
    return event.button === 0 || event.button === 1;
  })
  .on('zoom',function(event){
  zoomScale=event.transform.k;
  layer.attr('transform',event.transform);
  document.getElementById('btn-zoom-in').disabled=zoomScale>=4.999;
  document.getElementById('btn-zoom-out').disabled=zoomScale<=0.101;
  layer.classed('graph-labels-dense',event.transform.k>=0.9);
  if(nodeSelection){
    nodeSelection.select('.graph-node-title').style('display',event.transform.k>=0.62?null:'none');
    nodeSelection.select('.graph-node-category').style('display',event.transform.k>=0.95?null:'none');
  }
  if(linkLabelSelection){
    linkLabelSelection.style('display',function(edge){
      var source=edge.source.id||edge.source,target=edge.target.id||edge.target;
      return event.transform.k>=1.05&&
        (source===state.selectedId||target===state.selectedId||
         source===hoveredId||target===hoveredId)?null:'none';
    });
  }
  // [UI-03] Keep graph-node pointer targets at least as large as the 44px UI baseline.
  if(nodeSelection)nodeSelection.select('.graph-node-hit-target')
    .attr('r',Math.min(30,26/zoomScale));
});
svg.call(zoom).on('dblclick.zoom',null);
svg.on('mousedown.middle-prevent',function(event){
  if(event.button === 1) event.preventDefault();
});
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
    return (node.name||'未命名')+(node.group?'，'+node.group:'')+'，'+
      count(node.degree||0)+' 条关系'+(node.status==='draft'?'，草稿':'')+
      '，单击或 Space 选择，双击或 Enter 打开笔记';
  });
graphReady=true;
nodeSelection.append('title').text(function(node){return node.name||'未命名';});
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
  var result='',units=0,letters=Array.from(name);
  for(var i=0;i<letters.length;i+=1){
    var next=letters[i].codePointAt(0)>127?2:1;
    if(units+next>20)return result+'…';
    result+=letters[i];units+=next;
  }
  return result;
}
nodeSelection.append('text').attr('x',19).attr('y',1)
  .attr('class','graph-node-title')
  .text(nodeLabelText);
nodeSelection.append('text').attr('x',19).attr('y',20)
  .attr('class','graph-node-category')
  .text(function(node){return categoryLabel(node.group);});
function measureNodeLabels(){
  nodeSelection.select('text').text(nodeLabelText);
  nodeSelection.each(function(node){
    var label=this.querySelector('text');
    node.labelWidth=label?Math.ceil(label.getComputedTextLength()):0;
  });
}
measureNodeLabels();

function positionNodeLabels(){
  nodeSelection.select('.graph-node-category')
    .style('display',function(node){return node.group?'':'none';});
}
function constrainNode(node){
  if(!Number.isFinite(node.x))node.x=0;
  if(!Number.isFinite(node.y))node.y=0;
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
}
var layoutStorageKey='org-museum-graph-positions:'+location.pathname+':'+state.layout;
var manualPositions={};
try{manualPositions=JSON.parse(localStorage.getItem(layoutStorageKey)||'{}')||{};}
catch(_layoutReadError){manualPositions={};}
function saveManualPositions(){
  try{localStorage.setItem(layoutStorageKey,JSON.stringify(manualPositions));}
  catch(_layoutWriteError){}
}
function fitView(ids){
  var visible=canvasNodes.filter(function(node){return matches(node)&&(!ids||ids.has(node.id));});
  if(!visible.length){svg.call(zoom.transform,d3.zoomIdentity);return;}
  var xs=visible.map(function(node){return node.x||0;});
  var ys=visible.map(function(node){return node.y||0;});
  var minX=Math.min.apply(null,xs),maxX=Math.max.apply(null,xs);
  var minY=Math.min.apply(null,ys),maxY=Math.max.apply(null,ys);
  var centerX=(minX+maxX)/2,centerY=(minY+maxY)/2;
  var marginX=90,marginY=55,safePad=32;
  var bw=Math.max(maxX-minX+marginX*2,80);
  var bh=Math.max(maxY-minY+marginY*2,80);
  var availableW=Math.max(120,width-safePad*2);
  var availableH=Math.max(120,height-safePad*2);
  var scale=Math.max(0.1,Math.min(1.35,Math.min(availableW/bw,availableH/bh)));
  var tx=width/2-centerX*scale;
  var ty=height/2-centerY*scale;
  svg.call(zoom.transform,d3.zoomIdentity.translate(tx,ty).scale(scale));
}
function applyAutoLayout(){
  var visible=canvasNodes.filter(matches),positions=new Map();
  if(!visible.length){renderTick();return false;}
  var byId=new Map(visible.map(function(node){return [node.id,node];}));
  var edges=links.filter(visibleEdge).map(function(edge){return {source:edge.source.id||edge.source,target:edge.target.id||edge.target,type:edge.type};})
    .filter(function(edge){return byId.has(edge.source)&&byId.has(edge.target)&&edge.source!==edge.target;});
  var adjacent=new Map(),outgoing=new Map(),incoming=new Map();
  visible.forEach(function(node){adjacent.set(node.id,new Set());outgoing.set(node.id,new Set());incoming.set(node.id,new Set());});
  edges.forEach(function(edge){
    adjacent.get(edge.source).add(edge.target);adjacent.get(edge.target).add(edge.source);
    outgoing.get(edge.source).add(edge.target);incoming.get(edge.target).add(edge.source);
  });
  function rank(a,b){
    return adjacent.get(b.id).size-adjacent.get(a.id).size||
      (a.group||'').localeCompare(b.group||'','zh-CN')||(a.name||'').localeCompare(b.name||'','zh-CN')||a.id.localeCompare(b.id);
  }
  var ordered=visible.slice().sort(rank),cx=width/2,cy=height/2;
  function put(node,x,y){positions.set(node.id,{x:x,y:y});}
  function groupsOf(items,key){
    var groups=new Map();
    items.forEach(function(node){
      var name=key(node);
      if(!groups.has(name))groups.set(name,[]);
      groups.get(name).push(node);
    });
    return Array.from(groups.values());
  }

  // 1. Cycle Breaking via DFS (from DuckDB Editor applyTopologicalFlowLayout)
  var visited=new Set(),inStack=new Set(),backEdges=new Set();
  function detectBackEdges(u){
    visited.add(u);inStack.add(u);
    var children=Array.from(outgoing.get(u)||[]).sort(function(a,b){return rank(byId.get(a),byId.get(b));});
    children.forEach(function(v){
      if(!visited.has(v))detectBackEdges(v);
      else if(inStack.has(v))backEdges.add(u+'|'+v);
    });
    inStack.delete(u);
  }
  ordered.forEach(function(node){if(!visited.has(node.id))detectBackEdges(node.id);});

  // 2. Longest-Path DAG Layering
  function topologicalGroups(){
    var dagInDeg=new Map(),ranks=new Map();
    visible.forEach(function(node){
      var deg=0;
      (incoming.get(node.id)||[]).forEach(function(p){if(!backEdges.has(p+'|'+node.id))deg++;});
      dagInDeg.set(node.id,deg);
    });
    var queue=ordered.filter(function(node){return (dagInDeg.get(node.id)||0)===0;}).map(function(node){return node.id;});
    if(!queue.length&&visible.length)queue=[ordered[0].id];
    queue.forEach(function(id){ranks.set(id,0);});
    var cursor=0;
    while(cursor<queue.length){
      var u=queue[cursor++];
      var rU=ranks.get(u)||0;
      (outgoing.get(u)||[]).forEach(function(v){
        if(backEdges.has(u+'|'+v))return;
        var nextR=rU+1;
        if(!ranks.has(v)||ranks.get(v)<nextR){
          ranks.set(v,nextR);
          queue.push(v);
        }
      });
    }
    visible.forEach(function(node){if(!ranks.has(node.id))ranks.set(node.id,0);});
    var allRanks=Array.from(new Set(Array.from(ranks.values()))).sort(function(a,b){return a-b;});
    var rankMap=new Map(allRanks.map(function(r,i){return [r,i];}));
    var layers=Array.from({length:Math.max(allRanks.length,1)},function(){return [];});
    visible.forEach(function(node){
      var lIdx=rankMap.get(ranks.get(node.id))||0;
      layers[lIdx].push(node);
    });
    return layers.filter(function(l){return l.length>0;});
  }

  // 3. Tree Depth Layering
  function depthGroups(tree){
    var depth=new Map(),todo=[],unseen=new Set(visible.map(function(node){return node.id;}));
    while(unseen.size){
      var root=ordered.find(function(node){return unseen.has(node.id)&&incoming.get(node.id).size===0;})||
        ordered.find(function(node){return unseen.has(node.id);});
      depth.set(root.id,0);unseen.delete(root.id);todo.push(root.id);
      while(todo.length){
        var id=todo.shift();
        var next=tree?Array.from(outgoing.get(id)):Array.from(adjacent.get(id));
        next.sort(function(a,b){return rank(byId.get(a),byId.get(b));});
        next.forEach(function(other){
          if(unseen.has(other)){unseen.delete(other);depth.set(other,depth.get(id)+1);todo.push(other);}
        });
      }
    }
    var result=[];
    ordered.forEach(function(node){
      var level=depth.get(node.id)||0;
      if(!result[level])result[level]=[];
      result[level].push(node);
    });
    return result.filter(Boolean);
  }

  // 4. Bi-directional Barycentric Crossing Minimization with Adjacent Transposition (from DuckDB Editor)
  function minimizeCrossings(layers){
    var K=layers.length;
    if(K<=1)return layers;
    for(var sweep=0;sweep<8;sweep++){
      var forward=sweep%%2===0;
      if(forward){
        for(var layerIdx=1;layerIdx<K;layerIdx++){
          var prevLayer=layers[layerIdx-1];
          var prevPos=new Map(prevLayer.map(function(n,i){return [n.id,i];}));
          layers[layerIdx].sort(function(a,b){
            var predsA=Array.from(incoming.get(a.id)||[]).filter(function(id){return prevPos.has(id);});
            var predsB=Array.from(incoming.get(b.id)||[]).filter(function(id){return prevPos.has(id);});
            var bcA=predsA.length?predsA.reduce(function(s,id){return s+prevPos.get(id);},0)/predsA.length:layers[layerIdx].indexOf(a);
            var bcB=predsB.length?predsB.reduce(function(s,id){return s+prevPos.get(id);},0)/predsB.length:layers[layerIdx].indexOf(b);
            return bcA-bcB||rank(a,b);
          });
          var cur=layers[layerIdx];
          for(var p=0;p<cur.length-1;p++){
            var u=cur[p],v=cur[p+1];
            var uPreds=Array.from(incoming.get(u.id)||[]).map(function(id){return prevPos.get(id);}).filter(function(x){return x!==undefined;});
            var vPreds=Array.from(incoming.get(v.id)||[]).map(function(id){return prevPos.get(id);}).filter(function(x){return x!==undefined;});
            var cb=0,ca=0;
            uPreds.forEach(function(pu){vPreds.forEach(function(pv){if(pu>pv)cb++;if(pv>pu)ca++;});});
            if(ca<cb){cur[p]=v;cur[p+1]=u;}
          }
        }
      }else{
        for(var layerIdx=K-2;layerIdx>=0;layerIdx--){
          var nextLayer=layers[layerIdx+1];
          var nextPos=new Map(nextLayer.map(function(n,i){return [n.id,i];}));
          layers[layerIdx].sort(function(a,b){
            var succsA=Array.from(outgoing.get(a.id)||[]).filter(function(id){return nextPos.has(id);});
            var succsB=Array.from(outgoing.get(b.id)||[]).filter(function(id){return nextPos.has(id);});
            var bcA=succsA.length?succsA.reduce(function(s,id){return s+nextPos.get(id);},0)/succsA.length:layers[layerIdx].indexOf(a);
            var bcB=succsB.length?succsB.reduce(function(s,id){return s+nextPos.get(id);},0)/succsB.length:layers[layerIdx].indexOf(b);
            return bcA-bcB||rank(a,b);
          });
          var cur=layers[layerIdx];
          for(var p=0;p<cur.length-1;p++){
            var u=cur[p],v=cur[p+1];
            var uSuccs=Array.from(outgoing.get(u.id)||[]).map(function(id){return nextPos.get(id);}).filter(function(x){return x!==undefined;});
            var vSuccs=Array.from(outgoing.get(v.id)||[]).map(function(id){return nextPos.get(id);}).filter(function(x){return x!==undefined;});
            var cb=0,ca=0;
            uSuccs.forEach(function(su){vSuccs.forEach(function(sv){if(su>sv)cb++;if(sv>su)ca++;});});
            if(ca<cb){cur[p]=v;cur[p+1]=u;}
          }
        }
      }
    }
    return layers;
  }

  // 5. Channel-aware layer coordinate placement
  function placeLayers(layers,horizontal,barycentric){
    if(barycentric)minimizeCrossings(layers);
    var K=layers.length;
    var maxSpan=1;
    edges.forEach(function(e){
      var lA=-1,lB=-1;
      layers.forEach(function(grp,li){
        if(grp.some(function(n){return n.id===e.source;}))lA=li;
        if(grp.some(function(n){return n.id===e.target;}))lB=li;
      });
      if(lA>=0&&lB>=0)maxSpan=Math.max(maxSpan,Math.abs(lB-lA));
    });
    var channelGap=Math.min(70,(maxSpan-1)*16);
    var layerSpacing=(horizontal?250:135)+channelGap;
    var maxLayerLen=Math.max.apply(null,layers.map(function(l){return l.length;}));
    var crossSpacing=horizontal?Math.max(85,Math.min(125,(height-120)/Math.max(1,maxLayerLen))):
      Math.max(165,Math.min(235,(width-120)/Math.max(1,maxLayerLen)));

    layers.forEach(function(group,level){
      var totalCross=(group.length-1)*crossSpacing;
      var startCross=(horizontal?cy:cx)-totalCross/2;
      var startLevel=(horizontal?cx:cy)-((K-1)*layerSpacing)/2;
      var levelPos=startLevel+level*layerSpacing;
      group.forEach(function(node,index){
        var crossPos=startCross+index*crossSpacing;
        if(horizontal)put(node,levelPos,crossPos);
        else put(node,crossPos,levelPos);
      });
    });
  }

  // 6. Category Affinity Matrix & Circular Spectral Ordering (from DuckDB Editor)
  var catAffinity=new Map();
  edges.forEach(function(e){
    var nA=byId.get(e.source),nB=byId.get(e.target);
    if(!nA||!nB)return;
    var cA=nA.group||'其他',cB=nB.group||'其他';
    if(cA!==cB){
      var key=cA<cB?cA+'|'+cB:cB+'|'+cA;
      catAffinity.set(key,(catAffinity.get(key)||0)+1);
    }
  });
  function orderCategoriesCirculary(categories){
    if(categories.length<=2)return categories.slice();
    var rem=new Set(categories);
    var first=categories[0],bestCount=-1;
    categories.forEach(function(cat){
      var deg=0;
      categories.forEach(function(other){
        var key=cat<other?cat+'|'+other:other+'|'+cat;
        deg+=catAffinity.get(key)||0;
      });
      if(deg>bestCount){bestCount=deg;first=cat;}
    });
    var orderedCats=[first];
    rem.delete(first);
    while(rem.size>0){
      var curr=orderedCats[orderedCats.length-1];
      var next=null,maxAff=-1;
      rem.forEach(function(cand){
        var key=curr<cand?curr+'|'+cand:cand+'|'+curr;
        var aff=catAffinity.get(key)||0;
        if(aff>maxAff){maxAff=aff;next=cand;}
      });
      if(!next||maxAff===0)next=Array.from(rem)[0];
      orderedCats.push(next);
      rem.delete(next);
    }
    return orderedCats;
  }

  function ring(items,x,y,r,start,span){
    items.forEach(function(node,index){
      var angle=start+span*index/Math.max(1,items.length);
      put(node,x+Math.cos(angle)*r,y+Math.sin(angle)*r);
    });
  }

  function forceLayout(){
    ordered.forEach(function(node,index){
      var angle=index*2.39996,r=50+Math.sqrt(index)*95;
      put(node,cx+Math.cos(angle)*r,cy+Math.sin(angle)*r);
    });
    for(var step=0;step<140;step+=1){
      var delta=new Map(ordered.map(function(node){return [node.id,{x:0,y:0}];}));
      for(var i=0;i<ordered.length;i+=1)for(var j=i+1;j<ordered.length;j+=1){
        var a=positions.get(ordered[i].id),b=positions.get(ordered[j].id),dx=b.x-a.x,dy=b.y-a.y;
        var distance=Math.max(1,Math.hypot(dx,dy)),push=Math.min(20,9500/(distance*distance));
        delta.get(ordered[i].id).x-=dx/distance*push;delta.get(ordered[i].id).y-=dy/distance*push;
        delta.get(ordered[j].id).x+=dx/distance*push;delta.get(ordered[j].id).y+=dy/distance*push;
      }
      edges.forEach(function(edge){
        var a=positions.get(edge.source),b=positions.get(edge.target),dx=b.x-a.x,dy=b.y-a.y;
        var distance=Math.max(1,Math.hypot(dx,dy)),pull=(distance-220)*.014;
        delta.get(edge.source).x+=dx/distance*pull;delta.get(edge.source).y+=dy/distance*pull;
        delta.get(edge.target).x-=dx/distance*pull;delta.get(edge.target).y-=dy/distance*pull;
      });
      ordered.forEach(function(node){
        var p=positions.get(node.id),d=delta.get(node.id);
        p.x+=d.x*.45+(cx-p.x)*.002;p.y+=d.y*.45+(cy-p.y)*.002;
      });
    }
  }

  function communities(){
    var membership=new Map(ordered.map(function(node){return [node.id,node.id];}));
    var total=Math.max(1,edges.length*2);
    for(var pass=0;pass<10;pass+=1){
      var changed=false;
      var volumes=new Map();
      ordered.forEach(function(node){var id=membership.get(node.id);volumes.set(id,(volumes.get(id)||0)+adjacent.get(node.id).size);});
      ordered.forEach(function(node){
        var degree=adjacent.get(node.id).size;if(!degree)return;
        var current=membership.get(node.id),candidates=new Set([current]);
        volumes.set(current,volumes.get(current)-degree);
        adjacent.get(node.id).forEach(function(id){candidates.add(membership.get(id));});
        var best=current,bestScore=-Infinity;
        candidates.forEach(function(candidate){
          var internal=Array.from(adjacent.get(node.id)).filter(function(id){return membership.get(id)===candidate;}).length;
          var volume=volumes.get(candidate)||0;
          var score=internal-degree*volume/total;
          if(score>bestScore+1e-8||(Math.abs(score-bestScore)<1e-8&&candidate<best)){best=candidate;bestScore=score;}
        });
        volumes.set(best,(volumes.get(best)||0)+degree);
        if(best!==current){membership.set(node.id,best);changed=true;}
      });
      if(!changed)break;
    }
    return groupsOf(ordered,function(node){return membership.get(node.id);});
  }

  var mode=state.layout;
  if(mode==='semantic'){
    // Semantic flow: left-to-right DAG topological flow with Sugiyama crossing reduction & channel routing
    placeLayers(topologicalGroups(),true,true);
  }else if(mode==='dagre'){
    // Dagre: strict top-to-bottom DAG with crossing minimization
    placeLayers(topologicalGroups(),false,true);
  }else if(mode==='treeVertical'){
    placeLayers(depthGroups(true),false,true);
  }else if(mode==='treeHorizontal'){
    placeLayers(depthGroups(true),true,true);
  }else if(mode==='organic'){
    forceLayout();
  }else if(mode==='clusteredForce'||mode==='groupedCircular'){
    // Community-Centric / Grouped Circular with Macro Circular Ordering
    var isCluster=mode==='clusteredForce';
    var rawGroups=isCluster?communities():groupsOf(ordered,function(node){return node.group||'其他';});
    var groupKeys=rawGroups.map(function(g){return g[0].group||'其他';});
    var orderedKeys=orderCategoriesCirculary(Array.from(new Set(groupKeys)));
    var sortedGroups=rawGroups.slice().sort(function(a,b){
      var kA=a[0].group||'其他',kB=b[0].group||'其他';
      return orderedKeys.indexOf(kA)-orderedKeys.indexOf(kB);
    });
    var outerRadius=Math.max(260,sortedGroups.length*130);
    sortedGroups.forEach(function(group,index){
      var angle=2*Math.PI*index/sortedGroups.length-Math.PI/2;
      var gx=cx+(sortedGroups.length===1?0:outerRadius*Math.cos(angle));
      var gy=cy+(sortedGroups.length===1?0:outerRadius*Math.sin(angle));
      var gRadius=isCluster?Math.max(75,Math.sqrt(group.length)*95):Math.max(115,group.length*44);
      ring(group,gx,gy,gRadius,-Math.PI/2,2*Math.PI);
    });
  }else if(mode==='concentric'){
    // DuckDB Editor concentric layout:
    // Core center node at cx, cy. Surrounding categories ordered by affinity in sectors.
    var hub=ordered[0];
    put(hub,cx,cy);
    var nonHub=ordered.filter(function(n){return n.id!==hub.id;});
    var catsInGraph=orderCategoriesCirculary(Array.from(new Set(nonHub.map(function(n){return n.group||'其他';}))));
    var catCount=Math.max(catsInGraph.length,1);
    var sectorSpan=2*Math.PI/catCount;
    catsInGraph.forEach(function(cat,catIdx){
      var catNodes=nonHub.filter(function(n){return (n.group||'其他')===cat;});
      var centerAngle=-Math.PI/2+catIdx*sectorSpan;
      var baseR=Math.max(220,Math.min(width,height)*0.36);
      var maxInRing=Math.max(3,Math.floor((sectorSpan*baseR)/155));
      catNodes.forEach(function(node,i){
        var ringIdx=Math.floor(i/maxInRing);
        var inRing=i%%maxInRing;
        var inRingCount=Math.min(maxInRing,catNodes.length-ringIdx*maxInRing);
        var t=inRingCount<=1?0:(inRing-(inRingCount-1)/2)/(Math.max(1,inRingCount-1));
        var angle=centerAngle+t*sectorSpan*0.75;
        var r=baseR+ringIdx*130;
        put(node,cx+Math.cos(angle)*r,cy+Math.sin(angle)*r);
      });
    });
  }else if(mode==='starburst'){
    // DuckDB Editor starburst layout:
    // Core hub at cx, cy. Primary neighbors sorted by Hamiltonian greedy chain.
    // Outlying descendants projected outward along parent ray.
    var hub=ordered[0];
    put(hub,cx,cy);
    var primary=Array.from(adjacent.get(hub.id)).map(function(id){return byId.get(id);}).filter(Boolean);
    var orderedPrimary=[];
    if(primary.length>0){
      var pRem=new Set(primary);
      var pCurr=primary.slice().sort(rank)[0];
      orderedPrimary.push(pCurr);pRem.delete(pCurr);
      while(pRem.size>0){
        var neighbors=adjacent.get(pCurr.id)||new Set();
        var next=null;
        for(var cand of pRem){if(neighbors.has(cand.id)){next=cand;break;}}
        if(!next)next=Array.from(pRem)[0];
        orderedPrimary.push(next);pRem.delete(next);pCurr=next;
      }
    }
    var primarySet=new Set(orderedPrimary.map(function(n){return n.id;}));
    var rest=ordered.filter(function(n){return n.id!==hub.id&&!primarySet.has(n.id);});
    var pRadius=Math.max(210,orderedPrimary.length*40);
    ring(orderedPrimary,cx,cy,pRadius,-Math.PI/2,2*Math.PI);
    rest.forEach(function(node,index){
      var parent=orderedPrimary.find(function(p){return adjacent.get(p.id).has(node.id);});
      var anchor=parent?positions.get(parent.id):{x:cx,y:cy};
      var angle=Math.atan2(anchor.y-cy,anchor.x-cx)+(index%%3-1)*0.32;
      var dist=165+Math.floor(index/Math.max(1,orderedPrimary.length))*120+(index%%3)*35;
      put(node,anchor.x+Math.cos(angle)*dist,anchor.y+Math.sin(angle)*dist);
    });
  }else if(mode==='dandelion'){
    // DuckDB Editor dandelion layout:
    // Core center. Category flower centers arranged circularly.
    // Instances spread in multi-ring angular fans.
    var hub=ordered[0];
    put(hub,cx,cy);
    var nonHub=ordered.filter(function(n){return n.id!==hub.id;});
    var cats=orderCategoriesCirculary(Array.from(new Set(nonHub.map(function(n){return n.group||'其他';}))));
    var catCount=Math.max(cats.length,1);
    var sectorSize=2*Math.PI/catCount;
    cats.forEach(function(cat,catIdx){
      var items=nonHub.filter(function(n){return (n.group||'其他')===cat;});
      var centerAngle=-Math.PI/2+catIdx*sectorSize;
      var span=Math.max(sectorSize*0.68,Math.PI/4);
      var maxPerRing=Math.max(2,Math.floor((span*260)/140));
      items.forEach(function(node,j){
        var ringIdx=Math.floor(j/maxPerRing);
        var inRing=j%%maxPerRing;
        var countInRing=Math.min(maxPerRing,items.length-ringIdx*maxPerRing);
        var t=countInRing<=1?0:(inRing-(countInRing-1)/2)/Math.max(1,countInRing-1);
        var angle=centerAngle+t*span*0.82;
        var radius=220+ringIdx*120+(j%%2)*25;
        put(node,cx+Math.cos(angle)*radius,cy+Math.sin(angle)*radius);
      });
    });
  }else if(mode==='spoke'){
    // DuckDB Editor spoke tree layout:
    // Center-rooted tree with angle partitioning per subtree and outer satellite rings
    var hub=ordered[0];
    put(hub,cx,cy);
    var visitedSpoke=new Set([hub.id]);
    var children=Array.from(adjacent.get(hub.id)).map(function(id){return byId.get(id);}).filter(Boolean).sort(rank);
    children.forEach(function(c){visitedSpoke.add(c.id);});
    var branchCount=Math.max(children.length,1);
    var baseAngle=-Math.PI/2;
    var branchStep=2*Math.PI/branchCount;
    var branchDist=Math.max(200,Math.min(width,height)*0.28);
    children.forEach(function(child,bIdx){
      var angle=baseAngle+bIdx*branchStep;
      put(child,cx+Math.cos(angle)*branchDist,cy+Math.sin(angle)*branchDist);
      var subChildren=Array.from(adjacent.get(child.id)).map(function(id){return byId.get(id);})
        .filter(function(n){return n&&!visitedSpoke.has(n.id);}).sort(rank);
      subChildren.forEach(function(sc,scIdx){
        visitedSpoke.add(sc.id);
        var spread=(scIdx-(subChildren.length-1)/2)*0.24;
        var subAngle=angle+spread;
        var subDist=branchDist+140;
        put(sc,cx+Math.cos(subAngle)*subDist,cy+Math.sin(subAngle)*subDist);
      });
    });
    var disconnected=ordered.filter(function(n){return !visitedSpoke.has(n.id);});
    var satRadius=branchDist*1.95;
    disconnected.forEach(function(node,dIdx){
      var angle=baseAngle+((dIdx+0.5)/Math.max(disconnected.length,1))*2*Math.PI;
      var ringIdx=Math.floor(dIdx/8);
      put(node,cx+Math.cos(angle)*(satRadius+ringIdx*90),cy+Math.sin(angle)*(satRadius+ringIdx*90));
    });
  }else{
    // Grid: orthogonal matrix sorted by category then rank with clean row/col spacing
    var gridNodes=ordered.slice().sort(function(a,b){
      return (a.group||'').localeCompare(b.group||'','zh-CN')||rank(a,b);
    });
    var cols=Math.max(1,Math.ceil(Math.sqrt(gridNodes.length*1.4)));
    var colWidth=210,rowHeight=95;
    var startX=cx-((cols-1)*colWidth)/2;
    var rows=Math.ceil(gridNodes.length/cols);
    var startY=cy-((rows-1)*rowHeight)/2;
    gridNodes.forEach(function(node,index){
      var c=index%%cols,r=Math.floor(index/cols);
      put(node,startX+c*colWidth,startY+r*rowHeight);
    });
  }

  visible.forEach(function(node){
    var point=positions.get(node.id);
    if(point){node.x=point.x;node.y=point.y;}
  });
  Object.keys(manualPositions).forEach(function(id){
    var node=byId.get(id),saved=manualPositions[id];
    if(node&&Number.isFinite(saved.x)&&Number.isFinite(saved.y)){node.x=saved.x;node.y=saved.y;}
  });

  // 7. Robust Overlap Prevention & Collision Relaxation (ensures label & node separation)
  for(var iteration=0;iteration<visible.length*4;iteration+=1){
    var moved=false;
    for(var i=0;i<visible.length;i+=1)for(var j=i+1;j<visible.length;j+=1){
      var a=visible[i],b=visible[j];
      var dx=b.x-a.x,dy=b.y-a.y;
      var reqX=Math.max(152,38+(a.labelWidth||100)/2+(b.labelWidth||100)/2);
      var reqY=68;
      var overlapX=reqX-Math.abs(dx);
      var overlapY=reqY-Math.abs(dy);
      if(overlapX>0&&overlapY>0){
        var pinA=!!manualPositions[a.id],pinB=!!manualPositions[b.id];
        if(pinA&&pinB)continue;
        // Resolve along the axis with smaller intrusion
        if(overlapY*1.8<overlapX){
          var shiftY=overlapY+4;
          if(pinA){b.y+=(dy>=0?shiftY:-shiftY);}
          else if(pinB){a.y-=(dy>=0?shiftY:-shiftY);}
          else{a.y-=(dy>=0?shiftY/2:-shiftY/2);b.y+=(dy>=0?shiftY/2:-shiftY/2);}
        }else{
          var shiftX=overlapX+6;
          if(pinA){b.x+=(dx>=0?shiftX:-shiftX);}
          else if(pinB){a.x-=(dx>=0?shiftX:-shiftX);}
          else{a.x-=(dx>=0?shiftX/2:-shiftX/2);b.x+=(dx>=0?shiftX/2:-shiftX/2);}
        }
        moved=true;
      }
    }
    if(!moved)break;
  }
  renderTick();fitView(activeNeighborhood);return true;
}
function setLayoutMode(mode){
  if(!layoutModes[mode])return;
  state.layout=mode;
  try{localStorage.setItem('org-museum-graph-layout',mode);}catch(_layoutModeWriteError){}
  layoutStorageKey='org-museum-graph-positions:'+location.pathname+':'+mode;
  try{manualPositions=JSON.parse(localStorage.getItem(layoutStorageKey)||'{}')||{};}
  catch(_layoutReadError){manualPositions={};}
  if(layoutLabel)layoutLabel.textContent=layoutModes[mode].label;
  renderLayoutOptions();
  var details=layoutMenu&&layoutMenu.closest('details');if(details)details.open=false;
  applyAutoLayout();announceGraph('已切换为 '+layoutModes[mode].label);
}
function syncGraphViewport(){
  var nextWidth=canvas.clientWidth||width,nextHeight=canvas.clientHeight||height;
  if(nextWidth===width&&nextHeight===height)return;
  width=nextWidth;height=nextHeight;
  svg.attr('viewBox','0 0 '+width+' '+height);
  applyAutoLayout();
}
applyAutoLayout();
try{
  nodeSelection.call(d3.drag().clickDistance(4)
    .on('start',function(_event,node){node.fx=node.x;node.fy=node.y;})
    .on('drag',function(event,node){node.x=event.x;node.y=event.y;renderTick();})
    .on('end',function(_event,node){
      node.fx=node.x;node.fy=node.y;
      manualPositions[node.id]={x:node.x,y:node.y};saveManualPositions();
      applyAutoLayout();
    }));
}catch(_dragError){canvas.classList.add('graph-drag-unavailable');}
try{
  if(window.ResizeObserver){
    var graphResizeObserver=new window.ResizeObserver(function(){syncGraphViewport();});
    graphResizeObserver.observe(canvas);
  }else window.addEventListener('resize',syncGraphViewport);
}catch(_resizeObserverError){window.addEventListener('resize',syncGraphViewport);}

var activeNeighborhood=null,hoveredId='';
function neighborhood(node){
  var ids=new Set([node.id]);
  links.forEach(function(link){
    var source=link.source.id||link.source,target=link.target.id||link.target;
    if(source===node.id)ids.add(target);
    if(target===node.id)ids.add(source);
  });
  return ids;
}
function applyFilter(reflow){
  updateMatchStatus();
  if(!nodeSelection)return;
  nodeSelection
    .style('display',function(node){return matches(node)?null:'none';})
    .classed('graph-node-neighbour',function(node){
      return !!activeNeighborhood&&activeNeighborhood.has(node.id);
    })
    .classed('is-context',function(node){
      return !!state.selectedId&&(!activeNeighborhood||!activeNeighborhood.has(node.id));
    })
    .classed('is-dimmed',false);
  function linkIsFocused(link){
    var source=link.source.id||link.source,target=link.target.id||link.target;
    var focus=hoveredId||state.selectedId;
    return !!focus&&(source===focus||target===focus);
  }
  linkSelection.style('display',function(link){return visibleEdge(link)?null:'none';})
    .classed('is-dimmed',false)
    .classed('is-focused',linkIsFocused)
    .classed('is-context',function(link){return !!state.selectedId&&!linkIsFocused(link);});
  linkLabelSelection.style('display',function(link){
    var source=link.source.id||link.source,target=link.target.id||link.target;
    return zoomScale>=1.05&&(source===state.selectedId||target===state.selectedId||
      source===hoveredId||target===hoveredId)?null:'none';
  })
    .classed('is-dimmed',false)
    .classed('is-focused',linkIsFocused)
    .classed('is-context',function(link){return !!state.selectedId&&!linkIsFocused(link);});
  if(reflow!==false)applyAutoLayout();
}
var tooltip=document.getElementById('graph-tooltip');
linkSelection
  .on('mouseenter',function(event,edge){
    var source=nodes.find(function(node){return node.id===(edge.source.id||edge.source);});
    var target=nodes.find(function(node){return node.id===(edge.target.id||edge.target);});
    document.getElementById('tt-title').textContent=edge.type||'显式链接';
    document.getElementById('tt-meta').textContent=(source?source.name:'')+' → '+(target?target.name:'');
    tooltip.style.left=(event.clientX+16)+'px';tooltip.style.top=(event.clientY+16)+'px';
    tooltip.classList.add('is-visible');
  })
  .on('mousemove',function(event){
    tooltip.style.left=(event.clientX+16)+'px';tooltip.style.top=(event.clientY+16)+'px';
  })
  .on('mouseleave',function(){tooltip.classList.remove('is-visible');});
nodeSelection
  .on('mouseenter',function(event,node){
    previewNode(node);
    hoveredId=node.id;applyFilter(false);
    document.getElementById('tt-title').textContent=node.name;
    document.getElementById('tt-meta').textContent=(node.group?categoryLabel(node.group)+' · ':'')+count(node.degree||0)+' 条关系';
    tooltip.classList.add('is-visible');
  })
  .on('mousemove',function(event){
    tooltip.style.left=(event.clientX+16)+'px';tooltip.style.top=(event.clientY+16)+'px';
  })
  .on('mouseleave',function(){
    hoveredId='';applyFilter(false);
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
svg.on('click',function(event){if((event.target===svg.node()||(event.target&&event.target.classList&&event.target.classList.contains('graph-canvas-catcher')))&&state.selectedId)clearSelection(true);});

document.getElementById('btn-reset').addEventListener('click',function(){
  fitView(activeNeighborhood);
});
function applyLayout(){
  manualPositions={};saveManualPositions();
  canvasNodes.forEach(function(node){node.fx=null;node.fy=null;});
  applyAutoLayout();announceGraph('已重新布局');
}
document.getElementById('btn-layout').addEventListener('click',applyLayout);
function syncMotionPreference(event){
  reduceMotion=event.matches;
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
  var restoredRelation=params.get('relation')||'*';
  state.relation=restoredRelation==='*'||relationTypes.indexOf(restoredRelation)>=0?
    restoredRelation:'*';
  if(relationFilter)relationFilter.value=state.relation;
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
     (or (org-museum--versioned-resource-href
          (expand-file-name "resources/org-museum-graph-layout.js"
                            (org-museum--shared-root)) graph-file)
         "resources/org-museum-graph-layout.js")
     (or (org-museum--versioned-resource-href
          (expand-file-name "resources/org-museum-graph-edges.js"
                            (org-museum--shared-root)) graph-file)
         "resources/org-museum-graph-edges.js")
     (or (org-museum--versioned-resource-href
          (expand-file-name "resources/org-museum-graph-network.js"
                            (org-museum--shared-root)) graph-file)
         "resources/org-museum-graph-network.js")
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
function readingShortcutBlocked(e){
  return e.defaultPrevented||e.isComposing||e.metaKey||e.ctrlKey||e.altKey||
    e.target.isContentEditable||e.target.closest('input,textarea,select,button,a,[role=\"dialog\"],dialog')||
    document.querySelector('dialog[open],#image-lightbox-overlay.visible')||
    document.body.classList.contains('museum-drawer-open')||
    document.body.classList.contains('museum-toc-open');
}
document.addEventListener('keydown',function(e){
  if(readingShortcutBlocked(e))return;
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
  if(!readingShortcutBlocked(e)&&e.key==='z'){e.preventDefault();toggleZen();}
});
function toggleZen(){
  var enabled=document.body.classList.toggle('zen-mode');
  var button=document.querySelector('[data-reading-zen]');
  if(button){button.setAttribute('aria-pressed',String(enabled));button.textContent=enabled?'退出专注':'专注阅读';}
  if(enabled)updZ();
}

/* Reading actions stay visible even when mobile metadata is collapsed. */
function initReadingActions(){
  var article=document.querySelector('.article-container'),nav=document.querySelector('.article-back-nav');
  if(!article||!nav)return;
  var title=article.querySelector('h1.title');
  article.insertBefore(nav,title||article.firstChild);
  nav.classList.add('museum-reading-actions');nav.setAttribute('aria-label','阅读操作');
  var status=document.createElement('span');status.className='museum-reading-action-status';
  status.setAttribute('role','status');status.setAttribute('aria-live','polite');
  function copy(value,button){
    var label=button.dataset.label;
    function done(ok){
      status.textContent=ok?'已复制，可粘贴引用':'复制失败，请选择下方文本手动复制';
      button.textContent=ok?'已复制':label;
      clearTimeout(button.copyTimer);button.copyTimer=setTimeout(function(){button.textContent=label;},1800);
      var old=nav.querySelector('textarea');if(old)old.remove();
      if(!ok){var manual=document.createElement('textarea');manual.value=value;
        manual.readOnly=true;manual.setAttribute('aria-label','手动复制引用');nav.appendChild(manual);manual.focus();manual.select();}
    }
    function fallback(){
      var area=document.createElement('textarea');area.value=value;area.readOnly=true;
      area.style.position='fixed';area.style.left='-9999px';document.body.appendChild(area);area.select();
      var ok=false;try{ok=document.execCommand('copy')===true;}catch(_error){}
      area.remove();button.focus({preventScroll:true});done(ok);
    }
    if(navigator.clipboard&&navigator.clipboard.writeText)navigator.clipboard.writeText(value).then(function(){done(true);},fallback);
    else fallback();
  }
  function action(label,handler){
    var button=document.createElement('button');button.type='button';button.textContent=label;button.dataset.label=label;
    button.addEventListener('click',function(){handler(button);});nav.appendChild(button);return button;
  }
  action('复制链接',function(button){
    var url=new URL(location.href);url.search='';copy(url.href,button);
  });
  if(document.body.dataset.pageId)action('复制 Org 引用',function(button){
    var label=(title?title.textContent:document.title).replace(/[\\[\\]\\r\\n]/g,' ').trim();
    copy('[[wiki:'+document.body.dataset.pageId+']['+label+']]',button);
  });
  var zen=action('专注阅读',toggleZen);zen.dataset.readingZen='';zen.setAttribute('aria-pressed','false');zen.title='快捷键 Z';
  nav.appendChild(status);
}
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
  var caption=document.createElement('p');caption.className='image-lightbox-caption';
  caption.setAttribute('role','status');
  var toolbar=document.createElement('div');toolbar.className='image-lightbox-toolbar';
  var previous=document.createElement('button');previous.type='button';previous.textContent='上一张';
  var next=document.createElement('button');next.type='button';next.textContent='下一张';
  var original=document.createElement('a');original.textContent='打开原图';original.target='_blank';original.rel='noopener';
  var close=document.createElement('button');close.type='button';
  close.className='image-lightbox-close';close.textContent='关闭图片预览';
  var lastFocus=null,background=[],activeIndex=0;
  var images=Array.from(document.querySelectorAll('.article-container img')).filter(function(img){return !img.closest('a');});
  if(!images.length)return;
  toolbar.appendChild(previous);toolbar.appendChild(next);toolbar.appendChild(original);toolbar.appendChild(close);
  ol.appendChild(oli);ol.appendChild(caption);ol.appendChild(toolbar);document.body.appendChild(ol);
  function hideLightbox(){
    ol.classList.remove('visible');ol.hidden=true;
    background.forEach(function(item){item.element.inert=item.inert;});background=[];
    document.documentElement.classList.remove('museum-lightbox-open');
    if(lastFocus&&document.contains(lastFocus))lastFocus.focus({preventScroll:true});
  }
  function showImage(index){
    activeIndex=(index+images.length)%images.length;
    var img=images[activeIndex];oli.src=img.currentSrc||img.src;oli.alt=img.alt||'';
    original.href=oli.src;
    caption.textContent=(activeIndex+1)+' / '+images.length+(img.alt?' · '+img.alt:'');
    previous.hidden=next.hidden=images.length<2;
  }
  function showLightbox(img){
    lastFocus=img;showImage(images.indexOf(img));
    Array.from(document.body.children).forEach(function(element){
      if(element===ol||/^(SCRIPT|STYLE|LINK)$/.test(element.tagName))return;
      background.push({element:element,inert:element.inert});element.inert=true;
    });
    document.documentElement.classList.add('museum-lightbox-open');
    ol.hidden=false;ol.classList.add('visible');close.focus();
  }
  previous.addEventListener('click',function(){showImage(activeIndex-1);});
  next.addEventListener('click',function(){showImage(activeIndex+1);});
  oli.addEventListener('error',function(){caption.textContent='图片加载失败，可尝试打开原图';});
  close.addEventListener('click',hideLightbox);
  ol.addEventListener('click',function(event){if(event.target===ol)hideLightbox();});
  ol.addEventListener('keydown',function(event){
    if(event.key==='Escape'){event.preventDefault();hideLightbox();}
    else if(event.key==='ArrowLeft'){event.preventDefault();showImage(activeIndex-1);}
    else if(event.key==='ArrowRight'){event.preventDefault();showImage(activeIndex+1);}
    else if(event.key==='Tab'){
      var items=Array.from(toolbar.querySelectorAll('button,a')).filter(function(item){return !item.hidden;});
      var at=items.indexOf(document.activeElement);
      if(event.shiftKey&&at<=0){event.preventDefault();items[items.length-1].focus();}
      else if(!event.shiftKey&&at===items.length-1){event.preventDefault();items[0].focus();}
    }
  });
  images.forEach(function(img){
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

/* ── 13. Heading anchor copy ── */
function initHeadingAnchors(){
  var headings=document.querySelectorAll('.article-container h2[id],.article-container h3[id],.article-container h4[id]');
  headings.forEach(function(h){
    if(h.querySelector('.heading-anchor-copy'))return;
    var btn=document.createElement('button');
    btn.type='button';btn.className='heading-anchor-copy';
    btn.setAttribute('aria-label','复制小节链接');
    btn.title='复制小节链接';
    btn.innerHTML='<span aria-hidden=\"true\">#</span>';
    btn.onclick=function(e){
      e.stopPropagation();
      var url=new URL(location.href);url.hash='#'+h.id;
      var clean=url.href;
      function done(ok){
        btn.classList.add('copied');
        btn.setAttribute('aria-label',ok?'已复制小节链接':'复制失败');
        setTimeout(function(){
          btn.classList.remove('copied');
          btn.setAttribute('aria-label','复制小节链接');
        },1800);
      }
      if(navigator.clipboard&&navigator.clipboard.writeText){
        navigator.clipboard.writeText(clean).then(function(){done(true);},function(){done(false);});
      }else{
        var ta=document.createElement('textarea');ta.value=clean;
        ta.style.position='fixed';ta.style.left='-9999px';
        document.body.appendChild(ta);ta.select();
        var ok=false;try{ok=document.execCommand('copy')===true;}catch(_e){}
        ta.remove();done(ok);
      }
    };
    h.appendChild(btn);
  });
}

window.addEventListener('load',function(){
  initReadingActions();
  initHeadingAnchors();
  initScrollSpy();
  initCodeBlocks();
  initReadingProgress();
  initLightbox();
  initCJKSpacing();
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
    (message "Org Museum 索引检查完成：修复 %d 项、幽灵条目 %d 项、失效链接 %d 条"
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
    (with-current-buffer (get-buffer-create "*Org Museum 状态*")
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
                          "[[elisp:(call-interactively 'org-museum-export-all)][Export now]]"
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
      (insert "- [[elisp:(call-interactively 'org-museum-export-graph)][Generate Knowledge Graph]]\n")
      (insert "- [[elisp:(org-museum-index-build t)][Force Rebuild Index]]\n")
      (insert "- [[elisp:(org-museum-index-verify)][Verify & Repair Index]]\n")
      (insert "- [[elisp:(org-museum-check-links)][Check All Links]]\n")
      (unless (plist-get runtime-status :in-sync)
        (insert "- [[elisp:(org-museum-reload)][Reload Current Runtime]]\n"))
      (insert "- [[elisp:(call-interactively 'org-museum-export-all)][Export All Pages]]\n")

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
     (message "Org Museum LaTeX：已配置 minted 代码高亮"))
    ('listings
     (org-museum--set-latex-src-backend 'listings)
     (cl-pushnew '("" "listings" nil) org-latex-packages-alist :test #'equal)
     (cl-pushnew '("" "color" nil)    org-latex-packages-alist :test #'equal)
     (message "Org Museum LaTeX：已配置 listings 代码高亮"))
    (_
     (org-museum--set-latex-src-backend 'verbatim)
     (message "Org Museum LaTeX：未配置代码高亮"))))

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
  (message "Org Museum 已初始化：%s" org-museum-root-dir))

;; ============================================================
;; §29  MINOR MODE  [Fix-02 debounce + Fix-13 defvar]
;; ============================================================

(defun org-museum--dispatch-status-string ()
  "Return a one-line status string for the dispatch panel."
  (if org-museum--index
      (format "已索引 %d 篇笔记｜根目录：%s"
              (hash-table-count (org-museum-index-pages org-museum--index))
              (abbreviate-file-name (or org-museum-root-dir "未设置")))
    "索引尚未加载"))

(defun org-museum--dispatch-minibuffer ()
  "Command panel fallback using `completing-read'."
  (let* ((status (org-museum--dispatch-status-string))
         (cmds
          `(("n  新建笔记"       . org-museum-create-page)
            ("f  补全链接"       . org-museum-link-complete)
            ("e  导出当前笔记"   . org-museum-export-page)
            ("E  导出全部"       . org-museum-export-all)
            ("g  导出图谱"       . org-museum-export-graph)
            ("G  打开可编辑图谱" . org-museum-graph-open-live)
            ("p  同步发布站点"   . org-museum-publish-sync)
            ("!  完整同步与公开检查" . org-museum-publish-sync-full)
            ("P  部署到 GitHub" . org-museum-publish-deploy)
            ("r  重命名笔记"     . org-museum-rename-page)
            ("i  重建索引"       . org-museum-index-build)
            ("v  检查索引"       . org-museum-index-verify)
            ("l  检查链接"       . org-museum-check-links)
            ("a  分析当前笔记"   . org-museum-analyze-current)
            ("A  打开 AI 中心"   . org-museum-ai-center-open)
            ("d  分析待处理笔记" . org-museum-analyze-dirty)
            ("R  召回经验"       . org-museum-recall)
            ("G  上下文图谱"     . org-museum-context-graph)
            ("D  知识组合"       . org-museum-derive-current)
            ("?  知识缺口"       . org-museum-knowledge-gap)
            ("S  全库巡检"       . org-museum-deep-scan)
            ("t  结算任务"       . org-museum-settle-task)
            ("F  记录失败经验"   . org-museum-record-failure)
            ("m  关联当前笔记"   . org-museum-relate-current)
            ("M  查看关系"       . org-museum-relations)
            ("X  移除关系"       . org-museum-relation-remove)
            ("K  AI 队列"       . org-museum-ai-queue)
            ("c  启动本机服务"   . org-museum-curation-server-start)
            ("C  停止本机服务"   . org-museum-curation-server-stop)
            ("s  状态报告"       . org-museum-status)
            ("I  初始化工作区"   . org-museum-init)))
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
      "Org Museum 命令面板。"
      [:description
       (lambda () (format "Org Museum — %s"
                          (org-museum--dispatch-status-string)))
       ["笔记"
        ("n" "新建笔记"       org-museum-create-page)
        ("r" "重命名笔记"     org-museum-rename-page)
        ("f" "补全链接"       org-museum-link-complete)]
       ["导出与发布"
        ("e" "导出当前笔记"   org-museum-export-page)
        ("E" "导出全部"       org-museum-export-all)
        ("g" "导出图谱"       org-museum-export-graph)
        ("G" "打开可编辑图谱" org-museum-graph-open-live)
        ("p" "同步发布站点"   org-museum-publish-sync)
        ("!" "完整同步与公开检查" org-museum-publish-sync-full)
        ("P" "部署到 GitHub" org-museum-publish-deploy)]
       ["索引"
        ("i" "重建索引"       org-museum-index-build)
        ("v" "检查并修复"     org-museum-index-verify)
        ("l" "检查链接"       org-museum-check-links)]
       ["知识"
        ("a" "分析当前笔记"   org-museum-analyze-current)
        ("A" "打开 AI 中心"   org-museum-ai-center-open)
        ("d" "分析待处理笔记" org-museum-analyze-dirty)
        ("R" "召回经验"       org-museum-recall)
        ("G" "上下文图谱"     org-museum-context-graph)
        ("D" "知识组合"       org-museum-derive-current)
        ("?" "知识缺口"       org-museum-knowledge-gap)
        ("S" "全库巡检"       org-museum-deep-scan)
        ("t" "结算任务"       org-museum-settle-task)
        ("F" "记录失败经验"   org-museum-record-failure)
        ("m" "关联当前笔记"   org-museum-relate-current)
        ("M" "查看关系"       org-museum-relations)
        ("X" "移除关系"       org-museum-relation-remove)
        ("K" "AI 队列"       org-museum-ai-queue)]
       ["工作区"
        ("s" "状态报告"       org-museum-status)
        ("I" "初始化工作区"   org-museum-init)
        ("c" "启动本机服务"   org-museum-curation-server-start)
        ("C" "停止本机服务"   org-museum-curation-server-stop)]])
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
    (define-key map (kbd "C-c w a")   #'org-museum-analyze-current)
    (define-key map (kbd "C-c w A")   #'org-museum-ai-center-open)
    (define-key map (kbd "C-c w d")   #'org-museum-analyze-dirty)
    (define-key map (kbd "C-c w R")   #'org-museum-recall)
    (define-key map (kbd "C-c w G")   #'org-museum-context-graph)
    (define-key map (kbd "C-c w D")   #'org-museum-derive-current)
    (define-key map (kbd "C-c w ?")   #'org-museum-knowledge-gap)
    (define-key map (kbd "C-c w S")   #'org-museum-deep-scan)
    (define-key map (kbd "C-c w t")   #'org-museum-settle-task)
    (define-key map (kbd "C-c w F")   #'org-museum-record-failure)
    (define-key map (kbd "C-c w m")   #'org-museum-relate-current)
    (define-key map (kbd "C-c w M")   #'org-museum-relations)
    (define-key map (kbd "C-c w X")   #'org-museum-relation-remove)
    (define-key map (kbd "C-c w K")   #'org-museum-ai-queue)
    (define-key map (kbd "C-c w s")   #'org-museum-status)
    (define-key map (kbd "C-c w SPC") #'org-museum-dispatch)
    map)
  "Keymap for `org-museum-mode'.")

;; `defvar' preserves a keymap from an already running Emacs.  Install new
;; bindings there too when this source is reloaded during an Org Museum update.
(define-key org-museum-mode-map (kbd "C-c w A") #'org-museum-ai-center-open)

;;;###autoload
(define-minor-mode org-museum-mode
  "Minor mode for managing an Org Museum wiki."
  :lighter " OrgMuseum"
  :keymap org-museum-mode-map
  (if org-museum-mode
      (progn
        (when org-museum-root-dir
          (unless org-museum--index (org-museum-index-build)))
        (add-hook 'after-save-hook #'org-museum--on-save nil t)
        (add-hook 'after-save-hook #'org-museum-knowledge--on-save nil t)
        (org-museum-knowledge--schedule-failure-reminder))
    (remove-hook 'after-save-hook #'org-museum--on-save t)
    (remove-hook 'after-save-hook #'org-museum-knowledge--on-save t)))

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
             ;; A normal content save cannot change source files other than
             ;; the one the user already saved.  Global snapshots are needed
             ;; only for the rare WIKI_ID rename path that rewrites links.
             (source-snapshots
              (when (cl-some #'org-museum--on-save-id-changed-p files)
                (org-museum--snapshot-files (org-museum--scan-files))))
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
           (message "Org Museum 批量保存后的索引更新失败：%s"
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
          (error "Org Museum 索引 ID [%s] 已被占用" new-id)
        (when (yes-or-no-p
               (format "Org Museum: WIKI_ID changed %s → %s; update all cross-links? "
                       old-id new-id))
          (org-museum--update-links-globally old-id new-id))))))

(defun org-museum--on-save-id-changed-p (file)
  "Return non-nil when FILE's WIKI_ID differs from the indexed page ID."
  (when-let* ((pages (and org-museum--index (org-museum-index-pages org-museum--index)))
              (old (org-museum--find-page-by-path file pages)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((new-id (if (re-search-forward
                        "^#\\+WIKI_ID:\\s-*\\(\\S-+\\)\\s-*$" nil t)
                        (string-trim (match-string 1))
                      (org-museum--generate-id file))))
        (not (equal new-id (org-museum-page-id old)))))))

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
         (buffer (get-buffer-create "*Org Museum 策展预览*")))
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
                   (when (yes-or-no-p "应用这项已预览的策展变更？")
                     (when (or (not (plist-get transaction :identity-change))
                               (yes-or-no-p "再次确认身份或路径变更？"))
                       (org-museum-curation-apply
                        (plist-get transaction :id) t)
                       (message "Org Museum 策展变更已应用")))))
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
  (let* ((body (or body ""))
         (payload (if (multibyte-string-p body)
                      (encode-coding-string body 'utf-8 t)
                    body))
         (cache-control (or (cdr (assoc "Cache-Control" headers)) "no-store"))
         (headers (cl-remove-if (lambda (header)
                                  (equal (car header) "Cache-Control"))
                                headers))
         (reason (pcase status (200 "OK") (201 "Created") (204 "No Content")
                        (400 "Bad Request") (401 "Unauthorized") (403 "Forbidden")
                        (404 "Not Found") (409 "Conflict") (413 "Payload Too Large")
                        (415 "Unsupported Media Type") (_ "Internal Server Error"))))
    (concat (format "HTTP/1.1 %d %s\r\n" status reason)
            (format "Content-Type: %s\r\n" (or type "application/json; charset=utf-8"))
            (format "Content-Length: %d\r\n" (string-bytes payload))
            (format "Cache-Control: %s\r\n" cache-control)
            "X-Content-Type-Options: nosniff\r\n"
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

(defun org-museum--ai-resources-need-deployment-p ()
  "Whether AI Center assets are absent or newer than deployed copies.
Avoid hashing large bundled fonts on every page visit."
  (let ((names (append '("resources/org-museum.css"
                         "resources/org-museum-ai.js"
                         "resources/org-museum-ai-browser.js"
                         "resources/org-museum-ai-workspace.js"
                         "resources/org-museum-org-view.js"
                         "resources/org-museum-markdown.js"
                         "resources/vendor/markdown-it.umd.min.js")
                       (mapcar (lambda (entry)
                                 (concat "resources/fonts/" (car entry)))
                               org-museum--font-resources)
                       (mapcar (lambda (name)
                                 (concat "resources/icons/" name))
                               org-museum--icon-resources))))
    (seq-some
     (lambda (name)
       (let ((source (expand-file-name name (org-museum--plugin-dir)))
             (target (expand-file-name name (org-museum--shared-root))))
         (and (file-regular-p source)
              (or (not (file-regular-p target))
                  (file-newer-than-file-p source target)))))
     names)))

(defun org-museum--ai-center-needs-export-p ()
  "Whether the local AI Center HTML is missing or behind its sources."
  (let* ((out (expand-file-name "ai-center.html" (org-museum--shared-root)))
         (inputs (list (expand-file-name "org-museum-ai-web.el"
                                         (org-museum--plugin-dir))
                       (expand-file-name "org-museum.el"
                                         (org-museum--plugin-dir))
                       (expand-file-name "resources/org-museum-ai.js"
                                         (org-museum--shared-root))
                       (expand-file-name "resources/org-museum-ai-browser.js"
                                         (org-museum--shared-root))
                       (expand-file-name "resources/org-museum-ai-workspace.js"
                                         (org-museum--shared-root))
                       (org-museum--css-output-path)
                       (org-museum-knowledge--derived-path))))
    (or (not (file-regular-p out))
        (seq-some (lambda (input)
                    (and (file-regular-p input)
                         (file-newer-than-file-p input out)))
                  inputs)
        (with-temp-buffer
          (insert-file-contents out)
          (goto-char (point-min))
          (not (search-forward "data-ai-capture-results" nil t))))))

(defun org-museum--curation-content-type (file)
  "Return a conservative response content type for FILE."
  (pcase (downcase (or (file-name-extension file) ""))
    ("html" "text/html; charset=utf-8") ("css" "text/css; charset=utf-8")
    ("js" "application/javascript; charset=utf-8") ("json" "application/json; charset=utf-8")
    ("svg" "image/svg+xml") ("png" "image/png") ("woff2" "font/woff2")
    (_ "application/octet-stream")))

(defun org-museum--graph-current-json ()
  "Return a graph snapshot rebuilt from current Org files when needed."
  (unless (and org-museum--index
               (org-museum--index-fresh-p (org-museum--index-file-path)))
    (org-museum-index-build))
  (org-museum--generate-graph-json))

(defun org-museum--graph-edit-edge (request)
  "Persist one validated graph edge REQUEST to its owner Org note."
  (org-museum--curation-reject-unknown
   request '("action" "ownerId" "targetId" "expectedSha256"
             "type" "label" "direction" "weight" "style") "graph edge")
  (let* ((action (org-museum--curation-value "action" request))
         (owner-id (org-museum--curation-clean-string
                    (org-museum--curation-value "ownerId" request) "ownerId" 96))
         (target-id (org-museum--curation-clean-string
                     (org-museum--curation-value "targetId" request) "targetId" 96))
         (expected (org-museum--curation-clean-string
                    (org-museum--curation-value "expectedSha256" request)
                    "expectedSha256" 64))
         (page (org-museum--curation-page owner-id))
         (file (org-museum-page-path page))
         (transaction-id (secure-hash 'sha256
                                      (format "%s%s%s" owner-id target-id (float-time)))))
    (unless (member action '("upsert" "delete"))
      (signal 'org-museum-curation-error (list "Unknown graph edge action")))
    (unless (and (org-museum--curation-valid-id-p owner-id)
                 (org-museum--curation-valid-id-p target-id)
                 (not (equal owner-id target-id)))
      (signal 'org-museum-curation-error (list "Invalid graph edge endpoints")))
    (org-museum--curation-page target-id)
    (unless (string= expected (org-museum--curation-sha256 file))
      (signal 'org-museum-curation-error (list "Source changed; reload graph before editing")))
    (when (org-museum--curation-modified-buffer (list file))
      (signal 'org-museum-curation-error (list "Unsaved Org buffer blocks graph edit")))
    (let* ((type (when (equal action "upsert")
                   (org-museum--curation-clean-string
                    (org-museum--curation-value "type" request) "type" 48)))
           (label (when (equal action "upsert")
                    (org-museum--curation-clean-string
                     (org-museum--curation-value "label" request) "label" 96)))
           (direction (or (org-museum--curation-value "direction" request) "forward"))
           (weight (or (org-museum--curation-value "weight" request) 1))
           (style (or (org-museum--curation-value "style" request) "solid"))
           (record `((targetId . ,target-id)
                     (state . ,(if (equal action "delete") "deleted" "active"))
                     (type . ,(or type "")) (label . ,(or label ""))
                     (direction . ,direction) (weight . ,weight) (style . ,style)))
           (graph-html (expand-file-name "graph.html" (org-museum--shared-root)))
           (graph-js (org-museum--runtime-resource-path 'graph))
           (snapshot (org-museum--snapshot-files (list file graph-html graph-js)))
           (existing-output (seq-filter #'file-regular-p (list graph-html graph-js)))
           stage)
      (unless (and (member direction '("forward" "reverse" "both"))
                   (numberp weight) (<= 0.2 weight 5)
                   (member style '("solid" "dashed" "dotted")))
        (signal 'org-museum-curation-error (list "Invalid direction, weight or style")))
      (org-museum--curation-persist-backups (list file) transaction-id)
      (condition-case err
          (progn
            (setq stage 'write)
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (let ((case-fold-search t))
                (while (re-search-forward
                        "^#\\+MUSEUM_GRAPH_EDGE:[[:space:]]*\\(.*\\)$" nil t)
                  (let ((existing (condition-case nil
                                      (let ((json-object-type 'alist)
                                            (json-key-type 'string))
                                        (json-read-from-string (match-string-no-properties 1)))
                                    (error nil))))
                    (when (equal (cdr (assoc "targetId" existing)) target-id)
                      (let ((start (line-beginning-position))
                            (end (min (point-max) (1+ (line-end-position)))))
                        (delete-region start end)
                        (goto-char start))))))
              (goto-char (point-min))
              (insert "#+MUSEUM_GRAPH_EDGE: " (org-museum--curation-json record) "\n")
              (org-museum--write-content-if-changed file (buffer-string)))
            (setq stage 'index)
            (org-museum-index-build t)
            (setq stage 'export)
            (org-museum--export-graph-current :silent t)
            (setq stage 'graph)
            (org-museum--generate-graph-json))
        (error
         (org-museum--restore-file-snapshots snapshot)
         (dolist (output (list graph-html graph-js))
           (when (and (not (member output existing-output))
                      (file-regular-p output))
             (delete-file output)))
         (org-museum-index-build t)
         (signal 'org-museum-curation-error
                 (list (format "Graph edit %s failed: %s" stage
                               (error-message-string err)))))))))

(defun org-museum--curation-dispatch-http (method path headers body)
  "Dispatch one loopback METHOD PATH request with HEADERS and BODY."
  (condition-case error-data
      (if (string-prefix-p "/api/v1/" path)
          (progn
            (unless (org-museum--curation-authorized-p headers)
              (signal 'org-museum-curation-error (list "Unauthorized local session")))
            (if (string-prefix-p "/api/v1/ai/" path)
                (org-museum-ai-web--dispatch-http method path body)
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
              (`("GET" "/api/v1/graph")
               (org-museum--curation-http-response
                200 (concat "{\"ok\":true,\"graph\":"
                            (org-museum--graph-current-json) "}")))
              (`("POST" "/api/v1/graph/edge")
               (unless (string-prefix-p "application/json"
                                        (or (cdr (assoc "content-type" headers)) ""))
                 (signal 'org-museum-curation-error (list "Content-Type must be application/json")))
               (org-museum--curation-http-response
                200 (concat "{\"ok\":true,\"graph\":"
                            (org-museum--graph-edit-edge
                             (org-museum--curation-json-read body)) "}")))
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
              (_ (org-museum--curation-http-error 404 "Unknown API endpoint")))))
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
         ((or (equal (car (split-string path "?")) "/ai-center.html")
              (org-museum--curation-static-file path))
          (when (equal (car (split-string path "?")) "/ai-center.html")
            (when (org-museum--ai-resources-need-deployment-p)
              (org-museum--ensure-css-deployed))
            (when (org-museum--ai-center-needs-export-p)
              (org-museum-ai-web--export-center)))
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
                 `(("Content-Security-Policy" . "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'")
                   ("Cache-Control" . ,(if (string-prefix-p "/resources/" path)
                                           (if (string-match-p "[?&]v=[[:xdigit:]]+" path)
                                               "private, max-age=31536000, immutable"
                                             "private, max-age=86400")
                                         "no-store"))))))))
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
(defun org-museum-curation-server-start (&optional page)
  "Start the authenticated Org Museum loopback server and open the export."
  (interactive)
  (unless (eq org-museum-curation-mode 'loopback)
    (signal 'org-museum-curation-error
            (list "Set org-museum-curation-mode to loopback before starting the server")))
  (org-museum--guard-init)
  (unless (file-regular-p
           (expand-file-name (or page "index.html") (org-museum--shared-root)))
    (let ((org-museum-open-browser-after-export nil)) (org-museum-export-all)))
  (unless (and (process-live-p org-museum--curation-server)
               org-museum--curation-token org-museum--curation-server-port)
    (when (process-live-p org-museum--curation-server)
      (org-museum-curation-server-stop))
    (setq org-museum--curation-token
          (secure-hash 'sha256 (format "%s:%s:%s:%s" (float-time) (emacs-pid) (random) (user-uid))))
    (setq org-museum--curation-server
          (make-network-process
           :name "org-museum-curation" :server t :host "127.0.0.1"
           :service org-museum-curation-port :family 'ipv4 :noquery t
           :coding 'binary :filter #'org-museum--curation-server-filter))
    (setq org-museum--curation-server-port
          (process-contact org-museum--curation-server :service)))
  (let ((url (format "http://127.0.0.1:%d/%s#org-museum-curation-token=%s"
                     org-museum--curation-server-port (or page "")
                     org-museum--curation-token)))
    (browse-url url)
    (message "Org Museum 本机服务已启动：127.0.0.1:%d"
             org-museum--curation-server-port)
    url))

;;;###autoload
(defun org-museum-graph-open-live ()
  "Open the authenticated, live knowledge graph in the browser."
  (interactive)
  (org-museum--guard-init)
  (org-museum-index-build)
  (org-museum--export-graph-current :silent t)
  (let ((org-museum-curation-mode 'loopback))
    (org-museum-curation-server-start "graph.html")))

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
  (when (boundp 'org-museum-ai-web--previews)
    (clrhash org-museum-ai-web--previews))
  (message "Org Museum 本机服务已停止"))

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
    (message "注册命令已复制；运行前请核对现有处理程序")))

(defun org-museum-curation-protocol-uninstall-command ()
  "Copy a Windows command that removes the org-protocol handler.
This command never modifies the registry itself."
  (interactive)
  (let ((command "reg delete HKCU\\Software\\Classes\\org-protocol /f"))
    (kill-new command)
    (message "卸载命令已复制；运行前请核对已注册的处理程序")))

(load (expand-file-name "org-museum-knowledge.el" (org-museum--plugin-dir)))
(load (expand-file-name "org-museum-context.el" (org-museum--plugin-dir)))
(load (expand-file-name "org-museum-derived.el" (org-museum--plugin-dir)))
(load (expand-file-name "org-museum-gap.el" (org-museum--plugin-dir)))
(load (expand-file-name "org-museum-ai-session.el" (org-museum--plugin-dir)))
(load (expand-file-name "org-museum-ai-web.el" (org-museum--plugin-dir)))

(provide 'org-museum)

;;; org-museum.el ends here
