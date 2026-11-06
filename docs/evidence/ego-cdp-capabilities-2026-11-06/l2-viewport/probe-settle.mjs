// After clearDeviceMetricsOverride, how long until the page's size changes?
const waitChange = (page, w, h, budgetMs) => page.evaluate(`new Promise(resolve => {
  const start = performance.now();
  const tick = () => {
    const elapsed = performance.now() - start;
    if (innerWidth !== ${w} || innerHeight !== ${h}) resolve({changed: true, ms: Math.round(elapsed), w: innerWidth, h: innerHeight});
    else if (elapsed > ${budgetMs}) resolve({changed: false, ms: Math.round(elapsed), w: innerWidth, h: innerHeight});
    else setTimeout(tick, 10);
  };
  tick();
})`);
const task = await taskSpace("masc-l2-viewport-settle");
const page = task.page("p1");
await page.goto("http://127.0.0.1:18768/index.html");
const natural = await page.evaluate("[innerWidth, innerHeight]");
const sizes = [[100, 100], [4096, 4096], [800, 600], [1280, 720], [375, 812]];
const rows = [];
for (let round = 0; round < 20; round++) for (const [width, height] of sizes) {
  await page.cdp("Emulation.setDeviceMetricsOverride", {width, height, deviceScaleFactor: 0, mobile: false});
  await page.cdp("Emulation.clearDeviceMetricsOverride", {});
  rows.push(await waitChange(page, width, height, 3000));
}
// A clear with no override active: the size must not change.
const idle = await (async () => { await page.cdp("Emulation.clearDeviceMetricsOverride", {}); return waitChange(page, natural[0], natural[1], 1000); })();
const ms = rows.filter(r => r.changed).map(r => r.ms).sort((a, b) => a - b);
const q = p => ms[Math.min(ms.length - 1, Math.floor(p * ms.length))];
await task.finish({keep: []});
console.log(JSON.stringify({spaceId: task.spaceId, natural, trials: rows.length, changed: ms.length,
  wrongSizeAfterChange: rows.filter(r => r.changed && (r.w !== natural[0] || r.h !== natural[1])).length,
  msP50: q(0.5), msP90: q(0.9), msP99: q(0.99), msMax: ms[ms.length - 1], idleClear: idle}, null, 1));
