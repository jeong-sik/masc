import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {webcrypto} from 'node:crypto';
const background = readFileSync(new URL('../connectors/browser/extension/background.js', import.meta.url), 'utf8');
const ocaml = readFileSync(new URL('../lib/browser_interaction.ml', import.meta.url), 'utf8');
const extensionFunction = background.slice(background.indexOf('function interactInPage'), background.indexOf('async function pageInteract')).trim();
const driverFunction = ocaml.split('let script = {js|')[1].split('\nreturn interactInPage(arguments[0]);')[0].trim();
assert.equal(extensionFunction, driverFunction, 'live and WebDriver use the same closed DOM implementation');
let clicked = 0, events = [], replies = [], executions = 0, closed = false;
class Input {
  constructor(type = 'text') { this.type = type; this.stored = 'before'; this.readOnly = false; this.disabled = false; }
  get value() { return this.stored; }
  set value(value) { this.stored = this.type === 'number' && value !== '' && !Number.isFinite(Number(value)) ? '' : value; }
  getClientRects() { return [{}]; }
  matches(selector) { assert.equal(selector, ':disabled'); return this.disabled; }
  dispatchEvent(event) { events.push(event.type); }
}
class Textarea extends Input {}
const note = new Textarea(), count = new Input('number');
count.stored = '12';
const button = {getClientRects: () => [{}], matches: () => false, click: () => clicked++};
const page = vm.createContext({HTMLInputElement: Input, HTMLTextAreaElement: Textarea,
  location: {href: 'https://example.org/form'},
  document: {title: 'Public fixture', querySelectorAll: selector => {
    if (selector === '[') throw new Error('syntax');
    return selector === '#note' ? [note] : selector === '#count' ? [count] : selector === '#button' ? [button]
      : selector === '.ambiguous' ? [button, button] : [];
  }},
  getComputedStyle: () => ({display: 'block', visibility: 'visible'}),
  Event: class {constructor(type, options) {this.type = type; this.bubbles = options.bubbles;}},
  window: {scrollX: 0, scrollY: 0, scrollBy(options) {
    assert.equal(options.behavior, 'instant'); this.scrollX += options.left; this.scrollY += options.top;
  }},
});
const event = () => ({addListener() {}, removeListener() {}});
const browser = {webNavigation:{getFrame:async () => ({documentId:'native-source',url:page.location.href}),onCommitted:event(),onReferenceFragmentUpdated:event()},runtime: {connectNative: () => ({onMessage: {addListener() {}}, onDisconnect: {addListener() {}}, postMessage: value => replies.push(value)})},
  tabs: {onRemoved:event(),get:async id=>{assert.equal(id,7);if(closed)throw new Error('tab_closed');return {id,url:page.location.href};},executeScript: async (id, {code}) => {executions++; assert.equal(id, 7); if (closed) throw new Error('tab_closed'); return [vm.runInContext(code, page)];}}};
const context = vm.createContext({browser, TextEncoder, AbortController, setTimeout, clearTimeout});
vm.runInContext(background, context);
async function command(args) { context.command = {id: 'interaction-fixture', verb: 'page.interact', deadlineMs:Date.now()+20000, args}; await vm.runInContext('onHostMessage(command)', context); return replies.at(-1); }
assert.equal((await command({action: 'click', selector: '#button'})).error, 'tab_id_required');
assert.equal(executions, 0);
assert.equal((await command({tabId: 7, action: 'click', selector: '.ambiguous'})).error, 'selector_is_ambiguous');
assert.equal((await command({tabId: 7, action: 'click', selector: '#missing'})).error, 'element_not_found');
assert.equal((await command({tabId: 7, action: 'click', selector: '['})).error, 'invalid_css_selector');
assert.equal(clicked, 0);
assert.equal((await command({tabId: 7, action: 'click', selector: '#button', expectedUrl: 'https://example.org/other'})).error, 'page_url_changed');
assert.equal(clicked, 0);
assert.equal((await command({tabId: 7, action: 'click', selector: '#button'})).ok, true);
assert.equal(clicked, 1);
const text = 'first\n");submit();//';
const fill = await command({tabId: 7, action: 'fill', selector: '#note', text});
assert.equal(fill.ok, true); assert.equal(note.value, text); assert.deepEqual(events, ['input', 'change']);
assert.equal(JSON.stringify(fill).includes(text), false, 'input contents never enter result');
assert.equal((await command({tabId: 7, action: 'fill', selector: '#count', text: 'bad number'})).error, 'input_rejected_value');
assert.equal(count.value, '12'); assert.equal(events.length, 2);
note.readOnly = true;
assert.equal((await command({tabId: 7, action: 'fill', selector: '#note', text: 'blocked'})).error, 'element_read_only');
const scroll = await command({tabId: 7, action: 'scroll', x: 0, y: 300});
assert.equal(scroll.ok, true); assert.equal(scroll.data.scrollY, 300);
closed = true;
assert.equal((await command({tabId: 7, action: 'click', selector: '#button'})).ok, false);
assert.equal(clicked, 1, 'closed tab cannot redirect action to another page');
console.log('PASS: shared script, explicit tab, unique selector, URL precondition, literal fill, no Enter/submit, rejected number, readonly, scroll, closed tab');

