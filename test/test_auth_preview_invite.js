// Run with node test/test_auth_preview_invite.js.
// Runs the script of the invitation page as the page source holds it, over
// the elements it names. It checks what the script does with the address,
// not what the page says.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[2] || 'lib/auth_preview.ml', 'utf8');
const opening = 'let invite_script =\n  {|';
const start = source.indexOf(opening);
const end = source.indexOf('|}', start);
assert(start >= 0 && end > start, 'the script of the invitation page must be present');
const script = source.slice(start + opening.length, end);

// The elements the page gives the script, and which of them it hides at
// first (invite_page in the same source).
const hiddenAtFirst = new Set(['back']);

/** Opens the page at an address with this fragment and runs its script. */
function open(hash) {
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) elements.set(id, { value: '', textContent: '', hidden: hiddenAtFirst.has(id) });
    return elements.get(id);
  };
  const location = {
    hash,
    pathname: '/accounts/invite',
    reloads: 0,
    reload() { this.reloads += 1; },
  };
  const addresses = [];
  const history = {
    replaceState(_state, _unused, address) {
      addresses.push(address);
      location.hash = '';
    },
  };
  const listeners = new Map();
  new Function('location', 'history', 'document', 'addEventListener', script)(
    location, history, { getElementById: element, title: '' },
    (type, listener) => { listeners.set(type, listener); });
  return { element, location, addresses, listeners };
}

const token = 'a'.repeat(64);

// A link with a token: the form carries it, and the address keeps none of it.
const taken = open('#' + token);
assert.equal(taken.element('invite').value, token);
assert.deepEqual(taken.addresses, ['/accounts/invite']);
assert.equal(taken.element('accept').hidden, false);
assert.equal(taken.element('back').hidden, true);

// An address with no token: the form is away and the way back is offered.
const bare = open('');
assert.equal(bare.element('accept').hidden, true);
assert.equal(bare.element('back').hidden, false);

// The link opened again in the tab that shows the page changes only the
// fragment. The page loads itself again, in either state.
for (const page of [bare, taken]) {
  const onFragment = page.listeners.get('hashchange');
  assert.equal(typeof onFragment, 'function', 'the page must hear a change of the fragment');
  assert.equal(page.location.reloads, 0);
  onFragment();
  assert.equal(page.location.reloads, 1);
}
console.log('invitation page script passed');
