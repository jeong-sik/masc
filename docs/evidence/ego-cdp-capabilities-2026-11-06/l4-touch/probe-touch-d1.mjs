// L4 probe d1: press and end the SDK process without a release.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const task = await taskSpace("masc-l4-touch-d");
log("space", task.spaceId);
const page = task.page("p1");
await page.goto("http://127.0.0.1:18771/index.html");
await page.cdp("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: 100, y: 100 }] });
log("held", await page.evaluate("window.__events.map(r => r.kind).join(' ')"));
