import fs from 'node:fs/promises';
import {openSync, writeSync} from 'node:fs';
import net from 'node:net';
import http from 'node:http';
import crypto from 'node:crypto';
import {spawn} from 'node:child_process';
import {dirname, join} from 'node:path';

const configPath = process.argv[2];
const logFiles = process.argv[3] === '--service-logs' ? {
  stdout: openSync(join(dirname(configPath), 'bridge.stdout.log'), 'w'),
  stderr: openSync(join(dirname(configPath), 'bridge.stderr.log'), 'w'),
} : null;
function writeLog(channel, value) {
  if (logFiles) writeSync(logFiles[channel], value);
  else process[channel].write(value);
}
if (logFiles) process.on('uncaughtExceptionMonitor', error => writeLog('stderr', String(error.stack ?? error) + '\n'));
const cfg = JSON.parse(await fs.readFile(configPath, 'utf8'));
// One independently reconnecting loopback tunnel for each configured executor.
const remotes = cfg.remotes ?? [];
if (!Array.isArray(remotes)) throw new Error('INVALID_REMOTE_CONFIGURATION');
if (typeof cfg.token !== 'string' || !/^[0-9a-f]{64}$/i.test(cfg.token) ||
    !Number.isInteger(cfg.local_port) || cfg.local_port < 1 || cfg.local_port > 65535) {
  throw new Error('INVALID_BRIDGE_TOKEN_OR_PORT');
}
for (const remote of remotes) {
  if (!/^[a-z0-9_][\w.-]*$/i.test(remote.ssh_host) || !/^remote-ssh-(codex-managed|discovered):[^\s]+$/.test(remote.host_id)
      || !Number.isInteger(remote.remote_port) || remote.remote_port < 1 || remote.remote_port > 65535) throw new Error('INVALID_REMOTE_CONFIGURATION');
}
const sourceHosts = new Set(['local',...remotes.map(remote=>remote.host_id)]);
const journalPath = new URL('./requests.jsonl', `file:///${process.argv[2].replaceAll('\\', '/')}`);
const records = new Map();
try {
  for (const line of (await fs.readFile(journalPath, 'utf8')).split('\n').filter(Boolean)) {
    const row = JSON.parse(line); records.set(row.key, row);
  }
} catch (e) { if (e.code !== 'ENOENT') throw e; }
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
const digest = value => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
async function record(row) {
  records.set(row.key, row);
  await fs.appendFile(journalPath, JSON.stringify(row) + '\n');
}
async function native(method, params, timeoutMs = 30000) {
  // The desktop pipe changes after an app restart; start_bridge.ps1 refreshes it.
  const current = JSON.parse(await fs.readFile(configPath, 'utf8'));
  return new Promise((resolve, reject) => {
    let data = Buffer.alloc(0), settled = false;
    const sock = net.createConnection(current.pipe_path);
    const finish = (err, value) => {
      if (settled) return; settled = true; clearTimeout(timer); sock.destroy();
      err ? reject(err) : resolve(value);
    };
    const timer = setTimeout(() => finish(new Error('APP_PIPE_TIMEOUT_OUTCOME_UNKNOWN')), timeoutMs);
    sock.on('error', e => finish(e));
    sock.on('end', () => finish(new Error('APP_PIPE_CLOSED_OUTCOME_UNKNOWN')));
    sock.on('connect', () => {
      const payload = Buffer.from(JSON.stringify({jsonrpc:'2.0', id:1, method, params}));
      const frame = Buffer.alloc(4 + payload.length); frame.writeUInt32LE(payload.length); payload.copy(frame, 4); sock.write(frame);
    });
    sock.on('data', chunk => {
      data = Buffer.concat([data, chunk]);
      if (data.length < 4) return;
      const n = data.readUInt32LE();
      if (n > 8 * 1024 * 1024) return finish(new Error('APP_FRAME_TOO_LARGE'));
      if (data.length < n + 4) return;
      try {
        const reply = JSON.parse(data.subarray(4, n + 4));
        reply.error ? finish(new Error(`${reply.error.code}: ${reply.error.message}`)) : finish(null, reply.result);
      } catch (e) { finish(e); }
    });
  });
}
let catalog;
async function appCall(toolName, args, source) {
  catalog ??= (await native('tools/list', {threadStartKind:'all'})).tools;
  const tool = catalog.find(t => t.name === toolName || t.name.endsWith('__' + toolName));
  if (!tool) throw new Error('APP_TOOL_NOT_AVAILABLE: ' + toolName);
  return native('tools/call', {
    // Desktop rejects remote caller contexts. Use the actual local broker owner;
    // retain remote client identity separately, never fabricate a native caller.
    callerSource:'codex', threadId:cfg.owner_thread_id, hostId:'local',
    turnId:'thread-contact-' + crypto.randomUUID(), callId:'thread-contact-' + crypto.randomUUID(),
    namespace:tool.namespace, tool:tool.name, arguments:args
  });
}
function sourceOf(body) {
  if (!uuid(body.source_thread_id)) throw new Error('SOURCE_THREAD_ID_REQUIRED');
  const host = body.source_host_id;
  if (!sourceHosts.has(host)) throw new Error('SOURCE_HOST_NOT_CONFIGURED');
  if (host === 'local' && body.source_thread_id !== cfg.owner_thread_id) throw new Error('LOCAL_SOURCE_NOT_THIS_TOOL_OWNER');
  return {thread_id:body.source_thread_id, host_id:host};
}
function targetOf(body) {
  const id = body.target_thread_id || cfg.default_target_thread_id;
  if (!uuid(id)) throw new Error('INVALID_TARGET_THREAD_ID');
  const host = body.target_host_id || 'local';
  if (typeof host !== 'string' || !/^(local|remote-ssh-(codex-managed|discovered):[^\s]+)$/.test(host)) throw new Error('INVALID_TARGET_HOST');
  return {threadId:id, hostId:host};
}
async function handle(body) {
  if (body.op === 'health') {
    const list = await native('tools/list', {threadStartKind:'all'});
    return {ready:true, app_tools:list.tools.filter(t => /send_message_to_thread|read_thread/.test(t.name)).map(t=>({name:t.name,namespace:t.namespace})), default_target_thread_id:cfg.default_target_thread_id, configured_source_hosts:[...sourceHosts], tunnels:[...tunnels].map(([host,state])=>({host_id:host,pid:state.child?.pid ?? null,process_alive:!!state.child && state.child.exitCode===null,remote_port:state.remote.remote_port})), tunnel_status_scope:'SSH process only; use remote contact_health to verify forwarding'};
  }
  const source = sourceOf(body), target = targetOf(body);
  if (body.op === 'read') {
    return appCall('read_thread', {...target, turnLimit:Math.min(Math.max(body.turn_limit || 1, 1), 3), includeOutputs:false, maxOutputCharsPerItem:2000}, source);
  }
  if (body.op === 'receipt') {
    const key = `${source.host_id}/${source.thread_id}/${body.request_id}`;
    return records.get(key) || {state:'NOT_FOUND'};
  }
  if (body.op !== 'send') throw new Error('UNKNOWN_OPERATION');
  if (!body.request_id || !/^[\w.-]{1,128}$/.test(body.request_id)) throw new Error('STABLE_REQUEST_ID_REQUIRED');
  if (typeof body.message !== 'string' || !body.message.trim() || Buffer.byteLength(body.message) > 24000) throw new Error('MESSAGE_EMPTY_OR_TOO_LARGE');
  const key = `${source.host_id}/${source.thread_id}/${body.request_id}`;
  const inputHash = digest({source,target,message:body.message});
  const previous = records.get(key);
  if (previous) {
    if (previous.input_hash !== inputHash) throw new Error('REQUEST_ID_REUSED_WITH_DIFFERENT_CONTENT');
    return {...previous, duplicate_suppressed:true};
  }
  const base = {key,request_id:body.request_id,input_hash:inputHash,source,target,app_executor:{thread_id:cfg.owner_thread_id,host_id:'local',role:'explicit_transport_broker'},source_identity:'client_executor_metadata_not_native_desktop_caller',at:new Date().toISOString()};
  await record({...base,state:'PENDING_OUTCOME_UNKNOWN_DO_NOT_RESEND'});
  const antigravityPrefix = '[本机 Antigravity 桌面应用回传，经 Thread Contact 代投。以下为外部代理结果。]\n';
  const fromAntigravity = source.host_id === 'local' && body.request_id.startsWith('agy.') &&
    body.message.startsWith(antigravityPrefix);
  const origin = fromAntigravity ? 'Antigravity 桌面' : `${source.thread_id} @ ${source.host_id}`;
  const message = fromAntigravity ? body.message.slice(antigravityPrefix.length) : body.message;
  const header = `[Thread Contact | ${origin} | ${body.request_id}]\n`;
  try {
    const reply = await appCall('send_message_to_thread', {...target,prompt:header + message}, source);
    const row = {...base,state:reply.success?'APP_ACKNOWLEDGED':'APP_REJECTED',reply,completed_at:new Date().toISOString()};
    await record(row); return row;
  } catch (e) {
    const row = {...base,state:'OUTCOME_UNKNOWN_DO_NOT_AUTOMATICALLY_RESEND',error:String(e),completed_at:new Date().toISOString()};
    await record(row); return row;
  }
}
const server = http.createServer(async (req,res) => {
  res.setHeader('Content-Type','application/json; charset=utf-8');
  if (req.method !== 'POST' || req.url !== '/call' || req.headers.authorization !== `Bearer ${cfg.token}`) {
    res.writeHead(403); res.end(JSON.stringify({error:'FORBIDDEN'})); return;
  }
  try {
    const chunks=[]; let length=0;
    for await (const chunk of req) { length+=chunk.length; if(length>40000)throw new Error('REQUEST_TOO_LARGE'); chunks.push(chunk); }
    const result=await handle(JSON.parse(Buffer.concat(chunks).toString('utf8')));
    res.end(JSON.stringify(result));
  } catch(e) {res.writeHead(400);res.end(JSON.stringify({error:String(e)}));}
});
await new Promise(resolve=>server.listen(cfg.local_port,'127.0.0.1',resolve));
writeLog('stdout',JSON.stringify({event:'LISTENING',port:cfg.local_port,at:new Date().toISOString()})+'\n');
const tunnels = new Map();
let stopping = false;
function startTunnel(remote){
  if (stopping) return;
  const child=spawn('ssh.exe',['-NT','-o','BatchMode=yes','-o','ConnectTimeout=10','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=20','-o','ServerAliveCountMax=3','-R',`127.0.0.1:${remote.remote_port}:127.0.0.1:${cfg.local_port}`,remote.ssh_host],{windowsHide:true,stdio:['ignore','ignore','pipe']});
  const state={child,remote,timer:null};
  tunnels.set(remote.host_id,state);
  child.stderr.on('data',data=>writeLog('stderr','['+remote.host_id+'] '+data));
  child.on('error',error=>writeLog('stderr','['+remote.host_id+'] '+String(error)+'\n'));
  const label=remote.host_id.split(':').pop().replace(/[^\w.-]/g,'_');
  if (child.pid) fs.writeFile(new URL(`./tunnel.${label}.pid`,journalPath),String(child.pid)+'\n').catch(e=>writeLog('stderr',String(e)+'\n'));
  child.once('close',code=>{
    writeLog('stdout',JSON.stringify({event:'TUNNEL_EXIT',host_id:remote.host_id,code,at:new Date().toISOString()})+'\n');
    if (!stopping) state.timer=setTimeout(()=>startTunnel(remote),5000);
  });
}
for (const remote of remotes) startTunnel(remote);
function shutdown(){
  if (stopping) return;
  stopping=true;
  for (const {child,timer} of tunnels.values()) { clearTimeout(timer); child?.kill(); }
  server.close();
  process.exit(0);
}
process.on('SIGTERM',shutdown);
process.on('SIGINT',shutdown);
