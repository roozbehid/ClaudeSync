import {readFile} from 'node:fs/promises';
import {setTimeout as delay} from 'node:timers/promises';
import {pathToFileURL} from 'node:url';

export function eligibleTarget(target) {
  try {
    const url = new URL(target.url);
    return ['page','webview'].includes(target.type) && url.protocol === 'https:' &&
      ['claude.ai','claude.com','preview.claude.ai'].includes(url.hostname);
  } catch {return false;}
}
export function validateDebuggerUrl(value, port) {
  const url = new URL(value);
  if (url.protocol !== 'ws:' || url.hostname !== '127.0.0.1' || Number(url.port) !== port || url.username || url.password) throw new Error('Debugger endpoint must stay on the selected loopback port.');
  return url.href;
}
export async function connect(value, port) {
  const socket = new WebSocket(validateDebuggerUrl(value,port));
  const pending = new Map();let sequence=0, destroyed=false;
  socket.addEventListener('message', event => {
    const message=JSON.parse(String(event.data));
    if (message.method === 'Runtime.executionContextsCleared') destroyed=true;
    const entry=pending.get(message.id);if(!entry)return;pending.delete(message.id);clearTimeout(entry.timer);
    if(message.error)entry.reject(new Error(message.error.message));else entry.resolve(message.result);
  });
  socket.addEventListener('close',()=>{for(const entry of pending.values()){clearTimeout(entry.timer);entry.reject(new Error('Desktop target closed'));}pending.clear();});
  await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{socket.close();reject(new Error('Debugger connection timed out'));},5000);
    socket.addEventListener('open',()=>{clearTimeout(timer);resolve();},{once:true});
    socket.addEventListener('error',()=>{clearTimeout(timer);reject(new Error('Debugger connection failed'));},{once:true});});
  const rpc=(method,params={})=>new Promise((resolve,reject)=>{
    const id=++sequence;const timer=setTimeout(()=>{pending.delete(id);reject(new Error('Debugger request timed out'));},5000);
    pending.set(id,{resolve,reject,timer});socket.send(JSON.stringify({id,method,params}));
  });
  await rpc('Runtime.enable');
  return {rpc, get stale(){return destroyed||socket.readyState!==WebSocket.OPEN;}, close(){socket.close();}};
}
async function main() {
  const args=process.argv.slice(2), port=Number(args[args.indexOf('--port')+1]);
  if(!Number.isInteger(port)||port<1024||port>65535)throw new Error('Pass --port with the Desktop comparison port.');
  const remove=args.includes('--remove');
  const source=await readFile(new URL('./renderer.js',import.meta.url),'utf8');
  const connections=new Map();let stopping=false, everConnected=false;
  process.once('SIGINT',()=>{stopping=true;});process.once('SIGTERM',()=>{stopping=true;});
  async function targets() {
    const response=await fetch(`http://127.0.0.1:${port}/json/list`,{signal:AbortSignal.timeout(3000),redirect:'error'});
    if(!response.ok)throw new Error('Desktop debugging endpoint did not respond.');
    const items=await response.json();return items.filter(eligibleTarget);
  }
  async function dispose(connection) {
    try{await connection.rpc('Runtime.evaluate',{expression:'globalThis.__historySyncDomLaunchers?.dispose(); delete globalThis.__historySyncDomLaunchers;',returnByValue:true});}catch{}
    connection.close();
  }
  try {
    for(let attempts=0;!stopping;attempts++) {
      let list;
      try {list=await targets();} catch(error) {
        if(everConnected)break;
        if(attempts>20)throw new Error('Desktop did not expose its DevTools endpoint. This build may reject the startup flag. No installed files were changed.');
        await delay(1000);continue;
      }
      const live=new Set(list.map(t=>t.id));
      for(const [id,connection] of connections)if(!live.has(id)||connection.stale){connection.close();connections.delete(id);}
      for(const target of list) {
        if(connections.has(target.id))continue;
        const connection=await connect(target.webSocketDebuggerUrl,port);
        if(remove){await dispose(connection);continue;}
        try {
          const result=await connection.rpc('Runtime.evaluate',{expression:source+'\n;globalThis.__historySyncDomLaunchers.snapshot();',returnByValue:true});
          if(result.exceptionDetails)throw new Error(result.exceptionDetails.text || 'DOM launcher injection failed');
          connections.set(target.id,connection);everConnected=true;
          console.log('DOM launchers attached:',JSON.stringify(result.result?.value));
        } catch(error){connection.close();throw error;}
      }
      if(remove)break;
      if(!list.length&&attempts===0)console.log('Waiting for the Claude Desktop page.');
      await delay(1500);
    }
  } finally {for(const connection of connections.values())await dispose(connection);}
  console.log('DOM launchers removed. Restart Desktop normally to close its temporary debugging endpoint.');
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url)main().catch(error=>{console.error(error.message);process.exitCode=1;});
