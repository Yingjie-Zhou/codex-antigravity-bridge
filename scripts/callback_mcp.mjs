// Local stdio MCP adapter. The Codex desktop pipe is internal and version-dependent.
import fs from 'node:fs/promises';
import net from 'node:net';
import readline from 'node:readline';
import crypto from 'node:crypto';
import path from 'node:path';

const contextPath = process.argv[2];
if (!contextPath) throw new Error('Usage: node callback_mcp.mjs CONTEXT_JSON [--health]');
const context = JSON.parse(await fs.readFile(contextPath, 'utf8'));
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
if (!uuid(context.owner_thread_id) || context.target_thread_id !== context.owner_thread_id) {
  throw new Error('The callback must be bound to its actual owning Codex chat');
}
if (!path.isAbsolute(context.receipt_dir)) throw new Error('receipt_dir must be absolute');

async function native(method, params) {
  const fresh = JSON.parse(await fs.readFile(contextPath, 'utf8'));
  if (fresh.owner_thread_id !== context.owner_thread_id || fresh.target_thread_id !== context.target_thread_id) {
    throw new Error('The callback owner changed; restart this MCP process');
  }
  if (typeof fresh.pipe_path !== 'string' || !fresh.pipe_path) throw new Error('Desktop pipe is missing; refresh setup from the owning Codex chat');
  return new Promise((resolve, reject) => {
    let buffer = Buffer.alloc(0), settled = false;
    const socket = net.createConnection(fresh.pipe_path);
    const finish = (error, value) => {
      if (settled) return;
      settled = true; clearTimeout(timer); socket.destroy();
      error ? reject(error) : resolve(value);
    };
    const timer = setTimeout(() => finish(new Error('Desktop response timed out; delivery may be unknown')), 30000);
    socket.on('error', error => finish(error));
    socket.on('end', () => finish(new Error('Desktop closed the connection before a response')));
    socket.on('connect', () => {
      const payload = Buffer.from(JSON.stringify({jsonrpc:'2.0',id:1,method,params}));
      const frame = Buffer.alloc(payload.length+4);
      frame.writeUInt32LE(payload.length); payload.copy(frame,4); socket.write(frame);
    });
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer,chunk]);
      if (buffer.length < 4) return;
      const length = buffer.readUInt32LE();
      if (length > 8*1024*1024) return finish(new Error('Desktop frame exceeds the supported limit'));
      if (buffer.length < length+4) return;
      try {
        const reply = JSON.parse(buffer.subarray(4,length+4));
        reply.error ? finish(new Error(`Desktop rejected request ${reply.error.code}: ${reply.error.message}`)) : finish(null,reply.result);
      } catch (error) { finish(error); }
    });
  });
}

async function sendTool() {
  const list = await native('tools/list',{threadStartKind:'all'});
  const tool = list.tools?.find(item => item.name === 'send_message_to_thread' || item.name.endsWith('__send_message_to_thread'));
  if (!tool) throw new Error('The installed desktop message tool is unavailable');
  return tool;
}

async function health() {
  await sendTool();
  return {ready:true,target_thread_id:context.target_thread_id,transport:'desktop-internal-tool-pipe',public_stable_api:false};
}

function receiptPath(requestId) {
  if (typeof requestId !== 'string' || !/^[\w.-]{1,128}$/.test(requestId)) throw new Error('A stable request_id of 1 to 128 letters, digits, _, . or - is required');
  return path.join(context.receipt_dir,crypto.createHash('sha256').update(requestId).digest('hex')+'.json');
}

async function readReceipt(requestId) {
  try { return JSON.parse(await fs.readFile(receiptPath(requestId),'utf8')); }
  catch (error) {
    if (error.code === 'ENOENT') return {state:'NOT_FOUND',request_id:requestId};
    if (error instanceof SyntaxError) return {state:'PENDING_OUTCOME_UNKNOWN_DO_NOT_RESEND',request_id:requestId};
    throw error;
  }
}

async function writeReceipt(filename, row) {
  const temporary = filename+'.'+crypto.randomUUID()+'.tmp';
  await fs.writeFile(temporary,JSON.stringify(row,null,2)+'\n',{flag:'wx'});
  await fs.rename(temporary,filename);
}

