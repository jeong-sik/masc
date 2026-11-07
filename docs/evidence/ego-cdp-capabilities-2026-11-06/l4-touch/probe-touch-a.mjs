// L4 probe a: CDP touch input on an ego Page. No call here opens a
// permission prompt or a dialog. Each step prints its own line at once.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const origin = "http://127.0.0.1:18771";
const task = await taskSpace("masc-l4-touch");
log("space", task.spaceId);
const page = task.page("p1");
const state = () => page.evaluate(`({
  maxTouchPoints: navigator.maxTouchPoints,
  ontouchstart: 'ontouchstart' in window,
  pointerCoarse: matchMedia('(pointer: coarse)').matches,
  anyPointerCoarse: matchMedia('(any-pointer: coarse)').matches,
  hoverNone: matchMedia('(hover: none)').matches,
  scrollY: Math.round(scrollY),
  viewport: [innerWidth, innerHeight]
})`);
const events = () => page.evaluate(`(() => { const rows = window.__events; window.__events = []; return rows; })()`);
const touch = (type, points) => page.cdp("Input.dispatchTouchEvent", { type, touchPoints: points.map(([x, y]) => ({ x, y })) });
const timed = async (fn) => { const start = Date.now(); const value = await fn(); return { value, startedAt: start, returnedAt: Date.now(), ms: Date.now() - start }; };
const pause = (ms) => page.evaluate(`new Promise(resolve => setTimeout(resolve, ${ms}))`);

await run("goto", () => page.goto(origin + "/index.html"));
await run("stateBefore", state);

// A: no touch emulation.
await run("a.touchStart", () => timed(() => touch("touchStart", [[100, 100]])));
await run("a.touchEnd", () => timed(() => touch("touchEnd", [])));
await run("a.events", events);

// B: with touch emulation.
await run("b.enable", () => page.cdp("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 1 }));
await run("b.state", state);
await run("b.touchStart", () => timed(() => touch("touchStart", [[100, 100]])));
await run("b.touchEnd", () => timed(() => touch("touchEnd", [])));
await run("b.events", events);

// C: a swipe upward through three points, with emulation on.
await run("c.stateBefore", state);
await run("c.touchStart", () => touch("touchStart", [[200, 500]]));
for (const [i, y] of [400, 300, 200].entries()) await run(`c.touchMove${i}`, () => touch("touchMove", [[200, y]]));
await run("c.touchEnd", () => timed(() => touch("touchEnd", [])));
await run("c.pause", () => pause(800));
await run("c.events", events);
await run("c.stateAfter", state);
await run("c.lastScroll", () => page.evaluate("window.__lastScroll || null"));

// D: a touchend handler that runs 400 ms. Does the CDP answer wait for it?
await run("d.scrollTop", () => page.evaluate("scrollTo(0, 0), Math.round(scrollY)"));
await run("d.busy", () => page.evaluate("window.__busyMs = 400"));
await run("d.touchStart", () => timed(() => touch("touchStart", [[100, 100]])));
await run("d.touchEnd", () => timed(() => touch("touchEnd", [])));
await run("d.events", events);
await run("d.unbusy", () => page.evaluate("window.__busyMs = 0"));

// E: emulation off again.
await run("e.disable", () => page.cdp("Emulation.setTouchEmulationEnabled", { enabled: false }));
await run("e.state", state);
await run("e.touchStart", () => touch("touchStart", [[100, 100]]));
await run("e.touchEnd", () => touch("touchEnd", []));
await run("e.events", events);

await run("finish", () => task.finish({ keep: [] }));
