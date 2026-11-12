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

async function exerciseList(rows) {
  const start = source.indexOf('async function listPats() {');
  const end = source.indexOf('\ndocument.getElementById("issue-pat")', start);
  assert(start >= 0 && end > start, 'list handler must be present');
  const pats = { textContent: 'previous list' };
  const read = async () => [{ ok: true }, { pats: rows }];
  const list = new Function('read', 'pats', source.slice(start, end) + '\nreturn listPats;')(read, pats);
  await list();
  return pats.textContent;
}

(async () => {
  for (const value of ['', '  ']) {
    const { requests } = await exercise(value);
    assert.equal(requests.length, 1);
    assert.equal(requests[0][1].expires_at_ms, null);
  }
  // The field is a date and time in the local time zone (an input of type
  // datetime-local). What is no date and time is refused in the page, a bare
  // count of milliseconds included: nothing is sent, and the result line is
  // not left empty.
  for (const value of ['tomorrow', '1e999', '1730000000000']) {
    const { requests, message } = await exercise(value);
    assert.equal(requests.length, 0, value);
    assert.notEqual(message, '', value);
  }
  const local = '2026-12-01T09:30';
  const { requests } = await exercise(local);
  assert.equal(requests.length, 1);
  assert.equal(requests[0][1].expires_at_ms, new Date(local).getTime());
  assert(Number.isSafeInteger(requests[0][1].expires_at_ms));
  const normalExpiry = 1730000000000;
  const outsideDateRange = 8640000000000001;
  assert(Number.isSafeInteger(outsideDateRange));
  const row = (pat_id, expires_at_ms, status = 'open') =>
    ({ pat_id, expires_at_ms, status, scope: {} });
  const mixed = await exerciseList([
    row('no-expiry', null), row('normal', normalExpiry),
    row('date-edge', 8640000000000000), row('out-of-range', outsideDateRange)
  ]);
  for (const id of ['no-expiry', 'normal', 'date-edge', 'out-of-range']) {
    assert(mixed.includes(id), id + ' must remain available');
  }
  assert(mixed.includes(new Date(normalExpiry).toISOString()));
  assert(mixed.includes(String(outsideDateRange)), 'retain the stored expiry when Date cannot format it');
  const revoked = await exerciseList([
    row('revoked-large', outsideDateRange, 'revoked'), row('still-open', normalExpiry)
  ]);
  assert(revoked.includes('revoked-large') && revoked.includes('still-open'));
  console.log('PAT expiry handlers passed');
})().catch((error) => { console.error(error); process.exitCode = 1; });
