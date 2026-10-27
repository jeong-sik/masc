#!/usr/bin/env node
// Re-measures the assumptions behind the Ego input-release rules with the production workflow script on a real Ego.
// Run it again whenever the Ego SDK changes: node scripts/probe-browser-ego-input-release.mjs <ego executable> <output dir> [--no-stall]
//   refusal  a selector the SDK cannot resolve leaves no press behind (click, dblclick, dragAndDrop, press, drag_to)
//   stall    when the page stalls so a CDP command times out, no gesture reports its input released
//   dialog   a dialog that cuts a gesture short is reported as inputInterruptedBy=dialog and the next click starts clean
//   typing   keyboard.type into an already open dialog sends nothing and is refused before any key
// The script creates and finishes its own task Space. Exit status 1 when any expectation differs.
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createHash} from 'node:crypto';
import {join, resolve} from 'node:path';

const args = process.argv.slice(2);
const stall = !args.includes('--no-stall');
const [executable, output] = args.filter(arg => !arg.startsWith('--'));
if (!executable || !output) { console.error('usage: probe-browser-ego-input-release.mjs <ego executable> <output dir> [--no-stall]'); process.exit(2); }
mkdirSync(output, {recursive: true});

const STALL_MS = 17000; // longer than the SDK's 15 s response timeout for one CDP command
const between = (text, start, end) => text.split(start)[1].split(end)[0];
const workflowScript = between(readFileSync(new URL('../lib/browser_ego_workflow.ml', import.meta.url), 'utf8'), 'let script = {js|', '|js}');
const targetInputScript = between(readFileSync(new URL('../lib/browser_ego_peer.ml', import.meta.url), 'utf8'), 'let target_input_script = {js|', '|js}');

const frameHtml = `<!doctype html><meta charset="utf-8"><style>body{margin:8px}button,input{display:block;width:260px;height:40px;margin:4px 0;font-size:16px}</style>
<button id="fb">frame: confirm on mousedown</button><input id="fi" placeholder="frame: confirm on keydown a">
<script>
document.getElementById('fb').addEventListener('mousedown', () => { confirm('frame mousedown'); });
document.getElementById('fi').addEventListener('keydown', (e) => { if (e.key === 'a') confirm('frame keydown a'); });
</script>`;
const pageHtml = frameOrigin => `<!doctype html><meta charset="utf-8"><title>input release probe</title>
<style>body{font:18px sans-serif;margin:24px}button,input{display:block;margin:10px 0;padding:12px;font-size:18px;width:420px}</style>
<button id="ca">A: confirm on mousedown</button><button id="cb">B: confirm on click</button><button id="cc">C: plain button</button>
<button id="hid" style="display:none">hidden</button><button id="dis" disabled>disabled</button>
<input id="t1" placeholder="t1: plain input, confirm on paste"><input id="t2" placeholder="t2: confirm on keydown a">
<iframe id="fr" src="${frameOrigin}/" style="width:300px;height:120px;border:1px solid #888"></iframe>
<script>
window.__log = []; window.__dlg = []; window.__move = null; window.__busy = null;
for (const type of ['mousedown', 'mouseup', 'click', 'dblclick', 'keydown', 'keyup']) {
  document.addEventListener(type, (e) => {
    window.__log.push({type: e.type, buttons: typeof e.buttons === 'number' ? e.buttons : 0, key: e.key, repeat: e.repeat === true,
      ctrl: e.ctrlKey === true, shift: e.shiftKey === true, alt: e.altKey === true, meta: e.metaKey === true});
    if (window.__busy === type) { const t = Date.now(); while (Date.now() - t < ${STALL_MS}) {} }
  }, true);
}
document.addEventListener('mousemove', (e) => { window.__move = {buttons: e.buttons}; }, true);
document.getElementById('ca').addEventListener('mousedown', () => { confirm('A: opened from mousedown'); });
document.getElementById('cb').addEventListener('click', () => { confirm('B: opened from click'); });
document.getElementById('t1').addEventListener('paste', () => { confirm('paste: confirm in paste event'); });
document.getElementById('t2').addEventListener('keydown', (e) => { if (e.key === 'a') confirm("T2: opened from keydown 'a'"); });
</script>`;

const frameServer = createServer((req, res) => { res.setHeader('Content-Type', 'text/html'); res.end(frameHtml); });
frameServer.listen(0, '127.0.0.1'); await once(frameServer, 'listening');
const pageServer = createServer((req, res) => { res.setHeader('Content-Type', 'text/html'); res.end(pageHtml('http://127.0.0.1:' + frameServer.address().port)); });
pageServer.listen(0, 'localhost'); await once(pageServer, 'listening');
const pageUrl = 'http://localhost:' + pageServer.address().port + '/';

