# Org Museum 第二轮 Design QA

## 视觉基线

- 设计方向：沿用已选 Index Matrix 与 Monokai，不引入新的主题语言。
- 阅读密度：正文基准 12px；中文优先；所有资源继续离线加载。
- 本轮修复前真实页面截图：
  - 首页：`C:\Users\luoyu\AppData\Local\Temp\org-museum-usage-audit-2026-08-01\01-home.png`
  - 主题筛选：`C:\Users\luoyu\AppData\Local\Temp\org-museum-usage-audit-2026-08-01\08-topic-filter.png`
  - 长文章章节入口：`C:\Users\luoyu\AppData\Local\Temp\org-museum-usage-audit-2026-08-01\03-article-section.png`
  - 移动图谱：`C:\Users\luoyu\AppData\Local\Temp\org-museum-usage-audit-2026-08-01\05-graph-mobile.png`

## 同视口比较证据

比较图左侧为修复前真实页面，右侧为最终实现。桌面按 1280×720 CSS
像素、移动端按 390×844 CSS 像素验收；Playwright 截图使用 CSS scale，
两种视口的 `devicePixelRatio` 均为 1。旧首页与筛选截图原始尺寸为
1265×712、旧移动图谱为 390×843；比较前只在右下补齐背景，没有缩放或
拉伸内容。

- 首页：`test/qa/second-round-compare-home-1280x720.png`
- 主题筛选：`test/qa/second-round-compare-filter-1280x720.png`
- 长文章：`test/qa/second-round-compare-article-1280x720.png`
- 移动图谱：`test/qa/second-round-compare-graph-mobile-390x844.png`
- 最终实现原图：
  - `test/qa/second-round-home-1280x720.png`
  - `test/qa/second-round-home-sql-filter-1280x720.png`
  - `test/qa/second-round-article-section-1280x720.png`
  - `test/qa/second-round-graph-mobile-viewport-390x844.png`
  - `test/qa/second-round-graph-mobile-390x844.png`（完整页面）

## 主要交互与状态证据

- 首页索引为 schema 2，包含 12 篇笔记、1 篇已发布、11 篇草稿、6 个
  主题；1280×720 下“全部笔记”入口距视口顶部 379px，首屏可达，页面
  水平溢出为 0。
- 搜索、主题与状态共用 `{query, category, status}`：SQL 主题返回 3 篇，
  与草稿组合后仍为 3 篇；后退恢复主题状态；清除筛选与顶部“全部笔记”
  均恢复 12 篇。URL 正确保存 `q`、`category`、`status`。
- 搜索“学习目标”只返回一篇最佳结果，链接直达该文章的真实章节锚点；
  重新完整导出后，首页索引与文章锚点仍保持同批一致。
- 105 分钟长文的目录包含 146 项，桌面目录和正文水平溢出均为 0；19 张
  表格均位于独立滚动容器。章节直达时粘性身份栏显示文章、SQL、草稿和
  当前“1.1. 学习目标”。
- 390×844 下，章节标题距身份栏底部 42px，不被身份栏或底部 HUD 遮挡。
  目录抽屉被移到 `BODY` 层，关闭按钮可点击，关闭后 `aria-expanded=false`
  且焦点返回启动按钮。
- 零连线图谱保持 12 个孤立笔记、6 个分类簇和 0 条推断关系。移动端筛选
  摘要默认折叠，图谱工作区 `overflow-y: visible`、嵌套滚动差值为 0，页面
  水平溢出为 0；“复制链接”进入“已复制”并更新实时状态。
- `duckdb-ontology.html` 的 6 个现存外部本地链接均正确解析：3 个 Org、
  3 个 SQL，全部输出 `file:///` 地址、“本地文件”状态和“复制路径”操作；
  本轮真实库没有缺失目标。
- 阅读状态通过同源 HTTP 实测：浅访问产生 0 条记录；8% 进度产生 1 条
  合格记录并带章节锚点；失效章节回退到 8.1% 滚动比例；已删除页及旧版
  0% 浅访问被清除；停留 30.043 秒且进度为 0 也能合格；IndexedDB 被禁用
  时继续阅读区隐藏，全部 12 篇最近更新仍可用。
- 首页、长文章与图谱在全新浏览器会话中产生 0 个 JavaScript 异常；页面
  不含远程资源引用。Windows Straight 的纯文本链接占位文件已在部署时
  解引用，D3 与 Highlight.js 均输出真实离线资源。

## 已解决问题

- P1：首页主题筛选后无法回到全部笔记；改为统一 URL 状态管线、可组合
  控件、结果摘要和稳定清除入口。
- P1：章节直达缺少文章身份，且锚点被粘性栏遮挡；增加按需身份栏与
  48px 章节滚动留白。
- P1：移动目录遮罩挡住关闭按钮；抽屉模式下把目录移出滚动层并保留
  焦点陷阱与恢复。
- P1：Windows Straight 资源占位文件被原样导出，导致 Highlight.js 与
  D3 语法错误；部署时改为复制实际仓库资源，并覆盖 CSS 同类情况。
- P1：移动零连线图谱有固定工作区和双重滚动；改为自然文档流、折叠摘要
  和共享筛选状态。
- P1：相对本地 Org/SQL 链接按导出目录解析；改为按源 Org 目录解析，并
  提供存在、缺失和复制路径状态。
- P2：健康报告只覆盖已发布孤立页且缺少描述/本地链接诊断；现已覆盖所有
  状态，并报告描述、本地外链、失效目标和源文件新旧关系。
- P2：缺失 favicon 产生 404 控制台噪音；所有页面加入离线空 favicon。

## 最终评估

同视口视觉比较与主要任务路径中没有未解决的 P0、P1 或 P2 缺陷。最终
批处理测试和真实导出结果见交付说明。

## 第三轮阅读与图谱验收（2026-08-01）

- `1440×1024` 真实长文正文宽度为 959px，基准字号 12px，全局水平溢出为 0。
- `1280×720` fixture 正文宽度为 960px，目录自动切换为固定抽屉；移动端
  `390×844` 正文宽度为 327px，基准字号仍为 12px，水平溢出为 0。
- 真实长文共识别 31 个长代码块；折叠态实测 320px / 523px，点击后展开为
  523px / 523px，并同步更新为 `COLLAPSE` 与 `aria-expanded=true`。
- 旧版 `org-museum-bg-fx=tubes` 不再自动恢复；新页面首次加载 Canvas 为
  `display:none`，控制台无异常。
- 真实零连线图谱渲染 12 个节点、0 条边且画布可见；fixture 显式链接图谱
  渲染 3 个有效节点、2 条真实边。两种状态均无远程资源和控制台异常。
- Monokai 语义色已覆盖正文标题、强调、行内代码、列表、表格、Org htmlize
  类与 Highlight.js 类；普通正文仍保持高对比白灰。
- ERT 全套 25/25 通过；真实完整导出 12/12 成功，manifest 与文章数量均为 12。

- 背景效果主动开启后进入 Zen 阅读模式，Canvas 会立即从 `display:block` 切换为
  `display:none`；离开页面会注销动画帧、媒体查询、可见性、按钮与观察器监听。
- 最终 `graph.html` 渲染 12 个真实节点、0 条虚假边，无全局横向溢出、无控制台错误；
  D3 或 Highlight.js 本地部署失败时不再写入 CDN 地址，而是使用无障碍清单或未高亮代码降级。

## 第四轮系统健康与可访问性验收（2026-08-01）

- 当前交互式 Emacs 曾保留旧版函数定义，重新导出会覆盖修复后的页面；已同步 Straight
  构建副本、热重载实际 Emacs 进程，并由该进程完成 12/12 真实导出。
- 浏览器健康检查遍历首页、图谱和全部 12 篇文章，并复测 390×844：无控制台异常、
  请求失败、远程资源、重复 ID、失效锚点、全局横向溢出或标题层级跳跃。
- CJK 自动间距不再进入 `pre/code/kbd/samp/script/style/textarea/contenteditable`；
  真实 SQL 页所有代码块与未执行脚本的原始 HTML 对比差异为 0。
