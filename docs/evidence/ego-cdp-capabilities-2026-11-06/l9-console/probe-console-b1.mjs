// L9 probe b1: turn ego's console hiding off on p1 and exit without turning it back on.
// The space stays open so b2, a new SDK process, can see what is left. Also: is the hiding per Page?
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const origin = "http://127.0.0.1:18776";
const lines = (events) => events.filter((e) => e.method === "Runtime.consoleAPICalled").map((e) => e.params.args?.[0]?.value);
const task = await taskSpace("masc-l9-console-b");
log("space", { spaceId: task.spaceId, name: task.name, ownership: task.ownership });
const p1 = task.page("p1");
await run("b1.goto", () => p1.goto(origin + "/page"));
const p2 = await task.newPage();
await run("b1.p2goto", () => p2.goto(origin + "/page"));
await p1.events(); await p2.events();
await run("b1.disableOnP1", () => p1.cdp("egoAutomated.disable"));
await run("b1.p2cycle", async () => { await p2.cdp("Runtime.disable"); await p2.cdp("Runtime.enable"); const seen = lines(await p2.events()); await p2.cdp("Runtime.disable"); return seen; });
await run("b1.p1cycle", async () => { await p1.cdp("Runtime.disable"); await p1.cdp("Runtime.enable"); const seen = lines(await p1.events()); return seen; });
await run("b1.say", () => p1.evaluate(() => window.say(2, "b1")));
log("b1.exit", { p2: p2.label, note: "left hiding off and Runtime on for p1" });
