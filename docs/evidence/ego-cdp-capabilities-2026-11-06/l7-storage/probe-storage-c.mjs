const storageNames = async function(page, args, reason) {
  let seen;
  try {
    seen = await page.evaluate(async limits => {
      const cut = text => String(text).slice(0, limits.nameChars);
      const failure = error => ({error: cut(error && error.name || error)});
      const area = name => {
        try {
          const store = window[name];
          const count = store.length;
          const keys = [];
          for (let index = 0; index < Math.min(count, limits.names); index++) keys.push(cut(store.key(index)));
          return {count, keys, truncated: count > limits.names};
        } catch (error) { return failure(error); }
      };
      const databases = async () => {
        try {
          if (typeof indexedDB === "undefined" || typeof indexedDB.databases !== "function") return {unsupported: true};
          let timer;
          const listed = await Promise.race([indexedDB.databases(),
            new Promise(resolve => { timer = setTimeout(() => resolve(null), limits.indexedDbWaitMs); })]);
          clearTimeout(timer);
          if (listed === null) return {error: "timeout"};
          return {count: listed.length, names: listed.slice(0, limits.names).map(database => cut(database.name)),
            truncated: listed.length > limits.names};
        } catch (error) { return failure(error); }
      };
      return {url: location.href, origin: location.origin, localStorage: area("localStorage"),
        sessionStorage: area("sessionStorage"), indexedDb: await databases()};
    }, args.limits);
  } catch (error) {
    return {ok: false, error: "the page's storage names were not read: " + reason(error)};
  }
  if (seen === null || typeof seen !== "object" || typeof seen.url !== "string")
    return {ok: false, error: "the page answered its storage names without its URL"};
  let listed;
  try {
    listed = await page.cdp("Network.getCookies", {urls: [seen.url]});
  } catch (error) {
    return {ok: false, error: "Network.getCookies failed: " + reason(error)};
  }
  if (listed === null || typeof listed !== "object" || !Array.isArray(listed.cookies))
    return {ok: false, error: "Network.getCookies answered without a cookie list"};
  const cookies = listed.cookies.map(cookie => ({
    name: cookie.name, domain: cookie.domain, path: cookie.path, secure: cookie.secure, httpOnly: cookie.httpOnly,
    ...(cookie.sameSite === undefined ? {} : {sameSite: cookie.sameSite}),
    ...(cookie.session === false ? {expiry: Math.floor(cookie.expires)} : {})}));
  return {ok: true, value: {cookies: cookies.slice(0, args.limits.cookies), total: cookies.length,
    storage: {origin: seen.origin, localStorage: seen.localStorage, sessionStorage: seen.sessionStorage,
      indexedDb: seen.indexedDb}}};
}
// L7 probe c: the production storage_names_script (storage.js, prepended) on real Pages.
// Only test cookies named masc_l7_* exist on the test origin; no call opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const port = 18774;
const origin = `http://127.0.0.1:${port}`;
const cross = `http://localhost:${port}`;
const reason = (error) => String(error && error.message || error);
const limits = { cookies: 200, names: 100, nameChars: 200, indexedDbWaitMs: 2000 };
const secrets = ["HTTP_SECRET_VALUE", "PERSIST_SECRET_VALUE", "SUB_SECRET_VALUE", "JS_SECRET_VALUE", "LOCAL_SECRET_VALUE", "SESSION_SECRET_VALUE", "FRAME_SECRET_VALUE"];
const leaks = (value) => secrets.filter((secret) => JSON.stringify(value).includes(secret));
const ours = (cookies) => cookies.filter((c) => c.name.startsWith("masc_l7_"));
const task = await taskSpace("masc-l7-storage-c");
log("space", task.spaceId);
const p1 = task.page("p1");
const p2 = await task.newPage();
await run("c.precheck", async () => ours((await p1.cdp("Network.getCookies", { urls: [origin + "/", origin + "/sub/x", cross + "/"] })).cookies).map((c) => c.name));
await run("c.setFrameCookie", () => p2.goto(cross + "/setframe"));
await run("c.goto", () => p1.goto(origin + "/set"));
await run("c.seed", () => p1.evaluate(async () => {
  document.cookie = "masc_l7_js=JS_SECRET_VALUE; path=/";
  localStorage.setItem("masc_l7_local", "LOCAL_SECRET_VALUE");
  for (let i = 0; i < 105; i++) localStorage.setItem("masc_l7_many_" + String(i).padStart(3, "0"), "x");
  localStorage.setItem("masc_l7_" + "k".repeat(300), "LOCAL_SECRET_VALUE");
  sessionStorage.setItem("masc_l7_session", "SESSION_SECRET_VALUE");
  return await new Promise((resolve) => { const q = indexedDB.open("masc_l7_db"); q.onsuccess = () => { q.result.close(); resolve(true); }; q.onerror = () => resolve(String(q.error)); });
}));
await run("c.addFrame", () => p1.evaluate((src) => window.addFrame(src), cross + "/frame.html"));
const read = async (page) => {
  const t0 = Date.now();
  const answer = await storageNames(page, { label: "x", limits }, reason);
  if (!answer.ok) return { ms: Date.now() - t0, answer };
  const v = answer.value;
  return { ms: Date.now() - t0, leaks: leaks(answer), total: v.total, cookies: ours(v.cookies),
    cookieKeys: [...new Set(v.cookies.flatMap((c) => Object.keys(c)))].sort(),
    storage: { origin: v.storage.origin,
      localStorage: v.storage.localStorage.error ? v.storage.localStorage : { count: v.storage.localStorage.count, truncated: v.storage.localStorage.truncated, listed: v.storage.localStorage.keys.length, longestKey: Math.max(...v.storage.localStorage.keys.map((k) => k.length)), first: v.storage.localStorage.keys.slice(0, 2) },
      sessionStorage: v.storage.sessionStorage, indexedDb: v.storage.indexedDb } };
};
await run("c.http", () => read(p1));
await run("c.dataGoto", () => p2.goto("data:text/html,<p>opaque</p>"));
await run("c.data", () => read(p2));
await run("c.blankGoto", () => p2.goto("about:blank"));
await run("c.blank", () => read(p2));
// Cleanup: the test origin's storage, then only the test cookies, by name.
await run("z.cleanStorage", () => p1.evaluate(async () => {
  for (const key of Object.keys(localStorage).filter((k) => k.startsWith("masc_l7_"))) localStorage.removeItem(key);
  sessionStorage.removeItem("masc_l7_session");
  return await new Promise((resolve) => { const q = indexedDB.deleteDatabase("masc_l7_db"); q.onsuccess = () => resolve(true); q.onerror = () => resolve(String(q.error)); q.onblocked = () => resolve("blocked"); });
}));
await run("z.deleteCookies", async () => {
  const { cookies } = await p1.cdp("Network.getCookies", { urls: [origin + "/", origin + "/sub/x", cross + "/"] });
  const deleted = [];
  for (const c of ours(cookies)) { await p1.cdp("Network.deleteCookies", { name: c.name, domain: c.domain, path: c.path }); deleted.push(c.name + "@" + c.domain + c.path); }
  return deleted.sort();
});
await run("z.after", async () => ours((await p1.cdp("Network.getCookies", { urls: [origin + "/", origin + "/sub/x", cross + "/"] })).cookies).map((c) => c.name));
await run("z.storageAfter", () => p1.evaluate(async () => ({ local: Object.keys(localStorage).filter((k) => k.startsWith("masc_l7_")).length, idb: (await indexedDB.databases()).filter((d) => d.name.startsWith("masc_l7_")).length })));
await run("z.finish", () => task.finish({ keep: [] }));