- 侧栏搜索和链接提示仅通过 DOM 文本节点渲染；包含 `<img>` 的合成标题不会生成节点，
  两条内容注入复现均已关闭。
- 所有页面增加键盘“跳到正文”入口；移动文章页主要按钮、搜索框、目录、背景设置和代码操作
  的命中区均达到 44px，审计中的过小主要控件从 12 个降为 0。
- 图片预览支持 Enter/Space 打开、Escape/背景/关闭按钮退出、Tab 焦点约束、替代文本与焦点恢复。
- D3 故障注入退化为 12 条笔记清单；Highlight.js 故障注入仍保留 63 个可读代码块和折叠操作。
- ERT 全套 30/30 通过；长代码块在 1440×1024 与 390×844 下均识别 13 个，样式留白不再影响判定。

## 第五轮键盘、语义与独立可访问性验收（2026-08-01）

- 关闭的全部笔记与目录抽屉原先分别保留 20 和 148 个可聚焦控件，Tab 会进入屏幕外内容；
  现使用 `inert` 与 `aria-hidden` 同步隔离，1280×720、390×844 下各循环 240 次 Tab 均无隐藏焦点。
- 1440×1024 的内联目录保持 `inert=false`，断点切换、打开、Escape 关闭及触发按钮焦点恢复均通过。
- 首页分类脚本不再把普通文章误识别为按压控件；卡片分类入口改为按钮语义，筛选、URL 历史和清除流程保持一致。
- 可横向滚动的实际 `<pre>` 容器在需要时获得键盘焦点，窗口尺寸及展开状态变化后重新计算；
  Highlight.js 不再制造内层滚动，纯文本、未知语言和高亮代码均通过，短代码不增加多余 Tab 停靠点。
- 图谱 SVG 根节点由图片语义改为交互分组，12 个节点继续作为可键盘打开的链接，不再形成嵌套交互冲突。
- Monokai 粉色调整为同色相的可读版本 `#ff4f8b`（对 `#272822` 为 4.77:1）；离线 Highlight.js
  主题同步更新粉色与注释灰，避免后加载样式覆盖主色板。
- Axe 对首页、长文桌面、长文移动端和移动图谱的 WCAG 2 A/AA 与 2.1 AA 扫描均为 0 violations。
- 14 页结构遍历、首页历史筛选、移动抽屉、代码展开和图谱流程均无失败，控制台 0 error；ERT 32/32 通过。

## Round 6 cache and recovery verification (2026-08-01)

- Reproduced the stale-export symptom in one browser session: an unversioned CSS
  URL remained cached after its bytes changed, while a content-versioned URL
  loaded the new bytes immediately.
- Main CSS, Highlight.js CSS and scripts, and D3 now use stable 12-character
  SHA-256 content versions. The real export emitted 12 manifest pages with
  `org-museum.css?v=1a608ec1a416`,
  `highlight.min.js?v=471ef9ae90c4`, and
  `d3.v7.min.js?v=f2094bbf6141`.
- CSS deployment now compares bytes instead of trusting timestamps, preventing
  a newer stale destination from masking a changed source file.
- HTTP browser verification loaded both versioned stylesheets, rendered 13 long
  code controls and 12 graph nodes, reported zero horizontal overflow, and
  produced zero console errors. A malformed percent-encoded article hash also
  remained operational.
- Corrupt legacy reading progress is clamped to the finite 0-1 range before it
  reaches the resume UI. ERT completed 35/35 tests, including full offline
  fixture export and version assertions for index, article, and graph pages.

## Round 7 export efficiency and HTML conformance (2026-08-01)

- A six-page fixture reproduced 24 Highlight.js deployment checks per export;
  the full-export cache reduces this to one deployment check per batch while
  preserving independent checks for single-page exports.
- Independent HTML validation reduced 290 structural and semantic errors to
  zero. The only excluded rule is trailing whitespace inside two user-authored
  code examples, which is preserved as source content.
- The real 12-page export repairs Org 9.8's malformed tag separator, gives each
  scrollable table a unique native landmark, and uses valid navigation, button,
  time, search-label, and graph-legend semantics.
- Browser lifecycle verification found one lightbox overlay and one background
  canvas before and after history navigation, with no duplicate controls and
  zero console errors. The long SQL article has 13 code toggles and 19 table
  containers with no global horizontal overflow.
- The first long code block changes from 320px collapsed to 425.75px expanded,
  with `COLLAPSE`, `aria-expanded=true`, and the expanded CSS state synchronized.
- The real zero-link graph renders 12 nodes, zero inferred edges, six native
  legend items, a visible canvas, and no global horizontal overflow.
- ERT completed 38/38 tests, including batch resource caching and the repaired
  exported HTML semantics.

## Round 8 persistence and failure-atomicity verification (2026-08-01)

- Reproduced an existing IndexedDB v1 database with a valid `readingState`
  record but no `lastVisitedAt` index. Before the fix, the record remained in
  storage while the entire continue-reading section was hidden.
- The homepage now falls back to the object-store cursor when the optional
  index is absent, normalizes and sorts records by `lastVisitedAt`, and keeps
  the most recent six. The database remains `org-museum` version 1 and no
  migration or destructive reset is performed.
- Reproduced a failed article export that still regenerated index.html and
  graph.html. Full exports now preserve the previous entry pages whenever any
  article fails; manifest writing and stale cleanup remain success-only.
- Direct `file:///` verification passed for the homepage, graph, and long SQL
  article: 12 indexed pages, three DuckDB search results, one loaded stylesheet,
  12 D3 nodes, 13 working code toggles, 19 table containers, no horizontal
  overflow, and zero browser errors.
- The real HTTP export passed 17 desktop/mobile page cases, 643 internal-link
  instances, 32 unique targets, all fragment targets, duplicate-ID checks,
  ARIA reference checks, offline-resource checks, and console monitoring.
- The real manifest contains 12 pages, independent HTML validation reports zero
  structural errors, and ERT completed 39/39 tests.

## Round 9 index integrity and transactional-save verification (2026-08-01)

- A two-file fixture with the same `WIKI_ID` previously completed silently
  with one indexed page. Index construction now raises a dedicated duplicate-ID
  error that names both source files, preventing invisible page replacement.
- A late incremental-update failure previously replaced the old indexed page
  before logging an error. Updates now run against a private working copy and
  commit only after parsing, registration, link repair, and cache persistence
  all succeed; the original index remains byte-for-byte usable on failure.
- Successful incremental updates were separately verified to commit the new
  page metadata and inbound-link state as one complete working copy.
- Independent review found that unchanged outgoing links lost their target's
  backreference after a normal save, because only newly added links were
  restored. All current targets now receive the current page ID after the old
  page is removed; both stable IDs and page-ID renames retain correct inbound
  links.
- An injected disk failure after writing JSON previously overwrote the stable
  cache. Index persistence now writes a same-directory temporary file and only
  replaces the cache after a complete write; failure preserves the old bytes
  and removes the temporary artifact.
- The real library exported 12 pages with 12 unique IDs, a 12-page manifest,
  12 article HTML files, and zero leftover index temporary files. Independent
  HTML validation reports zero structural errors.
- ERT completed 45/45 tests, including duplicate IDs, late rollback,
  successful commit, unchanged links, ID renames, and atomic cache failures.

## Round 10 resource, section, graph and print verification (2026-08-08)

- Straight repository resources are now authoritative over stale build, link-tree,
  and legacy roam copies. The final repository and exported CSS SHA-256 are both
  `7f6bf8e0c1c45abc995c257540bd2bb9d9f8de7e0cd5adc69d96f6aab82f7e1b`, and all
  14 HTML files reference `org-museum.css?v=7f6bf8e0c1c4`. When the repository
  asset is absent or a link placeholder points to a missing target, both CSS and
  shared script deployment explicitly fall back to the Straight build copy without
  exporting pointer text or attempting the network.
- Direct entry to the current long-article 5.5 anchor resolves one shared state:
  sticky identity text and TOC highlight both report 5.5, the heading clears the
  top bars at 168px, the article column is 960px, and horizontal overflow is zero.
