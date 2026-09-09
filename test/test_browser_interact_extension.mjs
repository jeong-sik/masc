import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
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
