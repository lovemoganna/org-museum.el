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

final result: passed
