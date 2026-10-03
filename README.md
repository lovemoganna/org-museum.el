# org-museum.el

## AI 中心与笔记分析

先在 LM Studio 加载 **Gemma 4 E2B**。然后在 Emacs 中运行
`M-x org-museum-ai-center-open`（或在 Org Museum 笔记中按 `C-c w A`）。
请使用 Emacs 新打开的本机 AI 中心页面；直接双击 `dist/ai-center.html` 打开的
`file:///` 页面只能阅读已公开的经验，不能执行 AI 操作。

本机页面的主流程是 **选择多篇资料 → AI 流式分析 → 选择推荐方向 →
多轮深挖 → 预览并确认沉淀**。每轮回答完成后，AI 根据已选资料、前面的分析和
整轮对话推荐有来源依据的下一步；也可在输入框中自由追问。会话保存在本机私有的
`.org-museum-ai-sessions.json` 中，重新打开页面后可继续。来源笔记发生变化时，
请开始新一轮分析。队列、关系、失败模式、知识组合、知识缺口和全库巡检仍在
「更多工具」中。若提示模型未加载，回到 LM Studio 加载模型后重试。

讨论按轮次显示为可折叠时间线；目录可跳转到任一问题，回答下方单独列出引用与
参考笔记。新回答完成后，AI 优先给出有本轮回答依据的精简结论，可一键收录；
旧回答也可点「收录此回答」。收录会把原问题、前文上下文、来源及
版本、完整回答、可编辑结论和收录时间保存到本机私有的
`.org-museum-ai-captures.json`。在「已收录结论」中可按问题、结论和来源检索，
修改分类及结论，回到原讨论继续，或引用到当前会话的下一次提问。收录不会直接
修改或公开 Org 笔记；需要写入原笔记时仍使用下方的预览和确认流程。

值得沉淀的结论、经验、方法和待办由 AI 提议，先核对或编辑内容及写入目标，
再明确确认。确认后会追加到目标原笔记的「AI 协作沉淀」章节；待办使用 Org TODO，
来源和待验证状态一起写入。已公开的原笔记按原有发布规则公开新增内容。
确认前的完整对话、推荐及草稿只留在本机，不进入公开导出。
在笔记页点击右侧 **AI 分析** 展开当前笔记的分析和相关经验；左侧目录默认收起，鼠标悬浮、键盘聚焦或点击可打开。
窄屏上两侧抽屉一次显示一个，避免挡住彼此。`C-c w a` 仍直接分析 Emacs 中的当前笔记。

网页 AI 操作固定使用本机 LM Studio 中已加载的 `google/gemma-4-e2b`。
断开本机服务后，公开站点的 AI 中心仅展示已确认并允许公开的经验；
原始分析、队列、候选与完整巡检结果不进入导出文件。
经验和关系必须经过来源预览及明确确认；AI 不会自行改写原 Org 正文。
退出时运行 `M-x org-museum-curation-server-stop` 使本机会话失效。

多篇笔记分析使用统一的并发批次：每篇笔记是一个独立任务，默认最多同时运行 2 个
Worker；内容哈希未变化的笔记直接复用私有分析。单项请求超时后最多自动重试 2 次，
批次页面显示排队、运行、完成和失败进度，并支持暂停、取消和查看日志。所有笔记完成
后才生成汇总、去重和冲突提示；用户确认的建议会在重新检查来源版本后按笔记顺序串行
写回，分析阶段不会修改 Org 原文。

## Knowledge runtime (Phase 0–6)

Saving an Org Museum note still updates its ordinary index. It also records a
content hash in a private dirty queue; saving never calls a model. The default
`org-museum-knowledge-work-mode` is `assist`. Choose `manual` to keep all AI
work behind explicit commands, or opt into `auto` for one analysis request at a
time after idle time. Use `org-museum-ai-set-mode` to switch modes and
`org-museum-ai-pause`, `org-museum-ai-cancel`,
`org-museum-ai-queue`, and `org-museum-ai-queue-clear` to control the worker.

