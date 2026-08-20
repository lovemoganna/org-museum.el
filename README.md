# org-museum.el

A MECE-refactored static wiki generator based on Org Mode, featuring a Monokai theme, D3.js graph visualization, and Zen writing mode.

**Version:** 2.4.2

## Installation

### Requirements

- Emacs 27.1 or later
- Org Mode (built into Emacs)

### Using straight.el

```elisp
(straight-use-package
 '(org-museum :type git :host github :repo "lovemoganna/org-museum.el"))
```

### Manual Installation

1. Clone the repository:

```bash
git clone https://github.com/lovemoganna/org-museum.el.git
```

2. Add to your Emacs configuration:

```elisp
(add-to-list 'load-path "/path/to/org-museum.el/")
(require 'org-museum)
```

### Stable Source and Canonical Local Checkout

The remote Git tag `v2.4.2` is the stable source of truth. On this workstation,
the canonical runtime checkout fetched from that remote is:

```text
C:/Users/luoyu/AppData/Roaming/.emacs.d/org-roam
```

The Emacs configuration uses `:straight nil` and adds that directory with
`:load-path`. Do not maintain a second live copy or continue development on a
rollback checkout. Before treating a local revision as stable, fetch it from
the remote, reload it in Emacs, and verify the loaded implementation with:

```elisp
(symbol-file 'org-museum-export-all 'defun)
```

The returned path must be under the canonical checkout above, and the local
file hash must match the fetched remote revision. The legacy `load.el` entry
point delegates to the same Emacs configuration rather than defining another
wiki root or package source. Older versions are recovery artifacts only.

## Quick Start

### 1. Set Up Your Wiki Root

```elisp
(setq org-museum-root-dir "~/my-wiki/")
```

### 2. Create Your First Page

Create an `.org` file in your wiki root:

```org
#+TITLE: My First Page
#+CREATED: [2026-01-01]
#+FILETAGS: :intro:

Welcome to my wiki! This is a paragraph.

** Section One

More content here.

*** Subsection

- Item one
- Item two
```

### 3. Build the Wiki

```elisp
M-x org-museum-export-all
```

Or programmatically:

```elisp
(org-museum-export-all)
```

### 4. Inspect or Reopen

```elisp
M-x org-museum-status
M-x org-museum-dispatch
```

A full export opens `index.html` by default.  Set
`org-museum-open-page-after-export` to `graph` to open the graph instead, or to
`nil` to leave the browser untouched.

### 5. Publish with GitHub Pages

Publishing is deliberately split into two reviewable stages:

```elisp
M-x org-museum-publish-sync    ; export, privacy-check, and update the local mirror
M-x org-museum-publish-deploy  ; commit managed files, push, and configure Pages
```

Configure a dedicated checkout outside the Wiki root:

```elisp
(setq org-museum-publish-directory "~/org-notes/")
(setq org-museum-publish-repository "your-account/org-notes")
(setq org-museum-publish-branch "main")
(setq org-museum-publish-remote "origin")
```

Sync always builds a privacy-safe local preview. If an exported page contains a
Windows path, UNC path, or local `file:///` reference, its public candidate is
replaced with a neutral placeholder and `*Org Museum Privacy Report*` opens with
the source Org file, line number, matched text, and a suggested repair. Non-HTML
text resources with findings are omitted. The detailed report stays in Emacs;
the managed `.org-museum-publish-status.json` records only `ready` or `blocked`
and safe relative filenames.

Deployment refuses a `blocked` preview before running Git or GitHub commands.
It also requires a current status file and rechecks every managed candidate for
local paths and privacy placeholders, so editing `blocked` to `ready` cannot
bypass the gate. Fix the reported source links, rerun sync, and confirm the
status becomes `ready`; the next sync replaces every placeholder with the real
page. Do not copy the original unsafe exports into the publish checkout.

The first ready deploy shows the public repository name and asks before creating
it with the authenticated GitHub CLI. Later deploys refuse unexpected
uncommitted files, remote-ahead or diverged history, and symbolic links. Only
files recorded in the publish manifest are staged; repository-owned files such
as `CNAME` and `README.md` are preserved. The local export-only
`.org-museum-manifest.json` and the detailed privacy report are never published.

## Project Structure

```
my-wiki/
├── exports/html/          # Generated HTML output
│   ├── pages/             # Page HTML files
│   └── resources/         # CSS, JS assets
├── .org-museum-index.json # Generated index cache
└── *.org                  # Your Org Mode source files
```

## Core Concepts

### Tags and Organization

Use `#+FILETAGS:` to categorize pages:

```org
#+FILETAGS: :category:subcategory:
```

### Internal Links

Link between pages using standard Org Mode links:

```org
[[file:another-page.org][Another Page]]
[[id:UNIQUE-ID][Link by ID]]
```

