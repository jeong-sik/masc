// Execute both shipped observation scripts against the same small DOM fixture.
// Firefox behavior and native action effects belong to the browser smoke test.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const nativeSource = fs.readFileSync(path.join(root, 'lib/browser_page_script.ml'), 'utf8');
const nativeScript = nativeSource.match(/let elements = \{\|([\s\S]*?)\|\}/)?.[1];
assert.ok(nativeScript, 'native elements script exists');
const extensionSource = fs.readFileSync(
  path.join(root, 'connectors/browser/extension/background.js'), 'utf8');

function fixture() {
  function element(tag, attrs = {}, properties = {}) {
    return {
      localName: tag, nodeType: 1, parentElement: null, children: [],
      innerText: '', disabled: false,
      type: tag === 'input' ? (attrs.type || 'text') : undefined,
      getAttribute(name) { return attrs[name] ?? null; },
      getClientRects() { return [{}]; },
      matches(selector) {
        assert.equal(selector, ':disabled');
        return this.disabled || this.disabledByFieldset || false;
      },
      ...properties,
    };
  }
  const html = element('html');
  const body = element('body');
  html.children = [body];
  body.parentElement = html;
  const text = element('input', { value: 'original attribute' }, { value: 'current edit' });
  const check = element('input', { type: 'checkbox' },
    { value: 'agree', checked: true, indeterminate: true });
  const radio = element('input', { type: 'radio', checked: '' },
    { value: 'second', checked: false });
  const area = element('textarea', {}, { value: 'current\nmultiline', readOnly: true });
  const password = element('input', { type: 'password' });
  const file = element('input', { type: 'file' });
  for (const control of [password, file]) {
    Object.defineProperty(control, 'value', {
      get() { throw new Error('sensitive input value was accessed'); },
    });
  }
  const select = element('select', {}, { value: 'published-id', multiple: true });
  const disabledGroup = element('optgroup', {}, { disabled: true, parentElement: select });
  select.options = [
    { value: 'draft-id', label: '초안', selected: false, disabled: false, parentElement: select },
    { value: 'published-id', label: 'Published', selected: true, disabled: false, parentElement: select },
    { value: 'locked-id', label: 'Locked', selected: true, disabled: false, parentElement: disabledGroup },
  ];
  const inheritedDisabled = element('input', {}, { value: 'locked', disabledByFieldset: true });
  const controls = [text, check, radio, area, password, file, select, inheritedDisabled];
  body.children = controls;
  for (const control of controls) control.parentElement = body;
  return {
    text,
    context: {
      document: { title: 'Control fixture', querySelectorAll: () => controls },
      location: { href: 'https://example.invalid/form' },
      getComputedStyle: () => ({ visibility: 'visible' }),
    },
  };
}

const plain = value => JSON.parse(JSON.stringify(value));

function runNative(context, args = {}) {
  return plain(vm.runInNewContext(`(function () {${nativeScript}})(${JSON.stringify(args)})`, context));
}

async function runExtension(context, args = {}) {
  const api = {
    runtime: {
      connectNative() {
        return { onMessage: { addListener() {} }, onDisconnect: { addListener() {} } };
      },
    },
    tabs: {
      async executeScript(tabId, { code }) {
        assert.equal(tabId, 37);
        return [vm.runInNewContext(code, context)];
      },
    },
  };
  const extension = vm.createContext({ browser: api, setTimeout, clearTimeout });
  vm.runInContext(extensionSource, extension);
  return plain(await extension.pageElements({ tabId: 37, ...args }));
}

function checkControls(observation) {
  assert.equal(observation.total, 8);
  assert.equal(observation.truncated, false);
  const [text, checkbox, radio, area, password, file, select, disabled] = observation.elements;
  assert.equal(text.type, 'text');
  assert.equal(text.value, 'current edit');
  assert.equal(checkbox.value, 'agree');
  assert.equal(checkbox.checked, true);
  assert.equal(checkbox.indeterminate, true);
  assert.equal(radio.checked, false, 'current property wins over checked attribute');
  assert.equal(area.value, 'current\nmultiline');
  assert.equal(area.readOnly, true);
  assert.equal(Object.hasOwn(password, 'value'), false);
  assert.equal(Object.hasOwn(file, 'value'), false);
  assert.equal(select.value, 'published-id');
  assert.equal(select.multiple, true);
  assert.deepEqual(select.options, [
    { value: 'draft-id', label: '초안', selected: false, disabled: false },
    { value: 'published-id', label: 'Published', selected: true, disabled: false },
    { value: 'locked-id', label: 'Locked', selected: true, disabled: true },
  ]);
  assert.equal(disabled.disabled, true, 'inherited fieldset disability is observed');
  assert.equal(new Set(observation.elements.map(item => item.selector)).size, 8);
}

test('native elements expose actionable current states without sensitive values', () => {
  const { context, text } = fixture();
  checkControls(runNative(context));
  text.value = 'later edit';
  assert.equal(runNative(context).elements[0].value, 'later edit');
});