- At 390x844 the graph renders 12 real isolated nodes and zero edges. All 12 labels
  remain inside the SVG, the smallest hit target is 32px, Space selects, Enter opens,
  and the unselected detail link stays hidden. The 32px hit area remains constant at
  every zoom level. Forced reduced-motion output produced 12 distinct precomputed
  positions, disables the freeze control, and reports `布局已静止`.
- Monokai scrollbars are active on the mobile article and graph (`#5f6057` thumb,
  `#1e1f1c` track), with no page-level horizontal overflow or console warnings.
- A real Edge print produced a 52-page article PDF. Rendered page inspection confirms
  a light paper surface, readable code and tables, sensible page breaks, and no topbar,
  sidebars, mobile HUD, open drawer/backdrop, background effects, or code buttons.
- Final browser checks found 13 working long-code toggles, no remote resources, no
  console errors, 12 manifest pages, 1 published / 11 drafts, 6 categories, and zero
  inferred graph relationships. ERT completed 51/51 tests.
- Final screenshots and print artifacts are in
  `C:/Users/luoyu/AppData/Local/Temp/org-museum-audit-2026-08-08/09-home-1280-final.png`,
  `10-graph-mobile-final.png`, `11-article-anchor-mobile-final.png`, and
  `16-article-print-final.pdf`.

## Round 11 stable anchors, responsive graph and lifecycle verification (2026-08-09)

- Repeated full fixture exports now preserve every exportable H2-H4 anchor. `CUSTOM_ID` and
  heading `ID` remain authoritative; all other anchors use a deterministic
  `section-<12 hex>` value derived from page ID, full outline path, and duplicate
  occurrence. `COMMENT`, `noexport`, selected-tree, archived-tree, and task export
  rules are evaluated before pairing source headings with generated HTML. The real
  export contains 316 stable section anchors and zero transient `org...` heading anchors.
- URL entry, TOC highlighting, sticky identity, and reading history share one active
  heading. Direct entry to `#section-cd51d6fc4549` reports section 5.5 everywhere;
  switching from 1440x1024 to 390x844 keeps 5.5 through responsive reflow, while a
  subsequent real user scroll updates the state to the newly visible section.
- The mobile article has two contextual TOC triggers with 44px minimum targets and no
  bottom HUD. At 390x844 its content width is 332px, document width equals viewport
  width, the direct target remains below the sticky bars, and no horizontal overflow
  occurs.
- The graph recomputes its SVG viewBox from `332x558` at 390x844 to `870x571` at
  1280x720. All 12 labels remain within the canvas, hit targets are at least 32x32px,
  mobile filters default closed, and desktop filters reopen after the breakpoint.
- Graph query and selection use one `{query, category, selectedId}` state. Searching
  `DuckDB` reports three matches; selecting one node keeps all three matches visible;
  clear selection restores the prompt and removes `aria-current`.
- Reading state now saves qualified sessions when the page becomes hidden, clears its
  timers on `pagehide`, resumes once on `pageshow`, and rewrites uniquely matched old
  heading titles to stable IDs without changing IndexedDB version 1.
- Health reporting now adds duplicate outline paths and transient exported anchors to
  the existing missing-description and isolated-page diagnostics. It remains read-only
  and does not modify Org sources.
- The real export completed 12/12 pages: 1 published, 11 drafts, 6 categories, 12 graph
  nodes, and zero inferred links. Repository, exported, and Straight build CSS all use
  SHA-256 `71d9d49e8416884a923eb46f35521075f12a80ca3c0a1d65faa03144f72863e7`;
  all 14 HTML files carry the content-versioned CSS URL and no remote runtime assets.
- HTTP browser verification completed at 1440x1024, 1280x720, and 390x844 with zero
  console warnings or errors. Direct `file:///` navigation could not be repeated because
  the automation browser blocks local-file URLs by policy; no bypass was attempted.
  Static inspection confirms relative offline assets, and the prior Round 8 direct-file
  acceptance remains applicable.
- ERT completed 60/60 tests, including stable duplicate headings, export-excluded
  subtrees, stale cross-page fragments, legacy reading
  recovery, responsive reflow, unified graph state, mobile TOC controls, and hidden-page
  persistence.

## Round 12 runtime consistency, mobile retrieval, and package quality (2026-08-09)

- Every export entry point now compares the loaded Elisp digest with the
  authoritative Straight repository source before writing. The current Emacs,
  repository, and Straight build all use SHA-256
  `56ed8689b9a357cbfe2d6c250906749d7f552840b3da0827bdb312630024d114`.
  Reload failure and one-time re-entry are covered without allowing stale code
  to mutate the index, HTML, or manifest.
- Filtered home states use a results-first layout. At both 390x844 and 320x844,
  `DuckDB` reports three results and the first result ends at 382px and 403px
  respectively, without scrolling. Clearing filters restores the continue-reading
  and topic sections. Top navigation targets measure 44px high at 12px type;
  index metadata is 11px and horizontal overflow is zero.
- Legacy reading records recover a unique stable section from a normalized title
  whether the old ID is invalid or absent. Ambiguous titles keep the scroll ratio
  without emitting a stale fragment. The home page also has a screen-reader H1.
- All 12 articles now emit a valid HTML doctype and `lang="zh-CN"` unless an
  explicit `#+LANGUAGE` overrides it. Browser entry to
  `#section-cd51d6fc4549` shows 5.5 in the heading, sticky identity, and
  `toc-active` link, with the heading at 204px and no horizontal overflow.
- Index, article, and graph executable code is externalized to three local,
  content-versioned resources. The 12 article files contain zero executable
  inline scripts; the 41,478-byte shared article runtime avoids about 456KB of
  repeated output. D3, Highlight.js, CSS, and generated runtimes have no network
  fallback and all three generated scripts pass `node --check`.
- The real export contains 12 manifest pages, 316 stable H2-H4 anchors, zero
  transient heading anchors, 12 graph nodes, zero inferred links, and three
  local runtime assets. Repository, Straight build, and exported CSS share
  SHA-256 `60a2bb88eceba974ac820eed219924a3fe04ac73800e6c6174d719fafb321af0`.
- Browser checks at 1440x1024, 1280x720, 390x844, and 320x844 found a 960px
  desktop article, no global horizontal overflow, no remote requests, and no
  console warnings or errors. The mobile graph keeps all 12 labels inside its
  332x558 canvas with 32x32px hit targets. Code expansion changes the first long
  block from 320px / `EXPAND` to 426px / `COLLAPSE` with synchronized ARIA state.
- Direct `file:///` navigation was blocked by the automation browser's URL
  policy, so no bypass was attempted. Static inspection confirms relative local
  assets; HTTP execution completed without remote requests.
- Source text is normalized to LF through `.gitattributes`. Emacs byte compilation
  completes with warnings treated as errors, and ERT completes 69/69 tests.
  Both Standards and Spec re-reviews report no remaining actionable findings.
- Current-round screenshots are stored in
  `C:/Users/luoyu/AppData/Local/Temp/org-museum-audit-2026-08-09-round13/` as
  `01-home-desktop-1440.png`, `03-home-mobile-search-320.png`,
  `04-article-mobile-anchor.png`, and `05-graph-mobile.png`.

## Round 13 全站阅读体验重构（2026-09-04）

### 视觉来源与同视口比较

- 来源：`C:\Users\luoyu\Downloads\ChatGPT Image Sep 3, 2026, 10_14_22 PM.png`，
  1668×944 像素，1× 密度；状态为深色书架、暖白纸张、双篇摘要对读。
- 实现：`test/qa/reading-shell-related-1668x944-pass3.png`，1668×944 CSS
  像素，`devicePixelRatio=1`，同样使用深色主题与一组真实双向 Org 链接。
- 最终并排比较：`test/qa/reading-shell-comparison-final.png`。局部重点复核了
  顶栏/书架、标题与元数据、双栏正文、关系带和底部模式操作。
- 响应式原图覆盖 1280×720、820×944、390×844 与 320×720；另检查了
  桌面/移动文章、桌面图谱、首页和中档书架抽屉。

### 比较历史与修复

- Pass 1（P1）：模式栏占用纸张顶部并导致长标题换行；将模式切换移到底部，
  收紧标题和纸张内边距，并把搜索区纳入稳定顶栏网格。
