// Run with node test/test_auth_preview_session.js.
// Runs the script of the home page, as the page source holds it, over the
// elements its markup names and routes that answer from a list. It checks
// which view the page shows, what it asks the server and where it sends the
// browser, not what a view says.
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
  const text = definition('home_script');
  const start = text.indexOf('{|');
  const end = text.lastIndexOf('|}');
  assert(start >= 0 && end > start, 'the script of the home page must be present');
  return text.slice(start + 2, end);
})();
// The page reads the session as soon as it runs. The test calls the same
// function itself, once, so it can wait for it.
const call = '\nshow();';
assert(script.endsWith(call), 'the page must read the session when it loads');
const body = script.slice(0, -call.length);
// The name of the CSRF header is filled in when the page is written.
const csrfHeader = '%s';

// The elements of the page, whether each is hidden at first and the value it
// holds, as the markup of home_page and start_form writes them. An id the
// markup does not write is no element, as in a browser.
const markup = new Map();
for (const [, attributes] of (definition('start_form') + definition('home_page')).matchAll(/<[a-z][a-z0-9]*\b([^>]*)>/g)) {
  const id = /\bid=\\"([\w-]+)\\"/.exec(attributes);
  if (id === null) continue;
  const value = /\bvalue=\\"([^\\]*)\\"/.exec(attributes);
  markup.set(id[1], { hidden: /\shidden(?=\s|$)/.test(attributes), value: value === null ? '' : value[1] });
}
const views = ['signin', 'unread', 'stuck'];
for (const id of views) assert(markup.has(id), 'the markup of the home page must write the view ' + id);
// The console is where the form of the page returns a login to.
const consolePath = markup.get('return-to')?.value;
assert(consolePath, 'the form of the home page must name where a login comes back to');

const sessionOf = (user, token) => [200, { user_id: user, expires_at_ms: 1, csrf_token: token }];
const session = sessionOf('usr_0123456789', 'one');
const refused = (status) => [status, { error: 'refused' }];

/** An answer the test gives when it chooses: `answer` waits for `give`. */
function held() {
  let give;
  const answer = new Promise((resolve) => { give = resolve; });
  return { answer, give };
}

/** The page as the document has it at first. `answers` maps a path to what
    the server answers there: a [status, body] pair, 'no answer', a
    held() answer, or { inTurn: [...] } of those, one per request; the last
    one of a list answers every request after it. */
async function open(answers) {
  const sent = [];
  const replaced = [];
  let reloads = 0;
  const elements = new Map([...markup].map(([id, { hidden, value }]) => {
    const attributes = new Map();
    const listeners = [];
    return [id, {
      id, hidden, value, textContent: '', listeners,
      getAttribute: (name) => attributes.get(name) ?? null,
      setAttribute: (name, text) => { attributes.set(name, String(text)); },
      removeAttribute: (name) => { attributes.delete(name); },
      addEventListener: (type, listener) => { listeners.push({ type, listener }); },
    }];
  }));
  const document = { getElementById: (id) => elements.get(id) ?? null };
  const fetch = async (path, init = {}) => {
    sent.push({ path, method: init.method || 'GET', headers: init.headers || {} });
    assert(path in answers, 'the page asks a route the test does not answer: ' + path);
    const listed = answers[path];
    const given = listed.inTurn === undefined
      ? listed
      : (listed.inTurn.length > 1 ? listed.inTurn.shift() : listed.inTurn[0]);
    const answer = given.answer instanceof Promise ? await given.answer : given;
    if (answer === 'no answer') throw new TypeError('fetch failed');
    const [status, json] = answer;
    return {
      ok: status >= 200 && status < 300,
      status,
      json: async () => (typeof json === 'string' ? JSON.parse(json) : json),
      text: async () => (typeof json === 'string' ? json : JSON.stringify(json)),
    };
  };
  const location = {
    replace: (address) => { replaced.push(address); },
    reload: () => { reloads += 1; },
  };
  const show = new Function('document', 'fetch', 'location', body + '\nreturn show;')(document, fetch, location);
  await show();
  const shown = () => views.filter((id) => !elements.get(id).hidden);
  /** A press on the sign-out of the page, and the wait for what it does. */
  const press = () => Promise.all(
    elements.get('leave').listeners.filter(({ type }) => type === 'click').map(({ listener }) => listener()));
  return { elements, sent, replaced, reloads: () => reloads, shown, press };
}

const asked = (sent) => sent.map((one) => `${one.method} ${one.path}`);
const consoleOpens = [200, '<!doctype html>'];

