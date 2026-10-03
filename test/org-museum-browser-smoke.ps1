param(
  [string]$ExportRoot = (Join-Path $PSScriptRoot '..\exports\html'),
  [string]$PlaywrightWrapper = $env:ORG_MUSEUM_PLAYWRIGHT_WRAPPER
)

$ErrorActionPreference = 'Stop'
$gitCommand = Get-Command git -ErrorAction SilentlyContinue
$gitBash = if ($gitCommand) {
  $gitRoot = Split-Path (Split-Path $gitCommand.Source -Parent) -Parent
  Join-Path $gitRoot 'bin\bash.exe'
}
$bash = if ($gitBash -and (Test-Path -LiteralPath $gitBash)) {
  $gitBash
}
else {
  (Get-Command bash -ErrorAction Stop).Source
}
$userProfile = [Environment]::GetFolderPath('UserProfile')
$wrapperPath = if ($PlaywrightWrapper) {
  $PlaywrightWrapper
}
else {
  Join-Path $userProfile '.codex\skills\playwright\scripts\playwright_cli.sh'
}
if (-not (Test-Path -LiteralPath $wrapperPath)) {
  throw "Playwright CLI wrapper not found. Pass -PlaywrightWrapper or set ORG_MUSEUM_PLAYWRIGHT_WRAPPER: $wrapperPath"
}
$wrapper = (Resolve-Path -LiteralPath $wrapperPath).Path -replace '\\', '/'
$session = 'org-museum-smoke'
$opened = $false
$server = $null

function Invoke-MuseumBrowser {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
  & $bash $wrapper "-s=$session" @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Browser smoke command failed: $($Arguments -join ' ')"
  }
}

$root = (Resolve-Path -LiteralPath $ExportRoot).Path
$listener = [System.Net.Sockets.TcpListener]::new(
  [System.Net.IPAddress]::Loopback, 0
)
$listener.Start()
$port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()
$indexUrl = "http://127.0.0.1:$port/index.html"
$graphUrl = "http://127.0.0.1:$port/graph.html"
$timelineUrl = "http://127.0.0.1:$port/timeline.html"