`org-museum-analyze-current`, `org-museum-analyze-dirty`, and
`org-museum-analyze-project` perform incremental analysis. They use the local
LM Studio server at `127.0.0.1:1234` with `google/gemma-4-e2b` by default.
Load that model in LM Studio before analyzing. If unavailable, the item remains
queued and ordinary writing and reading continue. Use
`org-museum-knowledge-select-backend` to explicitly select another configured
gptel backend; there is no automatic cloud fallback.

`org-museum-recall` ranks indexed notes and confirmed past experiences for a
question. After a real task, run `org-museum-settle-task` from its source note.
The preview asks for explicit confirmation before an experience is stored and
included in its exported page. Only confirmed experiences enter public HTML,
which is still checked by the existing publish privacy gate. AI analyses and
the queue stay in the private `.org-museum-knowledge.json` and
`.org-museum-ai-state.json` files; neither changes original Org content.

For a recurring pitfall, open the saved source Org note and run
`org-museum-record-failure` (`C-c w F`). Select a relevant passage first; if it
contains an Org `#+RESULTS:` block, the record notes that the result is present
in the source. Otherwise its verification is labeled user confirmed. Fill in
the problem, cause, failed attempt, working fix and scope, then review the
source line, excerpt and SHA-256 in the preview. Only an explicit “沉淀并公开”
confirmation stores and publishes it. The private derived record keeps the
excerpt and provenance; public pages show the approved explanation and source
location, not the excerpt. Changing the original note's content makes its old
record ineligible for public display until reviewed again.

On opening another Museum note, a single idle check can remind you of a
similar historical Failure Pattern or a confirmed older experience with a
failed attempt. This check uses local text overlap and
never calls a model. `org-museum-recall` puts matching failure patterns ahead
of ordinary experience and shows cause, failed attempt, fix, verification,
scope and source. Set `org-museum-knowledge-reminder-min-score` higher to make
reminders more selective.

Semantic relations build on existing `#+MUSEUM_RELATION: target-id | label`
annotations. Explicit labels such as 前置依赖, 启发影响, 属于, 支持 and 矛盾
retain their Org note as provenance. From a saved source note, select a passage
and run `org-museum-relate-current` (`C-c w m`) to confirm a private typed
relation to another indexed note. The preview shows both source versions and a
confidence from 0 to 1. Confidence is a recall ranking weight, not a measured
probability. The relation is suspended when either note changes; the source
Org text and the site's public graph are not rewritten.

`org-museum-recall` uses one-hop, source-backed relations to rank relevant
notes and confirmed experiences, and shows relation type, confidence and
provenance. Run `org-museum-relations` (`C-c w M`) to inspect effective and
stale relations plus possible contradictions: opposing support/conflict links,
two-way dependencies, or different confirmed fixes for the same problem and
scope. These are review prompts, not automatic judgments. Use
`org-museum-relation-remove` (`C-c w X`) to withdraw a confirmed private
relation; edit an Org annotation in its source note to change that annotation.

Run `org-museum-context-graph` (`C-c w G`) from an Org note to see a temporary
local graph. With a prefix, enter the current task; the current heading becomes
a tutorial section node when available. From outside a Museum note, enter a
task and the view selects its closest indexed note. The default view includes
one hop of linked or confirmed relations, plus current confirmed experiences,
failure records, and a clearly marked unverified analysis summary. Press `x`
for a second hop, `c` to collapse, `n`/`p` to switch nodes, `g` to refresh,
`o` to open the selected source, or `e` to reveal its private evidence. Select
nodes with the text buttons below the visual graph. The graph is capped and
built from current source versions, and exists only in Emacs; it is not stored
or published.

Phase 5 adds `org-museum-derive-current` (`C-c w D`). From a saved note, select
a useful passage if needed, enter the current task, and choose a second indexed
note. Linked and task-relevant notes appear first. The command sends two short,
source-backed passages to the explicitly selected gptel backend; by default
this is only local Gemma 4 E2B. It asks for one new, falsifiable combination and
a verification plan. It never runs on save or in the auto analysis worker.