(async () => {
  // A session whose console the server gives goes on to it, and the page is
  // left out of the history of the tab. Nothing else is asked.
  {
    const page = await open({ '/auth/session': session, [consolePath]: consoleOpens });
    assert.deepEqual(page.replaced, [consolePath]);
    assert.equal(page.elements.get('unread').hidden, true, 'a page that leaves for the console says nothing went wrong');
    assert.equal(page.elements.get('stuck').hidden, true, 'a page that leaves for the console says nothing went wrong');
    assert.deepEqual(asked(page.sent), ['GET /auth/session', 'GET ' + consolePath]);
  }
  // A session whose console the server does not give stays: going on would
  // bring the person back here.
  for (const answer of [refused(503), refused(404), 'no answer']) {
    const page = await open({ '/auth/session': session, [consolePath]: answer });
    assert.deepEqual(page.shown(), ['stuck'], JSON.stringify(answer));
    assert.deepEqual(page.replaced, [], JSON.stringify(answer));
  }
  // There the person can sign out with the CSRF token of the session. A 204
  // or a 401 (the session ended meanwhile) loads the page again, which then
  // shows the sign-in.
  for (const status of [204, 401]) {
    const page = await open({
      '/auth/session': session, [consolePath]: refused(503), '/auth/logout': [status, ''],
    });
    await page.press();
    const posted = page.sent.filter((one) => one.method === 'POST');
    assert.deepEqual(posted.map((one) => [one.path, one.headers[csrfHeader]]), [['/auth/logout', 'one']]);
    assert.equal(page.reloads(), 1, String(status));
  }
  // A sign-out that ends the session says nothing more on the page it leaves.
  {
    const page = await open({ '/auth/session': session, [consolePath]: refused(503), '/auth/logout': [204, ''] });
    await page.press();
    assert.equal(page.elements.get('leave-note').textContent, '');
  }
  const posts = (page) =>
    page.sent.filter((one) => one.method === 'POST').map((one) => [one.path, one.headers[csrfHeader]]);
  // A sign-out the server refuses or does not answer leaves the page, says
  // that something went wrong, and can be pressed again. The session is read
  // again first, and it is the same: the token is not sent twice.
  for (const answer of [refused(403), refused(503), 'no answer']) {
    const page = await open({
      '/auth/session': session, [consolePath]: refused(503), '/auth/logout': { inTurn: [answer, [204, '']] },
    });
    await page.press();
    assert.equal(page.reloads(), 0, JSON.stringify(answer));
    assert.deepEqual(posts(page), [['/auth/logout', 'one']], JSON.stringify(answer));
    assert.deepEqual(asked(page.sent).filter((one) => one === 'GET /auth/session').length, 2, JSON.stringify(answer));
    assert.notEqual(page.elements.get('leave-note').textContent, '', JSON.stringify(answer));
    assert.equal(page.elements.get('leave').getAttribute('aria-disabled'), null, JSON.stringify(answer));
    await page.press();
    assert.equal(page.reloads(), 1, 'the second press signs out: ' + JSON.stringify(answer));
  }
  // Another tab signed the same person in again: the page holds a token the
  // server refuses. It takes the new one from the session and sends it once.
  {
    const page = await open({
      '/auth/session': { inTurn: [session, sessionOf('usr_0123456789', 'two')] },
      [consolePath]: refused(503),
      '/auth/logout': { inTurn: [refused(403), [204, '']] },
    });
    await page.press();
    assert.deepEqual(posts(page), [['/auth/logout', 'one'], ['/auth/logout', 'two']]);
    assert.equal(page.reloads(), 1);
  }
  // The session ended meanwhile, or another person signed in: the page loads
  // again, and sends no token of another person.
  for (const now of [refused(401), sessionOf('usr_another0000', 'two')]) {
    const page = await open({
      '/auth/session': { inTurn: [session, now] }, [consolePath]: refused(503), '/auth/logout': refused(403),
    });
    await page.press();
    assert.deepEqual(posts(page), [['/auth/logout', 'one']], JSON.stringify(now));
    assert.equal(page.reloads(), 1, JSON.stringify(now));
  }
  // While a sign-out waits, the button says it cannot be pressed and the
  // note of a refusal before is gone. A second press sends nothing more.
  {
    const wait = held();
    const page = await open({
      '/auth/session': session, [consolePath]: refused(503), '/auth/logout': { inTurn: [refused(503), wait] },
    });
    await page.press();
    assert.notEqual(page.elements.get('leave-note').textContent, '');
    const first = page.press();
    const second = page.press();
    await Promise.resolve();
    assert.equal(page.elements.get('leave').getAttribute('aria-disabled'), 'true');
    assert.equal(page.elements.get('leave-note').textContent, '');
    wait.give([204, '']);
    await Promise.all([first, second]);
    assert.equal(posts(page).length, 2);
    assert.equal(page.reloads(), 1);
  }
  // No session: the sign-in, and nothing else is asked.
  {
    const page = await open({ '/auth/session': refused(401) });
    assert.deepEqual(page.shown(), ['signin']);
    assert.deepEqual(page.replaced, []);
    assert.deepEqual(asked(page.sent), ['GET /auth/session']);
  }
  // Anything else leaves the session unknown: the page says so in place of
  // the sign-in, which would tell a signed-in person that the session is
  // over. A 200 that names no CSRF token or no person is no session the page
  // can use.
  const unknown = [
    refused(503), refused(500), refused(403), 'no answer',
    [200, { user_id: 'usr_0123456789' }], [200, { user_id: 'usr_0123456789', csrf_token: null }],
    [200, { csrf_token: 'one' }], [200, 'not json'],
  ];
  for (const answer of unknown) {
    const page = await open({ '/auth/session': answer });
    assert.deepEqual(page.shown(), ['unread'], JSON.stringify(answer));
    assert.deepEqual(page.replaced, [], JSON.stringify(answer));
    assert.deepEqual(asked(page.sent), ['GET /auth/session'], JSON.stringify(answer));
  }
  console.log('session views of the home page passed');
})().catch((error) => { console.error(error); process.exitCode = 1; });
