// Measure the elements read on a public page with the main script and this stack's script.
// Usage: node measure.mjs <firefox> <old_page_script.ml> <new_page_script.ml> <url> [within...]
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const [firefox, oldPath, newPath, url, ...scopes] = process.argv.slice(2);
const script = p => readFileSync(p, 'utf8').match(/let elements = \{\|([\s\S]*?)\|\}/)[1];
const profile = mkdtempSync(join(tmpdir(), 'masc-measure-'));
const ff = spawn(firefox, ['--headless', '--no-remote', '--profile', profile, '--remote-debugging-port', '0'],
  { stdio: ['ignore', 'ignore', 'pipe'] });
const port = await new Promise((resolve, reject) => {
  let buf = '';
  ff.stderr.on('data', d => { buf += d; const m = buf.match(/WebDriver BiDi listening on ws:\/\/127\.0\.0\.1:(\d+)/); if (m) resolve(m[1]); });
  setTimeout(() => reject(new Error('firefox did not start: ' + buf.slice(-400))), 30000);
});
const ws = new WebSocket(`ws://127.0.0.1:${port}/session`);
await new Promise(r => ws.addEventListener('open', r));
let next = 0; const pending = new Map();
ws.addEventListener('message', e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const ask = (method, params) => new Promise(r => { const id = ++next; pending.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
await ask('session.new', { capabilities: {} });
const tree = await ask('browsingContext.getTree', {});
const context = tree.result.contexts[0].context;
await ask('browsingContext.navigate', { context, url, wait: 'complete' });
const run = async (body, args) => {
  const r = await ask('script.callFunction', { functionDeclaration: `function(a){ return JSON.stringify((function(){ ${body} }).call(null, JSON.parse(a))); }`,
    target: { context }, awaitPromise: false, arguments: [{ type: 'string', value: JSON.stringify(args) }] });
  if (r.result?.type !== 'success') return { error: JSON.stringify(r).slice(0, 300) };
  return JSON.parse(r.result.result.value);
};
const summary = (name, o) => {
  const sel = o.elements.map(x => x.selector.length);
  return { read: name, bytes: JSON.stringify(o).length, total: o.total, returned: o.elements.length, truncated: o.truncated,
    withinMatches: o.withinMatches ?? null, selectorBytesMean: Math.round(sel.reduce((a, b) => a + b, 0) / Math.max(1, sel.length)),
    selectorBytesMax: Math.max(0, ...sel), sample: o.elements.slice(0, 3).map(x => x.selector) };
};
const rows = [summary('main (before)', await run(script(oldPath), {})), summary('stack, no within', await run(script(newPath), {}))];
for (const within of scopes) rows.push(summary(`stack, within ${within}`, await run(script(newPath), { within })));
console.log(JSON.stringify({ url, firefox: (await ask('session.status', {})).result ? 'ok' : 'n/a', rows }, null, 1));
await ask('session.end', {});
ws.close(); ff.kill('SIGTERM'); await new Promise(r => ff.on('exit', r)); rmSync(profile, { recursive: true, force: true });
