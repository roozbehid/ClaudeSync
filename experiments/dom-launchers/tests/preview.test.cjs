const test=require('node:test');const assert=require('node:assert/strict');
const {readFileSync}=require('node:fs');const path=require('node:path');const {JSDOM}=require('jsdom');
test('generated comparison runs the production UI and DOM delegation with fixture accounts',async()=>{
  const html=readFileSync(path.join(__dirname,'../../../docs/history-sync-preview.html'),'utf8');
  const source=html.split('<script type="module">')[1].split('</script>')[0];
  const dom=new JSDOM(html,{url:'https://claude.ai/code/fixture',runScripts:'outside-only'});
  try {
    await dom.window.eval('(async()=>{'+source+'})()');
    const doc=dom.window.document;
    assert.match(doc.querySelector('#band').textContent,/History sync · Prompt/);
    assert.match(doc.querySelector('#mode').textContent,/History sync · Mode/);
    assert.match(doc.querySelector('#hint').textContent,/History sync · Hint/);
    assert.equal(dom.window.__historySyncDomLaunchers.snapshot().ready,true);
    doc.querySelector('[data-history-sync-dom="sidebar"]').shadowRoot.querySelector('button').click();
    assert.equal(doc.querySelector('#menu').hidden,false);
    assert.match(doc.querySelector('#pane').textContent,/current@example.test/);
    await new Promise(resolve=>setTimeout(resolve,450)); // Opening settings refreshes fixture profiles.
    const next=[...doc.querySelectorAll('#pane button')].find(node=>node.textContent==='Continue to Sync');next.click();
    await new Promise(resolve=>setTimeout(resolve,450));
    const preview=[...doc.querySelectorAll('#pane button')].find(node=>node.textContent==='Preview');preview.click();
    await new Promise(resolve=>setTimeout(resolve,450));
    assert.match(doc.querySelector('#pane').textContent,/Old release plan/);
    assert.match(doc.querySelector('#pane').textContent,/Release planning/);
    const archived=[...doc.querySelectorAll('#pane button')].find(node=>node.textContent==='Archived');archived.click();
    await new Promise(resolve=>setImmediate(resolve));
    assert.ok(!doc.querySelector('#pane').textContent.includes('New project ideas'));
    const accounts=[...doc.querySelectorAll('#pane button')].find(node=>node.textContent==='Accounts');accounts.click();
    await new Promise(resolve=>setImmediate(resolve));
    const location=[...doc.querySelectorAll('#pane select')].find(node=>node.parentElement.textContent.startsWith('Launcher placement'));
    location.value='mode';location.dispatchEvent(new dom.window.Event('change'));
    await new Promise(resolve=>setTimeout(resolve,450));
    assert.equal(doc.querySelector('#band button'),null);
    assert.ok(doc.querySelector('#mode button'));
    assert.equal(doc.querySelector('#hint button'),null);
    assert.ok(!doc.querySelector('#operations').textContent.includes('Sync'));
  } finally {dom.window.__historySyncDomLaunchers?.dispose();dom.window.close();}
});
