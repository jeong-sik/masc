const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(path.join(__dirname, '../connectors/browser/extension/background.js'), 'utf8');

function fixture() {
  let now = 1000, timerId = 0, url = 'https://example.org/source';
  const timers = new Map(), replies = [], injections = [];
  const event = () => {
    const listeners = new Set();
    return {addListener:f=>listeners.add(f), removeListener:f=>listeners.delete(f),
      emit(...args) { for (const f of [...listeners]) f(...args); },
      get size() { return listeners.size; }};
  };
  const committed = event(), fragment = event(), removed = event(), disconnected = event();
  const port = {onMessage:event(),onDisconnect:disconnected,postMessage:r=>replies.push(JSON.parse(JSON.stringify(r)))};
  const browser = {
    runtime:{connectNative:()=>port},
    webNavigation:{getFrame:async()=>{ if(f.frameGate) await f.frameGate; return {documentId:'native-source',url}; },
      onCommitted:committed,onReferenceFragmentUpdated:fragment},
    tabs:{onRemoved:removed, get:async()=>{ if(f.tabGate) await f.tabGate; return {url}; }, async executeScript(tabId, options) {
      assert.equal(tabId, 7);
      assert.equal(options.runAt, 'document_end');
      const follow = options.code.startsWith('(() => { const browserScene');
      injections.push(follow ? 'follow' : 'read');
      if (follow) {
        if (f.rejectFollow) throw new Error('injection refused');
        if (f.refuseFollow) return [{interactionFailure:{message:'scene_node_detached',effectStarted:false}}];
        return [{action:'follow_link',urlBefore:url,url,destinationUrl:f.destination,
          navigationSource:{url,documentId:'masc-source'}}];
      }
      if (f.rejectRead) throw new Error('destination document unavailable');
      return [{url,documentId:'masc-new',nodes:[]}];
    }},
  };
  const context = vm.createContext({browser,TextEncoder,AbortController,
    Date:class extends Date { static now() { return now; } },
    setTimeout(fn, delay) { const id = ++timerId; timers.set(id,{fn,due:now+delay}); return id; },
    clearTimeout:id=>timers.delete(id)});
  vm.runInContext(source, context);
  const f = {destination:'https://example.org/destination',replies,injections,timers,
    get listeners() { return committed.size + fragment.size + removed.size; },
    call(id,verb,args,deadlineMs=now+20000) {
      return context.onHostMessage({id,verb,args,deadlineMs},port);
    },
    follow(id='follow',deadline) {
      return f.call(id,'page.interact',{tabId:7,expectedUrl:url,action:'follow_link',documentId:'masc-source',nodeId:'link'},deadline);
    },
    read(id='read',deadline) { return f.call(id,'page.scene',{tabId:7,view:'content',maxChars:20000},deadline); },
    commit(documentId='native-new',tabId=7,frameId=0) {
      if (tabId===7 && frameId===0 && documentId!=='native-source') url=f.destination;
      committed.emit({tabId,frameId,documentId,url});
    },
    fragment(destination=f.destination,documentId='native-source') {
      url=destination; fragment.emit({tabId:7,frameId:0,documentId,url});
    },
    close() { removed.emit(7); }, disconnect() { disconnected.emit(); },
    advance(ms) {
      now += ms;
      for (const [id,timer] of [...timers]) if (timer.due<=now) { timers.delete(id); timer.fn(); }
    },
  };
  return f;
}
const entered = () => new Promise(resolve=>setImmediate(resolve));

