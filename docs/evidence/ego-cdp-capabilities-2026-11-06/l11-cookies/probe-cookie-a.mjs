// L11 probe a: what Network.setCookie and Network.deleteCookies do through an ego Page's CDP
// session, on the test host 127.0.0.1 only. Every cookie it writes is named masc_l11_*, and it
// deletes each by exact name, domain and path. No profile-wide command, no getAllCookies.
// It logs names, scoping fields and the test values it wrote itself; no other cookie's value.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const origin = "http://127.0.0.1:18777";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ours = (cookies) => cookies.filter((c) => c.name.startsWith("masc_l11_"))
  .map(({ value, ...rest }) => rest).sort((x, y) => (x.name + x.path).localeCompare(y.name + y.path));
const listed = async (page, url) => ours((await page.cdp("Network.getCookies", { urls: [url] })).cookies);
const task = await taskSpace("masc-l11-cookies-a");
log("space", { spaceId: task.spaceId, name: task.name, ownership: task.ownership });
const p1 = task.page("p1");
await run("a0.goto", () => p1.goto(origin + "/page"));
await run("a0.before", async () => {
  const all = (await p1.cdp("Network.getCookies", { urls: [origin + "/page"] })).cookies;
  return { total: all.length, ours: ours(all) };
});
// A1: a plain session cookie scoped by url only.
await run("a1.set", () => p1.cdp("Network.setCookie", { name: "masc_l11_a", value: "v1", url: origin + "/page", path: "/" }));
await run("a1.listed", () => listed(p1, origin + "/page"));
await run("a1.fieldKeys", async () => Object.keys((await p1.cdp("Network.getCookies", { urls: [origin + "/page"] })).cookies.find((c) => c.name === "masc_l11_a") ?? {}).sort());
await run("a1.page", () => p1.evaluate(() => window.seen()));
await run("a1.request", () => p1.evaluate(() => window.echo()));
// A2: httpOnly, expiry, SameSite, a path below the page, Secure on http.
await run("a2.httpOnly", () => p1.cdp("Network.setCookie", { name: "masc_l11_h", value: "v2", url: origin + "/page", path: "/", httpOnly: true }));
await run("a2.expires", () => p1.cdp("Network.setCookie", { name: "masc_l11_e", value: "v3", url: origin + "/page", path: "/", expires: Date.now() / 1000 + 3600, sameSite: "Strict" }));
await run("a2.subPath", () => p1.cdp("Network.setCookie", { name: "masc_l11_s", value: "v4", url: origin + "/page", path: "/sub" }));
await run("a2.secure", () => p1.cdp("Network.setCookie", { name: "masc_l11_secure", value: "v5", url: origin + "/page", path: "/", secure: true }));
await run("a2.noneSecure", () => p1.cdp("Network.setCookie", { name: "masc_l11_n", value: "v6", url: origin + "/page", path: "/", secure: true, sameSite: "None" }));
await run("a2.noneInsecure", () => p1.cdp("Network.setCookie", { name: "masc_l11_ni", value: "v7", url: origin + "/page", path: "/", sameSite: "None" }));
await run("a2.listedPage", () => listed(p1, origin + "/page"));
await run("a2.listedSub", () => listed(p1, origin + "/sub/page"));
await run("a2.page", () => p1.evaluate(() => window.seen()));
await run("a2.request", () => p1.evaluate(() => window.echo()));
await run("a2.requestSub", () => p1.evaluate(() => window.echo("/sub/echo")));
// A3: the same name and path again replaces; another path is another cookie.
await run("a3.replace", () => p1.cdp("Network.setCookie", { name: "masc_l11_a", value: "v1b", url: origin + "/page", path: "/" }));
await run("a3.request", () => p1.evaluate(() => window.echo()));
// A4: values CDP refuses, and whether the error repeats the value.
await run("a4.control", () => p1.cdp("Network.setCookie", { name: "masc_l11_bad", value: "SECRET_L11\u0001x", url: origin + "/page", path: "/" }));
await run("a4.semicolon", () => p1.cdp("Network.setCookie", { name: "masc_l11_bad", value: "SECRET_L11;x=1", url: origin + "/page", path: "/" }));
await run("a4.space", () => p1.cdp("Network.setCookie", { name: "masc_l11_sp", value: "a b,c\"d", url: origin + "/page", path: "/" }));
await run("a4.badName", () => p1.cdp("Network.setCookie", { name: "masc l11=bad", value: "SECRET_L11", url: origin + "/page", path: "/" }));
await run("a4.longValue", () => p1.cdp("Network.setCookie", { name: "masc_l11_long", value: "x".repeat(4096), url: origin + "/page", path: "/" }));
await run("a4.tooLong", () => p1.cdp("Network.setCookie", { name: "masc_l11_toolong", value: "x".repeat(5000), url: origin + "/page", path: "/" }));
await run("a4.pastExpiry", () => p1.cdp("Network.setCookie", { name: "masc_l11_past", value: "v8", url: origin + "/page", path: "/", expires: Date.now() / 1000 - 60 }));
await run("a4.listed", () => listed(p1, origin + "/page"));
// A5: deletes. By exact name, domain and path; by url; a path the url does not reach; a name nobody has.
await run("a5.byDomainPath", () => p1.cdp("Network.deleteCookies", { name: "masc_l11_a", domain: "127.0.0.1", path: "/" }));
await run("a5.byUrl", () => p1.cdp("Network.deleteCookies", { name: "masc_l11_h", url: origin + "/page" }));
await run("a5.subByPageUrl", () => p1.cdp("Network.deleteCookies", { name: "masc_l11_s", url: origin + "/page" }));
await run("a5.nobody", () => p1.cdp("Network.deleteCookies", { name: "masc_l11_nobody", url: origin + "/page" }));
await run("a5.nameOnly", () => p1.cdp("Network.deleteCookies", { name: "masc_l11_nobody_anywhere_7f3c" }));
await run("a5.listedPage", () => listed(p1, origin + "/page"));
await run("a5.listedSub", () => listed(p1, origin + "/sub/page"));
// A6: a page that is not http(s).
await run("a6.blank", async () => { await p1.goto("about:blank"); return p1.evaluate(() => location.href); });
await run("a6.setBlank", () => p1.cdp("Network.setCookie", { name: "masc_l11_blank", value: "v9", url: "about:blank", path: "/" }));
await run("a6.back", () => p1.goto(origin + "/page"));
// A7: a busy page.
for (const round of [1, 2, 3]) {
  await run(`a7.busy${round}`, async () => {
    await p1.evaluate(() => { setTimeout(() => { const end = Date.now() + 3000; while (Date.now() < end) {} }, 0); return true; });
    await sleep(200);
    const t0 = Date.now();
    const timed = (promise) => promise.then(() => Date.now() - t0, (e) => ({ error: String(e && e.message || e), ms: Date.now() - t0 }));
    const evaluate = timed(p1.evaluate("Date.now()"));
    const set = await timed(p1.cdp("Network.setCookie", { name: "masc_l11_busy", value: "v10", url: origin + "/page", path: "/" }));
    const get = await timed(p1.cdp("Network.getCookies", { urls: [origin + "/page"] }));
    const del = await timed(p1.cdp("Network.deleteCookies", { name: "masc_l11_busy", domain: "127.0.0.1", path: "/" }));
    return { evaluateMs: await evaluate, setMs: set, getMs: get, deleteMs: del };
  });
  await sleep(3000);
}
// A8: leave one session cookie for b, a new SDK process; clean the rest by exact triple.
await run("a8.forB", () => p1.cdp("Network.setCookie", { name: "masc_l11_b", value: "vb", url: origin + "/page", path: "/" }));
await run("a8.clean", async () => {
  const left = [...await listed(p1, origin + "/page"), ...await listed(p1, origin + "/sub/page")]
    .filter((c) => c.name !== "masc_l11_b");
  const seen = new Set();
  for (const c of left) {
    const key = c.name + "|" + c.domain + "|" + c.path;
    if (seen.has(key)) continue;
    seen.add(key);
    await p1.cdp("Network.deleteCookies", { name: c.name, domain: c.domain, path: c.path });
  }
  return { deleted: [...seen], after: [...await listed(p1, origin + "/page"), ...await listed(p1, origin + "/sub/page")] };
});
await run("z.finish", () => task.finish({ keep: [] }));
