// L7 probe a: Network.getCookies and storage names on one Page, without Network.enable.
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
const shape = (cookies) => ours(cookies).map((c) => ({
  name: c.name, domain: c.domain, path: c.path, httpOnly: c.httpOnly, secure: c.secure, session: c.session,
  expiresPositive: c.expires > 0, sameSite: c.sameSite === undefined ? "(absent)" : c.sameSite,
  valueLength: typeof c.value === "string" ? c.value.length : null, keys: Object.keys(c).sort(),
}));
const names = (cookies) => ours(cookies).map((c) => c.name).sort();
const task = await taskSpace("masc-l7-storage-a");
log("space", task.spaceId);
const p1 = task.page("p1");
const p2 = task.page("p2");
await run("a.precheck", async () => names((await p1.cdp("Network.getCookies", { urls: [origin + "/", origin + "/sub/x", cross + "/"] })).cookies));
await run("a.goto", () => p1.goto(origin + "/set"));
await run("a.seed", () => p1.evaluate(async () => {
  document.cookie = "masc_l7_js=JS_SECRET_VALUE; path=/";
  localStorage.setItem("masc_l7_local", "LOCAL_SECRET_VALUE");
  sessionStorage.setItem("masc_l7_session", "SESSION_SECRET_VALUE");
  const opened = await new Promise((resolve) => {
    const request = indexedDB.open("masc_l7_db");
    request.onsuccess = () => { request.result.close(); resolve(true); };
    request.onerror = () => resolve(String(request.error));
  });
  return { documentCookieNames: document.cookie.split("; ").map((pair) => pair.split("=")[0]).filter((n) => n.startsWith("masc_l7_")).sort(), opened };
}));
// A: no urls argument, Network domain never enabled.
await run("a.noUrls", async () => { const t0 = Date.now(); const r = await p1.cdp("Network.getCookies"); return { ms: Date.now() - t0, rows: shape(r.cookies) }; });
await run("a.urlsTop", async () => names((await p1.cdp("Network.getCookies", { urls: [origin + "/set"] })).cookies));
await run("a.urlsSub", async () => names((await p1.cdp("Network.getCookies", { urls: [origin + "/sub/x"] })).cookies));
// B: a cross-site frame whose host has its own first-party cookie.
await run("b.setFrameCookie", () => p2.goto(cross + "/setframe"));
await run("b.addFrame", () => p1.evaluate((src) => window.addFrame(src), cross + "/frame.html"));
await run("b.frameSees", () => p1.evaluate(async () => { await new Promise((r) => setTimeout(r, 300)); return window.frameCookies; }));
await run("b.noUrls", async () => names((await p1.cdp("Network.getCookies")).cookies));
await run("b.urlsTop", async () => names((await p1.cdp("Network.getCookies", { urls: [await p1.url()] })).cookies));
await run("b.p2noUrls", async () => names((await p2.cdp("Network.getCookies")).cookies));
// C: does page.evaluate wait for a promise; storage names.
await run("c.asyncAwaited", () => p1.evaluate(async () => { await new Promise((r) => setTimeout(r, 50)); return 7; }));
await run("c.names", () => p1.evaluate(async () => ({
  origin: location.origin,
  local: Array.from({ length: localStorage.length }, (_, i) => localStorage.key(i)).filter((n) => n.startsWith("masc_l7_")),
  session: Array.from({ length: sessionStorage.length }, (_, i) => sessionStorage.key(i)).filter((n) => n.startsWith("masc_l7_")),
  idb: typeof indexedDB.databases === "function" ? (await indexedDB.databases()).map((d) => d.name).filter((n) => n.startsWith("masc_l7_")) : "unsupported",
})));
// D: a busy renderer.
for (const round of [1, 2, 3]) {
  await run(`d.busy${round}`, async () => {
    await p1.evaluate(() => { setTimeout(() => { const end = Date.now() + 3000; while (Date.now() < end) {} }, 0); return true; });
    await new Promise((r) => setTimeout(r, 200));
    const t0 = Date.now();
    const timed = (promise) => promise.then(() => Date.now() - t0, (e) => ({ error: String(e && e.message || e), ms: Date.now() - t0 }));
    const [evaluate, cookies] = await Promise.all([timed(p1.evaluate("Date.now()")), timed(p1.cdp("Network.getCookies"))]);
    return { evaluateMs: evaluate, getCookiesMs: cookies };
  });
}
// E: a data: URL page has an opaque origin.
await run("e.goto", () => p2.goto("data:text/html,<p>opaque</p>"));
await run("e.cookies", async () => { const r = await p2.cdp("Network.getCookies"); return { count: r.cookies.length, ours: names(r.cookies) }; });
await run("e.storage", () => p2.evaluate(() => {
  const area = (name) => { try { return { length: window[name].length }; } catch (error) { return { error: String(error && error.name || error) }; } };
  return { origin: location.origin, local: area("localStorage"), session: area("sessionStorage"), idb: typeof indexedDB.databases };
}));
// Cleanup: only the test cookies, by name; the test origin's storage.
await run("z.cleanStorage", () => p1.evaluate(async () => {
  localStorage.removeItem("masc_l7_local"); sessionStorage.removeItem("masc_l7_session");
  return await new Promise((resolve) => { const q = indexedDB.deleteDatabase("masc_l7_db"); q.onsuccess = () => resolve(true); q.onerror = () => resolve(String(q.error)); q.onblocked = () => resolve("blocked"); });
}));
await run("z.deleteCookies", async () => {
  const { cookies } = await p1.cdp("Network.getCookies", { urls: [origin + "/", origin + "/sub/x", cross + "/"] });
  const deleted = [];
  for (const c of ours(cookies)) { await p1.cdp("Network.deleteCookies", { name: c.name, domain: c.domain, path: c.path }); deleted.push(c.name + "@" + c.domain + c.path); }
  return deleted.sort();
});
await run("z.after", async () => names((await p1.cdp("Network.getCookies", { urls: [origin + "/", origin + "/sub/x", cross + "/"] })).cookies));
await run("z.finish", () => task.finish({ keep: [] }));
