const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const [argumentsPath, outputPath] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(argumentsPath, 'utf8'));
const script = name => fs.readFileSync(path.join(__dirname, '../lib/', name), 'utf8')
  .split('let script = {js|')[1].split('|js}')[0];
// Both production scripts are unchanged. Only the documented native transport
// is a stand-in; these cases make no real browser/runtime claims.
const nativeErrorSource = fs.readFileSync(path.join(__dirname, '../lib/browser_ego_workflow.ml'), 'utf8')
  .split('let native_error_script = {js|')[1].split('|js}')[0];
const pageEvents = require('./browser_ego_page_events_source.cjs')();
const run = vm.runInNewContext(nativeErrorSource + '\n' + pageEvents + '\n' + script('browser_ego_raw_type.ml') + '\n('
  + script('browser_ego_workflow.ml') + ')', {URL});
const sentinel = 'PRIVATE_WORKFLOW_NATIVE_HEADER_SENTINEL';
async function scenario(mode) {
  const calls = [], queues = new Map();
  let inventories = 0, typeCalls = 0, fillCalls = 0, clickCalls = 0;
  const original = data.source;
  const dialogError = method => Object.assign(new Error(sentinel), {
    code:'EGO_PAGE_DIALOG_OPENED', method, sessionId:'actual-error-session',
    dialog:{type:'alert', message:'owned native dialog'},
  });
  const child = {...original, label:'p2', targetId:'T2'};
  const makePage = identity => {
    const queue = []; queues.set(identity.label, queue);
    const frame = 'root-' + identity.label, session = 'session-' + identity.label;
    let binding, world;
    const event = (method, params) => ({method, params, sessionId:session});
    const page = {...identity,
      async url() { return 'https://example.test/start'; },
      async title() { return 'Owned workflow'; },
      async snapshot() { if (mode === 'snapshot') throw Error(sentinel); return 'native snapshot'; },
      async info() { if (mode === 'info') throw Error(sentinel); return {}; },
      async fill() { calls.push(identity.label + '.fill'); fillCalls++; return {}; },
      async click() { calls.push(identity.label + '.click'); clickCalls++; return {}; },
      async press() { calls.push(identity.label + '.press'); throw Error(sentinel); },
      async waitForEvent() { return {spaceId:identity.spaceId, label:'p2'}; },
      async events() { calls.push(identity.label + '.events'); return queue.splice(0); },
      async cdp(method, params = {}) {
        calls.push(identity.label + '.' + method);
        switch (method) {
          case 'Page.enable': case 'Runtime.enable': return {};
          case 'Page.getFrameTree': return {frameTree:{frame:{id:frame, loaderId:'document'}}};
          case 'Page.createIsolatedWorld':
            world = params.worldName;
            queue.push(event('Runtime.executionContextCreated', {context:{id:41,
              uniqueId:'context-' + identity.label, name:world, origin:'https://example.test',
              auxData:{frameId:frame, isDefault:false, type:'isolated'}}}));
            return {executionContextId:41};
          case 'Runtime.addBinding': binding = params.name; return {};
          case 'Runtime.evaluate': {
            if (mode === 'start-dialog') throw dialogError(method);
            const value = vm.runInNewContext(params.expression, {[binding]: payload => {
              if (mode !== 'missing-end' || JSON.parse(payload).bound !== 'end')
                queue.push(event('Runtime.bindingCalled', {name:binding, payload, executionContextId:41}));
            }});
            return {result:{type:'string', value}};
          }
          case 'Runtime.removeBinding':
            if (mode === 'cleanup') throw Error(sentinel);
            if (mode === 'cleanup-dialog') throw dialogError(method);
            if (mode === 'cleanup-malformed') throw Object.assign(new Error(sentinel), {
              code:'EGO_PAGE_DIALOG_OPENED', method,
              dialog:{type:'alert', message:'owned', private:sentinel},
            });
            return {};
          default: throw Error('unexpected stand-in native method');
        }
      },
      keyboard:{async type(text, options) {
        typeCalls++; calls.push(identity.label + '.type');
        assert.equal(text, 'a');
        assert.equal(options, undefined, 'omitted options preserve native defaults');
        queue.push(event('Network.requestWillBeSentExtraInfo', {headers:{Cookie:sentinel}}));
        if (mode === 'native-dialog') throw dialogError('Input.dispatchKeyEvent');
        if (mode === 'dialog') queue.push(event('Page.javascriptDialogOpening', {type:'alert', message:'owned'}));
      }},
      async waitForSelector() {},
    };
    return page;
  };
  const opener = makePage(original), popup = makePage(child);
  const task = {spaceId:original.spaceId, ownership:'agent', async tabs() {
    inventories++;
    // The first inventory is the workflow source check. The next one belongs
    // to the raw producer, after any earlier click receipt.
    if ((mode === 'pre-raw' || mode === 'prefix-pre-raw') && inventories === 2) return [];
    return [opener, popup].map(page => ({...page, page}));
  }};
  const raw = {method:'keyboard.type', text:'a'};
  const prefix = mode === 'prefix-pre-raw' ? [{method:'click', selector:'#owned'}]
    : mode === 'popup' ? [{method:'clickAndWaitForPopup', selector:'#owned'}] : [];
  const following = mode === 'two-raw' ? [raw, {method:'fill', selector:'#entry', text:'followup'}]
    : mode === 'late-hold' ? [{method:'keyboard.press', key:'Enter'}]
    : [{method:'fill', selector:'#entry', text:'followup'}];
  // keyboard.press is a separate unreturned holding step; its uncertainty
  // must dominate the earlier verified raw tail.
  opener.keyboard.press = popup.keyboard.press = async () => { throw Error(sentinel); };
  const steps = [...prefix, raw, ...following];
  const request = {tabId:1, expectedUrl:'https://example.test/start', steps, maxChars:1000};
  const args = {...request, cursor:'Owned window fixture', label:original.label,
    snapshotScope:'viewport', expectedSourcePage:original,
    inputReceiptContract:data.receiptContract, nativeInputWindows:data.windows};
  const result = await run(opener, args, task, () => {});
  const noContinuation = ['dialog','native-dialog','start-dialog','missing-end','cleanup','cleanup-dialog','cleanup-malformed','info','pre-raw','prefix-pre-raw','late-hold'].includes(mode);
  assert.equal(fillCalls, noContinuation ? 0 : 1, mode + ' follow-up count');
  assert.equal(typeCalls, ['pre-raw','prefix-pre-raw','start-dialog'].includes(mode) ? 0 : mode === 'two-raw' ? 2 : 1);
  if (mode === 'popup') assert.ok(calls.includes('p2.type') && !calls.includes('p1.type'));
  return {mode, request, result, typeCalls, fillCalls, clickCalls, calls};
}
(async () => {
  const results = [];
  for (const mode of ['normal','dialog','native-dialog','start-dialog','missing-end','cleanup','cleanup-dialog','cleanup-malformed','info','snapshot','popup',
    'two-raw','late-hold','pre-raw','prefix-pre-raw']) results.push(await scenario(mode));
  fs.writeFileSync(outputPath, JSON.stringify(results, null, 2) + '\n', {mode:0o600});
  console.log('15 actual-source Workflow/Raw producer scenarios PASS; native transport is a stand-in');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
