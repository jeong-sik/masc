// L9 probe a: what an ego Page's CDP session shows of console lines and uncaught errors, with
// ego's hiding on and off, across Runtime.enable/disable, navigation, frames and a busy page.
// Logs console types, first-argument test strings, field names and counts only.
// No call opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const port = 18776;
const origin = `http://127.0.0.1:${port}`;
const cross = `http://localhost:${port}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const first = (event) => {
  const arg = event.params?.args?.[0];
  return arg ? (arg.type === "string" ? arg.value : arg.type + ":" + (arg.description ?? arg.value)) : null;
};
const summary = (events) => {
  const methods = {}, console_ = [], thrown = [];
  for (const event of events) {
    methods[event.method] = (methods[event.method] ?? 0) + 1;
    if (event.method === "Runtime.consoleAPICalled") console_.push(event.params.type + " " + first(event));
    if (event.method === "Runtime.exceptionThrown") thrown.push(event.params.exceptionDetails?.exception?.description?.split("\n")[0] ?? event.params.exceptionDetails?.text);
  }
  return { methods, console: console_, thrown };
};
const drain = async (page) => summary(await page.events());
const fingerprint = (page) => page.evaluate(() => {
  let stackRead = false;
  const error = new Error("fingerprint");
  Object.defineProperty(error, "stack", { get() { stackRead = true; return ""; } });
  console.debug(error);
  return { webdriver: navigator.webdriver, stackRead };
});
const task = await taskSpace("masc-l9-console-a");
log("space", { spaceId: task.spaceId, name: task.name, ownership: task.ownership });
const p1 = task.page("p1");
await run("a1.goto", () => p1.goto(origin + "/page"));
await sleep(300);
await run("a1.loadEvents", () => drain(p1));
await run("a1.fingerprint", () => fingerprint(p1));
await sleep(100);
await run("a1.afterFingerprint", () => drain(p1));
// A2: Runtime.enable while ego hides console messages.
await run("a2.enable", () => p1.cdp("Runtime.enable"));
await run("a2.events", () => drain(p1));
await run("a2.say", () => p1.evaluate(() => window.say(3, "a2")));
await run("a2.throw", () => p1.evaluate(() => window.throwLater("a2-uncaught")));
await sleep(200);
await run("a2.sayEvents", () => drain(p1));
// A3: turn the hiding off; is anything replayed, and does a second Runtime.enable replay?
await run("a3.disableHiding", () => p1.cdp("egoAutomated.disable"));
await sleep(100);
await run("a3.eventsAfterDisable", () => drain(p1));
await run("a3.enableAgain", () => p1.cdp("Runtime.enable"));
await run("a3.eventsAfterEnableAgain", () => drain(p1));
await run("a3.runtimeDisable", () => p1.cdp("Runtime.disable"));
await run("a3.runtimeEnable", () => p1.cdp("Runtime.enable"));
await run("a3.replay", () => drain(p1));
await run("a3.fingerprint", () => fingerprint(p1));
await run("a3.say", () => p1.evaluate(() => window.say(2, "a3")));
await run("a3.throw", () => p1.evaluate(() => window.throwLater("a3-uncaught")));
await sleep(200);
await run("a3.live", () => drain(p1));
await run("a3.shape", async () => {
  await p1.evaluate(() => console.log("shape", 1, { a: 1 }, [2]));
  await sleep(100);
  const event = (await p1.events()).find((e) => e.method === "Runtime.consoleAPICalled");
  return event && { paramKeys: Object.keys(event.params).sort(), argTypes: event.params.args.map((a) => a.type + (a.subtype ? "/" + a.subtype : "")),
    argKeys: event.params.args.map((a) => Object.keys(a).sort()), stackFrameKeys: Object.keys(event.params.stackTrace?.callFrames?.[0] ?? {}).sort(),
    timestamp: typeof event.params.timestamp };
});
// A4: hiding back on.
await run("a4.runtimeDisable", () => p1.cdp("Runtime.disable"));
await run("a4.enableHiding", () => p1.cdp("egoAutomated.enable"));
await run("a4.fingerprint", () => fingerprint(p1));
await run("a4.say", () => p1.evaluate(() => window.say(2, "a4")));
await sleep(200);
await run("a4.events", () => drain(p1));
await run("a4.sdkStillWorks", async () => ({ url: await p1.url(), title: await p1.title(), snapshot: (await p1.snapshot()).length > 0, evaluate: await p1.evaluate("1+1") }));
// A5: Runtime.enable while hidden after the round trip: execution contexts still reported?
await run("a5.enableHidden", () => p1.cdp("Runtime.enable"));
await run("a5.events", () => drain(p1));
await run("a5.disable", () => p1.cdp("Runtime.disable"));
// A6: what a later replay holds: everything since the load, or since the last read?
await run("a6.cycle", async () => {
  await p1.cdp("egoAutomated.disable"); await p1.cdp("Runtime.enable");
  const events = summary(await p1.events());
  await p1.cdp("Runtime.disable"); await p1.cdp("egoAutomated.enable");
  return events;
});
// A7: navigation.
await run("a7.reload", () => p1.reload());
await sleep(300);
await run("a7.drainLoad", () => drain(p1));
await run("a7.cycle", async () => {
  await p1.cdp("egoAutomated.disable"); await p1.cdp("Runtime.enable");
  const events = summary(await p1.events());
  await p1.cdp("Runtime.disable"); await p1.cdp("egoAutomated.enable");
  return events;
});
// A8: frames.
await run("a8.sameFrame", () => p1.evaluate((src) => window.addFrame(src), origin + "/frame.html"));
await run("a8.crossFrame", () => p1.evaluate((src) => window.addFrame(src), cross + "/frame.html"));
await sleep(300);
await run("a8.cycle", async () => {
  await p1.cdp("egoAutomated.disable"); await p1.cdp("Runtime.enable");
  const events = summary(await p1.events());
  await p1.cdp("Runtime.disable"); await p1.cdp("egoAutomated.enable");
  return { console: events.console.filter((line) => line.includes("frame")), methods: events.methods };
});
// A9: how many lines a replay keeps, and a long line.
await run("a9.say", () => p1.evaluate(() => window.say(1500, "a9")));
await run("a9.long", () => p1.evaluate(() => { console.log("long-" + "x".repeat(20000)); return true; }));
await sleep(200);
await run("a9.cycle", async () => {
  await p1.cdp("egoAutomated.disable"); await p1.cdp("Runtime.enable");
  const events = await p1.events();
  await p1.cdp("Runtime.disable"); await p1.cdp("egoAutomated.enable");
  const lines = events.filter((e) => e.method === "Runtime.consoleAPICalled");
  const a9 = lines.map(first).filter((text) => typeof text === "string" && text.startsWith("a9-"));
  const long = lines.map(first).find((text) => typeof text === "string" && text.startsWith("long-"));
  return { total: lines.length, a9: a9.length, firstA9: a9[0], lastA9: a9[a9.length - 1], longLength: long?.length ?? null, other: lines.map(first).filter((t) => !(typeof t === "string" && t.startsWith("a9-"))).slice(0, 12) };
});
// A10: a busy page.
const timed = (t0, promise) => promise.then(() => Date.now() - t0, (e) => ({ error: String(e && e.message || e), ms: Date.now() - t0 }));
for (const round of [1, 2, 3]) {
  await run(`a10.busy${round}`, async () => {
    await p1.evaluate(() => { setTimeout(() => { const end = Date.now() + 3000; while (Date.now() < end) {} }, 0); return true; });
    await sleep(200);
    const t0 = Date.now();
    const evaluate = timed(t0, p1.evaluate("Date.now()"));
    const disable = await timed(t0, p1.cdp("egoAutomated.disable"));
    const enable = await timed(t0, p1.cdp("Runtime.enable"));
    const off = await timed(t0, p1.cdp("Runtime.disable"));
    const hide = await timed(t0, p1.cdp("egoAutomated.enable"));
    return { evaluateMs: await evaluate, disableMs: disable, runtimeEnableMs: enable, runtimeDisableMs: off, enableHidingMs: hide };
  });
  await sleep(3000);
}
await run("a10.drain", async () => (await p1.events()).length);
await run("z.finish", () => task.finish({ keep: [] }));