closed = false;
Object.assign(page,{crypto:webcrypto,innerWidth:800,innerHeight:600,scrollX:0,scrollY:0});
page.window.getComputedStyle = node => page.getComputedStyle(node);
page.document.documentElement = {};
page.document.elementFromPoint = (x,y) => {assert.equal(x,200);assert.equal(y,300);return button;};
// Obtain the same lightweight viewport identity used by capture, inside this page.
vm.runInContext(background.slice(0,background.indexOf('async function pageScene')), page);
const viewport = vm.runInContext("browserScene({mode:'viewport'})",page);
const point = {x:0.25,y:0.5}, observed = {tabId:7,expectedUrl:page.location.href,viewport,point};
assert.equal((await command({...observed,action:'click_at'})).ok,true);
assert.equal(clicked,2);
assert.equal((await command({...observed,action:'click_at',viewport:{...viewport,height:700}})).error,'observed_viewport_changed');
assert.equal((await command({...observed,action:'drag',from:point,to:point})).error,'trusted_drag_requires_automation');
const pane = {scrollTop:0,scrollLeft:0,scrollHeight:1000,clientHeight:200,scrollWidth:100,clientWidth:100,
  parentElement:null,getRootNode:()=>({}),scrollBy({top}) {this.scrollTop=Math.max(-800,Math.min(0,this.scrollTop+top));}};
button.parentElement=pane;
page.getComputedStyle = el => ({display:'block',visibility:'visible',overflowY:el===pane?'auto':'visible',overflowX:'visible'});
const nested = await command({...observed,action:'scroll_at',x:0,y:-120});
assert.equal(nested.ok,true);assert.equal(pane.scrollTop,-120);
console.log('PASS: extension dispatches screenshot point click, rejects stale viewport and unsupported drag, scrolls reverse-flow pane');

const innerHost = {shadowRoot: {elementFromPoint: () => button}};
const outerHost = {shadowRoot: {elementFromPoint: () => innerHost}};
page.document.elementFromPoint = () => outerHost;
pane.scrollTop = 0;
const shadowScroll = await command({...observed,action:'scroll_at',x:0,y:-120});
assert.equal(shadowScroll.ok,true);
assert.equal(pane.scrollTop,-120,'nested open shadow roots reach the internal scroll pane');
console.log('PASS: nested open shadow roots target the internal scroll pane');

// Following an observed href never runs an application click handler/new window.
class Anchor {
  constructor(target = '', href = 'https://example.org/destination') {this.localName='a';this.target=target;this.href=href;}
  hasAttribute(name) {return name === 'href';}
  getAttribute(name) {return name === 'target' ? this.target : null;}
  getClientRects() {return [{}];}
  click() {throw new Error('follow must not run window.open handlers');}
}
let followed, assigned = [];
// Styles are per node so an ancestor can withdraw the anchor the way a page
// does, which is what the scene's `rendered` walk already accounts for.
const followStyles = new Map();
const followPage = vm.createContext({HTMLAnchorElement:Anchor, URL, window:{},
  browserScene: () => followed,
  location:{href:'https://example.org/source',assign:url=>assigned.push(url)},
  document:{title:'Still source',querySelector:()=>null},scrollX:0,scrollY:0,
  getComputedStyle:node =>
    followStyles.get(node) ?? {display:'block',visibility:'visible',opacity:'1'}});
