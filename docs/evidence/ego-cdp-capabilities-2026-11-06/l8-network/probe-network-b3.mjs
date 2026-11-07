// L8 probe b3: does a popup's Page buffer Network events once the script holds it? Logs test addresses only.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const origin = "http://127.0.0.1:18775";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const tagged = (events) => {
  const counts = {};
  for (const e of events.filter((e) => e.method === "Network.requestWillBeSent")) { const u = new URL(e.params.request.url); const tag = u.searchParams.get("tag") ?? u.pathname; counts[tag] = (counts[tag] ?? 0) + 1; }
  return counts;
};
const methods = (events) => { const c = {}; for (const e of events) c[e.method] = (c[e.method] ?? 0) + 1; return c; };
const task = await taskSpace("masc-l8-network-b3");
log("space", { spaceId: task.spaceId, name: task.name, ownership: task.ownership });
const p1 = task.page("p1");
await run("e.goto", () => p1.goto(origin + "/page"));
await run("e.link", () => p1.evaluate(() => {
  const a = document.createElement("a"); a.id = "pop"; a.target = "_blank"; a.href = "/page?tag=popup"; a.textContent = "pop";
  document.body.appendChild(a); return true;
}));
await run("e.drain", async () => (await p1.events()).length);
let popup;
await run("e.click", async () => { const waiting = p1.waitForEvent("popup"); await p1.click("#pop"); popup = await waiting; return popup.label; });
await run("e.popupLoad", () => popup.waitForLoadState());
await run("e.popupFirst", async () => { const events = await popup.events(); return { length: events.length, methods: methods(events) }; });
await run("e.popupFire", () => popup.evaluate(() => window.fire(2, "popupfire")));
await sleep(300);
await run("e.popupAfterFire", async () => { const events = await popup.events(); return { tags: tagged(events), methods: methods(events) }; });
await run("e.popupReload", () => popup.reload());
await run("e.popupAfterReload", async () => { const events = await popup.events(); return { tags: tagged(events), methods: methods(events) }; });
await run("e.viaTask", async () => { const page = task.page(popup.label); await page.evaluate(() => window.fire(1, "viatask")); await sleep(200); return tagged(await page.events()); });
// A page opened by newPage, as a control.
const p3 = await task.newPage();
await run("e.p3goto", () => p3.goto(origin + "/page?tag=newpage"));
await run("e.p3events", async () => tagged(await p3.events()));
await run("z.finish", () => task.finish({ keep: [] }));