test('live elements retain tab identity and match native control observations', async () => {
  const { context } = fixture();
  const result = await runExtension(context);
  assert.equal(result.tabId, 37);
  checkControls(result);
  const { tabId, ...page } = result;
  assert.deepEqual(page, runNative(context));
});

test('shared ancestor visibility stays correct and is refreshed for each observation', async () => {
  const { context, text } = fixture();
  const body = text.parentElement;
  const html = body.parentElement;
  let hidden = null, visibility = null;
  const calls = new Map();
  context.getComputedStyle = element => {
    calls.set(element, (calls.get(element) || 0) + 1);
    return { display: element === hidden ? 'none' : 'block', opacity: '1',
      visibility: element === visibility ? 'hidden' : 'visible' };
  };
  for (const ancestor of [null, body, html, null]) {
    hidden = ancestor;
    calls.clear();
    const native = runNative(context);
    const nativeCalls = [...calls.values()].reduce((a, b) => a + b, 0);
    calls.clear();
    const { tabId, ...extension } = await runExtension(context);
    assert.deepEqual(native, extension, 'ancestor display and later changes preserve observations');
    console.log(JSON.stringify({ hiddenAncestor: ancestor?.localName ?? null,
      nativeStyleReads: nativeCalls, extensionStyleReads: [...calls.values()].reduce((a, b) => a + b, 0) }));
  }
  visibility = body;
  assert.equal(runNative(context).total, 8, 'a descendant can override inherited visibility');
  visibility = text;
  assert.equal(runNative(context).total, 7, 'the control own visibility still hides it');
  hidden = null;
  context.getComputedStyle = element => ({ display: 'block', visibility: 'visible',
    opacity: element === html ? '0' : '1' });
  assert.equal(runNative(context).total, 0, 'an opacity-zero ancestor hides every descendant');
});

// A cut through a surrogate pair leaves half a character. JSON then carries
// an escape that a strict reader refuses, and the whole inventory is lost.
test('element text is cut by code point, never through a surrogate pair', async () => {
  const { context, text } = fixture();
  const cuts = async () => [runNative(context), await runExtension(context)]
    .map(observation => observation.elements[0].text);
  text.innerText = 'a'.repeat(499) + '\u{1F600}' + 'tail';
  for (const cut of await cuts()) {
    assert.equal(cut.isWellFormed(), true);
    assert.equal(Array.from(cut).length, 500);
    assert.equal(cut.endsWith('\u{1F600}'), true);
  }
  // 500 two-unit characters fill the 1000 units that are split, and a 501st
  // starts right after them.
  text.innerText = '\u{1F600}'.repeat(501);
  for (const cut of await cuts()) assert.equal(cut, '\u{1F600}'.repeat(500));
  text.innerText = 'short \u{1F600}';
  for (const cut of await cuts()) assert.equal(cut, 'short \u{1F600}');
});

// [within] is read by the page's CSS engine. The fixture stands in for it with
// a table of selectors: each names the elements it matches, and one is not CSS.
function scope(context, containers) {
  const controls = context.document.querySelectorAll();
  context.document.querySelectorAll = selector => {
    if (selector.startsWith('a[href]')) return controls;
    if (selector === 'nav((') throw new SyntaxError('not a selector');
    return containers[selector] ?? [];
  };
}

test('within keeps the controls inside the matched elements, in both readers', async () => {
  const { context, text } = fixture();
  const body = text.parentElement;
  const controls = body.children;
  const [first, second, ...rest] = controls;
  const nav = { localName: 'nav', nodeType: 1, parentElement: body, children: [first, second],
    getAttribute() { return null; } };
  first.parentElement = nav;
  second.parentElement = nav;
  body.children = [nav, ...rest];
  scope(context, { nav: [nav], '#agree': [second], '#missing': [] });
  const read = async within => {
    const native = runNative(context, { within });
    const { tabId, ...extension } = await runExtension(context, { within });
    assert.deepEqual(extension, native, 'both readers apply the same scope');
    return native;
  };

  const inNav = await read('nav');
  assert.equal(inNav.within, 'nav');
  assert.equal(inNav.withinMatches, 1);
  assert.equal(inNav.total, 2);
  assert.deepEqual(inNav.elements.map(item => item.value), ['current edit', 'agree']);

  const itself = await read('#agree');
  assert.equal(itself.total, 1, 'a control that matches within counts');
  assert.equal(itself.elements[0].value, 'agree');

  const none = await read('#missing');
  assert.equal(none.withinMatches, 0);
  assert.equal(none.total, 0);

  const whole = runNative(context);
  assert.equal(Object.hasOwn(whole, 'within'), false);
  assert.equal(Object.hasOwn(whole, 'withinMatches'), false);
  assert.equal(whole.total, 8);
});

test('an invalid within is refused, never read as the whole page', async () => {
  const { context } = fixture();
  scope(context, {});
  assert.throws(() => runNative(context, { within: 'nav((' }), /invalid_css_selector/);
  await assert.rejects(runExtension(context, { within: 'nav((' }), /invalid_css_selector/);
  await assert.rejects(runExtension(context, { within: '' }), /invalid_within/);
});