followPage.window.top=followPage.window;
vm.runInContext(driverFunction,followPage);
const follow = () => vm.runInContext("interactInPage({action:'follow_link',documentId:'doc',nodeId:'link',expectedUrl:'https://example.org/source'})",followPage);
followed=new Anchor('_blank');
assert.equal(follow().interactionFailure.message,'follow_link_requires_same_tab');
assert.equal(assigned.length,0,'new-tab target rejects before navigation');
followed=new Anchor('', 'javascript:window.open("other")');
assert.equal(follow().interactionFailure.message,'follow_link_requires_http_url');
assert.equal(assigned.length,0);
followed=new Anchor();
const receipt=follow();
assert.equal(receipt.destinationUrl,'https://example.org/destination');
assert.equal(receipt.url,'https://example.org/source','delayed navigation receipt remains source observation');
assert.deepEqual(assigned,['https://example.org/destination']);

// A page can withdraw the observed link between the read and the follow. The
// scene stops admitting it -- `rendered` walks ancestors for display and
// opacity -- so the follow has to stop too, or it navigates to a link the
// operator can no longer see.
{
  const wrapper = {};
  followed = new Anchor();
  followed.parentElement = wrapper;
  followStyles.set(wrapper, {display:'block',visibility:'visible',opacity:'0'});
  const before = assigned.length;
  assert.equal(follow().interactionFailure.message,'element_not_visible',
    'an ancestor with opacity 0 withdraws the link');
  assert.equal(assigned.length,before,'a withdrawn link never navigates');
  followStyles.set(wrapper, {display:'none',visibility:'visible',opacity:'1'});
  assert.equal(follow().interactionFailure.message,'element_not_visible',
    'an ancestor with display none withdraws the link');
  followStyles.set(wrapper, {display:'block',visibility:'visible',opacity:'1'});
  assert.equal(follow().destinationUrl,'https://example.org/destination',
    'a rendered ancestor still follows');
  followStyles.delete(wrapper);
  followed.parentElement = undefined;
}
console.log('PASS: a link withdrawn by an ancestor is not followed');

// Exercise the actual native message dispatch and injected scene resolver.
page.HTMLAnchorElement=Anchor;page.URL=URL;
page.getComputedStyle=()=>({display:'block',visibility:'visible'});
page.document.querySelector=()=>null;
page.location.assign=url=>assigned.push(url);
page.followAnchor=new Anchor('_blank');
page.followAnchor.isConnected=true;page.followAnchor.ownerDocument=page.document;
vm.runInContext("window[Symbol.for('masc.browser.scene.refs.v3')].nodes.set('follow-link',new WeakRef(followAnchor));window[Symbol.for('masc.browser.scene.refs.v3')].links.set('follow-link',followAnchor.href)",page);
const dispatchedFollow={tabId:7,action:'follow_link',documentId:viewport.documentId,nodeId:'follow-link',expectedUrl:page.location.href};
assert.equal((await command(dispatchedFollow)).error,'follow_link_requires_same_tab');
page.followAnchor.target='_self';
const dispatchedReceipt=await command(dispatchedFollow);
assert.equal(dispatchedReceipt.ok,true,JSON.stringify(dispatchedReceipt));
assert.equal(dispatchedReceipt.data.tabId,7);
assert.equal(dispatchedReceipt.data.destinationUrl,'https://example.org/destination');
assert.equal(dispatchedReceipt.data.action,'follow_link');
assert.equal(dispatchedReceipt.data.navigationSource.documentId,viewport.documentId);
assert.equal(dispatchedReceipt.data.navigationSource.url,page.location.href);
console.log('PASS: native host message dispatch follows an observed same-tab anchor and exposes destinationUrl');
const beforeRecycledFollow=assigned.length;
page.followAnchor.href='https://example.org/recycled-channel';
const recycledFollow=await command(dispatchedFollow);
assert.equal(recycledFollow.error,'scene_link_destination_changed');
assert.equal(recycledFollow.effectPhase,'not_started');
assert.equal(assigned.length,beforeRecycledFollow,'recycled anchors cannot navigate to an unobserved destination');
page.followAnchor.href='https://example.org/destination';


const stale=await command({...dispatchedFollow,expectedUrl:'https://example.org/stale'});
assert.equal(stale.effectPhase,'not_started','stale URL rejection is explicitly pre-effect through native dispatch');
const detached=await command({...dispatchedFollow,nodeId:'detached'});
assert.equal(detached.effectPhase,'not_started','detached reference is pre-effect');
page.followAnchor.target='_self';
page.location.assign=()=>{throw new Error('navigation result lost');};
const uncertain=await command(dispatchedFollow);
assert.equal(uncertain.ok,false);
assert.equal(uncertain.effectPhase,undefined,'failure after navigation starts must remain unknown');
console.log('PASS: native dispatch preserves pre-effect rejection and unknown post-effect failure');