const code = `
const PAGE = ${JSON.stringify(pageUrl)}, STALL = ${JSON.stringify(stall)};
const out = {};
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const task = await taskSpace('masc-input-release-probe');
out.spaceId = task.spaceId;
const page = task.page('p1');
${workflowScript}
${targetInputScript}
let EXPECTED = PAGE;
const T = {timeout: 1200};
const base = steps => ({expectedUrl: EXPECTED, steps, snapshotScope: 'viewport', maxChars: 100, cursor: 'probe', label: 'probe'});
const summary = r => ({failureMethod: r.failure?.method ?? null, failureMessage: String(r.failure?.message ?? '').slice(0, 120),
  effectStarted: r.effectStarted, completedEffect: r.completedEffect, inputReleased: r.inputReleased,
  inputInterruptedBy: r.inputInterruptedBy ?? null, dialog: r.failure?.dialog?.message ?? null, completed: r.completed.map(c => c.method),
  ...(r.pointerReleased === undefined ? {} : {pointerReleased: r.pointerReleased, error: r.error, receiptDialog: r.receiptDialog ?? null})});
const clearDialog = async () => { for (let i = 0; i < 3; i++) { if (!(await page.info()).dialog) return; await page.acceptDialog(); await sleep(250); } };
const reset = async () => { await clearDialog(); await page.goto(PAGE); await sleep(400); };
const center = selector => page.evaluate(sel => { const r = document.querySelector(sel).getBoundingClientRect(); return {x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2)}; }, selector);
const frameAt = dy => page.evaluate(offset => { const r = document.getElementById('fr').getBoundingClientRect(); return {x: Math.round(r.left + 138), y: Math.round(r.top + offset)}; }, dy);
const flags = e => (e.ctrl ? 'C' : '') + (e.shift ? 'S' : '') + (e.alt ? 'A' : '') + (e.meta ? 'M' : '');
const inputEvents = () => page.evaluate(() => window.__log.length);
// What the next plain click looks like after the case: events with pressed buttons and modifiers, SDK modifier mask.
const nextClick = async () => {
  await page.evaluate(() => { window.__busy = null; window.__log.length = 0; window.__move = null; });
  const r = await nativeWorkflow(page, base([{method: 'click', selector: '#cc'}]));
  const log = await page.evaluate(() => window.__log);
  const move = await page.evaluate(() => window.__move);
  return {ok: r.failure === null && r.inputReleased === true, events: log.map(e => e.type + ':b' + e.buttons + (flags(e) ? ':' + flags(e) : '')).join(' '),
    moveButtons: move ? move.buttons : null, modifierMask: await page.keyboard.modifierMask(),
    stuck: log.some(e => (e.type === 'mousedown' && e.buttons !== 1) || flags(e) !== '' || e.repeat)};
};
const measure = async (group, name, steps, {busy = null, wait = 300} = {}) => {
  await reset();
  await page.evaluate(flag => { window.__log.length = 0; window.__busy = flag; }, busy);
  const started = Date.now();
  const result = await steps();
  const ms = Date.now() - started;
  const row = {group, name, ms, result: summary(result)};
  await sleep(wait);
  row.open = Boolean((await page.info()).dialog);
  await clearDialog();
  row.pageInputEvents = await inputEvents();
  row.next = await nextClick();
  (out.rows ??= []).push(row);
};
const one = step => () => nativeWorkflow(page, base([step]));
try {
  await page.goto(PAGE); EXPECTED = await page.url();
  // refusal: the SDK cannot resolve the selector, so nothing may have been pressed
  for (const [name, step] of [
    ['click_missing', {method: 'click', selector: '#nope', options: T}], ['click_hidden', {method: 'click', selector: '#hid', options: T}],
    ['click_disabled', {method: 'click', selector: '#dis', options: T}], ['click_bad_syntax', {method: 'click', selector: 'loc=css:[', options: T}],
    ['dblclick_missing', {method: 'dblclick', selector: '#nope', options: T}],
    ['drag_missing_source', {method: 'dragAndDrop', selector: '#nope', destination: '#cc', options: T}],
    ['drag_missing_destination', {method: 'dragAndDrop', selector: '#cc', destination: '#nope', options: T}],
    ['press_missing', {method: 'press', selector: '#nope', key: 'Enter', options: T}]]) await measure('refusal', name, one(step));
  for (const [name, args] of [['target_drag_missing_source', {target: '#nope', destination: '#cc'}], ['target_drag_missing_destination', {target: '#cc', destination: '#nope'}]])
    await measure('refusal', name, async () => { const r = await nativeTargetInput(page, {action: 'drag_to', expectedUrl: EXPECTED, cursor: 'probe', ...args});
      return {failure: null, effectStarted: true, completedEffect: false, inputReleased: r.pointerReleased, completed: [], pointerReleased: r.pointerReleased, error: String(r.error ?? '').slice(0, 80)}; });
  // dialog: the SDK reports a dialog that cuts the gesture short
  const clickT2 = {method: 'click', selector: '#t2'};
  await measure('dialog', 'click_confirm_on_mousedown', one({method: 'click', selector: '#ca'}));
  await measure('dialog', 'click_confirm_in_click_handler', one({method: 'click', selector: '#cb'}));
  await measure('dialog', 'dblclick_confirm_on_mousedown', one({method: 'dblclick', selector: '#ca'}));
  await measure('dialog', 'dragAndDrop_confirm_on_mousedown', one({method: 'dragAndDrop', selector: '#ca', destination: '#t1'}));
  await measure('dialog', 'mouse_click_confirm_on_mousedown', async () => { const c = await center('#ca'); return nativeWorkflow(page, base([{method: 'mouse.click', x: c.x, y: c.y}])); });
  await measure('dialog', 'press_chord_confirm_on_keydown', async () => nativeWorkflow(page, base([clickT2, {method: 'keyboard.press', key: 'Control+a'}])));
  await measure('dialog', 'selector_press_confirm_on_keydown', one({method: 'press', selector: '#t2', key: 'a'}));
  await measure('dialog', 'type_confirm_on_keydown', async () => nativeWorkflow(page, base([clickT2, {method: 'keyboard.type', text: 'a'}])));
  await measure('dialog', 'paste_confirm_in_paste_event', async () => nativeWorkflow(page, base([{method: 'click', selector: '#t1'}, {method: 'keyboard.paste', text: 'pasted'}])));
  await measure('dialog', 'frame_click_confirm_cross_site', async () => { const c = await frameAt(28); return nativeWorkflow(page, base([{method: 'mouse.click', x: c.x, y: c.y}])); });
  await measure('dialog', 'frame_type_confirm_cross_site', async () => { const c = await frameAt(80); return nativeWorkflow(page, base([{method: 'mouse.click', x: c.x, y: c.y}, {method: 'keyboard.type', text: 'a'}])); });
  await measure('dialog', 'target_drag_confirm_on_mousedown', async () => { const r = await nativeTargetInput(page, {action: 'drag_to', expectedUrl: EXPECTED, cursor: 'probe', target: '#ca', destination: '#cc'});
    return {failure: null, effectStarted: true, completedEffect: false, inputReleased: r.pointerReleased, completed: [], pointerReleased: r.pointerReleased, error: r.error, receiptDialog: r.receipt?.dialog?.message ?? null}; });
  // stall: a page that stops answering input commands; no gesture may report its input released
  if (STALL) {
    const stalled = {wait: 5000};
    await measure('stall', 'press_keydown_stalled', one({method: 'press', selector: '#t1', key: 'a'}), {busy: 'keydown', ...stalled});
    await measure('stall', 'keyboard_press_keydown_stalled', async () => nativeWorkflow(page, base([{method: 'click', selector: '#t1'}, {method: 'keyboard.press', key: 'a'}])), {busy: 'keydown', ...stalled});
    await measure('stall', 'click_mousedown_stalled', one({method: 'click', selector: '#cc'}), {busy: 'mousedown', ...stalled});
    await measure('stall', 'click_mouseup_stalled', one({method: 'click', selector: '#cc'}), {busy: 'mouseup', ...stalled});
    await measure('stall', 'dblclick_mouseup_stalled', one({method: 'dblclick', selector: '#cc'}), {busy: 'mouseup', ...stalled});
    await measure('stall', 'dragAndDrop_mouseup_stalled', one({method: 'dragAndDrop', selector: '#cc', destination: '#t1'}), {busy: 'mouseup', ...stalled});
  }
  // typing: a dialog that is already open when keyboard.type starts
  await reset();
  await page.evaluate(() => { document.getElementById('t1').value = ''; });
  const plain = await nativeWorkflow(page, base([{method: 'click', selector: '#t1'}, {method: 'keyboard.type', text: 'hello'}]));
  out.plainTyping = {...summary(plain), value: await page.evaluate(() => document.getElementById('t1').value)};
  await reset();
  await nativeWorkflow(page, base([{method: 'click', selector: '#ca'}]));
  await page.events();
  const raw = await page.keyboard.type('hello');
  out.rawTypeIntoOpenDialog = {returned: raw === undefined ? 'undefined' : typeof raw, newOpeningEvents: (await page.events()).filter(e => e?.method === 'Page.javascriptDialogOpening').length,
    stillOpen: Boolean((await page.info()).dialog)};
  await reset();
  await page.evaluate(() => { setTimeout(() => confirm('timer dialog'), 300); });
  out.typeIntoTimerDialog = summary(await nativeWorkflow(page, base([{method: 'waitForTimeout', milliseconds: 900}, {method: 'keyboard.type', text: 'hello'}])));
} finally {
  try { await clearDialog(); } catch (error) {}
  await task.finish({keep: []});
  console.log('INPUT_RELEASE_PROBE ' + JSON.stringify(out));
}
`;