- Pass 2（P2）：模式栏与纸张之间留白过大，桌面仍显示移动跳转按钮；把操作栏
  固定到参考图位置，桌面改为打开源笔记/图谱/目标笔记，快速跳转仅在小屏显示。
- 图谱 Pass 1（P1/P2）：暖色画布仍使用浅色文字，且选中节点只显示计数；统一
  暖纸文字令牌，增加明确的出链、入链和关联阅读入口，并分离选中/相邻标签位置。
- 响应式复核（P1）：1280px 首页主栏宽度没有扣除 294px 固定书架；820px
  书架已转抽屉但触发按钮仍隐藏。两项均已修复并加入 ERT 回归测试。
- 移动端（P1）：顶部导航挤压、字标换行、元数据抢占首屏；隐藏非核心链接、保持
  字标单行，并将文章元数据改为默认折叠的“文章信息”。

### 最终交互与实现证据

- 关联阅读支持无参数关系索引，以及稳定的 `source`、`target`、`mode` 参数；
  摘要/全文、交换方向、两侧打开、返回图谱、移动快速跳转均使用真实内容运行。
- 全文切换保留两侧会话滚动位置；双向链接明确标为“显式 Org 双向链接”，出链与
  入链方向分别按“当前 → 目标”和“来源 → 当前”表达，不显示推测关系。
- 820px 书架按钮实际显示，Escape 关闭后 `aria-expanded=false` 且焦点返回
  “打开全部笔记”；移动文章元数据默认关闭，目录按钮可见且命中区不小于 44px。
- 首页、文章、图谱、关联阅读在 HTTP 下均无横向溢出、远程资源、控制台 warning
  或 error。630 个本地 HTML 资源引用全部存在，9 个导出脚本全部通过语法检查。
- 当前自动化浏览器按安全策略拒绝 `file:///` 导航，未尝试绕过；本轮以相对资源
  静态检查、无网络运行时测试和既有 Round 8 的直接文件验收共同覆盖离线路径。
- 发布清单含 46 个文件并明确包含 `related.html` 与关系数据。真实隐私扫描在原
  `vibe-coding` 页面发现 4 项、在关系数据副本发现同源 6 项，证明副本不会绕过
  现有发布门禁；这 10 项仍会按既有策略阻止未经处理的公开发布。
- 使用本地 Noto Serif CJK SC 标题字体和 Phosphor 官方 SVG 子集；无在线 CDN、
  手绘替代图标或占位图片。许可与来源已写入第三方声明和字体来源记录。

### 最终工程验证

- GNU Emacs 30.2：ERT 156/156 通过；字节编译以 warning 作为 error 时通过。
- 真实全量导出：16/16 文章成功，首页、图谱、关联阅读与版本化资源同步生成；
  `symbol-file` 指向当前仓库的 `org-museum.el`。
- 未修改任何 Org 源文件或 `org-roam.db`；未提交、推送、发布或切换稳定版本。

最终同视口比较和主要阅读路径中没有未解决的 P0、P1 或 P2 视觉或交互缺陷。

## Round 14 独立时间阅读页（2026-09-04）

### 视觉来源与同视口比较

- 来源：`C:\Users\luoyu\Downloads\ChatGPT Image Sep 3, 2026, 10_01_56 PM.png`，
  1668×944 像素；采用时间筛选、横向月份轴、交错笔记节点和右侧阅读预览。
- 实现：`test/qa/timeline-1668x944-final.png`，1668×944 CSS 像素，深色书架与
  暖白纸张主题，选中真实 Ontology 笔记并展开创建到更新的时间区间。
- 最终并排比较：`test/qa/timeline-comparison-final.png`。结构、信息层级、月份主
  刻度、日期次刻度、主题色节点、显式关系弧、孤立笔记区和阅读预览均逐项复核。
- 响应式证据：`timeline-1280x720.png`、`timeline-820x944.png`、
  `timeline-390x844.png`、`timeline-390x844-selected.png` 与
  `timeline-320x844.png`。

### 比较历史与修复

- Pass 1（P1）：创建时间集中的卡片互相遮挡且顶部/底部被裁切。引入按日期距离
  分配上下轨道的布局，压缩卡片尺寸和轨道间距，并保留完整标题的可访问名称。
- Pass 2（P1）：两篇互链笔记同日创建时，普通曲线退化为零长度。为同日关系
  增加可见回环；互链仍合并为一条双向弧，不产生推测关系。
- Pass 3（P1/P2）：移动端主题筛选占据过多首屏且显示滚动条；改为隐藏滚动条的
  单行横向筛选，时间流提前进入首屏，选中详情继续紧邻节点显示。
- 内容复核（P1）：无 `DESCRIPTION` 的笔记曾把 Org 属性抽屉当摘要；摘要提取现
  在跳过属性/抽屉语法，并在没有有效段落时显示明确空状态。

### 最终交互与实现证据

- 时间索引包含 16 篇笔记、1 条显式关系、0 个日期回退；8 篇同日更新笔记使用
  “同日更新”语义。创建日期来自首个有效 `#+DATE`，更新日期来自文件修改时间。
- `q`、`category`、`status`、`focus` 会写入网址；主题和 Ontology 筛选、键盘
  Space 选择、更新时间展开、右侧/移动内联预览和关系阅读入口均在 HTTP 预览中运行。
- 820px 以下使用纵向时间流；390px 和 320px 无页面横向溢出，筛选与节点命中区
  不小于 44px。浏览器运行日志为空。
- 自动化浏览器按安全策略拒绝真实 `file:///` 导航，未尝试绕过。离线静态检查覆盖
  20 个 HTML、698 个本地引用，缺失引用与远程脚本源均为 0；10/10 个导出脚本
  通过语法检查。
- 发布候选共 49 个文件，明确包含 `timeline.html`、版本化时间运行时和时钟图标；
  隐私扫描仍报告既有 10 项源内容问题，时间页自身新增 0 项，证明时间页进入同一门禁。

### 最终工程验证

- GNU Emacs 30.2：ERT 159/159 通过；字节编译在 warning 作为 error 时通过。
- 真实全量导出：16/16 文章成功，首页、时间、图谱和关联阅读同步生成；批处理与
  当前 Emacs 31.1 会话的 `symbol-file` 都指向当前工作区 `org-museum.el`，运行时
  已重新加载并确认 schema 4 与 `org-museum-export-timeline` 可用。
- Org 源文件和 `org-roam.db` 未变化；未提交、推送、发布或切换稳定版本。

最终同视口比较与主要时间阅读路径中没有未解决的 P0、P1 或 P2 问题。

final result: passed

## Round 23 全系统 MECE 与安全策展验收（2026-09-13）

### 已解决的产品问题

- 全局外壳统一导航命名、语义色、焦点、状态条、对话框与操作层级；文章恢复阅读改为不遮挡正文的顶部状态条。
- 关联阅读保留摘要默认模式；完整正文增加双侧阅读进度、粘性标题和可选比例同步，移动端拆分为源笔记、关系、目标笔记三个互斥段。
- 时间轴在 1280×720 首屏容纳标题、筛选、主轴、详情与主要操作；移动端合并选中节点和详情，取消重复标题。
- 图谱将关系阅读与待连接彻底分离；待连接不再保留画布、布局控制、图例或旧焦点，摘要在卡片内展开。移动关系链改为单侧标签与纵向排布。
- 新增用户确认驱动的关系建立入口，以及 org-protocol 默认审阅和可选认证回环服务；静态公共导出不包含令牌、API 路径或回环运行时代码。

### 真实页面证据

- 1668×944：图谱关系/待连接、关联阅读完整正文均无横向溢出；待连接工作区为单列全宽，关系画布、控制、图例全部隐藏，URL 旧焦点已清除。
- 1280×720：时间轴主画布高度 420px，详情和“打开笔记／关联阅读”操作位于首屏。
- 820×944 与 320×844：首页、文章、关联阅读、时间轴、图谱五页矩阵横向溢出均为 0。
- 390×844 与 320×844：移动图谱节点标题全部位于画布内，标签互相重叠为 0；移动时间轴只保留一个选中详情标题，关联阅读每次只显示一个分段。
- 关联阅读完整正文两侧可滚动高度分别为 6059px 和 7761px，两个进度条可见，双侧标题计算样式均为 `position: sticky`；最终浏览器控制台错误与警告均为 0。

