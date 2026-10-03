const {test}=require('node:test');
const assert=require('node:assert/strict');
const ai=require('../resources/org-museum-ai-browser.js');
const config={endpoint:'http://localhost:1234/v1',model:'real-service-model',provider:'compatible',key:'fixture-secret'};
function streamed(chunks,type='text/event-stream') {
  return new Response(new ReadableStream({start(controller){
    chunks.forEach(chunk=>controller.enqueue(new TextEncoder().encode(chunk))); controller.close();
  }}),{headers:{'content-type':type}});
}
test('model catalog and credentials use the selected service only',async()=>{
  let request;
  const models=await ai.models(config,null,async(url,options)=>{
    request={url,options}; return Response.json({data:[{id:'model-a'},{id:'model-b'}]});
  });
  assert.deepEqual(models,['model-a','model-b']);
  assert.equal(request.url,'http://localhost:1234/v1/models');
  assert.equal(request.options.headers.Authorization,'Bearer fixture-secret');
  assert.equal(request.options.credentials,'omit');
  assert.throws(()=>ai.base({...config,endpoint:'file:///secret'}));
  assert.throws(()=>ai.base({...config,endpoint:'https://user:password@example.test/v1'}));
});
test('compatible streaming handles chunk boundaries, unicode and completion',async()=>{
  const data='data: '+JSON.stringify({choices:[{delta:{content:'你好'}}]})+'\r\n\r\n'+
    'data: '+JSON.stringify({choices:[{delta:{content:'，世界'},finish_reason:'stop'}]})+'\n\n'+'data: [DONE]\n\n';
  const parts=[data.slice(0,7),data.slice(7,45),data.slice(45)];
  const output=[]; let body;
  const answer=await ai.chat(config,[{role:'user',content:'test'}],text=>output.push(text),null,async(_url,options)=>{
    body=JSON.parse(options.body); return streamed(parts);
  });
  assert.equal(answer,'你好，世界'); assert.equal(output.at(-1),answer);
  assert.equal(body.stream,true); assert.equal(body.model,config.model);
});
test('Ollama models and NDJSON use native endpoints',async()=>{
  const ollama={...config,key:'',provider:'ollama',endpoint:'http://localhost:11434'};
  const models=await ai.models(ollama,null,async url=>{
    assert.equal(url,'http://localhost:11434/api/tags'); return Response.json({models:[{name:'local-model'}]});
  }); assert.deepEqual(models,['local-model']);
  const answer=await ai.chat(ollama,[],()=>{},null,async url=>{
    assert.equal(url,'http://localhost:11434/api/chat');
    return streamed(['{"message":{"content":"A"},"done":false}\n{"message":',
      '{"content":"B"},"done":true}'],'application/x-ndjson');
  }); assert.equal(answer,'AB');
});
test('HTTP errors, interrupted streams and cancellation never report success',async()=>{
  await assert.rejects(ai.models(config,null,async()=>Response.json({error:{message:'invalid key'}},{status:401})),/401.*invalid key/);
  await assert.rejects(ai.chat(config,[],()=>{},null,async()=>streamed(['data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'])),/提前中断/);
  const controller=new AbortController();controller.abort();
  await assert.rejects(ai.chat(config,[],()=>{},controller.signal,async()=>streamed([])),{name:'AbortError'});
});
