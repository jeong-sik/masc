// L6 probe c: which requests a blocked host loses: frame navigation, image, script navigation.
// Network.enable here only lets the probe read why a request failed.
// No call here opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const port = 18773;
const origin = `http://127.0.0.1:${port}`;
const blocked = `http://blocked.localhost:${port}`;
const task = await taskSpace("masc-l6-block-c");
log("space", task.spaceId);
const page = task.page("p1");
const failures = async () => {
  const events = await page.events();
  const urls = new Map();
  const out = [];
  for (const event of events) {
    const method = event.method || event.type;
    const params = event.params || event.data || {};
    if (method === "Network.requestWillBeSent") urls.set(params.requestId, { url: params.request && params.request.url, type: params.type ?? null });
    if (method === "Network.loadingFailed") out.push({ ...(urls.get(params.requestId) ?? {}), errorText: params.errorText, blockedReason: params.blockedReason ?? null });
  }
  return out;
};
await run("goto", () => page.goto(origin + "/index.html"));
await run("enable", () => page.cdp("Network.enable", {}));
await run("block", () => page.cdp("Network.setBlockedURLs", { urlPatterns: [{ urlPattern: "*://blocked.localhost:*/*", block: true }] }));
await run("drain", async () => (await failures()).length);
// J: an iframe whose document is on the blocked host.
await run("j.frame", () => page.evaluate((src) => window.addFrame(src), `${blocked}/frame.html`));
await run("j.frameReachable", () => page.evaluate((url) => window.frameFetch(0, url), `${origin}/x.txt`));
// K: an image on the blocked host.
await run("k.image", () => page.evaluate((src) => new Promise((resolve) => { const image = new Image(); image.onload = () => resolve("load"); image.onerror = () => resolve("error"); image.src = src; }), `${blocked}/x.txt?image`));
await run("jk.why", failures);
// L: the page's own script navigates to the blocked host.
await run("l.assign", () => page.evaluate((url) => { location.assign(url); return true; }, `${blocked}/x.txt?assigned`));
await run("l.wait", () => new Promise((resolve) => setTimeout(() => resolve(true), 1000)));
await run("l.where", async () => ({ url: await page.url(), text: await page.evaluate("document.body ? document.body.innerText.slice(0, 80) : null") }));
await run("l.why", failures);
await run("back", () => page.goto(origin + "/index.html"));
await run("clear", () => page.cdp("Network.setBlockedURLs", { urlPatterns: [] }));
await run("disable", () => page.cdp("Network.disable", {}));
await run("finish", () => task.finish({ keep: [] }));
