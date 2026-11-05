// Probe: what does the installed Ego SDK throw when click/dblclick/dragAndDrop
// cannot resolve its target, and does the page see any pointer event first?
// Runs inside `ego-browser nodejs`. Owns one task space and finishes it.
const FIXTURE = '__FIXTURE__';
const SPACE = 'probe-prepress-1104';
const out = {version: null, before: null, after: null, cases: []};
const describe = error => error == null ? null : ({
  ctor: error && error.constructor && error.constructor.name,
  name: error && error.name,
  kind: error && error.kind,
  keys: error && typeof error === 'object' ? Object.keys(error) : [],
  message: String(error && error.message || error).slice(0, 200),
});
const listSpaces = async () => typeof listTaskSpaces === 'function'
  ? (await listTaskSpaces()).map(s => ({id: s.id ?? s.spaceId, name: s.name, ownership: s.ownership})) : 'unavailable';
out.before = await listSpaces();
const task = await taskSpace(SPACE);
try {
  const page = task.page('p1');
  await page.goto(FIXTURE);
  const drain = () => page.evaluate(() => { const l = window.log; window.log = []; return l; });
  const run = async (label, fn) => {
    await drain();
    const started = Date.now();
    let receipt = null, error = null;
    try { receipt = await fn(); } catch (e) { error = e; }
    out.cases.push({label, ms: Date.now() - started, receipt: receipt === undefined ? 'undefined' : receipt,
      error: describe(error), events: await drain()});
  };
  await run('control click #ok', () => page.click('loc=css:#ok'));
  await run('click ambiguous text', () => page.click('text="dev-frontend"'));
  await run('click missing', () => page.click('loc=css:#missing'));
  await run('click hidden', () => page.click('loc=css:#hidden'));
  await run('click disabled', () => page.click('loc=css:#disabled'));
  await run('click covered by overlay', () => page.click('loc=css:#covered'));
  await run('click stale ref', () => page.click('@99999'));
  await run('dblclick missing', () => page.dblclick('loc=css:#missing'));
  await run('dblclick ambiguous text', () => page.dblclick('text="dev-frontend"'));
  await run('dragAndDrop missing source', () => page.dragAndDrop('loc=css:#missing', 'loc=css:#dst'));
  await run('dragAndDrop missing destination', () => page.dragAndDrop('loc=css:#src', 'loc=css:#missing'));
  await run('press missing (excluded, info only)', () => page.press('loc=css:#missing', 'Enter'));
  out.modifierMask = typeof page.keyboard?.modifierMask === 'function' ? await page.keyboard.modifierMask() : 'unavailable';
  await run('final control click #ok', () => page.click('loc=css:#ok'));
} finally {
  await task.finish({keep: []});
  out.after = await listSpaces();
}
console.log('PROBE_RESULT ' + JSON.stringify(out));
