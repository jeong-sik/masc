// L6 probe b: what a blocked request fails with, the default port, and a navigation.
// Network.enable here only lets the probe read why a request failed.
// No call here opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const port = 18773;
const origin = `http://127.0.0.1:${port}`;
const task = await taskSpace("masc-l6-block-b");
log("space", task.spaceId);
const page = task.page("p1");
const patterns = (list) => page.cdp("Network.setBlockedURLs", { urlPatterns: list.map((urlPattern) => ({ urlPattern, block: true })) });
const fetchOne = (url) => page.evaluate((target) => window.probeFetch(target), url);
// Why each request failed, from the Network events since the last read.
const failures = async () => {
  const events = await page.events();
  const urls = new Map();
  const out = [];
  for (const event of events) {
    const method = event.method || event.type;
    const params = event.params || event.data || {};
    if (method === "Network.requestWillBeSent") urls.set(params.requestId, params.request && params.request.url);
    if (method === "Network.loadingFailed") out.push({ url: urls.get(params.requestId) ?? null, errorText: params.errorText, blockedReason: params.blockedReason ?? null });
  }
  return { events: events.length, failures: out };
};
await run("goto", () => page.goto(origin + "/index.html"));
await run("enable", () => page.cdp("Network.enable", {}));
await run("drain", failures);
// G: the port wildcard pattern, explicit and default port.
await run("g.block", () => patterns(["*://blocked.localhost:*/*"]));
await run("g.explicit", () => fetchOne(`http://blocked.localhost:${port}/x.txt`));
await run("g.default", () => fetchOne("http://blocked.localhost/x.txt"));
await run("g.freeDefault", () => fetchOne("http://free.localhost/x.txt"));
await run("g.why", failures);
// H: a pattern with no port part.
await run("h.block", () => patterns(["*://blocked.localhost/*"]));
await run("h.explicit", () => fetchOne(`http://blocked.localhost:${port}/x.txt`));
await run("h.default", () => fetchOne("http://blocked.localhost/x.txt"));
await run("h.why", failures);
// I: a navigation to a blocked host.
await run("i.block", () => patterns(["*://blocked.localhost:*/*"]));
await run("i.goto", () => page.goto(`http://blocked.localhost:${port}/x.txt`, { timeout: 5000 }));
await run("i.where", async () => ({ url: await page.url(), title: await page.title() }));
await run("i.text", () => page.evaluate("document.body ? document.body.innerText.slice(0, 120) : null"));
await run("i.why", failures);
await run("i.back", () => page.goto(origin + "/index.html"));
await run("clear", () => page.cdp("Network.setBlockedURLs", { urlPatterns: [] }));
await run("disable", () => page.cdp("Network.disable", {}));
await run("finish", () => task.finish({ keep: [] }));