The generated proposal is a **private AI inference** with both source files,
lines, excerpts and content hashes. Use `org-museum-derived-review` to reopen
it. Press `a` to confirm that it is useful, `r` to reject it, `o` to open the
first source (prefix `o` for the second), or `t` to retry an unconfirmed
proposal. If Gemma is not loaded, the task is saved with an actionable error
and remains available for retry. `org-museum-derived-cancel` stops an active
request. Confirmed combinations appear in private recall and the local context
graph while both source versions remain current; unconfirmed and stale ones do
not. From a saved Org note, select a nonempty `#+RESULTS:` block and run
`org-museum-derived-verify` to attach the recorded execution result. This
distinguishes a model inference, a user's confirmation, and an existing
recorded result; it does not rerun the code. Changing the result note removes
the verified label. All proposals live in `.org-museum-derived.json` and stay
out of public site exports. Original Org text is never rewritten.

Phase 6 adds `org-museum-knowledge-gap` (`C-c w ?`). Enter a current task or
learning goal. The first view checks at most six relevant indexed notes without
calling a model. It shows a few evidence gaps, each note's observable maturity
(source, connections, recorded results, confirmed cases), and reuse signals.
These are review prompts based on available records, not judgments about truth
or a numeric value score. Press `a` in that view to ask the explicitly selected
model to review the local evidence. Gemma 4 E2B is the default local model;
the request cites only the shown source IDs and yields at most three private,
unverified suggestions. An unavailable model leaves a retryable report.
`org-museum-knowledge-gap-cancel` stops an active model review. Reports are
stored in `.org-museum-gap.json`; a source change suspends old suggestions.

Run `org-museum-deep-scan` (`C-c w S`) only when you want a full-library
governance check. It rebuilds the index, then reads source files in small,
cancellable batches. The report covers exact duplicates, possible conflicts,
isolated notes, stale derived records, low-confidence relations, promising
linked pairs, unverified conclusions, task-relevant evidence gaps around
frequently referenced notes, and legacy dirty jobs. It shows at most twelve
priority review items; press `c` to cancel or run
`org-museum-deep-scan-status` to reopen progress or the latest report. Deep
Scan itself makes no model request, does not edit Org files, and does not
publish its findings.

A static Org reading system with a unified bookshelf shell, warm-paper article
pages, explicit relationship reading, a D3.js knowledge graph, and Zen mode.

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

Interactive export and publish commands return immediately and run in one
isolated background Emacs process. This keeps editing, completion, navigation,
and other commands responsive; jobs are serialized so two exports cannot race.
Use `M-x org-museum-background-status` to inspect the active or most recent
job. After a successful full export, the parent Emacs opens the configured page
in the browser; after a successful publish sync, it opens the synchronized
directory in the platform file manager. Failed jobs open neither, so stale
results are never presented as current. Programmatic calls remain synchronous
so scripts can detect failure and preserve transactional rollback behavior.

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

Deployment preserves existing repository-local Git author settings. If either
author field is missing, Org Museum derives it from the authenticated GitHub
account (using a GitHub noreply address) and writes it only to this publish
checkout. Optional explicit fallbacks are available without changing global
Git configuration:

```elisp
(setq org-museum-publish-git-user-name "Your GitHub Name")
(setq org-museum-publish-git-user-email "12345+account@users.noreply.github.com")
```

The normal sync is conservative. If an exported page contains a Windows path,
UNC path, local `file:///` reference, or another detected local value, its
public candidate is replaced with a neutral placeholder and `*Org Museum
Privacy Report*` opens with the source Org file, line number, matched text, and
a suggested repair. Non-HTML text resources with findings are omitted. The
detailed report stays in Emacs; the managed status file contains only safe
relative filenames.

When you intentionally need a byte-for-byte local mirror, use the separate
high-risk workflow:

```elisp
M-x org-museum-publish-sync-full
```

This command never silently removes or rewrites selected exported content. It
requires entering exactly `COPY PRIVATE EXPORTS` before queuing the isolated
job. The background log then records the effective sharing scope, files to
add/overwrite/delete, unknown hash baselines, conflicts, and every privacy
finding. A conflict means a managed file was manually changed after the last
sync; the command stops with zero changes rather than overwriting or deleting
that edit. An incorrect or cancelled confirmation leaves the old mirror
untouched.

Full-sync scope and decisions are controlled by a local policy that is never
copied into the publish checkout:

```elisp
(setq org-museum-publish-policy-file
      (expand-file-name "org-museum-publish-policy.json"
                        user-emacs-directory))
```

