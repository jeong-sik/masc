// L5 probe a: Browser.getWindowForTarget for every tab of a dedicated task space.
// No call here opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const origin = "http://127.0.0.1:18772";
const timed = async (fn) => { const start = Date.now(); try { const value = await fn(); return { value, ms: Date.now() - start }; } catch (error) { return { error: String((error && error.message) || error), ms: Date.now() - start }; } };
const task = await taskSpace("masc-l5-windows-a");
log("space", task.spaceId);
const win = (targetId) => task.cdp("Browser.getWindowForTarget", { targetId });
const rows = async () => (await task.tabs()).map((t) => ({ label: t.label ?? null, targetId: t.targetId, active: t.active, openedBy: t.openedBy, url: t.url }));
const windows = async () => Promise.all((await task.tabs()).map(async (t) => ({ label: t.label ?? null, ...(await timed(() => win(t.targetId))) })));
const p1 = task.page("p1");
await run("goto1", () => p1.goto(origin + "/index.html?p1"));
// A: one tab.
await run("a.tabs", rows);
await run("a.windows", windows);
// B: a second Page and an agent-opened target=_blank tab.
const p2 = await run("b.newPage", async () => (await task.newPage()).label);
if (p2) await run("b.goto2", () => task.page(p2).goto(origin + "/index.html?p2"));
const tabPopup = p1.waitForEvent("popup");
await run("b.clickBlank", async () => { const r = await p1.click("#blank"); return r && r.popups ? r.popups : null; });
await run("b.popupLabel", async () => (await tabPopup).label);
await run("b.tabs", rows);
await run("b.windows", windows);
// C: latency, sequential versus parallel, 10 rounds each.
await run("c.sequential", async () => { const out = []; for (let i = 0; i < 10; i++) { const start = Date.now(); for (const t of await task.tabs()) await win(t.targetId); out.push(Date.now() - start); } return out; });
await run("c.parallel", async () => { const out = []; for (let i = 0; i < 10; i++) { const start = Date.now(); await Promise.all((await task.tabs()).map((t) => win(t.targetId))); out.push(Date.now() - start); } return out; });
await run("c.tabsOnly", async () => { const out = []; for (let i = 0; i < 10; i++) { const start = Date.now(); await task.tabs(); out.push(Date.now() - start); } return out; });
// D: the renderer of p1 is busy for 3 s.
await run("d.busy", () => p1.evaluate("window.busy(3000), true"));
await run("d.windowsWhileBusy", windows);
await run("d.tabsWhileBusy", async () => timed(rows));
await run("d.waitBusyEnd", () => new Promise((resolve) => setTimeout(() => resolve(true), 3500)));
// E: a target that does not exist.
await run("e.unknownTarget", () => timed(() => win("0000000000000000000000000000DEAD")));
// F: a popup window opened by an agent click.
const winPopup = p1.waitForEvent("popup");
await run("f.clickPopup", async () => { const r = await p1.click("#popup"); return r && r.popups ? r.popups : null; });
await run("f.popupLabel", async () => (await winPopup).label);
await run("f.tabs", rows);
await run("f.windows", windows);
await run("finish", () => task.finish({ keep: [] }));