try {
  $server = Start-Process -FilePath python -WindowStyle Hidden -PassThru -ArgumentList @(
    '-m', 'http.server', $port, '--bind', '127.0.0.1', '--directory', "`"$root`""
  )
  $ready = $false
  for ($attempt = 0; $attempt -lt 30 -and -not $ready; $attempt++) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri $indexUrl -TimeoutSec 1
      $ready = $response.StatusCode -eq 200
    }
    catch { Start-Sleep -Milliseconds 200 }
  }
  if (-not $ready) { throw 'Local export server did not become ready' }
  Invoke-MuseumBrowser open $indexUrl
  $opened = $true
  Invoke-MuseumBrowser resize 1440 900
  Invoke-MuseumBrowser eval "() => { const entries=Array.from(document.querySelectorAll('.museum-index-entry')); const columns=3;if(entries.some(function(entry){return getComputedStyle(entry).transform!=='none';})) throw new Error('card transform remains'); for(let start=0;start<entries.length;start+=columns){const row=entries.slice(start,start+columns);if(row.length<2)continue;const titleTops=row.map(function(entry){return entry.querySelector('h3').getBoundingClientRect().top;});const categoryTops=row.map(function(entry){return entry.querySelector('.museum-entry-category').getBoundingClientRect().top;});if(Math.max.apply(null,titleTops)-Math.min.apply(null,titleTops)>1)throw new Error('title row misaligned');if(Math.max.apply(null,categoryTops)-Math.min.apply(null,categoryTops)>1)throw new Error('category row misaligned');} return 'alignment-ok'; }"
  Invoke-MuseumBrowser resize 1024 900
  Invoke-MuseumBrowser eval "() => { const entries=Array.from(document.querySelectorAll('.museum-index-entry'));const columns=3;for(let start=0;start<entries.length;start+=columns){const row=entries.slice(start,start+columns);if(row.length<2)continue;const titleTops=row.map(function(entry){return entry.querySelector('h3').getBoundingClientRect().top;});const categoryTops=row.map(function(entry){return entry.querySelector('.museum-entry-category').getBoundingClientRect().top;});if(Math.max.apply(null,titleTops)-Math.min.apply(null,titleTops)>1)throw new Error('1024 title row misaligned');if(Math.max.apply(null,categoryTops)-Math.min.apply(null,categoryTops)>1)throw new Error('1024 category row misaligned');}return 'alignment-1024-ok'; }"
  Invoke-MuseumBrowser resize 1440 900
  Invoke-MuseumBrowser eval "() => { const input=document.querySelector('#org-museum-global-search'); if(!input) throw new Error('search missing'); input.value=(document.querySelector('.museum-index-entry h3')?.textContent||'').trim().slice(0,4); input.dispatchEvent(new Event('input',{bubbles:true})); if(document.querySelectorAll('.museum-search-result').length<1) throw new Error('search returned no results'); return 'search-ok'; }"
  Invoke-MuseumBrowser eval "() => { let params=new URL(location.href).searchParams;if(!params.get('q'))throw new Error('search URL state missing');const category=document.querySelector('.topic-filter[data-category]');if(!category)throw new Error('category control missing');category.click();params=new URL(location.href).searchParams;if(params.get('category')!==category.dataset.category)throw new Error('category URL state missing');const draft=document.querySelector('[data-status-filter=draft]');if(!draft)throw new Error('draft status control missing');draft.click();params=new URL(location.href).searchParams;if(params.get('status')!=='draft')throw new Error('status URL state missing');return 'index-url-ok'; }"
  Invoke-MuseumBrowser reload
  Invoke-MuseumBrowser eval "() => { const params=new URL(location.href).searchParams;if((document.querySelector('#org-museum-global-search').value||'')!==(params.get('q')||''))throw new Error('index URL state did not restore');const category=document.querySelector('.topic-filter[data-category].is-active');if(!category||category.dataset.category!==params.get('category'))throw new Error('category did not restore');if(params.get('status')==='draft'&&!document.querySelector('[data-status-filter=draft].is-active'))throw new Error('status did not restore');return 'index-reload-ok'; }"
  Invoke-MuseumBrowser go-back
  Invoke-MuseumBrowser eval "() => { const params=new URL(location.href).searchParams;if(params.has('status'))throw new Error('index back did not clear status');if(!params.get('category')||!document.querySelector('.topic-filter[data-category].is-active'))throw new Error('index back lost category');if(!document.querySelector('[data-status-filter=all].is-active'))throw new Error('index back did not restore all status');return 'index-back-ok'; }"
  Invoke-MuseumBrowser go-forward
  Invoke-MuseumBrowser eval "() => { const params=new URL(location.href).searchParams;if(!params.get('q')||!params.get('category')||params.get('status')!=='draft')throw new Error('index forward did not restore combined URL state');if(!document.querySelector('.topic-filter[data-category].is-active')||!document.querySelector('[data-status-filter=draft].is-active'))throw new Error('index forward did not restore combined controls');return 'index-forward-ok'; }"
  Invoke-MuseumBrowser eval "async () => { await document.fonts.ready; const faces=Array.from(document.fonts); const required=faces.filter(function(face){return face.family==='Org Museum Noto Sans SC'||face.family==='Org Museum Victor Mono';}); if(required.length!==3) throw new Error('expected three bundled font faces, got '+required.length); await Promise.all(required.map(function(face){return face.load();})); if(required.some(function(face){return face.status!=='loaded';})) throw new Error('font face did not load'); if(!required.some(function(face){return face.family==='Org Museum Victor Mono'&&face.style==='italic';})) throw new Error('Victor italic face missing'); const external=performance.getEntriesByType('resource').filter(function(entry){return new URL(entry.name).host!==location.host;}); if(external.length) throw new Error('external resource request: '+external[0].name); if(document.documentElement.scrollWidth>document.documentElement.clientWidth+1) throw new Error('desktop overflow'); return 'fonts-layout-ok'; }"
  Invoke-MuseumBrowser eval "async () => { if(!window.hljs){await new Promise(function(resolve,reject){const script=document.createElement('script');script.src='resources/highlight.min.js';script.onload=resolve;script.onerror=reject;document.head.appendChild(script);});} const cases=[['cpp','std::vector<int> values;'],['fsharp','let add x y = x + y']]; cases.forEach(function(item){const code=document.createElement('code');code.className='language-'+item[0];code.textContent=item[1];document.body.appendChild(code);hljs.highlightElement(code);if(code.dataset.highlighted!=='yes'||code.classList.contains('no-highlight')) throw new Error(item[0]+' highlight failed');}); return 'highlight-ok'; }"
  Invoke-MuseumBrowser resize 390 844
  Invoke-MuseumBrowser eval "() => { if(document.documentElement.scrollWidth>document.documentElement.clientWidth+1) throw new Error('mobile overflow'); return 'mobile-ok'; }"
  Invoke-MuseumBrowser open $graphUrl
  # [UI-04] A real pointer hover must expose the current shared action cue.
  Invoke-MuseumBrowser run-code "async (page) => { const button=page.locator('#btn-reset');await button.hover();const state=await button.evaluate(function(element){var styles=getComputedStyle(element);return {color:styles.color,accent:getComputedStyle(document.documentElement).getPropertyValue('--museum-accent').trim()};});var expected=await page.evaluate(function(color){var probe=document.createElement('span');probe.style.color=color;document.body.appendChild(probe);var resolved=getComputedStyle(probe).color;probe.remove();return resolved;},state.accent);if(!state.accent||state.color!==expected)throw new Error('graph control hover does not use the shared action cue: '+state.color+' / '+state.accent); }"
  Invoke-MuseumBrowser eval "() => { const data=JSON.parse(document.querySelector('#graph-data').textContent);const isolated=data.nodes.filter(function(node){return (node.degree||0)===0;});const related=data.nodes.filter(function(node){return (node.degree||0)>0;});if(!isolated.length)return 'isolated-node-fixture-empty';const rendered=Array.from(document.querySelectorAll('.graph-nodes g'));if(rendered.length!==related.length)throw new Error('relation canvas rendered '+rendered.length+' nodes instead of '+related.length);if(rendered.some(function(node){return node.classList.contains('is-isolated');}))throw new Error('isolated notes leaked into the relation canvas');const triage=document.querySelector('[data-graph-view=triage]');const relations=document.querySelector('[data-graph-view=relations]');const panel=document.querySelector('#graph-triage-panel');const status=document.querySelector('#graph-match-status');if(!triage||!relations||!panel||!status)throw new Error('graph mode controls are incomplete');if(parseInt(status.textContent,10)!==related.length)throw new Error('relation status does not match its canvas: '+status.textContent);triage.click();if(panel.hidden)throw new Error('triage panel did not open');const rows=panel.querySelectorAll('#graph-isolated-list article');if(rows.length!==isolated.length)throw new Error('triage list has '+rows.length+' rows instead of '+isolated.length);if(parseInt(status.textContent,10)!==isolated.length)throw new Error('triage status does not match its list: '+status.textContent);relations.click();if(!panel.hidden)throw new Error('triage panel did not close');return 'graph-modes-ok:'+related.length+'+'+isolated.length; }"
  Invoke-MuseumBrowser eval "() => { const input=document.querySelector('#org-museum-global-search'); input.value=(document.querySelector('.graph-nodes g')?.__data__.name||'').slice(0,3); input.dispatchEvent(new Event('input',{bubbles:true})); const category=document.querySelector('[data-graph-category]:not(.is-active)'); if(category)category.click(); const params=new URL(location.href).searchParams; if(input.value&&!params.get('q')) throw new Error('graph query URL missing'); if(category&&!params.get('category')) throw new Error('graph category URL missing'); return 'graph-url-ok'; }"
  Invoke-MuseumBrowser reload
  Invoke-MuseumBrowser eval "() => { const params=new URL(location.href).searchParams; if((document.querySelector('#org-museum-global-search').value||'')!==(params.get('q')||'')) throw new Error('graph query did not restore'); if(params.get('category')&&!document.querySelector('[data-graph-category].is-active')) throw new Error('graph category did not restore'); return 'graph-reload-ok'; }"
  Invoke-MuseumBrowser go-back
  Invoke-MuseumBrowser eval "() => { const params=new URL(location.href).searchParams;if(params.has('category'))throw new Error('graph back did not clear category');const active=document.querySelector('[data-graph-category].is-active');if(!active||active.dataset.graphCategory!=='*')throw new Error('graph back did not restore all categories');return 'graph-back-ok'; }"
  Invoke-MuseumBrowser go-forward
  Invoke-MuseumBrowser eval "() => { const params=new URL(location.href).searchParams;if(!params.get('category'))throw new Error('graph forward did not restore category URL');const active=document.querySelector('[data-graph-category].is-active');if(!active||active.dataset.graphCategory!==params.get('category'))throw new Error('graph forward did not restore category control');return 'graph-forward-ok'; }"
  Invoke-MuseumBrowser eval "() => { const node=document.querySelector('.graph-nodes g:not(.is-dimmed)')||document.querySelector('.graph-nodes g');if(!node)throw new Error('graph node missing');const href=node.__data__.url||'index.html';node.dispatchEvent(new MouseEvent('click',{bubbles:true}));if(document.body.dataset.pageKind!=='graph'||new URL(location.href).searchParams.get('focus')!==node.__data__.id)throw new Error('first graph click did not select in place');const detail=document.querySelector('#graph-selected-detail');if(!detail||detail.hidden)throw new Error('first graph click did not expose details');const themed=window.orgMuseumThemeUrl?window.orgMuseumThemeUrl(href):href;sessionStorage.setItem('orgMuseumSmokeExpectedUrl',new URL(themed,location.href).href);node.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));return 'graph-selected-and-opened'; }"
  Invoke-MuseumBrowser run-code "async (page) => { await page.waitForLoadState('domcontentloaded'); }"
  Invoke-MuseumBrowser eval "() => { const expected=sessionStorage.getItem('orgMuseumSmokeExpectedUrl');if(!expected||location.href!==expected)throw new Error('graph double click opened '+location.href+' instead of '+expected);if(document.body.dataset.pageKind!=='article'||location.pathname.endsWith('/graph.html'))throw new Error('graph double click did not open an article');return location.pathname; }"
  Invoke-MuseumBrowser open $timelineUrl
  Invoke-MuseumBrowser resize 320 844
  Invoke-MuseumBrowser eval "() => { const controls=Array.from(document.querySelectorAll('.timeline-filter-close,#timeline-isolated-list button')).filter(function(element){const rect=element.getBoundingClientRect();return rect.width>0&&rect.height>0;});if(!controls.length)throw new Error('timeline mobile action fixture is empty');const undersized=controls.filter(function(element){return element.getBoundingClientRect().height<44;});if(undersized.length)throw new Error('timeline mobile actions below 44px: '+undersized.map(function(element){return Math.round(element.getBoundingClientRect().height);}).join(','));return 'timeline-mobile-actions-ok:'+controls.length; }"
}
finally {
  try {
    if ($opened) { Invoke-MuseumBrowser close }
  }
  finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id }
  }
}