```json
{
  "schemaVersion": 1,
  "include": ["index.html", "timeline.html", "graph.html", "related.html", "pages/**", "resources/**"],
  "exclude": ["pages/private/**"],
  "authorizations": [],
  "detectors": [
    {
      "name": "internal account marker",
      "regexp": "ACCOUNT-[0-9]+",
      "group": 0,
      "suggestion": "Replace it with a public example."
    }
  ]
}
```

Missing policy means the complete export tree, with no exclusions or
authorisations. You can resolve each finding in one of three explicit ways:

- edit the source and re-export until the finding disappears (`fixed`);
- exclude its published relative path so the file is absent (`excluded`);
- use the preview button to authorise that exact content (`authorized`).

An authorisation stores a SHA-256 fingerprint, relative paths, reason, and time;
it never stores the matched private text. The fingerprint includes the source
line context and occurrence number, so changed content or context automatically
becomes `unresolved` again. Preview buttons can open the source line, exclude a
file, authorise or revoke one exact finding, edit the policy, and rerun the
review. Full sync with unresolved findings still updates the local raw mirror,
but writes `review-required`; only a review with every finding fixed, excluded,
or authorised writes `ready`.

Deployment refuses both `blocked` and `review-required` before running Git or
GitHub commands. For a full-sync candidate it additionally rechecks the policy
digest, manifest SHA-256 values, sharing scope, candidate digest, custom rules,
and every exact authorisation. Editing status JSON, changing policy after sync,
adding a managed-namespace file, or modifying a reviewed candidate therefore
requires another full sync. A version-1 manifest has no hash baseline; its first
full-sync migration is shown as “baseline unknown,” then writes schema version 2
hashes for future conflict detection.

The first ready deploy shows the public repository name and asks before creating
it with the authenticated GitHub CLI. Later deploys refuse unexpected
uncommitted files, remote-ahead or diverged history, and symbolic links. Only
files recorded in the publish manifest are staged; repository-owned files such
as `CNAME` and `README.md` are preserved. The local export-only
`.org-museum-manifest.json` and the detailed privacy report are never published.
The dangerous full-sync operation is available through `M-x` and both command
panels as “Full Sync / Review Sharing”; it intentionally has no default key
binding.

## Project Structure

```
my-wiki/
├── dist/                  # Generated, reproducible site output
│   ├── pages/             # Page HTML files
│   ├── resources/         # CSS, JS, fonts, and icons
│   ├── assets/            # Content-addressed article assets
│   └── assets.json        # Asset metadata and per-page references
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
Org pages become Wiki page URLs. Other `file:` and `attachment:` resources are
validated, de-duplicated by SHA256, copied into `dist/assets/`, and rendered by
MIME kind. Downloadable HTTP(S) asset URLs are cached privately on first build.
If a remote file cannot be fetched, its original link remains in the page and the
export reports its source location; missing local files still fail validation.
Ordinary web pages remain normal links. Org source files are never rewritten.

Images use lazy loading and the existing lightbox. Video and audio use native
players with `preload="none"`; PDFs and other files use accessible attachment
cards. Articles with embedded media also receive a compact **资源** download list;
files already shown as download cards are not listed twice. Downloads retain
their original filenames. Run
`M-x org-museum-refresh-remote-assets` to explicitly refresh locked URL content.

Article reading actions remain available on small screens: return to the current
search, graph, timeline or related-reading selection; copy a clean page/section
URL or an Org Wiki reference; and toggle focus mode. Image previews provide
previous/next navigation, an original-image link, Escape to close, and focus
restoration. Search results support Enter and the up/down arrow keys.

Index discovery excludes generated export directories and the project-relative
`.git`, `.cache`, `node_modules`, and `output` directories. Customize
`org-museum-scan-excluded-directories` if one intentionally holds source notes.
Changing scan scope or deleting a source invalidates the cached index.

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

The wiki includes a live D3 force graph (`graph.html`) showing:

- Org-backed links and edited graph relations with their type, label, direction, weight, and line style
- Category-coloured nodes sized by real relationship count; drag, zoom, one-hop focus, expansion, and fit
- Node and edge inspectors, with direct relationship editing through the authenticated local service
- One-click 2D/3D switching over the same graph data, with 3D orbit, zoom, and node dragging
- Random switching between force, hierarchy, ring, and grid layouts without changing relationships
- A separate **待连接** view for notes without graph relationships

Run `M-x org-museum-graph-open-live` (or `G` in the Museum command panel) to
open the authenticated editable graph. The exported `file:///` page remains an
interactive, read-only view. The 2D/3D switch preserves the selected node,
relationship filter, category filter, and search query. In 3D, drag the empty
canvas to rotate and use the mouse wheel or zoom buttons to change scale.