### 工程与安全验收

- GNU Emacs 31.1 严格字节编译退出码 0；全量 ERT 186/186 通过，其中新增错误令牌、跨源拒绝、服务停止失效、规范化、受控关系、路径约束、陈旧哈希和失败回滚覆盖。
- 主题/运行时测试通过，浅深色最低对比度为 4.61:1；差异空白检查通过。
- 当前源码真实全量导出 16/16，导出前后 16 个 Org 源文件指纹变化为 0，公共导出中的策展令牌、API 与注入标记引用为 0。
- 保留现有未提交改动；未提交、推送、发布、修改注册表、写入真实 Org 页面或数据库。

本轮计划内的视觉基础、发现与阅读、关联阅读、时间轴、图谱模式边界和安全策展链路均已实现并通过实页与工程回归，未发现未解决的 P0–P2 问题。

final result: passed

## Round 22 时间轴密度、动态画布与稀疏图谱收口（2026-09-12）

### 比较目标与证据

- 时间页视觉真值：
  `C:/Users/luoyu/Downloads/ChatGPT Image Sep 3, 2026, 10_01_56 PM.png`
  （1667×944）；当前实现：
  `output/playwright/org-museum-round22/timeline-light-selected-final-1668x944.png`
  （1657×944，CSS 视口 1668×944，devicePixelRatio 1.25）。两者归一到
  834×944 后并排放入 `timeline-comparison-final.png`。
- 图谱视觉真值：
  `C:/Users/luoyu/Downloads/f816e8d8-058e-4795-8884-e58dad99584c.png`
  （1672×941）；当前实现：
  `output/playwright/org-museum-round22/graph-light-selected-final-1668x944.png`
  （1668×944，CSS 视口 1668×944，devicePixelRatio 1.25）。两者归一到
  834×944 后并排放入 `graph-comparison-final.png`。
- 状态均为浅色主题、已选中“本体论建模 / 本体治理”关系路径。另检查
  `timeline-dark-selected-final-1668x944.png`、
  `graph-dark-selected-final-1668x944.png`、
  `timeline-light-selected-820x944.png` 与
  `graph-light-selected-820x944.png`。
- 全图在原始像素下可读，节点标题、关系标签、时间详情和图谱详情均可直接判断，
  因此无需另做局部裁切。420px 图谱截图出现浏览器合成伪影，已拒绝作为视觉证据；
  同一真实页面的 DOM 几何检查确认 3 个标题边界均位于 32.7–376.9px，页面横向
  溢出为 0，820px 浏览器截图作为窄屏视觉证据。

### 发现、修正与复核

- P1｜时间详情打开后 SVG 仍保留全宽 viewBox，导致节点与文字被横向压缩。
  增加动态几何同步；详情开合后画布与 viewBox 均为 1320×538，键盘 Space
  选择与网址直接恢复两条路径均通过，Escape 清理后无残留选择。
- P2｜时间轴固定 600px 以上画布放大无意义留白，11px 基础标题削弱阅读层级。
  画布改为 500–560px 随视口收敛，基础标题提升到 13px，选中标题 16px、关系
  邻居 14px；1668×944 首屏页面高度由约 1056px 收敛至 949px，横向溢出为 0。
- P2｜3 节点 / 2 连线的真实图谱只占画布中段，关系链和文字偏弱。稀疏布局跨度
  上限由 720px 提升到 900px，节点标题提升到 17px，关系标签 13px，并加强默认
  与选中路径线宽。桌面三个节点实测位于 x=206、656、1106，完整利用阅读面。
- P2｜390–420px 长标题可能贴边裁切，模拟触控后悬浮卡可能残留。窄屏标题截断
  阈值收紧到 8 个字符，420px 实测标题边界全部在视口内；820px 以下关闭悬浮卡，
  完整标题与关系事实仍保留在邻近阅读面板。

### 五项保真检查

- 字体与层级：继续使用本地 Noto Serif / Sans CJK；显示标题、正文、元数据、节点
  与关系标签的字号和字重层级清晰，无新增字体回退或截断退化。
- 间距与布局：时间页首屏更紧凑；详情开合后画布重新测量；图谱稀疏链条扩大但不
  触碰详情栏。桌面、820px 与 420px 几何检查均无页面级横向溢出。
- 颜色与状态：浅色保持暖纸、炭黑、酒红与旧金，深色使用同一语义映射；时间和
  图谱的选中、关系、焦点与主操作没有重新引入亮蓝或模块私有主色。
- 图像与资产：本轮没有缺失的内容图像；现有本地图标与字体继续加载，未使用占位
  图、CSS 绘图或网络素材替代参考资产。
- 文案与内容：保留真实 16 篇笔记、3 个关系节点与 2 条显式关系；没有为了接近
  参考图密度而生成虚构连线。筛选、统计、详情和连续阅读文案保持原语义。

### 交互与工程验收

- 浏览器实测时间页 Space 选择、Escape 清理、网址焦点恢复和详情开合；图谱实测
  点击与 Space 选择、Escape 清理、窄屏详情、浅/深色。最终浏览器错误和警告均为 0。
- 最终全量 ERT 178/178 通过；本轮新增后图谱/时间专项 25/25 通过；GNU Emacs
  31.1 warning-as-error 字节编译退出码 0，`symbol-file` 指向当前工作区源码。
- 最终真实全量导出 16/16，生成 20 个 HTML 与 16 个文章页。第二次完整导出前后
  16 个 Org 文件和 `org-roam.db` 共 17 个 SHA-256 指纹变化为 0。第一次复核期间
  `vibe-coding.org` 被外部进程更新，未回滚或覆盖；稳定后重新导出并得到零变化证明。
- `git diff --check` 通过；保留既有脏工作区，未提交、推送、发布或切换稳定版本。

本轮来源比较、浅/深色、动态详情、稀疏图谱、窄屏布局、核心交互和工程回归均通过，
没有未解决的 P0–P2 问题。参考图与实现的关系数量差异属于真实数据约束，不是视觉遗漏。

final result: passed

## Round 15 时间页沉浸式阅读轨迹（2026-09-04）

### 视觉来源与比较证据

- 视觉来源：`C:\Users\luoyu\Downloads\ChatGPT Image Sep 3, 2026, 10_01_56 PM.png`，
  1667×944 像素，时间轴选中 Ontology 笔记状态。
- 实现截图：`test/qa/timeline-immersive-1668x944.png`，浏览器视口
  1668×944、1× 密度；捕获结果为 1658×938，并规范化为
  `timeline-immersive-1668x944-normalized.png` 的 1667×944。
- 同画布比较：`test/qa/timeline-immersive-comparison.png`。左侧为来源，右侧为
  实现；两侧均展示时间轴、选中笔记、更新区间和显式关系状态。
- 响应式证据：`timeline-immersive-1280x720.png`、
  `timeline-immersive-820x944.png`、`timeline-immersive-390x844-selected.png`
  与 `timeline-immersive-320x844.png`。
- 移动端焦点截图已单独检查标题、摘要、元数据、关系、连续阅读和主操作，重要
  文字可直接辨认，因此无需再截取更小的局部区域。

### 比较历史与修复

- Pass 1（P1）：原三栏布局让节点与详情跨越整个页面，筛选后重新缩放时间范围；
  改为全宽固定时间域、紧凑范围栏和节点旁焦点卡，筛选仅淡出不匹配节点。
- Pass 2（P1）：焦点卡初版靠近画布底部，1280×720 下主操作落在首屏之外；
  改为按节点位置和画布边界双向避让，并在聚焦网址或选择节点后做最小滚动。
- Pass 2（P2）：桌面筛选按钮误显示且焦点卡与选中标题重叠；补齐控制类名，并
  将焦点卡与节点保留 80px 间距。最终 1668×944 的两个主操作均完整可见。
- Pass 3（P1）：移动端主题标签横向截断且日期重复；改为可聚焦的底部筛选面板，
  时间流按月份和日期分组，同一时刻只保留一份内联详情。
