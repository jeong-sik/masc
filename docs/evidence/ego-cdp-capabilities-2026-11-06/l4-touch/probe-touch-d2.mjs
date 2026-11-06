// L4 probe d2: a new SDK process on the same Page. Is the press still down?
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const task = await taskSpace("masc-l4-touch-d");
log("space", task.spaceId);
const page = task.page("p1");
const events = () => page.evaluate(`(() => { const rows = window.__events; window.__events = []; return rows.map(r => r.kind + '(' + r.x + ',' + r.y + ')').join(' '); })()`);
const touch = (type, points) => page.cdp("Input.dispatchTouchEvent", { type, touchPoints: points.map(([x, y]) => ({ x, y })) });
await run("eventsSoFar", events);
await run("tapStart", () => touch("touchStart", [[300, 100]]));
await run("tapEnd", () => touch("touchEnd", []));
await run("eventsTap", events);
await run("cancel", () => touch("touchCancel", []));
await run("eventsCancel", events);
await run("finish", () => task.finish({ keep: [] }));
