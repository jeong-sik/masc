// L8 probe b2: resume probe b1's space in a new SDK process, then measure which end of a full buffer ego keeps
// and whether a popup's first requests are buffered before the script holds its Page. Logs test addresses only.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const origin = "http://127.0.0.1:18775";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const willSend = (events) => events.filter((e) => e.method === "Network.requestWillBeSent");
const tagged = (events) => {
  const counts = {};
  for (const e of willSend(events)) { const u = new URL(e.params.request.url); const tag = u.searchParams.get("tag") ?? u.pathname; counts[tag] = (counts[tag] ?? 0) + 1; }
  return counts;
};
const task = await taskSpace("masc-l8-network-b");
log("space", { spaceId: task.spaceId, name: task.name, ownership: task.ownership });
const p1 = task.page("p1");
await run("b2.resumedEvents", async () => { const events = await p1.events(); return { length: events.length, tags: tagged(events) }; });
await run("b2.fire", () => p1.evaluate(() => window.fire(2, "b2")));
await sleep(300);
await run("b2.events", async () => tagged(await p1.events()));
// C: which end of a full buffer stays. 3,000 requests, six at a time, about six events each.
await run("c.fire", () => p1.evaluate(() => window.fire(3000, "c", 6)));
await sleep(500);
await run("c.events", async () => {
  const events = await p1.events();
  const indices = willSend(events).map((e) => Number(new URL(e.params.request.url).searchParams.get("i"))).filter(Number.isInteger);
  return { length: events.length, firstMethod: events[0]?.method, starts: indices.length, minI: Math.min(...indices), maxI: Math.max(...indices) };
});
await run("c.again", async () => (await p1.events()).length);
// D: a popup's first document request.
await run("d.link", () => p1.evaluate(() => {
  const a = document.createElement("a"); a.id = "pop"; a.target = "_blank"; a.href = "/page?tag=popup"; a.textContent = "pop";
  document.body.appendChild(a); return true;
}));
await run("d.drain", async () => (await p1.events()).length);
let popup;
await run("d.click", async () => {
  const waiting = p1.waitForEvent("popup");
  await p1.click("#pop");
  popup = await waiting;
  return popup.label;
});
await sleep(800);
await run("d.popupEvents", async () => { const events = await popup.events(); return { length: events.length, tags: tagged(events) }; });
await run("d.openerEvents", async () => tagged(await p1.events()));
await run("z.finish", () => task.finish({ keep: [] }));
