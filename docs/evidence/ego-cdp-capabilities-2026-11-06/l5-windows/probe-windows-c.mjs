// L5 probe c: Browser.getWindowForTarget while the Page's renderer is proven busy.
// No call here opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const origin = "http://127.0.0.1:18772";
const timed = async (fn) => { const start = Date.now(); try { const value = await fn(); return { value, ms: Date.now() - start }; } catch (error) { return { error: String((error && error.message) || error), ms: Date.now() - start }; } };
const task = await taskSpace("masc-l5-windows-c");
log("space", task.spaceId);
const p1 = task.page("p1");
await run("goto", () => p1.goto(origin + "/index.html?busy"));
for (const round of [1, 2, 3]) {
  await run(`r${round}.busy`, () => p1.evaluate("window.busy(3000), true"));
  await run(`r${round}.settle`, () => new Promise((resolve) => setTimeout(() => resolve(true), 200)));
  // Started together: the window read and a page read that must wait for the renderer.
  const pageRead = timed(() => p1.evaluate("Date.now()"));
  const windowRead = timed(() => task.cdp("Browser.getWindowForTarget", { targetId: p1.targetId }));
  const tabsRead = timed(async () => (await task.tabs()).length);
  await run(`r${round}.window`, () => windowRead);
  await run(`r${round}.tabs`, () => tabsRead);
  await run(`r${round}.page`, () => pageRead);
}
await run("finish", () => task.finish({ keep: [] }));
