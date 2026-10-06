const {test}=require('node:test');
const assert=require('node:assert/strict');
const {create}=require('../resources/org-museum-ai-workspace.js');
const pages=[{id:'a',title:'甲',category:'知识',sourceHash:'hash-a',href:'a.html',linksTo:['b']},{id:'b',title:'乙',category:'知识',sourceHash:'hash-b',href:'b.html'}];
const text='这是已保存的真实来源测试片段。\n#+RESULTS:\n: verified result';
function fixture(infer) {
  let saved;
  const options={pages,workspaceId:'test-wiki',publicRecords:[],model:()=> 'test-model',
    storage:{load:async()=>saved&&structuredClone(saved),save:async state=>{saved=structuredClone(state);}},
    source:async p=>({hash:p.sourceHash,text}),infer:infer|| (async(messages,onChunk)=> {
      if(messages[0].content.includes('只返回 JSON：')) return JSON.stringify({directions:[{title:'核实依据',question:'来源如何验证？',reason:'核实原文',sourcePageIds:['a']}],proposals:[{type:'conclusion',title:'原文依据总结',body:'这是有来源依据的整理内容。',targetPageId:'a',sourcePageIds:['a'],evidence:'这是已保存的真实来源测试片段。'}],takeaway:{title:'可复用结论',category:'结论',conclusion:'来源应逐字核实',evidence:'这是已完成的测试回答。'}});
      onChunk('这是已完成的测试回答。'); return '这是已完成的测试回答。';
    })};
  return {options, workspace:create(options)};
}
async function settled(workspace,id) {
  for(let i=0;i<100;i++) { const s=await workspace.api('session?sessionId='+id); if(!['streaming','recommending','batching'].includes(s.status)) { await workspace.flush(); return s; } await new Promise(resolve=>setImmediate(resolve)); }
  throw new Error('session did not finish');
}

test('backup import waits for an already-started workspace operation', async()=>{
  const backup=await fixture().workspace.exportData();
  const {options}=fixture();
  let release, entered;
  const waiting=new Promise(resolve=>{release=resolve;});
  const started=new Promise(resolve=>{entered=resolve;});
  options.source=async p=>{entered(); await waiting; return {hash:p.sourceHash,text};};
  const workspace=create(options), pending=workspace.api('session-start',{pageIds:['a']});
  await started;
  try { await assert.rejects(workspace.importData(backup),/运行中的操作/); }
  finally { release(); await pending; }
  assert.equal((await workspace.exportData()).sessions.length,1);
});

test('invalid late backup records cannot partially import earlier sessions', async()=>{
  const source=fixture().workspace;
  await settled(source,(await source.api('session-start',{pageIds:['a']})).id);
  const backup=await source.exportData();
  backup.queue=[{id:'invalid-job',pageId:'missing-page',status:'dirty'}];
  const destination=fixture().workspace, before=await destination.exportData();
  await assert.rejects(destination.importData(backup),/找不到/);
  assert.deepEqual(await destination.exportData(),before);
});

test('imported source links use current catalog addresses instead of executable URLs', async()=>{
  const source=fixture().workspace;
  const session=await settled(source,(await source.api('session-start',{pageIds:['a']})).id);
  await source.api('capture-add',{sessionId:session.id,turnId:session.turns[0].id});
  const backup=await source.exportData();
  backup.sessions[0].sources[0].href='javascript:alert(1)';
  backup.captures[0].sources[0].href='data:text/html,unsafe';
  const destination=fixture().workspace;
  await destination.importData(backup);
  const restored=await destination.exportData();
  assert.equal(restored.sessions[0].sources[0].href,'a.html');
  assert.equal(restored.captures[0].sources[0].href,'a.html');
});