- Pass 3（P2）：SVG 节点的程序化焦点能力在当前浏览器实现中不稳定；方向键改由
  页面级选择状态驱动，左右遍历可见笔记、上下遍历同日笔记，仍保留节点 Tab 路径。
- Pass 4（P1/P2）：代码审查发现键盘选择、DOM 焦点与历史记录可能脱节，且更新时间
  隔按精确时刻四舍五入会跨日多算一天。方向键现在同步选择与焦点并写入明确历史，
  日期间隔按日历日期计算；浏览器后退可恢复原选中笔记。
- Pass 4（P2）：选中后曾把没有显式链接的时间邻居一并降噪；现在前后各一篇保持
  清晰。移动时间页把全站顶栏改为随文档滚动，仅保留筛选摘要粘性，避免双层固定。
- Pass 5（P1）：底部孤立笔记曾忽略当前筛选，可能选中已淡出的节点；现在列表和
  数量都从可见集合派生，筛选后选择始终对应时间轴中的可见节点。

### 最终设计检查

- 字体与排版：沿用本地 Noto Serif CJK SC、Noto Sans CJK 和 Victor Mono；
  焦点卡标题、正文和微型元数据具有明确层级，长标题正常换行。
- 布局与节奏：筛选、时间轴、详情形成单一路径；桌面焦点卡不遮挡当前节点，移动
  详情紧邻选择，390px 和 320px 均无横向溢出。
- 色彩与令牌：继续使用暖白纸张、炭黑书架、酒红操作和金色时间关系；非关联节点
  降噪但仍可辨认，减少了原实现的等权拥挤。
- 图像与图标：本页没有新增位图或装饰资产，继续使用既有本地 Phosphor 图标，
  没有占位图、在线资源或手绘替代图标。
- 文案与状态：创建到更新使用自然语言区间；出链、入链和双向关系保持事实方向；
  筛选清除选择时有明确状态提示。

### 交互证据

- 默认状态不绘制关系弧；选中关系笔记后仅绘制 1 条相关显式关系，并显示 1 个
  桌面焦点卡或 1 个移动详情。
- Ontology 筛选保留仍匹配的选中笔记；切换至 SQL 后清除焦点并显示“筛选后已
  清除原选择”。筛选前后 Ontology 节点的时间坐标保持不变。
- 上一篇、下一篇、左右方向键和同日上下方向键均更新 `focus` 参数；搜索继续使用
  当前历史项，筛选和明确选择进入浏览历史。
- 最终键盘复核中，方向键切换后焦点环、`aria-pressed` 与 `focus` 同步落在新节点；
  浏览器后退恢复原节点。移动端同样保持唯一详情和选中按钮焦点。
- 1668×944、1280×720、820×944、390×844、320×844 均完成真实浏览器检查；
  页面运行日志为空，关键视口的横向溢出为 0。

### 工程验收

- GNU Emacs 30.2 全量 ERT 163/163 通过；`byte-compile-error-on-warn` 开启时
  `org-museum.el` 字节编译退出码为 0。
- 当前工作区源码完成真实全量导出：16/16 篇文章成功，首页、时间页、图谱和
  关联阅读页同步收尾；`symbol-file` 指向当前工作区 `org-museum.el`。
- 导出后 20 个 HTML 与 16 个文章页均存在；全部本地 `src` / `href` 引用可解析，
  缺失引用为 0，所有导出脚本语法通过，可加载远程资源为 0。
- HTTP 重新加载后仍显示 16 个节点、1 个选中节点、版本化时间运行时，页面日志
  为空且横向溢出为 0。自动化浏览器按安全策略拒绝 `file:///`，未尝试绕过；
  本地相对引用、版本查询参数和无网络资源检查构成离线静态证据。
- 导出前后 16 个 Org 文件及 `org-roam.db` 的 SHA-256 指纹一致；未提交、推送、
  发布或切换稳定版本。

本轮没有未解决的 P0、P1 或 P2 视觉与交互问题。

final result: passed

## Round 16 时间页交互连续性（2026-09-06）

### 已完成实现

- 选择、关系线、更新时间轨迹与详情改由同一帧协调更新；重复选择不重建详情。
- 桌面焦点卡保留外壳，仅在超出安全视口时做最小滚动；点击非节点时间轴区域、
  Escape 或返回按钮都会清理详情、关系线、更新时间和旧高亮。
- 上一篇、下一篇及方向键按当前可见集合实时计算，筛选后不会沿用旧列表；桌面
  键盘行为以实际获得焦点的节点为准。
- 移动详情复用同一面板并移动到当前节点下方；筛选面板打开时固定背景、约束焦点，
  关闭时恢复原滚动位置和触发按钮。筛选期间写入历史的仍是背景真实滚动锚点。
- 历史项保存滚动位置；前进/后退恢复筛选、选择和无选择状态的滚动锚点。仅宽度或
  响应式断点变化才重建时间轴，移动浏览器的纯高度变化不再打断阅读位置。
- 桌面筛选标签保持单行且不压缩文字；移动详情主操作达到 44px；新增内容切换和
  遮罩均尊重减少动态效果设置。

### 工程证据

- GNU Emacs 30.2 全量 ERT 166/166 通过，其中时间页专项 9/9；字节编译零警告。
- 最终真实全量导出 16/16 成功，`symbol-file` 指向当前工作区 `org-museum.el`。
- 20 个 HTML 的本地引用缺失为 0，10 个导出脚本语法失败为 0，远程资源引用为 0。
- 导出前后 Org 文件与 `org-roam.db` 的 SHA-256 一致；未提交、推送或发布。

### 待完成浏览器证据

- 本轮内置浏览器与桌面可视化控制均因应用侧受信任运行进程连续退出而无法连接，
  因此没有把上一轮截图冒充为当前运行时证据，也没有宣称 HTTP 交互已重新通过。
- 待在真实浏览器复核：桌面可见焦点卡选择时滚动量为 0；移动选择后标题与详情顶部
  同时可见；筛选面板无条件变化时开关前后滚动位置一致；前进/后退、断点切换、
  Escape、触控和键盘结果一致；1668×944、1280×720、820px、390×844、320px
  无横向溢出，并补充与来源图的同视口比较。

当前工程回归通过；浏览器连续性验收尚未完成，因此本轮不能判定 P0–P2 已清零。

final result: pending browser verification

## Round 17 图谱阅读工作台（2026-09-09）

### 已完成实现

- 桌面图谱重组为控制栏、稳定关系画布和持久阅读面板；缩放、适配、居中与布局控制
  使用本地 Phosphor 图标，关系图例、缩略导航和底部连续阅读操作均已接入。
- 主画布默认仅放置存在真实显式关系的笔记；14 篇孤立笔记收入按主题分组的“待连接
  笔记”折叠区，并可临时显示为独立候选带，不暗示不存在的关系。
- 图谱边保留方向；同类型互链合并为双向边，异类型互链保留两条错开有向边。重复
  `MUSEUM_RELATION` 标注采用首条有效值，无对应显式出链的标注进入健康诊断。
- 单击或 Space 选择，双击或 Enter 打开；悬停只显示轻提示。Escape、关闭按钮和
  画布空白会同步清理面板、关系高亮、提示和旧轮廓。
- `q`、`category`、`focus` 与浏览历史同步；筛选保留稳定布局，不重新启动力导向。
  阅读面板提供上一篇、下一篇、打开笔记、关联阅读和时间线入口。

### 交互与布局证据

- HTTP 1280×720 实测：选中关系节点后页面滚动量为 0，仅 1 条真实关系高亮；
  Escape 后面板、提示、按压态和关系高亮全部清除，焦点返回图谱画布。
- 分类筛选、浏览器后退、上一篇/下一篇均恢复对应选择、URL 和关系状态；非法分类
  或焦点参数会清理并回到默认视图。
- 布局切换后节点位置停止漂移；孤立候选可选择和打开。选择后的关联阅读、时间线与
  文章链接均传播当前主题。
- 筛选后的非相关路径与关系标签计算不透明度均为 `0.08`；页面横向溢出为 0，
  浏览器运行错误为 0。
