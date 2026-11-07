// L7 probe b: cross-site frame cookies, busy renderer with and without urls, and an opaque origin.
// Only test cookies named masc_l7_* are logged; no call opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const port = 18774;
const origin = `http://127.0.0.1:${port}`;
const cross = `http://localhost:${port}`;
const ours = (cookies) => cookies.filter((c) => c.name.startsWith("masc_l7_"));
const names = (cookies) => ours(cookies).map((c) => c.name + "@" + c.domain).sort();
const task = await taskSpace("masc-l7-storage-b");
log("space", task.spaceId);
const p1 = task.page("p1");
const p2 = await task.newPage();
log("p2", p2.label);
await run("b.precheck", async () => names((await p1.cdp("Network.getCookies", { urls: [origin + "/", origin + "/sub/x", cross + "/"] })).cookies));
// F: a cross-site frame whose host holds a first-party cookie set by another tab.
await run("f.setFrameCookie", () => p2.goto(cross + "/setframe"));
await run("f.p2sees", () => p2.evaluate(() => document.cookie.split("; ").map((pair) => pair.split("=")[0])));
await run("f.goto", () => p1.goto(origin + "/set"));
await run("f.addFrame", () => p1.evaluate((src) => window.addFrame(src), cross + "/frame.html"));
await run("f.frameSees", () => p1.evaluate(async () => { await new Promise((r) => setTimeout(r, 300)); return window.frameCookies; }));
await run("f.noUrls", async () => names((await p1.cdp("Network.getCookies")).cookies));
await run("f.urlsTop", async () => names((await p1.cdp("Network.getCookies", { urls: [origin + "/set"] })).cookies));
// G: busy renderer; getCookies without urls, with urls, and page.url().
const busy = async () => {
  await p1.evaluate(() => { setTimeout(() => { const end = Date.now() + 3000; while (Date.now() < end) {} }, 0); return true; });
  await new Promise((r) => setTimeout(r, 200));
};
const timed = (t0, promise) => promise.then(() => Date.now() - t0, (e) => ({ error: String(e && e.message || e), ms: Date.now() - t0 }));
for (const round of [1, 2, 3, 4, 5]) {
  await run(`g.busy${round}`, async () => {
    await busy();
    const t0 = Date.now();
    const [evaluate, noUrls, withUrls, url] = await Promise.all([
      timed(t0, p1.evaluate("Date.now()")),
      timed(t0, p1.cdp("Network.getCookies")),
      timed(t0, p1.cdp("Network.getCookies", { urls: [origin + "/set"] })),
      timed(t0, p1.url()),
    ]);
    return { evaluateMs: evaluate, noUrlsMs: noUrls, withUrlsMs: withUrls, urlMs: url };
  });
}
for (const round of [1, 2, 3]) {
  await run(`g.withUrlsAlone${round}`, async () => {
    await busy();
    const t0 = Date.now();
    const [withUrls, evaluate] = await Promise.all([timed(t0, p1.cdp("Network.getCookies", { urls: [origin + "/set"] })), timed(t0, p1.evaluate("Date.now()"))]);
    return { withUrlsMs: withUrls, evaluateMs: evaluate };
  });
}
await new Promise((r) => setTimeout(r, 3200));
// H: a data: URL page has an opaque origin.
await run("h.goto", () => p2.goto("data:text/html,<p>opaque</p>"));
await run("h.url", () => p2.url());
await run("h.cookies", async () => { const r = await p2.cdp("Network.getCookies"); return { count: r.cookies.length, ours: names(r.cookies) }; });
await run("h.storage", () => p2.evaluate(async () => {
  const area = (name) => { try { return { length: window[name].length }; } catch (error) { return { error: String(error && error.name || error) }; } };
  let idb;
  try { idb = (await indexedDB.databases()).length; } catch (error) { idb = { error: String(error && error.name || error) }; }
  return { origin: location.origin, local: area("localStorage"), session: area("sessionStorage"), idb };
}));
// Cleanup: only the test cookies, by name.
await run("z.deleteCookies", async () => {
  const { cookies } = await p1.cdp("Network.getCookies", { urls: [origin + "/", origin + "/sub/x", cross + "/"] });
  const deleted = [];
  for (const c of ours(cookies)) { await p1.cdp("Network.deleteCookies", { name: c.name, domain: c.domain, path: c.path }); deleted.push(c.name + "@" + c.domain + c.path); }
  return deleted.sort();
});
await run("z.after", async () => names((await p1.cdp("Network.getCookies", { urls: [origin + "/", origin + "/sub/x", cross + "/"] })).cookies));
await run("z.finish", () => task.finish({ keep: [] }));