test('follow receipt is immediate; the next read waits for the new top document, then uses document_end', async()=>{
  const f=fixture(); await f.follow();
  assert.equal(f.replies[0].ok,true);
  assert.equal(f.replies[0].data.navigationSource.documentId,'masc-source');
  const read=f.read(); await entered();
  assert.deepEqual(f.injections,['follow']);
  f.commit('native-source'); f.commit('other-tab',8); f.commit('subframe',7,2);
  await entered(); assert.deepEqual(f.injections,['follow']);
  f.commit(); await read;
  assert.deepEqual(f.injections,['follow','read']);
  assert.equal(f.replies[1].data.url,f.destination);
  assert.equal(f.listeners,0); assert.equal(f.timers.size,0);
});
test('an already committed document is read without waiting for a second event',async()=>{
  const f=fixture(); await f.follow(); f.commit(); await f.read();
  assert.equal(f.replies[1].ok,true); assert.equal(f.listeners,0); assert.equal(f.timers.size,0);
});
test('same-document readiness requires the observed native document and destination',async()=>{
  const f=fixture(); f.destination='https://example.org/source#part'; await f.follow();
  const read=f.read(); await entered();
  f.fragment(f.destination,'different-native-document'); await entered();
  f.fragment('https://example.org/source#other'); await entered();
  assert.deepEqual(f.injections,['follow']);
  f.fragment(); await read;
  assert.equal(f.replies[1].data.url,f.destination); assert.equal(f.listeners,0);
});
test('a committed error document returns its actual read failure and does not replay follow',async()=>{
  const f=fixture(); f.rejectRead=true; await f.follow();
  const read=f.read(); await entered(); f.commit(); await read;
  assert.equal(f.replies[0].ok,true); assert.equal(f.replies[1].ok,false);
  assert.equal(f.replies[1].error,'destination document unavailable');
  assert.deepEqual(f.injections,['follow','read']); assert.equal(f.listeners,0);
});
for (const mode of ['rejectFollow','refuseFollow']) test(`${mode} withdraws its observation and preserves effect metadata`,async()=>{
  const f=fixture(); f[mode]=true; await f.follow();
  assert.equal(f.replies[0].ok,false); assert.equal(f.listeners,0); assert.equal(f.timers.size,0);
  assert.equal(f.replies[0].effectPhase,mode==='refuseFollow'?'not_started':undefined);
});
for (const mode of ['close','disconnect']) test(`${mode} settles a waiting read without injection`,async()=>{
  const f=fixture(); await f.follow(); const read=f.read(); await entered(); f[mode](); await read;
  assert.equal(f.replies[1].ok,false); assert.deepEqual(f.injections,['follow']); assert.equal(f.listeners,0);
  assert.equal(f.timers.size,mode==='disconnect'?1:0); // existing host reconnect only
});
test('the propagated read deadline cancels the listener and late commits do not revive it',async()=>{
  const f=fixture(); await f.follow('follow',5000); const read=f.read('read',2000); await entered();
  f.advance(1001); await read; f.commit(); await entered();
  assert.equal(f.replies[1].error,'browser_command_cancelled');
  assert.deepEqual(f.injections,['follow']); assert.equal(f.listeners,0); assert.equal(f.timers.size,0);
});
test('a follow observation with no later read expires at its original transport deadline',async()=>{
  const f=fixture(); await f.follow('follow',2000); f.advance(1001);
  assert.equal(f.listeners,0); assert.equal(f.timers.size,0); assert.equal(f.replies[0].ok,true);
});
test('superseding a follow cancels the old read and only the new observation remains',async()=>{
  const f=fixture(); await f.follow('first'); const oldRead=f.read('old-read'); await entered();
  await f.follow('second'); await oldRead;
  assert.equal(f.replies.find(r=>r.id==='old-read').ok,false);
  const read=f.read('new-read'); await entered(); f.commit(); await read;
  assert.equal(f.replies.find(r=>r.id==='new-read').ok,true); assert.equal(f.listeners,0);
});
test('an expired native command cannot start an interaction',async()=>{
  const f=fixture(); await f.follow('expired',999);
  assert.deepEqual(f.injections,[]); assert.equal(f.replies[0].effectPhase,'not_started');
  assert.equal(f.replies[0].error,'browser_command_expired');
});

for (const gate of ['tabGate','frameGate']) for (const cancellation of ['deadline','disconnect']) {
  test(`late ${gate} cannot inject after ${cancellation}`,async()=>{
    const f=fixture(); let release;
    f[gate]=new Promise(resolve=>{release=resolve;});
    const pending=f.follow(); await entered();
    if(cancellation==='deadline') f.advance(20001); else f.disconnect();
    release(); await pending;
    assert.deepEqual(f.injections,[]);
    assert.equal(f.listeners,0);
    assert.equal(f.timers.size,cancellation==='disconnect' ? 1 : 0); // reconnect timer only
    if(cancellation==='deadline') {
      assert.equal(f.replies[0].ok,false);
      assert.equal(f.replies[0].effectPhase,'not_started');
    }
  });
}
