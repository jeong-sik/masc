const assert = require('node:assert/strict');
const vm = require('node:vm');
const test = require('node:test');
// The production cookie write, unchanged, in its own realm.
const source = require('./browser_ego_cookie_write_source.cjs');
const load = () => vm.runInNewContext('(' + source + ')', {URL});
// Values from another vm realm compare only through JSON.
const plain = value => JSON.parse(JSON.stringify(value));
const reason = error => String(error && error.message || error);
const secret = 'SECRET_L11_VALUE';
const href = 'https://app.example.com/page';
// A cookie jar as L11 measured Chromium through an ego Page: setCookie with a
// url and no domain makes a host-only cookie and answers success false for
// SameSite=None without Secure; it throws for a value it cannot sanitize or
// an address that is not http or https; a past expiry stores nothing.
// getCookies lists what the url sees, deleteCookies removes an exact domain
// and path. Each `fail` entry throws for that method, `after` throws once the
// effect is done, and `keep` makes deleteCookies leave a domain in place.
const fakePage = ({at = href, jar = [], fail = {}, after = {}, keep = [], answer = {}} = {}) => {
  const page = {calls: [], jar: jar.map(cookie => ({...cookie}))};
  const sees = (cookie, url) => {
    const address = new URL(url);
    const domain = cookie.domain.startsWith('.')
      ? address.hostname === cookie.domain.slice(1) || address.hostname.endsWith(cookie.domain)
      : address.hostname === cookie.domain;
    const pathOk = address.pathname === cookie.path || address.pathname.startsWith(cookie.path.endsWith('/') ? cookie.path : cookie.path + '/');
    return domain && pathOk;
  };
  page.evaluate = async () => {
    page.calls.push('evaluate');
    if (fail.evaluate) throw new Error('evaluate failed');
    return at;
  };
  page.cdp = async (method, params) => {
    page.calls.push({method, params});
    if (fail[method]) throw new Error(method + ' failed');
    if (method in answer) return answer[method];
    if (method === 'Network.getCookies')
      return {cookies: page.jar.filter(cookie => params.urls.some(url => sees(cookie, url))).map(cookie => ({...cookie}))};
    if (method === 'Network.setCookie') {
      const address = new URL(params.url);
      if (address.protocol !== 'http:' && address.protocol !== 'https:') throw new Error('URL must have scheme http or https');
      if (/[;\u0000-\u001f]/.test(params.value)) throw new Error('Sanitizing cookie failed');
      if (params.sameSite === 'None' && !params.secure) return {success: false};
      page.jar = page.jar.filter(cookie => !(cookie.name === params.name && cookie.domain === address.hostname && cookie.path === params.path));
      const session = params.expires === undefined;
      if (session || params.expires > Date.now() / 1000)
        page.jar.push({name: params.name, value: params.value, domain: address.hostname, path: params.path, secure: !!params.secure,
          httpOnly: !!params.httpOnly, ...(params.sameSite ? {sameSite: params.sameSite} : {}), session, expires: session ? -1 : params.expires,
          size: params.name.length + params.value.length});
      if (after[method]) throw new Error(method + ' timed out');
      return {success: true};
    }
    if (method === 'Network.deleteCookies') {
      if (params.url === undefined && params.domain === undefined) throw new Error('At least one of the url and domain needs to be specified');
      if (!keep.includes(params.domain))
        page.jar = page.jar.filter(cookie => !(cookie.name === params.name && cookie.domain === params.domain && cookie.path === params.path));
      if (after[method]) throw new Error(method + ' timed out');
      return {};
    }
    throw new Error('unexpected ' + method);
  };
  return page;
};
const set = (fields = {}) => ({kind: 'set', label: 'p1', tabId: 1, name: 'session', value: secret, path: '/',
  secure: true, httpOnly: true, sameSite: null, maxAgeSec: null, ...fields});
const del = (name = 'session') => ({kind: 'delete', label: 'p1', tabId: 1, name});
const cookie = (fields = {}) => ({name: 'session', value: 'old', domain: 'app.example.com', path: '/', secure: true, httpOnly: true,
  session: true, expires: -1, size: 10, ...fields});
const methods = page => page.calls.map(call => typeof call === 'string' ? call : call.method);

test('a set writes a host-only cookie for the page address, reads it back and answers without its value', async () => {
  const write = load();
  const page = fakePage();
  const answer = plain(await write(page, set(), reason));
  assert.deepEqual(methods(page), ['evaluate', 'Network.getCookies', 'Network.setCookie', 'Network.getCookies']);
  const sent = plain(page.calls[2].params);
  assert.deepEqual(sent, {name: 'session', value: secret, url: href, path: '/', secure: true, httpOnly: true});
  assert.deepEqual(plain(page.calls[1].params), {urls: ['https://app.example.com/']});
  assert.deepEqual(answer, {ok: true, value: {name: 'session', domain: 'app.example.com', path: '/', secure: true, httpOnly: true,
    session: true, replaced: false}});
  assert.equal(JSON.stringify(answer).includes(secret), false);
  assert.equal(page.jar.length, 1);
});

test('a lifetime becomes an expiry and SameSite passes through', async () => {
  const write = load();
  const page = fakePage();
  const before = Date.now() / 1000;
  const answer = plain(await write(page, set({sameSite: 'Strict', maxAgeSec: 3600, path: '/app'}), reason));
  const sent = page.calls[2].params;
  assert.equal(sent.sameSite, 'Strict');
  assert.equal(sent.expires >= before + 3600 && sent.expires <= Date.now() / 1000 + 3600, true);
  assert.equal(answer.ok, true);
  assert.equal(answer.value.session, false);
  assert.equal(answer.value.sameSite, 'Strict');
  assert.equal(answer.value.path, '/app');
  assert.equal(Number.isInteger(answer.value.expiry) && answer.value.expiry === Math.floor(sent.expires), true);
});

