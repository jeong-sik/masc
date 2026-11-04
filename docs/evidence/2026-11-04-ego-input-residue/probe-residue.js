// RFC #48037 M1-M3 + E: does a dialog-interrupted Ego input leave a key or
// button held, on the same Page or another Page of the same task space, and
// do the SDK's public release calls clear it? Runs inside `ego-browser nodejs`.
// Owns one task space and finishes it.
const FIXTURE = '__FIXTURE__';
const SPACE = 'probe-input-residue-1104';
const out = {cases: [], before: null, after: null, errors: []};
const msg = e => String((e && e.message) || e).slice(0, 160);
const listSpaces = async () => typeof listTaskSpaces === 'function'
  ? (await listTaskSpaces()).map(s => ({id: s.id ?? s.spaceId, name: s.name})) : 'unavailable';
out.before = await listSpaces();
const task = await taskSpace(SPACE);
const p1 = task.page('p1'), p2 = await task.newPage();
const settleDialogs = async () => {
  for (const pg of [p1, p2]) { try { await pg.acceptDialog(); } catch (e) { /* none open */ } }
};
const reset = async pg => pg.evaluate(() => {
  window.log = []; window.trap = null; window.onbeforeunload = null;
  for (const id of ['editor', 'probeInput']) document.getElementById(id).value = '';
});
const probe = async pg => {
  await pg.evaluate(() => { window.log = []; document.getElementById('probeInput').value = ''; });
  let clickError = null, typeError = null;
  try { await pg.click('loc=css:#probe'); } catch (e) { clickError = msg(e); }
  try { await pg.click('loc=css:#probeInput'); await pg.keyboard.type('ab'); } catch (e) { typeError = msg(e); }
  const r = await pg.evaluate(() => ({log: window.log, value: document.getElementById('probeInput').value}));
  const mousedown = r.log.filter(e => e.t === 'mousedown' && e.id === 'probe').map(e => e.b);
  const keydowns = r.log.filter(e => e.t === 'keydown' && e.id === 'probeInput');
  const result = {
    clickError, typeError, value: r.value, mousedownButtons: mousedown,
    clicks: r.log.filter(e => e.t === 'click' && e.id === 'probe').length,
    modifierEvents: r.log.filter(e => e.sh || e.ct || e.al || e.me).map(e => e.t + ':' + e.k),
    repeats: keydowns.filter(e => e.rp).map(e => e.k),
    heldMoves: r.log.filter(e => e.t === 'mousemove').length,
    mask: await pg.keyboard.modifierMask(),
  };
  result.residue = clickError !== null || typeError !== null || result.value !== 'ab'
    || JSON.stringify(mousedown) !== '[1]' || result.clicks !== 1 || result.modifierEvents.length > 0
    || result.repeats.length > 0 || result.heldMoves > 0 || result.mask !== 0;
  return result;
};
const runCase = async (label, setup, act, extra) => {
  const row = {label};
  try {
    await reset(p1); await reset(p2);
    await p1.evaluate(setup);
    const started = Date.now();
    try { const receipt = await act(); row.answer = receipt === undefined ? 'void' : receipt; }
    catch (e) { row.thrown = {name: e && e.name, kind: e && e.kind, code: e && e.code, message: msg(e)}; }
    row.ms = Date.now() - started;
    const info = await p1.info().catch(e => ({error: msg(e)}));
    row.dialogOpenAfter = !!(info && info.dialog);
    row.accepted = await p1.acceptDialog().catch(() => false);
    row.interrupted = await p1.evaluate(() => window.trap === null);
    row.samePage = await probe(p1);
    row.otherPage = await probe(p2);
    if (extra) row.extra = await extra();
  } catch (e) { row.error = msg(e); await settleDialogs(); }
  out.cases.push(row);
};
try {
  await p1.goto(FIXTURE + '?p=1'); await p2.goto(FIXTURE + '?p=2');
  const baseline = {label: 'baseline', samePage: await probe(p1), otherPage: await probe(p2)};
  out.cases.push(baseline);
  const gestures = [
    ['click', {event: 'mousedown', id: 'target'}, () => p1.click('loc=css:#target')],
    ['dblclick', {event: 'mousedown', id: 'target'}, () => p1.dblclick('loc=css:#target')],
    ['dragAndDrop', {event: 'mousedown', id: 'src'}, () => p1.dragAndDrop('loc=css:#src', 'loc=css:#dst')],
    ['press Shift+a', {event: 'keydown', id: 'editor', key: 'A'}, () => p1.press('loc=css:#editor', 'Shift+a')],
    ['keyboard.press Shift+a', {event: 'keydown', id: 'editor', key: 'A'},
      async () => { await p1.focus('loc=css:#editor'); return p1.keyboard.press('Shift+a'); }],
    ['keyboard.type ab', {event: 'keydown', id: 'editor', key: 'a'},
      async () => { await p1.focus('loc=css:#editor'); return p1.keyboard.type('ab'); }],
  ];
  for (const [name, trap, act] of gestures)
    for (const type of ['alert', 'confirm', 'prompt'])
      await runCase(`M1/M2 ${name} cut by ${type} on ${trap.event}`,
        new Function(`window.trap = ${JSON.stringify({...trap, type})};`), act);
  // M3a: a confirm opened on mouseup
  await runCase('M3 click cut by confirm on mouseup',
    () => { window.trap = {event: 'mouseup', id: 'target', type: 'confirm'}; }, () => p1.click('loc=css:#target'));
  // M3b: beforeunload on a link click (sticky activation exists from earlier clicks); stay on the page
  {
    const row = {label: 'M3 beforeunload on link click, dismissed'};
    try {
      await reset(p1); await reset(p2);
      await p1.evaluate(() => { window.onbeforeunload = e => { e.preventDefault(); e.returnValue = ''; return ''; }; });
      try { const r = await p1.click('loc=css:#leave'); row.answer = r === undefined ? 'void' : r; }
      catch (e) { row.thrown = {name: e && e.name, message: msg(e)}; }
      const info = await p1.info().catch(e => ({error: msg(e)}));
      row.dialogOpenAfter = !!(info && info.dialog); row.dialog = info && info.dialog;
      row.dismissed = await p1.dismissDialog().catch(() => false);
      row.url = await p1.url();
      row.samePage = await probe(p1); row.otherPage = await probe(p2);
    } catch (e) { row.error = msg(e); await settleDialogs(); }
    out.cases.push(row);
  }
  // M3c + E: a raw coordinate press cut by an alert, then the SDK's own mouse.up
  {
    const row = {label: 'M3 raw mouse.down cut by alert, then E mouse.up'};
    try {
      await reset(p1); await reset(p2);
      const box = await p1.evaluate(() => { const r = document.getElementById('target').getBoundingClientRect();
        return {x: r.x + r.width / 2, y: r.y + r.height / 2}; });
      const probeBox = await p1.evaluate(() => { const r = document.getElementById('probe').getBoundingClientRect();
        return {x: r.x + r.width / 2, y: r.y + r.height / 2}; });
      await p1.evaluate(() => { window.trap = {event: 'mousedown', id: 'target', type: 'alert'}; });
      await p1.mouse.move(box.x, box.y);
      try { row.downAnswer = (await p1.mouse.down()) === undefined ? 'void' : 'value'; }
      catch (e) { row.thrown = {name: e && e.name, message: msg(e)}; }
      row.dialogOpenAfter = !!((await p1.info()).dialog);
      row.accepted = await p1.acceptDialog().catch(() => false);
      const coordinateClick = async () => {
        await p1.evaluate(() => { window.log = []; });
        await p1.mouse.click(probeBox.x, probeBox.y);
        return p1.evaluate(() => window.log.filter(e => ['pointerdown', 'mousedown', 'mouseup', 'click', 'mousemove'].includes(e.t))
          .map(e => `${e.t}:${e.id}:b${e.b}`));
      };
      row.coordinateClickBeforeRelease = await coordinateClick();
      row.selectorProbeBeforeRelease = await probe(p1);
      try { await p1.mouse.up(); row.released = true; } catch (e) { row.releaseError = msg(e); }
      row.coordinateClickAfterRelease = await coordinateClick();
      row.otherPage = await probe(p2);
    } catch (e) { row.error = msg(e); await settleDialogs(); }
    out.cases.push(row);
  }
  // E for keys: typing cut on its first key, then the SDK's own keyboard.up for that key
  {
    const row = {label: 'E keyboard.type cut by alert, then keyboard.up(a)'};
    try {
      await reset(p1); await reset(p2);
      await p1.evaluate(() => { window.trap = {event: 'keydown', id: 'editor', key: 'a', type: 'alert'}; });
      await p1.focus('loc=css:#editor');
      try { await p1.keyboard.type('ab'); } catch (e) { row.thrown = msg(e); }
      row.accepted = await p1.acceptDialog().catch(() => false);
      row.beforeRelease = await probe(p1);
      await p1.focus('loc=css:#editor');
      await p1.evaluate(() => { window.log = []; });
      try { await p1.keyboard.up('a'); row.released = true; } catch (e) { row.releaseError = msg(e); }
      row.releaseEvents = await p1.evaluate(() => window.log.map(e => `${e.t}:${e.id}:${e.k}`));
      row.afterRelease = await probe(p1);
    } catch (e) { row.error = msg(e); await settleDialogs(); }
    out.cases.push(row);
  }
} catch (e) { out.errors.push(msg(e)); }
finally {
  await settleDialogs();
  try { await task.finish({keep: []}); } catch (e) { out.errors.push('finish: ' + msg(e)); }
  out.after = await listSpaces();
}
console.log('PROBE_RESULT ' + JSON.stringify(out));
