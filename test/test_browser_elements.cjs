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

function runNative(context) {
  return plain(vm.runInNewContext(`(function () {${nativeScript}})()`, context));
}

async function runExtension(context) {
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
  const extension = vm.createContext({ browser: api });
  vm.runInContext(extensionSource, extension);
  return plain(await extension.pageElements({ tabId: 37 }));
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
