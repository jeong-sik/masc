// Run with node test/test_auth_preview_session.js.
// Runs the part of the home page script that reads the session and signs
// out, as the page source holds it, over routes that answer from a list. It
// checks which view the page shows and what it sends, not what a view says.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[2] || 'lib/auth_preview.ml', 'utf8');
const start = source.indexOf('let csrf = null;');
const end = source.indexOf('\nasync function listAccounts() {', start);
assert(start >= 0 && end > start, 'the session part of the home page script must be present');
const part = source.slice(start, end);
// The name of the CSRF header is filled in when the page is written.
const csrfHeader = '%s';

// One answer of a route: a status and a JSON body, or 'no answer' for a
// request that fails.
const session = (token) => [200, { user_id: 'usr_0123456789', expires_at_ms: 1, csrf_token: token }];
const who = [200, { principal: { kind: 'human', id: 'usr_0123456789' }, role: 'worker', binding: { kind: 'session', id: 's' } }];
const refused = (status) => [status, { error: 'refused' }];
const ended = [204, null];

/** The page as the document has it at first (home_page in the same source),
    over routes that give `answers` in order. */
function open(answers) {
  const left = [...answers];
  const sent = [];
  let reloads = 0;
  let press = null;
  const block = (hidden) => ({ hidden, textContent: 'reading' });
  const page = {
    out: block(false),
    signin: block(false),
    signedIn: block(true),
    unread: block(true),
    allowSection: block(true),
    signout: { hidden: false, addEventListener: (_, handler) => { press = handler; } },
    // The link of the view that says the session was not read.
    reopen: { focused: 0, focus() { this.focused += 1; } },
  };
  const fetch = async (path, init = {}) => {
    sent.push({ path, token: (init.headers || {})[csrfHeader] });
    const next = left.shift();
    assert(next !== undefined, 'no answer was scripted for ' + path);
    if (next === 'no answer') throw new TypeError('fetch failed');
    const [status, body] = next;
    return { ok: status >= 200 && status < 300, status, text: async () => (body === null ? '' : JSON.stringify(body)) };
  };
  const location = { reload: () => { reloads += 1; } };
  const names = ['fetch', 'location', ...Object.keys(page)];
  const show = new Function(...names, part + '\nreturn show;')(fetch, location, ...Object.values(page));
  assert.equal(typeof press, 'function', 'the page must hear a press of the sign-out button');
  return { page, sent, show, press: () => press(), reloads: () => reloads };
}

/** Which of the three views a person sees. */
const shown = ({ signin, signedIn, unread }) =>
  [['the sign-in', signin], ['the tools of a signed-in person', signedIn], ['that the session was not read', unread]]
    .filter(([, view]) => !view.hidden)
    .map(([name]) => name);
const paths = (sent) => sent.map((one) => one.path);
const signOuts = (sent) => sent.filter((one) => one.path === '/auth/logout');

(async () => {
  // Reading the session: one view for each of the three things it can say.
  {
    const { page, show } = open([session('one'), who]);
    await show();
    assert.deepEqual(shown(page), ['the tools of a signed-in person']);
  }
  {
    const { page, show } = open([refused(401), refused(401)]);
    await show();
    assert.deepEqual(shown(page), ['the sign-in']);
  }
  for (const answer of [refused(503), refused(500), refused(403), 'no answer']) {
    const { page, show } = open([answer, answer]);
    await show();
    assert.deepEqual(shown(page), ['that the session was not read'], JSON.stringify(answer));
    assert.equal(page.reopen.focused, 0, 'a page that is loading takes no focus');
  }

  // A sign-out that ended the session, or found none, loads the page again
  // and reads nothing more in the page that is left.
  for (const answer of [ended, refused(401)]) {
    const { sent, show, press, reloads } = open([session('one'), who, answer]);
    await show();
    await press();
    assert.equal(reloads(), 1, JSON.stringify(answer));
    assert.deepEqual(paths(sent), ['/auth/session', '/api/v1/auth/whoami', '/auth/logout']);
    assert.equal(signOuts(sent)[0].token, 'one');
  }

  // A sign-out that did not end the session leaves the person signed in,
  // says more than a reading of the session does, and the next press carries
  // the token that was read after it.
  const plain = open([session('two'), who]);
  await plain.show();
  for (const answer of [refused(503), refused(403), 'no answer']) {
    const { page, sent, show, press, reloads } = open([session('one'), who, answer, session('two'), who, ended]);
    await show();
    await press();
    assert.equal(reloads(), 0, JSON.stringify(answer));
    assert.deepEqual(shown(page), ['the tools of a signed-in person']);
    assert.notEqual(page.out.textContent, plain.page.out.textContent, 'the page must say that the sign-out did not happen');
    assert.equal(page.reopen.focused, 0);
    await press();
    assert.deepEqual(signOuts(sent).map((one) => one.token), ['one', 'two']);
    assert.equal(reloads(), 1);
  }

  // After a sign-out that was refused, the view follows the session routes:
  // a session that is gone loads the page again, and one that cannot be read
  // is shown as not read. That view hides the button that was pressed, so
  // the focus goes to its link.
  {
    const { show, press, reloads } = open([session('one'), who, refused(503), refused(401), refused(401)]);
    await show();
    await press();
    assert.equal(reloads(), 1);
  }
  {
    const { page, show, press, reloads } = open([session('one'), who, refused(503), refused(503), refused(503)]);
    await show();
    await press();
    assert.equal(reloads(), 0);
    assert.deepEqual(shown(page), ['that the session was not read']);
    assert.equal(page.reopen.focused, 1);
  }
  console.log('session views of the home page passed');
})().catch((error) => { console.error(error); process.exitCode = 1; });
