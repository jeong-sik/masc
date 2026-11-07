// L11 probe c: the production cookie write (cookie-write.js, which this file follows on stdin) on real ego Pages.
// Test hosts only: 127.0.0.1:18777 and a.l11.localhost:18777 (loopback). Every cookie is named masc_l11_* (one
// __Host-masc_l11_* that the browser must refuse). The end deletes each by exact name, domain and path.
// No profile-wide command, no getAllCookies. Answers carry no value; logs keep the test values only.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const reason = (error) => String((error && error.message) || error);
const origin = "http://127.0.0.1:18777";
const sub = "http://a.l11.localhost:18777";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const set = (name, fields = {}) => ({ kind: "set", label: "p1", tabId: 1, name, value: "v-" + name, path: "/",
  secure: false, httpOnly: false, sameSite: null, maxAgeSec: null, ...fields });
const del = (name) => ({ kind: "delete", label: "p1", tabId: 1, name });
const brief = (cookies) => cookies.filter((c) => c.name.includes("masc_l11_"))
  .map((c) => `${c.name} ${c.domain} ${c.path}`).sort();
const listed = async (page, url) => brief((await page.cdp("Network.getCookies", { urls: [url] })).cookies);
const task = await taskSpace("masc-l11-cookies-c");
log("space", { spaceId: task.spaceId, name: task.name, ownership: task.ownership });
const p1 = task.page("p1");
await run("c0.goto", () => p1.goto(origin + "/page"));
await run("c0.before", () => listed(p1, origin + "/page"));
// C1-C3: a new session cookie, the same again, and one with every attribute.
await run("c1.set", () => write(p1, set("masc_l11_c1"), reason));
await run("c2.again", () => write(p1, set("masc_l11_c1", { value: "v2" }), reason));
await run("c3.attributes", () => write(p1, set("masc_l11_c3", { secure: true, httpOnly: true, sameSite: "Strict", maxAgeSec: 3600 }), reason));
await run("c4.page", () => p1.evaluate(() => window.seen()));
await run("c4.request", () => p1.evaluate(() => window.echo()));
// C5: a path the page is not under is set and read back on that path.
await run("c5.subPath", () => write(p1, set("masc_l11_c5", { path: "/sub" }), reason));
await run("c5.listedSub", () => listed(p1, origin + "/sub/page"));
// C6-C7: a delete of one cookie; a name at "/" and "/page" that the page sees and at "/sub" that it does not.
await run("c6.delete", () => write(p1, del("masc_l11_c1"), reason));
await run("c7.prepare", async () => {
  for (const path of ["/", "/page", "/sub"]) await p1.cdp("Network.setCookie", { name: "masc_l11_two", value: "t", url: origin + "/page", path });
  return [...await listed(p1, origin + "/page"), ...await listed(p1, origin + "/sub/page")];
});
await run("c7.delete", () => write(p1, del("masc_l11_two"), reason));
await run("c7.after", async () => [...await listed(p1, origin + "/page"), ...await listed(p1, origin + "/sub/page")]);
await run("c8.nobody", () => write(p1, del("masc_l11_nobody"), reason));
// C9-C11: what the browser refuses.
await run("c9.noneInsecure", () => write(p1, set("masc_l11_c9", { sameSite: "None" }), reason));
await run("c10.semicolon", () => write(p1, set("masc_l11_c10", { value: "SECRET_L11;x=1" }), reason));
await run("c11.hostPrefix", () => write(p1, set("__Host-masc_l11_c11"), reason));
await run("c11.listed", () => listed(p1, origin + "/page"));
// C12: a page that is not at an http or https address.
await run("c12.blank", async () => { await p1.goto("about:blank"); return write(p1, set("masc_l11_c12"), reason); });
// C13: on a *.localhost host, a delete reaches the host cookie and a parent-domain cookie the page sees.
await run("c13.goto", async () => { await p1.goto(sub + "/page"); return p1.evaluate(() => location.href); });
await run("c13.set", async () => {
  const host = await write(p1, set("masc_l11_c13"), reason);
  await p1.cdp("Network.setCookie", { name: "masc_l11_c13", value: "d", url: sub + "/page", domain: ".l11.localhost", path: "/" });
  return { host, listed: await listed(p1, sub + "/page") };
});
await run("c13.replaceBesideDomain", () => write(p1, set("masc_l11_c13"), reason));
await run("c13.delete", () => write(p1, del("masc_l11_c13"), reason));
await run("c13.after", () => listed(p1, sub + "/page"));
// C14: a busy page.
await run("c14.goto", () => p1.goto(origin + "/page"));
for (const round of [1, 2]) {
  await run(`c14.busy${round}`, async () => {
    await p1.evaluate(() => { setTimeout(() => { const end = Date.now() + 3000; while (Date.now() < end) {} }, 0); return true; });
    await sleep(200);
    const t0 = Date.now();
    const answer = await write(p1, set("masc_l11_busy"), reason);
    const setMs = Date.now() - t0;
    const t1 = Date.now();
    const deleted = await write(p1, del("masc_l11_busy"), reason);
    return { setMs, set: answer, deleteMs: Date.now() - t1, deleted };
  });
  await sleep(3000);
}
// Z: delete every masc_l11_ cookie both hosts list, by exact triple, and read again.
await run("z.clean", async () => {
  const deleted = [];
  for (const [page, url] of [[sub + "/page", sub + "/page"], [origin + "/page", origin + "/page"], [origin + "/page", origin + "/sub/page"]]) {
    await p1.goto(page);
    for (const c of (await p1.cdp("Network.getCookies", { urls: [url] })).cookies.filter((c) => c.name.includes("masc_l11_"))) {
      await p1.cdp("Network.deleteCookies", { name: c.name, domain: c.domain, path: c.path });
      deleted.push(`${c.name} ${c.domain} ${c.path}`);
    }
  }
  const after = [...await listed(p1, sub + "/page"), ...await listed(p1, origin + "/page"), ...await listed(p1, origin + "/sub/page")];
  return { deleted, after };
});
await run("z.finish", () => task.finish({ keep: [] }));
