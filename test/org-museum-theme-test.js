// Run with node test/org-museum-theme-test.js. No browser or network required.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.join(__dirname, '..');
const css = fs.readFileSync(path.join(root, 'resources/org-museum.css'), 'utf8');
const shared = css.slice(css.indexOf('/* Shared interface tokens'));
const blocks = [...shared.matchAll(/:root(?:\[data-theme="light"\])?\s*\{([^}]+)\}/g)].slice(0,2);
const parse = text => Object.fromEntries([...text.matchAll(/(--[\w-]+):\s*([^;]+);/g)].map(m => [m[1],m[2].trim()]));
const resolve = (map,key) => {let v=map[key]; for(let i=0;i<12 && /^var\(/.test(v);i++)v=map[v.slice(4,-1)]; assert(v, key);return v;};
const luminance = hex => {const c=hex.slice(1).match(/../g).map(v=>parseInt(v,16)/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4);return c[0]*.2126+c[1]*.7152+c[2]*.0722;};
const ratio=(a,b)=>{const x=luminance(a),y=luminance(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05);};
let minimum=Infinity;
for(const [i,block] of blocks.entries()) {
 const map={...parse(blocks[0][1]),...parse(block[1])};
 for(const surface of ['bg','surface','surface-raised','hover'])for(const text of ['text','text-muted','text-subtle','accent','secondary-text','success','warning','error']){
  const r=ratio(resolve(map,'--museum-'+text),resolve(map,'--museum-'+surface));minimum=Math.min(minimum,r);assert(r>=4.5,`${i} ${text}/${surface}: ${r}`);
 }
 for(const surface of ['bg','surface','surface-raised']){
  assert(ratio(resolve(map,'--museum-border'),resolve(map,'--museum-'+surface))>=3);
  assert(ratio(resolve(map,'--museum-control-border'),resolve(map,'--museum-'+surface))>=3);
 }
 for(const surface of ['bg','surface','surface-raised','hover'])assert(ratio(resolve(map,'--museum-focus-ring'),resolve(map,'--museum-'+surface))>=3);
 assert(ratio(resolve(map,'--museum-on-accent'),resolve(map,'--museum-accent'))>=4.5);
 assert.equal(resolve(map,'--museum-paper'),resolve(map,'--museum-surface'));
for(const token of ['surface-muted','selected-surface','success-surface','warning-surface','error-surface','code-surface','code-border','text-subtle','secondary','secondary-text','disabled','node-fill','relation-default','relation-primary','relation-selected','relation-1','relation-2','relation-3','relation-4','radius-control','radius-panel'])assert(map['--museum-'+token],`Missing ${token}`);
 assert.notEqual(resolve(map,'--museum-relation-primary'),resolve(map,'--museum-accent'));
 for(const token of ['type-display','type-h1','type-h2','type-h3','type-h4','type-h5','type-h6','type-title','type-heading','type-subheading','type-body','type-ui','type-meta','type-caption','weight-regular','weight-medium','weight-semibold','weight-bold','leading-body','leading-ui'])assert(map['--museum-'+token],`Missing ${token}`);
}
const darkMap=parse(blocks[0][1]);
assert.notEqual(resolve(darkMap,'--museum-node-fill'),resolve(darkMap,'--museum-text'),'Dark graph nodes must use a tuned material colour rather than inverted body text');
const defined=new Set([...css.matchAll(/(--[\w-]+)\s*:/g)].map(m=>m[1]));
for(const m of css.matchAll(/var\((--museum-[\w-]+)\)/g))assert(defined.has(m[1]),'Undefined '+m[1]);
assert(!/url\(["']?icons\//.test(css),'External SVG masks break under file:// unique origins');
for(const icon of ['book-open','clock','file-text','graph','magnifying-glass','moon','sun','plus','minus','corners-out','crosshair','rows']) {
 assert.match(css,new RegExp(`--museum-icon-${icon}:\\s*url\\("data:image/svg\\+xml;base64,`),`Missing inline icon: ${icon}`);
}
const interfaceCss=shared.slice(0,shared.indexOf('@media print'));
const declarationsRemoved=interfaceCss.replace(/:root(?:\[data-theme="light"\])?\s*\{[^}]+\}/g,'');
assert(!/(?:#[0-9a-f]{3,8}|(?:rgb|hsl)a?\()/i.test(declarationsRemoved),'Hard-coded interface colour outside semantic tokens');
const round24=css.slice(css.indexOf('ROUND 24 — THEME TYPOGRAPHY AND SURFACE BALANCE'));
assert(round24.length>0,'Missing Round 24 theme balance layer');
for(const selector of ['museum-topbar-link', 'museum-index-entry h3', 'resume-copy small', 'museum-entry-meta', 'timeline-preview-meta dt', 'graph-commandbar .graph-counts dt', 'graph-page .graph-isolated-grid article > small']) {
 assert(round24.includes(selector),`Missing readable type override: ${selector}`);
}
assert.match(round24,/\.article-container table\s*\{[^}]*font-size:\s*var\(--museum-type-ui\)[^}]*line-height:\s*1\.6/s);
assert.match(round24,/:where\(input, select, textarea\)\s*\{[^}]*border-color:\s*var\(--museum-control-border\)[^}]*background:\s*var\(--museum-surface-raised\)/s);
assert.match(round24,/\.related-index\s*\{[^}]*align-content:\s*start/s);
assert.match(css,/\.related-index-arrow\s*\{[^}]*color:\s*var\(--museum-secondary-text\)/s);
for(const selector of ['museum-filter-summary','museum-status-filters b','museum-status-badge','timeline-node-date','museum-article-toc-trigger','data-toc-count','data-toc-close','graph-selection-prompt','graph-tooltip span']) {
 assert(css.includes(selector),`Missing readable caption override: ${selector}`);
}
assert.match(css,/\.article-container :where\(figcaption, \.org-src-name, \.example-label\)[^}]*font-size:\s*var\(--museum-type-caption\)/s);
assert.match(css,/\.article-container pre code:not\(\.org-museum-code\)\s*\{[^}]*font-size:\s*inherit/s);
assert.match(css,/\.museum-search-line\s*\{[^}]*border:\s*1px solid var\(--museum-control-border\)/s);
assert.match(css,/\.graph-page \.graph-view-controls button\s*\{[^}]*border:\s*1px solid var\(--museum-control-border\)/s);
assert.match(css,/\.graph-mode-tabs button\.is-active\s*\{[^}]*border-color:\s*var\(--museum-control-border\)/s);
assert.match(css,/\.museum-status-filters button\.is-active,[^}]*background:\s*var\(--museum-selected-surface\)/s);
assert.match(css,/:is\(\.article-container, \.museum-md\) blockquote\s*\{[^}]*border-inline-start:\s*3px solid var\(--museum-accent\)[^}]*border-radius:\s*var\(--museum-radius-control\)[^}]*background:\s*var\(--museum-surface-muted\)/s);
assert.match(css,/\.museum-table-scroll\s*\{[^}]*border:\s*1px solid var\(--museum-border-soft\)[^}]*border-radius:\s*var\(--museum-radius-control\)/s);
assert.match(css,/(?:pre\.src|pre\.example|pre\.org-museum-code-block)\s*\{[^}]*border:\s*1px solid var\(--museum-code-border\)[^}]*border-radius:\s*var\(--museum-radius-control\)[^}]*background:\s*var\(--museum-code-surface\)/s);
assert.match(css,/:is\(\.article-container, \.museum-md\) img\s*\{[^}]*border-radius:\s*var\(--museum-radius-control\)/s);
assert.match(css,/\.article-container a:hover,[\s\S]*?text-decoration-thickness:\s*2px/s);
assert.match(css,/\.museum-table-scroll:focus-visible\s*\{[^}]*outline:\s*2px solid var\(--museum-focus-ring\)/s);
assert.match(css,/\.reading-restore-notice\s*\{[^}]*border-radius:\s*var\(--museum-radius-panel\)/s);
assert.match(css,/\.museum-curation-form select,[\s\S]*?\.museum-curation-form input\s*\{[^}]*border:\s*1px solid var\(--museum-control-border\)/s);
assert.match(css,/\.museum-curation-form button:not\(\.is-primary\):hover[^}]*background:\s*var\(--museum-selected-surface\)/s);
assert.match(css,/\.article-container h2\s*\{[^}]*font-size:\s*var\(--museum-type-h2\)[^}]*font-weight:\s*var\(--museum-weight-semibold\)/s);
assert.match(css,/\.article-container h3\s*\{[^}]*font-size:\s*var\(--museum-type-h3\)[^}]*font-weight:\s*var\(--museum-weight-semibold\)/s);
for(const level of [4,5,6]) {
 assert.match(css,new RegExp(`\\.article-container h${level}\\s*\\{[^}]*font-size:\\s*var\\(--museum-type-h${level}\\)[^}]*font-weight:\\s*var\\(--museum-weight-semibold\\)`,'s'));
}
assert.match(css,/\.timeline-hero h1\s*\{[^}]*font:[^;}]*var\(--museum-weight-bold\)[^;}]*var\(--museum-type-display\)[^;}]*var\(--museum-serif-font\)/s);
assert.match(css,/\.museum-index-entry h3\s*\{[^}]*font-size:\s*var\(--museum-type-h5\)/s);
assert.match(css,/\.museum-entry-tags\s*\{[^}]*margin-left:\s*auto[^}]*justify-content:\s*flex-end/s);
assert.match(css,/\.dashboard-result-tags\s*\{[^}]*margin-left:\s*auto[^}]*justify-content:\s*flex-end/s);
assert(!/\.dashboard-result-tags\s*\{[^}]*justify-content:\s*flex-start/s.test(css),'Index filetag chips must remain right-aligned across all media tiers');
assert.match(blocks[1][1],/--museum-control-border:\s*#[0-9a-f]{6}/i,'Light theme must own its control boundary token');
// Theme runtime: URL priority, default, blocked storage, toggle and cross-tab change.
const themeSource=fs.readFileSync(path.join(root,'resources/org-museum-theme.js'),'utf8');
// Final-cascade regressions: desktop-only home columns, mobile natural height and touch targets.
assert.match(css, /@media screen and \(min-width: 821px\)\s*\{\s*\.museum-home-upper\s*\{[^}]*grid-template-columns:\s*minmax\(0, 1\.15fr\) minmax\(300px, \.85fr\)/s);
const finalMobile = css.slice(css.indexOf('ROUND 23 —'),css.indexOf('ROUND 24 —'));
assert.match(css, /@media screen and \(min-width: 621px\) and \(max-width: 820px\)\s*\{\s*\.graph-page \.graph-isolated-grid\s*\{[^}]*grid-template-columns:\s*repeat\(2, minmax\(0, 1fr\)\)/s);
assert.match(finalMobile, /\.museum-home-upper\s*\{[^}]*grid-template-columns:\s*minmax\(0, 1fr\)/s);
assert.match(finalMobile, /\.graph-page\.graph-triage-mode \.museum-graph-workspace\s*\{[^}]*height:\s*auto[^}]*max-height:\s*none/s);
assert.match(finalMobile, /\.graph-page\.graph-triage-mode \.graph-triage-panel\s*\{[^}]*height:\s*auto[^}]*max-height:\s*none[^}]*overflow:\s*visible/s);
for (const selector of ['.resume-remove', '.reading-restore-notice button', '.related-mobile-segments button', '.timeline-mobile-node']) {
 const escaped=selector.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
 assert.match(finalMobile,new RegExp(escaped+'[^}]*\\{[^}]*min-height:\\s*44px','s'),`Missing 44px mobile target: ${selector}`);
}
assert.match(themeSource, /window\.orgMuseumCuration\.mode\s*===\s*"loopback"/);
assert.match(themeSource, /发送到 Emacs 审核/);
assert.match(themeSource, /差异与最终确认将在 Emacs 中完成/);
assert.match(themeSource, /本地认证会话未就绪/);
function curationFixture(){
 const fields={
  target:{value:'target',appendChild(){},addEventListener(){}},
  type:{value:'相关',addEventListener(){}},
  custom:{value:'',disabled:false,focus(){}}
 };
 const nodes={
  form:{elements:fields,addEventListener(){}}, custom:{hidden:true}, status:{textContent:''},
  submit:{textContent:'',disabled:false}, source:{textContent:''}, guidance:{textContent:''}
 };
 const dialog={innerHTML:'',open:false,setAttribute(){},addEventListener(){},showModal(){this.open=true;},
  querySelector(selector){return {'form':nodes.form,'.museum-curation-custom':nodes.custom,
   '.museum-curation-status':nodes.status,'button[type="submit"]':nodes.submit,
   '.museum-curation-source':nodes.source,'.museum-curation-guidance':nodes.guidance}[selector];}};
 const document={documentElement:{dataset:{},style:{}},body:{appendChild(){}},readyState:'complete',
  querySelector(){return null;},querySelectorAll(){return [];},addEventListener(){},
  createElement(tag){return tag==='dialog'?dialog:{};}};
 const window={addEventListener(){}};
 const context={window,document,localStorage:{getItem(){return null;},setItem(){}},URL,URLSearchParams,
  location:new URL('http://127.0.0.1/index.html')};
 vm.runInNewContext(themeSource,context);
 return {dialog,nodes,window};
}
const protocolCuration=curationFixture();
protocolCuration.window.orgMuseumCuration.openRelation({sourceId:'source',sourceTitle:'Source',targets:[{id:'target',title:'Target'}]});
assert.match(protocolCuration.dialog.innerHTML,/>发送到 Emacs 审核<\/button>/);
assert.match(protocolCuration.nodes.guidance.textContent,/差异与最终确认将在 Emacs 中完成/);
const loopbackCuration=curationFixture();
loopbackCuration.window.orgMuseumCuration.mode='loopback';
loopbackCuration.window.orgMuseumCuration.openRelation({sourceId:'source',sourceTitle:'Source',targets:[{id:'target',title:'Target'}]});
assert.match(loopbackCuration.dialog.innerHTML,/>预览差异<\/button>/);
assert.match(loopbackCuration.nodes.guidance.textContent,/浏览器中生成写入前差异/);
function themeFixture(url,stored,blocked=false,homeHref=null,media=null){
 const listeners={},button={setAttribute(){},querySelector(){return null;},addEventListener(e,f){this[e]=f;}};
 const systemButton={setAttribute(){},addEventListener(e,f){this[e]=f;}};
 const returnLink={href:'',textContent:''};
 const document={documentElement:{dataset:{},style:{}},querySelector(selector){
  if(selector==='.museum-wordmark[href]'&&homeHref)return {getAttribute(){return homeHref;}};
  if(selector==='[data-reading-return]')return returnLink;
  return null;
 },querySelectorAll(selector){return selector==='[data-theme-toggle]'?[button]:selector==='[data-theme-system]'?[systemButton]:[];},readyState:'complete',addEventListener(){}};
 const window={addEventListener(e,f){listeners[e]=f;}};
 if(media) window.matchMedia=()=>media;
 const store={getItem(){if(blocked)throw Error('blocked');return stored;},setItem(k,v){stored=v;}};
 const history={state:null,replaced:'',replaceState(_state,_title,next){this.replaced=String(next);}};
 const context={window,document,localStorage:store,URL,location:new URL(url),history};vm.runInNewContext(themeSource,context);
 return {document,window,button,systemButton,listeners,history,returnLink};
}
// Real URL transitions: nested exports, local files, filtering, and untrusted returns.
for(const rootUrl of ['https://example.test/wiki/','file:///C:/notes/dist/']){
 const home=themeFixture(rootUrl+'index.html?q=DuckDB&category=Sql&tag=duckdb&status=draft&from=2026-09-01&to=2026-09-30&sort=title-asc',null,true,'index.html');
 const article=new URL(home.window.orgMuseumThemeUrl('pages/sql/duckdb.html#section-1'));
 assert.equal(article.searchParams.get('museum-from'),'index.html?q=DuckDB&category=Sql&tag=duckdb&status=draft&from=2026-09-01&to=2026-09-30&sort=title-asc');
 assert.equal(article.hash,'#section-1');
 const reader=themeFixture(article.href,null,true,'../../index.html');
 assert.equal(new URL(reader.returnLink.href).searchParams.get('q'),'DuckDB');
 assert.equal(new URL(reader.returnLink.href).searchParams.get('tag'),'duckdb');
 assert.equal(new URL(reader.returnLink.href).searchParams.get('from'),'2026-09-01');
 assert.equal(new URL(reader.returnLink.href).searchParams.get('sort'),'title-asc');
 assert.equal(reader.returnLink.textContent,'← 返回筛选结果');
 const next=new URL(reader.window.orgMuseumThemeUrl('other.html'));
 assert.equal(next.searchParams.get('museum-from'),article.searchParams.get('museum-from'));
 assert(!new URL(reader.window.orgMuseumThemeUrl('../../graph.html')).searchParams.has('museum-from'));
 for(const from of ['https://evil.test/index.html','../index.html','pages/article.html','javascript:alert(1)']){
  const unsafe=themeFixture(rootUrl+'pages/a.html?museum-from='+encodeURIComponent(from),null,true,'../index.html');
  assert.equal(unsafe.returnLink.href,'');
 }
 const graph=themeFixture(rootUrl+'graph.html?focus=a&view=triage&time=30&relation=supports&dimension=3d&layout=radial&token=secret',null,true,'index.html');
 const graphArticle=new URL(graph.window.orgMuseumThemeUrl('pages/a.html'));
 assert.equal(graphArticle.searchParams.get('museum-from'),'graph.html?focus=a&view=triage&time=30&relation=supports&dimension=3d&layout=radial');
 const graphReader=themeFixture(graphArticle.href,null,true,'../index.html');
 for(const [name,value] of Object.entries({time:'30',relation:'supports',dimension:'3d',layout:'radial'}))assert.equal(new URL(graphReader.returnLink.href).searchParams.get(name),value);
}
for(const [query,stored,expected] of [['',null,'light'],['','dark','dark'],['','light','light'],['?org-museum-theme=light','dark','light'],['?org-museum-theme=invalid','dark','dark']]){
 const f=themeFixture('https://example.test/index.html'+query,stored);assert.equal(f.document.documentElement.dataset.theme,expected);f.button.click();assert.notEqual(f.document.documentElement.dataset.theme,expected);
}
assert.equal(themeFixture('file:///notes/index.html',null,true).document.documentElement.dataset.theme,'light');
const f=themeFixture('https://example.test/index.html',null);f.listeners.storage({key:'org-museum-theme',newValue:'light'});assert.equal(f.document.documentElement.dataset.theme,'light');assert(f.window.orgMuseumThemeUrl('timeline.html').includes('org-museum-theme=light'));
const toggled=themeFixture('https://example.test/index.html?org-museum-theme=dark','dark');toggled.button.click();assert.equal(new URL(toggled.history.replaced).searchParams.get('org-museum-theme'),'light');
assert.equal(f.window.orgMuseumCategoryColor('AI'),f.window.orgMuseumCategoryColor('ail'));
let systemChanged;
const media={matches:true,addEventListener(_event,listener){systemChanged=listener;}};
const system=themeFixture('https://example.test/index.html',null,false,null,media);
assert.equal(system.document.documentElement.dataset.theme,'dark');
assert.equal(system.document.documentElement.dataset.themePreference,'system');
assert(new URL(system.window.orgMuseumThemeUrl('graph.html')).searchParams.get('org-museum-theme')==='system');
media.matches=false; systemChanged(); assert.equal(system.document.documentElement.dataset.theme,'light');
system.button.click(); assert.equal(system.document.documentElement.dataset.themePreference,'dark');
systemChanged(); assert.equal(system.document.documentElement.dataset.theme,'dark','System changes must not override a manual choice');
system.systemButton.click(); assert.equal(system.document.documentElement.dataset.theme,'light');
media.matches=true;systemChanged();assert.equal(system.document.documentElement.dataset.theme,'dark');
// Execute the actual lane allocation against same-day and sparse records.
const source=fs.readFileSync(path.join(root,'org-museum.el'),'utf8');
const begin=source.indexOf('var laneLast=[]'),end=source.indexOf('var groups=layer.append',begin);
const allocation=source.slice(begin,end).replace(/if\(laneLast.length>12\)[\s\S]*$/,'');
for(const [count,spacing,dense] of [[1,0,false],[12,0,false],[13,0,true],[100,0,true],[40,150,false]]){
 const context={pages:Array.from({length:count},(_,id)=>({id,created:id*spacing})),scale:d=>d.getTime()/1000,axisY:300,Map};
 vm.runInNewContext(allocation,context);assert.equal(context.laneLast.length>12,dense);
 const occupied=[...context.nodeLayout.values()];for(let a=0;a<occupied.length;a++)for(let b=a+1;b<occupied.length;b++)if(occupied[a].lane===occupied[b].lane)assert(Math.abs(occupied[a].x-occupied[b].x)>=140);
}
console.log(`PASS: shared tokens, contrast (minimum ${minimum.toFixed(2)}:1), theme runtime, sparse/dense date allocation`);
