# org-museum.el

A MECE-refactored static wiki generator based on Org Mode, featuring a Monokai theme, D3.js graph visualization, and Zen writing mode.

**Version:** 2.3.0

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
M-x org-museum--build-wiki
```

Or programmatically:

```elisp
(org-museum--build-wiki)
```

### 4. Open in Browser

```elisp
M-x org-museum--open-site
```

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
| `org-museum-css-file` | `"resources/org-museum.css"` | CSS file path |
| `org-museum-open-browser-after-export` | `t` | Auto-open browser after export |
| `org-museum-local-graph-neighbour-limit` | `12` | Max neighbors in local graph |

### Example Configuration

```elisp
(use-package org-museum
  :straight (org-museum :type git :host github :repo "lovemoganna/org-museum.el")
  :custom
  (org-museum-root-dir "~/wiki/")
  (org-museum-export-dir "output/pages")
  (org-museum-shared-export-dir "output")
  (org-museum-css-file "themes/custom.css")
  (org-museum-open-browser-after-export t)
  :config
  ;; Add your custom key binding
  (define-key org-mode-map (kbd "C-c w") #'org-museum--build-wiki))
```

## Exported HTML Features

### Monokai Theme

The exported wiki uses the beautiful Monokai color scheme with:

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

`org-museum--build-wiki` performs the following steps:

1. **Scan** — Find all `.org` files in the wiki root
2. **Index** — Build JSON index of all pages and links
3. **Export** — Convert each `.org` file to HTML
4. **Link Processing** — Resolve internal links and fix asset paths
5. **Generate Index** — Create `index.html` with all pages
6. **Generate Graph** — Create `graph.html` with D3 visualization
7. **Copy Assets** — Copy CSS, JS resources to export directory

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

- Run `org-museum--build-wiki` to regenerate the index
- Check that your `.org` files have valid `#+TITLE:` or `#+ROAM_TITLE:` properties

### CSS Not Loading

Verify that `org-museum-css-file` points to a valid path relative to the plugin directory.

## Version History

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