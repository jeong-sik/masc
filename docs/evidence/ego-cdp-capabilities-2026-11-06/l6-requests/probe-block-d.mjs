const blockRequests =
async function(page, args, reason) {
  const registry = globalThis.mascBlockedHosts ??= new Map();
  const before = registry.get(args.label) ?? [];
  const hosts = args.hosts === null ? [] : [...new Set([...before, ...args.hosts])].sort();
  try {
    await page.cdp("Network.setBlockedURLs",
      {urlPatterns: hosts.map(host => ({urlPattern: "*://" + host + ":*/*", block: true}))});
  } catch (error) {
    return {ok: false, error: "Network.setBlockedURLs failed: " + reason(error)};
  }
  if (hosts.length === 0) registry.delete(args.label); else registry.set(args.label, hosts);
  return {ok: true, value: args.hosts === null ? {unblocked: before.length} : {blocked: hosts}};
};

// L6 probe d: the production request_block_script (block.js) on a real Page.
// No call here opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const reason = (error) => String(error && error.message || error);
const port = 18773;
const origin = `http://127.0.0.1:${port}`;
const task = await taskSpace("masc-l6-block-d");
log("space", task.spaceId);
const p1 = task.page("p1");
const p2label = (await task.newPage()).label;
const p2 = task.page(p2label);
const targets = { a: `http://a.localhost:${port}/x.txt`, b: `http://b.localhost:${port}/x.txt`, c: `http://c.localhost:${port}/x.txt` };
const fetchAll = (page) => page.evaluate(async (urls) => {
  const out = {};
  for (const [name, url] of Object.entries(urls)) {
    try { await fetch(url, { mode: "no-cors", cache: "no-store" }); out[name] = "ok"; }
    catch (error) { out[name] = "blocked"; }
  }
  return out;
}, targets);
await run("goto1", () => p1.goto(origin + "/index.html"));
await run("goto2", () => p2.goto(origin + "/index.html"));
await run("m.blockA", () => blockRequests(p1, { label: "p1", hosts: ["a.localhost"] }, reason));
await run("m.blockB", () => blockRequests(p1, { label: "p1", hosts: ["b.localhost", "a.localhost"] }, reason));
await run("m.p1", () => fetchAll(p1));
await run("m.p2", () => fetchAll(p2));
// N: a cross-site navigation of the same Page.
await run("n.gotoOtherSite", () => p1.goto(`http://localhost:${port}/index.html`));
await run("n.p1", () => fetchAll(p1));
await run("o.unblock", () => blockRequests(p1, { label: "p1", hosts: null }, reason));
await run("o.p1", () => fetchAll(p1));
await run("o.unblockAgain", () => blockRequests(p1, { label: "p1", hosts: null }, reason));
await run("finish", () => task.finish({ keep: [] }));
