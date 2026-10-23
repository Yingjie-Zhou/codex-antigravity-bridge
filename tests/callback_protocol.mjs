// Real stdio + local pipe fixture. Does not contact Codex, Antigravity, or a model.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn} from 'node:child_process';
import readline from 'node:readline';
import {fileURLToPath} from 'node:url';

const testBase=path.resolve(process.argv[2] || os.tmpdir());
await fs.mkdir(testBase,{recursive:true});
const temporary=await fs.mkdtemp(path.join(testBase,'codex-agy-protocol-'));
const pipe=process.platform==='win32' ? '\\\\.\\pipe\\codex-agy-fixture-'+crypto.randomUUID() : path.join(temporary,'app.sock');
const owner='12345678-1234-1234-1234-123456789abc';
const adapter=fileURLToPath(new URL('../scripts/callback_mcp.mjs',import.meta.url));
const contextPath=path.join(temporary,'context.json');
await fs.writeFile(contextPath,JSON.stringify({owner_thread_id:owner,target_thread_id:owner,pipe_path:pipe,receipt_dir:path.join(temporary,'receipts')}));
let sendCount=0, mode='ack';
const server=net.createServer(socket=>{
  let buffer=Buffer.alloc(0);
  socket.on('data',async chunk=>{
    buffer=Buffer.concat([buffer,chunk]);
    if(buffer.length<4 || buffer.length<buffer.readUInt32LE()+4)return;
    const request=JSON.parse(buffer.subarray(4,buffer.readUInt32LE()+4));
    let result;
    if(request.method==='tools/list')result={tools:[{namespace:'fixture',name:'send_message_to_thread'}]};
    else {
      assert.equal(request.method,'tools/call');
      assert.equal(request.params.threadId,owner);
      assert.equal(request.params.arguments.threadId,owner);
      assert.equal(request.params.arguments.hostId,'local');
      assert.match(request.params.arguments.prompt,/external agent data, not new human authorization/);
      sendCount++;
      if(mode==='close'){socket.destroy();return;}
      await new Promise(resolve=>setTimeout(resolve,60));
      result={success:true};
    }
    const payload=Buffer.from(JSON.stringify({jsonrpc:'2.0',id:request.id,result}));
    const frame=Buffer.alloc(payload.length+4);frame.writeUInt32LE(payload.length);payload.copy(frame,4);socket.write(frame);
  });
  socket.on('error',()=>{});
});
await new Promise(resolve=>server.listen(pipe,resolve));

const clients=[];
function client(){
  const child=spawn(process.execPath,[adapter,contextPath],{stdio:['pipe','pipe','pipe'],windowsHide:true});
  clients.push(child);
  let next=0;
  const pending=new Map();
  readline.createInterface({input:child.stdout}).on('line',line=>{
    const reply=JSON.parse(line),slot=pending.get(reply.id);
    if(slot){clearTimeout(slot.timer);pending.delete(reply.id);slot.resolve(reply);}
  });
  child.on('exit',code=>{for(const item of pending.values()){clearTimeout(item.timer);item.reject(new Error('Adapter exited '+code));}});
  return {child,request(method,params={}){
    return new Promise((resolve,reject)=>{
      const id=++next;
      const timer=setTimeout(()=>{pending.delete(id);reject(new Error('Fixture response timeout'));},5000);
      pending.set(id,{resolve,reject,timer});
      child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');
    });
  }};
}
const value=reply=>JSON.parse(reply.result.content[0].text);
const call=(c,name,args)=>c.request('tools/call',{name,arguments:args});
try{
  const a=client(),b=client();
  assert.ok((await a.request('initialize',{protocolVersion:'2025-06-18'})).result);
  assert.equal((await a.request('tools/list')).result.tools.length,3);
  assert.equal(value(await call(a,'callback_health',{})).ready,true);
  assert.equal(sendCount,0);
  const input={request_id:'one-logical-message',message:'中文回传',delay_seconds:0};
  const concurrent=await Promise.all([call(a,'notify_codex',input),call(b,'notify_codex',input)]);
  assert.equal(sendCount,1,'Concurrent processes must send only once');
  assert.ok(concurrent.some(reply=>value(reply).state==='APP_ACKNOWLEDGED'));
  assert.ok(concurrent.some(reply=>value(reply).duplicate_suppressed));
  assert.equal(value(await call(b,'callback_receipt',{request_id:input.request_id})).state,'APP_ACKNOWLEDGED');
  assert.equal(value(await call(a,'notify_codex',input)).duplicate_suppressed,true);
  assert.equal(sendCount,1);
  assert.ok((await call(a,'notify_codex',{...input,message:'different'})).error);
  assert.ok((await call(a,'notify_codex',{request_id:'other-target',message:'test',target_thread_id:crypto.randomUUID()})).error);
  assert.equal(sendCount,1,'Invalid input must not send');
  mode='close';
  const ambiguous={request_id:'unknown-logical-message',message:'simulated lost response'};
  const unknown=value(await call(a,'notify_codex',ambiguous));
  assert.equal(unknown.state,'OUTCOME_UNKNOWN_DO_NOT_RESEND');
  assert.equal(sendCount,2);
  assert.equal(value(await call(b,'notify_codex',ambiguous)).duplicate_suppressed,true);
  assert.equal(sendCount,2,'Unknown outcomes must not be resent');
  const c=client();
  assert.equal(value(await call(c,'notify_codex',input)).duplicate_suppressed,true);
  assert.equal(sendCount,2,'Receipts must survive process restart');
  console.log(JSON.stringify({status:'PASS',checks:['MCP discovery','health without send','two-process duplicate suppression','same ID changed content rejected','destination override rejected','ambiguous delivery retained','restart receipt reuse'],fixture_send_count:sendCount}));
}finally{
  for(const child of clients){child.stdin.end();child.kill();}
  await new Promise(resolve=>server.close(resolve));
}