test('replaced is only the same name on the same host and path', async () => {
  const write = load();
  for (const [jar, replaced] of [[[cookie()], true], [[cookie({domain: '.example.com'})], false],
    [[cookie({path: '/other'})], false], [[cookie({name: 'other'})], false]]) {
    const page = fakePage({jar});
    const answer = plain(await write(page, set(), reason));
    assert.equal(answer.ok, true);
    assert.equal(answer.value.replaced, replaced, JSON.stringify(jar));
  }
});

test('a refused cookie changes nothing and says why', async () => {
  const write = load();
  const page = fakePage();
  const answer = plain(await write(page, set({secure: false, sameSite: 'None'}), reason));
  assert.equal(answer.ok, false);
  assert.equal(answer.before, true);
  assert.match(answer.error, /success false/);
  assert.equal(page.jar.length, 0);
});

test('a thrown set is before the effect only when a new cookie is not there afterwards', async () => {
  const write = load();
  const refused = fakePage();
  const sanitized = plain(await write(refused, set({value: 'v;x=1'}), reason));
  assert.deepEqual(sanitized, {ok: false, before: true, error: 'Network.setCookie failed: Sanitizing cookie failed'});
  assert.deepEqual(methods(refused), ['evaluate', 'Network.getCookies', 'Network.setCookie', 'Network.getCookies']);
  const written = plain(await write(fakePage({after: {'Network.setCookie': true}}), set(), reason));
  assert.equal(written.ok, false);
  assert.equal(written.before, undefined);
  assert.match(written.error, /timed out/);
  const replacing = plain(await write(fakePage({jar: [cookie()], fail: {'Network.setCookie': true}}), set(), reason));
  assert.equal(replacing.ok, false);
  assert.equal(replacing.before, undefined);
  assert.equal(JSON.stringify([sanitized, written, replacing]).includes(secret), false);
});

test('an answer without success, or a success the jar does not show, is not a written cookie', async () => {
  const write = load();
  for (const answer of [null, {}, {success: 'yes'}]) {
    const result = plain(await write(fakePage({answer: {'Network.setCookie': answer}}), set(), reason));
    assert.deepEqual(result, {ok: false, error: 'Network.setCookie answered without success'});
  }
  const past = plain(await write(fakePage({answer: {'Network.setCookie': {success: true}}}), set(), reason));
  assert.equal(past.ok, false);
  assert.equal(past.before, undefined);
  assert.match(past.error, /do not list the cookie/);
});

test('a page that is not at an http or https address, or whose address is not read, is refused before any CDP call', async () => {
  const write = load();
  for (const [at, fail] of [['about:blank', {}], ['file:///tmp/x.html', {}], [href, {evaluate: true}], ['not an address', {}]]) {
    const page = fakePage({at, fail});
    const answer = plain(await write(page, set(), reason));
    assert.equal(answer.ok, false);
    assert.equal(answer.before, true, at);
    assert.deepEqual(methods(page), ['evaluate']);
  }
  for (const failing of [{fail: {'Network.getCookies': true}}, {answer: {'Network.getCookies': {}}}]) {
    const page = fakePage(failing);
    const answer = plain(await write(page, set(), reason));
    assert.equal(answer.before, true);
    assert.equal(methods(page).includes('Network.setCookie'), false);
  }
});

test('a delete names each cookie the page sees by its domain and path and leaves the rest', async () => {
  const write = load();
  const page = fakePage({jar: [cookie(), cookie({domain: '.example.com'}), cookie({path: '/sub'}),
    cookie({name: 'other'}), cookie({domain: 'other.example.org'})]});
  const answer = plain(await write(page, del(), reason));
  assert.deepEqual(answer, {ok: true, value: {deleted: [{domain: 'app.example.com', path: '/'}, {domain: '.example.com', path: '/'}]}});
  const deletes = page.calls.filter(call => call.method === 'Network.deleteCookies').map(call => plain(call.params));
  assert.deepEqual(deletes, [{name: 'session', domain: 'app.example.com', path: '/'}, {name: 'session', domain: '.example.com', path: '/'}]);
  assert.deepEqual(plain(page.calls[1].params), {urls: [href]});
  assert.deepEqual(page.jar.map(c => c.name + ' ' + c.domain + c.path).sort(),
    ['other app.example.com/', 'session app.example.com/sub', 'session other.example.org/']);
  assert.equal(JSON.stringify(answer).includes('old'), false);
  const none = plain(await write(fakePage(), del(), reason));
  assert.deepEqual(none, {ok: true, value: {deleted: []}});
});

test('a delete that stops halfway or leaves a cookie says what happened, never before the effect', async () => {
  const write = load();
  const twice = [cookie(), cookie({domain: '.example.com'})];
  let calls = 0;
  const page = fakePage({jar: twice});
  const cdp = page.cdp;
  page.cdp = async (method, params) => {
    if (method === 'Network.deleteCookies' && ++calls === 2) throw new Error('Network.deleteCookies timed out');
    return cdp(method, params);
  };
  const halfway = plain(await write(page, del(), reason));
  assert.deepEqual(halfway, {ok: false, error: 'Network.deleteCookies failed: Network.deleteCookies timed out; deleted before it: app.example.com/'});
  const left = plain(await write(fakePage({jar: twice, keep: ['.example.com']}), del(), reason));
  assert.deepEqual(left, {ok: false, error: 'the tab still sees 1 cookie(s) of that name: .example.com/'});
  const unread = plain(await write(fakePage({fail: {'Network.getCookies': true}}), del(), reason));
  assert.equal(unread.before, true);
});
