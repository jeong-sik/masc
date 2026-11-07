// L4 probe c: touchCancel when no touch is down, in a fresh SDK process.
// No call here opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const origin = "http://127.0.0.1:18771";
const task = await taskSpace("masc-l4-touch-c");
log("space", task.spaceId);
const page = task.page("p1");
const events = () => page.evaluate(`(() => { const rows = window.__events; window.__events = []; return rows; })()`);
const touch = (type, points) => page.cdp("Input.dispatchTouchEvent", { type, touchPoints: points.map(([x, y]) => ({ x, y })) });
const timed = async (fn) => { const start = Date.now(); const value = await fn(); return { value, ms: Date.now() - start }; };

await run("goto", () => page.goto(origin + "/index.html"));
// J: nothing is down. Does touchCancel reach the page?
await run("j.touchCancel", () => timed(() => touch("touchCancel", [])));
await run("j.events", events);
await run("j.touchCancelAgain", () => timed(() => touch("touchCancel", [])));
await run("j.eventsAgain", events);
// K: a tap right after the cancels.
await run("k.tapStart", () => touch("touchStart", [[100, 100]]));
await run("k.tapEnd", () => touch("touchEnd", []));
await run("k.events", events);
// L: cancel then tap, as every touch command would start.
await run("l.cancel", () => touch("touchCancel", []));
await run("l.tapStart", () => touch("touchStart", [[120, 100]]));
await run("l.tapEnd", () => touch("touchEnd", []));
await run("l.events", events);

await run("finish", () => task.finish({ keep: [] }));
