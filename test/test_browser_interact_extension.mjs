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
const browser = {runtime: {connectNative: () => ({onMessage: {addListener() {}}, onDisconnect: {addListener() {}}, postMessage: value => replies.push(value)})},
  tabs: {executeScript: async (id, {code}) => {executions++; assert.equal(id, 7); if (closed) throw new Error('tab_closed'); return [vm.runInContext(code, page)];}}};
const context = vm.createContext({browser, TextEncoder, setTimeout, clearTimeout});
vm.runInContext(background, context);
async function command(args) { context.command = {id: 'interaction-fixture', verb: 'page.interact', args}; await vm.runInContext('onHostMessage(command)', context); return replies.at(-1); }
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
