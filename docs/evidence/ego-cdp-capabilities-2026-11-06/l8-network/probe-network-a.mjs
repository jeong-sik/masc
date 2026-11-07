// L8 probe a: what page.events() holds once Network.enable is on, per Page, across SDK calls and navigation.
// Logs method counts, field names and test addresses only; no header value, cookie or body is logged.
// No call opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const port = 18775;
const origin = `http://127.0.0.1:${port}`;
const cross = `http://localhost:${port}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const histogram = (events) => {
  const counts = {};
  for (const event of events) counts[event.method] = (counts[event.method] ?? 0) + 1;
  return counts;
};
const tagOf = (url) => { try { return new URL(url).searchParams.get("tag"); } catch { return null; } };
const net = (events) => events.filter((e) => typeof e.method === "string" && e.method.startsWith("Network."));
const willSend = (events) => events.filter((e) => e.method === "Network.requestWillBeSent");
const tags = (events) => {
  const counts = {};
  for (const e of willSend(events)) { const tag = tagOf(e.params.request.url) ?? new URL(e.params.request.url).pathname; counts[tag] = (counts[tag] ?? 0) + 1; }
  return counts;
};
const task = await taskSpace("masc-l8-network-a");
log("space", task.spaceId);
const p1 = task.page("p1");
await run("a1.goto", () => p1.goto(origin + "/page"));
await run("a1.reload", () => p1.reload());
await run("a1.eventsBeforeEnable", async () => { const events = await p1.events(); return { length: events.length, methods: histogram(events) }; });
await run("a2.eventsAgain", async () => (await p1.events()).length);
await run("a3.enable", () => p1.cdp("Network.enable"));
await run("a3.fire", () => p1.evaluate(() => window.fire(3, "a3")));
await sleep(300);
await run("a3.events", async () => {
  const events = await p1.events();
  const sample = {};
  for (const e of net(events)) {
    if (sample[e.method]) continue;
    const params = e.params ?? {};
    sample[e.method] = {
      eventKeys: Object.keys(e).sort(),
      paramKeys: Object.keys(params).sort(),
      requestKeys: params.request ? Object.keys(params.request).sort() : undefined,
      requestHeaderNames: params.request?.headers ? Object.keys(params.request.headers).sort() : undefined,
      responseKeys: params.response ? Object.keys(params.response).sort() : undefined,
      responseHeaderNames: params.response?.headers ? Object.keys(params.response.headers).sort() : undefined,
      type: params.type, url: params.request?.url, method: params.request?.method,
      status: params.response?.status, mimeType: params.response?.mimeType,
      encodedDataLength: params.encodedDataLength ?? params.response?.encodedDataLength,
      wallTime: typeof params.wallTime, timestamp: typeof params.timestamp,
    };
  }
  return { length: events.length, methods: histogram(events), sample };
});
// A4: two Pages, each with Network.enable.
const p2 = await task.newPage();
log("p2", p2.label);
await run("a4.p2goto", () => p2.goto(origin + "/page"));
await run("a4.p2enable", () => p2.cdp("Network.enable"));
await run("a4.drainBoth", async () => ({ p1: (await p1.events()).length, p2: (await p2.events()).length }));
await run("a4.fireBoth", async () => [await p1.evaluate(() => window.fire(2, "a4p1")), await p2.evaluate(() => window.fire(2, "a4p2"))]);
await sleep(300);
await run("a4.split", async () => ({ p1: tags(await p1.events()), p2: tags(await p2.events()) }));
// A5: the same label through task.page twice.
await run("a5.same", () => task.page(p1.label) === p1);
await run("a5.fire", () => p1.evaluate(() => window.fire(1, "a5")));
await sleep(200);
await run("a5.viaHandle", async () => tags(await task.page(p1.label).events()));
await run("a5.thenP1", async () => tags(await p1.events()));
// A6: do other SDK calls drain the buffer?
await run("a6.fire", () => p1.evaluate(() => window.fire(2, "a6")));
await sleep(200);
await run("a6.calls", async () => {
  await p1.snapshot(); await p1.url(); await p1.title(); await p1.info(); await p1.evaluate("1"); await p1.waitForTimeout(10);
  return true;
});
await run("a6.events", async () => tags(await p1.events()));
// A7: navigation to another site and a reload.
await run("a7.gotoCross", () => p1.goto(cross + "/page"));
await run("a7.fire", () => p1.evaluate(() => window.fire(2, "a7")));
await sleep(200);
await run("a7.events", async () => { const events = await p1.events(); return { tags: tags(events), methods: histogram(net(events)) }; });
await run("a7.reload", () => p1.reload());
await run("a7.reloadEvents", async () => { const events = await p1.events(); return { tags: tags(events), methods: histogram(net(events)) }; });
await run("a7.back", () => p1.goto(origin + "/page"));
await run("a7.drain", async () => (await p1.events()).length);
// A8: a redirect.
await run("a8.fetch", () => p1.evaluate(() => fetch("/redir").then((r) => r.status)));
await sleep(200);
await run("a8.events", async () => {
  const events = net(await p1.events());
  return events.filter((e) => e.method === "Network.requestWillBeSent").map((e) => ({
    requestId: e.params.requestId, path: new URL(e.params.request.url).pathname, redirectResponse: e.params.redirectResponse ? { status: e.params.redirectResponse.status } : null,
  }));
});
// A9: a refused connection and a request still waiting.
await run("a9.refused", () => p1.evaluate((u) => fetch(u).then(() => "ok", (e) => String(e)), "http://127.0.0.1:18799/x"));
await run("a9.slow", () => p1.evaluate(() => { fetch("/slow?tag=slow"); return true; }));
await sleep(300);
await run("a9.events", async () => {
  const events = net(await p1.events());
  const byId = {};
  for (const e of events) { (byId[e.params.requestId] ??= []).push(e.method.slice(8)); }
  const failed = events.filter((e) => e.method === "Network.loadingFailed").map((e) => ({ errorText: e.params.errorText, canceled: e.params.canceled, blockedReason: e.params.blockedReason, type: e.params.type }));
  return { byId: Object.values(byId), failed };
});
await sleep(2200);
await run("a9.slowEnd", async () => histogram(net(await p1.events())));
// A10: a frame of another site that fetches on load.
await run("a10.addFrame", () => p1.evaluate((src) => window.addFrame(src), cross + "/frame.html"));
await sleep(500);
await run("a10.frameDone", () => p1.evaluate(() => window.frameDone));
await run("a10.events", async () => { const events = await p1.events(); return { tags: tags(events), methods: histogram(net(events)) }; });
// A11: a large burst without draining.
await run("a11.fire", () => p1.evaluate(() => window.fire(3000, "a11")));
await sleep(500);
await run("a11.events", async () => { const events = await p1.events(); return { length: events.length, methods: histogram(events), a11: tags(events).a11 }; });
// A12: page-visible values before and after Network.enable on a fresh Page.
const p3 = await task.newPage();
const fingerprint = () => p3.evaluate(() => {
  let stackRead = false;
  const error = new Error("probe");
  Object.defineProperty(error, "stack", { get() { stackRead = true; return ""; } });
  console.debug(error);
  return { webdriver: navigator.webdriver, stackRead, plugins: navigator.plugins.length, chromeKeys: Object.keys(window.chrome ?? {}).sort(), keys: Object.keys(window).length };
});
await run("a12.goto", () => p3.goto(origin + "/page"));
await run("a12.before", fingerprint);
await run("a12.enable", () => p3.cdp("Network.enable"));
await run("a12.after", fingerprint);
await run("a12.reload", () => p3.reload());
await run("a12.afterReload", fingerprint);
// A13: a busy renderer.
const timed = (t0, promise) => promise.then(() => Date.now() - t0, (e) => ({ error: String(e && e.message || e), ms: Date.now() - t0 }));
for (const round of [1, 2, 3]) {
  const p4 = await task.newPage();
  await p4.goto(origin + "/page");
  await run(`a13.busy${round}`, async () => {
    await p4.evaluate(() => { setTimeout(() => { const end = Date.now() + 3000; while (Date.now() < end) {} }, 0); return true; });
    await sleep(200);
    const t0 = Date.now();
    const [evaluate, enable, events] = await Promise.all([timed(t0, p4.evaluate("Date.now()")), timed(t0, p4.cdp("Network.enable")), timed(t0, p4.events())]);
    return { evaluateMs: evaluate, enableMs: enable, eventsMs: events };
  });
  await sleep(3000);
  await p4.close();
}
await run("z.finish", () => task.finish({ keep: [] }));