const run = await new Promise((done, fail) => {
  const child = spawn(executable, ['nodejs', '-e', code], {stdio: ['ignore', 'pipe', 'pipe']});
  let log = '';
  child.stdout.on('data', chunk => { log += chunk; });
  child.stderr.on('data', chunk => { log += chunk; });
  const timer = setTimeout(() => { log += '\nDRIVER timed out'; child.kill('SIGKILL'); }, 900000);
  child.once('error', fail);
  child.once('close', status => { clearTimeout(timer); done({status, log}); });
});
frameServer.closeAllConnections(); pageServer.closeAllConnections(); frameServer.close(); pageServer.close();
writeFileSync(join(output, 'sdk-output.txt'), run.log);
const line = run.log.split('\n').find(row => row.startsWith('INPUT_RELEASE_PROBE '));
if (!line) { console.error('no probe report; see ' + join(resolve(output), 'sdk-output.txt') + '\n' + run.log.slice(-1500)); process.exit(1); }
const report = JSON.parse(line.slice('INPUT_RELEASE_PROBE '.length));

const failures = [];
const expect = (name, ok, detail) => { console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(detail))); if (!ok) failures.push(name); };
for (const row of report.rows ?? []) {
  const {result, next} = row;
  const cleanNext = next.ok && !next.stuck && next.modifierMask === 0 && next.moveButtons === 0;
  if (row.group === 'refusal') {
    const preflight = row.name === 'press_missing';
    const released = row.name.startsWith('target_drag') ? result.pointerReleased === true : result.inputReleased === true;
    expect(`refusal ${row.name}: input released, page saw no input`, released && row.pageInputEvents === 0
      && (preflight ? result.failureMethod === 'inputPreflight' && result.effectStarted === false : true), row);
    expect(`refusal ${row.name}: the next click starts clean`, cleanNext, next);
  } else if (row.group === 'dialog') {
    const reported = row.name.startsWith('target_drag')
      ? result.pointerReleased === false && result.error === null && typeof result.receiptDialog === 'string'
      : result.inputReleased === false && result.inputInterruptedBy === 'dialog' && typeof result.dialog === 'string';
    expect(`dialog ${row.name}: reported as a dialog interruption`, reported, result);
    expect(`dialog ${row.name}: the next click starts clean`, cleanNext, next);
  } else if (row.group === 'stall') {
    expect(`stall ${row.name}: input is not reported released (${row.ms} ms)`, result.inputReleased === false && result.failureMethod !== null, result);
  }
}
const plain = report.plainTyping, raw = report.rawTypeIntoOpenDialog, timer = report.typeIntoTimerDialog;
expect('typing plain: types the text and releases', plain?.failureMethod === null && plain.inputReleased === true && plain.value === 'hello', plain);
expect('typing raw SDK into an open dialog: void, no new opening event, dialog stays', raw?.returned === 'undefined' && raw.newOpeningEvents === 0 && raw.stillOpen === true, raw);
expect('typing into a dialog opened between steps: refused before any key', timer?.failureMethod === 'keyboard.type' && timer.inputReleased === true
  && timer.inputInterruptedBy === null && timer.dialog === 'timer dialog' && timer.completed.join() === 'waitForTimeout', timer);
writeFileSync(join(output, 'report.json'), JSON.stringify({
  sdkVersion: run.log.match(/current (\d+(?:\.\d+)+)/)?.[1] ?? null, scope: 'Production workflow and drag_to scripts on the installed Ego against an owned local fixture; Ego Lite only',
  workflowScriptSha256: createHash('sha256').update(workflowScript).digest('hex'), stall, report, failures}, null, 2));
console.log(failures.length === 0 ? 'all expectations hold' : failures.length + ' expectation(s) differ; see ' + join(resolve(output), 'report.json'));
process.exit(failures.length === 0 ? 0 : 1);
