// L11 probe b, a new SDK process after a: does a's session cookie stay, does a delete with a
// path reach only that path, and how do domain cookies of a *.l11.localhost test host (loopback)
// answer to deletes by domain and by url. Every cookie is named masc_l11_*; each is deleted by
// exact name, domain and path at the end. No profile-wide command, no getAllCookies.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const origin = "http://127.0.0.1:18777";
const sub = "http://a.l11.localhost:18777";
const brief = (cookies) => cookies.filter((c) => c.name.startsWith("masc_l11_"))
  .map((c) => `${c.name} ${c.domain} ${c.path}`).sort();
const listed = async (page, url) => brief((await page.cdp("Network.getCookies", { urls: [url] })).cookies);
const task = await taskSpace("masc-l11-cookies-b");
log("space", { spaceId: task.spaceId, name: task.name, ownership: task.ownership });
const p1 = task.page("p1");
await run("b0.goto", () => p1.goto(origin + "/page"));
// B1: the session cookie a left in its SDK process.
await run("b1.fromA", () => listed(p1, origin + "/page"));
await run("b1.request", () => p1.evaluate(() => window.echo()));
// B2: one name at two paths; a delete with a path.
await run("b2.set", async () => {
  await p1.cdp("Network.setCookie", { name: "masc_l11_p", value: "root", url: origin + "/page", path: "/" });
  await p1.cdp("Network.setCookie", { name: "masc_l11_p", value: "sub", url: origin + "/page", path: "/sub" });
  return listed(p1, origin + "/sub/page");
});
await run("b2.deleteRootPath", () => p1.cdp("Network.deleteCookies", { name: "masc_l11_p", domain: "127.0.0.1", path: "/" }));
await run("b2.after", () => listed(p1, origin + "/sub/page"));
// B3: a path longer than the browser keeps, and a long name.
await run("b3.longPath", () => p1.cdp("Network.setCookie", { name: "masc_l11_lp", value: "v", url: origin + "/page", path: "/" + "p".repeat(1100) }));
await run("b3.path1024", () => p1.cdp("Network.setCookie", { name: "masc_l11_lp", value: "v", url: origin + "/page", path: "/" + "p".repeat(1023) }));
await run("b3.longName", () => p1.cdp("Network.setCookie", { name: "masc_l11_" + "n".repeat(300), value: "v", url: origin + "/page", path: "/" }));
await run("b3.nameValue4096", () => p1.cdp("Network.setCookie", { name: "masc_l11_nv", value: "x".repeat(4096 - 11), url: origin + "/page", path: "/" }));
await run("b3.listed", () => listed(p1, origin + "/page"));
// B4: a host under *.localhost, which Chromium sends to loopback, and a cookie for its parent domain.
await run("b4.goto", async () => { await p1.goto(sub + "/page"); return p1.evaluate(() => location.href); });
await run("b4.set", async () => {
  const host = await p1.cdp("Network.setCookie", { name: "masc_l11_host", value: "h", url: sub + "/page", path: "/" });
  const parent = await p1.cdp("Network.setCookie", { name: "masc_l11_dom", value: "d", url: sub + "/page", domain: ".l11.localhost", path: "/" });
  const parent2 = await p1.cdp("Network.setCookie", { name: "masc_l11_dom2", value: "d2", url: sub + "/page", domain: "l11.localhost", path: "/" });
  return { host, parent, parent2, listed: await listed(p1, sub + "/page") };
});
await run("b4.page", () => p1.evaluate(() => window.seen()));
await run("b4.deleteParentNoDot", () => p1.cdp("Network.deleteCookies", { name: "masc_l11_dom", domain: "l11.localhost", path: "/" }));
await run("b4.afterNoDot", () => listed(p1, sub + "/page"));
await run("b4.deleteParentDot", () => p1.cdp("Network.deleteCookies", { name: "masc_l11_dom", domain: ".l11.localhost", path: "/" }));
await run("b4.afterDot", () => listed(p1, sub + "/page"));
await run("b4.deleteParentByUrl", () => p1.cdp("Network.deleteCookies", { name: "masc_l11_dom2", url: sub + "/page" }));
await run("b4.afterUrl", () => listed(p1, sub + "/page"));
// Z: delete every masc_l11_ cookie both hosts list, by exact triple, and read again.
await run("z.clean", async () => {
  const deleted = [];
  for (const [url, host] of [[sub + "/page", sub], [origin + "/" + "p".repeat(1023), origin], [origin + "/sub/page", origin]]) {
    if (url.startsWith(sub)) await p1.goto(sub + "/page"); else await p1.goto(origin + "/page");
    for (const c of (await p1.cdp("Network.getCookies", { urls: [url] })).cookies.filter((c) => c.name.startsWith("masc_l11_"))) {
      await p1.cdp("Network.deleteCookies", { name: c.name, domain: c.domain, path: c.path });
      deleted.push(`${c.name.slice(0, 24)} ${c.domain} ${c.path.slice(0, 12)}`);
    }
  }
  const after = [...await listed(p1, sub + "/page"), ...await listed(p1, origin + "/sub/page"), ...await listed(p1, origin + "/" + "p".repeat(1023))];
  return { deleted, after };
});
await run("z.finish", () => task.finish({ keep: [] }));
