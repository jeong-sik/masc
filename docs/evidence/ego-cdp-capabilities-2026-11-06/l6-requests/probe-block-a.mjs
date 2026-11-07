// L6 probe a: Network.setBlockedURLs urlPatterns on one Page, without Network.enable.
// No call here opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const port = 18773;
const origin = `http://127.0.0.1:${port}`;
const task = await taskSpace("masc-l6-block-a");
log("space", task.spaceId);
const page = task.page("p1");
const block = (hosts) => page.cdp("Network.setBlockedURLs", { urlPatterns: hosts.map((host) => ({ urlPattern: `*://${host}:*/*`, block: true })) });
const targets = {
  blocked: `http://blocked.localhost:${port}/x.txt`,
  blockedQuery: `http://blocked.localhost:${port}/x.txt?q=1#h`,
  subdomain: `http://sub.blocked.localhost:${port}/x.txt`,
  other: `http://other.localhost:${port}/x.txt`,
  inQuery: `${origin}/x.txt?u=http://blocked.localhost:${port}/`,
  self: `${origin}/x.txt`,
};
const fetchAll = () => page.evaluate(async (urls) => {
  const out = {};
  for (const [name, url] of Object.entries(urls)) out[name] = await window.probeFetch(url);
  return out;
}, targets);
await run("goto", () => page.goto(origin + "/index.html"));
await run("a.before", fetchAll);
// A: block one host, Network domain not enabled.
await run("a.block", () => block(["blocked.localhost"]));
await run("a.after", fetchAll);
// Frames added after the block: same-origin, then cross-site.
await run("a.frameSame", () => page.evaluate((src) => window.addFrame(src), `${origin}/frame.html`));
await run("a.frameCross", () => page.evaluate((src) => window.addFrame(src), `http://localhost:${port}/frame.html`));
await run("a.frameFetch", () => page.evaluate(async (urls) => ({
  sameBlocked: await window.frameFetch(0, urls.blocked), sameOther: await window.frameFetch(0, urls.other),
  crossBlocked: await window.frameFetch(1, urls.blocked), crossOther: await window.frameFetch(1, urls.other),
}), targets));
// B: a second call with another host. Replaced or added?
await run("b.block", () => block(["other.localhost"]));
await run("b.after", fetchAll);
// C: union of both, then reload. Does it survive the navigation?
await run("c.block", () => block(["blocked.localhost", "other.localhost"]));
await run("c.reload", () => page.reload());
await run("c.afterReload", fetchAll);
// D: navigation to a blocked host, explicit and default port.
await run("d.gotoBlocked", () => page.goto(`http://blocked.localhost:${port}/x.txt`, { timeout: 5000 }));
await run("d.gotoBlockedDefaultPort", () => page.goto("http://blocked.localhost/x.txt", { timeout: 5000 }));
await run("d.gotoUnblockedDefaultPort", () => page.goto("http://free.localhost/x.txt", { timeout: 5000 }));
await run("d.back", () => page.goto(origin + "/index.html"));
// E: clear.
await run("e.clear", () => page.cdp("Network.setBlockedURLs", { urlPatterns: [] }));
await run("e.after", fetchAll);
// F: the deprecated urls glob, the same host.
await run("f.blockUrls", () => page.cdp("Network.setBlockedURLs", { urls: [`*://blocked.localhost:*/*`] }));
await run("f.after", fetchAll);
await run("f.clear", () => page.cdp("Network.setBlockedURLs", { urls: [] }));
await run("f.afterClear", fetchAll);
await run("finish", () => task.finish({ keep: [] }));
