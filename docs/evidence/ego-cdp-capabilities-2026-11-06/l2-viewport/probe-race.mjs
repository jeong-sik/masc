// How often does a read right after the CDP call still see the old size?
const read = page => page.evaluate(() => ({w: innerWidth, h: innerHeight}));
const framed = page => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve({w: innerWidth, h: innerHeight})))));
const task = await taskSpace("masc-l2-viewport-race");
const page = task.page("p1");
await page.goto("http://127.0.0.1:18768/index.html");
const natural = await read(page);
const sizes = [[100, 100], [4096, 4096], [800, 600], [1280, 720], [375, 812]];
const rows = [];
for (let round = 0; round < 20; round++) {
  for (const [width, height] of sizes) {
    await page.cdp("Emulation.setDeviceMetricsOverride", {width, height, deviceScaleFactor: 0, mobile: false});
    const now = await read(page), later = await framed(page);
    rows.push({kind: "set", want: [width, height], now: [now.w, now.h], later: [later.w, later.h]});
    await page.cdp("Emulation.clearDeviceMetricsOverride", {});
    const cnow = await read(page), clater = await framed(page);
    rows.push({kind: "clear", want: [natural.w, natural.h], now: [cnow.w, cnow.h], later: [clater.w, clater.h]});
  }
}
const same = (a, b) => a[0] === b[0] && a[1] === b[1];
const summary = {};
for (const kind of ["set", "clear"]) {
  const these = rows.filter(row => row.kind === kind);
  summary[kind] = {count: these.length, staleNow: these.filter(row => !same(row.now, row.want)).length,
    staleAfterTwoFrames: these.filter(row => !same(row.later, row.want)).length};
}
await task.finish({keep: []});
console.log(JSON.stringify({spaceId: task.spaceId, natural, summary, staleRows: rows.filter(row => !same(row.now, row.want)).slice(0, 10)}, null, 1));
