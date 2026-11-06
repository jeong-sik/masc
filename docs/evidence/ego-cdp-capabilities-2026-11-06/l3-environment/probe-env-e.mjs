// L3 probe 3, a new SDK process: does the grant outlive the process, how is it
// removed, and what does setPermission alone change? No prompt-capable call.
const log = (step, value) => console.log(JSON.stringify({ step, value }));
const run = async (step, fn) => { try { const v = await fn(); log(step, v ?? null); return v; } catch (e) { log(step, { error: String((e && e.message) || e) }); } };
const states = (page) => page.evaluate(`(async () => {
  const out = { url: location.href };
  for (const name of ["geolocation", "notifications", "camera", "microphone"]) out[name] = (await navigator.permissions.query({ name })).state;
  return out; })()`);
const task = await taskSpace("masc-l3-environment-v2");
const page = task.page("p1");
await run("newProcess 18769", () => states(page));
await run("resetPermissions", () => page.cdp("Browser.resetPermissions", {}));
await run("afterReset 18769", () => states(page));
await run("goto 18768", () => page.goto("http://127.0.0.1:18768/index.html"));
await run("afterReset 18768", () => states(page));
await run("goto 18770", () => page.goto("http://127.0.0.1:18770/index.html"));
await run("before 18770", () => states(page));
await run("setPermission 18770", () => page.cdp("Browser.setPermission", { permission: { name: "geolocation" }, setting: "granted", origin: "http://127.0.0.1:18770" }));
await run("afterSet 18770", () => states(page));
await run("setPermission no origin", () => page.cdp("Browser.setPermission", { permission: { name: "notifications" }, setting: "denied" }));
await run("afterNoOrigin 18770", () => states(page));
await run("goto 18769", () => page.goto("http://127.0.0.1:18769/index.html"));
await run("afterNoOrigin 18769", () => states(page));