Relative `file:` links are resolved from the source Org file. Links to indexed
Org pages become Wiki page URLs. Links to existing files outside the Wiki stay
local and are exported with a **Local file** badge plus a copy-path fallback;
external files are never copied into the export directory.

### Optional Page Metadata

```org
#+WIKI_STATUS: draft
#+DESCRIPTION: A short maintenance summary for the health report.
```

Drafts remain searchable and receive a visible badge. `DESCRIPTION` is optional;
missing values are reported by `M-x org-museum-status` but never written back to
the Org source automatically.

### Backlinks (Linked From)

`org-museum.el` automatically tracks which pages link to which. Every page displays a **Linked From** section showing its incoming links.

### Graph Visualization

The wiki includes an interactive D3.js graph (`graph.html`) showing:

- All pages as nodes
- Links between pages as edges
- Color-coded by category tags
- Click to navigate between pages

The main index (`index.html`) includes a small local graph for each page's immediate neighbors.

## Configuration

### Customization Options

| Option | Default | Description |
|--------|---------|-------------|
| `org-museum-root-dir` | `nil` | Root directory of your wiki |
| `org-museum-export-dir` | `"exports/html/pages"` | Page export location |
| `org-museum-shared-export-dir` | `"exports/html"` | Shared resources location |
| `org-museum-publish-directory` | `nil` | Dedicated local Git checkout for the public site |
| `org-museum-publish-repository` | `nil` | GitHub target in `OWNER/REPOSITORY` form |
| `org-museum-publish-branch` | `"main"` | GitHub Pages source branch |
| `org-museum-publish-remote` | `"origin"` | Git remote used for publishing |
| `org-museum-css-file` | `"resources/org-museum.css"` | CSS file path |
| `org-museum-open-browser-after-export` | `t` | Auto-open browser after export |
| `org-museum-open-page-after-export` | `index` | Page opened after export: `index`, `graph`, or `nil` |
| `org-museum-auto-reload-before-export` | `t` | Reload the authoritative source when the loaded runtime is stale |
| `org-museum-default-language` | `"zh-CN"` | HTML language when `#+LANGUAGE` is absent |
| `org-museum-local-graph-neighbour-limit` | `12` | Max neighbors in local graph |
| `org-museum-clean-stale-html-on-full-export` | `nil` | Delete stale page HTML only after a successful full export |
| `org-museum-category-label-alist` | `nil` | Display-only category labels, such as `Sql` → `SQL` |

Run `M-x org-museum-preview-stale-exports` to inspect stale page HTML before
enabling automatic cleanup. Cleanup is limited to ordinary `.html` files under
the configured page export directory and is refused for empty indexes or
symbolic links.

### Example Configuration

```elisp
(use-package org-museum
  :straight (org-museum :type git :host github :repo "lovemoganna/org-museum.el")
  :custom
  (org-museum-root-dir "~/wiki/")
  (org-museum-export-dir "output/pages")
  (org-museum-shared-export-dir "output")
  (org-museum-publish-directory "~/org-notes/")
  (org-museum-publish-repository "your-account/org-notes")
  (org-museum-css-file "themes/custom.css")
  (org-museum-open-browser-after-export t)
  (org-museum-open-page-after-export 'index)
  (org-museum-clean-stale-html-on-full-export t)
  (org-museum-category-label-alist '(("Sql" . "SQL") ("lisp" . "Lisp")))
  :config
  ;; Add your custom key binding
  (define-key org-mode-map (kbd "C-c w") #'org-museum-export-all))
```

## Exported HTML Features

### Unified Index Filters

Search, topic, and publication status share one filter state. Static URLs can
restore that state using `q`, `category`, and `status` query parameters, for
example `index.html?category=Sql&status=draft`. Search includes exported H2-H4
headings and links directly to the best matching section.

### Local Reading State

Qualified visits are stored locally in IndexedDB (`org-museum`, version `1`). A
visit qualifies after 30 seconds of focused reading or 3% progress. No article
body is stored or uploaded, and the continue-reading section is hidden when
IndexedDB is unavailable.

### Stable Sections and Current Runtime

Exported H2-H4 headings use deterministic `section-…` anchors.  Explicit
`CUSTOM_ID` or heading `ID` values still take priority, so saved reading
positions and cross-page section links survive repeat exports.

Before any page, graph, or full export, Org Museum compares the loaded Elisp
digest with its authoritative source. A manually loaded workspace remains
authoritative even when a Straight rollback clone exists; a Straight-loaded
runtime continues to prefer its repository source over build or link copies.
A stale runtime is reloaded once before any index or HTML is written. Use
`M-x org-museum-reload` to refresh explicitly and `M-x org-museum-status` to
inspect both paths and hashes.