test('failed durable backup save leaves the in-memory workspace unchanged', async()=>{
  const source=fixture().workspace;
  await settled(source,(await source.api('session-start',{pageIds:['a']})).id);
  const backup=await source.exportData(), {workspace,options}=fixture();
  const before=await workspace.exportData(), save=options.storage.save;
  options.storage.save=async()=>{throw new Error('disk-full');};
  await assert.rejects(workspace.importData(backup),/disk-full/);
  options.storage.save=save;
  await workspace.api('action',{action:'mode',mode:'assist'});
  assert.deepEqual(await workspace.exportData(),before);
});
test('category display labels remain consistent while filter keys stay unchanged', async()=>{
  const {options}=fixture();
  options.pages=pages.map(p=>({...p,category:'uncategorized',categoryLabel:'其他笔记'}));
  const workspace=create(options);
  assert.equal((await workspace.api('catalog')).pages[0].categoryLabel,'其他笔记');
  const session=await workspace.api('session-start',{pageIds:['a'],batch:true});
  const done=await settled(workspace,session.id);
  await workspace.api('capture-add',{sessionId:done.id,turnId:done.turns[0].id});
  const captured=await workspace.api('captures?sourceCategory=uncategorized');
  assert.deepEqual(captured.sourceCategories,[{value:'uncategorized',label:'其他笔记'}]);
  assert.equal(captured.captures.length,1);
});
test('shared sessions preserve provenance, recommendations, captures and refresh recovery',async()=>{
  const {workspace,options}=fixture();
  const started=await workspace.api('session-start',{pageIds:['a'],batch:true});
  const s=await settled(workspace,started.id);
  assert.equal(s.status,'ready'); assert.equal(s.turns[0].status,'done'); assert.equal(s.directions.length,1); assert.equal(s.proposals.length,1);
  const saved=await workspace.api('capture-add',{sessionId:s.id,turnId:s.turns[0].id});
  assert.equal(saved.capture.sources[0].hash,'hash-a');
  await workspace.api('capture-update',{captureId:saved.capture.id,title:'整理后的结论',category:'方法',conclusion:'经过用户整理的测试结论。'});
  const restored=create(options);
  assert.equal((await restored.api('sessions')).sessions.length,1);
  const captures=await restored.api('captures?q=整理后&category=方法&sourceCategory=知识');
  assert.equal(captures.captures.length,1); assert.equal(captures.captures[0].answer,'这是已完成的测试回答。');
  const continued=await restored.api('session-message',{sessionId:s.id,directionId:s.directions[0].id,captureId:saved.capture.id});
  assert.equal((await settled(restored,continued.id)).turns.length,2);
});
test('unconfirmed content never creates patches and stale previews cannot write',async()=>{
  const {workspace,options}=fixture();
  const s=await settled(workspace,(await workspace.api('session-start',{pageIds:['a']})).id);
  const proposal=s.proposals[0];
  const p=await workspace.api('session-preview',{sessionId:s.id,proposalId:proposal.id,targetPageId:'a',title:proposal.title,body:proposal.body});
  assert.equal((await workspace.exportData()).patches.length,0);
  const original=options.source; options.source=async p=>({hash:'changed',text});
  await assert.rejects(workspace.api('session-confirm',{transactionId:p.transactionId}),/变化/);
  assert.equal((await workspace.exportData()).patches.length,0);
  options.source=original;
  await workspace.api('session-confirm',{transactionId:p.transactionId});
  const output=await workspace.exportData(); assert.equal(output.patches.length,1); assert.equal(output.sessions[0].proposals[0].status,'local');
  await assert.rejects(workspace.api('session-confirm',{transactionId:p.transactionId}),/失效/);
});
test('cancelled generations keep partial content without permitting capture',async()=>{
  const {workspace}=fixture(async(messages,chunk,signal)=>{chunk('未完成的部分回答'); return new Promise((resolve,reject)=>{signal.addEventListener('abort',()=>reject(new DOMException('stopped','AbortError')),{once:true});});});
  const s=await workspace.api('session-start',{pageIds:['a']});
  await workspace.api('session-cancel',{sessionId:s.id});
  const result=await settled(workspace,s.id);
  assert.equal(result.status,'interrupted'); assert.equal(result.turns[0].status,'failed');
  await assert.rejects(workspace.api('capture-add',{sessionId:s.id,turnId:result.turns[0].id}),/已完成/);
});
test('relations require real evidence and preview before removal; context uses actual links',async()=>{
  const {workspace}=fixture();
  await assert.rejects(workspace.api('preview',{kind:'relation',pageId:'a',expectedHash:'hash-a',targetId:'b',relationType:'supports',confidence:.8,evidence:'并不存在的原文证据'}),/原文/);
  const p=await workspace.api('preview',{kind:'relation',pageId:'a',expectedHash:'hash-a',targetId:'b',relationType:'supports',confidence:.8,evidence:'这是已保存的真实来源测试片段。'});
  await workspace.api('confirm',{transactionId:p.transactionId});
  assert.match((await workspace.api('action',{action:'context',pageId:'a'})).text,/乙/);
  const r=(await workspace.api('status')).relations[0];
  const removal=await workspace.api('preview-removal',{relationId:r.id});
  assert.equal((await workspace.api('status')).relations.length,1);
  await workspace.api('confirm-removal',{transactionId:removal.transactionId});
  assert.equal((await workspace.api('status')).relations.length,0);
});
test('worker settings affect actual batch concurrency and all sources are analyzed',async()=>{
  let running=0,maximum=0,calls=0;
  const {workspace}=fixture(async(messages,chunk)=>{if(messages[0].content.includes('只返回 JSON：')) return '{}'; running++; maximum=Math.max(running,maximum); calls++; await new Promise(resolve=>setImmediate(resolve)); running--; chunk('已完成分析'); return '已完成分析';});
  await workspace.api('action',{action:'workers',maxWorkers:1});
  const started=await workspace.api('session-start',{pageIds:['a','b'],batch:true});
  await settled(workspace,started.id); assert.equal(maximum,1); assert.equal(calls,3);
  assert.equal((await workspace.api('page?pageId=b')).analysis.summary,'已完成分析');
});
test('backup import rejects other wikis and merges without replacing current records',async()=>{
  const {workspace}=fixture(); await settled(workspace,(await workspace.api('session-start',{pageIds:['a']})).id);
  const backup=await workspace.exportData();
  await assert.rejects(workspace.importData({...backup,workspaceId:'other-wiki'}),/不匹配/);
  backup.sessions[0].turns[0].answer='试图覆盖原回答'; await workspace.importData(backup);
  assert.equal((await workspace.exportData()).sessions[0].turns[0].answer,'这是已完成的测试回答。');
});
test('sync acknowledgement preserves history and prevents repeated Org additions',async()=>{
  const {workspace}=fixture(); const s=await settled(workspace,(await workspace.api('session-start',{pageIds:['a']})).id);
  const proposal=s.proposals[0], preview=await workspace.api('session-preview',{sessionId:s.id,proposalId:proposal.id,targetPageId:'a',title:proposal.title,body:proposal.body});
  await workspace.api('session-confirm',{transactionId:preview.transactionId});
  const patch=(await workspace.exportData()).patches[0];
  await workspace.acknowledge({syncedPatchIds:[patch.id],sourceHashes:{a:'new-version'}});
  const result=await workspace.exportData(); assert.equal(result.patches[0].synced,true); assert.equal(result.sessions[0].sources[0].hash,'new-version');
  assert.equal(result.sessions[0].proposals[0].status,'saved');
  const original=result.sessions[0].sources[0].text;
  await workspace.acknowledge({syncedPatchIds:[patch.id],sourceHashes:{a:'new-version'}});
  assert.equal((await workspace.exportData()).sessions[0].sources[0].text,original);
});
test('a transferred backup restores saved analyses, queue and interrupted session state',async()=>{
  const {workspace}=fixture(); await settled(workspace,(await workspace.api('session-start',{pageIds:['a'],batch:true})).id);
  const backup=await workspace.exportData(); backup.sessions[0].status='streaming'; backup.sessions[0].turns[0].status='streaming';
  const destination=fixture().workspace; await destination.importData(backup);
  assert.equal((await destination.api('page?pageId=a')).analysis.summary,'这是已完成的测试回答。');
  const result=await destination.api('session?sessionId='+backup.sessions[0].id);
  assert.equal(result.status,'interrupted'); assert.equal(result.turns[0].status,'failed');
});
