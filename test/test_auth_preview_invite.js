// Run with node test/test_auth_preview_invite.js.
// Runs the script of the invitation page as the page source holds it, over
// the elements its markup names and an address that changes the way the one
// of a browser tab does. It checks what the script does with the address and
// the form, not what the page says.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[2] || 'lib/auth_preview.ml', 'utf8');

/** The source of one value, from its `let` to the `;;` that ends it. */
function definition(name) {
  const start = source.indexOf('let ' + name + ' ');
  const end = source.indexOf('\n;;', start);
  assert(start >= 0 && end > start, name + ' must be present');
  return source.slice(start, end);
}
const script = (() => {
  const text = definition('invite_script');
  const start = text.indexOf('{|');
  const end = text.lastIndexOf('|}');
  assert(start >= 0 && end > start, 'the script of the invitation page must be present');
  return text.slice(start + 2, end);
})();

// The elements of the page, and whether each is hidden at first, as the markup
// of invite_page and start_form writes them. An id the markup does not write
// is no element, as in a browser.
const hiddenAtFirst = new Map();
for (const [, attributes] of (definition('start_form') + definition('invite_page')).matchAll(/<[a-z][a-z0-9]*\b([^>]*)>/g)) {
  const id = /\bid=\\"([\w-]+)\\"/.exec(attributes);
  if (id !== null) hiddenAtFirst.set(id[1], /\shidden(?=\s|$)/.test(attributes));
}
assert(hiddenAtFirst.size > 0, 'the markup of the invitation page must name its elements');

// Safety net for a script that keeps answering its own events.
const MAX_EVENTS = 10;

/** A tab that opens the page at /accounts/invite with this fragment. */
function open(fragment) {
  const elements = new Map(
    [...hiddenAtFirst].map(([id, hidden]) => [id, { id, value: '', textContent: '', hidden, disabled: false }]));
  const element = (id) => {
    assert(elements.has(id), 'the page must have the element ' + id);
    return elements.get(id);
  };
  const document = { title: '', getElementById: (id) => elements.get(id) ?? null };
  let address = new URL('http://server/accounts/invite' + fragment);
  const shown = () => address.pathname + address.hash;
  // The entries of the tab's history that this page has; the last one is open.
  const entries = [shown()];
  const listeners = [];
  const queued = [];
  const loads = [];
  // What a person can do with the form: see it, and press its button with the
  // pointer or with a key while the button holds the focus.
  const form = () => ({ shown: !element('accept').hidden, buttonOn: !element('go').disabled });
  // A load starts from the address of the moment the page asks for it, and
  // the page is what it is once the task that asked has ended: that is what a
  // person finds while the server answers.
  let loadAsked = null;
  const endOfTask = () => {
    if (loadAsked === null) return;
    loads.push({ address: loadAsked, ...form() });
    loadAsked = null;
  };
  // A change of the fragment from the page itself is a navigation too.
  const navigate = (next) => {
    const before = address.href;
    address = next;
    entries.push(shown());
    if (address.hash !== new URL(before).hash) queued.push({ type: 'hashchange', oldURL: before, newURL: address.href });
  };
  const location = {
    get pathname() { return address.pathname; },
    get hash() { return address.hash; },
    set hash(value) { const next = new URL(address); next.hash = value; navigate(next); },
    get href() { return address.href; },
    reload() { loadAsked = shown(); },
  };
  const history = {
    replaceState(_state, _unused, url) { address = new URL(url, address); entries[entries.length - 1] = shown(); },
    pushState(_state, _unused, url) { address = new URL(url, address); entries.push(shown()); },
  };
  const addEventListener = (type, listener, options) => {
    listeners.push({ type, listener, once: options?.once === true });
  };
  const window = { addEventListener, location, history, document };
  // Runs the events that are queued, the way the event loop of a tab does.
  const settle = () => {
    for (let count = 0; queued.length > 0; count += 1) {
      assert(count < MAX_EVENTS, 'the page keeps answering its own events');
      const event = queued.shift();
      for (const one of [...listeners]) {
        if (one.type !== event.type) continue;
        if (one.once) listeners.splice(listeners.indexOf(one), 1);
        one.listener(event);
      }
      endOfTask();
    }
  };
  new Function('window', 'location', 'history', 'document', 'addEventListener', script)(
    window, location, history, document, addEventListener);
  endOfTask();
  settle();
  return {
    element,
    form,
    loads,
    entries,
    address: shown,
    // The person opens an address of this page that differs in the fragment
    // alone, from the address bar or a link.
    go(next) { const url = new URL(address); url.hash = next; navigate(url); settle(); },
  };
}

const first = 'a1'.repeat(32);
const second = 'b2'.repeat(32);
const third = 'c3'.repeat(32);

// A link with a token: the form carries it and can be sent, and neither the
// address nor the entry of the tab keeps the token.
const taken = open('#' + first);
assert.equal(taken.element('invite').value, first);
assert.deepEqual(taken.form(), { shown: true, buttonOn: true });
assert.equal(taken.element('back').hidden, true);
assert.equal(taken.address(), '/accounts/invite');
assert.deepEqual(taken.entries, ['/accounts/invite']);
assert.deepEqual(taken.loads, []);

// An address with no token: the form is away and the way back is offered.
const bare = open('');
assert.equal(bare.form().shown, false);
assert.equal(bare.element('back').hidden, false);
assert.deepEqual(bare.loads, []);

// A link opened in the tab that shows the page changes the fragment alone.
// The page loads itself once, in either state, with the new link still in the
// address for the page that the server answers. While it waits, the form of
// the link before is away and its button is off.
const waiting = { shown: false, buttonOn: false };
for (const page of [open('#' + first), open('')]) {
  page.go('#' + second);
  assert.deepEqual(page.loads, [{ address: '/accounts/invite#' + second, ...waiting }]);
}

// A third link opened before the server answered the second loads the page
// again, with the last link.
const twice = open('#' + first);
twice.go('#' + second);
twice.go('#' + third);
assert.deepEqual(twice.loads, [
  { address: '/accounts/invite#' + second, ...waiting },
  { address: '/accounts/invite#' + third, ...waiting },
]);
console.log('invitation page script passed');