- 821–1199px、≤820px 与 ≤360px 的响应式规则、44px 触控目标和自然文档流已完成
  静态检查；本轮浏览器只提供 1280×720 固定视口，无法生成当前实现截图或切换到
  1668×944、820px、390×844、320px，因此未把旧截图当作当前视觉证据。

### 工程验收

- GNU Emacs 30.2 全量 ERT 171/171 通过；开启 `byte-compile-error-on-warn` 时字节
  编译零警告。两轮独立代码审查发现的增量索引、异类互链、筛选恢复、降噪层叠和
  焦点清理问题均已修正并回归。
- 当前工作区源码完成真实全量导出：16/16 篇文章成功，首页、图谱、关联阅读与
  时间页同步生成；`symbol-file` 指向当前工作区 `org-museum.el`，缓存 schema 为 5。
- 导出后共 20 个 HTML、16 个文章页；10 个本地脚本语法通过，本地资源缺失为 0，
  可执行远程资源引用为 0。
- 导出前后 16 个 Org 文件与 `org-roam.db` 的 SHA-256 一致；未提交、推送、发布或
  切换稳定版本。
- 自动化浏览器按安全策略拒绝 `file:///`，未尝试绕过；本地相对引用、主题查询参数、
  资源完整性和无网络依赖构成离线静态证据。

当前工程回归与 HTTP 核心交互通过；来源图同视口比较、小屏真实视觉检查和真实
`file:///` 浏览器验收受当前工具能力限制，故本轮不宣称 P0–P2 已全部清零。

final result: pending visual and file verification

## Round 18 图谱工作台连续阅读与 Triage 收尾（2026-09-10）

### 问题、原因、优先级与修复

- P1｜真实关系被大面积空白稀释：站点目前只有 1 条显式关系，原力导向布局仍按
  常规网络分散节点。改为稀疏关系预计算路径；桌面横向展开，移动端纵向堆叠，
  首屏完成后停止漂移，仅在断点或容器尺寸变化时重新定位。
- P1｜全站导航与图谱控制重复：内层左栏重复承载标题、筛选和导航，压缩了关系
  画布。改为单行工作台命令栏，全站书架继续负责跨页面导航，页面只保留关系阅读、
  待连接整理、范围和画布控制。
- P1｜孤立笔记混入关系图会暗示不存在的关系：14 篇无链接笔记原先与真实网络
  同层展示。新增独立 Triage 模式，按主题组织候选，并显示状态、更新时间、详情和
  Wiki 链接操作；选择孤立笔记不会压暗真实关系网络。
- P1｜移动端详情与选择对象距离过远：阅读面板固定在工作区尾部，长候选列表中
  选中后详情不可见。现在复用同一面板并移动到当前候选行之后；关闭、浏览器后退和
  断点变化都会恢复正确位置与选择状态。
- P2｜节点点击偶尔被拖动手势吞掉：拖动和点击共用同一目标且缺少位移阈值。
  D3 拖动增加 4px 点击距离，单击选择、双击或 Enter 打开文章的语义保持一致。
- P2｜移动端关系文字与节点标题碰撞：两节点垂直排列后边标签仍沿用桌面中点位置。
  小屏将关系标签横向错开，并保持节点标题、关系类型和方向箭头可辨认。

### 同视口设计比较

- 来源/旧实现与最终实现的组合图：
  `test/qa/graph-workbench-linear-before-after.png`。旧实现存在重复控制栏、真实关系
  聚集在狭小中央区域、阅读面板过浅；最终实现将操作压缩到顶部，真实关系成为主
  视觉路径，并让持久阅读面板与选择对象保持同一阅读上下文。
- 桌面最终截图：`graph-workbench-linear-1668x944.png` 与
  `graph-workbench-linear-triage-1668x944.png`。
- 响应式截图：`graph-workbench-linear-1280x720.png`、
  `graph-workbench-linear-820x944.png`、`graph-workbench-linear-390x844.png`、
  `graph-workbench-linear-390x844-triage-detail.png` 与
  `graph-workbench-linear-320x844.png`。
- 1668×944、1280×720、820×944、390×844、320×844 均完成真实浏览器检查；
  关系模式、Triage、候选详情、关闭与历史恢复均无页面级横向滚动，运行日志为空。

### 交互与信息层级验收

- 默认关系模式只显示 2 个真实关联节点和 1 条有向边；选中时仅对应关系强化，
  阅读面板显示摘要、事实、关系与连续阅读操作，非关联内容保持低对比上下文。
- `view=relations|triage`、`q`、`category`、`focus` 可收藏并随前进/后退恢复；非法
  参数回到默认关系视图，孤立笔记焦点自动进入 Triage，不产生空白页面。
- Triage 展示 14 篇待连接笔记、7 个主题组；标题使用可读墨色，移动端详情紧邻
  当前候选，关闭后面板回到工作区并清除旧焦点。
- 缩略导航在节点数不足 8 时隐藏，只有一种关系类型时收起冗余图例；选中使用
  酒红/金色体系，蓝色仅用于键盘可见焦点，延续全站视觉语义。

### 工程验收

- GNU Emacs 30.2 全量 ERT 178/178 通过；新增图谱专项覆盖稀疏布局、点击/拖动、
  工作台模式、孤立焦点、移动布局和邻近详情。开启 warning-as-error 后字节编译
  成功且未产生仓库内 `.elc`。
- 当前工作区源码完成真实全量导出：16/16 篇文章成功，首页、图谱、关联阅读与
  时间页同步生成；`symbol-file` 指向当前工作区 `org-museum.el`。
- 导出结果共 20 个 HTML、16 个文章页、699 个本地引用，缺失引用为 0；10 个
  本地脚本语法失败为 0，可执行远程资源引用为 0。
- 发布隐私扫描覆盖 54 个候选文件，并继续识别既有内容中的 10 项本地路径；门禁
  会阻止发布，本轮没有绕过或发布。16 个 Org 文件与 `org-roam.db` 在 Git 中保持
  无改动，未提交、推送或切换稳定版本。

本轮同视口比较、核心交互、响应式与工程回归均通过，未发现未解决的 P0–P2 问题。

final result: passed

## Round 19 暖纸博物馆视觉统一与时间/图谱检查器（2026-09-10）

### 视觉来源与实现范围

- 配色、质感与层级参考三张用户提供图片：
  `f816e8d8-058e-4795-8884-e58dad99584c.png`、
  `ChatGPT Image Sep 3, 2026, 10_14_22 PM.png` 与
  `ChatGPT Image Sep 3, 2026, 10_01_56 PM.png`。
- 共享语义层现在统一浅色暖纸、炭黑导航外壳、酒红主操作与旧金辅助强调；深色主题
  使用同一语义结构。代码高亮和主题分类继续使用各自独立令牌，不再承担按钮、选择
  或关系焦点状态。
- 默认主题改为浅色，已保存的深色选择、网址主题参数、跨页传播和离线兼容路径保持
  原行为。关系色集中为中性默认边、低饱和类型色以及酒红/旧金选中路径。
- 时间详情从画布浮层改为响应式阅读检查器：1200px 以上为 300px 侧栏，821–1199px
  位于画布下方，820px 以下继续使用按月分组列表中的邻近详情。
- 图谱普通节点改为中性墨色，分类色仅保留为小圆点提示；选中节点使用酒红描边与旧金
  微光。关系阅读、待连接整理、缩放、布局、网址状态和离线导航语义未改动。

### 已完成的静态与自动检查

- 主题令牌、浅/深色正文和操作对比度、焦点与边界对比度、默认主题、已保存深色、
  稀疏/密集日期分配及硬编码界面色守卫通过；最低自动测得对比度为 `4.61:1`。
- `org-museum-theme.js` 与主题测试脚本语法通过；所有 `--museum-*` 引用均有定义。
- 样式表包含 16 个本地资源引用，缺失为 0；当前资源目录包含 13 个本地图标和
  4 个本地字体文件。差异格式检查通过。
- 当前 16 个 Org 文件与 `org-roam.db` 已记录 SHA-256 指纹，Git 状态中它们均无
  改动；本轮未提交、推送、发布或修改内容数据。

### 阻塞的运行时与视觉验收