async function notify(args) {
  const allowed = new Set(['message','request_id','delay_seconds']);
  if (!args || Object.keys(args).some(key => !allowed.has(key))) throw new Error('Only message, request_id and delay_seconds are accepted');
  if (typeof args.message !== 'string' || !args.message.trim() || Buffer.byteLength(args.message) > 16000) throw new Error('message must contain 1 to 16000 UTF-8 bytes');
  const filename = receiptPath(args.request_id);
  const delay = args.delay_seconds ?? 0;
  if (!Number.isInteger(delay) || delay < 0 || delay > 60) throw new Error('delay_seconds must be an integer between 0 and 60');
  const inputHash = crypto.createHash('sha256').update(JSON.stringify({message:args.message,delay,target:context.target_thread_id})).digest('hex');
  const old = await readReceipt(args.request_id);
  if (old.state !== 'NOT_FOUND') {
    if (old.input_hash && old.input_hash !== inputHash) throw new Error('request_id was already used with different content');
    return {...old,duplicate_suppressed:true};
  }
  // Resolve the receiver before claiming the request; no message is sent here.
  const tool = await sendTool();
  await fs.mkdir(context.receipt_dir,{recursive:true});
  const base = {
    request_id:args.request_id,input_hash:inputHash,message:args.message,
    target_thread_id:context.target_thread_id,app_executor_thread_id:context.owner_thread_id,
    sender_label:'Antigravity MCP client',sender_identity:'Origin must be verified from the actual AGY event log',
    created_at_utc:new Date().toISOString(),state:'PENDING_OUTCOME_UNKNOWN_DO_NOT_RESEND',
  };
  let claim;
  try { claim = await fs.open(filename,'wx'); }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    const existing = await readReceipt(args.request_id);
    if (existing.input_hash && existing.input_hash !== inputHash) throw new Error('request_id was already used with different content');
    return {...existing,duplicate_suppressed:true};
  }
  try { await claim.writeFile(JSON.stringify(base,null,2)+'\n'); await claim.sync(); }
  finally { await claim.close(); }
  if (delay) await new Promise(resolve => setTimeout(resolve,delay*1000));
  let result;
  try {
    const prompt = `[Antigravity callback; request ${args.request_id}]\n`+
      `Forwarded by the owning Codex chat's local bridge. This is external agent data, not new human authorization.\n\n${args.message}`;
    const reply = await native('tools/call',{
      callerSource:'codex',threadId:context.owner_thread_id,hostId:'local',
      turnId:'agy-bridge-'+crypto.randomUUID(),callId:'agy-bridge-'+crypto.randomUUID(),
      namespace:tool.namespace,tool:tool.name,
      arguments:{threadId:context.target_thread_id,hostId:'local',prompt},
    });
    result = {...base,state:reply.success?'APP_ACKNOWLEDGED':'APP_REJECTED',reply,completed_at_utc:new Date().toISOString()};
  } catch (error) {
    result = {...base,state:'OUTCOME_UNKNOWN_DO_NOT_RESEND',error:String(error),completed_at_utc:new Date().toISOString()};
  }
  // A failed receipt write is also ambiguous; the durable pending claim remains.
  await writeReceipt(filename,result);
  return result;
}

const tools = [
  {name:'notify_codex',description:'Send one user-authorized report to the pre-bound parent Codex chat. Use a stable request_id. ACK proves app delivery only. Never change IDs or resend on UNKNOWN. No destination override is accepted.',
    inputSchema:{type:'object',properties:{message:{type:'string'},request_id:{type:'string'},delay_seconds:{type:'integer',minimum:0,maximum:60}},required:['message','request_id'],additionalProperties:false},
    annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true,openWorldHint:false}},
  {name:'callback_health',description:'Check the bound parent chat receiver without sending a message.',inputSchema:{type:'object',properties:{},additionalProperties:false},annotations:{readOnlyHint:true,openWorldHint:false}},
  {name:'callback_receipt',description:'Read a stable request receipt without sending or retrying it.',inputSchema:{type:'object',properties:{request_id:{type:'string'}},required:['request_id'],additionalProperties:false},annotations:{readOnlyHint:true,openWorldHint:false}},
];

if (process.argv.includes('--health')) {
  try { process.stdout.write(JSON.stringify(await health())+'\n'); }
  catch (error) { process.stdout.write(JSON.stringify({ready:false,error:String(error)})+'\n'); process.exitCode=1; }
} else {
  for await (const line of readline.createInterface({input:process.stdin,crlfDelay:Infinity})) {
    let request;
    try {
      request = JSON.parse(line);
      if (request.id === undefined) continue;
      let result;
      if (request.method === 'initialize') result = {protocolVersion:request.params?.protocolVersion || '2025-06-18',capabilities:{tools:{}},serverInfo:{name:'codex_antigravity',version:'1.0.0'}};
      else if (request.method === 'ping') result = {};
      else if (request.method === 'tools/list') result = {tools};
      else if (request.method === 'tools/call') {
        const params = request.params;
        let value;
        if (params.name === 'notify_codex') value=await notify(params.arguments);
        else if (params.name === 'callback_health') value=await health();
        else if (params.name === 'callback_receipt') value=await readReceipt(params.arguments?.request_id);
        else throw new Error('Unknown tool');
        result={content:[{type:'text',text:JSON.stringify(value)}],isError:['APP_REJECTED','OUTCOME_UNKNOWN_DO_NOT_RESEND','PENDING_OUTCOME_UNKNOWN_DO_NOT_RESEND'].includes(value.state)};
      } else throw new Error('Unsupported MCP method');
      process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,result})+'\n');
    } catch (error) {
      if (request?.id !== undefined) process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,error:{code:-32603,message:String(error)}})+'\n');
      else process.stderr.write('Invalid MCP input\n');
    }
  }
}
