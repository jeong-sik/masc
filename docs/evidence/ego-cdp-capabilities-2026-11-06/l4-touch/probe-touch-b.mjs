// L4 probe b: swipe without touch emulation, and a touch left down.
// No call here opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const origin = "http://127.0.0.1:18771";
const task = await taskSpace("masc-l4-touch-b");
log("space", task.spaceId);
const page = task.page("p1");
const state = () => page.evaluate(`({ maxTouchPoints: navigator.maxTouchPoints, pointerCoarse: matchMedia('(pointer: coarse)').matches, scrollY: Math.round(scrollY) })`);
const events = () => page.evaluate(`(() => { const rows = window.__events; window.__events = []; return rows; })()`);
const touch = (type, points) => page.cdp("Input.dispatchTouchEvent", { type, touchPoints: points.map(([x, y]) => ({ x, y })) });
const timed = async (fn) => { const start = Date.now(); const value = await fn(); return { value, ms: Date.now() - start }; };
const pause = (ms) => page.evaluate(`new Promise(resolve => setTimeout(resolve, ${ms}))`);

await run("goto", () => page.goto(origin + "/index.html"));
await run("stateBefore", state);

// F: the same swipe as probe a, with no emulation.
await run("f.touchStart", () => timed(() => touch("touchStart", [[200, 500]])));
for (const [i, y] of [400, 300, 200].entries()) await run(`f.touchMove${i}`, () => timed(() => touch("touchMove", [[200, y]])));
await run("f.touchEnd", () => timed(() => touch("touchEnd", [])));
await run("f.pause", () => pause(800));
await run("f.events", events);
await run("f.stateAfter", state);

// G: a slow swipe, 20 moves 25 ms apart, does it scroll by the dragged distance?
await run("g.scrollTop", () => page.evaluate("scrollTo(0, 0), Math.round(scrollY)"));
await run("g.touchStart", () => touch("touchStart", [[200, 600]]));
for (let i = 1; i <= 20; i++) { await touch("touchMove", [[200, 600 - i * 15]]); await new Promise((r) => setTimeout(r, 25)); }
await run("g.touchEnd", () => timed(() => touch("touchEnd", [])));
await run("g.pause", () => pause(800));
await run("g.eventKinds", async () => (await events()).map((r) => r.kind).join(" "));
await run("g.stateAfter", state);

// H: a press whose release is lost, then a new tap.
await run("h.scrollTop", () => page.evaluate("scrollTo(0, 0), Math.round(scrollY)"));
await run("h.touchStart", () => touch("touchStart", [[100, 100]]));
await run("h.eventsHeld", events);
await run("h.nextTapStart", () => timed(() => touch("touchStart", [[300, 100]])));
await run("h.nextTapEnd", () => timed(() => touch("touchEnd", [])));
await run("h.eventsNextTap", events);

// I: a press left down, cleared with touchCancel, then a new tap.
await run("i.touchStart", () => touch("touchStart", [[100, 100]]));
await run("i.touchCancel", () => timed(() => touch("touchCancel", [])));
await run("i.eventsCancel", events);
await run("i.tapStart", () => touch("touchStart", [[300, 100]]));
await run("i.tapEnd", () => touch("touchEnd", []));
await run("i.eventsTap", events);

await run("finish", () => task.finish({ keep: [] }));