- 本机当前没有可用 Emacs 安装；全盘只发现回收站中的 `emacs.exe`。因此本轮无法
  运行零警告字节编译、全量 ERT、当前源码真实全量导出、`symbol-file` 运行时身份
  或导出前后源文件指纹复核。上一轮的 178/178 和导出结果没有被当作本轮证据。
- Codex 应用内浏览器的受信任进程因 Windows 沙箱应用读取 ACL 失败而退出，无法
  打开当前实现、切换视口或捕获截图。因此没有使用旧截图代替本轮实现，也没有宣称
  1668×944、1280×720、820×944、390×844、320×844 的同视口比较、交互路径、
  横向溢出、焦点或控制台检查已经通过。
- 待环境恢复后必须补跑：全量 ERT、warning-as-error 字节编译、真实 16/16 导出及
  前后哈希；随后在应用内浏览器完成浅/深色首页、文章、关联阅读、时间和图谱的全部
  目标视口与交互检查，并把三张来源图和当前截图放入同一比较画布复核 P0–P2。

当前源码层实现与可运行的自动检查已完成；真实运行时和同视口 Design QA 尚不可用。

final result: blocked

## Round 21 暖纸视觉统一与时间/图谱真实浏览器收尾（2026-09-11）

### 同视口来源比较与视觉修正

- 使用用户批准的 Playwright CLI 打开当前真实导出，并把来源图与当前实现放入同一
  比较画布：`output/playwright/org-museum-round21/timeline-comparison-final.png`、
  `output/playwright/org-museum-round21/graph-comparison-final.png`。来源与实现均按
  `1668×944`、CSS 1×、相同选中态截图后等比并排比较，没有以旧实现截图替代。
- 时间页修正重复月份刻度，月份只保留一次；提高月份、选中节点和真实关系邻居的
  文字层级。固定 300px 阅读检查器继续位于画布右侧，不遮挡时间节点和关系弧线。
- 图谱在当前 3 个真实关系节点、2 条显式关系的数据规模下扩大稀疏路径跨度、节点、
  标签与 44px 以上点击目标；无障碍节点的点击中心不再被 SVG 画布拦截。
- 去除点击后出现的矩形 SVG 默认焦点框，保留节点上的旧金键盘焦点与酒红选中描边；
  浅色不再出现独立亮蓝主视觉。移动端节点标题改为左右两条文字轨道，关系类型留在
  连线中段，节点标题、关系文字与方向箭头不再重叠。
- 浅色保持暖纸、炭黑、酒红与旧金；深色使用相同语义映射。两套主题的内容面、边界、
  主操作、标签与状态在时间和图谱之间保持一致，没有新增网络素材或装饰资产。

### 真实浏览器与响应式证据

- 时间页：`timeline-light-selected-final-1668x944.png`、
  `timeline-light-selected-1280x720.png`、`timeline-light-selected-820x944.png`、
  `timeline-light-selected-390x844.png`、`timeline-light-selected-320x844.png` 与
  `timeline-dark-selected-1668x944.png`。
- 图谱：`graph-light-selected-final-1668x944.png`、
  `graph-light-selected-1280x720.png`、`graph-light-selected-final-820x944.png`、
  `graph-light-selected-final-390x844.png`、`graph-light-selected-final-320x844.png`、
  `graph-dark-selected-final-1668x944.png` 与
  `graph-light-triage-detail-final-390x844.png`。
- 组合断点检查见 `tablet-pair-final-820x944.png` 与移动端单页截图。所有目标视口的
  页面级横向溢出为 0；1200px 以上详情稳定在侧栏，821–1199px 落到画布下方，
  820px 及以下时间页使用按月列表，图谱详情与当前 Triage 候选相邻。
- 深色时间与图谱在 `1668×944` 实测，无表面断层、低对比正文或主题色漂移；本地字体、
  图标与纸面层级均正确加载。

### 交互与工程验收

- 实测图谱点击选择、Space 选择、Escape 清理、前进/后退恢复、关系/Triage 切换、
  125% 缩放、主题切换和移动候选详情；Triage URL 同步 `view` 与 `focus`，详情面板
  紧邻选中候选。时间页 Space 选择和 Escape 清理同步 URL、节点状态与检查器。
- 浏览器控制台错误 0、警告 0；本地 HTTP 预览加载当前 `timeline.html` 与
  `graph.html`，不是静态截图替代品。
- GNU Emacs 31.1 最终全量 ERT 178/178 通过；warning-as-error 字节编译退出码为 0，
  仓库内 `.elc` 为 0。最终真实导出为 16/16 页面、20 个 HTML、16 个文章页，
  可执行远程资源引用为 0；`symbol-file` 指向当前工作区 `org-museum.el`。
- 最终导出前后 16 个 Org 文件与 `org-roam.db` 共 17 个 SHA-256 指纹变化为 0。
  保留既有脏工作区；未提交、推送、发布或修改笔记与数据库。

本轮来源比较、浅/深色、全部目标视口、核心交互、控制台与工程回归均已通过，
未发现未解决的 P0–P2 问题。

final result: passed

## Round 20 Emacs 31.1 真实导出恢复与视觉验收复核（2026-09-11）

### 已恢复的工程证据

- 使用用户确认的 `C:\\v\\Emacs\\bin\\emacs.exe`（GNU Emacs 31.1）验证；
  `symbol-file` 指向当前工作区 `org-museum.el`。
- 首轮 warning-as-error 字节编译发现增量索引提前返回缺少对应 `cl-block`；补齐显式
  block 后重新验证，严格字节编译退出码为 0，且未在仓库内留下 `.elc`。
- 全量 ERT 178/178 通过，时间页、图谱工作台、主题运行时、键盘状态、响应式结构、
  离线资源和导出契约均包含在回归范围内。
- 当前工作区源码完成真实全量导出：16/16 篇文章成功；首页、时间、图谱和关联阅读
  同步生成。导出结果共 20 个 HTML、16 个文章页、699 个本地引用，缺失引用为 0；
  10 个导出脚本语法失败为 0，远程可执行脚本或样式依赖为 0。
- 同一导出进程前后比较 16 个 Org 文件与 `org-roam.db` 共 17 个 SHA-256 指纹，
  变化为 0；Git 状态中这些内容文件仍无改动。未提交、推送或发布。

### 当前视觉验收状态

- 视觉真值仍为 Round 19 记录的三张用户参考图；本轮需要比较的实现是真实导出后的
  `timeline.html` 与 `graph.html`，并覆盖浅/深色及所有约定视口。
- Codex 应用内浏览器连接进程仍因 Windows 沙箱 `apply deny-read ACLs` 错误退出；
  按 Product Design 浏览器规则回落到 Chrome 后，同一受信任进程仍在初始化阶段退出。
- 因无法捕获当前实现，没有生成新的同视口实现截图或组合比较图；旧 Round 18 截图
  未被当作本轮配色、时间检查器和图谱节点状态的证据。页面溢出、焦点、交互路径与
  控制台状态因此仍不能判定通过。

当前工程实现与真实导出已通过；Design QA 仍被浏览器沙箱阻塞。

final result: blocked

## Final status resolution（2026-09-11）

Round 20 的浏览器阻塞已由用户批准的 Playwright 真实页面验收解除；最终视觉、交互、
响应式、控制台、全量 ERT、严格字节编译、真实导出与源文件指纹证据见 Round 21。
Round 21 结论覆盖并取代 Round 19–20 的历史 blocked 状态。

final result: passed

## Final status resolution（2026-09-13）

Round 22 已完成时间轴密度、动态画布同步与稀疏图谱视觉收口；当前结论以 Round 22
的真实导出、桌面与窄屏、浅色与深色、键盘交互、控制台、ERT 及严格字节编译证据为准。
此前各轮的 pending 或 blocked 记录仅保留为历史过程，不再代表当前状态。

final result: passed

## Final status resolution（2026-09-13，Round 23）

当前最终结论由 Round 23 的 186/186 ERT、16/16 真实导出、五档响应式实页矩阵、
移动图谱标签边界、关联阅读双侧进度、时间轴首屏、策展会话安全和零公共泄漏证据共同支持。
此前轮次仅作为历史过程保留。

final result: passed