const originalGet=browser.tabs.get,originalExecute=browser.tabs.executeScript;
const beforePreflight=executions;
closed=true;
assert.equal((await command({tabId:7,action:'click',selector:'#button'})).effectPhase,'not_started');
closed=false;
browser.tabs.get=async()=>({id:7,url:'https://example.org/changed'});
assert.equal((await command({tabId:7,action:'click',selector:'#button',expectedUrl:'https://example.org/old'})).effectPhase,'not_started');
assert.equal(executions,beforePreflight,'preflight rejection never calls injection');
browser.tabs.get=originalGet;
browser.tabs.executeScript=async(...args)=>{await originalExecute(...args);throw new Error('injection result lost');};
const clicksBeforeLostReply=clicked;
const lostReply=await command({tabId:7,action:'click',selector:'#button'});
assert.equal(clicked,clicksBeforeLostReply+1,'page effect occurred before API rejection');
assert.equal(lostReply.ok,false);
assert.equal(lostReply.effectPhase,undefined,'API rejection alone cannot prove pre-effect');
browser.tabs.executeScript=originalExecute;
console.log('PASS: preflight rejection is pre-effect; applied script with lost API result remains unknown');

for (const target of ['_top','_parent']) {
  followed=new Anchor(target);const count=assigned.length;
  assert.equal(follow().destinationUrl,followed.href);assert.equal(assigned.length,count+1);
}
for (const policy of ['rel','referrerpolicy']) {
  followed=new Anchor();const count=assigned.length;
  followed.getAttribute=name=>name===policy ? (policy==='rel'?'noopener NoReferrer':'no-referrer') : null;
  followed.hasAttribute=name=>name==='href'||name===policy;
  assert.equal(follow().interactionFailure.message,'follow_link_referrer_policy_unsupported');
  assert.equal(follow().interactionFailure.effectStarted,false);assert.equal(assigned.length,count);
}
console.log('PASS: top-document parent/top targets accepted and link-specific referrer policies reject pre-effect');

const updates=[];
let activeTab={id:7,url:'https://example.org/channel',title:'Channel',active:false};
browser.tabs.get=async id=>{assert.equal(id,7);return {...activeTab};};
browser.tabs.update=async(id,changes)=>{assert.equal(id,7);assert.deepEqual(JSON.parse(JSON.stringify(changes)),{active:true});updates.push(changes);activeTab.active=true;return {...activeTab};};
assert.equal((await command({tabId:7,action:'activate_tab'})).error,'activate_tab_requires_expected_url');
assert.equal((await command({tabId:7,action:'activate_tab',expectedUrl:'https://example.org/wrong'})).error,'page_url_changed');
assert.equal(updates.length,0);
const priorExecutions=executions;
const activation=await command({tabId:7,action:'activate_tab',expectedUrl:activeTab.url});
assert.equal(activation.ok,true,JSON.stringify(activation));
assert.equal(activation.data.active,true);assert.equal(activation.data.tabId,7);
assert.equal(activation.data.url,activeTab.url);assert.equal(updates.length,1);
assert.equal(executions,priorExecutions,'activation does not inject or navigate the page');
console.log('PASS: activation checks explicit tab URL then updates only active and verifies receipt');

const activationArgs={tabId:7,action:'activate_tab',expectedUrl:activeTab.url};
assert.equal((await command({...activationArgs,expectedUrl:'https://example.org/stale'})).effectPhase,'not_started');
assert.equal((await command({...activationArgs,tabId:-1})).effectPhase,'not_started');
assert.equal((await command({tabId:7,action:'activate_tab'})).effectPhase,'not_started');
const getTab=browser.tabs.get,updateTab=browser.tabs.update;
browser.tabs.get=async()=>{throw new Error('closed before activation');};
assert.equal((await command(activationArgs)).effectPhase,'not_started');
browser.tabs.get=getTab;
browser.tabs.update=async()=>{throw new Error('activation transport outcome unknown');};
assert.equal((await command(activationArgs)).effectPhase,undefined,'dispatch failure must not authorize effect replay');
browser.tabs.update=async(...args)=>{const result=await updateTab(...args);browser.tabs.get=async()=>{throw new Error('closed after activation');};return result;};
assert.equal((await command(activationArgs)).effectPhase,undefined,'post-activation verification failure is not pre-effect');
browser.tabs.get=getTab;browser.tabs.update=updateTab;
console.log('PASS: native dispatch distinguishes activation pre-effect failures from unknown effect outcomes');
