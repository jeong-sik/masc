// One Node process, as masc's ego session: each block reopens the task space
// by id, as every masc command script does (lib/browser_ego_peer.ml script).
const size = page => page.evaluate(() => ({w: innerWidth, h: innerHeight, dpr: devicePixelRatio}));
const out = {};
const first = await taskSpace("masc-l2-viewport");
out.spaceId = first.spaceId;
await first.page("p1").goto("http://127.0.0.1:18768/index.html");
out.before = await size(first.page("p1"));
out.set = await first.page("p1").cdp("Emulation.setDeviceMetricsOverride", {width: 800, height: 600, deviceScaleFactor: 0, mobile: false});
out.sameScript = await size(first.page("p1"));
const second = await taskSpace(out.spaceId);
out.reopened = await size(second.page("p1"));
await new Promise(resolve => setTimeout(resolve, 2000));
const third = await taskSpace(out.spaceId);
out.afterTwoSeconds = await size(third.page("p1"));
await third.page("p1").goto("http://127.0.0.1:18768/index.html?moved=1");
out.afterGoto = await size(third.page("p1"));
await third.page("p1").reload();
out.afterReload = await size(third.page("p1"));
const fourth = await taskSpace(out.spaceId);
out.clear = await fourth.page("p1").cdp("Emulation.clearDeviceMetricsOverride", {});
out.cleared = await size(fourth.page("p1"));
out.small = await fourth.page("p1").cdp("Emulation.setDeviceMetricsOverride", {width: 100, height: 100, deviceScaleFactor: 0, mobile: false}).then(() => size(fourth.page("p1")), error => ({error: String(error && error.message || error)}));
out.large = await fourth.page("p1").cdp("Emulation.setDeviceMetricsOverride", {width: 4096, height: 4096, deviceScaleFactor: 0, mobile: false}).then(() => size(fourth.page("p1")), error => ({error: String(error && error.message || error)}));
await fourth.page("p1").cdp("Emulation.clearDeviceMetricsOverride", {});
out.end = await size(fourth.page("p1"));
await fourth.finish({keep: []});
console.log(JSON.stringify(out, null, 1));
