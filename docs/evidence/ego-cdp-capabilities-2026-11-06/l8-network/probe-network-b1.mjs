// L8 probe b1: send requests in one SDK process, leave the space open without draining, and exit.
// probe-network-b2.mjs resumes the same space in a new SDK process. Logs test addresses only.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const origin = "http://127.0.0.1:18775";
const task = await taskSpace("masc-l8-network-b");
log("space", task.spaceId);
const p1 = task.page("p1");
await run("b1.goto", () => p1.goto(origin + "/page"));
await run("b1.fire", () => p1.evaluate(() => window.fire(3, "b1")));
await new Promise((r) => setTimeout(r, 300));
log("b1.exit", "left the space open with the buffer undrained");
