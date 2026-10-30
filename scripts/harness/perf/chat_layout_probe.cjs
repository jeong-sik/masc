// Run against Vite serving this checkout; no production server writes or build.
// node scripts/harness/perf/chat_layout_probe.cjs <dev-origin> <output-directory>
const path = require('node:path');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '../../..');
const {
  chromium
} = require(path.join(root, 'dashboard/node_modules/playwright'));
if (process.argv.length !== 4) throw new Error('Expected <dev-origin> <output-directory>');
const origin = new URL(process.argv[2]);
if (!['http:', 'https:'].includes(origin.protocol) || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash) throw new Error('Expected an HTTP(S) origin');
const output = path.resolve(process.argv[3]);
fs.mkdirSync(output, {
  recursive: true
});
const hashes = Object.fromEntries(['dashboard/src/components/chat/primitives.ts', 'dashboard/src/styles/chat.css', 'dashboard/src/styles/chat-layout.css', 'dashboard/src/demo/chat-layout-perf-fixture.ts', 'dashboard/pnpm-lock.yaml'].map(file => [file, crypto.createHash('sha256').update(fs.readFileSync(path.join(root, file))).digest('hex')]));
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({
    viewport: {
      width: 1440,
      height: 1000
    }
  });
  const errors = [];
  p.on('pageerror', e => errors.push(e.message));
  await p.route('**/__chat-layout-probe', route => route.fulfill({
    contentType: 'text/html',
    body: '<!doctype html><html><head><link rel="stylesheet" href="/dashboard/src/styles/global.css"></head><body><div id="fixture" class="v2-app" style="height:800px;width:900px;display:flex;flex-direction:column;margin:40px auto"></div></body></html>'
  }));
  await p.goto(new URL('/dashboard/__chat-layout-probe', origin).href);
  await p.evaluate(async () => {
    const module = await import('/dashboard/src/demo/chat-layout-perf-fixture.ts');
    window.mountChatFixture = module.mountChatLayoutPerfFixture;
    window.override = document.createElement('style');
    document.head.appendChild(window.override);
  });
  const cdp = await p.context().newCDPSession(p);
  await cdp.send('Performance.enable');
  const result = [];
  for (const variant of ['baseline', 'contained', 'contained', 'baseline', 'baseline', 'contained']) {
    await p.evaluate(variant => {
      window.chatFixture?.unmount();
      window.override.textContent = variant === 'baseline' ? '.chat-transcript-content > :not(.kw-daydiv) {content-visibility:visible;contain-intrinsic-block-size:none}' : '';
    }, variant);
    const before = await cdp.send('Performance.getMetrics');
    const mount = await p.evaluate(() => {
      const started = performance.now();
      window.chatFixture = window.mountChatFixture(document.querySelector('#fixture'));
      return performance.now() - started;
    });
    await p.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
    const after = await cdp.send('Performance.getMetrics');
    const state = await p.locator('.chat-transcript').evaluate(e => ({
      rows: e.querySelector('.chat-transcript-content').children.length,
      nodes: e.querySelectorAll('*').length,
      distance: -e.scrollTop,
      containment: getComputedStyle(e.querySelector('.chat-transcript-content').children[2]).contentVisibility
    }));
    const metrics = {};
    for (const key of ['LayoutCount', 'LayoutDuration', 'RecalcStyleDuration', 'ScriptDuration', 'TaskDuration']) metrics[key] = after.metrics.find(x => x.name === key).value - before.metrics.find(x => x.name === key).value;
    result.push({
      variant,
      mount_ms: mount,
      state,
      metrics
    });
    await p.waitForTimeout(200);
  }
  const scroll = p.locator('.chat-transcript');
  const snapshot = () => scroll.evaluate(e => ({
    top: e.scrollTop,
    distance: -e.scrollTop,
    rows: e.querySelector('.chat-transcript-content').children.length,
    height: e.clientHeight
  }));
  const initial = await snapshot();
  await scroll.hover();
  await p.mouse.wheel(0, -1500);
  await p.waitForTimeout(200);
  const beforeAppend = await snapshot();
  const anchor = await scroll.evaluate(e => {
    const r = e.getBoundingClientRect();
    const row = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
      ?.closest('[data-chat-entry-id]');
    if (!row) throw new Error('No visible history row at the viewport center');
    return { id: row.getAttribute('data-chat-entry-id'), y: row.getBoundingClientRect().top };
  });
  await p.evaluate(() => window.chatFixture.append());
  await p.waitForTimeout(200);
  const afterAppend = await snapshot();
  const anchorAfter = await p.evaluate(id =>
    document.querySelector(`[data-chat-entry-id="${CSS.escape(id)}"]`).getBoundingClientRect().top,
    anchor.id);
  const jump = p.locator('[data-chat-jump-latest]');
  await jump.click();
  await p.waitForTimeout(200);
  const jumped = await snapshot();
  await p.evaluate(() => window.chatFixture.growLast());
  await p.waitForTimeout(200);
  const streaming = await snapshot();
  await scroll.evaluate(e => {
    e.scrollTop = -e.scrollHeight;
  });
  await p.waitForTimeout(200);
  const top = await snapshot();
  const media = p.locator('[data-chat-block="svg"]');
  console.log('svg targets', await media.count());
  await media.scrollIntoViewIfNeeded();
  await media.locator('.chat-block-media-frame').click();
  const dialog = p.locator('[role="dialog"]');
  await dialog.waitFor();
  const modal = await dialog.evaluate(e => {
    const r = e.getBoundingClientRect();
    return {
      parent: e.parentElement.tagName,
      x: r.x,
      y: r.y,
      width: r.width,
      height: r.height
    };
  });
  await p.screenshot({
    path: path.join(output, 'preview.png')
  });
  await p.keyboard.press('Escape');
  await dialog.waitFor({
    state: 'detached'
  });
  await p.screenshot({
    path: path.join(output, 'transcript.png')
  });
  const shortAlignment = async () => scroll.evaluate(e => {
    const row = e.querySelector('.chat-transcript-content').firstElementChild;
    return row.getBoundingClientRect().top - e.getBoundingClientRect().top
      - e.clientTop - parseFloat(getComputedStyle(e).paddingTop);
  });
  await p.evaluate(() => window.chatFixture.short());
  await p.waitForTimeout(100);
  const shortOffset = await shortAlignment();
  await p.evaluate(() => window.chatFixture.clear());
  await p.waitForTimeout(100);
  const emptyOffset = await shortAlignment();
  const evidence = {
    observed_at: new Date().toISOString(),
    origin: origin.origin,
    browser: await b.version(),
    scope: 'Current source fixture; baseline disables only row content-visibility, not a deployed binary comparison',
    hashes,
    runs: result,
    interaction: {
      initial,
      beforeAppend,
      afterAppend,
      anchor,
      anchorAfter,
      jumped,
      streaming,
      top,
      modal,
      shortOffset,
      emptyOffset
    },
    errors
  };
  fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify(evidence, null, 2));
  console.log(JSON.stringify(evidence, null, 2));
  await b.close();
  assert.equal(errors.length, 0);
  for (const run of result) {
    assert.equal(run.state.rows, 401);
    assert.ok(Math.abs(run.state.distance) <= 1);
  }
  assert.ok(beforeAppend.distance > 100);
  assert.ok(afterAppend.distance > 100);
  assert.ok(Math.abs(anchor.y - anchorAfter) <= 1, 'visible history anchor moved after append');
  assert.ok(Math.abs(jumped.distance) <= 1);
  assert.ok(Math.abs(streaming.distance) <= 1);
  assert.equal(modal.parent, 'BODY');
  assert.deepEqual([modal.x, modal.y, modal.width, modal.height], [0, 0, 1440, 1000]);
  assert.ok(Math.abs(shortOffset) <= 1, 'short transcript must start at the top');
  assert.ok(Math.abs(emptyOffset) <= 1, 'empty transcript must start at the top');
})().catch(e => {
  console.error(e);
  process.exit(1);
});