All browser code is deployed as content-versioned local resources.  D3,
Highlight.js, CSS, and generated page runtimes are required bundled assets;
export fails clearly when one is missing and never downloads a CDN fallback.

### Persistent Manual Theme

The exported wiki defaults to the Monokai dark theme and provides the same
keyboard-accessible theme control on the home, article, and graph pages. A
manual choice is stored only in `localStorage["org-museum-theme"]` and accepts
`dark` or `light`; missing or invalid values fall back to dark. The local
startup script applies the choice before page paint, without a network request.
For default `file:///` browsing, local HTML navigation also carries that value
in an `org-museum-theme` query parameter so each page can initialize its own
storage scope; existing search, filter, anchor, and unrelated browser state is
left intact.

The dark theme includes:

- Dark background (`#272822`)
- Syntax highlighting via Highlight.js
- Styled blockquotes, tables, and code blocks

### Zen Mode

Press `z` to toggle Zen mode — a distraction-free fullscreen view for focused writing.

### Scroll Spy

The page automatically highlights the current section in the table of contents as you scroll.

### Tubes (Reading Progress)

A subtle reading progress indicator appears at the bottom of each page.

### Graph Navigation

- Press `g` to open the full-site graph view
- Click nodes to navigate
- Hover for tooltip information

## Build Pipeline

`org-museum-export-all` performs the following steps:

1. **Scan** — Find all `.org` files in the wiki root
2. **Index** — Build JSON index of all pages and links
3. **Export** — Convert each `.org` file to HTML
4. **Link Processing** — Resolve internal links and fix asset paths
5. **Generate Index** — Create `index.html` with all pages
6. **Generate Graph** — Create `graph.html` with D3 visualization
7. **Copy Assets** — Copy CSS, JS resources to export directory

### Test and Export Commands

From the canonical checkout, run the complete ERT suite with Emacs 30.2:

```powershell
& "C:\Program Files\Emacs\emacs-30.2\bin\emacs.exe" -Q --batch `
  -L . -L test -l test/org-museum-test.el -f ert-run-tests-batch-and-exit
```

For the configured real wiki, run `M-x org-museum-export-all`. This rebuilds
the recoverable index and HTML under `exports/html/`; it does not modify the
source Org pages or the Org-roam database.

## Troubleshooting

### Pages Not Linking Correctly

Ensure your links use the correct syntax:

```org
[[file:target.org][Description]]
```

Not:

```org
[[target.org][Description]]  ;; This won't work
```

### Graph Missing Nodes

- Run `org-museum-export-all` to regenerate the index
- Check that your `.org` files have valid `#+TITLE:` or `#+ROAM_TITLE:` properties

### CSS Not Loading

Verify that `org-museum-css-file` points to a valid path relative to the plugin directory.

## Version History

### v2.4.2

- Bundles the complete Highlight.js 11.10.0 browser language set for offline code highlighting
- Normalizes punctuation-bearing language aliases such as C++, C#, F#, and X++
- Deduplicates reciprocal page references into one graph connection
- Opens graph articles with one click while preserving keyboard navigation and theme state
- Makes page creation and rename failures transactional and keeps theme controls semantically consistent
- Adds guarded two-stage GitHub Pages publishing with managed-file and privacy checks

### v2.4.1

- Keeps narrow article navigation and theme controls reachable down to 320 px
- Reports mobile drawer and table-of-contents state with matching accessible labels
- Preserves a manually loaded workspace as the authoritative runtime and resource root
- Avoids full Org syntax-tree work in routine health checks while retaining export-aware fallbacks
- Establishes the fetched and verified remote tag as the stable baseline

### v2.4.0

- Reloads stale loaded implementations before any export writes
- Uses stable section anchors and Chinese-by-default HTML language metadata
- Prioritizes filtered mobile search results and enlarges navigation targets
- Externalizes shared browser runtimes with content hashes and offline-only assets
- Normalizes source files to LF and compiles without warnings on current Org

### v2.3.0

- Fix-13: Pre-declare `org-museum--dispatch-transient` to prevent void-variable errors
- Fix-14: New `org-museum-pages-subdir` for consistent page organization
- Fix-15: Added `org-museum--pages-base-dir` helper
- Fix-16: Page creation now correctly follows the normalized category directory structure

### v2.2.0

12 targeted fixes including:
- Bidirectional linked-from stale removal
- Debounced on-save processing
- D3 simulation pre-heat for large graphs
- Local graph neighbour capping with overflow node

### v2.1.0

- Zen mode and scroll spy
- Tube reading progress indicator
- Graph edge arrow rendering

### v2.0.0

- MECE refactoring
- Improved D3 graph with SVG markers
- Monokai theme refinements

## License

Copyright (C) 2026. Distributed under GPL v3.