The main index (`index.html`) includes a small local graph for each page's immediate neighbors.

## Configuration

### Customization Options

| Option | Default | Description |
|--------|---------|-------------|
| `org-museum-root-dir` | `nil` | Root directory of your wiki |
| `org-museum-export-dir` | `"dist/pages"` | Page export location |
| `org-museum-shared-export-dir` | `"dist"` | Shared site output location |
| `org-museum-assets-subdir` | `"assets"` | Content-addressed asset directory below the shared output |
| `org-museum-asset-cache-directory` | Emacs user cache | Private locked cache for remote assets |
| `org-museum-asset-large-file-threshold` | `104857600` | Warning threshold for large assets in bytes |
| `org-museum-publish-directory` | `nil` | Dedicated local Git checkout for the public site |
| `org-museum-publish-repository` | `nil` | GitHub target in `OWNER/REPOSITORY` form |
| `org-museum-publish-branch` | `"main"` | GitHub Pages source branch |
| `org-museum-publish-remote` | `"origin"` | Git remote used for publishing |
| `org-museum-css-file` | `"resources/org-museum.css"` | CSS file path |
| `org-museum-open-browser-after-export` | `t` | Auto-open browser after export |
| `org-museum-open-page-after-export` | `index` | Page opened after export: `index`, `graph`, or `nil` |
| `org-museum-open-publish-directory-after-sync` | `t` | Open the synchronized publish directory after interactive sync |
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

### System and Manual Themes

The wiki follows the system's light/dark preference by default and responds
when that preference changes. Open the shared theme menu to choose **跟随系统**
or manually switch light/dark. The preference in
`localStorage["org-museum-theme"]` accepts `system`, `dark`, and `light`;
missing or invalid values use `system`. A manual choice takes precedence until
you select **跟随系统** again. The local startup script applies the preference
before page paint, without a network request.
For default `file:///` browsing, local HTML navigation also carries that value
in an `org-museum-theme` query parameter so each page can initialize its own
storage scope; existing search, filter, anchor, and unrelated browser state is
left intact.

The dark theme includes:

- Shared dark surfaces and semantic text, control, and graph colour tokens
- Syntax highlighting via Highlight.js
- Styled blockquotes, tables, and code blocks

### Org Mode Body View

Use **切换为 Org Mode** beneath an article title to view its exportable Org
body, then **切换为阅读视图** to return. Emacs Org Mode font-lock generates the
syntax spans, including native language highlighting inside source blocks;
the shared light/dark palette keeps these faces readable in either theme.
The source pane preserves indentation and table columns, with optional
**自动换行** and **复制 Org 正文** controls. TOC links also navigate to Org headings.
Source extraction respects excluded headings and drawers and never executes
Babel blocks.

### Zen Mode

Press `z` to toggle Zen mode — a distraction-free fullscreen view for focused writing.

### Scroll Spy

The page automatically highlights the current section in the table of contents as you scroll.

### Tubes (Reading Progress)

A subtle reading progress indicator appears at the bottom of each page.

### Graph Navigation

- Press `g` to open the full-site graph view
- Click or press Space to select a node; double-click or press Enter to open it
- Hover only shows a lightweight tooltip and does not change the URL or selection
- Use the persistent reading panel for summary, dates, tags, incoming/outgoing
  relationships, previous/next navigation, related reading, and timeline context
- Isolated notes stay in the folded **待连接笔记** area by default instead of
  occupying the relationship canvas

