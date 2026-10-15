const test=require('node:test');const assert=require('node:assert/strict');
test('loader accepts only Claude HTTPS page targets',async()=>{
  const {eligibleTarget}=await import('../Attach-DesktopDom.mjs');
  assert.equal(eligibleTarget({type:'page',url:'https://claude.ai/code/fixture'}),true);
  assert.equal(eligibleTarget({type:'webview',url:'https://claude.com/'}),true);
  for(const url of ['https://claude.ai.evil.test/','https://evil.test/','http://claude.ai/','file:///C:/fixture.html','invalid'])assert.equal(eligibleTarget({type:'page',url}),false);
  assert.equal(eligibleTarget({type:'service_worker',url:'https://claude.ai/'}),false);
});
test('loader refuses foreign hosts, ports, credentials, and protocols',async()=>{
  const {validateDebuggerUrl}=await import('../Attach-DesktopDom.mjs');
  assert.equal(validateDebuggerUrl('ws://127.0.0.1:9333/devtools/page/fixture',9333),'ws://127.0.0.1:9333/devtools/page/fixture');
  for(const url of ['ws://evil.test:9333/','ws://127.0.0.1:9334/','wss://127.0.0.1:9333/','ws://user:pass@127.0.0.1:9333/'])assert.throws(()=>validateDebuggerUrl(url,9333),/loopback/);
});
