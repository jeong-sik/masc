// L11 probe b-clean: find masc_l11_dom2, which b set with domain "l11.localhost" and a.l11.localhost
// did not list, and delete every masc_l11_ cookie of the test hosts by exact name, domain and path.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const urls = ["http://l11.localhost:18777/page", "http://a.l11.localhost:18777/page", "http://127.0.0.1:18777/page", "http://127.0.0.1:18777/sub/page"];
const ours = async (page) => (await page.cdp("Network.getCookies", { urls })).cookies.filter((c) => c.name.startsWith("masc_l11_"));
const task = await taskSpace("masc-l11-cookies-b");
log("space", { spaceId: task.spaceId, name: task.name, ownership: task.ownership });
const p1 = task.page("p1");
await run("c0.goto", () => p1.goto("http://l11.localhost:18777/page"));
await run("c1.found", async () => (await ours(p1)).map((c) => `${c.name} ${c.domain} ${c.path} session=${c.session}`));
await run("c2.clean", async () => {
  for (const c of await ours(p1)) await p1.cdp("Network.deleteCookies", { name: c.name, domain: c.domain, path: c.path });
  return (await ours(p1)).map((c) => `${c.name} ${c.domain} ${c.path}`);
});
await run("z.finish", () => task.finish({ keep: [] }));
