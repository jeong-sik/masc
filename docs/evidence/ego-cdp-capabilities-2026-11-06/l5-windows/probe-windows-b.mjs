// L5 probe b: do two task spaces share a window, and where does a CDP new window go?
// No call here opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const origin = "http://127.0.0.1:18772";
const rows = async (task) => Promise.all((await task.tabs()).map(async (t) => {
  let windowId = null, error = null;
  try { windowId = (await task.cdp("Browser.getWindowForTarget", { targetId: t.targetId })).windowId; } catch (e) { error = String(e && e.message || e); }
  return { label: t.label ?? null, targetId: t.targetId, openedBy: t.openedBy, url: t.url, windowId, error };
}));
const one = await taskSpace("masc-l5-windows-b1");
log("space1", one.spaceId);
await run("goto1", () => one.page("p1").goto(origin + "/index.html?space1"));
const two = await run("space2", async () => { const s = await taskSpace("masc-l5-windows-b2"); return s; });
if (two) {
  log("space2Id", two.spaceId);
  await run("goto2", () => two.page("p1").goto(origin + "/index.html?space2"));
}
await run("rows1", () => rows(one));
if (two) await run("rows2", () => rows(two));
// G: a CDP-created new window, from space one.
const created = await run("g.createTarget", () => one.cdp("Target.createTarget", { url: origin + "/index.html?newwin", newWindow: true }));
await run("g.pause", () => new Promise((resolve) => setTimeout(() => resolve(true), 800)));
if (created && created.targetId) {
  await run("g.windowOfCreated", () => one.cdp("Browser.getWindowForTarget", { targetId: created.targetId }));
  await run("g.rows1", () => rows(one));
  if (two) await run("g.rows2", () => rows(two));
  const listed = (await one.tabs()).find((t) => t.targetId === created.targetId);
  if (listed && listed.label) await run("g.closeManaged", () => one.page(listed.label).close());
  else await run("g.closeTarget", () => one.cdp("Target.closeTarget", { targetId: created.targetId }));
  await run("g.rowsAfterClose", () => rows(one));
}
await run("finish1", () => one.finish({ keep: [] }));
if (two) await run("finish2", () => two.finish({ keep: [] }));
