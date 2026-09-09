const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { waitForDurableOperation } = require('../scripts/imp-onboarding-browser.cjs');
const missing = { schema: 'masc.keeper_chat_operation.error.v1', error: 'unknown_operation' };
const operation = state => ({ schema: 'masc.keeper_chat_operation.v1', operation_id: 'request-1', state });
const response = (status, body) => ({ ok: () => status === 200, status: () => status, json: async () => body });
function fixture(responses) {
  let time = 0;
  return { page: { request: { get: async () => responses.shift() ?? response(404, missing) },
                   waitForTimeout: async delay => { time += delay; } }, now: () => time };
}

test('POST request and HTTP headers can precede durable admission', async () => {
  let admit;
  const admission = new Promise(resolve => { admit = resolve; });
  let registered = false;
  let releasePost;
  const arrived = new Promise(resolve => { releasePost = resolve; });
  const server = http.createServer(async (req, res) => {
    if (req.method === 'POST') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.write('retry: 250\n\n');
      releasePost();
      await admission;
      registered = true;
      res.end('data: accepted\n\n');
    } else {
      res.writeHead(registered ? 200 : 404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(registered ? operation('Succeeded') : missing));
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = 'http://127.0.0.1:' + server.address().port;
  try {
    const post = fetch(url, { method: 'POST' });
    await arrived;
    assert.equal((await post).status, 200);
    let absenceObserved = false;
    const page = { request: { get: async () => {
      const result = await fetch(url);
      if (result.status === 404) { absenceObserved = true; admit(); }
      return { ok: () => result.ok, status: () => result.status, json: () => result.json() };
    } }, waitForTimeout: () => new Promise(resolve => setTimeout(resolve, 5)) };
    const result = await waitForDurableOperation(page, url, 'fixture-token', 'request-1', { timeoutMs: 5000 });
    assert.equal(result.state, 'Succeeded');
    assert.equal(absenceObserved, true);
  } finally { admit(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
});

test('unrelated404 and authentication errors remain fatal', async () => {
  for (const [status, body] of [[404, {error:'wrong_route'}], [401, missing]]) {
    const f = fixture([response(status, body)]);
    await assert.rejects(waitForDurableOperation(f.page, 'unused', '', 'request-1', { now:f.now }), /lookup failed/);
  }
});

test('an admitted operation disappearing remains fatal', async () => {
  const f = fixture([response(200, operation('Queued')), response(404, missing)]);
  await assert.rejects(waitForDurableOperation(f.page, 'unused', '', 'request-1', { now:f.now }), /lookup failed/);
});

test('absence has a bounded admission deadline', async () => {
  const f = fixture([]);
  await assert.rejects(waitForDurableOperation(f.page, 'unused', '', 'request-1', { now:f.now, timeoutMs:500 }), /not admitted/);
});

test('operation identity and terminal failure are not converted to success', async () => {
  const wrong = fixture([response(200, {...operation('Succeeded'), operation_id:'another-request'})]);
  await assert.rejects(waitForDurableOperation(wrong.page, 'unused', '', 'request-1', { now:wrong.now }), /identity/);
  const failed = fixture([response(200, operation('Failed'))]);
  assert.equal((await waitForDurableOperation(failed.page, 'unused', '', 'request-1', { now:failed.now })).state, 'Failed');
});
