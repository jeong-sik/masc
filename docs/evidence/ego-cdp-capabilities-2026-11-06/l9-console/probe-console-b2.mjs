// L9 probe b2: a new SDK process resumes the b1 space by name. Is p1's console hiding still off?
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const lines = (events) => events.filter((e) => e.method === "Runtime.consoleAPICalled").map((e) => e.params.args?.[0]?.value);
const task = await taskSpace("masc-l9-console-b");
log("space", { spaceId: task.spaceId, name: task.name, ownership: task.ownership });
const p1 = task.page("p1");
await run("b2.firstEvents", async () => (await p1.events()).length);
await run("b2.say", () => p1.evaluate(() => window.say(2, "b2")));
await new Promise((r) => setTimeout(r, 200));
await run("b2.liveWithoutEnable", async () => lines(await p1.events()));
await run("b2.cycleWithoutDisable", async () => { await p1.cdp("Runtime.disable"); await p1.cdp("Runtime.enable"); const seen = lines(await p1.events()); await p1.cdp("Runtime.disable"); return seen; });
await run("b2.cycleWithDisable", async () => { await p1.cdp("egoAutomated.disable"); await p1.cdp("Runtime.disable"); await p1.cdp("Runtime.enable"); const seen = lines(await p1.events()); await p1.cdp("Runtime.disable"); await p1.cdp("egoAutomated.enable"); return seen; });
await run("z.finish", () => task.finish({ keep: [] }));