Open **布局** to select force, hierarchy, ring, or grid directly, adjust node
spacing, choose vertical/horizontal hierarchy, stop automatic movement, or
reset positions fixed by dragging. Layout preferences are stored locally.
**随机切换布局** selects a different topology each time. Connected components
are arranged independently and packed to fit the canvas; directed cycles are
condensed before hierarchy depth is assigned. Node labels keep a readable
screen size and try multiple positions to avoid nodes and other labels.
All layout changes affect presentation only. 2D/3D use the same graph snapshot
and retain selection, relation filters, and category filters when switching.

The graph preserves the direction of every explicit Org link. Unlabelled links
appear as `显式链接`. To label an existing outgoing link, add repeatable metadata
to the source page:

```org
#+MUSEUM_RELATION: target-page-id | 启发影响
```

This metadata never creates a relationship by itself. Its target must also be
present in an explicit outgoing Org link on the same page; otherwise it is
ignored and listed by the index health diagnostics. The first valid value wins
when labels are repeated or conflict.

Edits made in the live graph are saved as `#+MUSEUM_GRAPH_EDGE:` JSON keywords
in the owning Org note. These records can add a graph relationship or override
an existing link's public type, label, direction, weight, and style. Deleting a
graph edge stores a tombstone in that same note; it removes the edge from the
graph while preserving any original link embedded in prose. The local service
checks the source hash and unsaved Emacs buffers, creates a backup, rebuilds the
index, and returns an updated graph snapshot after each edit. External Org file
changes are picked up while the live graph is open.

Search, category, and explicit focus are bookmarkable:

```text
graph.html?q=ontology&category=Ontology&focus=page-id&view=triage
```

Search updates the current history entry; category and node selection create
history entries so Back and Forward restore the filters and reading panel.
`view` accepts `relations` (default) or `triage`; invalid values fall back to
relationship reading. The graph remains fully local and works from `file:///`
without edit access.

`layout` accepts `force`, `hierarchy`, `ring`, or `grid`; `dimension=3d` opens
the rotatable projected 3D view.

### Timeline Reading

`timeline.html` arranges every indexed note by its first valid `#+DATE`. When a
date is missing or invalid, the file modification time is used and reported by
the index health diagnostics. Creation nodes are shown by default; focusing or
selecting a note reveals its modification point, interval, metadata, summary,
tags, publication state, and explicit incoming or outgoing Org links. The
desktop keeps a stable full-range axis and opens details beside the selected
node, while unrelated nodes and relations recede without changing position.

The view is bookmarkable and works from `file:///` without a server:

```text
timeline.html?q=ontology&category=Ontology&status=published&focus=page-id
```

Below 820px the horizontal chart becomes a month- and date-grouped vertical
time stream. Filters open in a bottom sheet, selected details stay beside their
note, and previous/next controls support continuous reading. Generate only this
page when needed with `M-x org-museum-export-timeline`.

### Relationship Reading

`related.html` lists every explicit Org link in the generated index. Open a
pair with stable, bookmarkable parameters:

```text
related.html?source=source-id&target=target-id&mode=summary
related.html?source=source-id&target=target-id&mode=full
```

Summary mode uses only source material: `DESCRIPTION`, or the first readable
paragraph, up to six first-level exported sections, and two excerpt
paragraphs. Full mode embeds cleaned exported article content and preserves
tables, code, images, anchors, and internal links. No network request, AI
summary, or `fetch` call is used. Missing or invalid IDs return to the relation
index with an understandable empty state.

Generate only the relationship center when needed:

```elisp
M-x org-museum-export-related-reading
```

## Safe Local Curation

Static exports remain read-only. On `file:` and localhost pages, the graph's
**待连接** queue can hand a short relationship request back to Emacs. Public
exports hide the action and contain no loopback token or API route.

The default review path is `org-protocol`:

```elisp
(setq org-museum-curation-mode 'protocol)
```

Use `M-x org-museum-curation-protocol-install-command` to copy, but not run, a
Windows registration command for `C:\v\Emacs\bin\emacs.exe`. The command does
not inspect or overwrite an existing handler; check the registry value first.
`org-museum-curation-protocol-uninstall-command` likewise only copies an
uninstall command.

For an explicitly authenticated local session:

```elisp
(setq org-museum-curation-mode 'loopback)
(setq org-museum-curation-port 0) ; random free localhost port
(setq org-museum-curation-backup-directory
      "D:/backups/org-museum-curation/") ; outside the Wiki root
M-x org-museum-curation-server-start
```

