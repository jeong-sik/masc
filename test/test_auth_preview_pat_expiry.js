// Run with node test/test_auth_preview_pat_expiry.js.
// Exercise the issue handler embedded in the actual preview, not a copy of it.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[2] || 'lib/auth_preview.ml', 'utf8');
const start = source.indexOf('document.getElementById("issue-pat").addEventListener("click", async () => {');
const end = source.indexOf('\ndocument.getElementById("revoke-pat")', start);
assert(start >= 0 && end > start, 'issue handler must be present');
const handlerSource = source.slice(start, end);

async function exercise(value) {
  let handler;
  const requests = [];
  const document = { getElementById: () => ({ addEventListener: (_, fn) => { handler = fn; } }) };
  const patScope = { value: '{}' };
  const patExpiry = { value };
  const patToken = { textContent: '' };
  const patId = { value: '' };
  const post = async (...args) => {
    requests.push(args);
    return { ok: false, status: 400, text: async () => '' };
  };
  new Function('document', 'patScope', 'patExpiry', 'patToken', 'patId', 'post', 'listPats', 'location', handlerSource)(
    document, patScope, patExpiry, patToken, patId, post, async () => {}, { origin: '' });
  await handler();
  return { requests, message: patToken.textContent };
}

(async () => {
  for (const value of ['', '  ']) {
    const { requests } = await exercise(value);
    assert.equal(requests.length, 1);
    assert.equal(requests[0][1].expires_at_ms, null);
  }
  for (const value of ['tomorrow', '1e999', '1.5', '9007199254740992']) {
    const { requests, message } = await exercise(value);
    assert.equal(requests.length, 0, value);
    assert.match(message, /safe integer/);
  }
  const { requests } = await exercise('1730000000000');
  assert.equal(requests.length, 1);
  assert.equal(requests[0][1].expires_at_ms, 1730000000000);
  console.log('PAT expiry handler: 7 cases passed');
})().catch((error) => { console.error(error); process.exitCode = 1; });
