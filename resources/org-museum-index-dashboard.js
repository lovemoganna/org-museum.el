(function(){
'use strict';

var dataEl=document.getElementById('org-museum-index-data');
var data={pages:[],generatedAt:''};
try{data=JSON.parse(dataEl?dataEl.textContent:'{"pages":[]}');}catch(_error){}
var sourceData=Array.isArray(data.pages)?data.pages:[];
var search=document.getElementById('org-museum-global-search');
var suggestEl=document.getElementById('museum-index-suggest');
var clearSearchBtn=document.querySelector('[data-index-search-clear]');
var resultList=document.getElementById('index-search-list');
var fallbackList=document.querySelector('.museum-index-matrix');
var empty=document.getElementById('index-search-empty');
var heading=document.getElementById('index-results-heading');
var visibleCount=document.getElementById('index-visible-count');
var live=document.getElementById('index-results-live');
var summary=document.getElementById('index-filter-summary');
var summaryChips=document.getElementById('index-filter-chips');
var clearButton=document.querySelector('[data-clear-index-filters]');
var resetLink=document.querySelector('[data-index-reset]');
var dynamicFilters=document.getElementById('index-dynamic-filters');
var filterPanel=document.querySelector('details.dashboard-filter-panel');
if(filterPanel&&typeof window.matchMedia==='function'&&window.matchMedia('(max-width: 760px)').matches)
  filterPanel.open=false;
var typeChart=document.getElementById('index-type-chart');
var typeExpand=document.getElementById('index-type-expand');
var typeCaption=document.getElementById('index-type-caption');
var trendChart=document.getElementById('index-trend-chart');
var trendAxis=document.getElementById('index-trend-axis');
var trendCaption=document.getElementById('index-trend-caption');
var rangeStart=document.getElementById('index-date-start');
var rangeEnd=document.getElementById('index-date-end');
var rangeClear=document.getElementById('index-date-clear');
var recentThirty=document.getElementById('index-recent-30');
var sortControl=document.getElementById('index-sort');
var resume=document.getElementById('continue-reading');
var resumeList=document.getElementById('continue-reading-list');
var resumeCount=document.getElementById('continue-reading-count');
var collator=new Intl.Collator('zh-CN',{sensitivity:'base',numeric:true});
var dayMs=86400000;

function count(value){return String(value).padStart(2,'0');}
function dateMs(value){
  var n=Date.parse(String(value||'')+'T00:00:00Z');
  return Number.isFinite(n)?n:NaN;
}
function iso(ms){return new Date(ms).toISOString().slice(0,10);}
function validDate(value){
  var ms=dateMs(value);
  return /^\d{4}-\d{2}-\d{2}$/.test(value)&&Number.isFinite(ms)&&iso(ms)===value;
}
function dimensionValues(page,key){
  var value=page[key];
  if(Array.isArray(value)){
    return value.map(function(item){return typeof item==='string'?item.trim():'';}).filter(Boolean);
  }
  if(typeof value==='string'&&value.trim())return [value.trim()];
  return [];
}
function buildSchema(records){
  var schema={};
  ['category','tags','status','project','type'].forEach(function(key){
    var values=new Set();
    records.forEach(function(page){
      dimensionValues(page,key).forEach(function(value){values.add(value);});
    });
    if(values.size)schema[key]=Array.from(values).sort(collator.compare);
  });
  return schema;
}

var state={
  sourceData:sourceData,
  filterSchema:buildSchema(sourceData),
  filters:{keyword:'',dimensions:{category:[],tags:[],status:[],project:[],type:[]},timeRange:null},
  sort:'modified-desc',
  filteredData:[],
  aggregations:{metrics:{total:0,recentCreated:0,recentUpdated:0},typeDistribution:[],timeTrend:[]},
  selection:{activeChart:'',activeValue:'',expandedCategories:false,expandedFacets:{}}
};
try{
  Object.defineProperty(state.filters.dimensions,'topic',{
    get:function(){return this.category||[];},
    set:function(v){this.category=Array.isArray(v)?v:(v?[v]:[]);},
    enumerable:false,
    configurable:true
  });
}catch(_err){}
window.orgMuseumDashboard=state;

function indexSearchText(records){
  records.forEach(function(page){
    page._searchText=[page.title,page.description,page.category,page.categoryLabel,page.project,page.type]
      .concat(page.tags||[])
      .concat((page.headings||[]).map(function(item){return item.title;}))
      .join(' ').toLocaleLowerCase();
  });
}
indexSearchText(state.sourceData);

function categoryLabel(value){
  var page=state.sourceData.find(function(item){return item.category===value;});
  var fallback=value==='uncategorized'?'其他笔记':value;
  return page?(page.categoryLabel||fallback):fallback;
}
function valueLabel(key,value){
  if(key==='category')return categoryLabel(value);
  if(key==='status')return value==='draft'?'草稿':value==='published'?'已发布':value;
  return value;
}
function dimensionLabel(key){
  return {category:'主题',tags:'标签',status:'状态',project:'项目',type:'类型'}[key]||key;
}

function matches(page,except){
  var words=state.filters.keyword.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
  if(words.some(function(word){return page._searchText.indexOf(word)<0;}))return false;
  if(except!=='timeRange'&&state.filters.timeRange){
    var mod=page.modifiedDate||'';
    var cr=(page.dateSource!=='modified-fallback'?page.createdDate:'')||'';
    var start=state.filters.timeRange.start,end=state.filters.timeRange.end;
    var matchMod=(!start||mod>=start)&&(!end||mod<=end);
    var matchCr=cr&&(!start||cr>=start)&&(!end||cr<=end);
    if(!matchMod&&!matchCr)return false;
  }
  return Object.keys(state.filterSchema).every(function(key){
    if(key===except)return true;
    var selected=state.filters.dimensions[key]||[];
    return !selected.length||dimensionValues(page,key).some(function(value){return selected.indexOf(value)>=0;});
  });
}

function optionCounts(key){
  var values=state.filterSchema[key]||[];
  var candidate=state.sourceData.filter(function(page){return matches(page,key);});
  return values.map(function(value){
    return {
      value:value,
      count:candidate.filter(function(page){
        return dimensionValues(page,key).indexOf(value)>=0;
      }).length
    };
  }).filter(function(item){
    return item.count>0||(state.filters.dimensions[key]||[]).indexOf(item.value)>=0;
  }).sort(function(a,b){
    return b.count-a.count||collator.compare(a.value,b.value);
  });
}

function localIsoDate(d){
  return d.getFullYear()+'-'+count(d.getMonth()+1)+'-'+count(d.getDate());
}
function parseBuildDate(str){
  if(!str)return NaN;
  if(/^\d{4}-\d{2}-\d{2}$/.test(str))return dateMs(str);
  var d=new Date(str);
  if(Number.isFinite(d.getTime()))return dateMs(localIsoDate(d));
  return NaN;
}
function recentReference(){
  var ref=parseBuildDate(data.generatedAt);
  var maxModMs=-Infinity;
  var pool=state&&state.sourceData&&state.sourceData.length?state.sourceData:sourceData;
  (pool||[]).forEach(function(p){
    var m=dateMs(p.modifiedDate);
    if(Number.isFinite(m)&&m>maxModMs)maxModMs=m;
  });
  if(Number.isFinite(maxModMs)){
    var todayMs=dateMs(localIsoDate(new Date()));
    var upperLimit=Math.max(maxModMs,todayMs);
    if(!Number.isFinite(ref)){
      ref=maxModMs;
    }else{
      if(ref>upperLimit)ref=upperLimit;
      if(ref<maxModMs)ref=maxModMs;
    }
  }
  if(!Number.isFinite(ref)){
    var today=new Date();
    ref=Date.UTC(today.getFullYear(),today.getMonth(),today.getDate());
  }
  return ref;
}
function recentDaysRange(days){
  return {start:iso(recentReference()-(days-1)*dayMs),end:iso(recentReference())};
}
function recentThirtyRange(){
  return recentDaysRange(30);
}
function isRecentRange(days){
  var range=state.filters.timeRange,shortcut=recentDaysRange(days);
  return Boolean(range&&range.start===shortcut.start&&range.end===shortcut.end);
}
function isRecentThirty(){
  return isRecentRange(30);
}
var dateShortcutDefs=[
  {id:'index-recent-7',days:7,label:'最近 7 天',metricLabel:'近 7 天'},
  {id:'index-recent-30',days:30,label:'最近 30 天',metricLabel:'近 30 天'},
  {id:'index-recent-90',days:90,label:'最近 90 天',metricLabel:'近 90 天'},
  {id:'index-recent-180',days:180,label:'最近半年',metricLabel:'近半年'},
  {id:'index-recent-365',days:365,label:'最近 1 年',metricLabel:'近 1 年'}
];
function getActiveShortcutLabel(){
  for(var i=0;i<dateShortcutDefs.length;i++){
    if(isRecentRange(dateShortcutDefs[i].days))return dateShortcutDefs[i].label;
  }
  return null;
}
function getMetricTimeLabelPrefix(){
  if(!state.filters.timeRange)return '近 30 天';
  for(var i=0;i<dateShortcutDefs.length;i++){
    if(isRecentRange(dateShortcutDefs[i].days))return dateShortcutDefs[i].metricLabel;
  }
  return '时段内';
}

function trendScale(){
  var dates=[];
  var pool=state.filteredData.length?state.filteredData:state.sourceData;
  pool.forEach(function(page){
    if(Number.isFinite(dateMs(page.modifiedDate)))dates.push(dateMs(page.modifiedDate));
    if(page.dateSource!=='modified-fallback'&&Number.isFinite(dateMs(page.createdDate)))
      dates.push(dateMs(page.createdDate));
  });
  var rangeStartMs=state.filters.timeRange&&state.filters.timeRange.start?dateMs(state.filters.timeRange.start):null;
  var rangeEndMs=state.filters.timeRange&&state.filters.timeRange.end?dateMs(state.filters.timeRange.end):null;
  var hasRangeStart=Number.isFinite(rangeStartMs);
  var hasRangeEnd=Number.isFinite(rangeEndMs);

  var min, max;
  if(hasRangeStart&&hasRangeEnd){
    min=rangeStartMs;max=rangeEndMs;
  }else if(hasRangeStart){
    dates.push(rangeStartMs);
    min=rangeStartMs;max=dates.length?Math.max.apply(null,dates):rangeStartMs;
  }else if(hasRangeEnd){
    dates.push(rangeEndMs);
    min=dates.length?Math.min.apply(null,dates):rangeEndMs;max=rangeEndMs;
  }else{
    if(!dates.length)return [];
    min=Math.min.apply(null,dates);max=Math.max.apply(null,dates);
  }
  if(!Number.isFinite(min)||!Number.isFinite(max)||min>max)return [];
  var span=(max-min)/dayMs;
  var unit=span>730?'year':span>180?'quarter':span>45?'month':span>10?'week':'day';
  function floor(ms){
    var date=new Date(ms);
    if(unit==='year')return Date.UTC(date.getUTCFullYear(),0,1);
    if(unit==='quarter')return Date.UTC(date.getUTCFullYear(),Math.floor(date.getUTCMonth()/3)*3,1);
    if(unit==='month')return Date.UTC(date.getUTCFullYear(),date.getUTCMonth(),1);
    if(unit==='week')return ms-((date.getUTCDay()+6)%7)*dayMs;
    return ms;
  }
  function next(ms){
    var date=new Date(ms);
    if(unit==='year')return Date.UTC(date.getUTCFullYear()+1,0,1);
    if(unit==='quarter')return Date.UTC(date.getUTCFullYear(),date.getUTCMonth()+3,1);
    if(unit==='month')return Date.UTC(date.getUTCFullYear(),date.getUTCMonth()+1,1);
    return ms+(unit==='week'?7:1)*dayMs;
  }
  var bins=[];
  for(var at=floor(min);at<=max&&bins.length<36;at=next(at)){
    var end=next(at)-dayMs;
    bins.push({
      start:iso(at),
      end:iso(end),
      label:unit==='year'?String(new Date(at).getUTCFullYear()):
        unit==='quarter'?new Date(at).getUTCFullYear()+' Q'+(Math.floor(new Date(at).getUTCMonth()/3)+1):
        unit==='month'?iso(at).slice(0,7):
        unit==='week'?iso(at).slice(5):iso(at).slice(5),
      created:0,
      updated:0
    });
  }
  return bins;
}

function aggregate(records){
  var range=state.filters.timeRange;
  var hasRange=Boolean(range&&(range.start||range.end));
  var rStart=hasRange?(range.start||''):'';
  var rEnd=hasRange?(range.end||''):'';
  var defaultCutoff=iso(recentReference()-29*dayMs);
  var metrics={total:records.length,recentCreated:0,recentUpdated:0};
  var trend=records.length?trendScale():[];
  records.forEach(function(page){
    var createdKnown=page.dateSource!=='modified-fallback';
    if(hasRange){
      if(createdKnown&&(!rStart||page.createdDate>=rStart)&&(!rEnd||page.createdDate<=rEnd))
        metrics.recentCreated++;
      if((!rStart||page.modifiedDate>=rStart)&&(!rEnd||page.modifiedDate<=rEnd))
        metrics.recentUpdated++;
    }else{
      if(createdKnown&&page.createdDate>=defaultCutoff)metrics.recentCreated++;
      if(page.modifiedDate>=defaultCutoff)metrics.recentUpdated++;
    }
    trend.forEach(function(bin){
      if(createdKnown&&page.createdDate>=bin.start&&page.createdDate<=bin.end)bin.created++;
      if(page.modifiedDate>=bin.start&&page.modifiedDate<=bin.end)bin.updated++;
    });
  });
  return {metrics:metrics,typeDistribution:[],timeTrend:trend};
}

function sortPages(records){
  return records.sort(function(a,b){
    if(state.sort==='title-asc')return collator.compare(a.title,b.title);
    if(state.sort==='created-desc')return (b.created||0)-(a.created||0)||collator.compare(a.title,b.title);
    return (b.modified||0)-(a.modified||0)||collator.compare(a.title,b.title);
  });
}

function derive(){
  state.filteredData=sortPages(state.sourceData.filter(function(page){return matches(page);}));
  state.aggregations=aggregate(state.filteredData);
  if(state.sourceData.length&&state.filterSchema.category){
    state.aggregations.typeDistribution=optionCounts('category');
  }else{
    state.aggregations.typeDistribution=[];
  }
}

function validateFilters(){
  Object.keys(state.filters.dimensions).forEach(function(key){
    var valid=state.filterSchema[key]||[];
    state.filters.dimensions[key]=(state.filters.dimensions[key]||[]).filter(function(value){
      return valid.indexOf(value)>=0;
    });
  });
  var range=state.filters.timeRange;
  if(range&&((range.start&&!validDate(range.start))||
             (range.end&&!validDate(range.end))||
             (range.start&&range.end&&range.start>range.end)))state.filters.timeRange=null;
  if(['modified-desc','created-desc','title-asc'].indexOf(state.sort)<0)state.sort='modified-desc';
}

function readUrl(){
  var params=new URLSearchParams(location.search);
  state.filters.keyword=params.get('q')||'';
  Object.keys(state.filters.dimensions).forEach(function(key){
    var parameter=key==='tags'?'tag':key;
    var val=params.get(parameter);
    if(!val&&key==='category')val=params.get('topic');
    state.filters.dimensions[key]=(val||'').split(',').filter(Boolean);
  });
  var start=params.get('from'),end=params.get('to');
  state.filters.timeRange=start||end?{start:start||'',end:end||''}:null;
  state.sort=params.get('sort')||'modified-desc';
  validateFilters();
}

function writeUrl(mode){
  var url=new URL(location.href);
  ['q','topic','category','tag','status','project','type','from','to','sort'].forEach(function(key){
    url.searchParams.delete(key);
  });
  if(state.filters.keyword)url.searchParams.set('q',state.filters.keyword);
  Object.keys(state.filters.dimensions).forEach(function(key){
    var values=state.filters.dimensions[key];
    if(values.length)url.searchParams.set(key==='tags'?'tag':key,values.join(','));
  });
  if(state.filters.timeRange){
    if(state.filters.timeRange.start)url.searchParams.set('from',state.filters.timeRange.start);
    if(state.filters.timeRange.end)url.searchParams.set('to',state.filters.timeRange.end);
  }
  if(state.sort!=='modified-desc')url.searchParams.set('sort',state.sort);
  var target=url.pathname+url.search+url.hash;
  try{
    if(mode==='push')history.pushState({},'',target);
    else history.replaceState({},'',target);
  }catch(_error){}
}

function button(label,className,pressed){
  var node=document.createElement('button');
  node.type='button';node.className=className||'';node.textContent=label;
  if(pressed!==undefined)node.setAttribute('aria-pressed',pressed?'true':'false');
  return node;
}

function setDimension(key,value){
  var values=state.filters.dimensions[key]||[];
  if(key==='category'){
    if(values.indexOf(value)>=0){
      state.filters.dimensions.category=[];
    }else{
      state.filters.dimensions.category=[value];
    }
    state.selection.activeChart=state.filters.dimensions.category.length?'topic':'';
    state.selection.activeValue=state.filters.dimensions.category.length?value:'';
  }else if(key==='status'){
    if(values.indexOf(value)>=0){
      state.filters.dimensions.status=[];
    }else{
      state.filters.dimensions.status=[value];
    }
  }else{
    var index=values.indexOf(value);
    if(index>=0)values.splice(index,1);
    else values.push(value);
  }
  update('push',true);
}

function renderDimension(key,host,className,items){
  if(!host)return;
  host.textContent='';
  (items||optionCounts(key)).forEach(function(item){
    var active=(state.filters.dimensions[key]||[]).indexOf(item.value)>=0;
    var control=button('',className+(active?' is-active':''),active);
    control.dataset.dimension=key;control.dataset.value=item.value;
    var name=document.createElement('span');name.textContent=valueLabel(key,item.value);
    var number=document.createElement('strong');number.textContent=String(item.count);
    control.appendChild(name);control.appendChild(number);
    control.addEventListener('click',function(){setDimension(key,item.value);});
    host.appendChild(control);
  });
}

function renderFilters(){
  if(dynamicFilters){
    dynamicFilters.textContent='';
    Object.keys(state.filterSchema).forEach(function(key){
      var available=optionCounts(key);
      if(!available.length)return;
      var group=document.createElement('section');group.className='dashboard-filter-group';
      group.dataset.filterKey=key;
      group.setAttribute('aria-label','按'+dimensionLabel(key)+'筛选');
      var label=document.createElement('h3');label.textContent=dimensionLabel(key);
      var options=document.createElement('div');options.className='dashboard-filter-options';
      var expanded=Boolean(state.selection.expandedFacets[key]);
      var visible=expanded?available:available.filter(function(item,index){
        return index<8||(state.filters.dimensions[key]||[]).indexOf(item.value)>=0;
      });
      renderDimension(key,options,'dashboard-filter',visible);
      if(key==='status'){
        var all=button('全部','dashboard-filter'+
          ((state.filters.dimensions.status||[]).length?'':' is-active'),
          !(state.filters.dimensions.status||[]).length);
        all.dataset.filterAll='status';
        all.addEventListener('click',function(){
          state.filters.dimensions.status=[];update('push',true);
        });
        options.insertBefore(all,options.firstChild);
      }
      group.appendChild(label);group.appendChild(options);
      if(available.length>8){
        var expand=button(expanded?'收起':'查看全部 '+available.length,'dashboard-facet-expand');
        expand.dataset.facetExpand=key;
        expand.setAttribute('aria-expanded',expanded?'true':'false');
        expand.addEventListener('click',function(){
          state.selection.expandedFacets[key]=!state.selection.expandedFacets[key];
          renderFilters();
          var replacement=dynamicFilters.querySelector('[data-facet-expand="'+key+'"]');
          if(replacement)replacement.focus();
        });
        group.appendChild(expand);
      }
      dynamicFilters.appendChild(group);
    });
  }
  if(search&&search.value!==state.filters.keyword)search.value=state.filters.keyword;
  if(rangeStart)rangeStart.value=state.filters.timeRange?state.filters.timeRange.start:'';
  if(rangeEnd)rangeEnd.value=state.filters.timeRange?state.filters.timeRange.end:'';
  if(rangeEnd){rangeEnd.setCustomValidity('');rangeEnd.setAttribute('aria-invalid','false');}
  var dateFeedback=document.getElementById('index-date-feedback');
  if(dateFeedback){dateFeedback.textContent='';dateFeedback.hidden=true;}
  if(rangeClear)rangeClear.hidden=!state.filters.timeRange;
  if(recentThirty)recentThirty.setAttribute('aria-pressed',isRecentThirty()?'true':'false');
  dateShortcutDefs.forEach(function(item){
    var el=document.getElementById(item.id);
    if(el)el.setAttribute('aria-pressed',isRecentRange(item.days)?'true':'false');
  });
  if(sortControl)sortControl.value=state.sort;
}

function removeChip(key,value){
  if(key==='keyword')state.filters.keyword='';
  else if(key==='timeRange')state.filters.timeRange=null;
  else state.filters.dimensions[key]=(state.filters.dimensions[key]||[]).filter(function(item){return item!==value;});
  state.selection.activeChart='';state.selection.activeValue='';
  update('push',true);
}

function renderSummary(){
  if(!summary||!summaryChips)return;
  summaryChips.textContent='';
  var chips=[];
  if(state.filters.keyword)chips.push(['keyword',state.filters.keyword,'搜索：'+state.filters.keyword]);
  Object.keys(state.filters.dimensions).forEach(function(key){
    (state.filters.dimensions[key]||[]).forEach(function(value){
      chips.push([key,value,dimensionLabel(key)+'：'+valueLabel(key,value)]);
    });
  });
  if(state.filters.timeRange){
    var scLabel=getActiveShortcutLabel();
    chips.push(['timeRange','',
      scLabel?('时间：'+scLabel):
        ('时间：'+(state.filters.timeRange.start||'不限')+' ~ '+
          (state.filters.timeRange.end||'不限'))]);
  }
  if(!chips.length){
    var all=document.createElement('span');all.className='dashboard-filter-all';all.textContent='全部笔记';
    summaryChips.appendChild(all);
  }
  chips.forEach(function(item){
    var chip=button(item[2]+' ×','dashboard-filter-chip');
    chip.dataset.chipKey=item[0];chip.dataset.chipValue=item[1];
    chip.setAttribute('aria-label','移除 '+item[2]+' 筛选');
    chip.addEventListener('click',function(){removeChip(item[0],item[1]);});
    summaryChips.appendChild(chip);
  });
  if(clearButton)clearButton.hidden=!chips.length;
}

function renderMetrics(){
  var metrics=state.aggregations.metrics;
  var prefix=getMetricTimeLabelPrefix();
  var labelMap={
    'recent-created':prefix+'新增',
    'recent-updated':prefix+'更新'
  };
  [['total',metrics.total],['recent-created',metrics.recentCreated],
   ['recent-updated',metrics.recentUpdated]].forEach(function(item){
    var target=document.querySelector('[data-dashboard-metric="'+item[0]+'"]');
    if(target)target.textContent=String(item[1]);
    if(labelMap[item[0]]){
      var labelEl=document.querySelector('[data-dashboard-metric-label="'+item[0]+'"]');
      if(!labelEl&&target&&target.parentElement){
        labelEl=target.parentElement.querySelector('span');
      }
      if(labelEl)labelEl.textContent=labelMap[item[0]];
    }
  });
}

function renderTypeChart(){
  if(!typeChart)return;
  typeChart.textContent='';
  var distribution=state.aggregations.typeDistribution;
  var hasActiveFilter=Boolean(state.filters.dimensions.category&&state.filters.dimensions.category.length);
  if(typeCaption)typeCaption.textContent=hasActiveFilter?
    '按其他条件统计 · 点击取消或切换主题':'点击主题筛选';
  if(!state.filteredData.length||!distribution.length){
    var emptyMsg=document.createElement('div');
    emptyMsg.className='dashboard-chart-empty';
    emptyMsg.textContent='当前条件下没有主题数据';
    typeChart.appendChild(emptyMsg);
    if(typeExpand)typeExpand.hidden=true;
    return;
  }
  var visibleItems=distribution.filter(function(item){
    return item.count>0||(state.filters.dimensions.category||[]).indexOf(item.value)>=0;
  });
  if(typeExpand){
    typeExpand.hidden=visibleItems.length<=6;
    typeExpand.textContent=state.selection.expandedCategories?'收起主题':'查看全部主题 ('+visibleItems.length+')';
    typeExpand.setAttribute('aria-expanded',state.selection.expandedCategories?'true':'false');
  }
  var max=Math.max.apply(null,visibleItems.map(function(item){return item.count;}));
  if(max<1)max=1;
  (state.selection.expandedCategories?visibleItems:visibleItems.slice(0,6)).forEach(function(item){
    var active=(state.filters.dimensions.category||[]).indexOf(item.value)>=0;
    var row=button('','dashboard-type-row'+(active?' is-active':''),active);
    row.dataset.chartType=item.value;
    var label=categoryLabel(item.value);
    row.title=label+' · '+item.count+' 篇';
    row.setAttribute('aria-label',row.title+'；点击'+(active?'取消':'筛选'));
    var name=document.createElement('span');name.textContent=label;
    var track=document.createElement('span');track.className='dashboard-type-track';
    var fill=document.createElement('i');fill.style.width=(item.count/max*100)+'%';track.appendChild(fill);
    var number=document.createElement('strong');number.textContent=String(item.count);
    row.appendChild(name);row.appendChild(track);row.appendChild(number);
    row.addEventListener('click',function(){setDimension('category',item.value);});
    typeChart.appendChild(row);
  });
}

var trendDrag=null;
function renderTrend(){
  if(!trendChart)return;
  trendChart.textContent='';
  var bins=state.aggregations.timeTrend;
  if(!state.filteredData.length||!bins.length){
    if(trendAxis)trendAxis.textContent='';
    var emptyMsg=document.createElement('div');
    emptyMsg.className='dashboard-chart-empty';
    emptyMsg.textContent='当前条件下没有时间数据';
    trendChart.appendChild(emptyMsg);
    if(trendCaption)trendCaption.textContent='无时间数据';
    return;
  }
  var max=Math.max(1,...bins.map(function(bin){return Math.max(bin.created,bin.updated);}));
  var ceiling=max<=3?3:max<=6?6:max<=10?10:Math.ceil(max/5)*5;
  if(trendAxis){
    trendAxis.textContent='';
    [ceiling,Math.round(ceiling/2),0].forEach(function(value){
      var tick=document.createElement('span');tick.textContent=String(value);
      trendAxis.appendChild(tick);
    });
  }
  trendChart.style.gridTemplateColumns='repeat('+bins.length+',minmax(0,1fr))';
  bins.forEach(function(bin,index){
    var selected=state.filters.timeRange&&
      (!state.filters.timeRange.end||bin.start<=state.filters.timeRange.end)&&
      (!state.filters.timeRange.start||bin.end>=state.filters.timeRange.start);
    var cell=button('','dashboard-trend-bin'+(selected?' is-active':''),Boolean(selected));
    cell.dataset.trendIndex=String(index);
    var text=bin.start===bin.end?bin.start:bin.start+' ~ '+bin.end;
    cell.title='日期：'+text+' · 新增：'+bin.created+' · 更新：'+bin.updated;
    cell.setAttribute('aria-label',cell.title+'；点击筛选，拖动选择范围');
    var columns=document.createElement('span');columns.className='dashboard-trend-columns';

    var createdBar=document.createElement('i');
    createdBar.className='dashboard-trend-created';
    createdBar.style.height=bin.created?Math.max(8,Math.round(bin.created/ceiling*100))+'%':'0%';
    createdBar.dataset.value=String(bin.created);
    createdBar.dataset.label=String(bin.created);
    createdBar.title='新增：'+bin.created;
    var createdVal=document.createElement('span');
    createdVal.className='dashboard-trend-value dashboard-trend-label';
    createdVal.setAttribute('aria-hidden','true');
    createdVal.dataset.value=String(bin.created);
    createdVal.dataset.label=String(bin.created);
    createdVal.textContent=String(bin.created);
    createdBar.appendChild(createdVal);
    columns.appendChild(createdBar);

    var updatedBar=document.createElement('i');
    updatedBar.className='dashboard-trend-updated';
    updatedBar.style.height=bin.updated?Math.max(8,Math.round(bin.updated/ceiling*100))+'%':'0%';
    updatedBar.dataset.value=String(bin.updated);
    updatedBar.dataset.label=String(bin.updated);
    updatedBar.title='更新：'+bin.updated;
    var updatedVal=document.createElement('span');
    updatedVal.className='dashboard-trend-value dashboard-trend-label';
    updatedVal.setAttribute('aria-hidden','true');
    updatedVal.dataset.value=String(bin.updated);
    updatedVal.dataset.label=String(bin.updated);
    updatedVal.textContent=String(bin.updated);
    updatedBar.appendChild(updatedVal);
    columns.appendChild(updatedBar);

    var label=document.createElement('small');
    var labelStep=bins.length>16?Math.ceil(bins.length/6):bins.length>8?2:1;
    label.textContent=(index%labelStep===0||index===bins.length-1)?bin.label:'';
    label.title=bin.label;
    label.dataset.label=bin.label;
    cell.dataset.binLabel=bin.label;
    cell.appendChild(columns);cell.appendChild(label);
    cell.addEventListener('click',function(){
      if(trendDrag&&trendDrag.suppressClick){trendDrag=null;return;}
      var same=state.filters.timeRange&&state.filters.timeRange.start===bin.start&&
        state.filters.timeRange.end===bin.end;
      state.filters.timeRange=same?null:{start:bin.start,end:bin.end};
      state.selection.activeChart=same?'':'time';
      state.selection.activeValue=same?'':bin.start;
      update('push',true);
    });
    trendChart.appendChild(cell);
  });
  if(trendCaption){
    if(state.filters.timeRange){
      var sc=getActiveShortcutLabel();
      trendCaption.textContent='已筛选：'+(sc?sc+' · ':'')+(state.filters.timeRange.start||'起始')+' ~ '+(state.filters.timeRange.end||'至今');
    }else{
      trendCaption.textContent='点击时间筛选，拖拽选择区间';
    }
  }
}

function bestMatch(page){
  var words=state.filters.keyword.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
  if(!words.length)return {href:page.href,context:''};
  function contains(text){var value=String(text||'').toLocaleLowerCase();
    return words.every(function(word){return value.indexOf(word)>=0;});}
  if(contains(page.title))return {href:page.href,context:''};
  var headingMatch=(page.headings||[]).find(function(item){return contains(item.title);});
  if(headingMatch)return {href:page.href.split('#')[0]+'#'+encodeURIComponent(headingMatch.id),
    context:'章节 · '+headingMatch.title};
  if(contains(page.description))return {href:page.href,context:'摘要 · '+page.description};
  return {href:page.href,context:''};
}

function renderResults(){
  var query=state.filters.keyword.trim().toLocaleLowerCase();
  var hasQuery=Boolean(query);
  if(fallbackList)fallbackList.hidden=true;
  if(resultList){
    resultList.hidden=false;resultList.textContent='';
    state.filteredData.forEach(function(page){
      var match=bestMatch(page);
      var row=document.createElement('article');row.className='museum-search-result';

      var header=document.createElement('div');header.className='dashboard-result-header';
      var link=document.createElement('a');link.className='dashboard-result-title';
      link.href=window.orgMuseumThemeUrl?window.orgMuseumThemeUrl(match.href):match.href;
      link.textContent=page.title||page.pageId;
      header.appendChild(link);

      if(page.status){
        var statusBadge=document.createElement('span');
        statusBadge.className='museum-status-badge '+(page.status==='draft'?'is-draft':'is-published');
        statusBadge.textContent=valueLabel('status',page.status);
        header.appendChild(statusBadge);
      }
      row.appendChild(header);

      var meta=document.createElement('div');meta.className='dashboard-result-meta';
      var categoryVal=page.category||'';
      var topic=document.createElement(categoryVal?'button':'span');
      topic.className='dashboard-result-topic museum-entry-category';
      if(categoryVal){
        topic.type='button';
        topic.dataset.categoryLink=categoryVal;
        var activeCat=(state.filters.dimensions.category||[]).indexOf(categoryVal)>=0;
        if(activeCat)topic.classList.add('is-active');
        topic.setAttribute('aria-pressed',activeCat?'true':'false');
        topic.title=(activeCat?'取消筛选主题：':'筛选主题：')+(page.categoryLabel||categoryVal);
        topic.addEventListener('click',function(e){
          if(e&&typeof e.stopPropagation==='function')e.stopPropagation();
          setDimension('category',categoryVal);
        });
      }
      topic.textContent=page.categoryLabel||page.category||'未分类';
      meta.appendChild(topic);

      var modified=document.createElement('time');modified.className='dashboard-result-time';
      modified.dateTime=page.modifiedDate||'';
      modified.textContent=page.modifiedDate||'日期未知';
      meta.appendChild(modified);

      if(match.context){
        var context=document.createElement('span');context.className='dashboard-result-context';
        context.textContent=match.context;meta.appendChild(context);
      }

      if(Array.isArray(page.tags)&&page.tags.length){
        var tagContainer=document.createElement('div');
        tagContainer.className='dashboard-result-tags';
        page.tags.forEach(function(tag){
          var active=(state.filters.dimensions.tags||[]).indexOf(tag)>=0;
          var chip=document.createElement('button');
          chip.type='button';
          chip.className='museum-tag-chip'+(active?' is-active':'');
          chip.dataset.tag=tag;
          chip.setAttribute('aria-pressed',active?'true':'false');
          chip.title=(active?'取消筛选标签：#':'筛选标签：#')+tag;
          var hash=document.createElement('span');hash.className='museum-tag-hash';hash.textContent='#';
          var name=document.createElement('span');name.className='museum-tag-name';name.textContent=tag;
          chip.appendChild(hash);
          chip.appendChild(name);
          chip.addEventListener('click',function(e){
            if(e&&typeof e.stopPropagation==='function')e.stopPropagation();
            setDimension('tags',tag);
          });
          tagContainer.appendChild(chip);
        });
        meta.appendChild(tagContainer);
      }

      row.appendChild(meta);
      resultList.appendChild(row);
    });
  }
  var isEmpty=state.filteredData.length===0;
  if(empty)empty.hidden=!isEmpty;
  if(isEmpty&&fallbackList)fallbackList.hidden=true;
  if(heading)heading.textContent=hasQuery?'搜索结果':'笔记结果';
  if(visibleCount)visibleCount.textContent=String(state.filteredData.length);
  if(live)live.textContent='显示 '+state.filteredData.length+' 篇笔记';
}

function render(){
  var selectedCategories=state.filters.dimensions.category||[];
  state.selection.activeChart=selectedCategories.length?'topic':
    state.filters.timeRange?'time':'';
  state.selection.activeValue=selectedCategories.length?selectedCategories.join(','):
    state.filters.timeRange?(state.filters.timeRange.start+' ~ '+state.filters.timeRange.end):'';
  derive();renderFilters();renderSummary();renderMetrics();renderTypeChart();renderTrend();renderResults();
  document.body.classList.toggle('museum-index-filtering',Boolean(state.filters.keyword||
    state.filters.timeRange||Object.keys(state.filters.dimensions).some(function(key){
      return (state.filters.dimensions[key]||[]).length;
    })));
}

function focusDescriptor(){
  var active=document.activeElement;
  if(!active||!active.dataset)return null;
  if(active.dataset.dimension)return ['dimension',active.dataset.dimension,active.dataset.value];
  if(active.dataset.chartType)return ['chart',active.dataset.chartType];
  if(active.dataset.filterAll)return ['all',active.dataset.filterAll];
  if(active.dataset.chipKey)return ['chip',active.dataset.chipKey,active.dataset.chipValue];
  return null;
}
function restoreFocus(descriptor){
  var controls=descriptor&&Array.from(document.querySelectorAll('button'));
  var target=controls&&controls.find(function(node){
    if(descriptor[0]==='dimension')return node.dataset.dimension===descriptor[1]&&
      node.dataset.value===descriptor[2];
    if(descriptor[0]==='chart')return node.dataset.chartType===descriptor[1];
    if(descriptor[0]==='all')return node.dataset.filterAll===descriptor[1];
    return node.dataset.chipKey===descriptor[1]&&node.dataset.chipValue===descriptor[2];
  });
  (target||heading).focus({preventScroll:true});
}

function update(mode,focus){
  var descriptor=focus?focusDescriptor():null;
  validateFilters();writeUrl(mode||'push');render();
  if(focus&&heading)requestAnimationFrame(function(){restoreFocus(descriptor);});
}

function clearAll(){
  state.filters.keyword='';state.filters.timeRange=null;
  Object.keys(state.filters.dimensions).forEach(function(key){state.filters.dimensions[key]=[];});
  state.selection.activeChart='';state.selection.activeValue='';
  state.selection.expandedCategories=false;state.selection.expandedFacets={};
  update('push',true);
}

function setSourceData(newPages){
  state.sourceData=Array.isArray(newPages)?newPages:[];
  indexSearchText(state.sourceData);
  state.filterSchema=buildSchema(state.sourceData);
  validateFilters();
  update('replace',false);
}
state.setSourceData=setSourceData;
state.refresh=function(newPages){
  if(newPages)setSourceData(newPages);
  else update('replace',false);
};

var selectedSuggestIndex=-1;

function highlightMatch(text,query){
  if(!query||!text)return document.createTextNode(text||'');
  var span=document.createElement('span');
  var words=query.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
  if(!words.length){span.textContent=text;return span;}
  var lower=text.toLocaleLowerCase();
  var matchRanges=[];
  words.forEach(function(w){
    var idx=0;
    while((idx=lower.indexOf(w,idx))>=0){
      matchRanges.push([idx,idx+w.length]);
      idx+=w.length;
    }
  });
  if(!matchRanges.length){span.textContent=text;return span;}
  matchRanges.sort(function(a,b){return a[0]-b[0];});
  var merged=[];
  matchRanges.forEach(function(r){
    if(!merged.length||merged[merged.length-1][1]<r[0]){
      merged.push(r.slice());
    }else if(merged[merged.length-1][1]<r[1]){
      merged[merged.length-1][1]=r[1];
    }
  });
  var lastIdx=0;
  merged.forEach(function(r){
    if(r[0]>lastIdx){
      span.appendChild(document.createTextNode(text.slice(lastIdx,r[0])));
    }
    var mark=document.createElement('mark');
    mark.textContent=text.slice(r[0],r[1]);
    span.appendChild(mark);
    lastIdx=r[1];
  });
  if(lastIdx<text.length){
    span.appendChild(document.createTextNode(text.slice(lastIdx)));
  }
  return span;
}

function closeSuggest(){
  if(suggestEl){
    suggestEl.hidden=true;
    suggestEl.textContent='';
  }
  selectedSuggestIndex=-1;
  if(search)search.setAttribute('aria-expanded','false');
}

function updateSuggestSelection(items){
  items.forEach(function(item,i){
    var isSel=i===selectedSuggestIndex;
    item.classList.toggle('is-selected',isSel);
    item.setAttribute('aria-selected',isSel?'true':'false');
    if(isSel&&typeof item.scrollIntoView==='function'){
      item.scrollIntoView({block:'nearest'});
    }
  });
}

function renderSuggest(){
  if(!suggestEl||!search)return;
  var query=search.value.trim().toLocaleLowerCase();
  if(!query){closeSuggest();return;}
  var matches=state.filteredData.slice(0,7);
  suggestEl.textContent='';
  if(!matches.length){
    var emptyLi=document.createElement('li');
    emptyLi.className='museum-index-suggest-item';
    emptyLi.style.pointerEvents='none';
    var emptyCopy=document.createElement('span');
    emptyCopy.className='museum-index-suggest-context';
    emptyCopy.textContent='未找到匹配的笔记，按 Enter 查看筛选列表';
    emptyLi.appendChild(emptyCopy);
    suggestEl.appendChild(emptyLi);
    suggestEl.hidden=false;
    search.setAttribute('aria-expanded','true');
    selectedSuggestIndex=-1;
    return;
  }
  selectedSuggestIndex=-1;
  matches.forEach(function(page,idx){
    var li=document.createElement('li');
    li.className='museum-index-suggest-item';
    li.setAttribute('role','option');
    li.setAttribute('id','suggest-item-'+idx);
    li.dataset.index=String(idx);

    var icon=document.createElement('span');
    icon.className='museum-index-suggest-icon';
    icon.setAttribute('aria-hidden','true');
    li.appendChild(icon);

    var main=document.createElement('div');
    main.className='museum-index-suggest-main';

    var title=document.createElement('div');
    title.className='museum-index-suggest-title';
    title.appendChild(highlightMatch(page.title||page.pageId,query));
    main.appendChild(title);

    var matchInfo=bestMatch(page);
    var contextText=matchInfo.context||page.description||(page.tags&&page.tags.length?'#'+page.tags.join(' #'):'');
    if(contextText){
      var context=document.createElement('div');
      context.className='museum-index-suggest-context';
      context.appendChild(highlightMatch(contextText,query));
      main.appendChild(context);
    }
    li.appendChild(main);

    var badge=document.createElement('span');
    badge.className='museum-index-suggest-badge';
    badge.textContent=page.categoryLabel||page.category||'笔记';
    li.appendChild(badge);

    li.addEventListener('mousedown',function(e){
      e.preventDefault();
      var targetUrl=window.orgMuseumThemeUrl?window.orgMuseumThemeUrl(matchInfo.href):matchInfo.href;
      location.href=targetUrl;
    });

    suggestEl.appendChild(li);
  });

  var footer=document.createElement('li');
  footer.className='museum-index-suggest-footer';
  footer.innerHTML='<span>共找到 '+state.filteredData.length+' 篇笔记 · ↑↓ 键导航 · Enter 打开</span><span>Esc 关闭</span>';
  suggestEl.appendChild(footer);

  suggestEl.hidden=false;
  search.setAttribute('aria-expanded','true');
}

function updateClearButton(){
  if(clearSearchBtn&&search){
    clearSearchBtn.hidden=!search.value;
  }
}

if(clearSearchBtn){
  clearSearchBtn.addEventListener('click',function(){
    if(search){
      search.value='';
      state.filters.keyword='';
      updateClearButton();
      closeSuggest();
      update('replace',false);
      search.focus();
    }
  });
}

if(search){
  search.addEventListener('input',function(){
    state.filters.keyword=search.value;
    updateClearButton();
    update('replace',false);
    renderSuggest();
  });
  search.addEventListener('focus',function(){
    if(search.value.trim()){
      renderSuggest();
    }
  });
  search.addEventListener('keydown',function(event){
    if(event.isComposing)return;
    var items=suggestEl?Array.from(suggestEl.querySelectorAll('.museum-index-suggest-item[role="option"]')):[];
    if(event.key==='ArrowDown'){
      if(items.length>0&&!suggestEl.hidden){
        event.preventDefault();
        selectedSuggestIndex=(selectedSuggestIndex+1)%items.length;
        updateSuggestSelection(items);
        return;
      }
      var first=resultList&&resultList.querySelector('a[href]');
      if(first){event.preventDefault();first.focus();}
    }else if(event.key==='ArrowUp'){
      if(items.length>0&&!suggestEl.hidden){
        event.preventDefault();
        selectedSuggestIndex=(selectedSuggestIndex-1+items.length)%items.length;
        updateSuggestSelection(items);
        return;
      }
    }else if(event.key==='Enter'){
      if(items.length>0&&selectedSuggestIndex>=0&&!suggestEl.hidden){
        event.preventDefault();
        var selectedItem=items[selectedSuggestIndex];
        var pageIdx=Number(selectedItem.dataset.index);
        var page=state.filteredData[pageIdx];
        if(page){
          var m=bestMatch(page);
          var href=window.orgMuseumThemeUrl?window.orgMuseumThemeUrl(m.href):m.href;
          location.href=href;
          return;
        }
      }
      closeSuggest();
      var firstLink=resultList&&resultList.querySelector('a[href]');
      if(firstLink){event.preventDefault();firstLink.click();}
    }else if(event.key==='Escape'){
      event.preventDefault();
      if(suggestEl&&!suggestEl.hidden){
        closeSuggest();
      }else{
        state.filters.keyword='';
        if(search)search.value='';
        updateClearButton();
        update('replace',false);
        search.blur();
      }
    }
  });
}

document.addEventListener('click',function(e){
  if(suggestEl&&!suggestEl.hidden&&search&&!search.contains(e.target)&&!suggestEl.contains(e.target)){
    closeSuggest();
  }
});
if(resultList)resultList.addEventListener('keydown',function(event){
  if(['ArrowDown','ArrowUp','Escape'].indexOf(event.key)<0)return;
  var links=Array.from(resultList.querySelectorAll('a[href]'));
  var at=links.indexOf(document.activeElement);if(at<0)return;
  event.preventDefault();
  if(event.key==='Escape'||(event.key==='ArrowUp'&&at===0)){if(search)search.focus();return;}
  var next=links[at+(event.key==='ArrowDown'?1:-1)];if(next)next.focus();
});
document.addEventListener('keydown',function(event){
  if(event.key==='/'&&!event.metaKey&&!event.ctrlKey&&!event.altKey&&
     !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)){
    event.preventDefault();if(search)search.focus();
  }
});
if(clearButton)clearButton.addEventListener('click',clearAll);
if(resetLink)resetLink.addEventListener('click',function(event){
  event.preventDefault();clearAll();
  var target=document.getElementById('recent-updates');if(target)target.scrollIntoView({block:'start'});
});
if(sortControl)sortControl.addEventListener('change',function(){state.sort=sortControl.value;update('push',false);});
if(typeExpand)typeExpand.addEventListener('click',function(){
  state.selection.expandedCategories=!state.selection.expandedCategories;
  renderTypeChart();typeExpand.focus();
});
dateShortcutDefs.forEach(function(item){
  var el=document.getElementById(item.id);
  if(el){
    el.addEventListener('click',function(){
      var active=isRecentRange(item.days);
      state.filters.timeRange=active?null:recentDaysRange(item.days);
      state.selection.activeChart=state.filters.timeRange?'time':'';
      state.selection.activeValue=state.filters.timeRange?item.days+'d':'';
      update('push',false);
    });
  }
});
function applyDateInputs(){
  if(!rangeStart||!rangeEnd)return;
  var reversed=rangeStart.value&&rangeEnd.value&&rangeStart.value>rangeEnd.value;
  rangeEnd.setCustomValidity(reversed?'结束日期不能早于开始日期。':'');
  rangeEnd.setAttribute('aria-invalid',reversed?'true':'false');
  var feedback=document.getElementById('index-date-feedback');
  if(feedback){feedback.textContent=reversed?'结束日期不能早于开始日期，请调整日期。':'';feedback.hidden=!reversed;}
  if(reversed)return;
  state.filters.timeRange=rangeStart.value||rangeEnd.value?
    {start:rangeStart.value,end:rangeEnd.value}:null;
  state.selection.activeChart=state.filters.timeRange?'time':'';
  state.selection.activeValue=rangeStart.value||rangeEnd.value;
  update('push',false);
}
if(rangeStart)rangeStart.addEventListener('change',applyDateInputs);
if(rangeEnd)rangeEnd.addEventListener('change',applyDateInputs);
if(rangeClear)rangeClear.addEventListener('click',function(){
  state.filters.timeRange=null;state.selection.activeChart='';state.selection.activeValue='';
  update('push',false);
});
if(trendChart){
  trendChart.addEventListener('pointerdown',function(event){
    if(event.pointerType!=='mouse'||event.button!==0)return;
    var cell=event.target.closest('[data-trend-index]');if(!cell)return;
    trendDrag={start:Number(cell.dataset.trendIndex),end:Number(cell.dataset.trendIndex),moved:false};
  });
  document.addEventListener('pointermove',function(event){
    if(!trendDrag)return;
    var cell=document.elementFromPoint(event.clientX,event.clientY);
    cell=cell&&cell.closest('[data-trend-index]');
    if(!cell||!trendChart.contains(cell))return;
    var end=Number(cell.dataset.trendIndex);
    if(end!==trendDrag.end){trendDrag.end=end;trendDrag.moved=true;}
    Array.from(trendChart.children).forEach(function(node,index){
      node.classList.toggle('is-preview',index>=Math.min(trendDrag.start,trendDrag.end)&&
        index<=Math.max(trendDrag.start,trendDrag.end));
    });
  });
  document.addEventListener('pointerup',function(){
    if(!trendDrag)return;
    if(trendDrag.moved){
      var bins=state.aggregations.timeTrend;
      var first=bins[Math.min(trendDrag.start,trendDrag.end)];
      var last=bins[Math.max(trendDrag.start,trendDrag.end)];
      if(first&&last){
        state.filters.timeRange={start:first.start,end:last.end};
        state.selection.activeChart='time';state.selection.activeValue=first.start+' ~ '+last.end;
        trendDrag.suppressClick=true;update('push',false);
        setTimeout(function(){trendDrag=null;},0);
      }
    }else trendDrag=null;
  });
  document.addEventListener('pointercancel',function(){trendDrag=null;});
}
window.addEventListener('popstate',function(){readUrl();render();});

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
  return String(value||'').replace(/ +/g,' ').trim();
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
      var page=state.sourceData.find(function(item){return item.pageId===record.pageId;});
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
    if(state.sourceData.length){var start=document.createElement('a');
      start.href=state.sourceData.slice().sort(function(a,b){return (b.modified||0)-(a.modified||0);})[0].href;
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
document.addEventListener('click',function(e){
  var catBtn=e.target&&e.target.closest?e.target.closest('[data-category-link], .museum-entry-category'):null;
  if(catBtn&&catBtn.dataset&&catBtn.dataset.categoryLink){
    e.preventDefault();
    setDimension('category',catBtn.dataset.categoryLink);
  }
});
readUrl();validateFilters();writeUrl('replace');render();
openReadingDb().then(function(db){
  return loadRecentRecords(db).finally(function(){db.close();});
}).then(renderResume).catch(function(){renderResume([]);});
})();