The loopback server binds only to `127.0.0.1`, moves its 256-bit session token
from the URL fragment into session storage, and exposes versioned curation and
AI Center operations. Curation writes require a
fresh SHA-256, a short-lived preview transaction, an explicit second apply,
and a persistent backup. Identity or path changes require another confirmation.
Unknown fields, requests over 64KB, unsaved buffers, stale files, unknown IDs,
unsafe tags, path escape, symlinks, reserved names, and collisions are rejected.
Stop and invalidate the session with `M-x org-museum-curation-server-stop`.

Supported changes are title, `WIKI_ID`, category, publication status, created
date, description, tags, a relative `.org` path under `pages/`, and controlled
relations. Browser-created links live in a marked **Related Notes** section;
prose links outside that section remain manual edits.

## AI Center Model Connections

The AI Center offers **浏览器模型** and **Emacs 后端**. Browser mode works
without Emacs: configure an OpenAI-compatible API base (for example,
`http://127.0.0.1:1234/v1` for LM Studio) or an Ollama base
(`http://127.0.0.1:11434`), read the service's actual model list, and choose a
model or enter its ID. **加载并测试所选模型** sends a short real inference request
to verify readiness. Compatible services must support `/models` and
`/chat/completions`; Ollama uses `/api/tags` and `/api/chat`.

Both modes share the same analysis, conversation, capture library, exploration,
proposal review, relationship, knowledge gap, combination review and scan UI.
Browser mode stores its workspace in IndexedDB, separately for each wiki and
website origin. Select up to 12 published notes; real parallel workers analyze
each source before the combined conversation. Source versions, completed and
interrupted turns, edited captures and original context survive a refresh.
Only explicitly selected published notes are sent to models (20,000 characters
per source, 180,000 total for combined analysis). Private or unpublished notes
remain available only through the authenticated Emacs workspace. API keys stay
in page memory and are excluded from preferences, backups and synchronization.

**本地保存、导出与同步** exports the full workspace JSON or confirmed Org
additions. Import a backup in the authenticated page opened by
`org-museum-ai-center-open`, choose browser mode, and use **预览同步到 Emacs**.
Different ports have separate browser storage, so use export/import to transfer
between the static preview and that page. Explicit confirmation imports sessions,
captures, private relations, reviewed experiences and combination candidates,
and applies confirmed Org additions with backups and rollback. Changed source
versions or newer Emacs edits block conflicting imports. Browser additions stay
local until synchronization; saving locally never claims the original notes were
modified or experiences published. Imported combination claims remain pending
review in Emacs. Browser scan/change detection covers the published export;
Emacs retains access to the underlying files and unpublished sources.
Browser access requires the model service to allow this site's origin (CORS).
For Ollama, configure permitted origins with `OLLAMA_ORIGINS` according to its
[official FAQ](https://docs.ollama.com/faq#how-can-i-allow-additional-web-origins-to-access-ollama).
This mode uses remote or locally served models; it does not download model
weights into the browser. The model connection differs; the knowledge workflows
and explicit review steps are shared.

## Build Pipeline

`org-museum-export-all` performs the following steps:

1. **Scan** — Find all `.org` files in the wiki root
2. **Index** — Build JSON index of all pages and links
3. **Resolve Assets** — Validate Org links, MIME-classify, hash, and de-duplicate
4. **Export** — Convert each `.org` file to HTML with kind-based renderers
5. **Generate Index** — Create `index.html` with all pages
6. **Generate Graph** — Create `graph.html` with D3 visualization
7. **Generate Relationships** — Create `related.html` and its versioned local data
8. **Generate Timeline** — Create `timeline.html` and its versioned local runtime
9. **Publish Assets** — Write `assets/`, `assets.json`, CSS, JS, fonts, and icons

### Test and Export Commands

From the canonical checkout, run the complete ERT suite with Emacs 30.2:

```powershell
& "C:\path\to\emacs-30.2\bin\emacs.exe" -Q --batch `
  -L . -L test -l test/org-museum-test.el -f ert-run-tests-batch-and-exit
```

For the configured real wiki, run `M-x org-museum-export-all`. This rebuilds
the recoverable index and HTML under `dist/`; it does not modify the
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
